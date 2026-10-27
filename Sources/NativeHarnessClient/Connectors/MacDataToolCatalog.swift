import Foundation
import YardletAgentTools

/// Apple Calendar: the calendars on this Mac (iCloud's and every account's the Calendar app has),
/// shaped as the Google Calendar connector's tools where EventKit can do the same. EventKit cannot
/// invite people or answer invitations, so there is no attendee field or `respond_to_event`.
/// Creating, changing, and deleting an event ask the person before every call.
enum MacCalendarToolCatalog {
    static let listCalendars = "list_calendars"
    static let listEvents = "list_events"
    static let searchEvents = "search_events"
    static let getEvent = "get_event"
    static let createEvent = "create_event"
    static let updateEvent = "update_event"
    static let deleteEvent = "delete_event"

    static let approvalRequired: Set<String> = [createEvent, updateEvent, deleteEvent]

    static let tools: [ToolJSON] = [
        tool(listCalendars, "List calendars",
             "Lists the calendars on this Mac with each one's ID, name, account, and whether it takes changes.",
             properties: [:], readOnly: true),
        tool(listEvents, "List events",
             "Lists events within a time range, recurring events as occurrences, on every calendar or one. Defaults to "
                + "the 7 days from now.",
             properties: [
                "calendarId": string("A calendar's ID, from list_calendars. Defaults to every calendar."),
                "startTime": string("Range start (ISO 8601). Local time without an offset is read in timeZone, or the "
                    + "Mac's time zone. Defaults to now."),
                "endTime": string("Range end (ISO 8601), as startTime. Defaults to startTime plus 7 days."),
                "timeZone": timeZone,
                "query": string("Words matched against the title, location, and notes."),
                "pageSize": GoogleToolSchema.integer("Events to return, 1 to 250. Defaults to 50.", 1...250)
             ], readOnly: true),
        tool(searchEvents, "Search events",
             "Searches every calendar's events within a year either side of today by words in their title, location, or notes.",
             properties: [
                "query": string("Words to search for."),
                "pageSize": GoogleToolSchema.integer("Events to return, 1 to 250. Defaults to 25.", 1...250)
             ], required: ["query"], readOnly: true),
        tool(getEvent, "Get event",
             "Gets one event with its notes, alerts, and attendees.",
             properties: ["eventId": eventID], required: ["eventId"], readOnly: true),
        tool(createEvent, "Create event",
             "Creates an event, with alerts when given, and returns it.",
             properties: eventProperties(creating: true), required: ["summary", "startTime", "endTime"], readOnly: false),
        tool(updateEvent, "Update event",
             "Changes the given fields of an event. Moving only the start keeps the length.",
             properties: eventProperties(creating: false), required: ["eventId"], readOnly: false),
        tool(deleteEvent, "Delete event",
             "Deletes an event, or for a recurring event this occurrence (or it and those after it).",
             properties: ["eventId": eventID, "span": span], required: ["eventId"], readOnly: false, destructive: true)
    ]

    private static var eventID: ToolJSON { string("The event's ID, from list_events or search_events.") }

    private static var timeZone: ToolJSON {
        string("An IANA time zone (Asia/Seoul) for times without an offset, when the person names one.")
    }

    private static var span: ToolJSON {
        GoogleToolSchema.enumeration("For a recurring event: thisEvent (default) or futureEvents.", ["thisEvent", "futureEvents"])
    }

    private static func eventProperties(creating: Bool) -> [String: ToolJSON] {
        var properties: [String: ToolJSON] = [
            "calendarId": string(creating ? "The calendar's ID, from list_calendars. Defaults to the Mac's default calendar."
                                          : "A calendar to move it to."),
            "summary": string(creating ? "The title." : "A new title."),
            "startTime": string(creating
                ? "Start (ISO 8601, 2026-04-30T10:00:00). Local time without an offset is read in timeZone, or the Mac's time zone."
                : "A new start (ISO 8601)."),
            "endTime": string(creating ? "End (ISO 8601), as startTime." : "A new end (ISO 8601)."),
            "allDay": GoogleToolSchema.boolean("All-day: the dates of startTime and endTime are used, endTime's day included."),
            "timeZone": timeZone,
            "location": string("The location."),
            "description": string("Notes."),
            "url": string("A link kept with the event."),
            "alertMinutes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(40_320)]),
                "description": .string(creating ? "Alerts, each in minutes before the start." : "Alerts in place of the event's.")
            ])
        ]
        if !creating {
            properties["eventId"] = eventID
            properties["span"] = span
        }
        return properties
    }

    fileprivate static func string(_ description: String) -> ToolJSON { GoogleToolSchema.string(description) }

    fileprivate static func tool(_ name: String, _ title: String, _ description: String,
                                 properties: [String: ToolJSON], required: [String] = [],
                                 readOnly: Bool, destructive: Bool = false) -> ToolJSON {
        // A change reaches the account's server (iCloud, Google, Exchange) as the Mac syncs it.
        GoogleToolSchema.tool(name, title, description, properties: properties, required: required,
                              readOnly: readOnly, destructive: destructive, openWorld: !readOnly)
    }
}

