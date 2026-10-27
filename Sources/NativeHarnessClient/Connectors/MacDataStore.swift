import Foundation

/// The Mac's calendars, reminders, and contacts as Yardlet's connectors read and write them
/// (docs/CONNECTORS.md, "Apple"). iCloud has no public OAuth API for them, so the connectors use what
/// the Mac keeps in sync: EventKit for calendars and reminders, Contacts for contacts. The macOS
/// platform layer provides the store (`MacEventKitStore`); tests give a store of their own, so no
/// test reads the person's data or brings up a privacy prompt.
protocol MacDataStoring: Sendable {
    /// Whether macOS lets Yardlet reach the kind of data, without asking.
    func access(_ kind: MacDataKind) -> MacDataAccess
    /// Asks macOS, which shows its prompt the first time only; true when Yardlet may read and write.
    func requestAccess(_ kind: MacDataKind) async throws -> Bool

    /// Event calendars for `.calendars`, reminder lists for `.reminders`.
    func calendars(_ kind: MacDataKind) throws -> [MacCalendarInfo]
    /// Events overlapping the range, recurring events as their occurrences; all calendars when
    /// `calendarIDs` is nil.
    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [MacEvent]
    /// One event, or one occurrence of a recurring event when `occurrence` is its start.
    func event(id: String, occurrence: Date?) throws -> MacEvent?
    func saveEvent(_ change: MacEventChange) throws -> MacEvent
    func deleteEvent(id: String, occurrence: Date?, futureEvents: Bool) throws

    func reminders(_ query: MacReminderQuery) async throws -> [MacReminder]
    func saveReminder(_ change: MacReminderChange) throws -> MacReminder

    /// Contacts whose name, email address, or phone number matches `text`.
    func contacts(matching text: String, limit: Int) throws -> [MacContact]
    func contact(id: String) throws -> MacContact?
}

enum MacDataKind: String, Sendable {
    case calendars
    case reminders
    case contacts

    /// The pane's name, as System Settings shows it.
    var settingsName: String {
        switch self {
        case .calendars: L10n.string("Calendars")
        case .reminders: L10n.string("Reminders")
        case .contacts: L10n.string("Contacts")
        }
    }
}

enum MacDataAccess: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    /// A device policy decides (Screen Time, a management profile).
    case restricted
    /// Calendars allowed to add events only, which reads nothing.
    case writeOnly
    /// This build cannot ask: it has no reason to show in the prompt (a build without Info.plist).
    case unavailable
}

enum MacDataError: Error, Equatable, LocalizedError {
    /// macOS does not let Yardlet reach the data.
    case notAllowed(MacDataKind, MacDataAccess)
    case notFound(String)
    /// The calendar or list does not take changes (a subscribed or birthday calendar).
    case readOnly(String)
    /// EventKit's or Contacts' own message.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let kind, .unavailable):
            L10n.format("This build of Yardlet can't ask macOS for %@ access.", kind.settingsName)
        case .notAllowed(let kind, .restricted):
            L10n.format("A device policy keeps Yardlet from %@.", kind.settingsName)
        case .notAllowed(let kind, _):
            L10n.format("macOS doesn't let Yardlet use %@. Turn Yardlet on in System Settings → Privacy & Security → %@, then try again.",
                        kind.settingsName, kind.settingsName)
        case .notFound(let id): "Nothing on this Mac has the ID \(id)."
        case .readOnly(let name): "\(name) doesn't take changes."
        case .failed(let message): message
        }
    }
}

/// A calendar or a reminder list.
struct MacCalendarInfo: Equatable, Sendable {
    var id: String
    var title: String
    /// The account it belongs to (iCloud, Google, On My Mac).
    var account: String
    var color: String?
    var allowsChanges: Bool
    /// Where new events or reminders go when none is named.
    var isDefault: Bool
}

struct MacEvent: Equatable, Sendable {
    struct Person: Equatable, Sendable {
        var name: String?
        var email: String?
        /// accepted, declined, tentative, pending, …
        var status: String?
    }

    var id: String
    /// Its start when it is one occurrence of a recurring event.
    var occurrence: Date?
    var calendarID: String
    var calendarTitle: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZone: TimeZone?
    var location: String?
    var notes: String?
    var url: URL?
    var isRecurring: Bool
    var attendees: [Person] = []
    var organizer: Person?
    /// busy, free, tentative, unavailable.
    var availability: String?
    /// Minutes before the start of each alert.
    var alarmMinutes: [Int] = []
}

/// A new event (no `id`) or a change to one: nil leaves a field as it is.
struct MacEventChange: Equatable, Sendable {
    var id: String?
    var occurrence: Date?
    var calendarID: String?
    var title: String?
    var start: Date?
    var end: Date?
    var allDay: Bool?
    var timeZone: TimeZone?
    var location: String?
    var notes: String?
    var url: URL?
    var alarmMinutes: [Int]?
    /// For a recurring event: this occurrence and those after it, rather than this one only.
    var futureEvents = false
}

struct MacReminder: Equatable, Sendable {
    var id: String
    var listID: String
    var listTitle: String
    var title: String
    var notes: String?
    /// The day it is due, and the time when it has one.
    var due: DateComponents?
    var priority: Int
    var completed: Bool
    var completionDate: Date?
    var url: URL?
}

struct MacReminderQuery: Equatable, Sendable {
    enum Status: String, Sendable {
        case incomplete
        case completed
        case all
    }

    var listIDs: [String]?
    var status: Status = .incomplete
    /// Due (incomplete) or completed (completed) within the range, when given.
    var from: Date?
    var to: Date?
}

/// A new reminder (no `id`) or a change to one: nil leaves a field as it is.
struct MacReminderChange: Equatable, Sendable {
    var id: String?
    var listID: String?
    var title: String?
    var notes: String?
    var due: DateComponents?
    var priority: Int?
    var completed: Bool?
}

struct MacContact: Equatable, Sendable {
    struct Labeled: Equatable, Sendable {
        var label: String?
        var value: String
    }

    var id: String
    var givenName: String
    var familyName: String
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var emails: [Labeled] = []
    var phones: [Labeled] = []
    var addresses: [Labeled] = []
    var birthday: DateComponents?
}
