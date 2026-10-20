import Combine
import SwiftUI

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    /// Runs with the palette still open (the Claude row: the conversation
    /// happens inside the palette).
    var keepsOpen = false
    let action: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        PaletteBody(model: appState.palette)
    }
}

private struct PaletteBody: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: PaletteModel
    @ObservedObject private var assistant = Assistant.shared
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    /// Results live in view state and are rebuilt through Combine
    /// subscriptions created ONCE in `onAppear` — not `onReceive` (whose
    /// publisher is recreated every render, and each resubscription re-emits
    /// the current query, which re-renders: a livelock that starved real
    /// updates), and not inline in `body` (query publishes during the
    /// overlay's insertion could wedge that observation: the field kept
    /// accepting text while the list stayed stale).
    @State private var items: [PaletteItem] = []
    /// The assistant panel's content height: the panel hugs short replies
    /// and scrolls past 380pt.
    @State private var assistantHeight: CGFloat = 44
    @State private var subs: [AnyCancellable] = []

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { appState.paletteOpen = false }
            card(items: items)
        }
        .onAppear {
            subs = [
                model.$query.removeDuplicates().receive(on: DispatchQueue.main).sink { _ in
                    model.index = 0
                    refresh()
                },
                store.objectWillChange
                    .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                    .sink { _ in refresh() },
                InvoiceLink.shared.objectWillChange
                    .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                    .sink { _ in refresh() },
                model.$confirmTick.dropFirst().receive(on: DispatchQueue.main).sink { _ in
                    if assistant.isEngaged {
                        assistantReturn()
                        return
                    }
                    guard items.indices.contains(model.index) else { return }
                    run(items[model.index])
                },
                // ⌘↩: always the assistant (a follow-up when a conversation is open).
                model.$askTick.dropFirst().receive(on: DispatchQueue.main).sink { _ in
                    let q = model.query.trimmingCharacters(in: .whitespaces)
                    guard assistant.isConfigured, model.billing == nil, !q.isEmpty else { return }
                    askClaude(q)
                },
                // The palette stays mounted for the window's whole life;
                // each open resets the query and takes keyboard focus here.
                appState.$paletteOpen.removeDuplicates().receive(on: DispatchQueue.main).sink { open in
                    if open {
                        model.reset()
                        refresh()
                        focused = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
                    } else {
                        focused = false
                        model.billing = nil
                        // Esc / closing ends the conversation (and cancels a run).
                        assistant.reset()
                    }
                },
            ]
        }
        .onDisappear { subs = [] }
    }

    private func run(_ item: PaletteItem) {
        if !item.keepsOpen { appState.paletteOpen = false }
        item.action()
    }

    private func askClaude(_ text: String) {
        assistant.ask(text, store: store)
        model.query = ""
        focused = true
    }

    /// ↩ while a conversation is showing: send what's typed as the reply,
    /// or confirm the plan when the field is empty.
    private func assistantReturn() {
        guard !assistant.isRunning else { return }
        let q = model.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            askClaude(q)
        } else if !assistant.plan.isEmpty {
            assistant.confirm(store: store, appState: appState)
        }
    }

    private func openAssistantSettings() {
        appState.paletteOpen = false
        #if os(macOS)
        openSettings()
        #else
        appState.showSettingsSheet = true
        #endif
    }

    private func refresh() {
        items = buildItems()
        model.itemCount = items.count
        if model.index >= items.count { model.index = max(0, items.count - 1) }
    }

    private func card(items: [PaletteItem]) -> some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if assistant.isEngaged {
                assistantPanel
            } else {
                resultsList(items: items)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .cwtCard()
        .padding(.top, 80)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CWT.inkSoft)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(CWT.ui(16))
                .focused($focused)
                // macOS routes ↩ through KeyMonitor; this is iOS's return key.
                .onSubmit { if assistant.isEngaged { assistantReturn() } }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func resultsList(items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack, rows keyed by position: LazyVStack cached rows
                // by the .id(i) override while the ForEach was keyed on
                // per-build UUIDs, so refreshed results never re-rendered.
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        PaletteRow(item: item, selected: i == model.index)
                            .id(i)
                            .onTapGesture { run(item) }
                            .onHover2 { _ in model.index = i }
                    }
                    if items.isEmpty {
                        Text("No results")
                            .font(CWT.ui(13))
                            .foregroundStyle(CWT.inkSoft)
                            .padding(20)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .onChange(of: model.index) {
                proxy.scrollTo(model.index)
            }
        }
    }

    private var placeholder: String {
        if let event = model.billing { return "Bill “\(event.title ?? "Untitled")” to draft invoice…" }
        if assistant.isEngaged { return assistant.plan.isEmpty ? "Reply to Claude…" : "Change something, or ↩ to confirm…" }
        return "Search events or type a command…"
    }

    private var footer: some View {
        HStack {
            if assistant.isEngaged {
                if assistant.isRunning {
                    Text("esc cancel")
                } else if !assistant.plan.isEmpty {
                    Text("↩ confirm")
                    Text("type to change the plan")
                    Text("esc cancel")
                } else {
                    Text("↩ reply")
                    Text("esc close")
                }
            } else {
                Text("↑↓ navigate")
                Text("↩ select")
                if assistant.isConfigured, let hint = Self.macShortcut("⌘↩ ask Claude") { Text(hint) }
                Text("esc close")
            }
            Spacer()
        }
        .font(CWT.ui(10))
        .foregroundStyle(CWT.inkFaint)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func buildItems() -> [PaletteItem] {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        var items: [PaletteItem] = []

        // Billing mode: draft invoices only
        if let event = model.billing {
            let link = InvoiceLink.shared
            let drafts = q.isEmpty ? link.drafts : link.drafts.filter { ($0.client + " " + $0.id).localizedCaseInsensitiveContains(q) }
            if drafts.isEmpty {
                return [PaletteItem(title: link.error ?? "No draft invoices", subtitle: "Create one at invoice.cwandt.com", icon: "doc.text", shortcut: nil) {}]
            }
            return drafts.map { d in
                PaletteItem(title: "\(d.client) — \(d.id)", subtitle: "draft · \(String(format: "%g", d.hours))h so far", icon: "dollarsign.circle", shortcut: nil) {
                    Task {
                        do {
                            try await link.bill(event, to: d)
                            appState.toast = "Billed to \(d.id)"
                        } catch {
                            appState.toast = error.localizedDescription
                        }
                    }
                }
            }
        }

        // Natural-language quick add ("Lunch with Amy tomorrow 1pm")
        let quickAdd = QuickAdd.parse(q, defaultDurationMinutes: appState.settings.defaultDuration)
        if let parsed = quickAdd {
            items.append(PaletteItem(
                title: "Create “\(parsed.title)”",
                subtitle: "\(Fmt.dateTime.string(from: parsed.start)) – \(Fmt.time.string(from: parsed.end))",
                icon: "plus.circle.fill",
                shortcut: "↩"
            ) {
                appState.newEvent(store: store, start: parsed.start, end: parsed.end, title: parsed.title)
            })
        }

        // "Go to date" natural entry
        let goTo = parseDate(q)
        if let date = goTo {
            let f = DateFormatter()
            f.dateStyle = .full
            items.append(PaletteItem(title: "Go to \(f.string(from: date))", subtitle: nil, icon: "arrow.right.circle", shortcut: nil) {
                appState.goTo(date)
            })
        }

        // Commands
        let commands: [PaletteItem] = [
            PaletteItem(title: "Go to today", subtitle: nil, icon: "calendar", shortcut: "T") { appState.goToToday() },
            PaletteItem(title: "New event", subtitle: nil, icon: "plus", shortcut: "C") { appState.newEvent(store: store) },
            PaletteItem(title: "Day view", subtitle: nil, icon: "rectangle", shortcut: "D") { appState.setViewMode(.day) },
            PaletteItem(title: "Week view", subtitle: nil, icon: "rectangle.split.3x1", shortcut: "W") { appState.setViewMode(.week) },
            PaletteItem(title: "Month view", subtitle: nil, icon: "square.grid.3x3", shortcut: "M") { appState.setViewMode(.month) },
            PaletteItem(title: "Year view", subtitle: nil, icon: "square.grid.4x3.fill", shortcut: "Y") { appState.setViewMode(.year) },
            PaletteItem(title: "Share availability", subtitle: nil, icon: "square.and.arrow.up.on.square", shortcut: "S") { appState.toggleAvailabilityMode() },
            PaletteItem(title: "Undo", subtitle: nil, icon: "arrow.uturn.backward", shortcut: "⌘Z") { store.undo() },
            PaletteItem(title: "Sync now", subtitle: "Pull changes from every Google account", icon: "arrow.triangle.2.circlepath", shortcut: "⌘R") { store.refresh() },
            PaletteItem(title: appState.settings.showDeclined ? "Hide declined events" : "Show declined events", subtitle: nil, icon: "person.crop.circle.badge.xmark", shortcut: Self.macShortcut("⇧⌘D")) {
                appState.settings.showDeclined.toggle()
            },
            PaletteItem(title: "Show all calendars", subtitle: nil, icon: "eye", shortcut: nil) { store.showAllCalendars() },
            PaletteItem(title: "Hide all calendars", subtitle: nil, icon: "eye.slash", shortcut: nil) { store.hideAllCalendars() },
            // The palette closes before the action runs; RootView hosts the prompt.
            PaletteItem(title: "Save calendar set…", subtitle: "Name the calendars showing now", icon: "square.stack.3d.up", shortcut: nil) {
                appState.showSaveCalendarSet = true
            },
        ] + store.calendarSets.enumerated().map { i, set in
            PaletteItem(
                title: "Focus: \(set.name)",
                subtitle: store.isActive(set) ? "Showing now" : "\(set.visibleIDs.count) calendar\(set.visibleIDs.count == 1 ? "" : "s")",
                icon: store.isActive(set) ? "checkmark.circle" : "square.stack.3d.up",
                shortcut: i < 9 ? Self.macShortcut("⌥⌘\(i + 1)") : nil
            ) { store.apply(set) }
        } + personalOSCommands
        let matchedCommands = q.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(q) }
        items.append(contentsOf: matchedCommands)

        // Event search
        let hits = q.count >= 2 ? Array(store.searchEvents(q).prefix(12)) : []

        // Ask Claude: first when the text reads like a request rather than a
        // command / event / quick add; otherwise after those matches (⌘↩
        // sends it either way).
        if assistant.isConfigured, !q.isEmpty {
            let ask = PaletteItem(title: "Ask Claude: \(q)", subtitle: nil, icon: "sparkles",
                                  shortcut: Self.macShortcut("⌘↩"), keepsOpen: true) { askClaude(q) }
            let words = q.split(whereSeparator: \.isWhitespace)
            let request = Self.requestWords.contains(words.first.map { $0.lowercased() } ?? "") || q.hasSuffix("?")
            let weakMatch = quickAdd == nil && goTo == nil && (hits.isEmpty || words.count >= 4)
            if matchedCommands.isEmpty && (request || weakMatch) {
                items.insert(ask, at: 0)
            } else {
                items.append(ask)
            }
        }

        if !hits.isEmpty {
            for event in hits {
                items.append(PaletteItem(
                    title: event.title ?? "Untitled",
                    subtitle: Fmt.dateTime.string(from: event.startDate) + (event.calendar.map { " · \($0.title)" } ?? ""),
                    icon: "calendar.day.timeline.left",
                    shortcut: nil
                ) {
                    appState.goTo(event.startDate)
                    if appState.viewMode == .month { appState.setViewMode(.week) }
                    appState.select(event)
                })
            }
        }
        return items
    }

    /// First words that make the text a request for Claude, not a quick add.
    private static let requestWords: Set<String> = [
        "schedule", "reschedule", "cancel", "move", "push", "decline", "accept", "rsvp", "book",
        "find", "clear", "invite", "delete", "remove", "shift", "block", "set", "plan", "put",
        "what", "what's", "whats", "when", "who", "how", "which", "do", "am", "is", "are",
        "can", "could", "please", "make", "free", "skip", "drop",
    ]

    // MARK: - Assistant

    private var assistantPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(assistant.prompts.enumerated()), id: \.offset) { _, prompt in
                    Text(prompt)
                        .font(CWT.ui(12))
                        .foregroundStyle(CWT.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch assistant.phase {
                case .running(let status):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(CWT.ui(13))
                            .foregroundStyle(CWT.inkSoft)
                    }
                case .failed(let error):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(CWT.ui(13))
                            .foregroundStyle(CWT.signalRed)
                            .fixedSize(horizontal: false, vertical: true)
                        if error.needsSettings {
                            Button("Open Settings") { openAssistantSettings() }
                                .buttonStyle(.cwt(size: 12))
                        }
                    }
                case .answered:
                    if !assistant.reply.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(CWT.accent)
                            Text(Self.markdown(assistant.reply))
                                .font(CWT.ui(13))
                                .foregroundStyle(CWT.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .idle:
                    EmptyView()
                }
                if !assistant.plan.isEmpty, !assistant.isRunning {
                    planPreview
                }
            }
            .padding(14)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { assistantHeight = $0 }
        }
        .frame(height: min(max(assistantHeight, 44), 380))
    }

    private var planPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(assistant.plan.enumerated()), id: \.element.id) { i, step in
                    if i > 0 { Rectangle().fill(CWT.rule).frame(height: 1) }
                    PlanRow(step: step)
                }
            }
            .background(CWT.paper2.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CWT.rule, lineWidth: 1))
            HStack(spacing: 8) {
                if assistant.needsEmailChoice {
                    Toggle("Email guests", isOn: $assistant.emailGuests)
                        .font(CWT.ui(12))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(CWT.accent)
                        .fixedSize()
                }
                Spacer()
                Button("Cancel") { appState.paletteOpen = false }
                    .buttonStyle(.cwt(size: 13))
                    .help("Discard the plan (esc)")
                Button {
                    assistant.confirm(store: store, appState: appState)
                } label: {
                    Text(assistant.plan.count == 1 ? "Confirm" : "Confirm \(assistant.plan.count) changes")
                }
                .buttonStyle(.cwt(on: true, size: 13))
                .prominentLabel()
                .help("Make these changes (↩)")
            }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Personal OS actions on the selected event (open in the panel), like
    /// billing: done / not done for an EC todo, "Follow up" for any other.
    private var personalOSCommands: [PaletteItem] {
        guard PersonalOS.shared.isConfigured, let ctx = appState.panelContext, !ctx.isNew else { return [] }
        let event = ctx.event
        let title = PersonalOS.displayTitle(event.title) ?? "Untitled"
        if event.personalOSTodoID != nil {
            let state = PersonalOS.shared.state(of: event)
            guard state != .dropped else { return [] }
            return [PaletteItem(
                title: state == .done ? "Mark not done in Personal OS" : "Mark done in Personal OS",
                subtitle: title, icon: state == .done ? "square" : "checkmark.square", shortcut: nil
            ) { store.setPersonalOSCompleted(event, state != .done) }]
        }
        return [PaletteItem(title: "Follow up in Personal OS", subtitle: title, icon: "arrowshape.turn.up.right", shortcut: nil) {
            store.followUpInPersonalOS(event)
        }]
    }

    /// Shortcut hints for menu-bar-only shortcuts (no menu bar on iOS).
    private static func macShortcut(_ s: String) -> String? {
        #if os(macOS)
        return s
        #else
        return nil
        #endif
    }

    private func parseDate(_ q: String) -> Date? {
        guard !q.isEmpty else { return nil }
        let cal = appState.calendar
        let lower = q.lowercased()
        switch lower {
        case "today": return Date()
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: Date())
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: Date())
        case "next week": return cal.date(byAdding: .weekOfYear, value: 1, to: Date())
        default: break
        }
        // Weekday name → next occurrence
        let symbols = cal.weekdaySymbols.map { $0.lowercased() }
        if let idx = symbols.firstIndex(where: { $0.hasPrefix(lower) && lower.count >= 3 }) {
            let target = idx + 1
            for offset in 1...7 {
                if let d = cal.date(byAdding: .day, value: offset, to: Date()),
                   cal.component(.weekday, from: d) == target {
                    return d
                }
            }
        }
        for format in ["M/d/yyyy", "M/d", "MMM d", "MMMM d", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = format
            if let d = f.date(from: q) {
                var comps = cal.dateComponents([.month, .day], from: d)
                comps.year = format.contains("y") ? cal.component(.year, from: d) : cal.component(.year, from: Date())
                return cal.date(from: comps)
            }
        }
        return nil
    }
}