/// Apple Reminders: the reminder lists on this Mac. Adding a reminder and marking one done ask the
/// person before every call.
enum MacRemindersToolCatalog {
    static let listReminderLists = "list_reminder_lists"
    static let listReminders = "list_reminders"
    static let createReminder = "create_reminder"
    static let completeReminder = "complete_reminder"

    static let approvalRequired: Set<String> = [createReminder, completeReminder]

    static let priorities = ["none", "low", "medium", "high"]

    static let tools: [ToolJSON] = [
        MacCalendarToolCatalog.tool(listReminderLists, "List reminder lists",
                                    "Lists the reminder lists on this Mac with each one's ID, name, and account.",
                                    properties: [:], readOnly: true),
        MacCalendarToolCatalog.tool(listReminders, "List reminders",
                                    "Lists reminders, those not done by default, on every list or one, with their due date, "
                                        + "priority, and notes.",
                                    properties: [
                                        "listId": string("A list's ID, from list_reminder_lists. Defaults to every list."),
                                        "status": GoogleToolSchema.enumeration("incomplete (default), completed, or all.",
                                                                               ["incomplete", "completed", "all"]),
                                        "dueBefore": string("Only those due (or, for completed ones, done) before this "
                                            + "time (ISO 8601)."),
                                        "dueAfter": string("Only those due (or done) after this time (ISO 8601)."),
                                        "query": string("Words matched against the title and notes."),
                                        "pageSize": GoogleToolSchema.integer("Reminders to return, 1 to 250. Defaults to 50.", 1...250)
                                    ], readOnly: true),
        MacCalendarToolCatalog.tool(createReminder, "Create reminder",
                                    "Adds a reminder to a list, with a due date, priority, and notes when given.",
                                    properties: [
                                        "title": string("What to do."),
                                        "listId": string("The list's ID. Defaults to the Mac's default list."),
                                        "notes": string("Notes."),
                                        "dueDate": string("When it is due: a date (2026-04-30) or a date and time "
                                            + "(2026-04-30T09:00:00), read in the Mac's time zone without an offset."),
                                        "priority": GoogleToolSchema.enumeration("none (default), low, medium, or high.", priorities)
                                    ], required: ["title"], readOnly: false),
        MacCalendarToolCatalog.tool(completeReminder, "Complete reminder",
                                    "Marks a reminder done, or not done again with completed false.",
                                    properties: [
                                        "reminderId": string("The reminder's ID, from list_reminders."),
                                        "completed": GoogleToolSchema.boolean("false to mark it not done. Defaults to true.")
                                    ], required: ["reminderId"], readOnly: false)
    ]

    private static func string(_ description: String) -> ToolJSON { GoogleToolSchema.string(description) }
}

/// Apple Contacts: the contacts on this Mac, read only.
enum MacContactsToolCatalog {
    static let searchContacts = "search_contacts"
    static let getContact = "get_contact"

    static let tools: [ToolJSON] = [
        MacCalendarToolCatalog.tool(searchContacts, "Search contacts",
                                    "Finds contacts on this Mac by name, email address, or phone number, with their emails "
                                        + "and phone numbers.",
                                    properties: [
                                        "query": GoogleToolSchema.string("A name, an email address, or a phone number."),
                                        "pageSize": GoogleToolSchema.integer("Contacts to return, 1 to 100. Defaults to 20.", 1...100)
                                    ], required: ["query"], readOnly: true),
        MacCalendarToolCatalog.tool(getContact, "Get contact",
                                    "Gets one contact with every email, phone number, address, organization, and birthday.",
                                    properties: ["contactId": GoogleToolSchema.string("The contact's ID, from search_contacts.")],
                                    required: ["contactId"], readOnly: true)
    ]
}
