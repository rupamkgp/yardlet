import Foundation
import YardletAgentTools

/// Yardlet's own App Store Connect server: Apple's App Store Connect API with the person's own API
/// key, so no other party's server holds the key. Each tool reaches a harness under the key's slug
/// (`app_store_connect_list_builds`).
///
/// Reading comes first: apps, builds and their processing, TestFlight groups, testers, and beta
/// feedback, customer reviews, and App Store versions with their review. Writing is only what a
/// release needs: inviting and removing a tester, giving a build to a group, answering a review,
/// and submitting a version for App Review. Each write asks the person before every call through
/// the harness's own approval (`approvalRequired`).
enum AppStoreConnectToolCatalog {
    static let listApps = "list_apps"
    static let listBuilds = "list_builds"
    static let listBetaGroups = "list_beta_groups"
    static let listBetaTesters = "list_beta_testers"
    static let listBetaFeedback = "list_beta_feedback"
    static let getBetaCrashLog = "get_beta_crash_log"
    static let listCustomerReviews = "list_customer_reviews"
    static let listAppStoreVersions = "list_app_store_versions"
    static let listReviewSubmissions = "list_review_submissions"
    static let addBetaTester = "add_beta_tester"
    static let removeBetaTester = "remove_beta_tester"
    static let addBuildToGroup = "add_build_to_group"
    static let replyToReview = "reply_to_review"
    static let submitForReview = "submit_for_review"

    static let approvalRequired: Set<String> = [addBetaTester, removeBetaTester, addBuildToGroup, replyToReview, submitForReview]

