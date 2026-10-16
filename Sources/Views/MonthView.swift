import SwiftUI

/// Row height shared by month rows and the time grid's week strip — the two
/// must render identically for the grid↔month zoom to hand off invisibly.
let monthRowHeight: CGFloat = 108

/// Weekday header height shared by the month view and the time grid, so the
/// grid's week strip and the month's rows line up at the zoom handoff.
let dayHeaderHeight: CGFloat = 28

/// All-day lanes that fit a 108pt row (24pt header + 5 × 16pt bars). Bars
/// past the cap are dropped and surface as a per-day "+N" marker instead.
let monthSpanLaneCap = 5

/// Continuous vertically-scrolling month view (a stack of week rows spanning
/// ±1–2 years). The header month updates as you scroll; navigation scrolls here.
struct MonthView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    private let rowHeight: CGFloat = monthRowHeight
    /// Two-way scroll anchor: the week at the top of the viewport. Seeded at
    /// init so the first layout lands on the viewed week without instantiating
    /// the lazy rows above it (scrollTo(id:) built ~a year of rows to get
    /// there), and since it tracks the user's scrolling, re-renders can't
    /// re-assert a stale position.
    @State private var topWeek: Date?

    init(initialWeek: Date) {
        _topWeek = State(initialValue: initialWeek)
    }

    private var weeks: [Date] {
        let cal = appState.calendar
        let today = Date()
        guard let windowStart = cal.date(byAdding: .month, value: -12, to: today),
              let windowEnd = cal.date(byAdding: .month, value: 24, to: today) else { return [] }
        var result: [Date] = []
        var day = cal.startOfWeek(for: windowStart)
        while day < windowEnd {
            result.append(day)
            guard let next = cal.date(byAdding: .day, value: 7, to: day) else { break }
            day = next
        }
        return result
    }

    var body: some View {
        let cal = appState.calendar
        let allWeeks = weeks
        let gutter = settings.gridGutterWidth
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                // "Mon"…"Sun", matching the time grid's "Mon 13" headers.
                ForEach(cal.week(containing: Date()), id: \.self) { day in
                    Text(Fmt.weekdayShort.string(from: day))
                        .font(CWT.ui(12))
                        .foregroundStyle(cal.isDateInWeekend(day) ? CWT.inkSoft : CWT.ink)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: dayHeaderHeight)
            Divider()
            GeometryReader { geo in
                let cellW = (geo.size.width - gutter) / 7
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allWeeks, id: \.self) { weekStart in
                            MonthWeekRow(weekStart: weekStart, cellW: cellW, rowH: rowHeight)
                                .frame(height: rowHeight)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $topWeek, anchor: .top)
                .onAppear { appState.monthScrollTarget = nil } // consumed at init
                .onChange(of: appState.monthScrollTarget) {
                    guard let target = appState.monthScrollTarget else { return }
                    withAnimation(.linear(duration: 0.25)) {
                        topWeek = cal.startOfWeek(for: target)
                    }
                    appState.monthScrollTarget = nil
                }
                .onChange(of: topWeek) { updateCurrentMonth() }
            }
        }
    }

    /// The topmost visible week defines the header month while scrolling.
    private func updateCurrentMonth() {
        guard appState.viewMode == .month, let top = topWeek else { return }
        let cal = appState.calendar
        guard let representative = cal.date(byAdding: .day, value: 3, to: top) else { return }
        if !cal.isDate(representative, equalTo: appState.currentDate, toGranularity: .month) {
            appState.currentDate = representative
        }
    }
}

