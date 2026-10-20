import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: CalendarStore
    @ObservedObject private var accounts = AccountManager.shared
    @State private var transferStatus = ""
    @State private var oauthExpanded = false
    @ObservedObject private var personalOS = PersonalOS.shared
    /// Inline result of "Test connection": nil = not run, "" = running.
    @State private var personalOSTest: String?
    /// Inline result of the Claude key test: nil = not run, "" = running.
    @State private var assistantTest: String?

    private static let timeZones = AppSettings.curatedTimeZones

    /// Selecting from the picker appends to the list, then the picker resets.
    private var addTimeZoneBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { id in
                guard !id.isEmpty, !settings.secondaryTZs.contains(id) else { return }
                settings.secondaryTZs.append(id)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                accountsSection
                syncSection
                notifySection
                generalSection
                personalOSSection
                assistantSection
            }
            .padding(16)
        }
        .background(CWT.paper)
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        SettingsSection("Google accounts") {
            ForEach(accounts.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: account.needsReauth ? "exclamationmark.triangle.fill" : "person.crop.circle")
                        .foregroundStyle(account.needsReauth ? CWT.signalOrange : CWT.inkSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email).font(CWT.ui(13))
                        if account.needsReauth {
                            Text("Needs sign-in again — \(account.reauthReason ?? "sign-in expired")")
                                .font(CWT.ui(10)).foregroundStyle(CWT.signalOrange)
                        } else if let name = account.name {
                            Text(name).font(CWT.ui(10)).foregroundStyle(CWT.inkSoft)
                        }
                    }
                    Spacer()
                    Toggle("Sync", isOn: Binding(
                        get: { account.syncEnabled },
                        set: { accounts.setSyncEnabled($0, for: account.email) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(CWT.accent)
                    if account.needsReauth {
                        Button("Sign in…") { Task { await accounts.addAccount() } }
                            .buttonStyle(.cwt(size: 13))
                    }
                    Button(role: .destructive) {
                        accounts.remove(account.email)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(CWT.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Remove account")
                }
                .settingsRow()
            }
            HStack {
                Button(accounts.isSigningIn ? "Waiting for Google…" : "Add Google account…") {
                    Task { await accounts.addAccount() }
                }
                .buttonStyle(.cwt(size: 13))
                .disabled(accounts.isSigningIn || effectiveClientID.isEmpty)
                Spacer()
                if !accounts.statusMessage.isEmpty {
                    Text(accounts.statusMessage)
                        .font(CWT.ui(11))
                        .foregroundStyle(CWT.inkSoft)
                        .lineLimit(2)
                }
            }
            .settingsRow()
            Button {
                oauthExpanded.toggle()
            } label: {
                Text((oauthExpanded ? "⌄ " : "› ") + "OAuth client")
                    .font(CWT.ui(13))
                    .foregroundStyle(CWT.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsRow()
            if oauthExpanded {
                SettingsField("Desktop client ID", text: $settings.googleClientID)
                    .settingsRow()
                SettingsField("Desktop client secret", text: $settings.googleClientSecret)
                    .settingsRow()
                #if os(iOS)
                SettingsField("iOS client ID (optional)", text: $settings.googleIOSClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsRow()
                HStack {
                    Button("Paste setup from Mac") {
                        if let t = AppSettings.decodeSetupTransfer(Clipboard.paste()) {
                            settings.applySetupTransfer(t)
                            accounts.importAccounts(t.accounts)
                            store.hiddenCalendarIDs = Set(t.hiddenCalendarIDs)
                            transferStatus = "Imported \(t.accounts.count) account(s) — syncing…"
                            Task { await store.requestAccess() }
                        } else {
                            transferStatus = "Clipboard has no Fork Calendar setup"
                        }
                    }
                    .buttonStyle(.cwt(size: 13))
                    Spacer()
                    Text(transferStatus).font(CWT.ui(11)).foregroundStyle(CWT.inkSoft)
                }
                .settingsRow()
                #else
                HStack {
                    Button("Copy setup for iPhone") {
                        Clipboard.copy(settings.setupTransferString(
                            accounts: accounts.accounts, hiddenCalendarIDs: store.hiddenCalendarIDs))
                        transferStatus = "Copied (OAuth client, \(accounts.accounts.count) account(s), calendar visibility) — on the iPhone: Settings → OAuth client → Paste setup from Mac"
                    }
                    .buttonStyle(.cwt(size: 13))
                    Spacer()
                    Text(transferStatus).font(CWT.ui(11)).foregroundStyle(CWT.inkSoft)
                }
                .settingsRow()
                #endif
                SettingsFootnote("Create OAuth clients at console.cloud.google.com (APIs & Services → Credentials) in a project with the Google Calendar API enabled. macOS uses a **Desktop app** client; iOS works best with an **iOS** client for bundle ID com.cwandt.forkcalendar.app (falls back to the desktop client). Each account you add signs in through Google's own page.")
            }
        }
    }

    private var effectiveClientID: String {
        #if os(iOS)
        return settings.googleIOSClientID.isEmpty ? settings.googleClientID : settings.googleIOSClientID
        #else
        return settings.googleClientID
        #endif
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection("Sync") {
            SettingsRow("Check for changes") {
                CWTMenuPicker(selection: $settings.syncInterval, options: [
                    (0, "Manually (⌘R)"),
                    (60, "Every minute"),
                    (120, "Every 2 minutes"),
                    (300, "Every 5 minutes"),
                    (900, "Every 15 minutes"),
                ])
            }
            SettingsToggle("Also sync when the app becomes active", isOn: $settings.syncOnActivate)
            HStack {
                Button(store.isRefreshing ? "Syncing…" : "Sync now") { store.refresh() }
                    .buttonStyle(.cwt(size: 13))
                    .disabled(store.isRefreshing || store.accessState != .granted)
                Spacer()
                if let last = store.lastSync {
                    Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
                        .font(CWT.ui(11))
                        .foregroundStyle(CWT.inkSoft)
                }
            }
            .settingsRow()
            Button("Clear local cache and re-download") {
                store.engine.resetCache()
                store.refresh()
            }
            .buttonStyle(.cwt(size: 13))
            .settingsRow()
            SettingsFootnote("Edits you make are sent to Google immediately; this controls how often changes made elsewhere are pulled in.")
        }
    }

    // MARK: - Notifications

    private var notifySection: some View {
        SettingsSection("Emails to guests & organizers") {
            SettingsRow("When I change an event with guests") {
                CWTMenuPicker(selection: $settings.guestNotifyPolicy,
                              options: GuestNotifyPolicy.allCases.map { ($0, $0.label) })
            }
            SettingsToggle("Email the organizer when I RSVP", isOn: $settings.rsvpNotifyOrganizer)
            SettingsFootnote("Applies to creating, moving, editing and deleting events that have other guests, and to inviting people. Google sends the emails; nothing is sent from your Mail.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("Calendar") {
            SettingsRow("New events go to") {
                CWTMenuPicker(selection: $settings.defaultCalendarID,
                              options: [("", "First account's primary")]
                                + store.writableCalendars.map { ($0.calendarIdentifier, "\($0.title) — \($0.accountID)") })
            }
            SettingsRow("Start week on") {
                CWTMenuPicker(selection: $settings.firstWeekday, options: [
                    (0, "System default"),
                    (1, "Sunday"),
                    (2, "Monday"),
                ])
            }
            SettingsRow("Default event duration") {
                CWTMenuPicker(selection: $settings.defaultDuration,
                              options: [15, 30, 45, 60, 90, 120].map { ($0, "\($0) min") })
            }
            SettingsToggle("Show weekends in week view", isOn: $settings.showWeekends)
            SettingsToggle("Show declined events", isOn: $settings.showDeclined)
            SettingsToggle("Month view: all-day events only", isOn: $settings.monthAllDayOnly)
            SettingsRow("Zoom personal meeting URL") {
                SettingsField("https://zoom.us/j/…", text: $settings.zoomLink)
                    .frame(maxWidth: 220)
            }
            ForEach(settings.secondaryTZs, id: \.self) { id in
                HStack {
                    Text("Time zone: \(AppSettings.timeZoneLabel(id))")
                        .font(CWT.ui(13))
                        .foregroundStyle(CWT.ink)
                    Spacer()
                    Button {
                        settings.secondaryTZs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(CWT.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                .settingsRow()
            }
            SettingsRow("Add time zone") {
                CWTMenuPicker(selection: addTimeZoneBinding,
                              options: [("", "Choose…")]
                                + Self.timeZones.filter { !settings.secondaryTZs.contains($0) }
                                    .map { ($0, $0.replacingOccurrences(of: "_", with: " ")) })
            }
        }
    }

    // MARK: - Personal OS

    private var personalOSSection: some View {
        SettingsSection("Personal OS") {
            SettingsRow("URL") {
                SettingsField(PersonalOS.defaultURL, text: $settings.personalOSURL)
                    .frame(maxWidth: 260)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
            }
            SettingsRow("Capture token") {
                SettingsSecureField("Paste token", text: $settings.personalOSToken)
                    .frame(maxWidth: 260)
            }
            HStack {
                Button(personalOSTest == "" ? "Testing…" : "Test connection") {
                    personalOSTest = ""
                    Task {
                        await personalOS.refreshCallSheet()
                        let n = personalOS.callSheet.count
                        personalOSTest = personalOS.callSheetError.map { "✗ \($0)" }
                            ?? "OK — \(n) on today's call sheet"
                    }
                }
                .buttonStyle(.cwt(size: 13))
                .disabled(!personalOS.isConfigured || personalOSTest == "")
                Spacer()
                if let result = personalOSTest, !result.isEmpty {
                    Text(result)
                        .font(CWT.ui(11))
                        .foregroundStyle(result.hasPrefix("✗") ? CWT.signalRed : CWT.inkSoft)
                        .lineLimit(2)
                }
            }
            .settingsRow()
            SettingsFootnote("Optional. With a URL and capture token set: EC-calendar todo events get a checkbox (and moving one moves its due date), any event can become a **Follow up** todo (right-click or the event panel), and today's call sheet shows in the sidebar.")
        }
        .onChange(of: settings.personalOSToken) { personalOSTest = nil }
        .onChange(of: settings.personalOSURL) { personalOSTest = nil }
    }
}

// MARK: - Claude assistant

extension SettingsView {
    fileprivate var assistantSection: some View {
        SettingsSection("Claude assistant") {
            SettingsRow("Anthropic API key") {
                SettingsSecureField("sk-ant-…", text: $settings.anthropicAPIKey)
                    .frame(maxWidth: 260)
            }
            SettingsRow("Model") {
                CWTMenuPicker(selection: $settings.assistantModel,
                              options: AssistantModel.all.map { ($0.id, $0.label) }
                                + (AssistantModel.all.contains { $0.id == settings.assistantModel }
                                   ? [] : [(settings.assistantModel, settings.assistantModel)]))
            }
            HStack {
                Button(assistantTest == "" ? "Testing…" : "Test") {
                    assistantTest = ""
                    let key = settings.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let model = settings.assistantModel
                    Task {
                        let failure = await AnthropicTransport.test(apiKey: key, model: model)
                        assistantTest = failure.map { "✗ \($0)" } ?? "OK — \(model) answered"
                    }
                }
                .buttonStyle(.cwt(size: 13))
                .disabled(settings.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistantTest == "")
                Spacer()
                if let result = assistantTest, !result.isEmpty {
                    Text(result)
                        .font(CWT.ui(11))
                        .foregroundStyle(result.hasPrefix("✗") ? CWT.signalRed : CWT.inkSoft)
                        .lineLimit(3)
                }
            }
            .settingsRow()
            SettingsFootnote("Optional. With a key set, type a request in ⌘K (\"cancel my meetings this week\", \"30 min with Amy Thursday afternoon\") and choose **Ask Claude** (⌘↩). Claude reads your calendar to plan; nothing changes until you press **Confirm**, and one ⌘Z undoes the whole batch. Requests go to Anthropic's API with the events it looks up. The key is stored locally with the app's other settings.")
        }
        .onChange(of: settings.anthropicAPIKey) { assistantTest = nil }
        .onChange(of: settings.assistantModel) { assistantTest = nil }
    }
}

// MARK: - Settings building blocks

/// A section: medium-weight header over a hairline-bordered panel whose rows
/// are separated by 1px rules.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(CWT.ui(13, bold: true))
                .foregroundStyle(CWT.ink)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(CWT.rule).frame(height: 1)
                        }
                        row
                    }
                }
            }
            .foregroundStyle(CWT.ink)
            .background(CWT.paper2)
            .overlay(Rectangle().stroke(CWT.rule, lineWidth: 1))
        }
    }
}

