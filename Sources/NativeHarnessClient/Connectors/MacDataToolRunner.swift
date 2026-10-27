import Foundation
import YardletAgentTools

/// Runs the Apple Calendar, Reminders, and Contacts tools against the Mac's store and answers
/// with compact JSON text. Arguments are checked before the store is touched; a mistake the model
/// can fix is an error result. Times without an offset are read in the call's `timeZone`, else the
/// Mac's, as the Google Calendar tools read them.
struct MacDataToolRunner: Sendable {
    let service: LocalConnectorService
    let store: any MacDataStoring
    var timeZone: TimeZone = .current
    var now: @Sendable () -> Date = { Date() }

    typealias Problem = GoogleToolArguments.Problem
    private typealias Arguments = GoogleToolArguments

    /// The kind of data a service's tools reach.
    static func kind(of service: LocalConnectorService) -> MacDataKind? {
        switch service {
        case .appleCalendar: .calendars
        case .appleReminders: .reminders
        case .appleContacts: .contacts
        default: nil
        }
    }

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch (service, name) {
            case (.appleCalendar, MacCalendarToolCatalog.listCalendars): result = try calendars(.calendars, key: "calendars")
            case (.appleCalendar, MacCalendarToolCatalog.listEvents): result = try listEvents(arguments)
            case (.appleCalendar, MacCalendarToolCatalog.searchEvents): result = try searchEvents(arguments)
            case (.appleCalendar, MacCalendarToolCatalog.getEvent): result = try getEvent(arguments)
            case (.appleCalendar, MacCalendarToolCatalog.createEvent): result = try saveEvent(arguments, creating: true)
            case (.appleCalendar, MacCalendarToolCatalog.updateEvent): result = try saveEvent(arguments, creating: false)
            case (.appleCalendar, MacCalendarToolCatalog.deleteEvent): result = try deleteEvent(arguments)
            case (.appleReminders, MacRemindersToolCatalog.listReminderLists): result = try calendars(.reminders, key: "lists")
            case (.appleReminders, MacRemindersToolCatalog.listReminders): result = try await listReminders(arguments)
            case (.appleReminders, MacRemindersToolCatalog.createReminder): result = try createReminder(arguments)
            case (.appleReminders, MacRemindersToolCatalog.completeReminder): result = try completeReminder(arguments)
            case (.appleContacts, MacContactsToolCatalog.searchContacts): result = try searchContacts(arguments)
            case (.appleContacts, MacContactsToolCatalog.getContact): result = try getContact(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        }
    }

    // MARK: Calendars

    private func calendars(_ kind: MacDataKind, key: String) throws -> ToolJSON {
        .object([key: .array(try store.calendars(kind).map { calendar in
            var fields: [String: ToolJSON] = [
                "id": .string(calendar.id), "title": .string(calendar.title), "account": .string(calendar.account),
                "allowsChanges": .bool(calendar.allowsChanges)
            ]
            if calendar.isDefault { fields["default"] = .bool(true) }
            if let color = calendar.color { fields["color"] = .string(color) }
            return .object(fields)
        })])
    }

    private func listEvents(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let zone = try zone(arguments)
        let start = try Arguments.string(arguments, "startTime").map { try time($0, in: zone, name: "startTime").date } ?? now()
        let end = try Arguments.string(arguments, "endTime").map { try time($0, in: zone, name: "endTime").date }
            ?? start.addingTimeInterval(7 * 86_400)
        guard end > start else { throw Problem.invalid("endTime is after startTime.") }
        // EventKit looks at four years at most in one search.
        guard end.timeIntervalSince(start) <= 4 * 365 * 86_400 else { throw Problem.invalid("The range is four years at most.") }
        let calendars = Arguments.string(arguments, "calendarId").map { [$0] }
        let limit = Arguments.pageSize(arguments, range: 1...250, fallback: 50)
        return events(try store.events(from: start, to: end, calendarIDs: calendars), query: Arguments.string(arguments, "query"),
                      limit: limit, zone: zone)
    }

    private func searchEvents(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let query = try Arguments.required(arguments, "query")
        let today = now()
        let found = try store.events(from: today.addingTimeInterval(-365 * 86_400), to: today.addingTimeInterval(365 * 86_400),
                                     calendarIDs: nil)
        return events(found, query: query, limit: Arguments.pageSize(arguments, range: 1...250, fallback: 25), zone: timeZone)
    }

