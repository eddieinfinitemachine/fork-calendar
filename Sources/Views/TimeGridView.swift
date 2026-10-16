import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Day/N-day/week timeline. Renders three "pages" (previous / current / next
/// period) in a clipped strip so trackpad side-scrolling pans smoothly into
/// the neighboring weeks before snapping.
struct TimeGridView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    let days: [Date]

    private var gutterWidth: CGFloat { settings.gridGutterWidth }
    private var hourHeight: CGFloat { appState.hourHeight }
    @State private var zoomBase: CGFloat?
    @State private var zoomAnchorHours: CGFloat?
    @State private var zoomAnchorY: CGFloat = 0
    @State private var gridScroll = ScrollPosition(edge: .top)

    var body: some View {
        GeometryReader { outer in
            let pageWidth = max(outer.size.width - gutterWidth, 1)
            let colWidth = pageWidth / CGFloat(max(days.count, 1))
            let extDays = appState.visibleDays(pageOffset: -1, current: days) + days + appState.visibleDays(pageOffset: 1, current: days)
            let allStripBars = SpanLayout.bars(days: extDays, store: store, calendar: appState.calendar, stableLanes: true)
            let stripBars = allStripBars.filter { $0.lane < monthSpanLaneCap }
            let stripLanes = (stripBars.map(\.lane).max() ?? -1) + 1

            VStack(spacing: 0) {
                // The strip's clipped content still hit-tests one page beyond
                // its bounds, so everything in the gutter column sits above it
                // (zIndex) to keep clicks from landing on invisible columns.
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth, height: 1)
                    PagedStrip(pan: appState.pan, pageWidth: pageWidth) {
                        HStack(spacing: 0) {
                            ForEach(extDays, id: \.self) { day in
                                dayHeader(day)
                                    .frame(width: colWidth)
                                    // New columns are pushed in by the layout,
                                    // not faded in (no-fade zoom policy).
                                    .transition(.identity)
                            }
                        }
                    }
                }
                // Same height as the month view's header, so the strip below
                // sits where the month's first row does at the zoom handoff.
                .frame(height: dayHeaderHeight)
                .background(CWT.paper)
                .overlay(alignment: .leading) {
                    // Zone labels for the gutter columns; doubles as the click
                    // blocker keeping the strip's invisible out-of-bounds
                    // headers from receiving gutter clicks.
                    HStack(spacing: 0) {
                        ForEach(settings.secondaryTZs, id: \.self) { id in
                            Text(TimeZone(identifier: id)?.abbreviation() ?? AppSettings.timeZoneLabel(id))
                                .font(CWT.ui(9))
                                .foregroundStyle(CWT.inkFaint)
                                .lineLimit(1)
                                .frame(width: 42, alignment: .trailing)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)
                    .frame(width: gutterWidth, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                Divider()
                // The shared week strip: the same MonthCell + MonthSpanBar
                // the month view renders its rows with, so the dates and
                // all-day events on both sides of a grid↔month zoom are
                // identical pixels and the fold hands off invisibly.
                HStack(alignment: .top, spacing: 0) {
                    // Gutter month label; also blocks clicks from reaching the
                    // strip's invisible out-of-bounds content.
                    MonthRowGutter(
                        weekStart: appState.calendar.startOfWeek(for: days.first ?? appState.currentDate),
                        width: gutterWidth
                    )
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .zIndex(1)
                    PagedStrip(pan: appState.pan, pageWidth: pageWidth) {
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                ForEach(extDays, id: \.self) { day in
                                    // The day number lives in the column header
                                    // above; it shows here only while the month
                                    // zoom runs, so the handoff to the month's
                                    // rows stays pixel-identical.
                                    MonthCell(day: day, cellW: colWidth, rowH: monthRowHeight,
                                              laneInset: CGFloat(stripLanes) * 16, showsTimedEvents: false,
                                              showsDayNumber: appState.gridMonthOverlap)
                                        .frame(width: colWidth, height: monthRowHeight)
                                        .transition(.identity)
                                }
                            }
                            ForEach(stripBars) { bar in
                                MonthSpanBar(bar: bar, cellW: colWidth, rowH: monthRowHeight, barsTop: 24)
                            }
                            SpanOverflowMarkers(allBars: allStripBars, dayCount: extDays.count, cellW: colWidth)
                        }
                        .frame(width: pageWidth * 3, alignment: .topLeading)
                    }
                }
                .frame(height: monthRowHeight)
                .background(CWT.paper)
                // The month sheet masks itself above this line while sliding
                // over the hour grid, keeping this strip the only copy visible.
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("calBody")).maxY }) { _, y in
                    appState.stripBottomY = y
                }
                Divider()
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        timeGutter
                            .zIndex(1)
                        PagedStrip(pan: appState.pan, pageWidth: pageWidth) {
                            ZStack(alignment: .topLeading) {
                                hourLines
                                HStack(spacing: 0) {
                                    ForEach(extDays, id: \.self) { day in
                                        if appState.gridNeighborsLive || days.contains(day) {
                                            DayColumn(day: day, colWidth: colWidth, hourHeight: hourHeight)
                                                .transition(.identity)
                                        } else {
                                            // Offscreen neighbor pages render as
                                            // empty space while a zoom/column
                                            // animation runs — see gridNeighborsLive.
                                            Color.clear.frame(width: colWidth)
                                                .transition(.identity)
                                        }
                                    }
                                }
                            }
                            .frame(width: pageWidth * 3)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .padding(.bottom, 20)
                    #if os(iOS)
                    .background { SideScrollPan(appState: appState) }
                    #endif
                }
                .background(CWT.paper)
                .scrollPosition($gridScroll)
                .onScrollGeometryChange(for: CGRect.self, of: {
                    CGRect(x: $0.contentOffset.y, y: $0.containerSize.height, width: 0, height: 0)
                }) { _, new in
                    appState.gridScrollY = new.origin.x
                    appState.gridViewportH = new.origin.y
                }
                .simultaneousGesture(zoomGesture)
                .onAppear {
                    gridScroll.scrollTo(y: appState.hourHeight * 8)
                }
            }
            // Column-geometry animation is scoped to zoomTick, not driven by
            // withAnimation transactions: a store publish coalescing into the
            // same update cycle used to strip the transaction and snap the
            // columns. Pans and event refreshes don't touch the tick, so they
            // never animate by accident.
            .animation(AppState.zoomAnimation, value: appState.zoomTick)
            .onAppear {
                appState.weekPageWidth = pageWidth
                appState.gridColumnWidth = colWidth
            }
            .onChange(of: outer.size.width) {
                appState.weekPageWidth = pageWidth
                appState.gridColumnWidth = colWidth
            }
            .onChange(of: days.count) {
                appState.gridColumnWidth = pageWidth / CGFloat(max(days.count, 1))
            }
            .onChange(of: appState.currentDate) {
                guard !appState.isPanning else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { appState.pan.offset = 0 }
            }
        }
    }

    /// Pinch to zoom the hour scale (28–160 pt/hour), anchored at the pinch
    /// location so the hours under the fingers stay in view.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                appState.isZooming = true
                if zoomBase == nil {
                    zoomBase = appState.hourHeight
                    let viewportH = appState.gridViewportH > 0 ? appState.gridViewportH : 400
                    zoomAnchorY = value.startAnchor.y * viewportH
                    zoomAnchorHours = (appState.gridScrollY + zoomAnchorY) / appState.hourHeight
                }
                let newHeight = min(160, max(28, (zoomBase ?? 56) * value.magnification))
                appState.hourHeight = newHeight
                if let hours = zoomAnchorHours {
                    gridScroll.scrollTo(y: max(0, hours * newHeight - zoomAnchorY))
                }
            }
            .onEnded { _ in
                zoomBase = nil
                zoomAnchorHours = nil
                appState.isZooming = false
            }
    }

    /// "Mon 13" column header (Calendar.app pattern); today's number in the
    /// red badge, weekends in the secondary ink.
    private func dayHeader(_ day: Date) -> some View {
        let cal = appState.calendar
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let ink = cal.isDateInWeekend(day) ? CWT.inkSoft : CWT.ink
        return HStack(spacing: 4) {
            Text(Fmt.weekdayShort.string(from: day))
                .foregroundStyle(ink)
            Text(Fmt.dayNum.string(from: day))
                .padding(.horizontal, isToday ? 5 : 0)
                .frame(height: 20)
                .background { if isToday { Rectangle().fill(CWT.signalRed) } }
                .foregroundStyle(isToday ? Color.white : ink)
        }
        .font(CWT.ui(12))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var timeGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 0) {
                    ForEach(settings.secondaryTZs, id: \.self) { id in
                        Group {
                            if hour > 0, let tz = TimeZone(identifier: id) {
                                Text(hourLabel(hour, timeZone: tz))
                                    .font(CWT.mono(10))
                                    .foregroundStyle(CWT.inkFaint)
                                    .offset(y: -6)
                            }
                        }
                        .frame(width: 42, alignment: .topTrailing)
                    }
                    Group {
                        if hour > 0 {
                            Text(hourLabel(hour, timeZone: nil))
                                .font(CWT.mono(11))
                                .foregroundStyle(CWT.inkSoft)
                                .padding(.trailing, 8)
                                .offset(y: -6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                .frame(width: gutterWidth, height: hourHeight, alignment: .top)
            }
        }
        .frame(width: gutterWidth)
        .contentShape(Rectangle())
        .contextMenu {
            Menu("Add time zone") {
                ForEach(AppSettings.curatedTimeZones.filter { !settings.secondaryTZs.contains($0) }, id: \.self) { id in
                    Button(AppSettings.timeZoneLabel(id)) { settings.secondaryTZs.append(id) }
                }
            }
            if !settings.secondaryTZs.isEmpty {
                Divider()
                ForEach(settings.secondaryTZs, id: \.self) { id in
                    Button("Remove \(AppSettings.timeZoneLabel(id))") {
                        settings.secondaryTZs.removeAll { $0 == id }
                    }
                }
            }
        }
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Color.clear
                    .frame(height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(CWT.rule).frame(height: 1)
                    }
            }
        }
    }

    private func hourLabel(_ hour: Int, timeZone: TimeZone?) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        if let timeZone {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("j")
            f.timeZone = timeZone
            return f.string(from: date)
        }
        return Fmt.hour.string(from: date)
    }
}

