import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if isCompact {
                // iPhone: the grid directly; calendar list lives in a sheet
                // (a collapsed NavigationSplitView would strand users on the
                // sidebar with no path to the detail column).
                CalendarDetailView()
                    .sheet(isPresented: $appState.showCalendarsSheet) {
                        NavigationStack { SidebarView() }
                    }
            } else {
                NavigationSplitView(columnVisibility: $appState.columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                        #if os(macOS)
                        // The header bar carries the sidebar toggle; with the
                        // title bar hidden there's no toolbar to host this one.
                        .toolbar(removing: .sidebarToggle)
                        #endif
                } detail: {
                    // Drawer overlays the calendar instead of pushing it aside:
                    // a floating glass card inset from the window edges.
                    CalendarDetailView()
                        .overlay(alignment: .trailing) {
                            if let ctx = appState.panelContext {
                                EventPanelView(context: ctx)
                                    .id(ctx.id)
                                    .frame(width: 320)
                                    .frame(maxHeight: .infinity)
                                    .cwtCard()
                                    .padding(CWT.cardMargin)
                                    .transition(.move(edge: .trailing))
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: appState.panelContext == nil)
                }
            }
        }
        .task {
            await store.requestAccess()
            // Don't rely on onChange(accessState) for the first fetch: the
            // accounts sink can flip it to .granted before this view attaches,
            // so no change ever fires and the window stays empty until a
            // keypress moves the date.
            fetchVisible()
            #if os(macOS)
            KeyMonitor.install(appState: appState, store: store)
            #endif
        }
        .onChange(of: appState.currentDate) { fetchVisible() }
        .onChange(of: appState.viewMode) { fetchVisible() }
        .onChange(of: store.accessState) { fetchVisible() }
        .onChange(of: store.events) { reresolveSelection() }
        .sheet(item: compactSheetBinding) { ctx in
            NavigationStack {
                EventPanelView(context: ctx, isSheet: true)
            }
        }
        .overlay {
            // Always mounted, shown by opacity: inserting the palette on
            // demand wedged its first open (the insertion transaction left
            // the subtree's updates dead — typing searched but the list
            // never changed). A mounted-but-hidden view has no insertion.
            CommandPalette()
                .opacity(appState.paletteOpen ? 1 : 0)
                .allowsHitTesting(appState.paletteOpen)
        }
        .overlay(alignment: .bottom) {
            if appState.availabilityMode {
                AvailabilityBar()
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = appState.toast {
                Text(toast)
                    .font(CWT.ui(12))
                    .foregroundStyle(CWT.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .cwtCard(in: Capsule())
                    .padding(14)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        appState.toast = nil
                    }
            }
        }
        // One presentation per host view: stacked confirmationDialog / alert
        // modifiers on a single view only present one of them on macOS, which
        // left the repeating-event delete dialog (and its delete) dead.
        .background {
            Color.clear
                .confirmationDialog(
                "This is a repeating event.",
                isPresented: $appState.showSpanDialog,
                titleVisibility: .visible
            ) {
                Button("This event only") { appState.resolveSpanAction(span: .thisEvent, store: store) }
                Button("This and all future events") { appState.resolveSpanAction(span: .futureEvents, store: store) }
                Button("Cancel", role: .cancel) { appState.resolveSpanAction(span: nil, store: store) }
            }
        }
        .background {
            Color.clear
                .confirmationDialog(
                store.notifyPrompt.map { "\($0.title) — email \($0.guestCount == 1 ? "the guest" : "\($0.guestCount) guests")?" } ?? "",
                isPresented: Binding(get: { store.notifyPrompt != nil }, set: { if !$0 { store.resolveNotifyPrompt(false) } }),
                titleVisibility: .visible
            ) {
                Button("Send email") { store.resolveNotifyPrompt(true) }
                Button("Don't send") { store.resolveNotifyPrompt(false) }
            } message: {
                Text("Google notifies guests by email. You can change the default in Settings.")
            }
        }
        .background {
            Color.clear
                .calendarSetNameAlert("Save calendar set", isPresented: $appState.showSaveCalendarSet,
                                      message: "Saves which calendars are showing now.") { name in
                store.saveCurrentAsSet(named: name)
            }
        }
        .onChange(of: store.toast) { _, message in
            if let message { appState.toast = message; store.toast = nil }
        }
        .sheet(isPresented: $appState.showSettingsSheet) {
            NavigationStack {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(store)
                    .navigationTitle("Settings")
                    #if os(iOS)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appState.showSettingsSheet = false }
                        }
                    }
                    #endif
            }
        }
    }

    private var compactSheetBinding: Binding<EditorContext?> {
        Binding(
            get: { isCompact ? appState.panelContext : nil },
            set: { appState.panelContext = $0 }
        )
    }

    private func fetchVisible() {
        let cal = appState.calendar
        var interval: DateInterval?
        switch appState.viewMode {
        case .month:
            let days = cal.monthGrid(for: appState.currentDate)
            if let first = days.first, let last = days.last {
                interval = DateInterval(start: first, end: cal.date(byAdding: .day, value: 1, to: last) ?? last)
            }
        case .year:
            let year = cal.component(.year, from: appState.currentDate)
            if let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
               let nextJan = cal.date(from: DateComponents(year: year + 1, month: 1, day: 8)) {
                interval = DateInterval(start: cal.startOfWeek(for: jan1), end: nextJan)
            }
        default:
            let days = appState.visibleDays
            if let first = days.first, let last = days.last {
                interval = DateInterval(start: cal.startOfDay(for: first), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last)
            }
        }
        if let interval { store.ensureFetched(interval) }
    }

    /// After a store refresh, re-point the open panel at the refreshed event instance.
    private func reresolveSelection() {
        guard let ctx = appState.panelContext, !ctx.isNew else { return }
        let key = eventKey(ctx.event)
        if let match = store.events.first(where: { eventKey($0) == key }), match !== ctx.event {
            appState.panelContext = EditorContext(event: match, isNew: false)
        }
    }
}

