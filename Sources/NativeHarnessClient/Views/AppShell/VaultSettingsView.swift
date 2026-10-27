import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Passwords (docs/BROWSER_VAULT_DESIGN.md §8.1, §9, §14): the switch that gives tasks
/// `browser_fill_credential`, the current two-factor codes as an authenticator app lists them, the saved
/// items with their sites, kinds, agent use and last use, adding one, importing a browser's CSV export
/// or an authenticator app's export QR code, and emptying the vault. Rows follow Settings → General and
/// Connectors.
struct VaultSettingsView: View {
    @ObservedObject var vault: VaultCenter
    @State private var editing: Editing?
    @State private var confirmsEmptying = false
    /// Sites that held a Yardlet passkey, shown once the vault is emptied.
    @State private var passkeySites: [String] = []
    @State private var imported: Imported?
    @State private var failure: String?
    /// The items' code secrets, read from the keychain while the page shows codes.
    @State private var codeSecrets: [UUID: OneTimeCodeSecret] = [:]

    private struct Editing: Identifiable {
        let id = UUID()
        let item: VaultItem?
    }

    private struct Imported {
        let title: String
        let count: Int
        let files: [URL]
    }

    private var codeItems: [VaultItem] { vault.items.filter(\.hasOneTimeCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switchCard
            if !codeItems.isEmpty { codeList }
            VStack(alignment: .trailing, spacing: 8) {
                itemList
                HStack(spacing: 8) {
                    Button(L10n.string("Import QR Code…"), action: importQRCodes)
                    Button(L10n.string("Import CSV…"), action: importCSV)
                    Button {
                        editing = Editing(item: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(L10n.string("Add sign-in"))
                    .accessibilityLabel(L10n.string("Add sign-in"))
                }
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
                .alert(imported?.title ?? "",
                       isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } }),
                       presenting: imported) { result in
                    if result.count > 0 {
                        // An export holds secrets in the clear.
                        Button(L10n.string("Move the file to the Trash")) {
                            for file in result.files { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                        }
                        Button(L10n.string("Keep"), role: .cancel) {}
                    } else {
                        Button(L10n.string("OK"), role: .cancel) {}
                    }
                }
            }
            HStack(spacing: 8) {
                Button(L10n.string("Delete all passwords…"), role: .destructive) { confirmsEmptying = true }
                    .controlSize(.small)
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .alert(L10n.string("Delete all saved passwords?"), isPresented: $confirmsEmptying) {
                Button(L10n.string("Delete All"), role: .destructive, action: empty)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("Every saved sign-in and its history is deleted from this Mac."))
            }
        }
        .alert(L10n.string("Remove Yardlet's passkey on these sites too"),
               isPresented: Binding(get: { !passkeySites.isEmpty }, set: { if !$0 { passkeySites = [] } })) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(passkeySites.joined(separator: "\n"))
        }
        .sheet(item: $editing) { editing in
            VaultItemSheet(vault: vault, item: editing.item) { self.editing = nil }
        }
    }

    private var switchCard: some View {
        HStack(spacing: 12) {
            VaultSettingsIcon(systemName: "lock.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Password manager for agents")).font(.callout.weight(.medium))
                if !vault.isAllowedBuild {
                    Text(L10n.string("Available in team-signed builds of Yardlet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // A build that cannot keep items behind the team's code requirement shows the vault off.
            Toggle(L10n.string("Password manager for agents"), isOn: Binding(
                get: { vault.isAllowedBuild && vault.isEnabled }, set: { vault.isEnabled = $0 }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .parityCard()
    }

    /// Every item's current code, as an authenticator app lists them; the row's button copies one.
    private var codeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Two-factor codes"))
                .font(.callout.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(codeItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, SettingsCenterView.dividerLeading) }
                    HStack(spacing: 12) {
                        VaultSettingsIcon(systemName: "number")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            let detail = [item.username, item.sites.joined(separator: ", ")].filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        if let secret = codeSecrets[item.id] {
                            VaultLiveCode(vault: vault, secret: secret)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .parityCard()
        }
        .task(id: codeItems.map(\.id)) {
            codeSecrets = Dictionary(uniqueKeysWithValues: codeItems.compactMap { item in
                vault.secret(of: item.id)?.oneTimeCode.map { (item.id, $0) }
            })
        }
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(Array(vault.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, SettingsCenterView.dividerLeading) }
                VaultItemRow(item: item) { editing = Editing(item: item) }
            }
        }
        .padding(.horizontal, 12)
        // With no items the list keeps the height of one row.
        .frame(maxWidth: .infinity, minHeight: 54)
        .parityCard()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var encoding = String.Encoding.utf8
        let text = (try? String(contentsOf: url, usedEncoding: &encoding)) ?? ""
        let count = vault.importSignIns(VaultCSVImport.entries(text, suffixes: vault.suffixes))
        imported = Imported(title: L10n.format("Imported %lld sign-ins.", Int64(count)), count: count, files: [url])
    }

    /// Pictures of QR codes: an authenticator app's export (Google Authenticator's Transfer accounts, one
    /// or several codes) or a site's setup code. Each code becomes an item of its own.
    private func importQRCodes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let found = VaultQRCodeReader.setups(in: panel.urls.flatMap(VaultQRCodeReader.messages(in:)))
        let count = vault.importOneTimeCodes(found.setups)
        var title = found.setups.isEmpty && found.unsupported == 0
            ? L10n.string("No two-factor QR code is in the picture.")
            : L10n.format("Imported %lld two-factor codes.", Int64(count))
        if found.unsupported > 0 {
            title = L10n.format("Imported %lld two-factor codes. %lld counter-based codes were left out.",
                                Int64(count), Int64(found.unsupported))
        }
        imported = Imported(title: title, count: count, files: panel.urls)
    }

    private func empty() {
        do {
            failure = nil
            let sites = try vault.clear()
            guard !sites.isEmpty else { return }
            // The confirmation closes first; the list of sites is a second alert.
            Task { @MainActor in passkeySites = sites }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One saved sign-in: its name, its sites and kinds, how an agent may use it and when one last did.
private struct VaultItemRow: View {
    let item: VaultItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VaultSettingsIcon(systemName: "key.horizontal")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(item.policy.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)
                Text(lastUsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 72, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue([detail, item.policy.title, lastUsed].joined(separator: ", "))
    }

    private var detail: String {
        [item.sites.joined(separator: ", "), item.kindsTitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var lastUsed: String {
        item.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "—"
    }
}

private struct VaultSettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
    }
}
