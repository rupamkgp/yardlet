import Foundation
import Security

/// What Yardlet asks its lid helper over XPC. The connection itself is the other half: the helper
/// lets the Mac sleep again as soon as it ends.
@objc public protocol LidSleepHelperProtocol {
    /// Yardlet's tasks are working (true) or not (false). The reply says whether the Mac now stays
    /// awake with the lid closed: false on a battery under 20%, at a critical heat, or when macOS
    /// refused the setting.
    func setKeepsAwake(_ keepsAwake: Bool, reply: @escaping @Sendable (Bool) -> Void)
}

/// Where the helper lives in a Yardlet bundle and what each side checks of the other.
public enum LidSleepHelperIdentity {
    /// The launchd label and Mach service, from the app's bundle identifier, so a QA copy under
    /// another identifier finds no helper of its own instead of the installed app's.
    public static func label(appIdentifier: String) -> String { "\(appIdentifier).lid-helper" }

    /// `Contents/Library/LaunchDaemons/<this>` in the app bundle (`SMAppService.daemon(plistName:)`).
    public static func plistName(appIdentifier: String) -> String { "\(label(appIdentifier: appIdentifier)).plist" }

    /// A code requirement for the other end of the connection: its signing identifier and a
    /// certificate Apple issued to the team that signed this process. Nil when no team signed it (a
    /// local build signed ad hoc, which shares the installed app's identifier and settings): such a
    /// copy has no helper, so it never registers a second one under the same label.
    public static func peerRequirement(identifier: String) -> String? {
        ownTeamIdentifier().map {
            "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\""
        }
    }

    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
