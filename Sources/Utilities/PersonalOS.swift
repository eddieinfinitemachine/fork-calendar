import Combine
import Foundation
import SwiftUI

/// Bridge to Personal OS (the owner's todo / people / call-sheet web app).
/// It already mirrors every dated todo into a Google calendar ("EC") as an
/// all-day event with a deterministic id, so those events can be written
/// back: tick them done, and moving one moves the todo's due date. Any other
/// event can spawn a follow-up todo, and today's call sheet shows in the
/// sidebar. Optional — every UI piece hides until a base URL and capture
/// token are set (Settings → Personal OS). Auth is a bearer capture token.
@MainActor
final class PersonalOS: ObservableObject {
    static let shared = PersonalOS()
    nonisolated static let defaultURL = "https://personal-os-two-gold.vercel.app"

    struct CallSheetItem: Codable, Identifiable, Hashable {
        let personId: String
        let name: String
        let reason: String?
        var done: Bool
        /// Absolute link to the person's profile.
        let url: String
        var id: String { personId }
    }

    private struct CallSheet: Codable {
        let date: String
        let items: [CallSheetItem]
    }

    /// PATCH /api/capture/todo/{id} response.
    struct Todo: Codable {
        let id: String
        let title: String
        let dueDate: String?
        let completedAt: String?
    }

    /// Completion as the EC mirror encodes it in the event title.
    enum TodoState { case open, done, dropped }

    @Published private(set) var callSheet: [CallSheetItem] = []
    @Published private(set) var callSheetError: String?
    /// People with a swap in flight: their rows dim and lock until the
    /// server answers with who replaces them.
    @Published private(set) var callSheetSwapping: Set<String> = []
    /// Both URL and token set. Mirrors `AppSettings`; drives every UI piece.
    @Published private(set) var isConfigured = false
    /// Completion flips sent to the server but not yet visible in the synced
    /// event title (the server re-syncs the Google event a second or two
    /// later) — keeps the checkbox from snapping back meanwhile.
    @Published private var pendingCompletion: [String: Bool] = [:]

    struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    private var bag = Set<AnyCancellable>()
    private var lastCallSheetFetch: Date?

