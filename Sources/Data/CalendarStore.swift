import SwiftUI
import Combine

struct EventSnapshot {
    var title: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String?
    var location: String?
    var notes: String?
    var url: URL?
    var recurrence: [String]?
    var attendees: [CalAttendee]?

    init(_ event: CalEvent) {
        title = event.title
        start = event.startDate ?? Date()
        end = event.endDate ?? Date()
        isAllDay = event.isAllDay
        calendarID = event.calendar?.calendarIdentifier
        location = event.location
        notes = event.notes
        url = event.url
        recurrence = event.recurrence
        attendees = event.attendees
    }

    @MainActor
    func apply(to event: CalEvent, in store: CalendarStore) {
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes
        event.url = url
        event.recurrence = recurrence
        event.attendees = attendees
        if let calendarID, let cal = store.calendars.first(where: { $0.calendarIdentifier == calendarID }) {
            event.calendar = cal
        }
    }
}

enum UndoAction {
    case restore(id: String, snapshot: EventSnapshot)
    case recreate(snapshot: EventSnapshot)
    case remove(id: String)
    /// Put my RSVP back (`instanceOnly`: one occurrence, not the series).
    case rsvp(id: String, calendarKey: String, previous: ParticipantStatus, instanceOnly: Bool)
    /// Several changes made as one batch (the assistant's confirmed plan):
    /// one ⌘Z reverts them all, newest first. `notify` is the guest-email
    /// answer the batch was made with, reused so undoing it asks nothing.
    indirect case group([UndoAction], notify: Bool?)
}

