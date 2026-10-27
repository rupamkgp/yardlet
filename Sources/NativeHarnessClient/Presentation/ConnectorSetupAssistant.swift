import Foundation

/// The "Set up in one go" assistant for the services that need an app of the person's own
/// (Settings → Connectors): Google, whose one OAuth app serves Gmail, Calendar, and Drive, and
/// Slack, whose app Yardlet's manifest creates. Each step opens the exact console page and offers
/// a copy button for every value the person pastes; a step shows a check once it is done.
///
/// Yardlet cannot see a console, so a console step counts as done once its page was opened or
/// ticked by hand, and every console step counts as done once the app's client is saved; the last
/// step is done when an account is connected.
struct ConnectorSetupAssistant: Equatable {
    enum Service: String, Equatable, Sendable {
        case google
        case slack
    }

    enum StepID: String, CaseIterable, Sendable {
        // Google
        case project, apis, consent, publish, scopes, client, googleSignIn
        // Slack
        case slackCreate, slackCredentials, slackSignIn
    }

    struct Link: Equatable {
        let title: String
        let url: URL
    }

    /// A value the person pastes into a console, with what to call its copy button.
    struct Copy: Equatable {
        let label: String
        let value: String
    }

    struct Step: Equatable, Identifiable {
        let id: StepID
        let title: String
        let detail: String?
        var link: Link?
        var copies: [Copy] = []
        var isDone: Bool
    }

    let service: Service
    let steps: [Step]

    /// The first step not done, where the assistant's attention goes.
    var current: StepID? { steps.first { !$0.isDone }?.id }
    var doneCount: Int { steps.filter(\.isDone).count }
    var isComplete: Bool { current == nil }

    // MARK: Google

    static let googleProject = URL(string: "https://console.cloud.google.com/projectcreate")!
    /// Turns on all three APIs in one confirmation.
    static var googleAPIs: URL {
        URL(string: "https://console.cloud.google.com/flows/enableapi?apiid="
            + LocalConnectorService.allCases.map(\.apiID).joined(separator: ","))!
    }
    static let googleOverview = URL(string: "https://console.cloud.google.com/auth/overview")!
    static let googleAudience = URL(string: "https://console.cloud.google.com/auth/audience")!
    static let googleDataAccess = URL(string: "https://console.cloud.google.com/auth/scopes")!
    static let googleClients = URL(string: "https://console.cloud.google.com/auth/clients")!

    /// The app name the person types in Google's and Slack's consoles.
    static let appName = "Yardlet"

    /// Every Google scope, one per line, as Data Access → "Manually add scopes" takes them.
    static var googleScopeList: String {
        GoogleOAuth.scopes.map(\.url).joined(separator: "\n")
    }

    /// - Parameter builtIn: the build carries Yardlet's own Google app and the person is not setting
    ///   up one of theirs, so signing in is the only step.
    static func google(opened: Set<StepID>, appSaved: Bool, connectedAccounts: Int,
                       builtIn: Bool = false) -> ConnectorSetupAssistant {
        func done(_ id: StepID) -> Bool { appSaved || opened.contains(id) }
        let signIn = Step(id: .googleSignIn, title: L10n.string("Sign in with each Google account"),
                          detail: L10n.string("Pick Gmail, Calendar, and Drive for the account, then sign in once."),
                          isDone: connectedAccounts > 0)
        if builtIn { return ConnectorSetupAssistant(service: .google, steps: [signIn]) }
        let redirect = ConnectorOAuth.registeredClientRedirectURI.absoluteString
        return ConnectorSetupAssistant(service: .google, steps: [
            Step(id: .project, title: L10n.string("Create a Google Cloud project"),
                 detail: L10n.string("Any name. Or pick a project you have."),
                 link: Link(title: L10n.string("New project"), url: googleProject), isDone: done(.project)),
            Step(id: .apis, title: L10n.string("Turn on the Gmail, Calendar, and Drive APIs"),
                 detail: L10n.string("One page turns on all three; confirm the project and press Enable."),
                 link: Link(title: L10n.string("Enable APIs"), url: googleAPIs), isDone: done(.apis)),
            Step(id: .consent, title: L10n.string("Set up Google Auth Platform"),
                 detail: L10n.string("App name, your email, then Audience: External for personal Gmail and other accounts, Internal for your Workspace organization's accounts only."),
                 link: Link(title: L10n.string("Google Auth Platform"), url: googleOverview),
                 copies: [Copy(label: L10n.string("App name"), value: appName)], isDone: done(.consent)),
            Step(id: .publish, title: L10n.string("Publish the app (External only)"),
                 detail: L10n.string("Audience → Publish app, so its status is In production. In Testing, Google ends each sign-in after 7 days. No verification is needed for your own use."),
                 link: Link(title: L10n.string("Audience"), url: googleAudience), isDone: done(.publish)),
            Step(id: .scopes, title: L10n.string("Add the scopes"),
                 detail: L10n.string("Data Access → Add or remove scopes → Manually add scopes: paste the six, then Update and Save."),
                 link: Link(title: L10n.string("Data Access"), url: googleDataAccess),
                 copies: [Copy(label: L10n.string("Scopes"), value: googleScopeList)], isDone: done(.scopes)),
            Step(id: .client, title: L10n.string("Create a client and paste it here"),
                 detail: L10n.string("Application type Desktop app, name Yardlet, then Create. Paste its client ID and secret below. A Web application client works too with the redirect URL added."),
                 link: Link(title: L10n.string("Create client"), url: googleClients),
                 copies: [Copy(label: L10n.string("App name"), value: appName),
                          Copy(label: L10n.string("Redirect URL"), value: redirect)],
                 isDone: appSaved),
            signIn
        ])
    }