struct CalendarDetailView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var didSetInitialMode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // No rule under the header: its glass controls float over the
            // page rather than sitting in a ruled strip.
            HeaderBar()
            if store.accessState == .denied {
                AccessDeniedView()
            } else {
                // No fades: each layer is opaque and the deeper view draws on
                // top, so zooms are pure geometry — the top view covers or
                // reveals the one below. During a grid↔month zoom BOTH views
                // stay mounted (gridMonthOverlap): the grid's header strip and
                // the month's rows are live the whole time; the only motion is
                // the grid's hour section folding, and the hidden view
                // unmounts after the fold. .transition sits INSIDE the .id
                // identity boundary — outside it, the id swap replaces the
                // subtree without ever consulting the transition.
                let family = appState.viewMode.zoomFamily
                GeometryReader { geo in
                    let sheetTravel = max(geo.size.height - appState.stripBottomY, 0)
                    ZStack {
                        if family == .year {
                            YearView()
                                .background(CWT.paper)
                                .transition(zoomTransition)
                                .id(ZoomFamily.year)
                                .zIndex(0)
                        }
                        if family == .month {
                            // viewMode flips to .month only at overlap cleanup,
                            // after the sheet settles: this mounts as a static,
                            // pixel-identical swap — never during motion.
                            MonthView(initialWeek: appState.calendar.startOfWeek(
                                for: appState.monthScrollTarget ?? appState.currentDate))
                                .background(CWT.paper)
                                .transition(zoomTransition)
                                .id(ZoomFamily.month)
                                .zIndex(1)
                        }
                        if appState.gridMonthOverlap {
                            // Grid↔month zoom: the sheet of upcoming weeks
                            // slides up over the static hour grid (or down off
                            // it) beneath the pinned strip. The current week
                            // isn't in the sheet, so it cannot move. When the
                            // slide settles, the real MonthView (or the grid
                            // alone) takes over pixel for pixel.
                            MonthSheet()
                                .padding(.top, appState.stripBottomY)
                                .offset(y: appState.monthCover ? 0 : sheetTravel)
                                // Scoped to monthCover so the slide always
                                // animates (and nothing else rides along) no
                                // matter what shares the update cycle.
                                .animation(AppState.zoomAnimation, value: appState.monthCover)
                                .transition(.identity)
                                .zIndex(3)
                        }
                        if family == .grid || (appState.gridMonthOverlap && family == .month) {
                            TimeGridView(days: family == .grid ? appState.visibleDays : appState.gridOverlapDays)
                                .transition(zoomTransition)
                                .id(ZoomFamily.grid)
                                .zIndex(2)
                        }
                    }
                    .clipped()
                    .coordinateSpace(name: "calBody")
                }
            }
        }
        .background(CWT.paper)
        #if os(macOS)
        // Title bar hidden: the header bar takes the title-bar row itself,
        // level with the traffic lights, instead of sitting below an empty band.
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .onAppear {
            #if os(iOS)
            if !didSetInitialMode, sizeClass == .compact,
               UserDefaults.standard.string(forKey: "lastViewMode") == nil {
                // Direct set: the launch default should not play a zoom.
                // A saved mode from the last quit wins over this default.
                appState.viewMode = .days(3)
            }
            #endif
            didSetInitialMode = true
        }
    }

    /// Apple Calendar-style zoom. Zooming out (week → month → year), the
    /// current view collapses vertically into the row band it occupies in the
    /// shallower view while that view's other rows slide in from above and
    /// below; zooming in plays the reverse — the band stretches to fill the
    /// screen as the deeper view grows out of it.
    private var zoomTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let spec = appState.zoomSpec
        // Grid↔month mounts/unmounts are instant; the fold itself is layout
        // animation inside the grid, not a view transition.
        guard spec.kind == .band, spec.direction != 0, spec.scale > 1 else { return .identity }
        let anchor = UnitPoint(x: 0.5, y: spec.anchorY)
        let identity = RowBandZoom(scaleY: 1, anchor: anchor)
        let stretched = RowBandZoom(scaleY: spec.scale, anchor: anchor)
        let collapsed = RowBandZoom(scaleY: 1 / spec.scale, anchor: anchor)
        if spec.direction > 0 {
            return .asymmetric(
                insertion: .modifier(active: collapsed, identity: identity),
                removal: .modifier(active: stretched, identity: identity)
            )
        } else {
            return .asymmetric(
                insertion: .modifier(active: stretched, identity: identity),
                removal: .modifier(active: collapsed, identity: identity)
            )
        }
    }
}