/// A saved calendar focus set ("Work", "Just me"): a named visibility
/// configuration. Stores the VISIBLE ids, so a calendar added later stays
/// hidden whenever the set is applied.
struct CalendarSet: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var visibleIDs: [String]

    private static let defaultsKey = "calendarSets"

    static func load() -> [CalendarSet] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CalendarSet].self, from: data)) ?? []
    }

    static func save(_ sets: [CalendarSet]) {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// "Email the guests about this change?" — shown when the policy is Ask.
struct NotifyPrompt: Identifiable {
    let id = UUID()
    let title: String
    let guestCount: Int
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
final class CalendarStore: ObservableObject {
    /// `.denied` now means "no Google account connected".
    enum AccessState { case unknown, granted, denied }

    let engine = SyncEngine()
    private let accounts = AccountManager.shared

    @Published var accessState: AccessState = .unknown
    @Published var calendars: [CalCalendar] = []
    @Published var events: [CalEvent] = []
    @Published var isRefreshing = false
    @Published var lastSync: Date?
    /// Network unreachable on the last sync attempt (sidebar pill).
    @Published var isOffline = false
    /// Offline writes waiting to reach Google.
    @Published var pendingCount = 0
    @Published var toast: String?
    @Published var notifyPrompt: NotifyPrompt?
    @Published var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs")
            dayIndexCache = nil
            publishWidgetData()
            WidgetBridge.mirror(hiddenCalendarIDs: hiddenCalendarIDs)
        }
    }
    /// Saved focus sets, in sidebar order. Lives here (not AppSettings) next
    /// to the visibility it rewrites — and an AppSettings change would also
    /// restart the sync timer and flush the day index for nothing.
    @Published private(set) var calendarSets: [CalendarSet] {
        didSet { CalendarSet.save(calendarSets) }
    }

    private var fetchedInterval: DateInterval?
    private var undoStack: [UndoAction] = []
    /// Inside `performBatch`: the batch's guest-email answer (nil = policy).
    private var batchNotify: Bool?
    private var batchDepth = 0
    private var dayIndexCache: [Date: [CalEvent]]?
    private var bag = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        calendarSets = CalendarSet.load()
        WidgetBridge.mirror(
            hiddenCalendarIDs: hiddenCalendarIDs,
            calendarColors: AppSettings.shared.calendarColors,
            showDeclined: AppSettings.shared.showDeclined
        )
        engine.onChange = { [weak self] in self?.reload() }
        // A replayed offline insert traded its local id for the server's:
        // keep undo entries and any live (open-editor) event object valid.
        engine.onRemapID = { [weak self] old, new in
            guard let self else { return }
            self.findEvent(id: old)?.id = new
            self.remapUndo(from: old, to: new)
        }
        // An offline edit that finally reached Google: same write-back as a
        // live save (see writeBackPersonalOSDueDate).
        engine.onReplayedUpdate = { [weak self] old, new in
            self?.writeBackPersonalOSDueDate(old: old, new: new)
        }
        engine.$isOffline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offline in self?.isOffline = offline }
            .store(in: &bag)
        engine.$pendingOps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ops in self?.pendingCount = ops.count }
            .store(in: &bag)
        engine.$isSyncing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] syncing in self?.isRefreshing = syncing }
            .store(in: &bag)
        engine.$lastSync
            .receive(on: DispatchQueue.main)
            .sink { [weak self] date in self?.lastSync = date }
            .store(in: &bag)
        engine.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in self?.toast = "Sync: \(message)" }
            .store(in: &bag)
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.dayIndexCache = nil
                self?.objectWillChange.send()
                self?.restartTimer()
            }
            .store(in: &bag)
        // The widget snapshot is filtered when it's published, so flipping
        // the declined filter has to re-publish it (no-op on macOS).
        AppSettings.shared.$showDeclined
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishWidgetData() }
            .store(in: &bag)
        accounts.$accounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                self?.accessState = list.isEmpty ? .denied : .granted
            }
            .store(in: &bag)
        calendars = engine.calendars
    }

    // MARK: - Calendars

    var defaultCalendar: CalCalendar? {
        let preferred = AppSettings.shared.defaultCalendarID
        if !preferred.isEmpty, let cal = writableCalendars.first(where: { $0.calendarIdentifier == preferred }) {
            return cal
        }
        let order = accounts.accounts.map(\.email)
        return writableCalendars
            .sorted { a, b in
                let ia = order.firstIndex(of: a.accountID) ?? 99
                let ib = order.firstIndex(of: b.accountID) ?? 99
                if ia != ib { return ia < ib }
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.title < b.title
            }
            .first
    }

    /// Calendars this app can write to (new events / move targets).
    /// Every calendar in sidebar display order (accounts in account order,
    /// each account's subscriptions in the user's drag order).
    var orderedCalendars: [CalCalendar] {
        calendarsBySource.flatMap(\.calendars)
    }

    var writableCalendars: [CalCalendar] {
        orderedCalendars.filter { $0.allowsContentModifications }
    }

    var calendarsBySource: [(source: String, calendars: [CalCalendar])] {
        let order = accounts.accounts.map(\.email)
        let custom = AppSettings.shared.calendarOrder
        let groups = Dictionary(grouping: calendars) { $0.accountID }
        // Manual drag order first; calendars not yet ordered fall back to the
        // default primary-then-title rules, after the ordered ones.
        func rank(_ c: CalCalendar) -> (Int, Int, String) {
            if let i = custom.firstIndex(of: c.calendarIdentifier) { return (i, 0, "") }
            return (Int.max, c.isPrimary ? 0 : 1, c.title.lowercased())
        }
        return groups.keys
            .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { key in (key, groups[key]!.sorted { rank($0) < rank($1) }) }
    }

    /// Position of a calendar in the sidebar's display order (lower = higher
    /// in the list). Drives the strip order of merged duplicate events.
    private var sidebarRankCache: [String: Int]?

    func sidebarRank(_ calendarID: String?) -> Int {
        guard let calendarID else { return .max }
        if sidebarRankCache == nil {
            var r: [String: Int] = [:]
            var i = 0
            for group in calendarsBySource {
                for c in group.calendars { r[c.calendarIdentifier] = i; i += 1 }
            }
            sidebarRankCache = r
        }
        return sidebarRankCache?[calendarID] ?? .max
    }

    func invalidateSidebarRank() { sidebarRankCache = nil }

    // MARK: - Lifecycle

    /// Called once at launch: show the cache immediately, then sync.
    func requestAccess() async {
        accessState = accounts.accounts.isEmpty ? .denied : .granted
        reload()
        restartTimer()
        PersonalOS.shared.refreshCallSheetSoon()
        if accessState == .granted {
            engine.syncAll()
        }
    }

    /// ⌘R: full pass over every account.
    func refresh() {
        PersonalOS.shared.refreshCallSheetSoon()
        guard accessState == .granted else { return }
        engine.syncAll()
    }

    /// Foreground / window-activation sync (if enabled).
    func syncIfDue() {
        PersonalOS.shared.refreshCallSheetSoon(minAge: 20)
        guard accessState == .granted, AppSettings.shared.syncOnActivate else { return }
        if let last = engine.lastSync, Date().timeIntervalSince(last) < 20 { return }
        engine.syncAll()
    }

    private func restartTimer() {
        let interval = AppSettings.shared.syncInterval
        timerTask?.cancel()
        guard interval > 0 else { timerTask = nil; return }
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                PersonalOS.shared.refreshCallSheetSoon()
                guard self.accessState == .granted else { continue }
                self.engine.syncAll()
            }
        }
    }

    /// Rebuild `calendars`/`events` from the engine's records.
    func reload() {
        calendars = engine.calendars
        guard let interval = fetchedInterval else {
            events = []
            return
        }
        var lookup: [String: CalCalendar] = [:]
        for cal in calendars { lookup[cal.calendarIdentifier] = cal }
        var built: [CalEvent] = []
        for (key, dict) in engine.records {
            guard let cal = lookup[key] else { continue }
            for record in dict.values where record.status != "cancelled" {
                guard record.start < interval.end, record.end > interval.start else { continue }
                built.append(CalEvent(record: record, calendar: cal))
            }
        }
        built.sort {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
        events = built
        dayIndexCache = nil
        attendeeDirectory = nil
        sidebarRankCache = nil
        publishWidgetData()
    }

    // MARK: - Attendee directory (invite autocomplete)

    struct AttendeeSuggestion: Identifiable, Hashable {
        var email: String
        var name: String?
        var id: String { email }
    }

    private var attendeeDirectory: [(email: String, name: String?, weight: Int, last: Date)]?

    /// People you've shared events with, for invite autocomplete: every
    /// synced event's guests and organizers, ranked by how often and how
    /// recently they appear. Prefix matches (email, name, or any name word)
    /// outrank substring matches.
    func attendeeSuggestions(matching query: String, excluding: Set<String> = [], limit: Int = 5) -> [AttendeeSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if attendeeDirectory == nil { buildAttendeeDirectory() }
        guard let dir = attendeeDirectory else { return [] }
        var scored: [(s: AttendeeSuggestion, rank: Int, weight: Int, last: Date)] = []
        for entry in dir {
            if excluding.contains(entry.email) { continue }
            let email = entry.email
            let name = entry.name?.lowercased() ?? ""
            let rank: Int
            if email.hasPrefix(q) || name.hasPrefix(q) {
                rank = 0
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                rank = 1
            } else if email.contains(q) || name.contains(q) {
                rank = 2
            } else {
                continue
            }
            scored.append((AttendeeSuggestion(email: entry.email, name: entry.name), rank, entry.weight, entry.last))
        }
        scored.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.last > $1.last
        }
        return scored.prefix(limit).map(\.s)
    }

    private func buildAttendeeDirectory() {
        var acc: [String: (name: String?, weight: Int, last: Date)] = [:]
        func add(_ email: String, name: String?, date: Date) {
            let key = email.lowercased()
            guard key.contains("@"), !key.hasSuffix("resource.calendar.google.com") else { return }
            var e = acc[key] ?? (name, 0, .distantPast)
            if e.name == nil || e.name?.isEmpty == true { e.name = name }
            e.weight += 1
            if date > e.last { e.last = date }
            acc[key] = e
        }
        for dict in engine.records.values {
            for record in dict.values where record.status != "cancelled" {
                for a in record.attendees ?? [] where !a.isSelf && !a.isResource {
                    add(a.email, name: a.displayName, date: record.start)
                }
                if let org = record.organizerEmail, !record.organizerSelf {
                    add(org, name: nil, date: record.start)
                }
            }
        }
        attendeeDirectory = acc.map { (email: $0.key, name: $0.value.name, weight: $0.value.weight, last: $0.value.last) }
    }

    func ensureFetched(_ interval: DateInterval) {
        guard accessState == .granted else { return }
        if let fetched = fetchedInterval, fetched.start <= interval.start, fetched.end >= interval.end { return }
        var start = interval.start.addingTimeInterval(-28 * 86400)
        var end = interval.end.addingTimeInterval(28 * 86400)
        if let fetched = fetchedInterval {
            start = min(start, fetched.start)
            end = max(end, fetched.end)
        }
        // The interval only ever grows: shrinking it (an old 400-day cap
        // re-centered on the newest request) silently unloaded events from
        // month rows already scrolled past — and lazy rows only re-request
        // their range on first appearance, so they stayed blank.
        fetchedInterval = DateInterval(start: start, end: end)
        reload()
        engine.ensureWindow(covers: DateInterval(start: interval.start, end: interval.end))
    }

    // MARK: - Visibility

    func isVisible(_ calendar: CalCalendar) -> Bool {
        !hiddenCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func toggle(_ calendar: CalCalendar) {
        if hiddenCalendarIDs.contains(calendar.calendarIdentifier) {
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            hiddenCalendarIDs.insert(calendar.calendarIdentifier)
        }
    }

    // MARK: - Calendar sets (focus)

    /// Make exactly `visible` (among loaded calendars) show, in ONE assignment
    /// — one didSet, so one UserDefaults write and one widget mirror — and
    /// only if something changes. Ids in `visible` that no longer exist are
    /// ignored; hidden ids of calendars not loaded right now (an account
    /// awaiting re-auth) carry over untouched.
    private func setVisibleCalendars(_ visible: Set<String>) {
        let existing = Set(calendars.map(\.calendarIdentifier))
        let hidden = existing.subtracting(visible).union(hiddenCalendarIDs.subtracting(existing))
        if hidden != hiddenCalendarIDs { hiddenCalendarIDs = hidden }
    }

    /// Visible calendar ids among the loaded calendars.
    private var visibleCalendarIDs: Set<String> {
        Set(calendars.filter { isVisible($0) }.map(\.calendarIdentifier))
    }

    func showAllCalendars() { setVisibleCalendars(Set(calendars.map(\.calendarIdentifier))) }

    func hideAllCalendars() { setVisibleCalendars([]) }

    /// Show only this calendar.
    func soloCalendar(_ cal: CalCalendar) { setVisibleCalendars([cal.calendarIdentifier]) }

    /// True when this calendar is the only one showing.
    func isSolo(_ cal: CalCalendar) -> Bool { visibleCalendarIDs == [cal.calendarIdentifier] }

    func apply(_ set: CalendarSet) { setVisibleCalendars(Set(set.visibleIDs)) }

    /// Derived, never stored: a set is active when what's showing now equals
    /// the set's ids that still exist.
    func isActive(_ set: CalendarSet) -> Bool {
        let existing = Set(calendars.map(\.calendarIdentifier))
        return visibleCalendarIDs == Set(set.visibleIDs).intersection(existing)
    }

    /// Visible ids in sidebar order (stable, readable JSON).
    private var currentVisibleIDList: [String] {
        orderedCalendars.filter { isVisible($0) }.map(\.calendarIdentifier)
    }

    @discardableResult
    func saveCurrentAsSet(named name: String) -> CalendarSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = CalendarSet(
            id: UUID(),
            name: trimmed.isEmpty ? "Set \(calendarSets.count + 1)" : trimmed,
            visibleIDs: currentVisibleIDList)
        calendarSets.append(set)
        return set
    }

    func updateSetToCurrent(_ set: CalendarSet) {
        guard let i = calendarSets.firstIndex(where: { $0.id == set.id }) else { return }
        calendarSets[i].visibleIDs = currentVisibleIDList
    }

    func renameSet(_ set: CalendarSet, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = calendarSets.firstIndex(where: { $0.id == set.id }) else { return }
        calendarSets[i].name = trimmed
    }

    func deleteSet(_ set: CalendarSet) {
        calendarSets.removeAll { $0.id == set.id }
    }

    private func passesFilters(_ event: CalEvent) -> Bool {
        guard let cal = event.calendar, isVisible(cal) else { return false }
        if !AppSettings.shared.showDeclined, event.myParticipantStatus == .declined { return false }
        return true
    }

    func events(on day: Date, calendar: Calendar) -> (allDay: [CalEvent], timed: [CalEvent]) {
        let key = calendar.startOfDay(for: day)
        var allDay: [CalEvent] = []
        var timed: [CalEvent] = []
        for event in dayIndex()[key] ?? [] {
            guard let start = event.startDate, let end = event.endDate else { continue }
            if event.isAllDay || end.timeIntervalSince(start) >= 86400 {
                allDay.append(event)
            } else {
                timed.append(event)
            }
        }
        return (allDay, timed)
    }

    func spanningEvents(from: Date, to: Date) -> [CalEvent] {
        events.filter { event in
            guard passesFilters(event) else { return false }
            guard let start = event.startDate, let end = event.endDate else { return false }
            guard event.isAllDay || end.timeIntervalSince(start) >= 86400 else { return false }
            return start < to && end > from
        }
    }

    private func dayIndex() -> [Date: [CalEvent]] {
        if let cached = dayIndexCache { return cached }
        let cal = Calendar.autoupdatingCurrent
        var index: [Date: [CalEvent]] = [:]
        for event in events {
            guard passesFilters(event) else { continue }
            guard let start = event.startDate, let end = event.endDate else { continue }
            var day = cal.startOfDay(for: start)
            var hops = 0
            while day < end, hops < 62 {
                index[day, default: []].append(event)
                day = cal.date(byAdding: .day, value: 1, to: day) ?? end
                hops += 1
            }
        }
        dayIndexCache = index
        return index
    }

    var nextUpcomingEvent: CalEvent? {
        let now = Date()
        let cal = Calendar.autoupdatingCurrent
        return events.first {
            guard let cal2 = $0.calendar, isVisible(cal2), !$0.isAllDay else { return false }
            guard let s = $0.startDate else { return false }
            return s > now && cal.isDateInToday(s)
        }
    }

    // MARK: - Search (whole cache)

    func searchEvents(_ query: String) -> [CalEvent] {
        guard accessState == .granted, query.count >= 2 else { return [] }
        let now = Date()
        var lookup: [String: CalCalendar] = [:]
        for cal in calendars { lookup[cal.calendarIdentifier] = cal }
        var hits: [CalEvent] = []
        for (key, dict) in engine.records {
            guard let cal = lookup[key] else { continue }
            for r in dict.values where r.status != "cancelled" && (r.title ?? "").localizedCaseInsensitiveContains(query) {
                hits.append(CalEvent(record: r, calendar: cal))
            }
        }
        return hits.sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    // MARK: - Widgets

    private func publishWidgetData() {
        #if os(iOS)
        let cal = Calendar.autoupdatingCurrent
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 3, to: start) ?? start
        var items: [WidgetItem] = []
        var lookup: [String: CalCalendar] = [:]
        for c in calendars { lookup[c.calendarIdentifier] = c }
        for (key, dict) in engine.records {
            guard let c = lookup[key], isVisible(c) else { continue }
            for r in dict.values where r.status != "cancelled" && r.start < end && r.end > start {
                if !AppSettings.shared.showDeclined,
                   r.attendees?.first(where: { $0.isSelf })?.responseStatus == .declined { continue }
                items.append(WidgetItem(
                    id: r.id, title: r.title ?? "Untitled", start: r.start, end: r.end,
                    isAllDay: r.isAllDay, colorHex: c.displayColor.hexString ?? "7D6378"
                ))
            }
        }
        WidgetBridge.publish(items)
        #endif
    }

    // MARK: - Mutations + undo

    func newEvent() -> CalEvent {
        let event = CalEvent()
        event.calendar = defaultCalendar
        return event
    }

    func saveWithUndo(_ event: CalEvent, snapshot: EventSnapshot?, isNew: Bool, span: EditSpan) {
        guard let cal = event.calendar ?? defaultCalendar else {
            toast = "No writable calendar"
            return
        }
        event.calendar = cal
        if event.title?.isEmpty ?? true { event.title = "New event" }
        let forced = batchNotify
        if isNew || event.isLocal {
            engine.upsert(event.record())
            undoStack.append(.remove(id: event.id))
            reload()
            Task { await pushInsert(event, notify: forced) }
        } else {
            let oldKey = snapshot?.calendarID ?? cal.calendarIdentifier
            let old = engine.record(id: event.id, calendarKey: oldKey)
            if oldKey != cal.calendarIdentifier { engine.remove(id: event.id, calendarKey: oldKey) }
            let rec = event.record()
            engine.upsert(rec)
            // Mirror the change onto duplicate copies on other calendars
            // (invitee copies of the same event). Google propagates these
            // server-side, but locally they'd show stale times until the next
            // sync; the syncAll after the push confirms.
            var mirroredOriginals: [EventRecord] = []
            if let old {
                for (calKey, dict) in engine.records where calKey != rec.calendarKey {
                    for dup in dict.values where dup.id != rec.id
                        && dup.status != "cancelled"
                        && dup.title == old.title && dup.start == old.start && dup.end == old.end {
                        var patched = dup
                        patched.title = rec.title
                        patched.start = rec.start
                        patched.end = rec.end
                        patched.isAllDay = rec.isAllDay
                        mirroredOriginals.append(dup)
                        engine.upsert(patched)
                    }
                }
            }
            if let snapshot { undoStack.append(.restore(id: event.id, snapshot: snapshot)) }
            reload()
            Task {
                await pushUpdate(event, old: old, oldKey: oldKey, span: span, mirrored: mirroredOriginals, notify: forced)
                // Pull the server's propagation to the other calendars' copies.
                engine.syncAll()
            }
        }
    }

    func deleteWithUndo(_ event: CalEvent, span: EditSpan, notify: Bool = true) {
        guard let cal = event.calendar else { return }
        let snapshot = EventSnapshot(event)
        let key = cal.calendarIdentifier
        if span == .futureEvents, let masterID = event.recurringEventId {
            engine.removeInstances(of: masterID, calendarKey: key, from: event.originalStart ?? event.startDate)
        } else {
            engine.remove(id: event.id, calendarKey: key)
        }
        undoStack.append(.recreate(snapshot: snapshot))
        reload()
        let forced = batchNotify
        Task { await pushDelete(event, calendar: cal, span: span, notify: notify, forced: forced) }
    }

    /// Make several changes as ONE undo step: every undo entry the body adds
    /// is folded into a single `.group`, so one ⌘Z reverts the whole batch.
    /// `notifyGuests` answers "email the guests?" once for every change in
    /// the batch (nil = the Settings policy) — with the Ask policy, per-event
    /// prompts would otherwise pile up (only one can be on screen).
    func performBatch(notifyGuests: Bool?, _ body: () -> Void) {
        let mark = undoStack.count
        let outer = batchNotify
        batchNotify = notifyGuests
        batchDepth += 1
        body()
        batchDepth -= 1
        batchNotify = outer
        guard undoStack.count > mark else { return }
        let added = Array(undoStack[mark...])
        undoStack.removeSubrange(mark...)
        undoStack.append(added.count == 1 ? added[0] : .group(added, notify: notifyGuests))
    }

    /// The event `id` on calendar `calendarKey` — the live object if it's
    /// loaded, else rebuilt from the cache. (Ids alone can repeat across
    /// calendars: an invite shows on each signed-in account with one id.)
    func event(id: String, calendarKey: String) -> CalEvent? {
        if let live = events.first(where: { $0.id == id && $0.calendar?.calendarIdentifier == calendarKey }) { return live }
        guard let record = engine.record(id: id, calendarKey: calendarKey),
              let cal = engine.calendar(forKey: calendarKey) else { return nil }
        return CalEvent(record: record, calendar: cal)
    }

    func duplicate(_ event: CalEvent, dayOffset: Double = 0) {
        var snapshot = EventSnapshot(event)
        snapshot.start = snapshot.start.addingTimeInterval(dayOffset * 86400)
        snapshot.end = snapshot.end.addingTimeInterval(dayOffset * 86400)
        paste(snapshot)
    }

    /// Insert a fresh event from a snapshot (guests and repeat rules dropped).
    func paste(_ snapshot: EventSnapshot) {
        let copy = CalEvent()
        var snapshot = snapshot
        snapshot.attendees = nil
        snapshot.recurrence = nil
        snapshot.apply(to: copy, in: self)
        if copy.calendar == nil || !(copy.calendar?.allowsContentModifications ?? false) {
            copy.calendar = defaultCalendar
        }
        saveWithUndo(copy, snapshot: nil, isNew: true, span: .thisEvent)
    }

    func move(_ event: CalEvent, to calendar: CalCalendar) {
        let snapshot = EventSnapshot(event)
        event.calendar = calendar
        saveWithUndo(event, snapshot: snapshot, isNew: false, span: .thisEvent)
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        perform(action, notify: nil)
        if case .group(let list, _) = action {
            toast = "Undone — \(list.count) changes reverted"
        }
    }

    private func perform(_ action: UndoAction, notify forced: Bool?) {
        switch action {
        case .restore(let id, let snapshot):
            if let event = findEvent(id: id) {
                let before = EventSnapshot(event)
                snapshot.apply(to: event, in: self)
                let oldKey = before.calendarID ?? event.calendar?.calendarIdentifier ?? ""
                let old = engine.record(id: id, calendarKey: oldKey)
                if oldKey != event.calendar?.calendarIdentifier { engine.remove(id: id, calendarKey: oldKey) }
                engine.upsert(event.record())
                reload()
                Task { await pushUpdate(event, old: old, oldKey: oldKey, span: .thisEvent, notify: forced) }
            }
        case .recreate(let snapshot):
            let event = CalEvent()
            snapshot.apply(to: event, in: self)
            event.recurrence = nil
            if event.calendar == nil || !(event.calendar?.allowsContentModifications ?? false) {
                event.calendar = defaultCalendar
            }
            guard event.calendar != nil else { return }
            engine.upsert(event.record())
            reload()
            Task { await pushInsert(event, notify: forced) }
        case .remove(let id):
            if let event = findEvent(id: id), let cal = event.calendar {
                engine.remove(id: id, calendarKey: cal.calendarIdentifier)
                reload()
                Task { await pushDelete(event, calendar: cal, span: .thisEvent, notify: true, forced: forced) }
            }
        case .rsvp(let id, let key, let previous, let instanceOnly):
            if let event = self.event(id: id, calendarKey: key) {
                Task { await respond(event, status: previous, instanceOnly: instanceOnly, quiet: true) }
            }
        case .group(let list, let notify):
            for inner in list.reversed() { perform(inner, notify: notify) }
        }
    }

    private func findEvent(id: String) -> CalEvent? {
        if let match = events.first(where: { $0.id == id }) { return match }
        for (key, dict) in engine.records {
            if let r = dict[id] { return CalEvent(record: r, calendar: engine.calendar(forKey: key)) }
        }
        return nil
    }

    /// Remap a local id to the server's id in the undo stack.
    private func remapUndo(from old: String, to new: String) {
        undoStack = undoStack.map { Self.remap($0, from: old, to: new) }
    }

    private static func remap(_ action: UndoAction, from old: String, to new: String) -> UndoAction {
        switch action {
        case .remove(let id) where id == old: return .remove(id: new)
        case .restore(let id, let s) where id == old: return .restore(id: new, snapshot: s)
        case .group(let list, let notify): return .group(list.map { remap($0, from: old, to: new) }, notify: notify)
        default: return action
        }
    }

    // MARK: - RSVP

    /// RSVP as an undoable step (the assistant's plan; one ⌘Z puts the old
    /// answer back). `instanceOnly`: answer this occurrence, not the series.
    func respondWithUndo(_ event: CalEvent, status: ParticipantStatus, instanceOnly: Bool) {
        guard let cal = event.calendar, let previous = event.myParticipantStatus else {
            toast = "You're not on “\(event.title ?? "this event")”'s guest list"
            return
        }
        undoStack.append(.rsvp(id: event.id, calendarKey: cal.calendarIdentifier, previous: previous, instanceOnly: instanceOnly))
        let quiet = batchDepth > 0
        Task { await respond(event, status: status, instanceOnly: instanceOnly, quiet: quiet) }
    }

    /// `instanceOnly`: answer just this occurrence of a repeating event
    /// (default: the whole series). `quiet`: no success toast (batches).
    func respond(_ event: CalEvent, status: ParticipantStatus, instanceOnly: Bool = false, quiet: Bool = false) async {
        guard let cal = event.calendar else { return }
        guard var attendees = event.attendees, attendees.contains(where: { $0.isSelf }) else {
            toast = "You're not on this event's guest list (\(cal.accountID))"
            return
        }
        for i in attendees.indices where attendees[i].isSelf { attendees[i].responseStatus = status }
        // Optimistic: every cached copy of the series/instance shows the answer
        let key = cal.calendarIdentifier
        let targetID = instanceOnly ? event.id : (event.recurringEventId ?? event.id)
        let preChange = engine.record(id: targetID, calendarKey: key)
        event.attendees = attendees
        if let dict = engine.records[key] {
            for (id, var r) in dict where id == event.id || (!instanceOnly && r.recurringEventId == targetID) {
                r.attendees = attendees
                engine.upsert(r)
            }
        }
        reload()
        do {
            let token = try await accounts.validToken(for: cal.accountID)
            let sendUpdates = AppSettings.shared.rsvpNotifyOrganizer ? "all" : "none"
            _ = try await GoogleCalendarAPI.patch(
                calendarID: cal.googleID, eventID: targetID,
                body: ["attendees": attendees.map { $0.googleJSON() }],
                sendUpdates: sendUpdates, token: token
            )
            let label: String = status == .accepted ? "Going" : status == .tentative ? "Maybe" : "Not going"
            if !quiet { toast = "RSVP sent: \(label)" + (sendUpdates == "none" ? " (organizer not emailed)" : "") }
        } catch {
            if error.isRetryableOffline {
                engine.enqueue(PendingOp(
                    kind: .update, accountID: cal.accountID,
                    calendarKey: key, googleCalendarID: cal.googleID,
                    eventID: targetID,
                    body: PendingOp.encode(["attendees": attendees.map { $0.googleJSON() }]),
                    sendUpdates: AppSettings.shared.rsvpNotifyOrganizer ? "all" : "none",
                    optimistic: engine.record(id: targetID, calendarKey: key),
                    rollback: preChange
                ))
                toast = "Offline — RSVP will send when you're back online"
                return
            }
            toast = "RSVP failed — \(error.localizedDescription)"
        }
        await engine.resync(calendarKey: key)
    }

    // MARK: - Server writes

    /// Decide Google's sendUpdates for a change touching other guests.
    /// `forced`: a batch's one answer (see `performBatch`), overriding the policy.
    private func sendUpdates(for event: CalEvent, old: EventRecord?, verb: String, forced: Bool? = nil) async -> String {
        let guests = event.otherAttendees.count
        let hadGuests = (old?.attendees ?? []).contains { !$0.isSelf }
        guard guests > 0 || hadGuests else { return "none" }
        if let forced { return forced ? "all" : "none" }
        switch AppSettings.shared.guestNotifyPolicy {
        case .always: return "all"
        case .never: return "none"
        case .ask:
            let answer = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                notifyPrompt = NotifyPrompt(title: "\(verb) “\(event.title ?? "event")”", guestCount: max(guests, 1), continuation: cont)
            }
            return answer ? "all" : "none"
        }
    }

    func resolveNotifyPrompt(_ send: Bool) {
        guard let prompt = notifyPrompt else { return }
        notifyPrompt = nil
        prompt.continuation.resume(returning: send)
    }

    private func pushInsert(_ event: CalEvent, notify forced: Bool? = nil) async {
        guard let cal = event.calendar else { return }
        let localID = event.id
        let wantedMeet = event.wantsMeet
        let updates = await sendUpdates(for: event, old: nil, verb: "Invite guests to", forced: forced)
        do {
            let token = try await accounts.validToken(for: cal.accountID)
            let created = try await GoogleCalendarAPI.insert(
                calendarID: cal.googleID, body: EventBody.full(event), sendUpdates: updates, token: token
            )
            engine.remove(id: localID, calendarKey: cal.calendarIdentifier)
            if let record = created.record(calendarKey: cal.calendarIdentifier) {
                event.id = record.id
                event.etag = record.etag
                event.hangoutLink = record.hangoutLink
                event.wantsMeet = false
                engine.upsert(record)
                remapUndo(from: localID, to: record.id)
                if wantedMeet, record.hangoutLink != nil { toast = "Google Meet link added" }
            }
            reload()
            // Recurring masters → instances come from the server
            if !(event.recurrence ?? []).isEmpty { await engine.resync(calendarKey: cal.calendarIdentifier) }
        } catch {
            if error.isRetryableOffline {
                engine.enqueue(PendingOp(
                    kind: .insert, accountID: cal.accountID,
                    calendarKey: cal.calendarIdentifier, googleCalendarID: cal.googleID,
                    eventID: localID, body: PendingOp.encode(EventBody.full(event)),
                    sendUpdates: updates, optimistic: event.record(), rollback: nil
                ))
                toast = "Offline — event will sync when you're back online"
            } else {
                toast = "Couldn't create event — \(error.localizedDescription)"
                engine.remove(id: localID, calendarKey: cal.calendarIdentifier)
                reload()
            }
        }
    }

    private func pushUpdate(_ event: CalEvent, old: EventRecord?, oldKey: String, span: EditSpan, mirrored: [EventRecord] = [], notify forced: Bool? = nil) async {
        guard let cal = event.calendar else { return }
        let key = cal.calendarIdentifier
        let updates = await sendUpdates(for: event, old: old, verb: "Update", forced: forced)
        do {
            let token = try await accounts.validToken(for: cal.accountID)
            var eventID = event.id
            var sourceCal = engine.calendar(forKey: oldKey) ?? cal

            // Calendar change
            if oldKey != key {
                if sourceCal.accountID == cal.accountID {
                    let moved = try await GoogleCalendarAPI.move(
                        calendarID: sourceCal.googleID, eventID: eventID, to: cal.googleID,
                        sendUpdates: updates, token: token
                    )
                    eventID = moved.id
                    sourceCal = cal
                } else {
                    // Cross-account: copy then delete
                    let sourceToken = try await accounts.validToken(for: sourceCal.accountID)
                    let created = try await GoogleCalendarAPI.insert(
                        calendarID: cal.googleID, body: EventBody.full(event, includeAttendees: false),
                        sendUpdates: "none", token: token
                    )
                    try await GoogleCalendarAPI.delete(calendarID: sourceCal.googleID, eventID: eventID, sendUpdates: updates, token: sourceToken)
                    engine.remove(id: event.id, calendarKey: key)
                    if let record = created.record(calendarKey: key) {
                        remapUndo(from: event.id, to: record.id)
                        event.id = record.id
                        engine.upsert(record)
                    }
                    reload()
                    await engine.resync(calendarKey: oldKey)
                    return
                }
            }

            if span == .futureEvents, let masterID = event.recurringEventId {
                try await pushSeriesSplit(event, masterID: masterID, calendar: cal, updates: updates, token: token)
            } else {
                let patched = try await GoogleCalendarAPI.patch(
                    calendarID: cal.googleID, eventID: eventID,
                    body: EventBody.patch(event, old: old), sendUpdates: updates, token: token
                )
                if let record = patched.record(calendarKey: key) {
                    var r = record
                    r.recurrence = r.recurrence ?? event.recurrence
                    if eventID != event.id { engine.remove(id: event.id, calendarKey: key) }
                    remapUndo(from: event.id, to: r.id)
                    event.id = r.id
                    event.etag = r.etag
                    event.hangoutLink = r.hangoutLink
                    if event.wantsMeet, r.hangoutLink != nil { toast = "Google Meet link added" }
                    event.wantsMeet = false
                    engine.upsert(r)
                }
                reload()
                writeBackPersonalOSDueDate(old: old, new: event.record())
                if event.isMaster || (old?.recurrence ?? []) != (event.recurrence ?? []) {
                    await engine.resync(calendarKey: key)
                }
            }
        } catch {
            // Offline: keep the optimistic edit and queue the patch — but not
            // for calendar moves or series splits, which need a multi-step
            // server conversation that can't be replayed blindly.
            if error.isRetryableOffline, oldKey == key,
               !(span == .futureEvents && event.recurringEventId != nil) {
                engine.enqueue(PendingOp(
                    kind: .update, accountID: cal.accountID,
                    calendarKey: key, googleCalendarID: cal.googleID,
                    eventID: event.id, body: PendingOp.encode(EventBody.patch(event, old: old)),
                    sendUpdates: updates, optimistic: event.record(), rollback: old
                ))
                toast = "Offline — change will sync when you're back online"
                return
            }
            toast = "Couldn't save — \(error.localizedDescription)"
            // The server still has the pre-edit event, so put the optimistic
            // local record (and any mirrored duplicate copies) back; the
            // incremental resync below can't — records the server never
            // changed are never re-sent.
            if let old {
                engine.remove(id: event.id, calendarKey: key)
                engine.upsert(old)
            }
            for original in mirrored { engine.upsert(original) }
            if old != nil || !mirrored.isEmpty { reload() }
            await engine.resync(calendarKey: key)
            if oldKey != key { await engine.resync(calendarKey: oldKey) }
        }
    }

    /// "This and all future": patch the master when the edited instance is the
    /// first one; otherwise end the old series before it and start a new one.
    private func pushSeriesSplit(_ event: CalEvent, masterID: String, calendar cal: CalCalendar, updates: String, token: String) async throws {
        let key = cal.calendarIdentifier
        let master = try await GoogleCalendarAPI.getEvent(calendarID: cal.googleID, eventID: masterID, token: token)
        let masterStart = master.start.flatMap(GoogleDates.parse)
        let originalStart = event.originalStart ?? event.startDate ?? Date()
        let newRules = RRule.stripped(event.recurrence ?? master.recurrence ?? [])
        if let masterStart, abs(masterStart.timeIntervalSince(originalStart)) < 60 {
            var body = EventBody.full(event, includeAttendees: false)
            body["recurrence"] = newRules
            _ = try await GoogleCalendarAPI.patch(calendarID: cal.googleID, eventID: masterID, body: body, sendUpdates: updates, token: token)
            engine.setMasterRules(newRules, calendarKey: key, masterID: masterID)
        } else {
            let truncated = RRule.truncated(master.recurrence ?? [], before: originalStart, allDay: master.start?.date != nil)
            _ = try await GoogleCalendarAPI.patch(calendarID: cal.googleID, eventID: masterID, body: ["recurrence": truncated], sendUpdates: updates, token: token)
            engine.setMasterRules(truncated, calendarKey: key, masterID: masterID)
            var body = EventBody.full(event, includeAttendees: true)
            body["recurrence"] = newRules
            _ = try await GoogleCalendarAPI.insert(calendarID: cal.googleID, body: body, sendUpdates: updates, token: token)
        }
        engine.removeInstances(of: masterID, calendarKey: key, from: originalStart)
        reload()
        await engine.resync(calendarKey: key)
    }

    private func pushDelete(_ event: CalEvent, calendar cal: CalCalendar, span: EditSpan, notify: Bool, forced: Bool? = nil) async {
        let key = cal.calendarIdentifier
        if event.isLocal {
            // Never reached the server — just cancel any queued insert.
            engine.cancelPending(eventID: event.id, calendarKey: key)
            return
        }
        let updates = notify ? await sendUpdates(for: event, old: nil, verb: "Cancel", forced: forced) : "none"
        do {
            let token = try await accounts.validToken(for: cal.accountID)
            if span == .futureEvents, let masterID = event.recurringEventId {
                let master = try await GoogleCalendarAPI.getEvent(calendarID: cal.googleID, eventID: masterID, token: token)
                let masterStart = master.start.flatMap(GoogleDates.parse)
                let originalStart = event.originalStart ?? event.startDate ?? Date()
                if let masterStart, abs(masterStart.timeIntervalSince(originalStart)) < 60 {
                    try await GoogleCalendarAPI.delete(calendarID: cal.googleID, eventID: masterID, sendUpdates: updates, token: token)
                } else {
                    let truncated = RRule.truncated(master.recurrence ?? [], before: originalStart, allDay: master.start?.date != nil)
                    _ = try await GoogleCalendarAPI.patch(calendarID: cal.googleID, eventID: masterID, body: ["recurrence": truncated], sendUpdates: updates, token: token)
                    engine.setMasterRules(truncated, calendarKey: key, masterID: masterID)
                }
            } else {
                try await GoogleCalendarAPI.delete(calendarID: cal.googleID, eventID: event.id, sendUpdates: updates, token: token)
            }
        } catch {
            if error.isRetryableOffline {
                if span == .futureEvents, event.recurringEventId != nil {
                    // Truncating a series needs the master from the server;
                    // the local removal can't stand — a full re-list restores
                    // the instances once we're back online.
                    engine.dropSyncToken(forKey: key)
                    toast = "Can't delete future events while offline"
                } else {
                    engine.enqueue(PendingOp(
                        kind: .delete, accountID: cal.accountID,
                        calendarKey: key, googleCalendarID: cal.googleID,
                        eventID: event.id, body: nil, sendUpdates: updates,
                        optimistic: nil, rollback: event.record()
                    ))
                    toast = "Offline — will delete when you're back online"
                    return
                }
            } else {
                toast = "Couldn't delete — \(error.localizedDescription)"
            }
        }
        await engine.resync(calendarKey: key)
    }
}