    static let platforms = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]

    static let tools: [ToolJSON] = [
        tool(listApps, "List apps",
             "Lists the apps the key can see, with each one's ID, name, bundle ID, SKU, and primary language.",
             properties: [
                "bundleId": string("Only the app with this bundle ID."),
                "name": string("Only apps with exactly this name."),
                "limit": limit(default: 50),
                "cursor": cursor
             ], readOnly: true),
        tool(listBuilds, "List builds",
             "Lists an app's builds, newest upload first, with the version and build number, processing state, "
                + "expiry, and TestFlight state.",
             properties: [
                "appId": appID,
                "version": string("The marketing version (1.2.0)."),
                "buildNumber": string("The build number (CFBundleVersion)."),
                "processingState": GoogleToolSchema.enumeration("PROCESSING, FAILED, INVALID, or VALID.",
                                                                 ["PROCESSING", "FAILED", "INVALID", "VALID"]),
                "limit": limit(default: 20),
                "cursor": cursor
             ], required: ["appId"], readOnly: true),
        tool(listBetaGroups, "List beta groups",
             "Lists an app's TestFlight groups, internal and external, with each one's public link.",
             properties: ["appId": appID, "limit": limit(default: 50), "cursor": cursor],
             required: ["appId"], readOnly: true),
        tool(listBetaTesters, "List beta testers",
             "Lists TestFlight testers of a group or of an app, with each one's name, email, how they were invited, and state.",
             properties: [
                "groupId": string("A beta group's ID, from list_beta_groups."),
                "appId": string("An app's ID, for all its testers, when no groupId is given."),
                "email": string("Only the tester with this email."),
                "limit": limit(default: 50),
                "cursor": cursor
             ], readOnly: true),
        tool(listBetaFeedback, "List beta feedback",
             "Lists what TestFlight testers sent from the app, newest first: screenshots with comments, and crashes "
                + "with comments, with the device and build. get_beta_crash_log reads a crash's log.",
             properties: [
                "appId": appID,
                "kind": GoogleToolSchema.enumeration("screenshot, crash, or both (default).", ["screenshot", "crash", "both"]),
                "buildId": string("Only feedback on this build, from list_builds."),
                "limit": limit(default: 20)
             ], required: ["appId"], readOnly: true),
        tool(getBetaCrashLog, "Get beta crash log",
             "Reads the crash log of a crash a TestFlight tester sent, by its ID from list_beta_feedback.",
             properties: ["feedbackId": string("The crash feedback's ID.")],
             required: ["feedbackId"], readOnly: true),
        tool(listCustomerReviews, "List customer reviews",
             "Lists an app's App Store reviews, newest first, with rating, title, text, country, and any response.",
             properties: [
                "appId": appID,
                "rating": GoogleToolSchema.integer("Only reviews with this many stars.", 1...5),
                "territory": string("Only reviews from this country, as a three-letter code (KOR, USA)."),
                "hasResponse": GoogleToolSchema.boolean("true for reviews answered, false for those not."),
                "sort": GoogleToolSchema.enumeration("newest (default), oldest, highest, or lowest.",
                                                     ["newest", "oldest", "highest", "lowest"]),
                "limit": limit(default: 20),
                "cursor": cursor
             ], required: ["appId"], readOnly: true),
        tool(listAppStoreVersions, "List App Store versions",
             "Lists an app's App Store versions, newest first, with the state of each (in review, rejected, ready for "
                + "distribution…), its release type, and its build.",
             properties: [
                "appId": appID,
                "platform": platform,
                "limit": limit(default: 10),
                "cursor": cursor
             ], required: ["appId"], readOnly: true),
        tool(listReviewSubmissions, "List review submissions",
             "Lists an app's App Review submissions with their state (ready, waiting, in review, unresolved issues, "
                + "complete) and the version each holds.",
             properties: [
                "appId": appID,
                "platform": platform,
                "state": GoogleToolSchema.enumeration("Only submissions in this state.",
                                                      ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW",
                                                       "UNRESOLVED_ISSUES", "CANCELING", "COMPLETING", "COMPLETE"]),
                "limit": limit(default: 10)
             ], required: ["appId"], readOnly: true),
        tool(addBetaTester, "Add beta tester",
             "Adds a tester to a TestFlight group: a new tester by email, whom Apple emails an invitation, or one the "
                + "team has by testerId.",
             properties: [
                "groupId": string("The beta group's ID."),
                "email": string("A new tester's email."),
                "firstName": string("A new tester's first name."),
                "lastName": string("A new tester's last name."),
                "testerId": string("A tester the team has, from list_beta_testers, instead of email.")
             ], required: ["groupId"], readOnly: false, openWorld: true),
        tool(removeBetaTester, "Remove beta tester",
             "Removes a tester from a TestFlight group; they lose the group's builds.",
             properties: ["groupId": string("The beta group's ID."), "testerId": string("The tester's ID.")],
             required: ["groupId", "testerId"], readOnly: false, destructive: true, openWorld: true),
        tool(addBuildToGroup, "Add build to group",
             "Gives a build to a TestFlight group, whose testers can then install it; an external group gets it once "
                + "Beta App Review approves the build.",
             properties: ["groupId": string("The beta group's ID."), "buildId": string("The build's ID, from list_builds.")],
             required: ["groupId", "buildId"], readOnly: false, openWorld: true),
        tool(replyToReview, "Reply to review",
             "Publishes the developer response to a customer review, replacing one written before. Apple shows it on "
                + "the App Store.",
             properties: ["reviewId": string("The review's ID, from list_customer_reviews."),
                          "responseBody": string("The response's text.")],
             required: ["reviewId", "responseBody"], readOnly: false, openWorld: true),
        tool(submitForReview, "Submit for review",
             "Submits an App Store version for App Review, in the app's review submission that is not sent yet or a new one.",
             properties: ["versionId": string("The App Store version's ID, from list_app_store_versions.")],
             required: ["versionId"], readOnly: false, openWorld: true)
    ]

    // MARK: Schema pieces

    private static var appID: ToolJSON { string("The app's ID, from list_apps.") }

    private static var platform: ToolJSON {
        GoogleToolSchema.enumeration("IOS, MAC_OS, TV_OS, or VISION_OS.", platforms)
    }

    private static var cursor: ToolJSON { string("nextCursor from the previous page.") }

    private static func limit(default value: Int) -> ToolJSON {
        GoogleToolSchema.integer("Items per page, 1 to 200. Defaults to \(value).", 1...200)
    }

    private static func string(_ description: String) -> ToolJSON { GoogleToolSchema.string(description) }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: ToolJSON], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        GoogleToolSchema.tool(name, title, description, properties: properties, required: required,
                              readOnly: readOnly, destructive: destructive, openWorld: openWorld)
    }
}