    private init() {
        isConfigured = Self.configured
        let settings = AppSettings.shared
        settings.$personalOSURL.combineLatest(settings.$personalOSToken)
            .map { url, token in !Self.trimmed(url).isEmpty && !Self.trimmed(token).isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configured in
                guard let self else { return }
                self.isConfigured = configured
                if !configured {
                    self.callSheet = []
                    self.callSheetError = nil
                }
            }
            .store(in: &bag)
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Read straight from settings (not the published mirror, which lags a
    /// run-loop turn) so a request right after editing Settings sees it.
    private static var configured: Bool {
        !trimmed(AppSettings.shared.personalOSURL).isEmpty && !trimmed(AppSettings.shared.personalOSToken).isEmpty
    }

    var baseURL: URL? {
        let raw = Self.trimmed(AppSettings.shared.personalOSURL)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    // MARK: - Call sheet

    /// GET today's call sheet into `callSheet` / `callSheetError`.
    func refreshCallSheet() async {
        guard Self.configured else {
            callSheet = []
            callSheetError = nil
            return
        }
        lastCallSheetFetch = Date()
        do {
            let sheet: CallSheet = try decode(await send("GET", "api/capture/call-sheet/today"))
            callSheet = sheet.items
            callSheetError = nil
        } catch {
            callSheetError = error.localizedDescription
        }
    }

    /// Check a person off today's sheet (or back on). Optimistic: the row
    /// flips now, then takes the server's sheet; a failure flips it back.
    func setCallSheetDone(personId: String, _ done: Bool) async throws {
        if let i = callSheet.firstIndex(where: { $0.personId == personId }) { callSheet[i].done = done }
        do {
            let sheet: CallSheet = try decode(await send("POST", "api/capture/call-sheet/today",
                                                         body: ["personId": personId, "done": done]))
            callSheet = sheet.items
        } catch {
            // Only that row: a refresh may have replaced the rest meanwhile.
            if let i = callSheet.firstIndex(where: { $0.personId == personId }) { callSheet[i].done = !done }
            throw error
        }
    }

    /// "Get someone else": the server swaps this person for another one.
    /// Not optimistic — who comes back is the server's pick — so the row
    /// sits in `callSheetSwapping` until the new sheet arrives.
    func replaceCallSheetPerson(personId: String) async throws {
        callSheetSwapping.insert(personId)
        defer { callSheetSwapping.remove(personId) }
        let sheet: CallSheet = try decode(await send("POST", "api/capture/call-sheet/today",
                                                     body: ["personId": personId, "replace": true]))
        callSheet = sheet.items
    }

    /// Fire-and-forget refresh for the store's sync triggers (launch, ⌘R,
    /// the sync timer, app activation). `minAge` throttles activation, which
    /// fires on every window focus.
    func refreshCallSheetSoon(minAge: TimeInterval = 0) {
        guard Self.configured else { return }
        if minAge > 0, let last = lastCallSheetFetch, Date().timeIntervalSince(last) < minAge { return }
        Task { await refreshCallSheet() }
    }

    // MARK: - Todos

    /// POST a "Follow up: <title>" todo due the next weekday after the event
    /// (today if that's already past), noting when it was and who was there.
    func followUp(on event: CalEvent) async throws {
        let cal = Calendar.autoupdatingCurrent
        let start = event.startDate ?? Date()
        let end = event.endDate ?? start
        var due = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: start)) ?? start
        while cal.isDateInWeekend(due) { due = cal.date(byAdding: .day, value: 1, to: due) ?? due }
        let today = cal.startOfDay(for: Date())
        if due < today { due = today }

        let when: String
        if event.isAllDay {
            when = Self.dayRange.string(from: start, to: max(end.addingTimeInterval(-1), start))
        } else {
            when = Self.timeRange.string(from: start, to: end)
        }
        let names = (event.attendees ?? [])
            .filter { !$0.isSelf && !$0.isResource }
            .compactMap(\.name)
        var notes = when
        if !names.isEmpty { notes += " · " + names.joined(separator: ", ") }

        var body: [String: Any] = [
            "title": "Follow up: \(event.title ?? "Untitled")",
            "notes": notes,
            "dueDate": Self.ymd.string(from: due),
        ]
        if let link = event.htmlLink, !link.isEmpty { body["url"] = link }
        _ = try await send("POST", "api/capture/todo", body: body)
    }

    @discardableResult
    func setCompleted(todoID: String, _ completed: Bool) async throws -> Todo {
        pendingCompletion[todoID] = completed
        do {
            return try decode(await send("PATCH", "api/capture/todo/\(todoID)", body: ["completed": completed]))
        } catch {
            pendingCompletion[todoID] = nil
            throw error
        }
    }

    /// `day` is formatted yyyy-MM-dd in the device time zone — the same
    /// convention the app parses Google all-day dates with, so an all-day
    /// event's start maps to its own date. nil clears the due date.
    @discardableResult
    func setDueDate(todoID: String, _ day: Date?) async throws -> Todo {
        let value: Any = day.map { Self.ymd.string(from: $0) } ?? NSNull()
        return try decode(await send("PATCH", "api/capture/todo/\(todoID)", body: ["dueDate": value]))
    }

    /// The synced title has caught up (or another sync will tell): stop
    /// overriding it.
    func clearPendingCompletion(_ todoID: String) {
        pendingCompletion[todoID] = nil
    }

    /// Done / open / dropped as shown: a just-sent flip wins over the title.
    func state(of event: CalEvent) -> TodoState {
        let fromTitle = Self.titleState(event.title)
        guard fromTitle != .dropped, let id = event.personalOSTodoID, let pending = pendingCompletion[id] else { return fromTitle }
        return pending ? .done : .open
    }

    // MARK: - EC event ids + titles

    /// The todo id behind an EC mirror event id: the server writes
    /// `"ka" + hex(utf8(todoId))` and todo ids are cuids (`[a-z0-9]+`).
    /// Recurring-instance ids (`<master>_<time>`) never match — "_" isn't hex.
    nonisolated static func todoID(fromEventID id: String) -> String? {
        guard id.hasPrefix("ka") else { return nil }
        let hex = Array(id.utf8.dropFirst(2))
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
              decoded.utf8.allSatisfy({
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
              })
        else { return nil }
        return decoded
    }

    nonisolated private static let donePrefix = "✓ "
    nonisolated private static let droppedPrefix = "✗ "

    nonisolated static func titleState(_ title: String?) -> TodoState {
        guard let title else { return .open }
        if title.hasPrefix(donePrefix) { return .done }
        if title.hasPrefix(droppedPrefix) { return .dropped }
        return .open
    }

    /// Title without the mirror's "✓ " / "✗ " status prefix.
    nonisolated static func displayTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        for prefix in [donePrefix, droppedPrefix] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard Self.configured else { throw Err("Set up Personal OS in Settings (⌘,) first") }
        guard let base = baseURL else { throw Err("Personal OS URL must start with https://") }
        let token = Self.trimmed(AppSettings.shared.personalOSToken)
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let message = json?["error"] as? String { throw Err(message) }
            throw Err(code == 401 ? "Capture token rejected (HTTP 401)" : "HTTP \(code)")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Err("Unexpected response from Personal OS")
        }
    }

    /// Device time zone, like `GoogleDates.dayFormatter` (all-day dates).
    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()
    private static let timeRange: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private static let dayRange: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

