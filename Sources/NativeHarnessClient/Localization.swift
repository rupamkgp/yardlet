import Foundation

enum L10n {
    /// Any packaged app owns these resources, including separately identified QA builds.
    /// SwiftPM tests and previews keep using Bundle.module when they have no app resources.
    /// Decided once: every string a view shows asks for it, and looking the resource up searched
    /// the bundle each time (measured in scroll hitches while new rows came into view).
    private static let activeBundle: Bundle = {
        if Bundle.main.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"
        ) != nil {
            return .main
        }
        return .module
    }()

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: activeBundle)
    }

    static func string(_ key: String) -> String {
        activeBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, languageCode: String) -> String {
        guard let path = activeBundle.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