/// Vertical scale about a fixed anchor row — no fade. The anchor keeps the
/// shared week band pinned in place while the rest of the view compresses or
/// expands around it.
private struct RowBandZoom: ViewModifier {
    var scaleY: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: scaleY, anchor: anchor)
    }
}

struct HeaderBar: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.openSettings) private var openSettings
    #endif

    private var showsCalendarsButton: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    #if os(macOS)
    private var sidebarCollapsed: Bool { appState.columnVisibility == .detailOnly }
    #endif

    var body: some View {
        HStack(spacing: 10) {
            if showsCalendarsButton {
                Button {
                    appState.showCalendarsSheet = true
                } label: {
                    Image(systemName: "sidebar.leading")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt)
                .help("Calendars")
                .accessibilityLabel("Calendars")
            }
            #if os(macOS)
            Button {
                appState.columnVisibility = sidebarCollapsed ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.leading")
                    .frame(minWidth: Self.iconMinWidth)
            }
            .buttonStyle(.cwt)
            .help("Toggle sidebar (⌘\\)" as String)
            .accessibilityLabel("Toggle sidebar")
            #endif
            Text(Fmt.monthYear.string(from: appState.currentDate))
                #if os(iOS)
                .font(CWT.ui(12))
                #else
                .font(CWT.ui(17, bold: true))
                #endif
                .lineLimit(1)
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 2)
            }
            CWTGlassGroup {
                #if os(macOS)
                // ‹ Today › — ←/→ already step; this makes paging visible.
                // (iOS pages by swipe, and its header has no room.)
                Button {
                    appState.step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt)
                .help("Previous (←)")
                .accessibilityLabel("Previous")
                #endif
                Button("Today") { appState.goToToday() }
                    .buttonStyle(.cwt)
                    .help("Today (T)")
                #if os(macOS)
                Button {
                    appState.step(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt)
                .help("Next (→)")
                .accessibilityLabel("Next")
                #endif
            }
            viewMenu
            // Icon actions share one glass group, like a system toolbar's.
            CWTGlassGroup {
                Button {
                    appState.toggleAvailabilityMode()
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt(on: appState.availabilityMode))
                .prominentLabel(appState.availabilityMode)
                .help("Share availability (S)")
                .accessibilityLabel("Share availability")
                Button {
                    appState.paletteOpen = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt)
                .help("Search & commands (⌘K)")
                .accessibilityLabel("Search & commands")
                // No accounts yet: a disabled prominent button renders nearly invisible
                // on iOS, so show a plain one that leads to Settings instead.
                Button {
                    if store.accessState == .granted {
                        appState.newEvent(store: store)
                    } else {
                        #if os(iOS)
                        appState.showSettingsSheet = true
                        #else
                        openSettings()
                        #endif
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: Self.iconMinWidth)
                }
                .buttonStyle(.cwt(on: store.accessState == .granted))
                .prominentLabel(store.accessState == .granted)
                .help(store.accessState == .granted ? "New event (C)" : "Add a Google account in Settings")
                .accessibilityLabel(store.accessState == .granted ? "New event" : "Add a Google account in Settings")
            }
        }
        // Bordered controls don't inherit the root environment font.
        .font(CWT.ui(12))
        #if os(iOS)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        #else
        // The title bar is hidden (single header, HIG): clear the traffic
        // lights when the sidebar no longer sits under them, and let the
        // header's empty space drag the window.
        .padding(.leading, sidebarCollapsed ? 78 : 14)
        // Clears the window's rounded top-trailing corner.
        .padding(.trailing, 18)
        // 4pt top centers the 24pt controls on the traffic lights.
        .padding(.top, 4)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        #endif
    }

    /// Icon-only header buttons share one width, wider than they are tall
    /// (label + the face's 2×10pt padding ≥ 28pt).
    private static let iconMinWidth: CGFloat = 18

    private var viewMenu: some View {
        Menu {
            Button { appState.setViewMode(.day) } label: { menuLabel("Day", "D", appState.viewMode == .day) }
            Button { appState.setViewMode(.week) } label: { menuLabel("Week", "W", appState.viewMode == .week) }
            Button { appState.setViewMode(.month) } label: { menuLabel("Month", "M", appState.viewMode == .month) }
            Button { appState.setViewMode(.year) } label: { menuLabel("Year", "Y", appState.viewMode == .year) }
            Divider()
            ForEach([2, 3, 4, 5, 9], id: \.self) { n in
                Button { appState.setViewMode(.days(n)) } label: {
                    menuLabel("\(n) days", "\(n)", appState.viewMode == .days(n))
                }
            }
            Divider()
            Button { settings.showDeclined.toggle() } label: {
                menuLabel("Show declined events", "⇧⌘D", settings.showDeclined)
            }
        } label: {
            Text(appState.viewMode.title + " ▾")
        }
        .menuStyle(.button)
        .buttonStyle(.cwt)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Day (D) · Week (W) · Month (M) · 1–9 days")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, _ key: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

struct AvailabilityBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
            Text(appState.availabilitySlots.isEmpty
                 ? "Drag on the calendar to select available times"
                 : "\(appState.availabilitySlots.count) slot\(appState.availabilitySlots.count == 1 ? "" : "s") selected")
                .font(CWT.ui(12))
            if !appState.availabilitySlots.isEmpty {
                Button("Copy availability") {
                    Clipboard.copy(appState.availabilityText())
                    appState.toggleAvailabilityMode()
                }
                .buttonStyle(.cwt(on: true))
                .prominentLabel()
                Button("Clear") { appState.availabilitySlots.removeAll() }
                    .buttonStyle(.cwt)
            }
            Button("Done") { appState.toggleAvailabilityMode() }
                .buttonStyle(.cwt)
                .help("Esc")
        }
        .font(CWT.ui(12))
        .foregroundStyle(CWT.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cwtCard(in: Capsule())
    }
}

struct AccessDeniedView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var accounts = AccountManager.shared
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(CWT.ui(40))
                .foregroundStyle(CWT.inkSoft)
            Text("No Google account connected")
                .font(CWT.ui(13))
            Text("Fork Calendar talks to Google Calendar directly. Sign in with each account you want to see.")
                .font(CWT.ui(12))
                .foregroundStyle(CWT.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if settings.googleClientID.isEmpty {
                #if os(macOS)
                SettingsLink { Text("Open Settings to add an OAuth client…") }
                #else
                Button("Open Settings to add an OAuth client…") { appState.showSettingsSheet = true }
                #endif
            } else {
                Button(accounts.isSigningIn ? "Waiting for Google…" : "Add Google account…") {
                    Task { await accounts.addAccount() }
                }
                .buttonStyle(.cwt(on: true, size: 13))
                .prominentLabel()
                .disabled(accounts.isSigningIn)
            }
            if !accounts.statusMessage.isEmpty {
                Text(accounts.statusMessage)
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