struct MonthWeekRow: View {
    let weekStart: Date
    let cellW: CGFloat
    let rowH: CGFloat
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let cal = appState.calendar
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let allBars = SpanLayout.bars(days: days, store: store, calendar: cal)
        let bars = allBars.filter { $0.lane < monthSpanLaneCap }
        let laneCount = (bars.map(\.lane).max() ?? -1) + 1
        let barsTop: CGFloat = 24
        HStack(alignment: .top, spacing: 0) {
            MonthRowGutter(weekStart: weekStart, width: settings.gridGutterWidth)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        MonthCell(day: day, cellW: cellW, rowH: rowH, laneInset: CGFloat(laneCount) * 16)
                            .frame(width: cellW, height: rowH)
                    }
                }
                ForEach(bars) { bar in
                    MonthSpanBar(bar: bar, cellW: cellW, rowH: rowH, barsTop: barsTop)
                }
                SpanOverflowMarkers(allBars: allBars, dayCount: days.count, cellW: cellW)
            }
        }
        .onAppear {
            // Lazy rows fetch their own range: on tall windows many weeks are
            // visible beyond the header month's fetch window.
            if let end = cal.date(byAdding: .day, value: 7, to: weekStart) {
                store.ensureFetched(DateInterval(start: weekStart, end: end))
            }
        }
    }
}

/// The animated layer of a grid↔month zoom: only the weeks AFTER the current
/// one, laid out exactly like the month view's rows. It slides up over the
/// hour grid (or down off it) beneath the pinned week strip — the current
/// week is not in this view at all, so it can never appear to move. When the
/// slide settles, the real MonthView replaces grid+sheet pixel for pixel.
struct MonthSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let gutter = settings.gridGutterWidth
            let cellW = (geo.size.width - gutter) / 7
            let cal = appState.calendar
            let start = cal.startOfWeek(for: appState.currentDate)
            let count = max(Int(ceil(geo.size.height / monthRowHeight)) + 1, 1)
            VStack(spacing: 0) {
                ForEach(1...count, id: \.self) { i in
                    if let week = cal.date(byAdding: .day, value: 7 * i, to: start) {
                        MonthWeekRow(weekStart: week, cellW: cellW, rowH: monthRowHeight)
                            .frame(height: monthRowHeight)
                    }
                }
            }
            .background(CWT.paper)
        }
    }
}

/// "+N" markers in the day-number line for all-day events dropped past the
/// lane cap, so a crowded day never hides events silently.
struct SpanOverflowMarkers: View {
    let allBars: [SpanBar]
    let dayCount: Int
    let cellW: CGFloat

    var body: some View {
        let hidden = allBars.filter { $0.lane >= monthSpanLaneCap }
        if !hidden.isEmpty {
            ForEach(0..<dayCount, id: \.self) { idx in
                let n = hidden.filter { $0.startIndex <= idx && idx <= $0.endIndex }.count
                if n > 0 {
                    Text("+\(n)")
                        .font(CWT.ui(10))
                        .foregroundStyle(CWT.inkSoft)
                        .frame(width: cellW - 8, alignment: .trailing)
                        .offset(x: CGFloat(idx) * cellW + 4, y: 6)
                }
            }
        }
    }
}

/// Leading gutter cell for a week row: shows the month name on the row
/// containing the 1st (the same idea as the year view's gutter). Used by both
/// the month view and the time grid's week strip.
struct MonthRowGutter: View {
    @EnvironmentObject var appState: AppState
    let weekStart: Date
    let width: CGFloat

    var body: some View {
        Text(label)
            .font(CWT.ui(10))
            .foregroundStyle(CWT.inkSoft)
            .padding(.leading, 6)
            .padding(.top, 4)
            .frame(width: width, alignment: .topLeading)
    }

    private var label: String {
        appState.calendar.firstOfMonth(inWeekStarting: weekStart).map(Fmt.month.string) ?? ""
    }
}