    // MARK: Slack

    static func slack(opened: Set<StepID>, clientEntered: Bool, connected: Bool) -> ConnectorSetupAssistant {
        ConnectorSetupAssistant(service: .slack, steps: [
            Step(id: .slackCreate, title: L10n.string("Create the Yardlet app in Slack"),
                 detail: L10n.string("Opens Slack with Yardlet's manifest filled in: pick your workspace, press Next, then Create. It has the redirect URL, the 30 user scopes Slack's MCP server uses, MCP on, and PKCE."),
                 link: Link(title: L10n.string("Create in Slack"), url: SlackAppManifest.createURL),
                 copies: [Copy(label: L10n.string("Manifest"), value: SlackAppManifest.prettyJSON),
                          Copy(label: L10n.string("Redirect URL"), value: SlackAppManifest.redirectURL)],
                 isDone: opened.contains(.slackCreate) || clientEntered || connected),
            Step(id: .slackCredentials, title: L10n.string("Paste the client ID"),
                 detail: L10n.string("In the new app, Basic Information → App Credentials → Client ID. A PKCE app needs no secret."),
                 link: Link(title: L10n.string("Your Slack apps"), url: SlackAppManifest.appsURL),
                 isDone: clientEntered || connected),
            Step(id: .slackSignIn, title: L10n.string("Sign in to Slack"),
                 detail: L10n.string("Slack asks to allow Yardlet in your workspace. If your workspace needs an admin's approval, ask for it there."),
                 isDone: connected)
        ])
    }

    // MARK: Fields

    enum Validation: Equatable {
        case empty
        case valid
        case invalid(String)

        var isValid: Bool { self == .valid }
        var message: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Google OAuth client ID: `<number>-<letters and digits>.apps.googleusercontent.com`.
    static func validateGoogleClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        if value.hasPrefix("GOCSPX-") { return .invalid(L10n.string("That is the client secret; the client ID ends with .apps.googleusercontent.com.")) }
        let suffix = ".apps.googleusercontent.com"
        guard value.hasSuffix(suffix), value.count > suffix.count,
              value.dropLast(suffix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return .invalid(L10n.string("A Google client ID ends with .apps.googleusercontent.com."))
        }
        return .valid
    }

    /// A Google client secret: not empty, no spaces, and not the client ID pasted twice.
    static func validateGoogleSecret(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        if value.hasSuffix(".apps.googleusercontent.com") {
            return .invalid(L10n.string("That is the client ID; the secret is the other value, often starting with GOCSPX-."))
        }
        guard !value.contains(where: \.isWhitespace), value.count >= 16 else {
            return .invalid(L10n.string("The client secret looks cut off."))
        }
        return .valid
    }

    /// A Slack client ID: two runs of digits with a dot between, `123456789012.1234567890123`.
    static func validateSlackClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return .invalid(L10n.string("A Slack client ID is two numbers with a dot between, like 123.456."))
        }
        return .valid
    }

    /// A Slack client secret, only for an app without PKCE: 32 hexadecimal digits.
    static func validateSlackSecret(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        guard value.count == 32, value.allSatisfy(\.isHexDigit) else {
            return .invalid(L10n.string("A Slack client secret is 32 letters and digits (0–9, a–f)."))
        }
        return .valid
    }
}