/// Clips a 3-page-wide strip to one page and applies the live pan offset.
/// Observes only PanModel, so per-frame side-scroll updates re-render just
/// these three thin wrappers instead of the whole grid.
struct PagedStrip<Content: View>: View {
    @ObservedObject var pan: PanModel
    let pageWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .offset(x: -pageWidth + pan.offset)
            .frame(width: pageWidth, alignment: .leading)
            .clipped()
    }
}

struct DayColumn: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var draftStart: CGFloat?
    @State private var draftEnd: CGFloat?

    var body: some View {
        let timed = store.events(on: day, calendar: appState.calendar).timed
        let positioned = EventLayout.layout(timed, rank: { store.sidebarRank($0.calendar?.calendarIdentifier) })
        ZStack(alignment: .topLeading) {
            if appState.calendar.isDateInWeekend(day) {
                CWT.paper3.opacity(0.55)
                    .allowsHitTesting(false)
            }
            Color.clear
                .contentShape(Rectangle())
                #if os(macOS)
                .gesture(createDrag)
                .gesture(SpatialTapGesture().onEnded { value in
                    // Single click never creates a timed event — only drags do
                    // (all-day events can still be made with one click up top).
                    if appState.availabilityMode {
                        addSlot(fromY: snap(value.location.y), toY: snap(value.location.y) + hourHeight / 2)
                    } else if appState.panelContext != nil {
                        appState.closePanel()
                    }
                })
                #endif

            #if os(iOS)
            // Long-press drops a 1-hour draft; drag adjusts; release opens the
            // editor. Sits below the event blocks so their layers win touches.
            LongPressDrag(
                onTap: { _ in
                    if appState.panelContext != nil { appState.closePanel() }
                },
                onBegan: { point in
                    draftStart = snap(point.y)
                    draftEnd = (draftStart ?? 0) + hourHeight
                },
                onMoved: { point, translation in
                    if abs(translation.height) > 8 { draftEnd = snap(point.y) }
                },
                onEnded: { completed in
                    defer {
                        draftStart = nil
                        draftEnd = nil
                    }
                    guard completed, let s = draftStart, var e = draftEnd else { return }
                    if abs(e - s) < hourHeight / 4 { e = s + hourHeight }
                    createEvent(fromY: min(s, e), toY: max(s, e))
                }
            )
            #endif

            if let s = draftStart, let e = draftEnd {
                CWT.eventShape()
                    .fill(draftColor.opacity(0.22))
                    .overlay(CWT.eventShape().strokeBorder(draftColor.opacity(0.6)))
                    .frame(width: colWidth - 6, height: max(abs(e - s), 10))
                    .offset(x: 2, y: min(s, e))
                    .allowsHitTesting(false)
            }

            // Drag-created event awaiting save: keep its box visible while the
            // details panel is open.
            if let ctx = appState.panelContext, ctx.isNew, !ctx.event.isAllDay,
               let s = ctx.event.startDate, let e = ctx.event.endDate {
                let dayStart = appState.calendar.startOfDay(for: day)
                let dayEnd = dayStart.addingTimeInterval(86400)
                if s < dayEnd, e > dayStart {
                    let y = CGFloat(max(s, dayStart).timeIntervalSince(dayStart) / 3600) * hourHeight
                    let h = CGFloat(min(e, dayEnd).timeIntervalSince(max(s, dayStart)) / 3600) * hourHeight
                    CWT.eventShape()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(CWT.eventShape().strokeBorder(Color.accentColor.opacity(0.6)))
                        .frame(width: colWidth - 6, height: max(h, 10))
                        .offset(x: 2, y: y)
                        .allowsHitTesting(false)
                }
            }

            ForEach(appState.availabilitySlots.filter { $0.start.isSameDay(as: day, calendar: appState.calendar) }) { slot in
                let dayStart = appState.calendar.startOfDay(for: day)
                let y = CGFloat(slot.start.timeIntervalSince(dayStart) / 3600) * hourHeight
                let h = CGFloat(slot.end.timeIntervalSince(slot.start) / 3600) * hourHeight
                CWT.eventShape()
                    .fill(CWT.signalGreen.opacity(0.25))
                    .overlay(CWT.eventShape().strokeBorder(CWT.signalGreen.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .frame(width: colWidth - 6, height: max(h, 8))
                    .offset(x: 2, y: y)
                    .onTapGesture {
                        appState.availabilitySlots.removeAll { $0.id == slot.id }
                    }
            }

            ForEach(positioned) { item in
                EventBlockView(item: item, day: day, colWidth: colWidth, hourHeight: hourHeight)
            }

            if day.isSameDay(as: Date(), calendar: appState.calendar) {
                NowLine(hourHeight: hourHeight)
            }
        }
        .frame(width: colWidth, height: hourHeight * 24)
        .overlay(alignment: .leading) {
            Rectangle().fill(CWT.rule).frame(width: 1)
        }
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active(let p) = phase { appState.pasteTarget = (date(atY: snap(p.y)), true) }
        }
        #endif
    }

    private var draftColor: Color {
        appState.availabilityMode ? CWT.signalGreen : .accentColor
    }

    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draftStart == nil { draftStart = snap(value.startLocation.y) }
                draftEnd = snap(value.location.y)
            }
            .onEnded { _ in
                if let s = draftStart, let e = draftEnd, abs(e - s) >= hourHeight / 8 {
                    if appState.availabilityMode {
                        addSlot(fromY: min(s, e), toY: max(s, e))
                    } else {
                        createEvent(fromY: min(s, e), toY: max(s, e))
                    }
                }
                draftStart = nil
                draftEnd = nil
            }
    }

    private func snap(_ y: CGFloat) -> CGFloat {
        // Same zoom-dependent step as event drags: 5/10/15-minute snapping.
        let minutes: CGFloat = hourHeight >= 112 ? 5 : hourHeight >= 64 ? 10 : 15
        let step = hourHeight * minutes / 60
        return (y / step).rounded() * step
    }

    private func date(atY y: CGFloat) -> Date {
        let clamped = max(0, min(y, hourHeight * 24))
        let hours = Double(clamped / hourHeight)
        return appState.calendar.startOfDay(for: day).addingTimeInterval(hours * 3600)
    }

    private func createEvent(fromY: CGFloat, toY: CGFloat) {
        let start = date(atY: fromY)
        var end = date(atY: toY)
        if end <= start { end = start.addingTimeInterval(1800) }
        appState.newEvent(store: store, start: start, end: end)
    }

    private func addSlot(fromY: CGFloat, toY: CGFloat) {
        let start = date(atY: fromY)
        var end = date(atY: toY)
        if end <= start { end = start.addingTimeInterval(1800) }
        appState.availabilitySlots.append(AvailabilitySlot(start: start, end: end))
    }
}