/// A span bar in the month grid: drag to move (horizontal = days, vertical =
/// weeks), drag an edge to extend into a multi-day span.
struct MonthSpanBar: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let bar: SpanBar
    let cellW: CGFloat
    let rowH: CGFloat
    let barsTop: CGFloat

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var moveTranslation: CGSize = .zero
    @State private var resizeCols = 0
    @State private var resizingLead = false
    @State private var isResizing = false

    private var isEditable: Bool {
        bar.event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        var startIdx = bar.startIndex
        var endIdx = bar.endIndex
        if isResizing {
            if resizingLead {
                startIdx = min(startIdx + resizeCols, endIdx)
            } else {
                endIdx = max(endIdx + resizeCols, startIdx)
            }
        }

        return SpanBarView(event: bar.event, duplicates: bar.duplicates, compact: true)
            .frame(width: CGFloat(endIdx - startIdx + 1) * cellW - 6, height: 14)
            #if os(macOS)
            .overlay(alignment: .leading) { if isEditable { resizeHandle(lead: true) } }
            .overlay(alignment: .trailing) { if isEditable { resizeHandle(lead: false) } }
            #endif
            .opacity(isDragging || isResizing ? 0.75 : 1)
            .zIndex(isDragging ? 100 : 0)
            #if os(iOS)
            .overlay {
                LongPressDrag(
                    onTap: { _ in appState.select(bar.event) },
                    onBegan: { _ in
                        guard isEditable else { return }
                        isDragging = true
                        moveTranslation = .zero
                    },
                    onMoved: { _, translation in
                        guard isEditable else { return }
                        moveTranslation = translation
                        dragOffset = snappedOffset(translation)
                    },
                    onEnded: { completed in
                        let translation = moveTranslation
                        isDragging = false
                        dragOffset = .zero
                        moveTranslation = .zero
                        guard completed, isEditable else { return }
                        shift(byDays: moveDelta(translation))
                    }
                )
            }
            #endif
            // Personal OS todo checkbox: above the bar's tap/drag layers (on
            // iOS, above LongPressDrag), so it toggles without selecting.
            .overlay(alignment: .leading) {
                PersonalOSCheckbox(store: store, event: bar.event,
                                   color: bar.event.calendar?.displayColor ?? Color.accentColor)
                    .padding(.leading, SpanBarView.contentInset(copies: 1 + bar.duplicates.count) - 2)
            }
            .offset(
                x: CGFloat(startIdx) * cellW + 3 + dragOffset.width,
                y: barsTop + CGFloat(bar.lane) * 16 + dragOffset.height
            )
            #if os(macOS)
            .gesture(moveDrag)
            .contextMenu { PersonalOSMenuItems(store: store, event: bar.event) }
            #endif
    }

    private func snappedOffset(_ translation: CGSize) -> CGSize {
        CGSize(
            width: (translation.width / cellW).rounded() * cellW,
            height: (translation.height / rowH).rounded() * rowH
        )
    }

    private func moveDelta(_ translation: CGSize) -> Int {
        Int((translation.width / cellW).rounded()) + 7 * Int((translation.height / rowH).rounded())
    }


    private func shift(byDays delta: Int) {
        guard delta != 0 else { return }
        let cal = appState.calendar
        let snapshot = EventSnapshot(bar.event)
        bar.event.startDate = cal.date(byAdding: .day, value: delta, to: bar.event.startDate) ?? bar.event.startDate
        bar.event.endDate = cal.date(byAdding: .day, value: delta, to: bar.event.endDate) ?? bar.event.endDate
        appState.commitChange(to: bar.event, snapshot: snapshot, isNew: false, store: store)
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = snappedOffset(value.translation)
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable else { return }
                shift(byDays: moveDelta(value.translation))
            }
    }

    private func resizeHandle(lead: Bool) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isResizing = true
                        resizingLead = lead
                        resizeCols = Int((value.translation.width / cellW).rounded())
                    }
                    .onEnded { value in
                        defer {
                            isResizing = false
                            resizeCols = 0
                        }
                        let delta = Int((value.translation.width / cellW).rounded())
                            + 7 * Int((value.translation.height / rowH).rounded())
                        guard delta != 0 else { return }
                        let cal = appState.calendar
                        let snapshot = EventSnapshot(bar.event)
                        if lead {
                            guard let newStart = cal.date(byAdding: .day, value: delta, to: bar.event.startDate),
                                  newStart < bar.event.endDate else { return }
                            bar.event.startDate = newStart
                        } else {
                            guard let newEnd = cal.date(byAdding: .day, value: delta, to: bar.event.endDate),
                                  newEnd > bar.event.startDate else { return }
                            bar.event.endDate = newEnd
                        }
                        appState.commitChange(to: bar.event, snapshot: snapshot, isNew: false, store: store)
                    }
            )
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    let day: Date
    let cellW: CGFloat
    let rowH: CGFloat
    var laneInset: CGFloat = 0
    /// The time grid's week strip reuses this cell but shows timed events on
    /// the hour grid instead of as title chips.
    var showsTimedEvents = true
    /// The time grid's strip hides the number (its column header shows it)
    /// but keeps the line, which anchors the all-day bars below.
    var showsDayNumber = true

    /// Highlighted while drag-creating an all-day span, or covered by a
    /// drag-created event still open (unsaved) in the details panel.
    private var isInDraftRange: Bool {
        let cal = appState.calendar
        let key = cal.startOfDay(for: day)
        if let range = appState.monthDragRange { return range.contains(key) }
        if let ctx = appState.panelContext, ctx.isNew, ctx.event.isAllDay,
           let s = ctx.event.startDate, let e = ctx.event.endDate {
            let startDay = cal.startOfDay(for: s)
            let lastDay = cal.startOfDay(for: max(e.addingTimeInterval(-1), s))
            return key >= startDay && key <= lastDay
        }
        return false
    }

    var body: some View {
        let cal = appState.calendar
        let events = EventLayout.mergeDuplicates(
            (settings.monthAllDayOnly || !showsTimedEvents) ? [] : store.events(on: day, calendar: cal).timed,
            rank: { store.sidebarRank($0.calendar?.calendarIdentifier) }
        )
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let dayOfMonth = cal.component(.day, from: day)
        let month = cal.component(.month, from: day)
        let evenMonth = month % 2 == 0
        let isWeekend = cal.isDateInWeekend(day)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(dayOfMonth == 1 ? monthDayLabel : Fmt.dayNum.string(from: day))
                    .font(CWT.ui(11))
                    .padding(.horizontal, isToday ? 5 : 0)
                    .frame(height: 20)
                    .background { if isToday { Rectangle().fill(CWT.signalRed) } }
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .opacity(showsDayNumber ? 1 : 0)
                    .accessibilityHidden(!showsDayNumber)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3)
            if laneInset > 0 {
                Color.clear.frame(height: laneInset)
            }
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, pair in
                MonthChip(event: pair.primary, duplicates: pair.duplicates, cellW: cellW, rowH: rowH)
            }
            if events.count > 3 {
                Text("\(events.count - 3) more")
                    .font(CWT.ui(10))
                    .foregroundStyle(CWT.inkSoft)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            (evenMonth ? CWT.paper2 : Color.clear)
                .overlay(isWeekend ? CWT.paper3.opacity(0.55) : Color.clear)
                .overlay(isInDraftRange ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(CWT.rule).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(CWT.ruleSoft).frame(width: 1)
        }
        .contentShape(Rectangle())
        #if os(iOS)
        // Background layer so chips' own touch layers stay above it.
        .background {
            LongPressDrag(
                onTap: { _ in
                    if appState.panelContext != nil {
                        appState.closePanel()
                    } else {
                        appState.currentDate = day
                    }
                },
                onBegan: { _ in
                    updateDragRange(translation: .zero)
                },
                onMoved: { _, translation in
                    updateDragRange(translation: translation)
                },
                onEnded: { completed in
                    if completed {
                        finishDragCreate()
                    } else {
                        appState.monthDragRange = nil
                    }
                }
            )
        }
        #else
        .onTapGesture(count: 2) {
            appState.currentDate = day
            appState.setViewMode(.day)
        }
        .onTapGesture { appState.currentDate = day }
        .gesture(createDrag)
        .onHover { inside in if inside { appState.pasteTarget = (day, false) } }
        #endif
    }

    private func updateDragRange(translation: CGSize) {
        let cal = appState.calendar
        let delta = Int((translation.width / cellW).rounded())
            + 7 * Int((translation.height / rowH).rounded())
        let anchor = cal.startOfDay(for: day)
        let target = cal.date(byAdding: .day, value: delta, to: anchor) ?? anchor
        appState.monthDragRange = min(anchor, target)...max(anchor, target)
    }

    private func finishDragCreate() {
        if let range = appState.monthDragRange {
            let cal = appState.calendar
            let end = cal.date(byAdding: .day, value: 1, to: range.upperBound) ?? range.upperBound
            appState.newEvent(store: store, start: range.lowerBound, end: end, allDay: true)
        }
        appState.monthDragRange = nil
    }

    /// Drag across cells to create a (multi-day) all-day event — horizontal =
    /// days, vertical = weeks, mirroring how chips move.
    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                updateDragRange(translation: value.translation)
            }
            .onEnded { _ in
                finishDragCreate()
            }
    }


    private var monthDayLabel: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: day)
    }
}

