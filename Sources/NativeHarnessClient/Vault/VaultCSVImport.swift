import Foundation

/// Sign-ins exported from a browser or password manager as CSV (design §8.1): Chrome's and
/// 1Password's `name`/`title`, `url`, `username`, `password` columns and Bitwarden's `name`,
/// `login_uri`, `login_username`, `login_password`, in any order and among other columns, with the
/// two-factor code where the export has one (1Password's and Apple Passwords' `OTPAuth`, Bitwarden's
/// `login_totp`; design §14).
enum VaultCSVImport {
    struct Entry: Equatable, Sendable {
        var name: String
        var sites: [String]
        var username: String
        var password: String
        var oneTimeCode: OneTimeCodeSecret? = nil
    }

    private static let nameColumns = ["name", "title"]
    private static let addressColumns = ["url", "login_uri"]
    private static let usernameColumns = ["username", "login_username"]
    private static let passwordColumns = ["password", "login_password"]
    private static let codeColumns = ["otpauth", "login_totp", "totp"]

    /// The sign-ins in an export, in file order. A row is left out without a site Yardlet can fill
    /// on (`VaultSite.suggestion(for:)`) or without a password or two-factor code.
    static func entries(_ text: String, suffixes: PublicSuffixList = .bundled) -> [Entry] {
        let rows = records(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ names: [String]) -> Int? {
            names.lazy.compactMap { columns.firstIndex(of: $0) }.first
        }
        guard let address = column(addressColumns), let password = column(passwordColumns) else { return [] }
        let name = column(nameColumns), username = column(usernameColumns), code = column(codeColumns)
        return rows.dropFirst().compactMap { row in
            func value(_ index: Int?) -> String {
                guard let index, row.indices.contains(index) else { return "" }
                return row[index]
            }
            let secret = value(password)
            let oneTimeCode = OneTimeCodeSecret(setupText: value(code))
            guard !secret.isEmpty || oneTimeCode != nil else { return nil }
            let sites = Self.sites(in: value(address), suffixes: suffixes)
            guard let first = sites.first else { return nil }
            let title = value(name).trimmingCharacters(in: .whitespacesAndNewlines)
            return Entry(name: title.isEmpty ? first : title, sites: sites,
                         username: value(username).trimmingCharacters(in: .whitespacesAndNewlines), password: secret,
                         oneTimeCode: oneTimeCode)
        }
    }

    /// The sites of one row's address field. Bitwarden puts several addresses in one field; an
    /// address without a scheme is read as https.
    private static func sites(in field: String, suffixes: PublicSuffixList) -> [String] {
        var sites: [String] = []
        for part in field.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let address = part.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { continue }
            let site = VaultSite.suggestion(for: address, suffixes: suffixes)
                ?? (address.contains("://") ? nil : VaultSite.suggestion(for: "https://" + address, suffixes: suffixes))
            if let site, !sites.contains(site) { sites.append(site) }
        }
        return sites
    }

    /// RFC 4180 records: fields split at commas, a quoted field may hold commas, line breaks and
    /// doubled quotes, and lines end in CRLF, LF or CR. Blank lines are left out.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var fieldWasQuoted = false
        let characters = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var index = 0
        func endRecord() {
            record.append(field)
            if !(record.count == 1 && record[0].isEmpty && !fieldWasQuoted) { records.append(record) }
            record = []
            field = ""
            fieldWasQuoted = false
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            if quoted {
                if character == "\"" {
                    if index < characters.count, characters[index] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty && !fieldWasQuoted:
                quoted = true
                fieldWasQuoted = true
            case ",":
                record.append(field)
                field = ""
                fieldWasQuoted = false
            case "\r\n", "\n", "\r":
                endRecord()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !record.isEmpty || fieldWasQuoted { endRecord() }
        return records
    }
}

extension VaultCenter {
    /// Saves imported sign-ins and says how many were saved. One already in the vault for the same
    /// site and username takes the new password and keeps the rest; any other becomes a new item
    /// the agent may use at any time, as an item made by hand is. A name already taken gets the
    /// username after it, so an agent can name either. Codes with no site whose account's sign-in came
    /// in take its site (`linkCodesToTheirSignIns`).
    @discardableResult
    func importSignIns(_ entries: [VaultCSVImport.Entry]) -> Int {
        var saved = 0
        for entry in entries {
            if let existing = items.first(where: { item in
                item.username == entry.username && item.sites.contains { entry.sites.contains($0) }
            }) {
                let hasSecrets = existing.hasPassword || existing.hasOneTimeCode || existing.hasPasskey
                // A secret the keychain would not give back is kept rather than overwritten.
                guard var secret = hasSecrets ? secret(of: existing.id) : VaultSecret() else { continue }
                if !entry.password.isEmpty { secret.password = entry.password }
                if let code = entry.oneTimeCode { secret.oneTimeCode = code }
                guard (try? save(existing, secret: secret)) != nil else { continue }
            } else {
                var name = entry.name
                if !entry.username.isEmpty,
                   items.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                    name += " (\(entry.username))"
                }
                let item = VaultItem(name: name, sites: entry.sites, username: entry.username, policy: .always)
                let secret = VaultSecret(password: entry.password.isEmpty ? nil : entry.password, oneTimeCode: entry.oneTimeCode)
                guard (try? save(item, secret: secret)) != nil else { continue }
            }
            saved += 1
        }
        if saved > 0 { linkCodesToTheirSignIns() }
        return saved
    }
}
