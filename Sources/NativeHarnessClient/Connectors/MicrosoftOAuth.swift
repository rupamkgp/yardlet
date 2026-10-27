import Foundation

/// Microsoft's sign-in for the services Yardlet serves itself on Microsoft Graph: Outlook mail and
/// calendar, OneDrive, and Teams, each Microsoft account signed in once with the permissions of the
/// services turned on for it (docs/CONNECTORS.md, "Microsoft 365").
///
/// The app is a public client of the Microsoft identity platform (a "Mobile and desktop
/// applications" registration in Microsoft Entra): authorization code with PKCE, no secret, the
/// loopback redirect. A build may carry Yardlet's own registration (`BuiltInApp`, from the bundle's
/// Info.plist), so a person only signs in. The person may instead register an app of their own,
/// for an organization that admits only apps it registered: its client ID and directory (tenant)
/// are kept in `connectors.json`, since a public client has no secret, and take precedence. Each
/// account's item carries the client and token endpoint it signed in with, so a refresh keeps
/// working whichever app later signs in new accounts.
enum MicrosoftOAuth {
    /// The app registration a build carries, from `YardletMicrosoftOAuthClientID` in Info.plist
    /// (scripts/build-app.sh writes it from Packaging/MicrosoftOAuthClient.json, which stays out of
    /// git). A public client's ID is not a secret; PKCE protects each sign-in.
    struct BuiltInApp: Equatable, Sendable {
        let clientID: String

        static let clientIDKey = "YardletMicrosoftOAuthClientID"

        /// The app in a bundle's info dictionary; nil when the build carries none.
        static func from(info: [String: Any]?) -> BuiltInApp? {
            let id = (info?[clientIDKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id, !id.isEmpty else { return nil }
            return BuiltInApp(clientID: id)
        }
    }

    /// An app the person registered in their own Microsoft Entra directory.
    struct App: Codable, Equatable, Sendable {
        /// The application (client) ID.
        var clientID: String
        /// The directory (tenant) ID or domain for an app that admits only its own organization's
        /// accounts; `common` admits work, school, and personal accounts.
        var tenant: String

        init(clientID: String, tenant: String?) {
            self.clientID = clientID
            let tenant = tenant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.tenant = tenant.isEmpty ? MicrosoftOAuth.commonTenant : tenant
        }
    }

    static let commonTenant = "common"

    /// The identity platform's and Graph's addresses. Tests point them at a stand-in server.
    struct Endpoints: Equatable, Sendable {
        /// `https://login.microsoftonline.com`, before the tenant.
        var login: URL
        /// Microsoft Graph v1.0, `…/v1.0/`.
        var graph: URL

        /// learn.microsoft.com/entra/identity-platform/v2-oauth2-auth-code-flow and
        /// learn.microsoft.com/graph/api/overview.
        static let live = Endpoints(
            login: URL(string: "https://login.microsoftonline.com/")!,
            graph: URL(string: "https://graph.microsoft.com/v1.0/")!
        )

        func authorization(tenant: String) -> URL {
            login.appending(path: "\(tenant)/oauth2/v2.0/authorize")
        }

        func token(tenant: String) -> URL {
            login.appending(path: "\(tenant)/oauth2/v2.0/token")
        }

        /// The address a service's connector shows and is told apart by: the Graph collection it
        /// works in. Its requests go to `graph`.
        func address(for service: LocalConnectorService) -> URL {
            switch service {
            case .outlookMail: graph.appending(path: "me/messages")
            case .outlookCalendar: graph.appending(path: "me/calendars")
            case .oneDrive: graph.appending(path: "me/drive")
            case .teams: graph.appending(path: "me/chats")
            default: service.address
            }
        }
    }

    /// What every sign-in asks for besides the services' permissions: a refresh token, and the
    /// signed-in user's own profile, which names the account.
    static let baseScopes = ["offline_access", "User.Read"]

    /// The permissions for a set of services, in the directory's order, space-separated.
    static func scope(for services: some Sequence<LocalConnectorService>) -> String {
        let wanted = Set(services)
        let permissions = LocalConnectorService.microsoft.filter(wanted.contains).flatMap(\.scopes)
        var seen = Set<String>()
        return (baseScopes + permissions).filter { seen.insert($0.lowercased()).inserted }.joined(separator: " ")
    }

    /// The services whose every permission a granted scope string holds. The identity platform
    /// lists Graph permissions with or without Graph's address before them, in any case; without
    /// a list, every asked-for service counts as granted.
    static func grantedServices(_ granted: String?, of services: some Sequence<LocalConnectorService>)
        -> Set<LocalConnectorService> {
        guard let granted else { return Set(services) }
        let have = Set(granted.split(separator: " ").map { permission($0) })
        return Set(services.filter { service in service.scopes.allSatisfy { have.contains(permission($0)) } })
    }

    private static func permission(_ text: some StringProtocol) -> String {
        var name = text.lowercased()
        if name.hasPrefix("https://graph.microsoft.com/") { name.removeFirst("https://graph.microsoft.com/".count) }
        return name
    }

    /// The authorization server for a tenant as Microsoft documents it: no discovery request, no
    /// dynamic registration, a public client.
    static func authorizationServer(_ endpoints: Endpoints, tenant: String) -> OAuthAuthorizationServer {
        OAuthAuthorizationServer(
            issuer: endpoints.login.appending(path: "\(tenant)/v2.0").absoluteString,
            authorizationEndpoint: endpoints.authorization(tenant: tenant),
            tokenEndpoint: endpoints.token(tenant: tenant),
            registrationEndpoint: nil,
            tokenEndpointAuthMethods: ["none"]
        )
    }

    /// A Graph sign-in names no resource: the permissions carry it.
    static func plan(scope: String, endpoints: Endpoints, tenant: String) -> OAuthPlan {
        OAuthPlan(server: authorizationServer(endpoints, tenant: tenant), resource: nil, scope: scope)
    }

    /// A new account gets the account chooser, so a second account is not the browser's current
    /// one by default; signing in again names the account it was.
    static func authorizationParameters(account: String?) -> [String: String] {
        if let account, !account.isEmpty { return ["login_hint": account] }
        return ["prompt": "select_account"]
    }
}

enum MicrosoftSignInError: Error, Equatable, LocalizedError {
    /// The build carries no app and the person saved none.
    case noApp
    /// Microsoft issued a token without a service's permissions, by the service's name.
    case scopeNotGranted(String)
    /// Microsoft issued no refresh token, so the sign-in would not outlast the hour.
    case noRefreshToken

    static func scopeNotGranted(_ services: [LocalConnectorService]) -> MicrosoftSignInError {
        .scopeNotGranted(services.map(\.name).formatted(.list(type: .and)))
    }

    var errorDescription: String? {
        switch self {
        case .noApp:
            L10n.string("Save your Microsoft app first: Settings → Connectors → Set up Microsoft 365.")
        case .scopeNotGranted(let services):
            L10n.format("Microsoft did not grant access to %@. Connect again and allow it.", services)
        case .noRefreshToken:
            L10n.string("Microsoft did not issue a lasting sign-in. Connect again.")
        }
    }
}
