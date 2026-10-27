import AppKit
import SwiftUI

/// Settings → Connectors → Set up Zoom: Zoom's own MCP servers, one per product (Meetings, Team
/// Chat, Docs), through one Zoom app of the person's own, since Zoom registers no client by itself
/// (docs/CONNECTORS.md, "Directory"). The steps open Zoom's app builder and copy the redirect URL
/// and the read scopes of the products picked; the client ID and secret are pasted once and serve
/// every product, each of which then signs in in the browser.
struct ZoomSetupPage: View {
    let center: ConnectorCenter
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var products: Set<String>
    @State private var busy = false
    @State private var error: String?
    @AppStorage(ConnectorSetupProgress.key) private var openedSteps = ""

    /// - Parameters:
    ///   - product: the product the page was opened for; all start picked either way.
    ///   - clientID: the field starts with this (review renders).
    init(center: ConnectorCenter, product: ConnectorPreset? = nil, clientID: String = "") {
        self.center = center
        _clientID = State(initialValue: clientID)
        _products = State(initialValue: Set(ConnectorSetupAssistant.zoomPresets.map(\.id)).union(product.map { [$0.id] } ?? []))
    }

    private var added: [ConnectorRecord] {
        center.connectors.filter { $0.preset?.isZoom == true }
    }

    private var picked: [ConnectorPreset] {
        ConnectorSetupAssistant.zoomPresets.filter { products.contains($0.id) }
    }

    private var idValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateZoomClientID(clientID) }
    private var secretValidation: ConnectorSetupAssistant.Validation { ConnectorSetupAssistant.validateZoomSecret(clientSecret) }

    private var assistant: ConnectorSetupAssistant {
        .zoom(opened: ConnectorSetupProgress.decode(openedSteps), products: picked,
              clientEntered: (idValidation.isValid && secretValidation.isValid) || added.contains(where: \.usesRegisteredClient),
              connected: added.contains { $0.status == .connected })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(L10n.string("Yardlet uses Zoom's own MCP servers with a Zoom app of yours. One app serves Meetings, Team Chat, and Docs; Yardlet asks Zoom only to read."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(ParityTheme.accent)
            }
            ConnectorSetupHeader(title: L10n.string("Set up Zoom"), assistant: assistant)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(assistant.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 28) }
                    ConnectorSetupStepRow(number: index + 1, step: step, isCurrent: assistant.current == step.id,
                                          onToggle: step.id == .zoomCreate || step.id == .zoomScopes ? { toggle(step.id) } : nil,
                                          onOpen: { mark(step.id) }) {
                        switch step.id {
                        case .zoomScopes: productPicker
                        case .zoomCredentials: credentials
                        case .zoomSignIn: signIn
                        default: EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .parityCard(cornerRadius: 10)
            Text(L10n.string("Each Zoom product needs its license on your account. A product your plan lacks connects but its tools answer with Zoom's reason."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mark(_ id: ConnectorSetupAssistant.StepID) {
        var steps = ConnectorSetupProgress.decode(openedSteps)
        steps.insert(id)
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    private func toggle(_ id: ConnectorSetupAssistant.StepID) {
        var steps = ConnectorSetupProgress.decode(openedSteps)
        if steps.contains(id) { steps.remove(id) } else { steps.insert(id) }
        openedSteps = ConnectorSetupProgress.encode(steps)
    }

    private var productPicker: some View {
        HStack(spacing: 12) {
            ForEach(ConnectorSetupAssistant.zoomPresets) { preset in
                Toggle(preset.name.replacingOccurrences(of: "Zoom ", with: ""), isOn: Binding(
                    get: { products.contains(preset.id) },
                    set: { on in if on { products.insert(preset.id) } else { products.remove(preset.id) } }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private var credentials: some View {
        HStack(alignment: .top, spacing: 6) {
            ConnectorValidatedField(title: L10n.string("Zoom client ID"), text: $clientID, validation: idValidation)
            ConnectorValidatedField(title: L10n.string("Client secret"), text: $clientSecret, secure: true, validation: secretValidation)
                .frame(width: 190)
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(added) { record in
                let state = ConnectorSettingsState.make(record, in: center)
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(record.name).font(.caption.weight(.medium))
                    Text(state.word).font(.caption).foregroundStyle(.secondary)
                    if case .error(let reason) = state {
                        Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.string("Sign in to Zoom"), action: connect)
                        .parityProminentButton()
                        .controlSize(.small)
                        .disabled(!idValidation.isValid || !secretValidation.isValid || picked.isEmpty)
                }
            }
        }
        .padding(.top, 2)
    }

    /// Adds each picked product not added yet with the app, or gives one added already the app,
    /// and signs each in.
    private func connect() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let products = picked
        busy = true
        error = nil
        Task {
            do {
                for preset in products {
                    if let existing = added.first(where: { $0.presetID == preset.id }) {
                        try await center.useRegisteredClient(id: id, secret: secret, for: existing.id)
                        // One sign-in at a time: a registered app's redirect is the one fixed port.
                        await center.waitForConnection(existing.id)
                    } else {
                        let record = try await center.add(name: preset.name, serverURL: preset.serverURL,
                                                          client: (id: id, secret: secret), preset: preset)
                        center.connect(record.id)
                        await center.waitForConnection(record.id)
                    }
                }
                clientID = ""
                clientSecret = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
