import Foundation
import YardletAgentTools

/// Yardlet's own Google Calendar server: the tools it offers each signed-in Google account, named
/// and shaped as the claude.ai Google Calendar connector names them (`list_calendars`,
/// `list_events`, `search_events`, `get_event`, `suggest_time`, `create_event`, `update_event`,
/// `delete_event`, `respond_to_event`, which are Google's Calendar MCP server's), over the public
/// Calendar API v3. Each reaches a harness under the account's slug (`calendar_list_events`).
///
/// Three scopes, all sensitive and none restricted: the calendar list, events on every calendar
/// the person can reach (`calendar.events`, which reads, writes, and responds), and free/busy for
/// `suggest_time`. Creating, changing, deleting, and answering an event ask the person before
/// every call through the harness's own approval (`approvalRequired`).
enum GoogleCalendarToolCatalog {
    static let listCalendars = "list_calendars"
    static let listEvents = "list_events"
    static let searchEvents = "search_events"
    static let getEvent = "get_event"
    static let suggestTime = "suggest_time"
    static let createEvent = "create_event"
    static let updateEvent = "update_event"
    static let deleteEvent = "delete_event"
    static let respondToEvent = "respond_to_event"

    static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    static let freeBusyScope = "https://www.googleapis.com/auth/calendar.events.freebusy"
    static let scopes = [calendarListScope, eventsScope, freeBusyScope]

    static let approvalRequired: Set<String> = [createEvent, updateEvent, deleteEvent, respondToEvent]

    static let notificationLevels = ["NONE", "EXTERNAL_ONLY", "ALL"]

    static let tools: [ToolJSON] = [
        tool(listCalendars, "List calendars",
             "Lists the calendars the account owns or subscribes to, with each one's ID, name, time zone, and access role.",
             properties: [
                "pageSize": integer("Calendars per page, 1 to 250. Defaults to 100.", 1...250),
                "pageToken": string("nextPageToken from the previous page.")
             ], readOnly: true),
        tool(listEvents, "List events",
             "Lists events on one calendar within a time range, recurring events expanded. Defaults to the primary "
                + "calendar and the 7 days from now.",
             properties: [
                "calendarId": calendarID,
                "startTime": string("Range start (ISO 8601). Local time without an offset is read in timeZone, or the "
                    + "Mac's time zone. Defaults to now."),
                "endTime": string("Range end (ISO 8601), as startTime. Defaults to startTime plus 7 days."),
                "timeZone": timeZone,
                "fullText": string("Words matched against the title, description, location, and attendees."),
                "eventType": .object(["type": .string("array"), "description": .string("Event types to include."),
                                      "items": .object(["type": .string("string"), "enum": .array(eventTypes.map(ToolJSON.string))])]),
                "orderBy": enumeration("startTime (default), startTimeDesc, or lastModified.",
                                       ["default", "startTime", "startTimeDesc", "lastModified"]),
                "pageSize": integer("Events per page, 1 to 250. Defaults to 25.", 1...250),
                "pageToken": string("nextPageToken from the previous page.")
             ], readOnly: true),
        tool(searchEvents, "Search events",
             "Searches the primary calendar's events within a year either side of today by words in their title, "
                + "description, location, or attendees.",
             properties: [
                "query": string("Words to search for."),
                "pageSize": integer("Events per page, 1 to 250. Defaults to 25.", 1...250),
                "pageToken": string("nextPageToken from the previous page.")
             ], required: ["query"], readOnly: true),
        tool(getEvent, "Get event",
             "Gets one event with its attendees, conference link, and description.",
             properties: ["calendarId": calendarID, "eventId": string("The event's ID.")],
             required: ["eventId"], readOnly: true),
        tool(suggestTime, "Suggest time",
             "Finds free times of a given length that every attendee and the account have in common, from their free/busy.",
             properties: [
                "attendeeEmails": stringArray("Attendees' email addresses; the account is included."),
                "startTime": string("Search start (ISO 8601), as list_events' startTime."),
                "endTime": string("Search end (ISO 8601)."),
                "durationMinutes": integer("Length of each free time in minutes. Defaults to 30.", 5...1_440),
                "timeZone": timeZone,
                "preferences": .object([
                    "type": .string("object"),
                    "description": .string("Working hours and how many times to return."),
                    "properties": .object([
                        "startHour": string("Earliest start of day, \"HH:mm\"."),
                        "endHour": string("Latest end of day, \"HH:mm\"."),
                        "excludeWeekends": boolean("Leave out Saturdays and Sundays."),
                        "pageSize": integer("Times to return, 1 to 20. Defaults to 5.", 1...20)
                    ])
                ])
             ], required: ["attendeeEmails", "startTime", "endTime"], readOnly: true),
        tool(createEvent, "Create event",
             "Creates an event, with attendees, a Google Meet link, reminders, or a recurrence when given, and returns it.",
             properties: eventProperties(creating: true), required: ["summary", "startTime", "endTime"],
             readOnly: false, openWorld: true),
        tool(updateEvent, "Update event",
             "Changes the given fields of an event; attendees are added or removed by email. Moving only the start keeps "
                + "the length.",
             properties: eventProperties(creating: false), required: ["eventId"], readOnly: false, openWorld: true),
        tool(deleteEvent, "Delete event",
             "Deletes an event.",
             properties: ["calendarId": calendarID, "eventId": string("The event's ID."), "notificationLevel": notificationLevel],
             required: ["eventId"], readOnly: false, destructive: true, openWorld: true),
        tool(respondToEvent, "Respond to event",
             "Answers an invitation for the account: accepted, declined, or tentative, with an optional comment.",
             properties: [
                "calendarId": calendarID,
                "eventId": string("The event's ID."),
                "responseStatus": enumeration("accepted, declined, or tentative.", ["accepted", "declined", "tentative"]),
                "responseComment": string("A note sent with the answer."),
                "notificationLevel": notificationLevel
             ], required: ["eventId", "responseStatus"], readOnly: false, openWorld: true)
    ]

