import Combine
import Foundation

// The ⌘K Claude assistant, wired to the app: Anthropic's Messages API over
// URLSession, the calendar read from CalendarStore, and the confirmed plan
// executed through the store's normal save / delete / RSVP paths as one
// undo step. The engine (tools, loop, plan rules) is in AssistantCore.swift.

// MARK: - Messages API transport

/// POST /v1/messages with the key from Settings. Plain URLSession, the same
/// shape as PersonalOS / InvoiceLink: no SDK (Swift has no official one).
@MainActor
final class AnthropicTransport: AssistantTransport {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    let apiKey: String
    let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func send(_ body: AJSON, betas: [String]) async throws -> AJSON {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = body.encoded()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AssistantError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AssistantError.from(status: status, body: data, model: model)
        }
        guard let json = try? JSONDecoder().decode(AJSON.self, from: data) else {
            throw AssistantError.server(status, "unreadable response")
        }
        return json
    }

    /// Settings → Test: a tiny request. nil = OK, else what went wrong.
    static func test(apiKey: String, model: String) async -> String? {
        let body: AJSON = [
            "model": .string(model),
            "max_tokens": 256,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ]
        do {
            _ = try await AnthropicTransport(apiKey: apiKey, model: model).send(body, betas: [])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Calendar data from the store

@MainActor
final class StoreAssistantSource: AssistantDataSource {
    let store: CalendarStore

    init(store: CalendarStore) { self.store = store }

    var ownerEmails: [String] { AccountManager.shared.accounts.map(\.email) }
    var allCalendars: [CalCalendar] { store.orderedCalendars }
    func isVisible(_ calendar: CalCalendar) -> Bool { store.isVisible(calendar) }
    var defaultCalendar: CalCalendar? { store.defaultCalendar }
    var records: [String: [String: EventRecord]] { store.engine.records }
    var calendar: Calendar {
        var c = Calendar.autoupdatingCurrent
        if AppSettings.shared.firstWeekday > 0 { c.firstWeekday = AppSettings.shared.firstWeekday }
        return c
    }
    var defaultDurationMinutes: Int { AppSettings.shared.defaultDuration }
    var guestNotifyPolicy: GuestNotifyPolicy { AppSettings.shared.guestNotifyPolicy }
    var rsvpNotifyOrganizer: Bool { AppSettings.shared.rsvpNotifyOrganizer }
    var now: Date { Date() }

    /// The sync engine keeps a wide window (a year back, 18 months ahead);
    /// outside it, widen through the same path the views use, then wait for
    /// that sync (at most ~20 s).
    func ensureLoaded(_ interval: DateInterval) async {
        let window = store.engine.window
        guard interval.start < window.start || interval.end > window.end else { return }
        store.ensureFetched(interval)
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !store.engine.isSyncing { return }
        }
    }
}

// MARK: - Assistant

@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    enum Phase: Equatable {
        case idle
        case running(String)
        case answered
        case failed(AssistantError)
    }

    @Published private(set) var phase: Phase = .idle
    /// Claude's latest text reply.
    @Published private(set) var reply = ""
    /// Steps waiting for Confirm.
    @Published private(set) var plan: [PlannedAction] = []
    /// What the owner typed, in order (shown above the reply).
    @Published private(set) var prompts: [String] = []
    /// With the "Ask each time" email policy: the batch's one answer.
    @Published var emailGuests = false
    /// An API key is set: every assistant affordance hides until then.
    @Published private(set) var isConfigured = false

    private var session: AssistantSession?
    private var task: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    private init() {
        AppSettings.shared.$anthropicAPIKey
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configured in
                self?.isConfigured = configured
                if !configured { self?.reset() }
            }
            .store(in: &bag)
    }

    /// A conversation is on screen (the palette shows it instead of results).
    var isEngaged: Bool { phase != .idle }
    var isRunning: Bool { if case .running = phase { return true }; return false }

    /// Send the owner's message; continues the conversation if one is open.
    func ask(_ text: String, store: CalendarStore) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        let key = AppSettings.shared.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        prompts.append(text)
        plan = []
        reply = ""
        guard !key.isEmpty else {
            phase = .failed(.noKey)
            return
        }
        let model = AppSettings.shared.assistantModel
        if session == nil || session?.model != model {
            session = AssistantSession(model: model, transport: AnthropicTransport(apiKey: key, model: model),
                                       source: StoreAssistantSource(store: store))
        }
        guard let session else { return }
        session.onProgress = { [weak self] status in
            guard let self, self.isRunning else { return }
            self.phase = .running(status)
        }
        phase = .running("Thinking…")
        task = Task { [weak self] in
            do {
                let text = try await session.send(text)
                guard let self, !Task.isCancelled else { return }
                self.reply = text
                self.plan = session.plan
                self.emailGuests = false
                self.phase = .answered
                if text.isEmpty && session.plan.isEmpty { self.reply = "Done — nothing to change." }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                // A broken turn can't be continued (the API needs every
                // tool call answered): start fresh next time.
                self.session = nil
                self.plan = []
                self.phase = .failed(error as? AssistantError ?? .network(error.localizedDescription))
            }
        }
    }

    /// Esc / closing the palette: stop anything in flight, forget the conversation.
    func reset() {
        task?.cancel()
        task = nil
        session = nil
        plan = []
        prompts = []
        reply = ""
        emailGuests = false
        phase = .idle
    }

    /// Plan steps that would email guests under the "Ask each time" policy.
    var needsEmailChoice: Bool {
        AppSettings.shared.guestNotifyPolicy == .ask && plan.contains { $0.touchesGuests }
    }

    // MARK: Confirm

    /// Run the plan through the store's own paths (notify policy, offline
    /// queue, Meet creation, widgets all apply), as ONE undo step. Spans are
    /// fixed to "this event": the span dialog is never involved.
    func confirm(store: CalendarStore, appState: AppState) {
        guard !plan.isEmpty, !isRunning else { return }
        let steps = plan
        let notify: Bool? = AppSettings.shared.guestNotifyPolicy == .ask ? emailGuests : nil
        var done: [PlannedAction] = []
        var skipped: [String] = []
        var touched: Set<String> = []

        store.performBatch(notifyGuests: notify) {
            for step in steps {
                if let ref = step.ref { touched.insert(ref.eventID) }
                if execute(step, store: store) { done.append(step) } else { skipped.append(step.title) }
            }
        }

        if let ctx = appState.panelContext, !ctx.isNew, touched.contains(ctx.event.id) { appState.closePanel() }
        appState.toast = Self.doneMessage(done, skipped: skipped)
        appState.paletteOpen = false
        reset()
    }

    /// One step. False when its event is gone or no longer qualifies.
    private func execute(_ step: PlannedAction, store: CalendarStore) -> Bool {
        switch step.kind {
        case .create(let spec):
            guard let cal = store.calendars.first(where: { $0.calendarIdentifier == spec.calendarKey }),
                  cal.allowsContentModifications else { return false }
            // The same steps as the event panel's save of a new event.
            let event = store.newEvent()
            event.calendar = cal
            event.title = spec.title
            event.startDate = spec.start
            event.endDate = spec.end
            event.isAllDay = spec.allDay
            event.location = spec.location
            event.notes = spec.notes
            if !spec.attendees.isEmpty {
                event.attendees = [Self.organizer(cal)] + spec.attendees.map(Self.guest)
            }
            event.wantsMeet = spec.addMeet
            store.saveWithUndo(event, snapshot: nil, isNew: true, span: .thisEvent)
        case .move(let ref, let start, let end):
            guard let event = store.event(id: ref.eventID, calendarKey: ref.calendarKey) else { return false }
            let snapshot = EventSnapshot(event)
            event.startDate = start
            event.endDate = end
            store.saveWithUndo(event, snapshot: snapshot, isNew: false, span: .thisEvent)
        case .delete(let ref):
            guard let event = store.event(id: ref.eventID, calendarKey: ref.calendarKey),
                  let cal = event.calendar,
                  // Re-check the rule against the event as it is now.
                  AssistantToolbox.cancelDecision(event.record(), cal) == .delete
            else { return false }
            store.deleteWithUndo(event, span: .thisEvent)
        case .rsvp(let ref, let status, let instanceOnly):
            guard let event = store.event(id: ref.eventID, calendarKey: ref.calendarKey),
                  event.myParticipantStatus != nil else { return false }
            store.respondWithUndo(event, status: status, instanceOnly: instanceOnly)
        case .update(let ref, let changes):
            guard let event = store.event(id: ref.eventID, calendarKey: ref.calendarKey),
                  let cal = event.calendar else { return false }
            let snapshot = EventSnapshot(event)
            if let t = changes.title { event.title = t }
            if let l = changes.location { event.location = l.isEmpty ? nil : l }
            if let n = changes.notes { event.notes = n.isEmpty ? nil : n }
            if !changes.addAttendees.isEmpty || !changes.removeAttendees.isEmpty {
                var list = event.attendees ?? []
                if list.isEmpty, !changes.addAttendees.isEmpty { list.append(Self.organizer(cal)) }
                list.removeAll { a in changes.removeAttendees.contains { $0.caseInsensitiveCompare(a.email) == .orderedSame } }
                for email in changes.addAttendees where !list.contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                    list.append(Self.guest(email))
                }
                event.attendees = list
            }
            store.saveWithUndo(event, snapshot: snapshot, isNew: false, span: .thisEvent)
        }
        return true
    }

    /// Google adds the organizer itself; listing them keeps RSVP state
    /// visible right away (as the event panel does).
    private static func organizer(_ cal: CalCalendar) -> CalAttendee {
        CalAttendee(email: cal.accountID.lowercased(), displayName: nil, responseStatus: .accepted,
                    isSelf: true, isOrganizer: true, isOptional: false, isResource: false)
    }

    private static func guest(_ email: String) -> CalAttendee {
        CalAttendee(email: email, displayName: nil, responseStatus: .needsAction,
                    isSelf: false, isOrganizer: false, isOptional: false, isResource: false)
    }

    static func doneMessage(_ done: [PlannedAction], skipped: [String]) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts: [String] = []
        let cancelled = done.filter(\.isCancel).count
        if cancelled > 0 { parts.append(n(cancelled, "meeting", "meetings") + " cancelled") }
        let rest = done.filter { !$0.isCancel }
        for verb in ["Create", "Move", "Update", "Accept", "Maybe", "Decline"] {
            let c = rest.filter { $0.verb == verb }.count
            guard c > 0 else { continue }
            switch verb {
            case "Create": parts.append(n(c, "event", "events") + " created")
            case "Move": parts.append(n(c, "event", "events") + " moved")
            case "Update": parts.append(n(c, "event", "events") + " updated")
            default: parts.append(n(c, "RSVP", "RSVPs") + " sent")
            }
        }
        var message = parts.isEmpty ? "Nothing changed" : "Done — " + parts.joined(separator: ", ")
        if !skipped.isEmpty { message += " · skipped \(skipped.count) that changed meanwhile" }
        #if os(macOS)
        if !done.isEmpty { message += " · ⌘Z undoes" }
        #endif
        return message
    }
}
