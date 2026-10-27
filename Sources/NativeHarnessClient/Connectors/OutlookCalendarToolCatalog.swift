import Foundation
import YardletAgentTools

/// Yardlet's own Outlook calendar server: the tools it offers each signed-in Microsoft account, over
/// Microsoft Graph's calendar API (learn.microsoft.com/graph/api/resources/calendar). Names and
/// arguments follow Yardlet's Google Calendar tools (`list_events`, `suggest_time`, `create_event`
/// with `summary`, `startTime`, `endTime`, `timeZone`, `attendeeEmails`), so a model uses both
/// calendars alike. Each reaches a harness under the account's slug (`outlook_calendar_list_events`).
///
/// One delegated permission that needs no administrator's consent, `Calendars.ReadWrite`; free and
/// busy times come from `getSchedule` with it. Creating, changing, deleting, and answering an event
/// ask the person before every call through the harness's own approval (`approvalRequired`).
enum OutlookCalendarToolCatalog {
    static let listCalendars = "list_calendars"
    static let listEvents = "list_events"
    static let getEvent = "get_event"
    static let suggestTime = "suggest_time"
    static let createEvent = "create_event"
    static let updateEvent = "update_event"
    static let deleteEvent = "delete_event"
    static let respondToEvent = "respond_to_event"

    static let scopes = ["Calendars.ReadWrite"]

    static let approvalRequired: Set<String> = [createEvent, updateEvent, deleteEvent, respondToEvent]

    static let showAs = ["free", "tentative", "busy", "oof", "workingElsewhere"]
    static let responses = ["accepted", "declined", "tentative"]

    private typealias Schema = ConnectorToolSchema

    private static let calendarID = Schema.string("A calendar ID from list_calendars. Defaults to the account's own calendar.")
    private static let timeZone = Schema.string("IANA time zone (Asia/Seoul) for times without an offset, and for the "
        + "answer. Defaults to the Mac's.")

    private static let eventFields: [String: ToolJSON] = [
        "summary": Schema.string("Title."),
        "startTime": Schema.string("Start (ISO 8601). Local time without an offset is read in timeZone. A date alone with allDay."),
        "endTime": Schema.string("End, as startTime. For an all-day event, the last day."),
        "timeZone": timeZone,
        "allDay": Schema.boolean("An all-day event."),
        "description": Schema.string("Body text."),
        "location": Schema.string("Where it takes place."),
        "attendeeEmails": Schema.stringArray("Required attendees. Outlook sends each an invitation."),
        "optionalAttendeeEmails": Schema.stringArray("Optional attendees."),
        "addTeamsMeeting": Schema.boolean("Add a Microsoft Teams meeting link."),
        "reminderMinutes": Schema.integer("Minutes before the start to remind.", 0...40_320),
        "showAs": Schema.enumeration("free, tentative, busy (default), oof, or workingElsewhere.", showAs)
    ]

    static let tools: [ToolJSON] = [
        Schema.tool(listCalendars, "List calendars",
                    "Lists the account's calendars, with each one's ID, name, owner, and whether it can be changed.",
                    properties: [:], readOnly: true),
        Schema.tool(listEvents, "List events",
                    "Lists events on one calendar within a time range, recurring events expanded, in start order. "
                        + "Defaults to the account's calendar and the 7 days from now.",
                    properties: [
                        "calendarId": calendarID,
                        "startTime": Schema.string("Range start (ISO 8601). Defaults to now."),
                        "endTime": Schema.string("Range end (ISO 8601). Defaults to startTime plus 7 days."),
                        "timeZone": timeZone,
                        "pageSize": Schema.integer("Events per page, 1 to 250. Defaults to 50.", 1...250),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], readOnly: true),
        Schema.tool(getEvent, "Get event", "Reads one event with its attendees' answers and body.",
                    properties: ["eventId": Schema.string("The event's ID."), "timeZone": timeZone],
                    required: ["eventId"], readOnly: true),
        Schema.tool(suggestTime, "Suggest time",
                    "Finds times when the account and every attendee are free, from their Outlook free and busy times, "
                        + "within working hours if given.",
                    properties: [
                        "attendeeEmails": Schema.stringArray("Attendees' addresses."),
                        "startTime": Schema.string("Search from (ISO 8601)."),
                        "endTime": Schema.string("Search until (ISO 8601)."),
                        "durationMinutes": Schema.integer("Length of the meeting. Defaults to 30.", 5...1_440),
                        "timeZone": timeZone,
                        "preferences": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "startHour": Schema.string("Working hours start, HH:mm."),
                                "endHour": Schema.string("Working hours end, HH:mm."),
                                "excludeWeekends": Schema.boolean("Leave out Saturdays and Sundays."),
                                "pageSize": Schema.integer("Times to suggest, 1 to 20. Defaults to 5.", 1...20)
                            ])
                        ])
                    ], required: ["attendeeEmails", "startTime", "endTime"], readOnly: true),
        Schema.tool(createEvent, "Create event",
                    "Creates an event. Outlook sends invitations to the attendees.",
                    properties: eventFields.merging(["calendarId": calendarID]) { $1 },
                    required: ["summary", "startTime", "endTime"], readOnly: false, openWorld: true),
        Schema.tool(updateEvent, "Update event",
                    "Changes only the fields given. Moving only the start keeps the length. Outlook sends the "
                        + "attendees an update.",
                    properties: eventFields.merging([
                        "eventId": Schema.string("The event's ID."),
                        "addedAttendeeEmails": Schema.stringArray("Attendees to add."),
                        "removedAttendeeEmails": Schema.stringArray("Attendees to remove.")
                    ]) { $1 }.filter { $0.key != "attendeeEmails" && $0.key != "optionalAttendeeEmails" },
                    required: ["eventId"], readOnly: false, destructive: true, openWorld: true),
        Schema.tool(deleteEvent, "Delete event",
                    "Deletes an event. For a meeting the account organizes, Outlook sends the attendees a cancellation.",
                    properties: ["eventId": Schema.string("The event's ID.")],
                    required: ["eventId"], readOnly: false, destructive: true, openWorld: true),
        Schema.tool(respondToEvent, "Respond to event",
                    "Answers an invitation: accepted, declined, or tentative, with an optional note to the organizer.",
                    properties: [
                        "eventId": Schema.string("The event's ID."),
                        "responseStatus": Schema.enumeration("accepted, declined, or tentative.", responses),
                        "responseComment": Schema.string("A note to the organizer."),
                        "sendResponse": Schema.boolean("Tell the organizer. Defaults to true.")
                    ], required: ["eventId", "responseStatus"], readOnly: false, openWorld: true)
    ]
}
