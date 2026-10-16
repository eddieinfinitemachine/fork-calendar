import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var accounts = AccountManager.shared
    @ObservedObject private var personalOS = PersonalOS.shared
    @State private var showSettings = false
    @State private var showSaveSet = false
    @State private var renameTarget: CalendarSet?
    @State private var showRenameSet = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private func needsReauth(_ source: String) -> Bool {
        accounts.accounts.first(where: { $0.email == source })?.needsReauth == true
    }

    private var reauthAccounts: [GoogleAccount] { accounts.accounts.filter(\.needsReauth) }

    /// "OFFLINE", "3 QUEUED", "SIGN IN: cw@cwandt.com", or joined with " · ".
    private var offlineStatus: String {
        var parts: [String] = []
        if store.isOffline { parts.append("OFFLINE") }
        if store.pendingCount > 0 { parts.append("\(store.pendingCount) QUEUED") }
        for a in reauthAccounts { parts.append("SIGN IN: \(a.email)") }
        return parts.joined(separator: " · ")
    }

    private func openSettingsUI() {
        #if os(macOS)
        openSettings()
        #else
        showSettings = true
        #endif
    }

    /// Persist a drag reorder within one account section: the saved order is
    /// the full sidebar sequence with that section's new arrangement in place.
    private func moveCalendars(in group: (source: String, calendars: [CalCalendar]), from: IndexSet, to: Int) {
        var cals = group.calendars
        cals.move(fromOffsets: from, toOffset: to)
        var order: [String] = []
        for g in store.calendarsBySource {
            order += (g.source == group.source ? cals : g.calendars).map(\.calendarIdentifier)
        }
        settings.calendarOrder = order
        store.invalidateSidebarRank()
    }

    var body: some View {
        List {
            Section {
                MiniMonthView()
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
                    .listRowSeparator(.hidden)
            }
            focusSection
            if personalOS.isConfigured {
                callSheetSection
            }
            ForEach(store.calendarsBySource, id: \.source) { group in
                Section {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        CalendarRow(cal: cal)
                    }
                    .onMove { from, to in
                        moveCalendars(in: group, from: from, to: to)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Text(group.source.uppercased())
                            .font(CWT.ui(10))
                            .tracking(0.6)
                            .foregroundStyle(CWT.inkSoft)
                        if needsReauth(group.source) {
                            Button {
                                openSettingsUI()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("SIGN IN AGAIN")
                                        .kerning(0.4)
                                }
                                .font(CWT.ui(10))
                                .foregroundStyle(CWT.signalOrange)
                            }
                            .buttonStyle(.plain)
                            .help("This account's sign-in expired — tap to open Settings")
                        }
                    }
                }
            }
        }
        .navigationTitle("Fork Calendar")
        // Own prompts (not AppState's): on iPhone this list sits in a sheet,
        // where RootView can't present over it.
        .calendarSetNameAlert("Save calendar set", isPresented: $showSaveSet,
                              message: "Saves which calendars are showing now.") { name in
            store.saveCurrentAsSet(named: name)
        }
        .calendarSetNameAlert("Rename calendar set", isPresented: $showRenameSet,
                              initial: renameTarget?.name ?? "", confirm: "Rename",
                              message: "") { name in
            if let target = renameTarget { store.renameSet(target, to: name) }
        }
        #if os(iOS)
        // Programmatic push: a NavigationLink inside a List's safeAreaInset
        // doesn't reliably activate on iOS, so the gear drives this instead.
        .navigationDestination(isPresented: $showSettings) {
            SettingsView().navigationTitle("Settings")
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            // CW&T ID label: the codename is the logo.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    // The per-account "SIGN IN AGAIN" header only exists once that account has
                    // cached calendars; this pill covers a dead token on a fresh import.
                    if store.isOffline || store.pendingCount > 0 || !reauthAccounts.isEmpty {
                        Button {
                            if reauthAccounts.isEmpty { store.refresh() } else { openSettingsUI() }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: !reauthAccounts.isEmpty ? "exclamationmark.triangle.fill" : store.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                                Text(offlineStatus)
                                    .kerning(0.4)
                            }
                            .font(CWT.ui(10))
                            .foregroundStyle(CWT.signalOrange)
                        }
                        .buttonStyle(.plain)
                        .help("Changes made offline sync automatically when you're back online — tap to retry now")
                        .padding(.bottom, 3)
                    }
                    Text("CWT_STE0GW1_2607")
                        .font(CWT.ui(10))
                        .kerning(0.5)
                        .foregroundStyle(CWT.inkSoft)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")")
                        .font(CWT.ui(10))
                        .foregroundStyle(CWT.inkFaint)
                }
                Spacer()
                #if os(macOS)
                SettingsLink {
                    Image(systemName: "gearshape").font(CWT.ui(12)).foregroundStyle(CWT.inkSoft)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Accounts & settings (⌘,)")
                .accessibilityLabel("Accounts & settings")
                #else
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape").font(CWT.ui(15)).foregroundStyle(CWT.inkSoft)
                        // Finger-sized target — the bare glyph is ~15pt.
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accounts & settings")
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// "FOCUS": saved calendar sets (named visibility configurations) with
    /// one-click All / None, and + to save what's showing now as a new set.
    private var focusSection: some View {
        Section {
            if store.calendarSets.isEmpty {
                Text("Save the current calendars as a set with +")
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            } else {
                ForEach(store.calendarSets) { set in
                    CalendarSetRow(set: set) {
                        renameTarget = set
                        showRenameSet = true
                    }
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("FOCUS")
                    .font(CWT.ui(10))
                    .tracking(0.6)
                    .foregroundStyle(CWT.inkSoft)
                Spacer(minLength: 4)
                focusHeaderButton(label: "ALL", help: "Show all calendars") { store.showAllCalendars() }
                focusHeaderButton(label: "NONE", help: "Hide all calendars") { store.hideAllCalendars() }
                focusHeaderButton(systemImage: "plus", help: "Save the calendars showing now as a set") {
                    showSaveSet = true
                }
            }
        }
    }

    /// "CALL SHEET": today's people to call, from Personal OS. The box
    /// checks a person off, the name opens them in the browser, the swap
    /// control asks for someone else. Refreshed with every sync pass.
    private var callSheetSection: some View {
        Section {
            if let error = personalOS.callSheetError {
                callSheetNote(error)
            } else if personalOS.callSheet.isEmpty {
                callSheetNote("Nothing on the call sheet today")
            } else {
                ForEach(personalOS.callSheet) { item in
                    CallSheetRow(item: item)
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("CALL SHEET")
                    .font(CWT.ui(10))
                    .tracking(0.6)
                    .foregroundStyle(CWT.inkSoft)
                Spacer(minLength: 4)
                focusHeaderButton(systemImage: "arrow.clockwise", help: "Refresh the call sheet") {
                    Task { await personalOS.refreshCallSheet() }
                }
            }
        }
    }

    private func callSheetNote(_ text: String) -> some View {
        Text(text)
            .font(CWT.ui(11))
            .foregroundStyle(CWT.inkFaint)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    /// Compact header control, header-styled, with a ≥24pt target.
    private func focusHeaderButton(label: String? = nil, systemImage: String? = nil,
                                   help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else if let label {
                    Text(label).kerning(0.4)
                }
            }
            .font(CWT.ui(10))
            .foregroundStyle(CWT.inkSoft)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One call-sheet person: checkbox, name, then the reason in faint smaller
/// type; done calls fade and strike behind a checked box. Trailing swap
/// control (hover on macOS) asks Personal OS for someone else.
struct CallSheetRow: View {
    @EnvironmentObject var store: CalendarStore
    @ObservedObject private var personalOS = PersonalOS.shared
    @Environment(\.openURL) private var openURL
    let item: PersonalOS.CallSheetItem
    @State private var hovering = false

    private var doneLabel: String { item.done ? "Mark \(item.name) not done" : "Mark \(item.name) done" }

    private func openProfile() {
        if let url = URL(string: item.url) { openURL(url) }
    }

    var body: some View {
        let swapping = personalOS.callSheetSwapping.contains(item.personId)
        HStack(spacing: 4) {
            Button {
                store.setCallSheetDone(item, !item.done)
            } label: {
                SidebarCheckbox(checked: item.done)
                    // HIG ≥24pt target around the 14pt box.
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(doneLabel)
            .accessibilityLabel(doneLabel)
            .accessibilityAddTraits(item.done ? .isSelected : [])
            Button(action: openProfile) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(CWT.ui(13))
                        .foregroundStyle(CWT.ink)
                        .strikethrough(item.done, color: CWT.inkSoft)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let reason = item.reason, !reason.isEmpty {
                        Text(reason)
                            .font(CWT.ui(11))
                            .foregroundStyle(CWT.inkFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .opacity(item.done ? 0.5 : 1)
                // HIG ≥24pt target, like CalendarRow.
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.reason.map { "\(item.name) — \($0)" } ?? item.name)
            Button {
                store.replaceCallSheetPerson(item)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkSoft)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .opacity(hovering || swapping ? 1 : 0)
            #endif
            .help("Someone else")
            .accessibilityLabel("Swap \(item.name) for someone else")
        }
        .padding(.leading, -5)
        .opacity(swapping ? 0.4 : 1)
        .disabled(swapping)
        .cwtRowHighlight()
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button(item.done ? "Mark not done" : "Mark done") { store.setCallSheetDone(item, !item.done) }
            Button("Get someone else") { store.replaceCallSheetPerson(item) }
            Divider()
            Button("Open profile", action: openProfile)
        }
    }
}

/// The sidebar's square checkbox (FOCUS sets, call sheet): ink fill and a
/// paper check when on, a soft outline when off.
struct SidebarCheckbox: View {
    let checked: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        shape
            .fill(checked ? AnyShapeStyle(CWT.ink) : AnyShapeStyle(Color.clear))
            .overlay(shape.strokeBorder(checked ? CWT.ink : CWT.inkSoft, lineWidth: 1))
            .frame(width: 14, height: 14)
            .overlay {
                if checked {
                    Image(systemName: "checkmark")
                        .font(CWT.ui(9))
                        .foregroundStyle(CWT.paper)
                }
            }
    }
}

/// One saved focus set: click applies it; the active one (what's showing
/// matches the set exactly) reads as selected.
struct CalendarSetRow: View {
    @EnvironmentObject var store: CalendarStore
    let set: CalendarSet
    let rename: () -> Void

    var body: some View {
        let active = store.isActive(set)
        Button {
            store.apply(set)
        } label: {
            HStack(spacing: 8) {
                SidebarCheckbox(checked: active)
                Text(set.name)
                    .font(CWT.ui(13, bold: active))
                    .foregroundStyle(CWT.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(set.visibleIDs.count)")
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkFaint)
            }
            // HIG ≥24pt target, like CalendarRow.
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cwtRowHighlight(selected: active)
        .help("Show only this set's calendars")
        .accessibilityAddTraits(active ? .isSelected : [])
        .contextMenu {
            Button("Update to current calendars") { store.updateSetToCurrent(set) }
            Button("Rename…") { rename() }
            Divider()
            Button("Delete", role: .destructive) { store.deleteSet(set) }
        }
    }
}

/// Name prompt for saving or renaming a calendar set: an alert with a text
/// field. The draft resets to `initial` each time it opens.
private struct CalendarSetNameAlert: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let initial: String
    let confirm: String
    let message: String
    let onSave: (String) -> Void
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, open in
                if open { draft = initial }
            }
            .alert(title, isPresented: $isPresented) {
                TextField("Name", text: $draft)
                Button(confirm) { onSave(draft) }
                Button("Cancel", role: .cancel) {}
            } message: {
                if !message.isEmpty { Text(message) }
            }
    }
}

extension View {
    func calendarSetNameAlert(_ title: String, isPresented: Binding<Bool>, initial: String = "",
                              confirm: String = "Save", message: String,
                              onSave: @escaping (String) -> Void) -> some View {
        modifier(CalendarSetNameAlert(title: title, isPresented: isPresented, initial: initial,
                                      confirm: confirm, message: message, onSave: onSave))
    }
}

struct CalendarRow: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: AppSettings
    let cal: CalCalendar
    @State private var showColorPicker = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                #if os(macOS)
                // ⌥-click: show only this calendar; again on the solo one → all.
                if NSEvent.modifierFlags.contains(.option) {
                    if store.isSolo(cal) { store.showAllCalendars() } else { store.soloCalendar(cal) }
                    return
                }
                #endif
                store.toggle(cal)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(cal.displayColor.opacity(store.isVisible(cal) ? 1 : 0.25))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if store.isVisible(cal) {
                                Image(systemName: "checkmark")
                                    .font(CWT.ui(9))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(cal.title)
                        .font(CWT.ui(13))
                        .foregroundStyle(store.isVisible(cal) ? AnyShapeStyle(CWT.ink) : AnyShapeStyle(CWT.inkSoft))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                // HIG ≥24pt target: the whole row toggles, not just the label.
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help("⌥-click to show only this calendar")
            #endif
            Button {
                showColorPicker = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkSoft)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || showColorPicker ? 1 : 0)
            .help("Change color")
            .accessibilityLabel("Change color")
        }
        .cwtRowHighlight()
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button("Change color…") { showColorPicker = true }
            Divider()
            Button("Show only this calendar") { store.soloCalendar(cal) }
            Button("Show all calendars") { store.showAllCalendars() }
        }
        .popover(isPresented: $showColorPicker) {
            CalendarColorPicker(cal: cal)
                .environmentObject(settings)
        }
    }
}