    static let eventTypes = ["DEFAULT", "OUT_OF_OFFICE", "FOCUS_TIME", "WORKING_LOCATION", "BIRTHDAY", "FROM_GMAIL"]

    // MARK: Schema pieces

    private static var calendarID: ToolJSON {
        string("The calendar's ID, from list_calendars (often an email address). Defaults to the primary calendar.")
    }

    private static var timeZone: ToolJSON {
        string("An IANA time zone (Asia/Seoul) for times without an offset, when the person names one.")
    }

    private static var notificationLevel: ToolJSON {
        enumeration("Who Google emails about the change: NONE, EXTERNAL_ONLY, or ALL (default).", notificationLevels)
    }

    private static var attendees: ToolJSON {
        .object([
            "type": .string("array"),
            "description": .string("Attendees, each by email."),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "email": string("The attendee's email address."),
                    "displayName": string("The attendee's name."),
                    "optionalAttendee": boolean("Optional to attend.")
                ]),
                "required": .array([.string("email")])
            ])
        ])
    }

    private static func eventProperties(creating: Bool) -> [String: ToolJSON] {
        var properties: [String: ToolJSON] = [
            "calendarId": calendarID,
            "summary": string(creating ? "The title." : "A new title."),
            "startTime": string(creating
                ? "Start (ISO 8601, 2026-04-30T10:00:00). Local time without an offset is read in timeZone, or the Mac's time zone."
                : "A new start (ISO 8601)."),
            "endTime": string(creating ? "End (ISO 8601), as startTime." : "A new end (ISO 8601)."),
            "allDay": .object(["type": .string("boolean"),
                               "description": .string("All-day: the dates of startTime and endTime are used, endTime's day included.")]),
            "timeZone": timeZone,
            "description": string("The description; it can hold HTML."),
            "location": string("The location."),
            "addGoogleMeetUrl": boolean("Adds a Google Meet link."),
            "availability": enumeration("Whether it blocks time: AVAILABILITY_BUSY or AVAILABILITY_FREE.",
                                        ["AVAILABILITY_BUSY", "AVAILABILITY_FREE"]),
            "visibility": enumeration("default, public, or private.", ["default", "public", "private"]),
            "colorId": string("An event color ID, \"1\" to \"11\"."),
            "useDefaultReminders": boolean("Uses the calendar's default reminders."),
            "overrideReminders": .object([
                "type": .string("array"),
                "description": .string("Reminders in place of the calendar's defaults."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "method": enumeration("email or popup.", ["email", "popup"]),
                        "minutes": integer("Minutes before the start.", 0...40_320)
                    ]),
                    "required": .array([.string("method"), .string("minutes")])
                ])
            ]),
            "notificationLevel": notificationLevel
        ]
        if creating {
            properties["attendees"] = attendees
            properties["attendeeEmails"] = stringArray("Attendees by email alone, as well as or instead of attendees.")
            properties["recurrenceData"] = stringArray("Recurrence rules (RFC 5545): RRULE, RDATE, or EXDATE lines.")
        } else {
            properties["eventId"] = string("The event's ID.")
            properties["addedAttendees"] = attendees
            properties["addedAttendeeEmails"] = stringArray("Attendees to add by email alone.")
            properties["removedAttendeeEmails"] = stringArray("Attendees to remove, by email.")
        }
        return properties
    }

    private static func string(_ description: String) -> ToolJSON { ConnectorToolSchema.string(description) }

    private static func boolean(_ description: String) -> ToolJSON { ConnectorToolSchema.boolean(description) }

    private static func enumeration(_ description: String, _ values: [String]) -> ToolJSON {
        ConnectorToolSchema.enumeration(description, values)
    }

    private static func integer(_ description: String, _ range: ClosedRange<Int>) -> ToolJSON {
        ConnectorToolSchema.integer(description, range)
    }

    private static func stringArray(_ description: String) -> ToolJSON { ConnectorToolSchema.stringArray(description) }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: ToolJSON], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        ConnectorToolSchema.tool(name, title, description, properties: properties, required: required,
                              readOnly: readOnly, destructive: destructive, openWorld: openWorld)
    }
}