private extension View {
    /// Row padding inside a settings panel.
    func settingsRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// Label on the left, control on the right.
private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label).font(CWT.ui(13)).foregroundStyle(CWT.ink)
            Spacer()
            control
        }
        .settingsRow()
    }
}

private struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(CWT.accent)
        }
    }
}

/// Explanatory sentence under a group of rows. Markdown (`**bold**`) renders.
private struct SettingsFootnote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(CWT.ui(11))
            .foregroundStyle(CWT.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
            .settingsRow()
    }
}

/// Plain text field in a 1px ruled box; the placeholder doubles as the label.
private struct SettingsField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(CWT.inkFaint))
            .textFieldStyle(.plain)
            .font(CWT.ui(13))
            .foregroundStyle(CWT.ink)
            .padding(6)
            .overlay(Rectangle().stroke(CWT.rule, lineWidth: 1))
    }
}

/// `SettingsField` for secrets: same ruled box, input hidden.
private struct SettingsSecureField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        SecureField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(CWT.inkFaint))
            .textFieldStyle(.plain)
            .font(CWT.ui(13))
            .foregroundStyle(CWT.ink)
            .padding(6)
            .overlay(Rectangle().stroke(CWT.rule, lineWidth: 1))
    }
}

/// A `Picker` replacement: a CW&T-faced menu whose items mark the current
/// choice with "✓ ".
struct CWTMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                Button((value == selection ? "✓ " : "   ") + label) { selection = value }
            }
        } label: {
            Text((options.first { $0.0 == selection }?.1 ?? "") + " ▾")
        }
        .menuStyle(.button)
        .buttonStyle(.cwt(size: 13))
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
