import AppKit
import SwiftUI

/// The result body of an MCP tool call, shown in the timeline card that already names the server
/// and tool. Text keeps the bounded monospaced treatment the command output uses; an image is a
/// scaled preview that opens over the window with the result's other images; a resource link is
/// its name, description and URI.
struct CodexMCPResultContent: View {
    let projection: CodexMCPResultProjection

    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing

    var body: some View {
        if !projection.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(projection.blocks) { block in
                    switch block {
                    case let .text(_, text):
                        CodexBoundedOutput(text: text)
                    case let .image(id, data, _):
                        CodexMCPResultImage(data: data) { open(id) }
                    case let .resourceLink(_, link):
                        CodexMCPResultLink(link: link)
                    }
                }
            }
        }
    }

    private func open(_ id: CodexMCPResultProjection.Block.ID) {
        let images = projection.blocks.compactMap { block -> (id: CodexMCPResultProjection.Block.ID, data: Data)? in
            guard case let .image(id, data, _) = block else { return nil }
            return (id, data)
        }
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        pauseFollowing()
        openImageViewer(ImageViewerRequest(
            items: images.map { ImageViewerItem(name: L10n.string("Tool result image"), source: .data($0.data)) },
            index: index
        ))
    }
}

/// A link the tool returned. One Yardlet opens (a web page, a file) is a link in the accent color
/// that goes through the conversation's `openURL`, as a link in a message does; any other URI is
/// plain text the person can read and select, never something a click launches.
private struct CodexMCPResultLink: View {
    let link: CodexMCPResultProjection.ResourceLink

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openURL) private var openURL

    var body: some View {
        let url = link.openableURL
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: url?.isFileURL == true ? "doc" : "link")
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 14 * interfaceScale)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let url {
                        Button { openURL(url) } label: {
                            Text(verbatim: link.label)
                                .foregroundStyle(ParityTheme.accent)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .parityPointer()
                        .help(link.uri)
                        .accessibilityLabel(L10n.format("Open %@", link.label))
                    } else {
                        Text(verbatim: link.label)
                            .textSelection(.enabled)
                    }
                    if let mimeType = link.mimeType {
                        Text(verbatim: mimeType)
                            .font(.system(size: 11 * interfaceScale))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12.5 * interfaceScale, weight: .medium))
                if let description = link.description {
                    Text(verbatim: description)
                        .font(.system(size: 12 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if link.uri != link.label, !link.uri.isEmpty {
                    Text(verbatim: link.uri)
                        .font(.system(size: 11 * interfaceScale, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CodexMCPResultImage: View {
    let data: Data
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        if let image = NSImage(data: data) {
            Button(action: open) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260 * interfaceScale, maxHeight: 190 * interfaceScale)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(ParityTheme.separator) }
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.string("Tool result image"))
            .help(L10n.string("View the image"))
        }
    }
}