    private func events(_ found: [MacEvent], query: String?, limit: Int, zone: TimeZone) -> ToolJSON {
        let words = query?.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        let matching = found.filter { event in
            let text = [event.title, event.location ?? "", event.notes ?? ""].joined(separator: "\n").lowercased()
            return words.allSatisfy(text.contains)
        }.sorted { $0.start < $1.start }
        var result: [String: ToolJSON] = ["events": .array(matching.prefix(limit).map { encode($0, zone: zone, full: false) })]
        if matching.count > limit { result["more"] = .integer(Int64(matching.count - limit)) }
        return .object(result)
    }

    private func getEvent(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let (id, occurrence) = try eventID(arguments)
        guard let event = try store.event(id: id, occurrence: occurrence) else { throw MacDataError.notFound(id) }
        return encode(event, zone: timeZone, full: true)
    }

    private func saveEvent(_ arguments: [String: ToolJSON], creating: Bool) throws -> ToolJSON {
        let zone = try zone(arguments)
        var change = MacEventChange()
        var existing: MacEvent?
        if !creating {
            let (id, occurrence) = try eventID(arguments)
            guard let event = try store.event(id: id, occurrence: occurrence) else { throw MacDataError.notFound(id) }
            existing = event
            change.id = id
            change.occurrence = occurrence
            change.futureEvents = try futureEvents(arguments)
        }
        change.calendarID = Arguments.string(arguments, "calendarId")
        change.title = try creating ? Arguments.required(arguments, "summary") : Arguments.string(arguments, "summary")
        change.allDay = Arguments.bool(arguments["allDay"])
        change.timeZone = Arguments.string(arguments, "timeZone") == nil ? nil : zone
        let allDay = change.allDay ?? existing?.allDay ?? false
        let start = try Arguments.string(arguments, "startTime").map { try time($0, in: zone, name: "startTime") }
        let end = try Arguments.string(arguments, "endTime").map { try time($0, in: zone, name: "endTime") }
        if creating, start == nil || end == nil { throw Problem.missing(start == nil ? "startTime" : "endTime") }
        if allDay {
            // The days named, the end's day included, as an all-day event spans them.
            change.start = start.map { CalendarTime.day($0.date, in: zone) }
            change.end = end.map { CalendarTime.nextDay($0.date, in: zone).addingTimeInterval(-1) }
        } else {
            change.start = start?.date
            change.end = end?.date
        }
        // Moving only the start keeps the event's length.
        if let existing, let newStart = change.start, change.end == nil {
            change.end = newStart.addingTimeInterval(existing.end.timeIntervalSince(existing.start))
        }
        if let first = change.start ?? existing?.start, let last = change.end ?? existing?.end, last < first {
            throw Problem.invalid("endTime is after startTime.")
        }
        change.location = Arguments.string(arguments, "location")
        change.notes = Arguments.string(arguments, "description")
        if let link = Arguments.string(arguments, "url") {
            guard let url = URL(string: link), url.scheme != nil else { throw Problem.invalid("url is a full address.") }
            change.url = url
        }
        if arguments["alertMinutes"] != nil {
            change.alarmMinutes = try (arguments["alertMinutes"]?.arrayValue ?? []).map {
                guard let minutes = Arguments.integer($0), (0...40_320).contains(minutes) else {
                    throw Problem.invalid("alertMinutes takes minutes from 0 to 40320.")
                }
                return minutes
            }
        }
        return encode(try store.saveEvent(change), zone: zone, full: true)
    }

    private func deleteEvent(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let (id, occurrence) = try eventID(arguments)
        try store.deleteEvent(id: id, occurrence: occurrence, futureEvents: try futureEvents(arguments))
        return .object(["deleted": .bool(true), "eventId": .string(Arguments.string(arguments, "eventId") ?? id)])
    }

    private func futureEvents(_ arguments: [String: ToolJSON]) throws -> Bool {
        switch Arguments.string(arguments, "span") ?? "thisEvent" {
        case "thisEvent": false
        case "futureEvents": true
        default: throw Problem.invalid("span is thisEvent or futureEvents.")
        }
    }

    /// An occurrence of a recurring event is `<event ID>@<its start>`, since the occurrences share
    /// the event's own ID.
    static func eventID(_ event: MacEvent) -> String {
        guard let occurrence = event.occurrence else { return event.id }
        return "\(event.id)@\(CalendarTime.rfc3339(occurrence, in: TimeZone(identifier: "UTC")!))"
    }

