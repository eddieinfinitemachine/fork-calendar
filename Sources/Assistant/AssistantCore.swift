import Foundation

// The Claude assistant's engine: Messages API request shape, the tool-use
// loop, the read tools, and the plan builder for the write tools. No
// SwiftUI, no CalendarStore — the calendar comes in through
// `AssistantDataSource` and the network through `AssistantTransport`, so the
// whole loop can be driven by canned responses (see the README's
// "Claude assistant" section). Assistant.swift wires it to the app.

// MARK: - JSON

/// A JSON value. Assistant turns are echoed back to the API exactly as they
/// arrived (thinking blocks included), so they're kept as JSON, not models.
enum AJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AJSON])
    case object([String: AJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: AJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> AJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [AJSON]? { if case .array(let a) = self { return a }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default: return nil
        }
    }

    /// Sorted keys: tool definitions and results serialize byte-identically
    /// every time, which prompt caching depends on.
    func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("null".utf8)
    }

    var compactString: String { String(decoding: encoded(), as: UTF8.self) }
}

extension AJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                 ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(integerLiteral v: Int) { self = .int(v) }
    init(arrayLiteral elements: AJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, AJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

// MARK: - Models

enum AssistantModel {
    static let defaultID = "claude-opus-5-5"
    static let all: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 — most capable"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 — faster"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 — fastest"),
    ]

    /// Server-side refusal fallback (`fallbacks: "default"`) exists for the
    /// Opus and Sonnet lines on the Claude API; Haiku 5.5 has none.
    static func supportsFallbacks(_ id: String) -> Bool {
        id.hasPrefix("claude-opus") || id.hasPrefix("claude-sonnet")
    }
}

// MARK: - Errors

enum AssistantError: LocalizedError, Equatable {
    case noKey
    case invalidKey
    case permission(String)
    case modelNotFound(String)
    case billing
    case rateLimited
    case overloaded
    case badRequest(String)
    case server(Int, String)
    case network(String)
    case refused
    case truncated
    case tooManySteps

    var errorDescription: String? {
        switch self {
        case .noKey: return "Set your Anthropic API key in Settings to use the assistant."
        case .invalidKey: return "Anthropic didn't accept the API key. Check it in Settings."
        case .permission(let m): return "This API key isn't allowed to do that (\(m))."
        case .modelNotFound(let model): return "The model \(model) isn't available to this API key. Pick another in Settings."
        case .billing: return "Anthropic reported a billing problem with this API key's account."
        case .rateLimited: return "Anthropic's rate limit was hit. Wait a moment and try again."
        case .overloaded: return "Claude is overloaded right now. Try again in a minute."
        case .badRequest(let m): return "The request was rejected: \(m)"
        case .server(let code, let m): return "Anthropic error \(code)\(m.isEmpty ? "" : ": \(m)")."
        case .network(let m): return "Couldn't reach Anthropic — \(m)"
        case .refused: return "Claude declined this request."
        case .truncated: return "Claude's reply was cut off. Try a smaller request."
        case .tooManySteps: return "That took too many steps. Try a narrower request."
        }
    }

    /// The fix is in Settings (key / model): the palette links there.
    var needsSettings: Bool {
        switch self {
        case .noKey, .invalidKey, .modelNotFound, .permission: return true
        default: return false
        }
    }

    /// Worth one automatic retry.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded: return true
        case .server(let code, _): return code >= 500
        default: return false
        }
    }

    /// Map an HTTP error response from the Messages API.
    static func from(status: Int, body: Data, model: String) -> AssistantError {
        let json = try? JSONDecoder().decode(AJSON.self, from: body)
        let message = json?["error"]?["message"]?.string ?? ""
        switch status {
        case 400: return .badRequest(message.isEmpty ? "HTTP 400" : message)
        case 401: return .invalidKey
        case 402: return .billing
        case 403: return .permission(message.isEmpty ? "HTTP 403" : message)
        case 404: return .modelNotFound(model)
        case 429: return .rateLimited
        case 529: return .overloaded
        default: return .server(status, message)
        }
    }
}

// MARK: - Transport

/// One Messages API call. The real one is `AnthropicTransport` (URLSession);
/// tests pass canned responses.
@MainActor
protocol AssistantTransport: AnyObject {
    func send(_ body: AJSON, betas: [String]) async throws -> AJSON
}

// MARK: - Calendar data

/// What the assistant can see of the calendar. Read-only on purpose: the
/// assistant never mutates anything — only the confirmed plan does, through
/// CalendarStore (Assistant.swift).
@MainActor
protocol AssistantDataSource: AnyObject {
    var ownerEmails: [String] { get }
    /// Sidebar order.
    var allCalendars: [CalCalendar] { get }
    func isVisible(_ calendar: CalCalendar) -> Bool
    var defaultCalendar: CalCalendar? { get }
    /// Every cached event: calendar key → event id → record.
    var records: [String: [String: EventRecord]] { get }
    /// Local calendar (time zone + week start).
    var calendar: Calendar { get }
    var defaultDurationMinutes: Int { get }
    var guestNotifyPolicy: GuestNotifyPolicy { get }
    var rsvpNotifyOrganizer: Bool { get }
    var now: Date { get }
    /// Make sure `interval` is synced before reading it.
    func ensureLoaded(_ interval: DateInterval) async
}

struct EventRef: Hashable {
    let calendarKey: String
    let eventID: String
}

/// One step of the plan the owner confirms.
struct PlannedAction: Identifiable {
    struct NewEvent {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var calendarKey: String
        var attendees: [String]
        var location: String?
        var notes: String?
        var addMeet: Bool
    }

    struct Changes {
        var title: String?
        var location: String?
        var notes: String?
        var addAttendees: [String] = []
        var removeAttendees: [String] = []
    }

    enum Kind {
        case create(NewEvent)
        case move(EventRef, start: Date, end: Date)
        case delete(EventRef)
        /// `instanceOnly`: this occurrence of a repeating event, not the series.
        case rsvp(EventRef, ParticipantStatus, instanceOnly: Bool)
        case update(EventRef, Changes)
    }

