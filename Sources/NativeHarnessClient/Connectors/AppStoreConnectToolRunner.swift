import Foundation
import YardletAgentTools

/// Runs the App Store Connect tools (`AppStoreConnectToolCatalog`) for one key: each tool's request
/// to the App Store Connect API and its answer as compact JSON text. Apple's JSON:API resources are
/// flattened to their ID and attributes, with the related resources a tool asks Apple to include.
struct AppStoreConnectToolRunner: Sendable {
    let api: AppStoreConnectAPI

    /// The longest crash log a tool returns.
    static let crashLogLimit = 100_000

    typealias Catalog = AppStoreConnectToolCatalog
    private typealias Arguments = ConnectorToolArguments

    func call(_ tool: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let answer: ToolJSON
            switch tool {
            case Catalog.listApps: answer = try await listApps(arguments)
            case Catalog.listBuilds: answer = try await listBuilds(arguments)
            case Catalog.listBetaGroups: answer = try await listBetaGroups(arguments)
            case Catalog.listBetaTesters: answer = try await listBetaTesters(arguments)
            case Catalog.listBetaFeedback: answer = try await listBetaFeedback(arguments)
            case Catalog.getBetaCrashLog: answer = try await crashLog(arguments)
            case Catalog.listCustomerReviews: answer = try await listCustomerReviews(arguments)
            case Catalog.listAppStoreVersions: answer = try await listAppStoreVersions(arguments)
            case Catalog.listReviewSubmissions: answer = try await listReviewSubmissions(arguments)
            case Catalog.addBetaTester: answer = try await addBetaTester(arguments)
            case Catalog.removeBetaTester: answer = try await removeBetaTester(arguments)
            case Catalog.addBuildToGroup: answer = try await addBuildToGroup(arguments)
            case Catalog.replyToReview: answer = try await replyToReview(arguments)
            case Catalog.submitForReview: answer = try await submitForReview(arguments)
            default: return .error("Unknown tool: \(tool)")
            }
            return .text(Arguments.text(answer))
        } catch let problem as ConnectorToolArguments.Problem {
            return .error(problem.localizedDescription)
        }
    }

    // MARK: Reading

    private func listApps(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var query = page(arguments, fallback: 50)
        query.append(URLQueryItem(name: "fields[apps]", value: "name,bundleId,sku,primaryLocale"))
        if let bundle = Arguments.string(arguments, "bundleId") { query.append(URLQueryItem(name: "filter[bundleId]", value: bundle)) }
        if let name = Arguments.string(arguments, "name") { query.append(URLQueryItem(name: "filter[name]", value: name)) }
        let answer = try await api.get(["v1", "apps"], query)
        return listing("apps", answer) { app, _ in Self.flat(app) }
    }

    private func listBuilds(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try Arguments.required(arguments, "appId")
        var query = page(arguments, fallback: 20) + [
            URLQueryItem(name: "filter[app]", value: app),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "include", value: "preReleaseVersion,buildBetaDetail"),
            URLQueryItem(name: "fields[builds]",
                         value: "version,uploadedDate,expirationDate,expired,minOsVersion,processingState,preReleaseVersion,buildBetaDetail"),
            URLQueryItem(name: "fields[preReleaseVersions]", value: "version,platform"),
            URLQueryItem(name: "fields[buildBetaDetails]", value: "internalBuildState,externalBuildState")
        ]
        if let version = Arguments.string(arguments, "version") {
            query.append(URLQueryItem(name: "filter[preReleaseVersion.version]", value: version))
        }
        if let number = Arguments.string(arguments, "buildNumber") { query.append(URLQueryItem(name: "filter[version]", value: number)) }
        if let state = Arguments.string(arguments, "processingState") {
            query.append(URLQueryItem(name: "filter[processingState]", value: state))
        }
        let answer = try await api.get(["v1", "builds"], query)
        return listing("builds", answer) { build, included in
            var fields = Self.flat(build)
            // `version` is the build number; the marketing version is the pre-release version's.
            fields["buildNumber"] = fields.removeValue(forKey: "version")
            if let release = Self.related(build, "preReleaseVersion", in: included) {
                fields.merge(Arguments.pick(release["attributes"], ["version", "platform"])) { $1 }
            }
            if let beta = Self.related(build, "buildBetaDetail", in: included) {
                fields.merge(Arguments.pick(beta["attributes"], ["internalBuildState", "externalBuildState"])) { $1 }
            }
            return fields
        }
    }

    private func listBetaGroups(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try Arguments.required(arguments, "appId")
        let query = page(arguments, fallback: 50) + [
            URLQueryItem(name: "filter[app]", value: app),
            URLQueryItem(name: "fields[betaGroups]",
                         value: "name,createdDate,isInternalGroup,publicLinkEnabled,publicLink,publicLinkLimit,feedbackEnabled")
        ]
        let answer = try await api.get(["v1", "betaGroups"], query)
        return listing("groups", answer) { group, _ in Self.flat(group) }
    }

    private func listBetaTesters(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var query = page(arguments, fallback: 50)
        query.append(URLQueryItem(name: "fields[betaTesters]", value: "firstName,lastName,email,inviteType,state"))
        if let group = Arguments.string(arguments, "groupId") {
            query.append(URLQueryItem(name: "filter[betaGroups]", value: group))
        } else if let app = Arguments.string(arguments, "appId") {
            query.append(URLQueryItem(name: "filter[apps]", value: app))
        } else {
            throw ConnectorToolArguments.Problem.invalid("groupId or appId is required.")
        }
        if let email = Arguments.string(arguments, "email") { query.append(URLQueryItem(name: "filter[email]", value: email)) }
        let answer = try await api.get(["v1", "betaTesters"], query)
        return listing("testers", answer) { tester, _ in Self.flat(tester) }
    }

    private func listBetaFeedback(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "appId"))
        let kind = Arguments.string(arguments, "kind") ?? "both"
        guard ["screenshot", "crash", "both"].contains(kind) else {
            throw ConnectorToolArguments.Problem.invalid("kind is screenshot, crash, or both.")
        }
        var query = [
            URLQueryItem(name: "limit", value: String(Arguments.pageSize(arguments, "limit", range: 1...200, fallback: 20))),
            URLQueryItem(name: "sort", value: "-createdDate")
        ]
        if let build = Arguments.string(arguments, "buildId") { query.append(URLQueryItem(name: "filter[build]", value: build)) }
        var items: [ToolJSON] = []
        for (path, label) in [("betaFeedbackScreenshotSubmissions", "screenshot"), ("betaFeedbackCrashSubmissions", "crash")]
        where kind == "both" || kind == label {
            let answer = try await api.get(["v1", "apps", app, path], query)
            for item in answer["data"]?.arrayValue ?? [] {
                var fields = Self.flat(item)
                fields["kind"] = .string(label)
                if let build = Self.relatedID(item, "build") { fields["buildId"] = .string(build) }
                if let screenshots = fields["screenshots"]?.arrayValue {
                    fields["screenshots"] = .array(screenshots.map { .object(Arguments.pick($0, ["url", "width", "height"])) })
                }
                for key in ["appUptimeInMilliseconds", "diskBytesAvailable", "diskBytesTotal", "screenWidthInPoints",
                            "screenHeightInPoints", "pairedAppleWatch", "connectionType", "architecture"] {
                    fields.removeValue(forKey: key)
                }
                items.append(.object(fields))
            }
        }
        // Newest first across both kinds.
        items.sort { ($0["createdDate"]?.stringValue ?? "") > ($1["createdDate"]?.stringValue ?? "") }
        return .object(["feedback": .array(items)])
    }

    private func crashLog(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "feedbackId"))
        let answer = try await api.get(["v1", "betaFeedbackCrashSubmissions", id, "crashLog"])
        let text = answer["data"]?["attributes"]?["logText"]?.stringValue ?? ""
        var fields: [String: ToolJSON] = ["feedbackId": .string(id), "logText": .string(String(text.prefix(Self.crashLogLimit)))]
        if text.count > Self.crashLogLimit { fields["truncated"] = .bool(true) }
        return .object(fields)
    }

    private func listCustomerReviews(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "appId"))
        let sort: String = switch Arguments.string(arguments, "sort") ?? "newest" {
        case "oldest": "createdDate"
        case "highest": "-rating"
        case "lowest": "rating"
        case "newest": "-createdDate"
        default: throw ConnectorToolArguments.Problem.invalid("sort is newest, oldest, highest, or lowest.")
        }
        var query = page(arguments, fallback: 20) + [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "include", value: "response")
        ]
        if let rating = Arguments.integer(arguments["rating"]) { query.append(URLQueryItem(name: "filter[rating]", value: String(rating))) }
        if let territory = Arguments.string(arguments, "territory") {
            query.append(URLQueryItem(name: "filter[territory]", value: territory.uppercased()))
        }
        if let answered = Arguments.bool(arguments["hasResponse"]) {
            query.append(URLQueryItem(name: "exists[publishedResponse]", value: answered ? "true" : "false"))
        }
        let answer = try await api.get(["v1", "apps", app, "customerReviews"], query)
        return listing("reviews", answer) { review, included in
            var fields = Self.flat(review)
            if let response = Self.related(review, "response", in: included) { fields["response"] = .object(Self.flat(response)) }
            return fields
        }
    }

    private func listAppStoreVersions(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "appId"))
        var query = page(arguments, fallback: 10) + [
            URLQueryItem(name: "include", value: "build"),
            URLQueryItem(name: "fields[appStoreVersions]",
                         value: "platform,versionString,appVersionState,releaseType,earliestReleaseDate,createdDate,build"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate")
        ]
        if let platform = Arguments.string(arguments, "platform") { query.append(URLQueryItem(name: "filter[platform]", value: platform)) }
        let answer = try await api.get(["v1", "apps", app, "appStoreVersions"], query)
        return listing("versions", answer) { version, included in
            var fields = Self.flat(version)
            if let build = Self.related(version, "build", in: included) {
                var built = Self.flat(build)
                built["buildNumber"] = built.removeValue(forKey: "version")
                fields["build"] = .object(built)
            }
            return fields
        }
    }

    private func listReviewSubmissions(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let app = try Arguments.required(arguments, "appId")
        var query = [
            URLQueryItem(name: "filter[app]", value: app),
            URLQueryItem(name: "limit", value: String(Arguments.pageSize(arguments, "limit", range: 1...200, fallback: 10))),
            URLQueryItem(name: "include", value: "appStoreVersionForReview"),
            URLQueryItem(name: "fields[reviewSubmissions]", value: "platform,submittedDate,state,appStoreVersionForReview"),
            URLQueryItem(name: "fields[appStoreVersions]", value: "versionString,appVersionState")
        ]
        if let platform = Arguments.string(arguments, "platform") { query.append(URLQueryItem(name: "filter[platform]", value: platform)) }
        if let state = Arguments.string(arguments, "state") { query.append(URLQueryItem(name: "filter[state]", value: state)) }
        let answer = try await api.get(["v1", "reviewSubmissions"], query)
        return listing("submissions", answer) { submission, included in
            var fields = Self.flat(submission)
            if let version = Self.related(submission, "appStoreVersionForReview", in: included) {
                fields["version"] = .object(Self.flat(version))
            }
            return fields
        }
    }

    // MARK: Writing

    private func addBetaTester(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let group = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "groupId"))
        if let tester = Arguments.string(arguments, "testerId") {
            try await linkTesters([try AppStoreConnectAPI.segment(tester)], to: group, method: "POST")
            return .object(["added": .bool(true), "groupId": .string(group), "testerId": .string(tester)])
        }
        guard let email = Arguments.string(arguments, "email") else {
            throw ConnectorToolArguments.Problem.invalid("email or testerId is required.")
        }
        guard email.contains("@"), !email.contains(where: \.isWhitespace) else {
            throw ConnectorToolArguments.Problem.invalid("Not an email address: \(email)")
        }
        var attributes: [String: ToolJSON] = ["email": .string(email)]
        for key in ["firstName", "lastName"] { if let value = Arguments.string(arguments, key) { attributes[key] = .string(value) } }
        let answer = try await api.post(["v1", "betaTesters"], .object(["data": .object([
            "type": .string("betaTesters"),
            "attributes": .object(attributes),
            "relationships": .object(["betaGroups": .object(["data": .array([
                .object(["type": .string("betaGroups"), "id": .string(group)])
            ])])])
        ])]))
        return .object(["added": .bool(true), "groupId": .string(group),
                        "tester": answer["data"].map { .object(Self.flat($0)) } ?? .null])
    }

    private func removeBetaTester(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let group = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "groupId"))
        let tester = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "testerId"))
        try await linkTesters([tester], to: group, method: "DELETE")
        return .object(["removed": .bool(true), "groupId": .string(group), "testerId": .string(tester)])
    }

    private func linkTesters(_ testers: [String], to group: String, method: String) async throws {
        let body: ToolJSON = .object(["data": .array(testers.map { .object(["type": .string("betaTesters"), "id": .string($0)]) })])
        let path = ["v1", "betaGroups", group, "relationships", "betaTesters"]
        if method == "DELETE" { try await api.delete(path, body) } else { _ = try await api.post(path, body) }
    }

    private func addBuildToGroup(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let group = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "groupId"))
        let build = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "buildId"))
        _ = try await api.post(["v1", "betaGroups", group, "relationships", "builds"],
                               .object(["data": .array([.object(["type": .string("builds"), "id": .string(build)])])]))
        return .object(["added": .bool(true), "groupId": .string(group), "buildId": .string(build)])
    }

    private func replyToReview(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let review = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "reviewId"))
        let text = try Arguments.required(arguments, "responseBody")
        let answer = try await api.post(["v1", "customerReviewResponses"], .object(["data": .object([
            "type": .string("customerReviewResponses"),
            "attributes": .object(["responseBody": .string(text)]),
            "relationships": .object(["review": .object(["data": .object([
                "type": .string("customerReviews"), "id": .string(review)
            ])])])
        ])]))
        return .object(["reviewId": .string(review), "response": answer["data"].map { .object(Self.flat($0)) } ?? .null])
    }

    /// App Review takes a submission holding the version: the app's submission for that platform not
    /// sent yet (one started in App Store Connect), or a new one. Adding the version to it, then
    /// marking it submitted, sends it.
    private func submitForReview(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let versionID = try AppStoreConnectAPI.segment(try Arguments.required(arguments, "versionId"))
        let version = try await api.get(["v1", "appStoreVersions", versionID], [
            URLQueryItem(name: "fields[appStoreVersions]", value: "platform,versionString,app"),
            URLQueryItem(name: "include", value: "app")
        ])
        guard let data = version["data"], let platform = data["attributes"]?["platform"]?.stringValue,
              let app = Self.relatedID(data, "app") else { throw AppStoreConnectAPI.Failure.unreadableAnswer }
        let open = try await api.get(["v1", "reviewSubmissions"], [
            URLQueryItem(name: "filter[app]", value: app),
            URLQueryItem(name: "filter[platform]", value: platform),
            URLQueryItem(name: "filter[state]", value: "READY_FOR_REVIEW"),
            URLQueryItem(name: "limit", value: "1")
        ])
        let submission: String
        let reused: Bool
        if let existing = open["data"]?.arrayValue?.first?["id"]?.stringValue {
            submission = existing
            reused = true
        } else {
            let created = try await api.post(["v1", "reviewSubmissions"], .object(["data": .object([
                "type": .string("reviewSubmissions"),
                "attributes": .object(["platform": .string(platform)]),
                "relationships": .object(["app": .object(["data": .object(["type": .string("apps"), "id": .string(app)])])])
            ])]))
            guard let id = created["data"]?["id"]?.stringValue else { throw AppStoreConnectAPI.Failure.unreadableAnswer }
            submission = id
            reused = false
        }
        do {
            _ = try await api.post(["v1", "reviewSubmissionItems"], .object(["data": .object([
                "type": .string("reviewSubmissionItems"),
                "relationships": .object([
                    "reviewSubmission": .object(["data": .object(["type": .string("reviewSubmissions"), "id": .string(submission)])]),
                    "appStoreVersion": .object(["data": .object(["type": .string("appStoreVersions"), "id": .string(versionID)])])
                ])
            ])]))
        } catch let failure as AppStoreConnectAPI.Failure where reused && failure.status == 409 {
            // The submission started in App Store Connect holds this version already.
        }
        let sent = try await api.patch(["v1", "reviewSubmissions", submission], .object(["data": .object([
            "type": .string("reviewSubmissions"),
            "id": .string(submission),
            "attributes": .object(["submitted": .bool(true)])
        ])]))
        var fields: [String: ToolJSON] = ["versionId": .string(versionID), "platform": .string(platform)]
        fields.merge(Arguments.pick(data["attributes"], ["versionString"])) { $1 }
        fields["submission"] = sent["data"].map { .object(Self.flat($0)) } ?? .object(["id": .string(submission)])
        return .object(fields)
    }

    // MARK: JSON:API

    /// `limit` and `cursor`, as Apple's pages take them.
    private func page(_ arguments: [String: ToolJSON], fallback: Int) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "limit", value: String(Arguments.pageSize(arguments, "limit", range: 1...200, fallback: fallback)))]
        if let cursor = Arguments.string(arguments, "cursor") { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return query
    }

    /// The page's resources under `key`, and `nextCursor` from Apple's next link.
    private func listing(_ key: String, _ answer: ToolJSON,
                         _ item: (ToolJSON, [ToolJSON]) -> [String: ToolJSON]) -> ToolJSON {
        let included = answer["included"]?.arrayValue ?? []
        var fields: [String: ToolJSON] = [
            key: .array((answer["data"]?.arrayValue ?? []).map { .object(item($0, included)) })
        ]
        if let next = answer["links"]?["next"]?.stringValue,
           let cursor = URLComponents(string: next)?.queryItems?.first(where: { $0.name == "cursor" })?.value {
            fields["nextCursor"] = .string(cursor)
        }
        if let total = answer["meta"]?["paging"]?["total"] { fields["total"] = total }
        return .object(fields)
    }

    /// A resource as its ID and attributes.
    static func flat(_ resource: ToolJSON) -> [String: ToolJSON] {
        var fields = Arguments.pick(resource, ["id"])
        for (key, value) in resource["attributes"]?.objectValue ?? [:] where value != .null { fields[key] = value }
        return fields
    }

    static func relatedID(_ resource: ToolJSON, _ relationship: String) -> String? {
        resource["relationships"]?[relationship]?["data"]?["id"]?.stringValue
    }

    static func related(_ resource: ToolJSON, _ relationship: String, in included: [ToolJSON]) -> ToolJSON? {
        guard let linkage = resource["relationships"]?[relationship]?["data"], let id = linkage["id"]?.stringValue else { return nil }
        let type = linkage["type"]?.stringValue
        return included.first { $0["id"]?.stringValue == id && $0["type"]?.stringValue == type }
    }
}