    private func eventID(_ arguments: [String: ToolJSON]) throws -> (String, Date?) {
        let text = try Arguments.required(arguments, "eventId")
        if let at = text.lastIndex(of: "@"), let occurrence = CalendarTime.absolute(String(text[text.index(after: at)...])) {
            return (String(text[..<at]), occurrence)
        }
        return (text, nil)
    }

    private func encode(_ event: MacEvent, zone: TimeZone, full: Bool) -> ToolJSON {
        let shown = event.timeZone ?? zone
        var fields: [String: ToolJSON] = [
            "id": .string(Self.eventID(event)),
            "calendarId": .string(event.calendarID),
            "calendar": .string(event.calendarTitle),
            "summary": .string(event.title),
            "allDay": .bool(event.allDay)
        ]
        if event.allDay {
            fields["startTime"] = .string(CalendarTime.dateString(event.start, in: shown))
            fields["endTime"] = .string(CalendarTime.dateString(event.end.addingTimeInterval(-1), in: shown))
        } else {
            fields["startTime"] = .string(CalendarTime.rfc3339(event.start, in: shown))
            fields["endTime"] = .string(CalendarTime.rfc3339(event.end, in: shown))
        }
        if let zone = event.timeZone { fields["timeZone"] = .string(zone.identifier) }
        if let location = event.location, !location.isEmpty { fields["location"] = .string(location) }
        if event.isRecurring { fields["recurring"] = .bool(true) }
        if let availability = event.availability { fields["availability"] = .string(availability) }
        if full {
            if let notes = event.notes, !notes.isEmpty { fields["description"] = .string(notes) }
            if let url = event.url { fields["url"] = .string(url.absoluteString) }
            if !event.alarmMinutes.isEmpty { fields["alertMinutes"] = .array(event.alarmMinutes.map { .integer(Int64($0)) }) }
            if !event.attendees.isEmpty { fields["attendees"] = .array(event.attendees.map(person)) }
            if let organizer = event.organizer { fields["organizer"] = person(organizer) }
        }
        return .object(fields)
    }

    private func person(_ person: MacEvent.Person) -> ToolJSON {
        var fields: [String: ToolJSON] = [:]
        if let name = person.name { fields["name"] = .string(name) }
        if let email = person.email { fields["email"] = .string(email) }
        if let status = person.status { fields["status"] = .string(status) }
        return .object(fields)
    }

    // MARK: Reminders

    private func listReminders(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var query = MacReminderQuery()
        if let list = Arguments.string(arguments, "listId") { query.listIDs = [list] }
        guard let status = MacReminderQuery.Status(rawValue: Arguments.string(arguments, "status") ?? "incomplete") else {
            throw Problem.invalid("status is incomplete, completed, or all.")
        }
        query.status = status
        query.from = try Arguments.string(arguments, "dueAfter").map { try time($0, in: timeZone, name: "dueAfter").date }
        query.to = try Arguments.string(arguments, "dueBefore").map { try time($0, in: timeZone, name: "dueBefore").date }
        let words = Arguments.string(arguments, "query")?.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        let found = try await store.reminders(query).filter { reminder in
            let text = (reminder.title + "\n" + (reminder.notes ?? "")).lowercased()
            return words.allSatisfy(text.contains)
        }
        let limit = Arguments.pageSize(arguments, range: 1...250, fallback: 50)
        var result: [String: ToolJSON] = ["reminders": .array(found.prefix(limit).map(encode))]
        if found.count > limit { result["more"] = .integer(Int64(found.count - limit)) }
        return .object(result)
    }

    private func createReminder(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        var change = MacReminderChange()
        change.title = try Arguments.required(arguments, "title")
        change.listID = Arguments.string(arguments, "listId")
        change.notes = Arguments.string(arguments, "notes")
        if let due = Arguments.string(arguments, "dueDate") {
            let parsed = try time(due, in: timeZone, name: "dueDate")
            let components: Set<Calendar.Component> = parsed.dateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var dateComponents = calendar.dateComponents(components, from: parsed.date)
            dateComponents.calendar = calendar
            dateComponents.timeZone = parsed.dateOnly ? nil : timeZone
            change.due = dateComponents
        }
        if let priority = Arguments.string(arguments, "priority") {
            // EventKit's scale: 0 none, 9 low, 5 medium, 1 high (RFC 5545).
            guard let value = ["none": 0, "low": 9, "medium": 5, "high": 1][priority] else {
                throw Problem.invalid("priority is none, low, medium, or high.")
            }
            change.priority = value
        }
        return encode(try store.saveReminder(change))
    }