struct CalendarColorPicker: View {
    @EnvironmentObject var settings: AppSettings
    let cal: CalCalendar
    @State private var custom: Color = .blue

    private static let presets = [
        "E5484D", "F76B15", "FFB224", "46A758", "12A594", "0091FF",
        "3E63DD", "6E56CF", "AB4ABA", "E93D82", "8D8D8D", "5B5BD6",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cal.title)
                .font(CWT.ui(11))
                .lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        settings.calendarColors[cal.calendarIdentifier] = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if settings.calendarColors[cal.calendarIdentifier] == hex {
                                    Image(systemName: "checkmark")
                                        .font(CWT.ui(10))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                .font(CWT.ui(11))
                .onChange(of: custom) {
                    if let hex = custom.hexString {
                        settings.calendarColors[cal.calendarIdentifier] = hex
                    }
                }
            Button("Reset to account color") {
                settings.calendarColors.removeValue(forKey: cal.calendarIdentifier)
            }
            .font(CWT.ui(11))
            .disabled(settings.calendarColors[cal.calendarIdentifier] == nil)
        }
        .padding(12)
        .frame(width: 210)
        .onAppear { custom = cal.displayColor }
    }
}

struct MiniMonthView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let cal = appState.calendar
        VStack(spacing: 6) {
            HStack {
                Text(Fmt.monthYear.string(from: appState.currentDate))
                    .font(CWT.ui(11))
                Spacer()
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: -1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.left").font(CWT.ui(10))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Previous month")
                .accessibilityLabel("Previous month")
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: 1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.right").font(CWT.ui(10))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Next month")
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CWT.ui(10))
                        .foregroundStyle(CWT.inkSoft)
                }
                ForEach(Array(cal.monthGrid(for: appState.currentDate).enumerated()), id: \.offset) { _, day in
                    let isToday = day.isSameDay(as: Date(), calendar: cal)
                    let isSelected = day.isSameDay(as: appState.currentDate, calendar: cal)
                    let inMonth = cal.isDate(day, equalTo: appState.currentDate, toGranularity: .month)
                    Text(Fmt.dayNum.string(from: day))
                        .font(CWT.ui(11))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .foregroundStyle(isToday ? CWT.signalRed : inMonth ? Color.primary : CWT.inkSoft.opacity(0.5))
                        .contentShape(Rectangle())
                        .onTapGesture { appState.currentDate = day }
                }
            }
        }
    }
}
