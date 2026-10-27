import AppKit
import SwiftUI

/// An item's current two-factor code as authenticator apps show it (docs/BROWSER_VAULT_DESIGN.md §14):
/// the code in two groups, a ring with the seconds it has left, and a button that copies it.
struct VaultLiveCode: View {
    let vault: VaultCenter
    let secret: OneTimeCodeSecret
    @State private var copiedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = vault.code(for: secret, at: context.date)
            let remaining = secret.period - Int(context.date.timeIntervalSince1970) % secret.period
            HStack(spacing: 8) {
                Text(verbatim: Self.grouped(code))
                    .font(.system(.body, design: .monospaced).weight(.medium))
                VaultCodeTimer(remaining: remaining, period: secret.period)
                Button {
                    Self.copy(code)
                    copiedAt = context.date
                } label: {
                    Image(systemName: copiedAt.map { context.date.timeIntervalSince($0) < 2 } == true ? "checkmark" : "doc.on.doc")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Copy Code"))
                .accessibilityLabel(L10n.string("Copy Code"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.format("Code %@, %lld seconds left", Self.grouped(code), Int64(remaining)))
        }
    }

    /// "123 456", "1234 5678".
    static func grouped(_ code: String) -> String {
        guard code.count >= 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return String(code[..<middle]) + " " + String(code[middle...])
    }

    /// Copies the code marked as concealed, so clipboard history apps leave it out (nspasteboard.org).
    static func copy(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

/// The seconds a code has left, as a ring that empties and the number beside it.
private struct VaultCodeTimer: View {
    let remaining: Int
    let period: Int

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(ParityTheme.separator, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(period, 1)))
                    .stroke(remaining <= 5 ? Color.orange : Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(verbatim: "\(remaining)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}