extension CalEvent {
    /// The Personal OS todo this event mirrors (an event on the EC calendar),
    /// decoded from the bare Google event id; nil for every other event.
    var personalOSTodoID: String? { PersonalOS.todoID(fromEventID: id) }
}

// MARK: - Store actions (toast + pick up the server's re-sync)

extension CalendarStore {
    /// Tick an EC todo done / not done. The server re-syncs the Google event
    /// in the background, so pull it ~2 s later.
    func setPersonalOSCompleted(_ event: CalEvent, _ completed: Bool) {
        guard let todoID = event.personalOSTodoID else { return }
        Task {
            do {
                try await PersonalOS.shared.setCompleted(todoID: todoID, completed)
                toast = completed ? "Marked done in Personal OS" : "Marked not done in Personal OS"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refresh()
                // Let that sync land before the title takes over again.
                try? await Task.sleep(nanoseconds: 500_000_000)
                var waited = 0
                while isRefreshing, waited < 60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                }
                PersonalOS.shared.clearPendingCompletion(todoID)
            } catch {
                toast = "Personal OS: \(error.localizedDescription)"
            }
        }
    }

    func setCallSheetDone(_ item: PersonalOS.CallSheetItem, _ done: Bool) {
        Task {
            do {
                try await PersonalOS.shared.setCallSheetDone(personId: item.personId, done)
            } catch {
                toast = "Personal OS: \(error.localizedDescription)"
            }
        }
    }

    func replaceCallSheetPerson(_ item: PersonalOS.CallSheetItem) {
        Task {
            do {
                try await PersonalOS.shared.replaceCallSheetPerson(personId: item.personId)
            } catch {
                toast = "Personal OS: \(error.localizedDescription)"
            }
        }
    }

    func followUpInPersonalOS(_ event: CalEvent) {
        Task {
            do {
                try await PersonalOS.shared.followUp(on: event)
                toast = "Follow-up added to Personal OS"
            } catch {
                toast = "Personal OS: \(error.localizedDescription)"
            }
        }
    }

    /// Due-date write-back. Called once a change to an existing event has
    /// reached Google — `pushUpdate`'s success path (edits, drags, resizes,
    /// calendar moves, undo) and the offline outbox replay — with the
    /// pre-change record. Only EC todo events whose start DAY moved go out;
    /// everything else returns here untouched. A failure leaves the Google
    /// move standing (the nightly reconcile would revert it).
    func writeBackPersonalOSDueDate(old: EventRecord?, new: EventRecord) {
        guard PersonalOS.shared.isConfigured, let old,
              let todoID = PersonalOS.todoID(fromEventID: new.id) else { return }
        // All-day starts are device-local midnights (GoogleDates.parse), so a
        // local same-day check matches what the grid shows.
        guard !Calendar.autoupdatingCurrent.isDate(old.start, inSameDayAs: new.start) else { return }
        Task {
            do {
                try await PersonalOS.shared.setDueDate(todoID: todoID, new.start)
            } catch {
                toast = "Personal OS: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Views

/// Leading checkbox on an EC todo's all-day bar. Drawn as an overlay ABOVE
/// the bar's own gestures (and iOS's LongPressDrag layer), so a click here
/// toggles completion and never opens the panel or starts a drag.
struct PersonalOSCheckbox: View {
    @ObservedObject private var personalOS = PersonalOS.shared
    let store: CalendarStore
    let event: CalEvent
    let color: Color
    var size: CGFloat = PersonalOSCheckbox.boxSize

    /// SpanBarView leaves this much (+ a 4pt gap) before the title.
    static let boxSize: CGFloat = 9

    var body: some View {
        if personalOS.isConfigured, event.personalOSTodoID != nil {
            let state = personalOS.state(of: event)
            Button {
                store.setPersonalOSCompleted(event, state != .done)
            } label: {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(state == .done ? AnyShapeStyle(color) : AnyShapeStyle(Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(color, lineWidth: 1))
                    .overlay {
                        if state == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: size - 3, weight: .bold))
                                .foregroundStyle(CWT.paper)
                        } else if state == .dropped {
                            DeclinedSlash(color: color)
                        }
                    }
                    .frame(width: size, height: size)
                    // 2pt of slack each side; the bar's full height.
                    .frame(width: size + 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .dropped)
            .opacity(state == .dropped ? 0.45 : 1)
            .help(state == .dropped ? "Dropped in Personal OS" : state == .done ? "Mark not done in Personal OS" : "Mark done in Personal OS")
            .accessibilityLabel(state == .done ? "Mark not done" : "Mark done")
        }
    }
}

/// Personal OS items for an event's right-click menu: done/not done + open
/// for EC todos, "Follow up" for everything else. Empty when not configured.
struct PersonalOSMenuItems: View {
    @ObservedObject private var personalOS = PersonalOS.shared
    @Environment(\.openURL) private var openURL
    let store: CalendarStore
    let event: CalEvent

    var body: some View {
        if personalOS.isConfigured {
            if event.personalOSTodoID != nil {
                let state = personalOS.state(of: event)
                if state != .dropped {
                    Button {
                        store.setPersonalOSCompleted(event, state != .done)
                    } label: {
                        Label(state == .done ? "Mark not done in Personal OS" : "Mark done in Personal OS",
                              systemImage: state == .done ? "square" : "checkmark.square")
                    }
                }
                if let url = personalOS.baseURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open Personal OS", systemImage: "arrow.up.right.square")
                    }
                }
            } else if !event.isLocal {
                Button {
                    store.followUpInPersonalOS(event)
                } label: {
                    Label("Follow up in Personal OS", systemImage: "arrowshape.turn.up.right")
                }
            }
        }
    }
}

/// Event panel header buttons (icon-only, like Delete / Bill).
struct PersonalOSPanelButtons: View {
    @ObservedObject private var personalOS = PersonalOS.shared
    @Environment(\.openURL) private var openURL
    let store: CalendarStore
    let event: CalEvent

    var body: some View {
        if personalOS.isConfigured {
            if event.personalOSTodoID != nil {
                let state = personalOS.state(of: event)
                if state != .dropped {
                    Button {
                        store.setPersonalOSCompleted(event, state != .done)
                    } label: {
                        Image(systemName: state == .done ? "checkmark.square.fill" : "square")
                    }
                    .help(state == .done ? "Mark not done in Personal OS" : "Mark done in Personal OS")
                    .accessibilityLabel(state == .done ? "Mark not done in Personal OS" : "Mark done in Personal OS")
                }
                if let url = personalOS.baseURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open Personal OS")
                    .accessibilityLabel("Open Personal OS")
                }
            } else if !event.isLocal {
                Button {
                    store.followUpInPersonalOS(event)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .help("Follow up in Personal OS")
                .accessibilityLabel("Follow up in Personal OS")
            }
        }
    }
}
