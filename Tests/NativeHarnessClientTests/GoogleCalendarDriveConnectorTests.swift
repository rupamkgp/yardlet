import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own Google Calendar and Drive servers on the Google OAuth app Gmail uses
/// (docs/CONNECTORS.md, "Google"): one sign-in per Google account carrying the scopes of the services
/// turned on for it, incremental consent when one more is turned on, a scope left unchecked, each
/// tool's Calendar or Drive API request and answer, the harness asking before writes and not
/// before reads, and two accounts side by side. Google is a local fake (`FakeGoogleWorkspace`): no
/// request leaves the machine and no real account signs in.
@MainActor
final class GoogleCalendarDriveConnectorTests: XCTestCase {
    nonisolated private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func makeCenter(
        google: FakeGoogleWorkspace = FakeGoogleWorkspace(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.google = FakeGoogleWorkspace.endpoints
        environment.timeZone = { Self.seoul }
        return ConnectorCenter(environment: environment)
    }

    /// A center with the Google app saved and one account signed in with `services`.
    private func signedIn(
        _ address: String = "person@example.test",
        services: Set<LocalConnectorService> = Set(LocalConnectorService.allCases),
        google: FakeGoogleWorkspace = FakeGoogleWorkspace(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()
    ) async throws -> (ConnectorCenter, ConnectorCenter.GoogleAccount) {
        let center = makeCenter(google: google, agent: agent, credentials: credentials)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        google.google.signInAs = address
        let account = try XCTUnwrap(center.addGoogleAccount(services: services))
        await center.waitForConnection(account.id)
        let settled = try XCTUnwrap(center.googleAccounts.first { $0.id == account.id })
        return (center, settled)
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON] = [:],
                      task: UUID? = nil) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callConnectorTool(named: name, arguments: .object(arguments),
                                                          for: ConnectorToolContext(taskID: task)))
    }

    private func json(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> ToolJSON {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
    }

    private func query(_ url: URL?) -> [String: String] {
        Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - One sign-in for three services

    /// The account chooser asks once for every chosen service's scopes, offline and incremental;
    /// the account's services share one sign-in, each a connector with its own tools.
    func testOneSignInAsksForEveryChosenServicesScopesAndConnectsEach() async throws {
        let google = FakeGoogleWorkspace()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(google: google, agent: agent, credentials: credentials)

        XCTAssertEqual(agent.opened.count, 1, "One browser sign-in for three services")
        let asked = query(agent.opened.first)
        XCTAssertEqual(asked["scope"], [GmailToolCatalog.scope, GoogleCalendarToolCatalog.calendarListScope,
                                        GoogleCalendarToolCatalog.eventsScope, GoogleCalendarToolCatalog.freeBusyScope,
                                        GoogleDriveToolCatalog.readScope, GoogleDriveToolCatalog.fileScope].joined(separator: " "))
        XCTAssertEqual(asked["include_granted_scopes"], "true")
        XCTAssertEqual(asked["access_type"], "offline")
        XCTAssertEqual(asked["prompt"], "select_account consent")
        XCTAssertNil(asked["resource"])
        XCTAssertFalse(asked["scope"]?.contains("https://mail.google.com/") == true)
        XCTAssertFalse(asked["scope"]?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true,
                       "No full Drive access")
        XCTAssertFalse(asked["scope"]?.split(separator: " ").contains("https://www.googleapis.com/auth/calendar") == true,
                       "No full Calendar access")

        XCTAssertEqual(account.address, "person@example.test")
        XCTAssertEqual(account.services.map(\.localService), [.gmail, .googleCalendar, .googleDrive])
        XCTAssertEqual(account.services.map(\.slug), ["gmail", "calendar", "drive"])
        XCTAssertEqual(account.services.map(\.status), [.connected, .connected, .connected])
        XCTAssertEqual(account.services.map(\.displayName),
                       ["Gmail · person@example.test", "Google Calendar · person@example.test", "Google Drive · person@example.test"])
        XCTAssertEqual(Set(account.services.map(\.credentialID)), [account.id], "One sign-in for the account")
        XCTAssertEqual(account.services.first?.id, account.id, "Kept under the first service's ID, as Gmail's was")
        let credential = try XCTUnwrap(credentials.load(account.id))
        XCTAssertEqual(credential.clientID, FakeGoogle.clientID)
        for record in account.services.dropFirst() { XCTAssertNil(try credentials.load(record.id), "No second copy") }

        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(tools.filter { $0.hasPrefix("calendar_") },
                       ["calendar_list_calendars", "calendar_list_events", "calendar_search_events", "calendar_get_event",
                        "calendar_suggest_time", "calendar_create_event", "calendar_update_event", "calendar_delete_event",
                        "calendar_respond_to_event"])
        XCTAssertEqual(tools.filter { $0.hasPrefix("drive_") },
                       ["drive_search_files", "drive_list_recent_files", "drive_get_file_metadata", "drive_get_file_permissions",
                        "drive_read_file_content", "drive_download_file_content", "drive_create_file", "drive_copy_file",
                        "drive_update_file"])
        XCTAssertEqual(tools.count, 8 + 9 + 9)
        let exposed = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(exposed.first { $0["name"] == .string("calendar_list_events") }?["title"],
                       .string("Google Calendar · person@example.test: List events"))
        let label = try XCTUnwrap(ConnectorToolLabels.shared.label(forClaudeTool: "mcp__yardlet__drive_create_file"))
        XCTAssertEqual(label.localService, .googleDrive)
        XCTAssertEqual(label.account, "person@example.test")
        XCTAssertEqual(label.connector, "Google Drive")

        // Every call goes with the account's one token, to its own Calendar and Drive.
        _ = try json(try await call(center, "calendar_list_calendars"))
        _ = try json(try await call(center, "drive_list_recent_files"))
        XCTAssertEqual(Set(google.requests.compactMap(\.account)), ["person@example.test"])
    }

    /// An account with Calendar or Drive alone is named by what that service says, not by Gmail.
    func testAnAccountWithoutGmailIsNamedByCalendarOrDrive() async throws {
        let calendarOnly = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.googleCalendar]))
        let (_, calendarAccount) = try await signedIn("cal@company.test", services: [.googleCalendar], google: calendarOnly)
        XCTAssertEqual(calendarAccount.address, "cal@company.test")
        XCTAssertEqual(calendarAccount.services.map(\.slug), ["calendar"])
        XCTAssertFalse(calendarOnly.google.requests.contains { $0.url?.path().hasSuffix("/profile") == true },
                       "Gmail is not asked without its scope")
        XCTAssertEqual(calendarOnly.calls("GET").first?.path, "/calendar/v3/users/me/calendarList/primary")

        let driveOnly = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.googleDrive]))
        let (_, driveAccount) = try await signedIn("files@example.test", services: [.googleDrive], google: driveOnly)
        XCTAssertEqual(driveAccount.address, "files@example.test")
        let about = try XCTUnwrap(driveOnly.calls("GET", "/drive/v3/about").first)
        XCTAssertEqual(about.value("fields"), "user(emailAddress)")
    }

    // MARK: - Scopes

    /// With granular consent the person can leave Drive unchecked: Gmail and Calendar connect,
    /// Drive says what is missing and gives no tools; Reconnect asks again for all three.
    func testAScopeLeftUncheckedLeavesOnlyThatServiceNeedingSignIn() async throws {
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.gmail, .googleCalendar]))
        let agent = FakeUserAgent()
        let (center, account) = try await signedIn(google: google, agent: agent)
        XCTAssertEqual(account.services.map(\.status), [.connected, .connected, .signInRequired])
        let drive = try XCTUnwrap(account.record(.googleDrive))
        XCTAssertEqual(center.failures[drive.id], GoogleSignInError.scopeNotGranted([.googleDrive]).errorDescription)
        XCTAssertEqual(ConnectorSettingsState.make(drive, in: center), .error(try XCTUnwrap(center.failures[drive.id])))
        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertFalse(tools.contains { $0.hasPrefix("drive_") })
        XCTAssertTrue(tools.contains("calendar_create_event"))

        google.google.grantedScope = FakeGoogleWorkspace.allScopes
        center.reconnect(drive.id)
        await center.waitForConnection(drive.id)
        let again = query(agent.opened.last)
        XCTAssertEqual(again["login_hint"], "person@example.test")
        XCTAssertEqual(again["prompt"], "consent")
        XCTAssertEqual(again["scope"], FakeGoogleWorkspace.allScopes)
        let settled = try XCTUnwrap(center.googleAccounts.first)
        XCTAssertEqual(center.googleAccounts.count, 1)
        XCTAssertEqual(settled.services.map(\.status), [.connected, .connected, .connected])
        XCTAssertNil(center.failures[drive.id])

        // Nothing granted at all is no sign-in.
        let none = FakeGoogleWorkspace(granting: "openid")
        let empty = makeCenter(google: none)
        try await empty.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let lone = try XCTUnwrap(empty.addGoogleAccount(services: [.googleCalendar, .googleDrive]))
        await empty.waitForConnection(lone.id)
        XCTAssertEqual(empty.failures[lone.id],
                       GoogleSignInError.scopeNotGranted([.googleCalendar, .googleDrive]).errorDescription)
        XCTAssertNotEqual(empty.record(lone.id)?.status, .connected)
    }

    /// Turning a service on asks Google again only when the account's sign-in lacks its scopes
    /// (incremental authorization, the account named); off removes its connector and keeps the
    /// sign-in for the others; removing the account removes all of it.
    func testTurningAServiceOnAsksOnlyWhenTheSignInLacksItsScopes() async throws {
        let google = FakeGoogleWorkspace(granting: GmailToolCatalog.scope)
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(services: [.gmail], google: google, agent: agent, credentials: credentials)
        XCTAssertEqual(query(agent.opened.first)["scope"], GmailToolCatalog.scope, "Gmail alone asks for Gmail alone")

        google.google.grantedScope = FakeGoogleWorkspace.allScopes
        await center.setGoogleService(.googleCalendar, on: true, account: account.id)
        let calendar = try XCTUnwrap(center.googleAccounts.first?.record(.googleCalendar))
        await center.waitForConnection(calendar.id)
        XCTAssertEqual(agent.opened.count, 2, "Calendar's scopes were not granted yet")
        let incremental = query(agent.opened.last)
        XCTAssertEqual(incremental["login_hint"], "person@example.test")
        XCTAssertEqual(incremental["include_granted_scopes"], "true")
        XCTAssertEqual(incremental["scope"], GoogleOAuth.scope(for: [.gmail, .googleCalendar]))
        XCTAssertEqual(center.record(calendar.id)?.status, .connected)
        XCTAssertEqual(center.record(calendar.id)?.slug, "calendar")
        XCTAssertEqual(center.record(calendar.id)?.credentialID, account.id)
        XCTAssertEqual(center.record(account.id)?.status, .connected)

        // That sign-in granted Drive too, so turning Drive on needs no browser.
        await center.setGoogleService(.googleDrive, on: true, account: account.id)
        let drive = try XCTUnwrap(center.googleAccounts.first?.record(.googleDrive))
        await center.waitForConnection(drive.id)
        XCTAssertEqual(agent.opened.count, 2)
        XCTAssertEqual(center.record(drive.id)?.status, .connected)
        XCTAssertEqual(center.record(drive.id)?.account, "person@example.test")
        _ = try json(try await call(center, "drive_search_files", ["query": .string("plan")]))

        // Off: Calendar's connector goes, the sign-in stays for Gmail and Drive.
        await center.setGoogleService(.googleCalendar, on: false, account: account.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(center.record(calendar.id))
        XCTAssertNotNil(try credentials.load(account.id))
        XCTAssertEqual(center.googleAccounts.first?.enabled, [.gmail, .googleDrive])
        _ = try json(try await call(center, "gmail_list_labels"))
        let gone = await center.callConnectorTool(named: "calendar_list_calendars", arguments: .object([:]),
                                                  for: ConnectorToolContext())
        XCTAssertNil(gone, "No connector answers for Calendar any more")

        // Even Gmail's own connector, whose ID the sign-in is under, can go while Drive stays.
        await center.setGoogleService(.gmail, on: false, account: account.id)
        await center.waitForPendingDeletions()
        XCTAssertNotNil(try credentials.load(account.id))
        _ = try json(try await call(center, "drive_list_recent_files"))

        center.removeGoogleAccount(account.id)
        await center.waitForPendingDeletions()
        XCTAssertTrue(center.googleAccounts.isEmpty)
        XCTAssertNil(try credentials.load(account.id))
    }

    // MARK: - Calendar tools

    func testCalendarToolsMapToTheCalendarAPI() async throws {
        let google = FakeGoogleWorkspace()
        let (center, _) = try await signedIn(google: google)

        let calendars = try json(try await call(center, "calendar_list_calendars"))
        XCTAssertEqual(calendars["calendars"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
                       ["person@example.test", FakeGoogleWorkspace.holidays])
        XCTAssertEqual(calendars["calendars"]?.arrayValue?.last?["summary"], .string("공휴일"), "The person's own name for it")
        XCTAssertEqual(calendars["nextPageToken"], .string("calendars-2"))
        XCTAssertNil(calendars["calendars"]?.arrayValue?.first?["etag"])
        XCTAssertEqual(google.calls("GET", "/calendar/v3/users/me/calendarList").last?.value("maxResults"), "100")

        // A local time is read in the zone; the calendar ID is one encoded path segment.
        let events = try json(try await call(center, "calendar_list_events", [
            "calendarId": .string(FakeGoogleWorkspace.holidays), "startTime": .string("2026-10-20T09:00:00"),
            "endTime": .string("2026-10-22T18:00"), "fullText": .string("review"),
            "eventType": .array([.string("DEFAULT"), .string("FOCUS_TIME")]), "pageSize": .integer(500)
        ]))
        let list = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(list.path, "/calendar/v3/calendars/ko.south_korea%23holiday%40group.v.calendar.google.com/events")
        XCTAssertEqual(list.value("timeMin"), "2026-10-20T09:00:00+09:00")
        XCTAssertEqual(list.value("timeMax"), "2026-10-22T18:00:00+09:00")
        XCTAssertEqual(list.value("singleEvents"), "true")
        XCTAssertEqual(list.value("orderBy"), "startTime")
        XCTAssertEqual(list.value("q"), "review")
        XCTAssertEqual(list.query["eventTypes"], ["default", "focusTime"])
        XCTAssertEqual(list.value("maxResults"), "250")
        XCTAssertEqual(list.value("timeZone"), "Asia/Seoul")
        let first = try XCTUnwrap(events["events"]?.arrayValue?.first)
        XCTAssertEqual(first["id"], .string("e1"))
        XCTAssertEqual(first["conferenceUrl"], .string("https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(first["organizer"], .string("bob@example.com"))
        XCTAssertEqual(first["availability"], .string("AVAILABILITY_BUSY"))
        XCTAssertEqual(first["attendees"]?.arrayValue?.last?["self"], .bool(true))
        XCTAssertNil(first["etag"])
        XCTAssertEqual(events["nextPageToken"], .string("events-2"))
        let reversed = try json(try await call(center, "calendar_list_events", ["orderBy": .string("startTimeDesc")]))
        XCTAssertEqual(reversed["events"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["e2", "e1"])
        let defaults = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(defaults.path, "/calendar/v3/calendars/primary/events")
        let start = try XCTUnwrap(defaults.value("timeMin").flatMap(CalendarTime.absolute))
        let end = try XCTUnwrap(defaults.value("timeMax").flatMap(CalendarTime.absolute))
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 86_400, accuracy: 1, "The 7 days from now")

        _ = try json(try await call(center, "calendar_search_events", ["query": .string("design review")]))
        let search = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(search.path, "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(search.value("q"), "design review")
        let got = try json(try await call(center, "calendar_get_event", ["eventId": .string("e1")]))
        XCTAssertEqual(got["summary"], .string("Design review e1"))

        // Free times every attendee shares, past the merged busy times, on quarter hours.
        let free = try json(try await call(center, "calendar_suggest_time", [
            "attendeeEmails": .array([.string("bob@example.com"), .string("nobody@example.com")]),
            "startTime": .string("2026-10-21T09:00:00"), "endTime": .string("2026-10-21T13:00:00"),
            "durationMinutes": .integer(30)
        ]))
        let freeBusy = try XCTUnwrap(google.calls("POST", "/calendar/v3/freeBusy").last?.json)
        XCTAssertEqual(freeBusy["items"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
                       ["primary", "bob@example.com", "nobody@example.com"])
        XCTAssertEqual(freeBusy["timeMin"], .string("2026-10-21T09:00:00+09:00"))
        XCTAssertEqual(free["timeSlots"]?.arrayValue?.compactMap { $0["startTime"]?.stringValue },
                       ["2026-10-21T11:15:00+09:00", "2026-10-21T12:15:00+09:00"])
        XCTAssertEqual(free["unavailableCalendars"]?.arrayValue?.first?["calendar"], .string("nobody@example.com"))

        // Creating: the times with their offset and zone, attendees, a Meet link, a recurrence.
        let made = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Yardlet sync"), "startTime": .string("2026-10-23T15:00:00"),
            "endTime": .string("2026-10-23T15:30:00"), "description": .string("Connectors"),
            "attendees": .array([.object(["email": .string("bob@example.com"), "optionalAttendee": .bool(true)])]),
            "attendeeEmails": .array([.string("carol@example.com"), .string("BOB@example.com")]),
            "addGoogleMeetUrl": .bool(true), "recurrenceData": .array([.string("RRULE:FREQ=WEEKLY;COUNT=4")]),
            "overrideReminders": .array([.object(["method": .string("popup"), "minutes": .integer(10)])]),
            "availability": .string("AVAILABILITY_FREE")
        ]))
        let insert = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last)
        XCTAssertEqual(insert.value("conferenceDataVersion"), "1")
        XCTAssertEqual(insert.value("sendUpdates"), "all")
        let body = try XCTUnwrap(insert.json)
        XCTAssertEqual(body["start"], .object(["dateTime": .string("2026-10-23T15:00:00+09:00"), "timeZone": .string("Asia/Seoul")]))
        XCTAssertEqual(body["attendees"]?.arrayValue?.compactMap { $0["email"]?.stringValue },
                       ["bob@example.com", "carol@example.com"], "Bob once")
        XCTAssertEqual(body["attendees"]?.arrayValue?.first?["optional"], .bool(true))
        XCTAssertEqual(body["conferenceData"]?["createRequest"]?["conferenceSolutionKey"]?["type"], .string("hangoutsMeet"))
        XCTAssertEqual(body["recurrence"], .array([.string("RRULE:FREQ=WEEKLY;COUNT=4")]))
        XCTAssertEqual(body["reminders"]?["useDefault"], .bool(false))
        XCTAssertEqual(body["transparency"], .string("transparent"))
        XCTAssertEqual(made["conferenceUrl"]?.stringValue?.hasPrefix("https://meet.google.com/"), true)
        XCTAssertEqual(made["availability"], .string("AVAILABILITY_FREE"))

        // An all-day event: dates, the end day included; an offset given is kept as the instant.
        _ = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Offsite"), "startTime": .string("2026-11-02"), "endTime": .string("2026-11-03"),
            "allDay": .bool(true), "notificationLevel": .string("NONE")
        ]))
        let allDay = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last)
        XCTAssertEqual(allDay.json?["start"], .object(["date": .string("2026-11-02")]))
        XCTAssertEqual(allDay.json?["end"], .object(["date": .string("2026-11-04")]))
        XCTAssertEqual(allDay.value("sendUpdates"), "none")
        _ = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Call"), "startTime": .string("2026-10-23T06:00:00Z"), "endTime": .string("2026-10-23T06:30:00Z"),
            "timeZone": .string("Europe/Zurich")
        ]))
        let zoned = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last?.json)
        XCTAssertEqual(zoned["start"], .object(["dateTime": .string("2026-10-23T08:00:00+02:00"), "timeZone": .string("Europe/Zurich")]))

        // Moving only the start keeps the length; attendees change by email.
        _ = try json(try await call(center, "calendar_update_event", [
            "eventId": .string("e1"), "startTime": .string("2026-10-21T14:00:00"),
            "addedAttendeeEmails": .array([.string("dana@example.com")]), "removedAttendeeEmails": .array([.string("BOB@example.com")]),
            "notificationLevel": .string("EXTERNAL_ONLY")
        ]))
        let patch = try XCTUnwrap(google.calls("PATCH", "/calendar/v3/calendars/primary/events/e1").last)
        XCTAssertEqual(patch.value("sendUpdates"), "externalOnly")
        XCTAssertEqual(patch.json?["start"]?["dateTime"], .string("2026-10-21T14:00:00+09:00"))
        XCTAssertEqual(patch.json?["end"]?["dateTime"], .string("2026-10-21T15:00:00+09:00"))
        XCTAssertEqual(patch.json?["attendees"]?.arrayValue?.compactMap { $0["email"]?.stringValue },
                       ["person@example.test", "dana@example.com"])

        let deleted = try json(try await call(center, "calendar_delete_event", ["eventId": .string("e1")]))
        XCTAssertEqual(deleted["deleted"], .bool(true))
        XCTAssertEqual(google.calls("DELETE").last?.value("sendUpdates"), "all")

        // Answering: the account's own attendee entry, and only it, changes.
        let answered = try json(try await call(center, "calendar_respond_to_event", [
            "eventId": .string("e1"), "responseStatus": .string("accepted"), "responseComment": .string("See you")
        ]))
        let response = try XCTUnwrap(google.calls("PATCH", "/calendar/v3/calendars/primary/events/e1").last?.json)
        XCTAssertEqual(response["attendees"]?.arrayValue?.map { $0["responseStatus"] }, [.string("accepted"), .string("accepted")])
        XCTAssertEqual(response["attendees"]?.arrayValue?.last?["comment"], .string("See you"))
        XCTAssertEqual(response.objectValue?.keys.sorted(), ["attendees"])
        XCTAssertNotNil(answered["attendees"])
        let notInvited = try await call(center, "calendar_respond_to_event",
                                        ["eventId": .string("not-invited"), "responseStatus": .string("declined")])
        XCTAssertTrue(notInvited.isError)

        // Mistakes the model can fix answer before any request.
        let before = google.requests.count
        for (tool, arguments) in [("calendar_create_event", ["startTime": ToolJSON.string("2026-10-23T15:00:00"),
                                                              "endTime": .string("2026-10-23T16:00:00")]),
                                  ("calendar_list_events", ["timeZone": .string("Mars/Olympus")]),
                                  ("calendar_create_event", ["summary": .string("x"), "startTime": .string("tomorrow"),
                                                             "endTime": .string("later")]),
                                  ("calendar_update_event", ["eventId": .string("e1")]),
                                  ("calendar_respond_to_event", ["eventId": .string("e1"), "responseStatus": .string("maybe")])] {
            let result = try await call(center, tool, arguments)
            XCTAssertTrue(result.isError, "\(tool) \(arguments)")
        }
        XCTAssertEqual(google.requests.count, before)
        let missing = try await call(center, "calendar_get_event", ["eventId": .string("nope")])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, "Google Calendar: Not Found (HTTP 404)")
    }

    // MARK: - Drive tools

    func testDriveToolsMapToTheDriveAPI() async throws {
        let google = FakeGoogleWorkspace()
        let (center, _) = try await signedIn(google: google)

        // The query terms Google's Drive MCP takes, in the Drive API's words; trashed files stay out.
        let found = try json(try await call(center, "drive_search_files", [
            "query": .string("title contains 'plan' and parentId = 'root' and owner != 'me'"), "pageSize": .integer(500)
        ]))
        let search = try XCTUnwrap(google.calls("GET", "/drive/v3/files").last)
        XCTAssertEqual(search.value("q"), "(name contains 'plan' and 'root' in parents and not 'me' in owners) and trashed = false")
        XCTAssertEqual(search.value("pageSize"), "100")
        XCTAssertEqual(search.value("supportsAllDrives"), "true")
        XCTAssertTrue(search.value("fields")?.hasPrefix("nextPageToken,files(") == true)
        let file = try XCTUnwrap(found["files"]?.arrayValue?.first)
        XCTAssertEqual(file["title"], .string("Launch plan"))
        XCTAssertEqual(file["owner"], .string("person@example.test"))
        XCTAssertEqual(file["parentId"], .string("folder-1"))
        XCTAssertEqual(file["viewUrl"], .string("https://drive.google.com/file/d/doc-1/view"))
        XCTAssertEqual(found["nextPageToken"], .string("files-2"))
        _ = try json(try await call(center, "drive_search_files", ["query": .string("Bob's quarterly plan")]))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("q"),
                       "fullText contains 'Bob\\'s quarterly plan' and trashed = false", "Plain words search the text")
        _ = try json(try await call(center, "drive_list_recent_files", ["orderBy": .string("lastModified")]))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("orderBy"), "modifiedTime desc")
        _ = try json(try await call(center, "drive_list_recent_files"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("orderBy"), "recency desc")
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("pageSize"), "10")

        let metadata = try json(try await call(center, "drive_get_file_metadata", ["fileId": .string("pdf-1")]))
        XCTAssertEqual(metadata["fileSize"], .string("8"))
        let permissions = try json(try await call(center, "drive_get_file_permissions", ["fileId": .string("doc-1")]))
        XCTAssertEqual(permissions["permissions"]?.arrayValue?.compactMap { $0["role"]?.stringValue }, ["owner", "reader"])

        // Reading: a Doc as Markdown with its comments, a Sheet as CSV, text as it is; a PDF is not text.
        let doc = try json(try await call(center, "drive_read_file_content", ["fileId": .string("doc-1"),
                                                                              "includeComments": .bool(true)]))
        XCTAssertEqual(doc["content"], .string("# Launch plan\n\n1. Ship\n"))
        XCTAssertEqual(doc["contentFormat"], .string("markdown"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files/doc-1/export").last?.value("mimeType"), "text/markdown")
        let thread = try XCTUnwrap(doc["commentThreads"]?.arrayValue?.first)
        XCTAssertEqual(thread["headPost"]?["content"], .string("Is this the final date?"))
        XCTAssertEqual(thread["headPost"]?["authorName"], .string("Bob"))
        XCTAssertEqual(thread["quotedText"], .string("1. Ship"))
        XCTAssertEqual(thread["replies"]?.arrayValue?.first?["content"], .string("Yes."))
        XCTAssertEqual(thread["status"], .string("OPEN"))
        let sheet = try json(try await call(center, "drive_read_file_content", ["fileId": .string("sheet-1")]))
        XCTAssertEqual(sheet["content"], .string("item,cost\nservers,120\n"))
        XCTAssertEqual(sheet["contentFormat"], .string("csv, first sheet"))
        let slides = try json(try await call(center, "drive_read_file_content", ["fileId": .string("slides-1")]))
        XCTAssertEqual(slides["content"], .string("Kickoff\nGoals"))
        let notes = try json(try await call(center, "drive_read_file_content", ["fileId": .string("notes-1")]))
        XCTAssertEqual(notes["content"], .string("# Notes\n- ship it\n"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files/notes-1").last?.value("alt"), "media")
        let pdf = try await call(center, "drive_read_file_content", ["fileId": .string("pdf-1")])
        XCTAssertTrue(pdf.isError)
        XCTAssertTrue(pdf.text.contains("download_file_content"), pdf.text)

        // Downloading: bytes as base64; a Google type exported, as text unless another type is asked.
        let bytes = try json(try await call(center, "drive_download_file_content", ["fileId": .string("pdf-1")]))
        XCTAssertEqual(bytes["base64Content"], .string(FakeGoogleWorkspace.pdfBytes.base64EncodedString()))
        XCTAssertEqual(bytes["mimeType"], .string("application/pdf"))
        let exported = try json(try await call(center, "drive_download_file_content", [
            "fileId": .string("doc-1"), "exportMimeType": .string("application/pdf")]))
        XCTAssertEqual(exported["mimeType"], .string("application/pdf"))
        let huge = try await call(center, "drive_download_file_content", ["fileId": .string("huge-1")])
        XCTAssertTrue(huge.isError)
        XCTAssertFalse(google.calls("GET", "/drive/v3/files/huge-1").contains { $0.value("alt") == "media" },
                       "Too large is known from its size, before a download")

        // Creating: CSV content becomes a Sheet in one multipart upload; no content makes a Doc.
        let sheetMade = try json(try await call(center, "drive_create_file", [
            "title": .string("Costs"), "textContent": .string("a,b\n1,2\n"), "contentMimeType": .string("text/csv"),
            "parentId": .string("folder-9")
        ]))
        let upload = try XCTUnwrap(google.calls("POST", "/upload/drive/v3/files").last)
        XCTAssertEqual(upload.value("uploadType"), "multipart")
        let (sentMetadata, sentContent) = try XCTUnwrap(FakeGoogleWorkspace.multipart(
            upload.body, contentType: "multipart/related; boundary=\(try XCTUnwrap(Self.boundary(upload.body)))"))
        XCTAssertEqual(sentMetadata["mimeType"], .string(GoogleDriveToolCatalog.spreadsheet))
        XCTAssertEqual(sentMetadata["parents"], .array([.string("folder-9")]))
        XCTAssertEqual(sentContent, "a,b\n1,2\n")
        XCTAssertEqual(sheetMade["title"], .string("Costs"))
        let kept = try json(try await call(center, "drive_create_file", [
            "title": .string("raw.csv"), "textContent": .string("x"), "contentMimeType": .string("text/csv"),
            "disableConversionToGoogleType": .bool(true)
        ]))
        XCTAssertEqual(kept["mimeType"], .string("text/csv"))
        let emptyDoc = try json(try await call(center, "drive_create_file", ["title": .string("Notes")]))
        XCTAssertEqual(emptyDoc["mimeType"], .string(GoogleDriveToolCatalog.document))
        XCTAssertEqual(google.calls("POST", "/drive/v3/files").last?.json?["mimeType"], .string(GoogleDriveToolCatalog.document))

        let copied = try json(try await call(center, "drive_copy_file", ["fileId": .string("doc-1"), "title": .string("Plan v2")]))
        XCTAssertEqual(copied["title"], .string("Plan v2"))
        XCTAssertEqual(google.calls("POST", "/drive/v3/files/doc-1/copy").last?.json?["name"], .string("Plan v2"))

        // Changing: a file Yardlet made, renamed, moved, and given new content in one request.
        let changed = try json(try await call(center, "drive_update_file", [
            "fileId": .string("app-note"), "title": .string("Renamed"), "textContent": .string("new text"),
            "parentId": .string("folder-2")
        ]))
        let update = try XCTUnwrap(google.calls("PATCH", "/upload/drive/v3/files/app-note").last)
        XCTAssertEqual(update.value("addParents"), "folder-2")
        XCTAssertEqual(update.value("removeParents"), "folder-1")
        XCTAssertEqual(changed["title"], .string("Renamed"))
        // Someone else's file: `drive.file` gives no write access, and Google's words say so.
        let refused = try await call(center, "drive_update_file", ["fileId": .string("doc-1"), "title": .string("Mine now")])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.hasPrefix("Google Drive: The user has not granted the app"), refused.text)
        XCTAssertTrue(refused.text.hasSuffix("(HTTP 403)"), refused.text)

        let before = google.requests.count
        for arguments: [String: ToolJSON] in [["fileId": .string("app-note")],
                                              ["fileId": .string("x\ny")],
                                              ["fileId": .string("doc-1"), "textContent": .string("a"), "base64Content": .string("YQ==")]] {
            let result = try await call(center, "drive_update_file", arguments)
            XCTAssertTrue(result.isError, "\(arguments)")
        }
        let untyped = try await call(center, "drive_create_file", ["title": .string("x"), "base64Content": .string("YQ==")])
        XCTAssertTrue(untyped.isError, "base64 needs its type")
        XCTAssertEqual(google.requests.count, before)
    }

    private static func boundary(_ body: Data?) -> String? {
        guard let first = body.flatMap({ String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n").first }),
              first.hasPrefix("--") else { return nil }
        return String(first.dropFirst(2))
    }

    // MARK: - Asking before writes

    func testWritesAskInEveryHarnessAndReadsDoNot() async throws {
        let (center, _) = try await signedIn()
        XCTAssertEqual(GoogleCalendarToolCatalog.approvalRequired,
                       ["create_event", "update_event", "delete_event", "respond_to_event"])
        XCTAssertEqual(GoogleDriveToolCatalog.approvalRequired, ["create_file", "copy_file", "update_file"])
        for tool in GoogleCalendarToolCatalog.tools + GoogleDriveToolCatalog.tools {
            let name = try XCTUnwrap(tool["name"]?.stringValue)
            let writes = GoogleCalendarToolCatalog.approvalRequired.contains(name) || GoogleDriveToolCatalog.approvalRequired.contains(name)
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], .bool(!writes), name)
            let description = tool["description"]?.stringValue ?? ""
            XCTAssertLessThan(description.count, 260, description)
            for word in ["always", "must", "should", "IMPORTANT", "NEVER"] {
                XCTAssertFalse(description.contains(word), "Neutral wording: \(description)")
            }
        }
        XCTAssertEqual(GoogleCalendarToolCatalog.tools.first { $0["name"] == .string("delete_event") }?["annotations"]?["destructiveHint"],
                       .bool(true))

        // Claude Code: none is allowed up front, so the CLI asks before each.
        XCTAssertFalse(AgentToolServerLaunch.claudeAllowedTools.contains { $0.contains("calendar") || $0.contains("drive") })

        // Codex: the writes ask every time; reading does not.
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                                                     privateDirectory: FileManager.default.temporaryDirectory,
                                                     isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in }))
        broker.connectors = center
        let launch = try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .codex)))
        // Codex asks as the task's approval setting has it (2026-10-22): no per-tool mode of Yardlet's.
        XCTAssertNil(launch.codexConfig["mcp_servers"]?["yardlet"]?["tools"])

        // Claude Code's card: the account and what the call would do, with no "always allow".
        let create = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_create_event", input: .object([
            "summary": .string("Yardlet sync"), "startTime": .string("2026-10-23T15:00:00"), "endTime": .string("2026-10-23T15:30:00"),
            "attendees": .array([.object(["email": .string("bob@example.com")])]), "addGoogleMeetUrl": .bool(true)
        ])))
        XCTAssertEqual(create.title, L10n.format("Allow Claude to create an event in %@'s calendar?", "person@example.test"))
        for part in [L10n.format("Title: %@", "Yardlet sync"), L10n.format("Invites: %@", "bob@example.com"),
                     L10n.string("Adds a Google Meet link."), L10n.string("Google emails the guests.")] {
            XCTAssertTrue(create.detail.contains(part), "\(part) in \(create.detail)")
        }
        let delete = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_delete_event",
                                                              input: .object(["eventId": .string("e1"), "notificationLevel": .string("NONE")])))
        XCTAssertEqual(delete.title, L10n.format("Allow Claude to delete an event from %@'s calendar?", "person@example.test"))
        XCTAssertTrue(delete.detail.contains(L10n.string("Google emails no one about it.")))
        let respond = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_respond_to_event",
                                                               input: .object(["eventId": .string("e1"), "responseStatus": .string("declined")])))
        XCTAssertEqual(respond.title, L10n.format("Allow Claude to answer an invitation as %@?", "person@example.test"))
        XCTAssertTrue(respond.detail.contains(L10n.format("Answer: %@", L10n.string("Not going"))), respond.detail)
        let file = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_create_file", input: .object([
            "title": .string("Costs"), "textContent": .string("a,b\n1,2"), "contentMimeType": .string("text/csv")
        ])))
        XCTAssertEqual(file.title, L10n.format("Allow Claude to create a file in %@'s Drive?", "person@example.test"))
        XCTAssertTrue(file.detail.contains("a,b\n1,2"), file.detail)
        XCTAssertEqual(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_update_file", input: .object([:]))?.title,
                       L10n.format("Allow Claude to change a file in %@'s Drive?", "person@example.test"))
        XCTAssertNotNil(GoogleToolApproval.request(toolName: "mcp__yardlet__gmail_send_message", input: .object([:])),
                        "Gmail's cards come through the same place")
        for read in ["mcp__yardlet__calendar_list_events", "mcp__yardlet__drive_read_file_content",
                     "mcp__claude_ai_Google_Calendar__create_event"] {
            XCTAssertNil(GoogleToolApproval.request(toolName: read, input: .object([:])), read)
        }

        // Through the Claude adapter: the delete card has no "always allow"; a read keeps the CLI's offer.
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let recorder = PermissionRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case let .permissionRequested(request) = event.payload { await recorder.append(request) }
            }
        }
        defer { collector.cancel() }
        for (id, tool) in [("delete-1", "mcp__yardlet__calendar_delete_event"), ("read-1", "mcp__yardlet__calendar_list_events")] {
            let suggestion: JSONValue = .object([
                "type": .string("addRules"), "destination": .string("session"), "behavior": .string("allow"),
                "rules": .array([.object(["toolName": .string(tool)])])
            ])
            await transport.emit(.object([
                "type": .string("control_request"), "request_id": .string(id),
                "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string(tool),
                                    "input": .object(["eventId": .string("e1")]), "tool_use_id": .string("toolu-\(id)"),
                                    "permission_suggestions": .array([suggestion])])
            ]))
        }
        let deleteCard = try await recorder.waitFor("delete-1")
        XCTAssertEqual(deleteCard.title, delete.title)
        XCTAssertTrue(deleteCard.actions.isEmpty, "No always-allow: \(deleteCard.actions.map(\.id))")
        let readCard = try await recorder.waitFor("read-1")
        XCTAssertFalse(readCard.actions.isEmpty, "Reading is the CLI's ordinary card")
        await adapter.close(handle)
    }

    // MARK: - Two accounts

    func testTwoAccountsKeepTheirOwnTokensNamesAndServices() async throws {
        let google = FakeGoogleWorkspace()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, personal) = try await signedIn("person@example.test", google: google, credentials: credentials)
        google.google.signInAs = "developer@company.test"
        let work = try XCTUnwrap(center.addGoogleAccount(services: [.googleCalendar, .googleDrive]))
        await center.waitForConnection(work.id)
        let settled = try XCTUnwrap(center.googleAccounts.first { $0.id == work.id })
        XCTAssertEqual(settled.address, "developer@company.test")
        XCTAssertEqual(settled.services.map(\.slug), ["calendar_developer", "drive_developer"],
                       "A second account's tools are named after it")
        XCTAssertEqual(center.googleAccounts.map(\.address), ["person@example.test", "developer@company.test"])
        XCTAssertNotEqual(try credentials.load(personal.id)?.accessToken, try credentials.load(work.id)?.accessToken)

        _ = try json(try await call(center, "calendar_list_calendars"))
        XCTAssertEqual(google.requests.last?.account, "person@example.test")
        let theirs = try json(try await call(center, "calendar_developer_list_calendars"))
        XCTAssertEqual(google.requests.last?.account, "developer@company.test")
        XCTAssertEqual(theirs["calendars"]?.arrayValue?.first?["id"], .string("developer@company.test"))

        // Turned off in one task, only that account's Calendar leaves it.
        let task = UUID()
        let workCalendar = try XCTUnwrap(settled.record(.googleCalendar))
        center.setConnector(workCalendar.id, on: false, inTask: task)
        let inTask = await center.connectorTools(for: ConnectorToolContext(taskID: task)).compactMap { $0["name"]?.stringValue }
        XCTAssertFalse(inTask.contains { $0.hasPrefix("calendar_developer_") })
        XCTAssertTrue(inTask.contains("drive_developer_search_files"))
        XCTAssertTrue(inTask.contains("calendar_list_events"))

        // Turning Gmail on for the second account names it after the account too.
        await center.setGoogleService(.gmail, on: true, account: work.id)
        let workGmail = try XCTUnwrap(center.googleAccounts.first { $0.id == work.id }?.record(.gmail))
        await center.waitForConnection(workGmail.id)
        XCTAssertEqual(center.record(workGmail.id)?.slug, "gmail_developer")
        XCTAssertEqual(center.record(workGmail.id)?.status, .connected)

        // Signing in to an account that is here already adds its services to that account.
        google.google.signInAs = "Person@example.test"
        let again = try XCTUnwrap(center.addGoogleAccount(services: [.googleDrive]))
        await center.waitForConnection(again.id)
        XCTAssertEqual(center.googleAccounts.count, 2)
        XCTAssertNil(center.record(again.id), "Drive was on for that account already")
        XCTAssertNil(try credentials.load(again.id))

        // A revoked sign-in leaves all that account's services needing sign-in, not the other's.
        google.google.revoke("developer@company.test")
        let refused = try await call(center, "drive_developer_search_files", ["query": .string("x")])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("needs the user to sign in again"), refused.text)
        XCTAssertEqual(center.googleAccounts.first { $0.id == work.id }?.services.map(\.status),
                       [.signInRequired, .signInRequired, .signInRequired])
        XCTAssertEqual(center.googleAccounts.first { $0.id == personal.id }?.services.map(\.status),
                       [.connected, .connected, .connected])
        _ = try json(try await call(center, "drive_search_files", ["query": .string("x")]))
    }

    // MARK: - Pieces

    func testFreeSlotsKeepToWorkingHoursAndWeekdays() throws {
        let zone = Self.seoul
        // Friday 2026-10-23 16:00 to Monday 2026-10-26 12:00, Seoul.
        let from = try XCTUnwrap(CalendarTime.parse("2026-10-23T16:00:00", in: zone)?.date)
        let to = try XCTUnwrap(CalendarTime.parse("2026-10-26T12:00:00", in: zone)?.date)
        let busy = [DateInterval(start: try XCTUnwrap(CalendarTime.parse("2026-10-26T09:00:00", in: zone)?.date), duration: 3_600)]
        let window = try CalendarTime.Window(start: "09:00", end: "18:00")
        let slots = CalendarTime.freeSlots(from: from, to: to, busy: busy, minutes: 45, window: window,
                                           excludeWeekends: true, zone: zone, limit: 5)
        XCTAssertEqual(slots.map { CalendarTime.rfc3339($0.start, in: zone) },
                       ["2026-10-23T16:00:00+09:00", "2026-10-23T17:00:00+09:00", "2026-10-26T10:00:00+09:00",
                        "2026-10-26T11:00:00+09:00"])
        XCTAssertThrowsError(try CalendarTime.Window(start: "18:00", end: "09:00"))
        XCTAssertThrowsError(try CalendarTime.Window(start: "9am", end: nil))
    }

    func testDriveQueriesTranslateGooglesTermsToTheDriveAPI() {
        XCTAssertEqual(DriveQuery.translate(""), "trashed = false")
        XCTAssertEqual(DriveQuery.translate("mimeType = 'application/pdf' and modifiedTime > '2026-01-01T00:00:00Z'"),
                       "(mimeType = 'application/pdf' and modifiedTime > '2026-01-01T00:00:00Z') and trashed = false")
        XCTAssertEqual(DriveQuery.translate("title = 'It\\'s here' or (starred = true and sharedWithMe = true)"),
                       "(name = 'It\\'s here' or (starred = true and sharedWithMe = true)) and trashed = false")
        XCTAssertEqual(DriveQuery.translate("fullText contains 'title' and trashed = true"),
                       "fullText contains 'title' and trashed = true", "A word inside quotes stays; asking about trash is kept")
        XCTAssertEqual(DriveQuery.translate("budget 2026"), "fullText contains 'budget 2026' and trashed = false")
        XCTAssertEqual(DriveQuery.translate("plan in progress"), "fullText contains 'plan in progress' and trashed = false")
        XCTAssertEqual(DriveQuery.translate("'folder-1' in parents"), "('folder-1' in parents) and trashed = false")
    }

    private func makeExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yardlet-mcp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor PermissionRecorder {
    private var requests: [PermissionRequest] = []
    func append(_ request: PermissionRequest) { requests.append(request) }
    func waitFor(_ id: String) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let request = requests.last(where: { $0.id == id }) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessAdapterError.invalidProviderEvent("no permission request \(id)")
    }
}