/// Builds Google event JSON from a `CalEvent`.
enum EventBody {
    static func time(_ date: Date, allDay: Bool, tz: String?) -> [String: Any] {
        var d = GoogleDates.json(date, allDay: allDay, timeZone: tz)
        // PATCH merges nested objects; null out the other representation so
        // Google doesn't see both `date` and `dateTime`.
        if allDay {
            d["dateTime"] = NSNull()
            d["timeZone"] = NSNull()
        } else {
            d["date"] = NSNull()
        }
        return d
    }

    static func full(_ event: CalEvent, includeAttendees: Bool = true) -> [String: Any] {
        var b: [String: Any] = [
            "summary": event.title ?? "",
            "location": event.location ?? "",
            "description": event.notes ?? "",
            "start": GoogleDates.json(event.startDate, allDay: event.isAllDay, timeZone: event.timeZone),
            "end": GoogleDates.json(event.endDate, allDay: event.isAllDay, timeZone: event.timeZone),
        ]
        if let url = event.url {
            b["source"] = ["url": url.absoluteString, "title": event.title ?? "Link"]
        }
        if let rules = event.recurrence, !rules.isEmpty, event.recurringEventId == nil {
            b["recurrence"] = rules
        }
        if includeAttendees, let attendees = event.attendees, !attendees.isEmpty {
            b["attendees"] = attendees.map { $0.googleJSON() }
        }
        if event.wantsMeet {
            b["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ],
            ]
        }
        return b
    }

