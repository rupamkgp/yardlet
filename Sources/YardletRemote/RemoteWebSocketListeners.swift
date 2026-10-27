import Foundation
import Network

/// The remote's WebSocket listeners (Network.framework `NWListener` with `NWProtocolWebSocket`): one
/// per address it may listen on, each bound to exactly that address (`requiredLocalEndpoint`), never
/// to every interface. Connections go to the `RemoteServer`. Everything runs on the listeners' own
/// queue, off the main thread.
public final class RemoteWebSocketListeners: @unchecked Sendable {
    public enum ListenerState: Equatable, Sendable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private let server: RemoteServer
    private let queue = DispatchQueue(label: "yardlet.remote.listeners")
    private var listeners: [RemoteListenAddress: NWListener] = [:]
    private var states: [RemoteListenAddress: ListenerState] = [:]
    private var channels: [ObjectIdentifier: RemoteNWChannel] = [:]
    private var port: NWEndpoint.Port
    /// Told on the listeners' queue whenever a listener's state changes.
    public var onStateChange: (@Sendable ([RemoteListenAddress: ListenerState]) -> Void)?

    public init(server: RemoteServer, port: UInt16 = RemoteProtocol.defaultPort) {
        self.server = server
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
    }

    /// Listens on exactly these addresses: starts the new ones and stops the ones no longer named.
    public func listen(on addresses: [RemoteListenAddress], port: UInt16? = nil) {
        queue.async { [self] in
            if let port, let value = NWEndpoint.Port(rawValue: port), value != self.port {
                self.port = value
                for address in Array(listeners.keys) { stopListener(address) }
            }
            let wanted = Set(addresses)
            for address in Array(listeners.keys) where !wanted.contains(address) { stopListener(address) }
            for address in addresses where listeners[address] == nil { startListener(address) }
            report()
        }
    }

    /// Stops every listener and connection.
    public func stop() {
        queue.sync {
            for address in Array(listeners.keys) { stopListener(address) }
            for channel in channels.values { channel.connection.cancel() }
            channels.removeAll()
            report()
        }
    }

    /// The states as they are now (tests, Settings).
    public var currentStates: [RemoteListenAddress: ListenerState] {
        queue.sync { states }
    }

    private func startListener(_ address: RemoteListenAddress) {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maxClientFrameBytes
        // A browser always sends Origin; a web page on the tailnet must not reach the remote.
        websocket.setClientRequestHandler(queue) { _, headers in
            let fromBrowser = headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
            return NWProtocolWebSocket.Response(status: fromBrowser ? .reject : .accept, subprotocol: nil,
                                                additionalHeaders: fromBrowser ? nil : [Self.acceptedHeader])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address.host), port: port)
        parameters.allowLocalEndpointReuse = true
        if address.kind == .loopback { parameters.acceptLocalOnly = true }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            states[address] = .failed(error.localizedDescription)
            return
        }
        listeners[address] = listener
        states[address] = .starting
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.states[address] = .ready(port: listener?.port?.rawValue ?? self.port.rawValue)
            case let .failed(error):
                self.states[address] = .failed(error.localizedDescription)
                listener?.cancel()
                self.listeners[address] = nil
            case let .waiting(error):
                self.states[address] = .failed(error.localizedDescription)
            default:
                return
            }
            self.report()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// The header an accepted handshake answers with, which tells it from a refused one.
    private static let acceptedHeader = (name: "X-Yardlet-Remote", value: String(RemoteProtocol.version))

    private static func wasAccepted(_ connection: NWConnection) -> Bool {
        let metadata = connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        return metadata?.additionalServerHeaders?.contains { $0.0 == acceptedHeader.name } == true
    }

    private func stopListener(_ address: RemoteListenAddress) {
        listeners.removeValue(forKey: address)?.cancel()
        states[address] = nil
    }

    private func report() {
        onStateChange?(states)
    }

    private func accept(_ connection: NWConnection) {
        let channel = RemoteNWChannel(connection: connection, queue: queue)
        channels[ObjectIdentifier(channel)] = channel
        let server = self.server
        connection.stateUpdateHandler = { [weak self, weak channel] state in
            guard let self, let channel else { return }
            switch state {
            case .ready:
                // A refused handshake still reaches `.ready` after its HTTP 400; only an accepted one
                // carries the marker header the request handler added.
                guard Self.wasAccepted(channel.connection) else {
                    channel.connection.cancel()
                    return
                }
                Task {
                    guard let id = await server.open(channel) else { return }
                    self.queue.async {
                        channel.serverID = id
                        switch channel.connection.state {
                        case .failed, .cancelled: Task { await server.closed(id) }
                        default: self.receive(on: channel)
                        }
                    }
                }
            case .failed, .waiting:
                channel.connection.cancel()
            case .cancelled:
                self.channels[ObjectIdentifier(channel)] = nil
                if let id = channel.serverID { Task { await server.closed(id) } }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reads one frame, hands it to the server, then reads the next, so frames stay in order.
    private func receive(on channel: RemoteNWChannel) {
        let server = self.server
        channel.connection.receiveMessage { [weak self, weak channel] data, context, _, error in
            guard let self, let channel, let id = channel.serverID else { return }
            if error != nil {
                channel.connection.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                let frame = data ?? Data()
                Task {
                    await server.receive(frame, on: id)
                    self.queue.async { self.receive(on: channel) }
                }
            case .close?:
                channel.connection.cancel()
            case .binary?:
                channel.close(.unsupportedData)
            default:
                self.receive(on: channel)
            }
        }
    }
}

/// A WebSocket connection as the server sees it.
final class RemoteNWChannel: RemoteChannel, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    /// Set once the server took the connection.
    var serverID: UUID?
    private var isClosing = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ text: String) {
        queue.async { [self] in
            guard !isClosing else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    func close(_ code: RemoteCloseCode) {
        queue.async { [self] in
            guard !isClosing else { return }
            isClosing = true
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = (try? NWProtocolWebSocket.CloseCode(rawValue: code.rawValue)) ?? .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