    private func completeReminder(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        var change = MacReminderChange()
        change.id = try Arguments.required(arguments, "reminderId")
        change.completed = Arguments.bool(arguments["completed"]) ?? true
        return encode(try store.saveReminder(change))
    }

    private func encode(_ reminder: MacReminder) -> ToolJSON {
        var fields: [String: ToolJSON] = [
            "id": .string(reminder.id), "listId": .string(reminder.listID), "list": .string(reminder.listTitle),
            "title": .string(reminder.title), "completed": .bool(reminder.completed)
        ]
        if let notes = reminder.notes, !notes.isEmpty { fields["notes"] = .string(notes) }
        if let due = reminder.due, let text = Self.dueText(due, zone: timeZone) { fields["dueDate"] = .string(text) }
        switch reminder.priority {
        case 1...4: fields["priority"] = .string("high")
        case 5: fields["priority"] = .string("medium")
        case 6...9: fields["priority"] = .string("low")
        default: break
        }
        if let done = reminder.completionDate { fields["completionDate"] = .string(CalendarTime.rfc3339(done, in: timeZone)) }
        if let url = reminder.url { fields["url"] = .string(url.absoluteString) }
        return .object(fields)
    }

    /// A due day as `2026-04-30`, and with its time in the Mac's zone when it has one.
    static func dueText(_ due: DateComponents, zone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = due.timeZone ?? zone
        guard let date = calendar.date(from: due) else { return nil }
        return due.hour == nil ? CalendarTime.dateString(date, in: calendar.timeZone) : CalendarTime.rfc3339(date, in: zone)
    }

    // MARK: Contacts

    private func searchContacts(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let query = try Arguments.required(arguments, "query")
        let limit = Arguments.pageSize(arguments, range: 1...100, fallback: 20)
        return .object(["contacts": .array(try store.contacts(matching: query, limit: limit).map { encode($0, full: false) })])
    }

    private func getContact(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let id = try Arguments.required(arguments, "contactId")
        guard let contact = try store.contact(id: id) else { throw MacDataError.notFound(id) }
        return encode(contact, full: true)
    }

    private func encode(_ contact: MacContact, full: Bool) -> ToolJSON {
        var fields: [String: ToolJSON] = ["id": .string(contact.id)]
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { fields["name"] = .string(name) }
        if !contact.givenName.isEmpty { fields["givenName"] = .string(contact.givenName) }
        if !contact.familyName.isEmpty { fields["familyName"] = .string(contact.familyName) }
        for (key, value) in [("nickname", contact.nickname), ("organization", contact.organization), ("jobTitle", contact.jobTitle)] {
            if let value, !value.isEmpty { fields[key] = .string(value) }
        }
        func labeled(_ values: [MacContact.Labeled]) -> ToolJSON {
            .array(values.map { item in
                item.label.map { .object(["label": .string($0), "value": .string(item.value)]) } ?? .object(["value": .string(item.value)])
            })
        }
        if !contact.emails.isEmpty { fields["emails"] = labeled(contact.emails) }
        if !contact.phones.isEmpty { fields["phones"] = labeled(contact.phones) }
        if full {
            if !contact.addresses.isEmpty { fields["addresses"] = labeled(contact.addresses) }
            if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
                fields["birthday"] = .string(birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) }
                    ?? String(format: "--%02d-%02d", month, day))
            }
        }
        return .object(fields)
    }

    // MARK: Time

    private func zone(_ arguments: [String: ToolJSON]) throws -> TimeZone {
        guard let name = Arguments.string(arguments, "timeZone") else { return timeZone }
        guard let zone = TimeZone(identifier: name) else { throw Problem.invalid("Unknown time zone: \(name)") }
        return zone
    }

    private func time(_ text: String, in zone: TimeZone, name: String) throws -> (date: Date, dateOnly: Bool) {
        guard let parsed = CalendarTime.parse(text, in: zone) else {
            throw Problem.invalid("\(name) is a date and time such as 2026-04-30T10:00:00.")
        }
        return (parsed.date, parsed.dateOnly)
    }
}