    /// Only the fields that changed versus the cached record.
    static func patch(_ event: CalEvent, old: EventRecord?) -> [String: Any] {
        guard let old else { return full(event) }
        var b: [String: Any] = [:]
        if event.title != old.title { b["summary"] = event.title ?? "" }
        if event.location != old.location { b["location"] = event.location ?? "" }
        if event.notes != old.notes { b["description"] = event.notes ?? "" }
        if event.startDate != old.start || event.isAllDay != old.isAllDay {
            b["start"] = time(event.startDate, allDay: event.isAllDay, tz: event.timeZone)
        }
        if event.endDate != old.end || event.isAllDay != old.isAllDay {
            b["end"] = time(event.endDate, allDay: event.isAllDay, tz: event.timeZone)
        }
        if event.url?.absoluteString != old.url {
            if let url = event.url {
                b["source"] = ["url": url.absoluteString, "title": event.title ?? "Link"]
            } else {
                b["source"] = NSNull()
            }
        }
        if event.recurringEventId == nil, (event.recurrence ?? []) != (old.recurrence ?? []) {
            b["recurrence"] = event.recurrence ?? []
        }
        if (event.attendees ?? []) != (old.attendees ?? []) {
            b["attendees"] = (event.attendees ?? []).map { $0.googleJSON() }
        }
        if event.wantsMeet {
            b["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ],
            ]
        }
        return b
    }
}