struct MonthChip: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    let event: CalEvent
    /// Identical copies on other calendars, merged into this chip.
    var duplicates: [CalEvent] = []
    var cellW: CGFloat = 120
    var rowH: CGFloat = 108

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var moveTranslation: CGSize = .zero

    private var isEditable: Bool {
        event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        HStack(spacing: 4) {
            if duplicates.isEmpty, !event.needsMyResponse {
                Circle().fill(color).frame(width: 5, height: 5)
            } else {
                // One strip per calendar this event lives on; dashed = awaiting my RSVP.
                CalendarStrips(copies: [event] + duplicates)
                    .frame(height: 11)
            }
            if !event.isAllDay, let s = event.startDate {
                Text(Fmt.time.string(from: s))
                    .font(CWT.ui(10))
                    .foregroundStyle(CWT.inkSoft)
            }
            Text(event.title ?? "Untitled")
                .font(CWT.ui(10))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(CWT.eventShape(compact: true).fill(
            isDragging ? color.opacity(0.35) : color.opacity(isSelected ? 0.3 : event.isAllDay ? 0.16 : 0)
        ))
        .overlay { if event.myParticipantStatus == .declined { DeclinedSlash(color: color) } }
        .overlay {
            if event.needsMyResponse {
                CWT.eventShape(compact: true)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .zIndex(isDragging ? 100 : 0)
        .opacity(isDragging ? 0.85 : 1)
        #if os(iOS)
        .overlay {
            LongPressDrag(
                onTap: { _ in appState.select(event) },
                onBegan: { _ in
                    guard isEditable else { return }
                    isDragging = true
                    moveTranslation = .zero
                },
                onMoved: { _, translation in
                    guard isEditable else { return }
                    moveTranslation = translation
                    dragOffset = translation
                },
                onEnded: { completed in
                    let translation = moveTranslation
                    isDragging = false
                    dragOffset = .zero
                    moveTranslation = .zero
                    guard completed, isEditable else { return }
                    commitMove(translation)
                }
            )
        }
        #endif
        .onTapGesture { appState.select(event) }
        #if os(macOS)
        .gesture(moveDrag)
        .contextMenu {
            Button("Copy") { appState.copyEvent(event, store: store) }
            if isEditable {
                Button("Duplicate") { store.duplicate(event) }
                Button("Delete", role: .destructive) { appState.requestDelete(event, store: store) }
            }
            Button("Copy title") { Clipboard.copy(event.title ?? "") }
            PersonalOSMenuItems(store: store, event: event)
        }
        #endif
    }

    private func commitMove(_ translation: CGSize) {
        let dayDelta = Int((translation.width / cellW).rounded())
            + 7 * Int((translation.height / rowH).rounded())
        guard dayDelta != 0 else { return }
        let snapshot = EventSnapshot(event)
        let cal = appState.calendar
        event.startDate = cal.date(byAdding: .day, value: dayDelta, to: event.startDate) ?? event.startDate
        event.endDate = cal.date(byAdding: .day, value: dayDelta, to: event.endDate) ?? event.endDate
        appState.commitChange(to: event, snapshot: snapshot, isNew: false, store: store)
    }

    /// Drag a chip to another day cell — horizontal = days, vertical = weeks.
    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable else { return }
                commitMove(value.translation)
            }
    }
}
