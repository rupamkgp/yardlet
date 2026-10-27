import Foundation
import Security

/// Where Chromium keeps the key that encrypts the profile's cookies (docs/BROWSER_HOST.md §3).
///
/// Chromium stores a random password as "Chromium Safe Storage" in the login keychain. That item
/// trusts the code that made it, so it only suits a build whose signature stays the same across
/// updates: a Developer ID signature. Ad-hoc and development builds keep `use-mock-keychain`, a
/// fixed password, so a rebuild never asks for keychain access. The two keys differ: cookies saved
/// under one cannot be read under the other.
enum CookieKeychain {
    /// Gatekeeper's Developer ID requirement: an Apple-issued Developer ID intermediate and a
    /// Developer ID Application leaf certificate.
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// `YARDLET_BROWSER_KEYCHAIN=mock` keeps the mock keychain in a Developer ID build (QA copies,
    /// so they never make or read the installed app's keychain item).
    static func usesLoginKeychain(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["YARDLET_BROWSER_KEYCHAIN"] != "mock" else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The browser process's switches: `use-mock-keychain` first unless the login keychain is used.
    static func switches(_ switches: String, usesLoginKeychain: Bool) -> String {
        usesLoginKeychain ? switches : (["use-mock-keychain", switches].filter { !$0.isEmpty }.joined(separator: " "))
    }
}