/// RRULE helpers (Google stores recurrence as RFC 5545 lines).
enum RRule {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    /// End the rule before `date` (UNTIL = one second earlier, or the previous day for all-day series).
    static func truncated(_ rules: [String], before date: Date, allDay: Bool) -> [String] {
        rules.map { line in
            guard line.hasPrefix("RRULE:") else { return line }
            var parts = line.dropFirst(6).split(separator: ";").map(String.init)
                .filter { !$0.hasPrefix("UNTIL=") && !$0.hasPrefix("COUNT=") }
            let until = allDay
                ? dayFormatter.string(from: date.addingTimeInterval(-86400))
                : GoogleDates.rruleUTC.string(from: date.addingTimeInterval(-1))
            parts.append("UNTIL=\(until)")
            return "RRULE:" + parts.joined(separator: ";")
        }
    }

    /// Drop COUNT so a split-off series doesn't repeat the whole count again
    /// (ponytail: the remainder isn't computed, the new series runs until
    /// the original UNTIL or open-ended).
    static func stripped(_ rules: [String]) -> [String] {
        rules.map { line in
            guard line.hasPrefix("RRULE:") else { return line }
            let parts = line.dropFirst(6).split(separator: ";").map(String.init)
                .filter { !$0.hasPrefix("COUNT=") }
            return "RRULE:" + parts.joined(separator: ";")
        }
    }