    let id = UUID()
    let kind: Kind
    /// "Create", "Move", "Delete", "Decline", "Accept", "Maybe", "Update".
    let verb: String
    let title: String
    let when: String
    let details: [String]
    /// Came from propose_cancel_event (counted as "cancelled" afterwards).
    let isCancel: Bool
    /// Changes something other guests would be emailed about.
    let touchesGuests: Bool
    /// iCalUID, to keep two steps off copies of one meeting.
    let meetingUID: String?

    var ref: EventRef? {
        switch kind {
        case .create: return nil
        case .move(let r, _, _), .delete(let r), .rsvp(let r, _, _), .update(let r, _): return r
        }
    }

    var summary: String { ([verb, title, when] + details).joined(separator: " · ") }
}

// MARK: - Tools

@MainActor
final class AssistantToolbox {
    let source: AssistantDataSource
    /// The plan built from propose_* calls since the owner's latest message.
    private(set) var plan: [PlannedAction] = []
    /// Everything the owner typed: an email address they typed may be
    /// invited even if it's not in the people directory.
    private var ownerText = ""

    private var eventHandles: [EventRef: String] = [:]
    private var handleEvents: [String: EventRef] = [:]
    private var calendarHandles: [String: String] = [:]
    private var handleCalendars: [String: String] = [:]

    init(source: AssistantDataSource) {
        self.source = source
    }

    func beginOwnerMessage(_ text: String) {
        plan = []
        ownerText += "\n" + text.lowercased()
    }

    // MARK: Ids handed to the model

    func handle(for ref: EventRef) -> String {
        if let h = eventHandles[ref] { return h }
        let h = "e\(eventHandles.count + 1)"
        eventHandles[ref] = h
        handleEvents[h] = ref
        return h
    }

    func calendarHandle(_ key: String) -> String {
        if let h = calendarHandles[key] { return h }
        let h = "c\(calendarHandles.count + 1)"
        calendarHandles[key] = h
        handleCalendars[h] = key
        return h
    }

    // MARK: Definitions

    static let readTools: Set<String> = ["list_calendars", "list_events", "find_free_time", "search_people"]