/// One step of the assistant's plan: "Delete · Weekly Leads · Tue 12:00–1:15 PM · 4 guests (no email)".
private struct PlanRow: View {
    let step: PlannedAction

    private var icon: String {
        switch step.verb {
        case "Delete": return "trash"
        case "Decline": return "xmark.circle"
        case "Create": return "plus.circle"
        case "Move": return "arrow.right.circle"
        case "Accept": return "checkmark.circle"
        case "Maybe": return "questionmark.circle"
        default: return "pencil.circle"
        }
    }

    private var destructive: Bool { step.verb == "Delete" || step.verb == "Decline" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(destructive ? CWT.signalRed : CWT.inkSoft)
            VStack(alignment: .leading, spacing: 2) {
                (Text(step.verb).font(CWT.ui(13, bold: true)).foregroundColor(destructive ? CWT.signalRed : CWT.ink)
                 + Text(" · " + step.title).font(CWT.ui(13)).foregroundColor(CWT.ink))
                    .lineLimit(2)
                Text(([step.when] + step.details).joined(separator: " · "))
                    .font(CWT.ui(12))
                    .foregroundStyle(CWT.inkSoft)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.summary)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(CWT.inkSoft)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(CWT.ui(13))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(CWT.ui(12))
                        .foregroundStyle(CWT.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(CWT.ui(12))
                    .foregroundStyle(CWT.inkSoft)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

private extension View {
    /// onHover that no-ops on iOS.
    @ViewBuilder
    func onHover2(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        onHover { if $0 { action(true) } }
        #else
        self
        #endif
    }
}