    /// The RRULE's key/value parts.
    static func parts(_ rules: [String]?) -> [String: String] {
        guard let line = rules?.first(where: { $0.hasPrefix("RRULE:") }) else { return [:] }
        var parts: [String: String] = [:]
        for kv in line.dropFirst(6).split(separator: ";") {
            let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0]] = pair[1] }
        }
        return parts
    }

    /// The day an UNTIL rule ends on (local), if any.
    static func untilDay(_ rules: [String]?) -> Date? {
        guard let raw = parts(rules)["UNTIL"] else { return nil }
        return GoogleDates.rruleUTC.date(from: raw) ?? dayFormatter.date(from: String(raw.prefix(8)))
    }

    static func count(_ rules: [String]?) -> Int? {
        parts(rules)["COUNT"].flatMap(Int.init)
    }

    /// Rules ending on `day` (inclusive) or after `count` occurrences; nil for both = open-ended.
    static func ending(_ rules: [String], onDay day: Date?, count: Int?, allDay: Bool) -> [String] {
        let open = rules.map { line -> String in
            guard line.hasPrefix("RRULE:") else { return line }
            let parts = line.dropFirst(6).split(separator: ";").map(String.init)
                .filter { !$0.hasPrefix("UNTIL=") && !$0.hasPrefix("COUNT=") }
            return "RRULE:" + parts.joined(separator: ";")
        }
        if let day {
            let next = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Calendar.autoupdatingCurrent.startOfDay(for: day)) ?? day
            return truncated(open, before: next, allDay: allDay)
        }
        if let count { return open.map { $0.hasPrefix("RRULE:") ? $0 + ";COUNT=\(count)" : $0 } }
        return open
    }
}