    /// Fixed order and content: tools render first in the prompt, so any
    /// change here would invalidate the cache.
    static let definitions: [AJSON] = [
        [
            "name": "list_calendars",
            "description": "List the owner's calendars with their ids, account, whether the owner can add events to them (writable), whether they're shown in the app (visible), and which one is the default for new events. Call this when the owner names a calendar or you need a calendar id.",
            "input_schema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_events",
            "description": "List events between start and end on the owner's calendars, sorted by start. Each event has its id (use it with the propose_* tools), title, start/end (ISO 8601 with offset), all_day, calendar name and id, owner_is_organizer, my_rsvp (the owner's response: accepted, tentative, declined, needsAction, or not_invited), organizer, other attendees with their responses, recurring, has_video_link, can_edit, and duplicate_of when it's another copy of a meeting already listed. Call this before proposing changes to existing events and to answer questions about the schedule. Only calendars shown in the app are included unless include_hidden_calendars is true.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "start": ["type": "string", "description": "Range start, ISO 8601 (e.g. 2026-10-19T00:00:00-04:00) or a date (2026-10-19 = local midnight)."],
                    "end": ["type": "string", "description": "Range end (exclusive), same formats."],
                    "query": ["type": "string", "description": "Optional: only events whose title, location, organizer or attendee names/emails contain this text (case-insensitive)."],
                    "include_hidden_calendars": ["type": "boolean", "description": "Also include calendars the owner has hidden in the app. Default false."],
                ],
                "required": ["start", "end"],
            ],
        ],
        [
            "name": "find_free_time",
            "description": "Find free slots of at least duration_minutes between start and end on the owner's visible calendars (busy = timed events the owner hasn't declined; all-day events and events marked free don't block). With working_hours_only (default true) only weekdays 9:00–18:00 local are considered. Past times are never returned. Call this before proposing a new meeting time when the owner hasn't given an exact time.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "start": ["type": "string", "description": "Search window start, ISO 8601 or a date."],
                    "end": ["type": "string", "description": "Search window end, ISO 8601 or a date (exclusive)."],
                    "duration_minutes": ["type": "integer", "description": "Minimum slot length in minutes."],
                    "working_hours_only": ["type": "boolean", "description": "Only weekdays 9:00–18:00. Default true."],
                ],
                "required": ["start", "end", "duration_minutes"],
            ],
        ],
        [
            "name": "search_people",
            "description": "Look up people the owner has met with (attendees and organizers of the owner's events from the last and next 90 days) by name or email fragment. Returns names, email addresses and how often they appear. Call this to turn a name like \"Amy\" into an email address before inviting someone. If nobody or several different people match, ask the owner.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Name or part of an email address."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "propose_create_event",
            "description": "Propose creating a new event. Nothing is created until the owner confirms the plan. Use the owner's default calendar unless they asked for another. Attendees must be email addresses returned by search_people or list_events, or typed by the owner.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO 8601 with offset; for all_day events a date (YYYY-MM-DD)."],
                    "end": ["type": "string", "description": "ISO 8601 with offset; for all_day events the day after the last day (exclusive)."],
                    "all_day": ["type": "boolean", "description": "Default false."],
                    "calendar_id": ["type": "string", "description": "From list_calendars. Default: the owner's default calendar."],
                    "attendees": ["type": "array", "items": ["type": "string"], "description": "Guest email addresses to invite."],
                    "location": ["type": "string"],
                    "description": ["type": "string"],
                    "add_google_meet": ["type": "boolean", "description": "Create a Google Meet link. Default false."],
                ],
                "required": ["title", "start", "end"],
            ],
        ],
        [
            "name": "propose_move_event",
            "description": "Propose moving an existing event (by id from list_events) to a new start and end. For a repeating event only that occurrence moves. Nothing changes until the owner confirms.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string"],
                    "new_start": ["type": "string", "description": "ISO 8601 with offset."],
                    "new_end": ["type": "string", "description": "ISO 8601 with offset."],
                ],
                "required": ["event_id", "new_start", "new_end"],
            ],
        ],
        [
            "name": "propose_cancel_event",
            "description": "Propose cancelling the owner's attendance at an event (by id from list_events). The app decides how: meetings the owner organizes (or with no other guests) are deleted; meetings someone else organizes are declined, never deleted. For a repeating event only that occurrence is affected. Nothing changes until the owner confirms.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string"],
                ],
                "required": ["event_id"],
            ],
        ],
        [
            "name": "propose_rsvp",
            "description": "Propose answering an invitation (by id from list_events) for the owner: accepted, tentative or declined. For a repeating event only that occurrence is answered. Nothing is sent until the owner confirms.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string"],
                    "response": ["type": "string", "enum": ["accepted", "tentative", "declined"]],
                ],
                "required": ["event_id", "response"],
            ],
        ],
        [
            "name": "propose_update_event",
            "description": "Propose editing an existing event (by id from list_events): title, location, description, and adding or removing guests by email. Only include the fields that change. For a repeating event only that occurrence changes. Nothing changes until the owner confirms.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "event_id": ["type": "string"],
                    "title": ["type": "string"],
                    "location": ["type": "string"],
                    "description": ["type": "string"],
                    "add_attendees": ["type": "array", "items": ["type": "string"]],
                    "remove_attendees": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["event_id"],
            ],
        ],
    ]

    /// Short status for the palette while a tool runs.
    func progressLabel(name: String, input: AJSON) -> String {
        switch name {
        case "list_events":
            if let s = input["start"]?.string.flatMap(parseTime), let e = input["end"]?.string.flatMap(parseTime) {
                return "Looking at \(rangeLabel(s, e))…"
            }
            return "Looking at your calendar…"
        case "list_calendars": return "Checking your calendars…"
        case "find_free_time": return "Finding free time…"
        case "search_people": return "Looking up “\(input["query"]?.string ?? "")”…"
        default: return "Drafting changes…"
        }
    }

    private func rangeLabel(_ s: Date, _ e: Date) -> String {
        let cal = source.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: s), to: cal.startOfDay(for: e)).day ?? 0
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: source.now)
        if let w = thisWeek, abs(s.timeIntervalSince(w.start)) < 3600 * 13, abs(e.timeIntervalSince(w.end)) < 3600 * 13 {
            return "this week"
        }
        if days <= 1 {
            if cal.isDate(s, inSameDayAs: source.now) { return "today" }
            return Self.fmt("EEEEMMMd", s, cal)
        }
        return Self.fmt("MMMd", s, cal) + " – " + Self.fmt("MMMd", e.addingTimeInterval(-1), cal)
    }

    // MARK: Dispatch

    struct ToolOutput {
        let content: String
        let isError: Bool
        static func ok(_ json: AJSON) -> ToolOutput { ToolOutput(content: json.compactString, isError: false) }
        static func ok(_ text: String) -> ToolOutput { ToolOutput(content: text, isError: false) }
        static func error(_ text: String) -> ToolOutput { ToolOutput(content: text, isError: true) }
    }

    func run(name: String, input: AJSON) async -> ToolOutput {
        switch name {
        case "list_calendars": return listCalendars()
        case "list_events": return await listEvents(input)
        case "find_free_time": return await findFreeTime(input)
        case "search_people": return searchPeople(input)
        case "propose_create_event": return proposeCreate(input)
        case "propose_move_event": return proposeMove(input)
        case "propose_cancel_event": return proposeCancel(input)
        case "propose_rsvp": return proposeRSVP(input)
        case "propose_update_event": return proposeUpdate(input)
        default: return .error("Unknown tool \(name).")
        }
    }

    // MARK: Read tools

    private func listCalendars() -> ToolOutput {
        let def = source.defaultCalendar?.calendarIdentifier
        let list: [AJSON] = source.allCalendars.map { c in
            [
                "id": .string(calendarHandle(c.calendarIdentifier)),
                "name": .string(c.title),
                "account": .string(c.accountID),
                "writable": .bool(c.allowsContentModifications),
                "visible": .bool(source.isVisible(c)),
                "is_default": .bool(c.calendarIdentifier == def),
                "primary": .bool(c.isPrimary),
            ]
        }
        return .ok(["calendars": .array(list)])
    }

    private func listEvents(_ input: AJSON) async -> ToolOutput {
        guard let s = input["start"]?.string, let start = parseTime(s) else {
            return .error("start is missing or not ISO 8601 (e.g. 2026-10-19T00:00:00-04:00 or 2026-10-19).")
        }
        guard let e = input["end"]?.string, let end = parseTime(e) else {
            return .error("end is missing or not ISO 8601.")
        }
        guard end > start else { return .error("end must be after start.") }
        guard end.timeIntervalSince(start) <= 92 * 86400 else { return .error("Range too long: ask for at most 92 days at a time.") }
        await source.ensureLoaded(DateInterval(start: start, end: end))
        let includeHidden = input["include_hidden_calendars"]?.bool ?? false
        let query = input["query"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        var hits: [(EventRecord, CalCalendar)] = []
        for cal in source.allCalendars where includeHidden || source.isVisible(cal) {
            for r in (source.records[cal.calendarIdentifier] ?? [:]).values
            where r.status != "cancelled" && r.start < end && r.end > start {
                if !query.isEmpty, !Self.matches(r, query) { continue }
                hits.append((r, cal))
            }
        }
        hits.sort { ($0.0.start, $0.0.title ?? "", $0.1.calendarIdentifier) < ($1.0.start, $1.0.title ?? "", $1.1.calendarIdentifier) }
        let limit = 150
        var firstCopy: [String: String] = [:]
        var out: [AJSON] = []
        for (r, cal) in hits.prefix(limit) {
            let h = handle(for: EventRef(calendarKey: cal.calendarIdentifier, eventID: r.id))
            var json = eventJSON(r, cal, handle: h)
            if let uid = r.iCalUID {
                let key = uid + "@" + String(r.start.timeIntervalSince1970)
                if let first = firstCopy[key] { json = json.merging(["duplicate_of": .string(first)]) }
                else { firstCopy[key] = h }
            }
            out.append(json)
        }
        var result: [String: AJSON] = ["events": .array(out), "count": .int(out.count)]
        if hits.count > limit { result["note"] = .string("Showing the first \(limit) of \(hits.count); narrow the range or add a query.") }
        return .ok(.object(result))
    }

    private static func matches(_ r: EventRecord, _ q: String) -> Bool {
        if (r.title ?? "").lowercased().contains(q) { return true }
        if (r.location ?? "").lowercased().contains(q) { return true }
        if (r.organizerEmail ?? "").lowercased().contains(q) { return true }
        return (r.attendees ?? []).contains {
            $0.email.lowercased().contains(q) || ($0.displayName ?? "").lowercased().contains(q)
        }
    }

    func eventJSON(_ r: EventRecord, _ cal: CalCalendar, handle: String) -> AJSON {
        let me = r.attendees?.first(where: { $0.isSelf })
        let others = (r.attendees ?? []).filter { !$0.isSelf && !$0.isResource }
        var o: [String: AJSON] = [
            "id": .string(handle),
            "title": .string(r.title ?? "(no title)"),
            "all_day": .bool(r.isAllDay),
            "calendar": .string(cal.title),
            "calendar_id": .string(calendarHandle(cal.calendarIdentifier)),
            "owner_is_organizer": .bool(r.organizerSelf),
            "my_rsvp": .string(me?.responseStatus.rawValue ?? "not_invited"),
            "recurring": .bool(r.recurringEventId != nil || !(r.recurrence ?? []).isEmpty),
            "has_video_link": .bool(Self.hasVideoLink(r)),
            "can_edit": .bool(cal.allowsContentModifications && (r.organizerSelf || others.isEmpty || r.guestsCanModify)),
        ]
        if r.isAllDay {
            o["start"] = .string(dayString(r.start))
            o["end"] = .string(dayString(r.end))
        } else {
            o["start"] = .string(iso(r.start))
            o["end"] = .string(iso(r.end))
        }
        if let org = r.organizerEmail, !r.organizerSelf { o["organizer"] = .string(org) }
        if let loc = r.location, !loc.isEmpty { o["location"] = .string(String(loc.prefix(120))) }
        if !others.isEmpty {
            o["attendee_count"] = .int(others.count)
            o["other_attendees"] = .array(others.prefix(15).map { a in
                var p: [String: AJSON] = ["email": .string(a.email), "response": .string(a.responseStatus.rawValue)]
                if let n = a.displayName, !n.isEmpty { p["name"] = .string(n) }
                return .object(p)
            })
        }
        return .object(o)
    }

    private static let videoHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                     "webex.com", "whereby.com", "meet.jit.si", "around.co", "gather.town"]

    private static func hasVideoLink(_ r: EventRecord) -> Bool {
        if r.hangoutLink != nil { return true }
        let text = [r.url, r.location, r.notes].compactMap { $0?.lowercased() }.joined(separator: " ")
        return videoHosts.contains { text.contains($0) }
    }

    private func findFreeTime(_ input: AJSON) async -> ToolOutput {
        guard let start = input["start"]?.string.flatMap(parseTime),
              let end = input["end"]?.string.flatMap(parseTime) else {
            return .error("start and end must be ISO 8601 (or YYYY-MM-DD).")
        }
        guard end > start else { return .error("end must be after start.") }
        guard end.timeIntervalSince(start) <= 31 * 86400 else { return .error("Search at most 31 days at a time.") }
        guard let minutes = input["duration_minutes"]?.int, (5...720).contains(minutes) else {
            return .error("duration_minutes must be an integer from 5 to 720.")
        }
        let working = input["working_hours_only"]?.bool ?? true
        await source.ensureLoaded(DateInterval(start: start, end: end))
        let cal = source.calendar

        // Busy intervals, merged.
        var busy: [(Date, Date)] = []
        for c in source.allCalendars where source.isVisible(c) {
            for r in (source.records[c.calendarIdentifier] ?? [:]).values
            where r.status != "cancelled" && r.start < end && r.end > start {
                if r.isAllDay || r.end.timeIntervalSince(r.start) >= 86400 { continue }
                if r.transparency == "transparent" { continue }
                if r.attendees?.first(where: { $0.isSelf })?.responseStatus == .declined { continue }
                busy.append((r.start, r.end))
            }
        }
        busy.sort { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for b in busy {
            if let last = merged.last, b.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, b.1) }
            else { merged.append(b) }
        }

        let need = TimeInterval(minutes * 60)
        let floor = max(start, source.now)
        var slots: [AJSON] = []
        var day = cal.startOfDay(for: start)
        while day < end, slots.count < 25 {
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? end
            var windows: [(Date, Date)] = []
            if working {
                if !cal.isDateInWeekend(day),
                   let ws = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                   let we = cal.date(bySettingHour: 18, minute: 0, second: 0, of: day) {
                    windows.append((ws, we))
                }
            } else {
                windows.append((day, next))
            }
            for (ws, we) in windows {
                var cursor = max(ws, floor)
                let stop = min(we, end)
                for b in merged where b.1 > cursor && b.0 < stop {
                    emit(from: cursor, to: b.0)
                    cursor = max(cursor, b.1)
                }
                emit(from: cursor, to: stop)
            }
            day = next
        }

        func emit(from a: Date, to b: Date) {
            guard slots.count < 25 else { return }
            let s = Self.roundUp(a, toMinutes: 15, cal)
            guard b.timeIntervalSince(s) >= need else { return }
            slots.append([
                "start": .string(iso(s)),
                "end": .string(iso(b)),
                "minutes": .int(Int(b.timeIntervalSince(s) / 60)),
            ])
        }
        var result: [String: AJSON] = ["slots": .array(slots)]
        if slots.isEmpty { result["note"] = .string("No free slot of \(minutes) minutes in that window.") }
        return .ok(.object(result))
    }

    private static func roundUp(_ d: Date, toMinutes m: Int, _ cal: Calendar) -> Date {
        let comps = cal.dateComponents([.minute, .second], from: d)
        let minute = comps.minute ?? 0, second = comps.second ?? 0
        let extra = (m - minute % m) % m
        if extra == 0 && second == 0 { return d }
        let base = d.addingTimeInterval(-TimeInterval(second))
        return base.addingTimeInterval(TimeInterval((extra == 0 ? m : extra) * 60))
    }

    /// People from the owner's events: email → (name, count, last seen).
    private func directory(within window: DateInterval?) -> [String: (name: String?, count: Int, last: Date)] {
        let owners = Set(source.ownerEmails.map { $0.lowercased() })
        var acc: [String: (name: String?, count: Int, last: Date)] = [:]
        func add(_ email: String, _ name: String?, _ date: Date) {
            let key = email.lowercased()
            guard key.contains("@"), !owners.contains(key), !key.hasSuffix("calendar.google.com") else { return }
            var e = acc[key] ?? (nil, 0, .distantPast)
            if (e.name ?? "").isEmpty { e.name = name }
            e.count += 1
            e.last = max(e.last, date)
            acc[key] = e
        }
        for dict in source.records.values {
            for r in dict.values where r.status != "cancelled" {
                if let w = window, !w.contains(r.start) { continue }
                for a in r.attendees ?? [] where !a.isSelf && !a.isResource { add(a.email, a.displayName, r.start) }
                if let org = r.organizerEmail, !r.organizerSelf { add(org, nil, r.start) }
            }
        }
        return acc
    }

    private func searchPeople(_ input: AJSON) -> ToolOutput {
        let q = (input["query"]?.string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return .error("query must be at least 2 characters.") }
        let now = source.now
        let window = DateInterval(start: now.addingTimeInterval(-90 * 86400), end: now.addingTimeInterval(90 * 86400))
        let hits = directory(within: window).filter { email, e in
            let name = (e.name ?? "").lowercased()
            return email.contains(q) || name.contains(q)
        }
        .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        .prefix(10)
        guard !hits.isEmpty else {
            return .ok("No one matching “\(q)” in the owner's events from the last or next 90 days. Ask the owner for the email address — don't guess one.")
        }
        let people: [AJSON] = hits.map { email, e in
            var p: [String: AJSON] = ["email": .string(email), "events": .int(e.count), "last_seen": .string(dayString(e.last))]
            if let n = e.name, !n.isEmpty { p["name"] = .string(n) }
            return .object(p)
        }
        return .ok(["people": .array(people)])
    }

    // MARK: Write tools (plan only — never mutate)

    private enum Resolved {
        case found(EventRef, EventRecord, CalCalendar)
        case failed(ToolOutput)
    }

    private func resolveEvent(_ input: AJSON, key: String = "event_id") -> Resolved {
        guard let h = input[key]?.string else { return .failed(.error("\(key) is required.")) }
        guard let ref = handleEvents[h] else {
            return .failed(.error("Unknown event id “\(h)”. Use an id returned by list_events in this conversation."))
        }
        guard let r = source.records[ref.calendarKey]?[ref.eventID], r.status != "cancelled",
              let cal = source.allCalendars.first(where: { $0.calendarIdentifier == ref.calendarKey }) else {
            return .failed(.error("Event \(h) no longer exists (it may have changed in a sync). Call list_events again."))
        }
        return .found(ref, r, cal)
    }

    /// One step per event, and one per meeting across its calendar copies.
    private func checkNotPlanned(_ ref: EventRef, _ r: EventRecord) -> ToolOutput? {
        if let other = plan.first(where: { $0.ref == ref }) {
            return .error("\(handle(for: ref)) is already in the plan (\(other.verb.lowercased())). Each event can have one step.")
        }
        if let uid = r.iCalUID, let other = plan.first(where: { $0.meetingUID == uid && $0.ref.map { source.records[$0.calendarKey]?[$0.eventID]?.start } == r.start }) {
            return .error("Another copy of this meeting is already in the plan (\(other.verb.lowercased()) \(other.title)). Act on one copy only.")
        }
        return nil
    }

    private func knownEmail(_ email: String) -> Bool {
        let e = email.lowercased()
        if source.ownerEmails.contains(where: { $0.lowercased() == e }) { return true }
        if ownerText.contains(e) { return true }
        return directory(within: nil)[e] != nil
    }

    private func validateEmails(_ list: [String]) -> ToolOutput? {
        for email in list {
            let e = email.trimmingCharacters(in: .whitespaces)
            guard e.contains("@"), e.split(separator: "@").count == 2, e.contains(".") else {
                return .error("“\(email)” isn't an email address.")
            }
            guard knownEmail(e) else {
                return .error("\(e) doesn't appear in the owner's events and the owner didn't type it. Don't guess addresses: use search_people, or ask the owner.")
            }
        }
        return nil
    }

    private func guestNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let g = count == 1 ? "1 guest" : "\(count) guests"
        switch source.guestNotifyPolicy {
        case .always: return "email \(g)"
        case .never: return "\(g) (no email)"
        case .ask: return g
        }
    }

    private func otherGuests(_ r: EventRecord) -> Int {
        (r.attendees ?? []).filter { !$0.isSelf && !$0.isResource }.count
    }

    private func queued(_ action: PlannedAction) -> ToolOutput {
        plan.append(action)
        return .ok("Queued for the owner's confirmation (step \(plan.count)): \(action.summary)")
    }

    private func proposeCreate(_ input: AJSON) -> ToolOutput {
        let title = (input["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .error("title is required.") }
        let allDay = input["all_day"]?.bool ?? false
        guard var start = input["start"]?.string.flatMap(parseTime),
              var end = input["end"]?.string.flatMap(parseTime) else {
            return .error("start and end must be ISO 8601 with offset (or YYYY-MM-DD for all_day).")
        }
        if allDay {
            let cal = source.calendar
            start = cal.startOfDay(for: start)
            end = cal.startOfDay(for: end)
            if end <= start { end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400) }
        }
        guard end > start else { return .error("end must be after start.") }
        guard end.timeIntervalSince(start) <= 14 * 86400 else { return .error("That's longer than two weeks — check start and end.") }
        let calendar: CalCalendar
        if let h = input["calendar_id"]?.string {
            guard let key = handleCalendars[h], let c = source.allCalendars.first(where: { $0.calendarIdentifier == key }) else {
                return .error("Unknown calendar_id “\(h)”. Use an id from list_calendars.")
            }
            calendar = c
        } else {
            guard let c = source.defaultCalendar else { return .error("The owner has no writable calendar.") }
            calendar = c
        }
        guard calendar.allowsContentModifications else {
            return .error("\(calendar.title) is read-only for the owner. Pick a writable calendar from list_calendars.")
        }
        let attendees = (input["attendees"]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespaces).lowercased() }
        if let err = validateEmails(attendees) { return err }
        let guests = Self.unique(attendees.filter { $0 != calendar.accountID.lowercased() })
        let meet = input["add_google_meet"]?.bool ?? false
        var details = [calendar.title]
        if !guests.isEmpty { details.append("invite " + Self.emailList(guests)) }
        if meet { details.append("Google Meet") }
        if let loc = input["location"]?.string, !loc.isEmpty { details.append(loc) }
        if !guests.isEmpty {
            switch source.guestNotifyPolicy {
            case .always: details.append("email invite")
            case .never: details.append("no email")
            case .ask: break // the preview's "Email guests" switch decides
            }
        }
        return queued(PlannedAction(
            kind: .create(.init(title: title, start: start, end: end, allDay: allDay,
                                calendarKey: calendar.calendarIdentifier, attendees: guests,
                                location: input["location"]?.string, notes: input["description"]?.string,
                                addMeet: meet)),
            verb: "Create", title: title, when: whenLabel(start, end, allDay: allDay), details: details,
            isCancel: false, touchesGuests: !guests.isEmpty, meetingUID: nil))
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func emailList(_ emails: [String]) -> String {
        emails.count <= 2 ? emails.joined(separator: ", ") : "\(emails[0]), \(emails[1]) +\(emails.count - 2)"
    }

    /// Owner may change this event's time/details (not just their own copy).
    private func editable(_ r: EventRecord, _ cal: CalCalendar, verb: String) -> ToolOutput? {
        guard cal.allowsContentModifications else {
            return .error("“\(r.title ?? "This event")” is on \(cal.title), which is read-only for the owner — it can't be \(verb).")
        }
        if !r.organizerSelf, otherGuests(r) > 0, !r.guestsCanModify {
            return .error("The owner didn't organize “\(r.title ?? "this event")” (\(r.organizerEmail ?? "someone else") did) and guests can't modify it, so it can't be \(verb). Suggest declining, or asking the organizer.")
        }
        return nil
    }

    private func proposeMove(_ input: AJSON) -> ToolOutput {
        let (ref, r, cal): (EventRef, EventRecord, CalCalendar)
        switch resolveEvent(input) {
        case .failed(let e): return e
        case .found(let a, let b, let c): (ref, r, cal) = (a, b, c)
        }
        if let err = checkNotPlanned(ref, r) { return err }
        if let err = editable(r, cal, verb: "moved") { return err }
        guard var start = input["new_start"]?.string.flatMap(parseTime),
              var end = input["new_end"]?.string.flatMap(parseTime) else {
            return .error("new_start and new_end must be ISO 8601 with offset.")
        }
        if r.isAllDay {
            let c = source.calendar
            start = c.startOfDay(for: start)
            end = c.startOfDay(for: end)
            if end <= start { end = c.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400) }
        }
        guard end > start else { return .error("new_end must be after new_start.") }
        if start == r.start && end == r.end { return .error("That's the event's current time — nothing to move.") }
        var details = ["from " + whenLabel(r.start, r.end, allDay: r.isAllDay)]
        if r.recurringEventId != nil { details.append("this occurrence only") }
        if let note = guestNote(otherGuests(r)) { details.append(note) }
        return queued(PlannedAction(
            kind: .move(ref, start: start, end: end), verb: "Move", title: r.title ?? "(no title)",
            when: whenLabel(start, end, allDay: r.isAllDay), details: details,
            isCancel: false, touchesGuests: otherGuests(r) > 0, meetingUID: r.iCalUID))
    }

    enum CancelDecision: Equatable {
        case delete
        case decline
        case impossible(String)
    }

    /// Rule: delete what the owner organizes (or has nobody else on it);
    /// decline what someone else organizes — never delete it.
    static func cancelDecision(_ r: EventRecord, _ cal: CalCalendar) -> CancelDecision {
        let others = (r.attendees ?? []).filter { !$0.isSelf && !$0.isResource }
        if r.organizerSelf || others.isEmpty {
            guard cal.allowsContentModifications else {
                return .impossible("“\(r.title ?? "This event")” is on \(cal.title), which is read-only for the owner; it can't be cancelled from here.")
            }
            return .delete
        }
        guard r.attendees?.contains(where: { $0.isSelf }) == true else {
            return .impossible("The owner isn't on the guest list of “\(r.title ?? "this event")” (\(r.organizerEmail ?? "someone else") organizes it; maybe a group invite), so it can't be declined from here — and it isn't theirs to delete.")
        }
        return .decline
    }

    private func proposeCancel(_ input: AJSON) -> ToolOutput {
        let (ref, r, cal): (EventRef, EventRecord, CalCalendar)
        switch resolveEvent(input) {
        case .failed(let e): return e
        case .found(let a, let b, let c): (ref, r, cal) = (a, b, c)
        }
        if let err = checkNotPlanned(ref, r) { return err }
        let decision = Self.cancelDecision(r, cal)
        if case .impossible(let msg) = decision { return .error(msg) }
        let instance = r.recurringEventId != nil
        var details: [String] = []
        if instance { details.append("this occurrence only") }
        switch decision {
        case .impossible:
            return .error("Can't cancel this event.")
        case .delete:
            if let note = guestNote(otherGuests(r)) { details.append(note) }
            return queued(PlannedAction(
                kind: .delete(ref), verb: "Delete", title: r.title ?? "(no title)",
                when: whenLabel(r.start, r.end, allDay: r.isAllDay), details: details,
                isCancel: true, touchesGuests: otherGuests(r) > 0, meetingUID: r.iCalUID))
        case .decline:
            if r.attendees?.first(where: { $0.isSelf })?.responseStatus == .declined {
                return .error("The owner already declined “\(r.title ?? "this event")”.")
            }
            details.append(source.rsvpNotifyOrganizer ? "tell organizer" : "organizer not emailed")
            return queued(PlannedAction(
                kind: .rsvp(ref, .declined, instanceOnly: instance), verb: "Decline", title: r.title ?? "(no title)",
                when: whenLabel(r.start, r.end, allDay: r.isAllDay), details: details,
                isCancel: true, touchesGuests: false, meetingUID: r.iCalUID))
        }
    }

    private func proposeRSVP(_ input: AJSON) -> ToolOutput {
        let (ref, r): (EventRef, EventRecord)
        switch resolveEvent(input) {
        case .failed(let e): return e
        case .found(let a, let b, _): (ref, r) = (a, b)
        }
        if let err = checkNotPlanned(ref, r) { return err }
        guard let raw = input["response"]?.string, let status = ParticipantStatus(rawValue: raw), status != .needsAction else {
            return .error("response must be accepted, tentative or declined.")
        }
        guard let me = r.attendees?.first(where: { $0.isSelf }) else {
            return .error("The owner isn't on the guest list of “\(r.title ?? "this event")”, so there's nothing to answer.")
        }
        if r.organizerSelf { return .error("The owner organizes “\(r.title ?? "this event")” — there's no invitation to answer.") }
        if me.responseStatus == status { return .error("The owner already answered \(raw) to “\(r.title ?? "this event")”.") }
        let instance = r.recurringEventId != nil
        var details: [String] = []
        if instance { details.append("this occurrence only") }
        details.append(source.rsvpNotifyOrganizer ? "tell organizer" : "organizer not emailed")
        let verb = status == .accepted ? "Accept" : status == .tentative ? "Maybe" : "Decline"
        return queued(PlannedAction(
            kind: .rsvp(ref, status, instanceOnly: instance), verb: verb, title: r.title ?? "(no title)",
            when: whenLabel(r.start, r.end, allDay: r.isAllDay), details: details,
            isCancel: false, touchesGuests: false, meetingUID: r.iCalUID))
    }

    private func proposeUpdate(_ input: AJSON) -> ToolOutput {
        let (ref, r, cal): (EventRef, EventRecord, CalCalendar)
        switch resolveEvent(input) {
        case .failed(let e): return e
        case .found(let a, let b, let c): (ref, r, cal) = (a, b, c)
        }
        if let err = checkNotPlanned(ref, r) { return err }
        if let err = editable(r, cal, verb: "edited") { return err }
        var changes = PlannedAction.Changes()
        var details: [String] = []
        if let t = input["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != r.title {
            changes.title = t
            details.append("rename to “\(t)”")
        }
        if let l = input["location"]?.string, l != (r.location ?? "") {
            changes.location = l
            details.append(l.isEmpty ? "clear location" : "location: \(l)")
        }
        if let d = input["description"]?.string, d != (r.notes ?? "") {
            changes.notes = d
            details.append(d.isEmpty ? "clear description" : "new description")
        }
        let existing = Set((r.attendees ?? []).map { $0.email.lowercased() })
        let add = (input["add_attendees"]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !existing.contains($0) }
        if let err = validateEmails(add) { return err }
        let remove = (input["remove_attendees"]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespaces).lowercased() }
        for e in remove where !existing.contains(e) {
            return .error("\(e) isn't a guest of “\(r.title ?? "this event")”.")
        }
        if remove.contains(where: { e in source.ownerEmails.contains { $0.lowercased() == e } }) {
            return .error("Can't remove the owner from their own event; use propose_cancel_event instead.")
        }
        changes.addAttendees = Self.unique(add)
        changes.removeAttendees = remove
        if !changes.addAttendees.isEmpty { details.append("invite " + Self.emailList(changes.addAttendees)) }
        if !remove.isEmpty { details.append("remove " + Self.emailList(remove)) }
        guard !details.isEmpty else { return .error("Nothing would change: give at least one field that differs.") }
        if r.recurringEventId != nil { details.append("this occurrence only") }
        let guestsAfter = otherGuests(r) + changes.addAttendees.count - remove.count
        if let note = guestNote(max(guestsAfter, otherGuests(r))) { details.append(note) }
        return queued(PlannedAction(
            kind: .update(ref, changes), verb: "Update", title: r.title ?? "(no title)",
            when: whenLabel(r.start, r.end, allDay: r.isAllDay), details: details,
            isCancel: false, touchesGuests: max(guestsAfter, otherGuests(r)) > 0, meetingUID: r.iCalUID))
    }

    // MARK: Dates

    private func isoFormatter(fractional: Bool = false) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = source.calendar.timeZone
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    func iso(_ d: Date) -> String { isoFormatter().string(from: d) }

    func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = source.calendar
        f.timeZone = source.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// ISO 8601 with offset, without one (local time), or a bare date (local midnight).
    func parseTime(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let d = isoFormatter().date(from: s) ?? isoFormatter(fractional: true).date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = source.calendar
        f.timeZone = source.calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func fmt(_ template: String, _ d: Date, _ cal: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    /// "Tue 12:00–1:15 PM", "Thu Oct 29 3:00–3:30 PM", "Fri · all day".
    func whenLabel(_ start: Date, _ end: Date, allDay: Bool) -> String {
        let cal = source.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: source.now), to: cal.startOfDay(for: start)).day ?? 0
        let day = Self.fmt((0...6).contains(days) ? "EEE" : "EEEMMMd", start, cal)
        if allDay {
            let last = end.addingTimeInterval(-1)
            if cal.isDate(start, inSameDayAs: last) { return day + " · all day" }
            return day + "–" + Self.fmt("EEEMMMd", last, cal) + " · all day"
        }
        let f = DateIntervalFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        if cal.isDate(start, inSameDayAs: end) {
            f.dateStyle = .none
            f.timeStyle = .short
            return day + " " + f.string(from: start, to: end)
        }
        f.dateTemplate = "EEEMMMdjmm"
        return f.string(from: start, to: end)
    }

    // MARK: Context

    /// Per-conversation facts; sent with the owner's first message (not in
    /// the system prompt, which stays frozen for caching).
    func contextBlock() -> String {
        let cal = source.calendar
        let now = source.now
        let long = DateFormatter()
        long.calendar = cal
        long.timeZone = cal.timeZone
        long.dateStyle = .full
        long.timeStyle = .short
        let week = cal.dateInterval(of: .weekOfYear, for: now)
        let def = source.defaultCalendar
        var lines = [
            "Now: \(long.string(from: now)) (\(iso(now)))",
            "Time zone: \(cal.timeZone.identifier)",
            "Week starts on: \(cal.weekdaySymbols[(cal.firstWeekday - 1) % 7])",
        ]
        if let week {
            lines.append("This week: \(dayString(week.start)) to \(dayString(week.end.addingTimeInterval(-1)))")
        }
        lines.append("Owner's Google accounts: \(source.ownerEmails.joined(separator: ", "))")
        if let def {
            lines.append("Default calendar for new events: \(def.title) (id \(calendarHandle(def.calendarIdentifier)), account \(def.accountID))")
        }
        lines.append("Default event duration: \(source.defaultDurationMinutes) minutes")
        return "<context>\n" + lines.joined(separator: "\n") + "\n</context>"
    }

    static let systemPrompt = """
    You are the scheduling assistant inside Fork Calendar, a calendar app. You act for the app's owner on their Google calendars. The owner's first message starts with a <context> block: the current date and time, time zone, week start, their accounts and defaults.

    How you work:
    - Read tools (list_events, list_calendars, find_free_time, search_people) are free; call them as needed, in parallel when they're independent, so every answer rests on the owner's real calendar. Resolve relative dates ("Thursday afternoon", "this week", "next Monday") against the context's date, time zone and week start. Unless the owner says otherwise: morning is 9:00–12:00, afternoon 12:00–17:00, evening 17:00–20:00; "this week" runs from now to the end of the week.
    - Write tools (the propose_* tools) never change anything. Each call adds one step to a plan that the app shows the owner, and nothing happens until they press Confirm. Propose the complete plan in one go, then reply with a one- or two-sentence summary. Don't ask "shall I go ahead?" — the Confirm button is that question.
    - The plan holds only what you propose after the owner's latest message. If they reply to adjust it, propose the whole revised plan again.
    - Use only event ids, calendar ids and email addresses that a tool gave you, or that the owner typed. Never invent or guess them. To invite someone by name, use search_people first; if nobody matches, or several different people plausibly do (two Amys), ask the owner one short question and propose nothing.
    - If the request is ambiguous in a way that changes what would happen, ask one short clarifying question instead of proposing. Otherwise pick the sensible default and say what you picked.
    - New events go on the default calendar unless the owner names another, with the default duration unless they give a length. When the owner gives a day or part of a day but no exact time, use find_free_time and pick the earliest free slot that fits.
    - Cancelling: call propose_cancel_event for each meeting. The app decides how: meetings the owner organizes (or with nobody else on them) are deleted, meetings someone else organizes are declined. For a repeating meeting only that occurrence is affected. Unless the owner explicitly includes them, leave out all-day events, events the owner already declined, and events on calendars that aren't theirs (holidays, subscribed or read-only calendars).
    - The same meeting can appear on several of the owner's calendars (one per signed-in account); list_events marks the extra copies with duplicate_of. Act on one copy only — the one where owner_is_organizer is true, if any.
    - If a tool returns an error, correct the input and retry, or explain the problem to the owner.
    - Your reply appears in a small command palette: plain sentences, at most a few short lines, no headings, tables or lists of ids. Write times the way the owner would ("Thu 3:00 PM"), never ISO strings.
    """
}