struct NowLine: View {
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = Calendar.autoupdatingCurrent.startOfDay(for: context.date)
            let y = CGFloat(context.date.timeIntervalSince(start) / 3600) * hourHeight
            HStack(spacing: 0) {
                Rectangle().fill(CWT.signalRed).frame(width: 5, height: 5)
                Rectangle().fill(CWT.signalRed).frame(height: 1)
            }
            .offset(y: y - 2.5)
        }
        .allowsHitTesting(false)
    }
}

struct EventBlockView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var invoices = InvoiceLink.shared
    @Environment(\.openURL) private var openURL
    let item: PositionedEvent
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var moveTranslation: CGSize = .zero
    @State private var resizeDelta: CGFloat = 0
    @State private var resizingTop = false
    @State private var isResizing = false

    private var isEditable: Bool {
        item.event.calendar?.allowsContentModifications == true
    }

    /// The primary copy plus any merged duplicates from other calendars.
    private var copies: [CalEvent] { [item.event] + item.duplicates }

    var body: some View {
        let cal = appState.calendar
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let start = max(item.event.startDate ?? dayStart, dayStart)
        let end = min(item.event.endDate ?? dayEnd, dayEnd)
        var y = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
        var height = max(CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight, 16)
        let subWidth = (colWidth - 6) / CGFloat(item.columnCount)
        let x = 2 + subWidth * CGFloat(item.column)
        let color = item.event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == item.id
        let isPast = (item.event.endDate ?? Date()) < Date()
        let joinURL = MeetLink.url(for: item.event)
        let awaiting = item.event.needsMyResponse

        if isResizing {
            if resizingTop {
                y += resizeDelta
                height = max(height - resizeDelta, hourHeight / 4)
            } else {
                height = max(height + resizeDelta, hourHeight / 4)
            }
        }

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(item.event.title ?? "Untitled")
                    .font(CWT.ui(12))
                    .lineLimit(height > 32 ? 2 : 1)
                if joinURL != nil, height > 20, subWidth > 60 {
                    Image(systemName: "video.fill")
                        .font(CWT.ui(9))
                }
                if invoices.billed.contains(item.event.id) {
                    Image(systemName: "dollarsign")
                        .font(CWT.ui(9))
                }
            }
            if height > 34 || isResizing || isDragging, let s = item.event.startDate, let e = item.event.endDate {
                // Live readout: while resizing/moving, show the times the
                // commit would produce (deltas are already snapped).
                let resizeMin = Double(resizeDelta / hourHeight) * 60
                let moveMin = Double(dragOffset.height / hourHeight) * 60
                let ds = isResizing ? (resizingTop ? s.addingTimeInterval(resizeMin * 60) : s)
                       : isDragging ? s.addingTimeInterval(moveMin * 60) : s
                let de = isResizing ? (resizingTop ? e : e.addingTimeInterval(resizeMin * 60))
                       : isDragging ? e.addingTimeInterval(moveMin * 60) : e
                Text(Fmt.interval.string(from: ds, to: de))
                    .font(CWT.ui(10))
                    .opacity(0.75)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.leading, 4 + CalendarStrips.totalWidth(count: copies.count))
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(width: max(subWidth - 2, 12), height: height, alignment: .topLeading)
        .background(CWT.eventShape().fill(color.opacity(
            awaiting ? 0.07 : isSelected ? 0.28 : 0.16
        )))
        .overlay(alignment: .leading) {
            // One strip per calendar this event lives on; dashed = awaiting my RSVP.
            CalendarStrips(copies: copies)
                .padding(.vertical, 1)
        }
        .clipShape(CWT.eventShape())
        .overlay { if item.event.myParticipantStatus == .declined { DeclinedSlash(color: color) } }
        .overlay {
            if awaiting {
                CWT.eventShape()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: isSelected ? 1.8 : 1.2, dash: [4, 3]))
            } else if isSelected {
                CWT.eventShape().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .top) {
            if showsResizeHandles(isSelected: isSelected) {
                resizeHandle(top: true)
            }
        }
        .overlay(alignment: .bottom) {
            if showsResizeHandles(isSelected: isSelected) {
                resizeHandle(top: false)
            }
        }
        .opacity((isDragging ? 0.7 : 1) * (isPast && !isSelected ? 0.55 : 1))
        #if os(iOS)
        .overlay {
            LongPressDrag(
                onTap: { _ in appState.select(item.event) },
                onBegan: { _ in
                    guard isEditable else { return }
                    isDragging = true
                    moveTranslation = .zero
                },
                onMoved: { _, translation in
                    guard isEditable else { return }
                    moveTranslation = translation
                    dragOffset = snappedMoveOffset(translation)
                },
                onEnded: { completed in
                    defer {
                        isDragging = false
                        dragOffset = .zero
                        moveTranslation = .zero
                    }
                    guard completed, isEditable, isDragging else { return }
                    commitMove(moveTranslation)
                }
            )
        }
        #endif
        .offset(x: x + dragOffset.width, y: y + dragOffset.height)
        .onTapGesture { appState.select(item.event) }
        #if os(macOS)
        .gesture(moveDrag)
        .contextMenu { contextMenuItems(joinURL: joinURL) }
        #endif
    }

    /// On touch, handles appear only on the selected event so drags on
    /// unselected blocks scroll the grid (Notion Calendar behavior).
    private func showsResizeHandles(isSelected: Bool) -> Bool {
        guard isEditable, !appState.availabilityMode else { return false }
        #if os(iOS)
        return isSelected
        #else
        return true
        #endif
    }

    @ViewBuilder
    private func contextMenuItems(joinURL: URL?) -> some View {
        if item.event.attendees?.isEmpty == false {
            Menu("RSVP") {
                Button("Going") { rsvp(.accepted) }
                Button("Maybe") { rsvp(.tentative) }
                Button("Not going") { rsvp(.declined) }
            }
        }
        if let joinURL {
            Button {
                openURL(joinURL)
            } label: {
                Label("Join meeting", systemImage: "video")
            }
        }
        Button {
            appState.select(item.event)
        } label: {
            Label("Open", systemImage: "sidebar.right")
        }
        #if os(macOS)
        Button {
            appState.copyEvent(item.event, store: store)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        #endif
        if isEditable {
            Button {
                store.duplicate(item.event)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu("Move to calendar") {
                ForEach(store.writableCalendars, id: \.calendarIdentifier) { cal in
                    Button(cal.title) { store.move(item.event, to: cal) }
                }
            }
        }
        Button {
            Clipboard.copy(item.event.title ?? "")
        } label: {
            Label("Copy title", systemImage: "doc.on.doc")
        }
        Button {
            appState.billEvent(item.event)
        } label: {
            Label(invoices.billed.contains(item.event.id) ? "Bill to another invoice…" : "Bill to invoice…", systemImage: "dollarsign.circle")
        }
        PersonalOSMenuItems(store: store, event: item.event)
        if isEditable {
            Divider()
            Button(role: .destructive) {
                appState.requestDelete(item.event, store: store)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func rsvp(_ status: ParticipantStatus) {
        let event = item.event
        let s = store
        Task { await s.respond(event, status: status) }
    }

    private func resizeHandle(top: Bool) -> some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                // Global space: the handle MOVES with the resize preview, so
                // a local-space translation oscillated between snap steps
                // (the applied delta fed back into the measurement — jitter).
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        isResizing = true
                        resizingTop = top
                        // Live preview snaps to the zoom-dependent step
                        let step = hourHeight * snapMinutes / 60
                        resizeDelta = (value.translation.height / step).rounded() * step
                    }
                    .onEnded { value in
                        defer {
                            isResizing = false
                            resizeDelta = 0
                        }
                        let minutes = (Double(value.translation.height / hourHeight) * 60 / snapMinutes).rounded() * snapMinutes
                        guard minutes != 0 else { return }
                        let snapshot = EventSnapshot(item.event)
                        if top {
                            let newStart = item.event.startDate.addingTimeInterval(minutes * 60)
                            guard newStart < item.event.endDate else { return }
                            item.event.startDate = newStart
                        } else {
                            let newEnd = item.event.endDate.addingTimeInterval(minutes * 60)
                            guard newEnd > item.event.startDate else { return }
                            item.event.endDate = newEnd
                        }
                        appState.commitChange(to: item.event, snapshot: snapshot, isNew: false, store: store)
                    }
            )
    }

    /// Minute snap step for drags, finer as the hour scale zooms in.
    private var snapMinutes: Double {
        if hourHeight >= 112 { return 5 }
        if hourHeight >= 64 { return 10 }
        return 15
    }

    /// Live preview snaps to the zoom-dependent step and whole day columns
    private func snappedMoveOffset(_ translation: CGSize) -> CGSize {
        let step = hourHeight * snapMinutes / 60
        return CGSize(
            width: (translation.width / colWidth).rounded() * colWidth,
            height: (translation.height / step).rounded() * step
        )
    }

    private func commitMove(_ translation: CGSize) {
        let minuteDelta = (Double(translation.height / hourHeight) * 60 / snapMinutes).rounded() * snapMinutes
        let dayDelta = (translation.width / colWidth).rounded()
        guard minuteDelta != 0 || dayDelta != 0 else { return }
        let interval = minuteDelta * 60 + Double(dayDelta) * 86400
        var isOption = false
        #if os(macOS)
        isOption = NSEvent.modifierFlags.contains(.option)
        #endif
        if isOption {
            store.duplicate(item.event, dayOffset: interval / 86400)
        } else {
            let snapshot = EventSnapshot(item.event)
            item.event.startDate = item.event.startDate.addingTimeInterval(interval)
            item.event.endDate = item.event.endDate.addingTimeInterval(interval)
            appState.commitChange(to: item.event, snapshot: snapshot, isNew: false, store: store)
        }
    }

    private var moveDrag: some Gesture {
        // Global space: the block follows the preview offset, so a
        // local-space translation would feed back and jitter (see resize).
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = snappedMoveOffset(value.translation)
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