private extension AJSON {
    func merging(_ other: [String: AJSON]) -> AJSON {
        guard case .object(var o) = self else { return self }
        for (k, v) in other { o[k] = v }
        return .object(o)
    }
}

// MARK: - Session (the tool-use loop)

@MainActor
final class AssistantSession {
    let toolbox: AssistantToolbox
    private let transport: AssistantTransport
    let model: String
    private var useFallbacks: Bool
    /// The conversation, append-only: assistant turns are kept verbatim
    /// (thinking blocks included) as the API requires.
    private(set) var messages: [AJSON] = []
    var onProgress: ((String) -> Void)?

    static let maxTurns = 8

    init(model: String, transport: AssistantTransport, source: AssistantDataSource) {
        self.model = model
        self.transport = transport
        self.toolbox = AssistantToolbox(source: source)
        self.useFallbacks = AssistantModel.supportsFallbacks(model)
    }

    var plan: [PlannedAction] { toolbox.plan }

    func requestBody() -> AJSON {
        var body: [String: AJSON] = [
            "model": .string(model),
            "max_tokens": 16000,
            "system": [[
                "type": "text",
                "text": .string(AssistantToolbox.systemPrompt),
                "cache_control": ["type": "ephemeral"],
            ]],
            "tools": .array(AssistantToolbox.definitions),
            "messages": .array(messages),
            // Automatic breakpoint on the newest block: each turn of the loop
            // reads the conversation so far from cache.
            "cache_control": ["type": "ephemeral"],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "medium"],
        ]
        if useFallbacks { body["fallbacks"] = "default" }
        return .object(body)
    }

    private var betas: [String] { useFallbacks ? ["server-side-fallback-2026-07-01"] : [] }

    private func call() async throws -> AJSON {
        var retried = false
        while true {
            do {
                return try await transport.send(requestBody(), betas: betas)
            } catch let error as AssistantError {
                // An org without the fallback beta gets a 400 naming it: drop it.
                if case .badRequest(let m) = error, useFallbacks,
                   m.localizedCaseInsensitiveContains("fallback") || m.localizedCaseInsensitiveContains("anthropic-beta") {
                    useFallbacks = false
                    continue
                }
                if error.isTransient, !retried {
                    retried = true
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                throw error
            }
        }
    }

    /// Send the owner's message and run tools until Claude answers. Returns
    /// Claude's text reply; the plan is in `plan`.
    func send(_ text: String) async throws -> String {
        toolbox.beginOwnerMessage(text)
        var content: [AJSON] = []
        if messages.isEmpty { content.append(["type": "text", "text": .string(toolbox.contextBlock())]) }
        content.append(["type": "text", "text": .string(text)])
        messages.append(["role": "user", "content": .array(content)])
        onProgress?("Thinking…")

        for _ in 0..<Self.maxTurns {
            try Task.checkCancellation()
            let response = try await call()
            try Task.checkCancellation()
            let blocks = response["content"]?.array ?? []
            let stop = response["stop_reason"]?.string ?? ""
            if stop == "refusal" { throw AssistantError.refused }
            messages.append(["role": "assistant", "content": .array(blocks)])
            let text = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch stop {
            case "tool_use":
                var results: [AJSON] = []
                for block in blocks where block["type"]?.string == "tool_use" {
                    let name = block["name"]?.string ?? ""
                    let input = block["input"] ?? [:]
                    onProgress?(toolbox.progressLabel(name: name, input: input))
                    let out = await toolbox.run(name: name, input: input)
                    var result: [String: AJSON] = [
                        "type": "tool_result",
                        "tool_use_id": block["id"] ?? "",
                        "content": .string(out.content),
                    ]
                    if out.isError { result["is_error"] = true }
                    results.append(.object(result))
                }
                messages.append(["role": "user", "content": .array(results)])
            case "pause_turn":
                continue
            case "max_tokens", "model_context_window_exceeded":
                throw AssistantError.truncated
            default:
                return text
            }
        }
        throw AssistantError.tooManySteps
    }
}
