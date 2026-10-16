import SwiftUI

enum RecurrenceChoice: String, CaseIterable, Identifiable {
    case none = "Does not repeat"
    case daily = "Every day"
    case weekdays = "Every weekday"
    case weekly = "Every week"
    case biweekly = "Every 2 weeks"
    case monthly = "Every month"
    case yearly = "Every year"

    var id: String { rawValue }

    /// RFC 5545 lines as Google stores them.
    var rules: [String]? {
        switch self {
        case .none: return nil
        case .daily: return ["RRULE:FREQ=DAILY"]
        case .weekdays: return ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]
        case .weekly: return ["RRULE:FREQ=WEEKLY"]
        case .biweekly: return ["RRULE:FREQ=WEEKLY;INTERVAL=2"]
        case .monthly: return ["RRULE:FREQ=MONTHLY"]
        case .yearly: return ["RRULE:FREQ=YEARLY"]
        }
    }

    static func from(_ event: CalEvent) -> RecurrenceChoice {
        let parts = RRule.parts(event.recurrence)
        guard !parts.isEmpty else { return .none }
        let interval = Int(parts["INTERVAL"] ?? "1") ?? 1
        switch parts["FREQ"] {
        case "DAILY": return .daily
        case "WEEKLY":
            if interval == 2 { return .biweekly }
            if (parts["BYDAY"]?.split(separator: ",").count ?? 0) == 5 { return .weekdays }
            return .weekly
        case "MONTHLY": return .monthly
        case "YEARLY": return .yearly
        default: return .none
        }
    }
}

/// Notion-style right-hand event panel: details + inline editing.
struct EventPanelView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let context: EditorContext
    /// True only when presented as a sheet (iOS compact). The inline macOS
    /// panel must NOT call dismiss() — that dismisses the whole window.
    var isSheet = false

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var urlString: String
    @State private var calendarID: String
    @State private var recurrence: RecurrenceChoice
    enum RepeatEnd: String, CaseIterable, Identifiable {
        case never = "Never ends", onDate = "Ends on", after = "Ends after"
        var id: String { rawValue }
    }
    @State private var repeatEnd: RepeatEnd
    @State private var repeatUntil: Date
    @State private var repeatCount: Int
    @State private var inviteEmails: String = ""
    @State private var addMeetOnSave = false
    @State private var editingNotes = false
    @State private var renderedNotes: AttributedString?
    private let originalSnapshot: EventSnapshot?
    @FocusState private var titleFocused: Bool
    @FocusState private var inviteFocused: Bool

    init(context: EditorContext, isSheet: Bool = false) {
        self.context = context
        self.isSheet = isSheet
        _title = State(initialValue: context.event.title ?? "")
        _isAllDay = State(initialValue: context.event.isAllDay)
        _start = State(initialValue: context.event.startDate ?? Date())
        _end = State(initialValue: context.event.endDate ?? Date().addingTimeInterval(3600))
        _location = State(initialValue: context.event.location ?? "")
        _notes = State(initialValue: context.event.notes ?? "")
        _urlString = State(initialValue: context.event.url?.absoluteString ?? "")
        _calendarID = State(initialValue: context.event.calendar?.calendarIdentifier ?? "")
        _recurrence = State(initialValue: RecurrenceChoice.from(context.event))
        let until = RRule.untilDay(context.event.recurrence), count = RRule.count(context.event.recurrence)
        _repeatEnd = State(initialValue: until != nil ? .onDate : count != nil ? .after : .never)
        _repeatUntil = State(initialValue: until ?? Calendar.autoupdatingCurrent.date(byAdding: .month, value: 3, to: context.event.startDate ?? Date()) ?? Date())
        _repeatCount = State(initialValue: count ?? 10)
        originalSnapshot = context.isNew ? nil : EventSnapshot(context.event)
    }

    // MARK: - Invite autocomplete

    /// The email fragment being typed (after the last comma).
    private var inviteToken: String {
        let last = inviteEmails.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? inviteEmails
        return last.trimmingCharacters(in: .whitespaces)
    }

    private var inviteSuggestions: [CalendarStore.AttendeeSuggestion] {
        guard inviteFocused, !isReadOnly else { return [] }
        let token = inviteToken.lowercased()
        guard !token.isEmpty else { return [] }
        // Don't re-suggest people already on the event or earlier in the field.
        var taken = Set((context.event.attendees ?? []).map { $0.email.lowercased() })
        for part in inviteEmails.split(separator: ",").dropLast() {
            taken.insert(part.trimmingCharacters(in: .whitespaces).lowercased())
        }
        let matches = store.attendeeSuggestions(matching: token, excluding: taken)
        if matches.count == 1, matches[0].email == token { return [] } // already typed in full
        return matches
    }

    private func acceptInviteSuggestion(_ s: CalendarStore.AttendeeSuggestion) {
        var parts = inviteEmails.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = s.email
        inviteEmails = parts.joined(separator: ", ") + ", "
        inviteFocused = true
    }

    private func acceptFirstInviteSuggestion() {
        if let first = inviteSuggestions.first { acceptInviteSuggestion(first) }
    }

    private var isReadOnly: Bool {
        !context.isNew && !(context.event.calendar?.allowsContentModifications ?? true)
    }

    /// All-day pickers show the last day the event covers; the model (like
    /// Google) keeps an exclusive end — midnight after that last day.
    private var inclusiveEnd: Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.autoupdatingCurrent
                return cal.startOfDay(for: max(end.addingTimeInterval(-1), start))
            },
            set: {
                let cal = Calendar.autoupdatingCurrent
                let lastDay = cal.startOfDay(for: $0)
                end = cal.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !context.isNew, !isReadOnly {
                    Button {
                        appState.requestDelete(context.event, store: store)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete (⌫)")
                    .accessibilityLabel("Delete")
                }
                if !context.isNew {
                    Button {
                        appState.billEvent(context.event)
                    } label: {
                        Image(systemName: "dollarsign.circle")
                    }
                    .help("Bill to invoice (B)")
                    .accessibilityLabel("Bill to invoice")
                    PersonalOSPanelButtons(store: store, event: context.event)
                }
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close (esc)")
                .accessibilityLabel("Close")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Add title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(CWT.ui(15))
                        .focused($titleFocused)
                        .lineLimit(3)
                        .disabled(isReadOnly)

                    if let joinURL = currentJoinURL {
                        Button {
                            openURL(joinURL)
                        } label: {
                            Label("Join meeting", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.cwt(on: true, size: 13))
                        .prominentLabel()
                    } else if addMeetOnSave {
                        Label("Google Meet will be created on save", systemImage: "video.badge.checkmark")
                            .font(CWT.ui(13))
                            .foregroundStyle(CWT.inkSoft)
                    } else if !isReadOnly {
                        conferencingMenu
                    }

                    row(icon: "clock") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("All day", isOn: $isAllDay)
                                .font(CWT.ui(13))
                            DatePicker(
                                "Starts",
                                selection: $start,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(CWT.ui(13))
                            .fieldDatePickerStyle()
                            DatePicker(
                                "Ends",
                                selection: isAllDay ? inclusiveEnd : $end,
                                in: (isAllDay ? Calendar.autoupdatingCurrent.startOfDay(for: start) : start)...,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(CWT.ui(13))
                            .fieldDatePickerStyle()
                        }
                        .disabled(isReadOnly)
                    }

                    row(icon: "repeat") {
                        CWTMenuPicker(selection: $recurrence,
                                      options: RecurrenceChoice.allCases.map { ($0, $0.rawValue) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isReadOnly)
                    }

                    if recurrence != .none {
                        row(icon: "repeat.1") {
                            HStack(spacing: 8) {
                                CWTMenuPicker(selection: $repeatEnd,
                                              options: RepeatEnd.allCases.map { ($0, $0.rawValue) })
                                switch repeatEnd {
                                case .never: EmptyView()
                                case .onDate:
                                    DatePicker("", selection: $repeatUntil, in: start..., displayedComponents: [.date])
                                        .labelsHidden()
                                        .font(CWT.ui(13))
                                        .fieldDatePickerStyle()
                                case .after:
                                    Stepper("\(repeatCount) times", value: $repeatCount, in: 1...999)
                                        .font(CWT.ui(13))
                                        .fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isReadOnly)
                        }
                    }

                    row(icon: "calendar") {
                        CWTMenuPicker(selection: $calendarID,
                                      options: (context.isNew || !isReadOnly ? store.writableCalendars : store.orderedCalendars)
                                        .map { ($0.calendarIdentifier, $0.title) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isReadOnly)
                    }

                    if !context.isNew, context.event.attendees?.isEmpty == false {
                        row(icon: "envelope.badge") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your response")
                                    .font(CWT.ui(11))
                                    .foregroundStyle(CWT.inkSoft)
                                HStack(spacing: 6) {
                                    rsvpButton("Going", status: .accepted)
                                    rsvpButton("Maybe", status: .tentative)
                                    rsvpButton("No", status: .declined)
                                }
                            }
                        }
                    }

                    if let attendees = context.event.attendees, !attendees.isEmpty {
                        row(icon: "person.2") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                                    let status = attendee.responseStatus
                                    HStack(spacing: 6) {
                                        Image(systemName: statusIcon(status))
                                            .font(CWT.ui(11))
                                            .foregroundStyle(statusColor(status))
                                        Text(attendee.name ?? "Unknown")
                                            .font(CWT.ui(13))
                                            .lineLimit(1)
                                        if attendee.isSelf {
                                            Text("(you)").font(CWT.ui(11)).foregroundStyle(CWT.inkSoft)
                                        } else if attendee.isOrganizer {
                                            Text("(organizer)").font(CWT.ui(11)).foregroundStyle(CWT.inkSoft)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    row(icon: "person.badge.plus") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Invite people (emails, comma-separated)", text: $inviteEmails)
                                .textFieldStyle(.plain)
                                .font(CWT.ui(13))
                                .disabled(isReadOnly)
                                .focused($inviteFocused)
                                .onSubmit(acceptFirstInviteSuggestion)
                                #if os(iOS)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                #endif
                            // Lookup from past events' guests: click (or press
                            // return for the top hit) to complete the token
                            // being typed after the last comma.
                            ForEach(inviteSuggestions) { s in
                                Button {
                                    acceptInviteSuggestion(s)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.crop.circle")
                                            .font(CWT.ui(11))
                                            .foregroundStyle(CWT.inkSoft)
                                        if let name = s.name, !name.isEmpty, name.lowercased() != s.email {
                                            Text(name).font(CWT.ui(12)).lineLimit(1)
                                            Text(s.email).font(CWT.ui(11))
                                                .foregroundStyle(CWT.inkSoft).lineLimit(1)
                                        } else {
                                            Text(s.email).font(CWT.ui(12)).lineLimit(1)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if !inviteEmails.isEmpty {
                                Text(settings.guestNotifyPolicy == .never
                                     ? "Added to the guest list on save (no email — see Settings)"
                                     : "Added to the guest list and emailed on save")
                                    .font(CWT.ui(10))
                                    .foregroundStyle(CWT.inkFaint)
                            }
                        }
                    }

                    row(icon: "mappin.and.ellipse") {
                        HStack(spacing: 6) {
                            TextField("Add location", text: $location)
                                .textFieldStyle(.plain)
                                .font(CWT.ui(13))
                                .disabled(isReadOnly)
                            if let maps = mapsURL {
                                Button {
                                    openURL(maps)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(CWT.ui(13))
                                        .foregroundStyle(CWT.inkSoft)
                                }
                                .buttonStyle(.plain)
                                .help("Open in Google Maps")
                            }
                        }
                    }

                    row(icon: "link") {
                        TextField("Add URL", text: $urlString)
                            .textFieldStyle(.plain)
                            .font(CWT.ui(13))
                            .disabled(isReadOnly)
                    }

                    row(icon: "text.alignleft") {
                        VStack(alignment: .leading, spacing: 4) {
                            if !editingNotes, HTMLNotes.looksLikeHTML(notes) {
                                // Google descriptions are usually HTML; show
                                // them formatted, with links tappable.
                                Text(renderedNotes ?? AttributedString())
                                    .font(CWT.ui(13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(CWT.paper2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                if !isReadOnly {
                                    Button("Edit notes") { editingNotes = true }
                                        .buttonStyle(.plain)
                                        .font(CWT.ui(11))
                                        .foregroundStyle(CWT.inkSoft)
                                }
                            } else {
                                TextEditor(text: $notes)
                                    .font(CWT.ui(13))
                                    .frame(minHeight: 70)
                                    .scrollContentBackground(.hidden)
                                    .background(CWT.paper2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .disabled(isReadOnly)
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            HStack {
                if isReadOnly {
                    Text("Read-only calendar")
                        .font(CWT.ui(11))
                        .foregroundStyle(CWT.inkSoft)
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.cwt(size: 13))
                Button(context.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.cwt(on: true, size: 13))
                    .prominentLabel()
                    .disabled(isReadOnly)
            }
            .padding(12)
        }
        // Controls (buttons, pickers, toggles) don't inherit the root font.
        .font(CWT.ui(13))
        // As a sheet it's the page; inline, the host floats it on a glass
        // card (RootView), so it paints nothing of its own.
        .background { if isSheet { CWT.paper } }
        .onChange(of: start) { oldValue, newValue in
            end = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
        }
        .onAppear {
            if context.isNew { titleFocused = true }
        }
        // Never render inside body: the HTML importer spins the run loop
        // (WebKit), which re-entered SwiftUI mid-update and left the iPhone
        // sheet blank for every event with an HTML description.
        .task {
            renderedNotes = HTMLNotes.render(notes)
            if renderedNotes == nil { editingNotes = true }
        }
    }

    /// Google Maps search link for the location text. A location that is
    /// itself a URL (e.g. a pasted meeting link) gets no maps link.
    private var mapsURL: URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") { return nil }
        var comps = URLComponents(string: "https://www.google.com/maps/search/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: trimmed),
        ]
        return comps.url
    }

    /// Join link considering unsaved edits to the URL field.
    private var currentJoinURL: URL? {
        if let typed = URL(string: urlString), MeetLink.isMeetingURL(typed) { return typed }
        return MeetLink.url(for: context.event)
    }

    private var conferencingMenu: some View {
        Menu {
            Button {
                addMeetOnSave = true
            } label: {
                Label("Google Meet (created on save)", systemImage: "video.badge.plus")
            }
            if let zoomURL = URL(string: settings.zoomLink), !settings.zoomLink.isEmpty {
                Button {
                    urlString = zoomURL.absoluteString
                    if location.isEmpty { location = "Zoom" }
                } label: {
                    Label("Zoom (personal meeting)", systemImage: "video")
                }
            } else {
                Button("Zoom — set your personal link in Settings…") {}
                    .disabled(true)
            }
            Button {
                if let pasted = Clipboard.paste(),
                   let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true {
                    urlString = url.absoluteString
                }
            } label: {
                Label("Paste link from clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Label("Add conferencing", systemImage: "video")
                .frame(maxWidth: .infinity)
        }
    }

    private func row(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(CWT.ui(13))
                .foregroundStyle(CWT.inkSoft)
                .frame(width: 18)
                .padding(.top, 3)
            content()
        }
    }

    private func rsvpButton(_ label: String, status: ParticipantStatus) -> some View {
        let isCurrent = context.event.myParticipantStatus == status
        return Button(label) {
            let event = context.event
            let s = store
            Task { await s.respond(event, status: status) }
        }
        .buttonStyle(.cwt(on: isCurrent))
    }

    private func statusIcon(_ status: ParticipantStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(_ status: ParticipantStatus) -> Color {
        switch status {
        case .accepted: return CWT.signalGreen
        case .declined: return CWT.signalRed
        case .tentative: return CWT.signalOrange
        default: return CWT.inkSoft
        }
    }

    private func close() {
        appState.closePanel()
        if isSheet { dismiss() }
    }

    private func save() {
        let event = context.event
        event.title = title.isEmpty ? "New event" : title
        event.isAllDay = isAllDay
        if isAllDay {
            // Normalize to whole days with an exclusive end, so a one-day
            // event spans exactly one day (Google rejects an empty range).
            let cal = Calendar.autoupdatingCurrent
            let firstDay = cal.startOfDay(for: start)
            let lastDay = cal.startOfDay(for: max(end.addingTimeInterval(-1), firstDay))
            event.startDate = firstDay
            event.endDate = cal.date(byAdding: .day, value: 1, to: lastDay) ?? end
        } else {
            event.startDate = start
            event.endDate = max(end, start.addingTimeInterval(900))
        }
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        event.url = urlString.isEmpty ? nil : URL(string: urlString)
        let newRules = recurrence.rules.map {
            RRule.ending($0, onDay: repeatEnd == .onDate ? repeatUntil : nil,
                         count: repeatEnd == .after ? repeatCount : nil, allDay: event.isAllDay)
        }
        let endChanged = RRule.untilDay(newRules).map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
            != RRule.untilDay(event.recurrence).map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
            || RRule.count(newRules) != RRule.count(event.recurrence)
        if RecurrenceChoice.from(event) != recurrence || endChanged {
            event.recurrence = newRules
        }
        if let cal = store.writableCalendars.first(where: { $0.calendarIdentifier == calendarID }),
           cal.calendarIdentifier != event.calendar?.calendarIdentifier {
            event.calendar = cal
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendar
        }
        // Guests + Meet ride along with the save (one Google write).
        let emails = inviteEmails.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
        if !emails.isEmpty {
            var list = event.attendees ?? []
            let me = event.calendar?.accountID.lowercased()
            if list.isEmpty, let me {
                // First guest: Google adds the organizer automatically, but
                // listing myself keeps RSVP state visible right away.
                list.append(CalAttendee(email: me, displayName: nil, responseStatus: .accepted,
                                        isSelf: true, isOrganizer: true, isOptional: false, isResource: false))
            }
            for email in emails where !list.contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                list.append(CalAttendee(email: email, displayName: nil, responseStatus: .needsAction,
                                        isSelf: false, isOrganizer: false, isOptional: false, isResource: false))
            }
            event.attendees = list
        }
        event.wantsMeet = addMeetOnSave
        appState.commitChange(to: event, snapshot: originalSnapshot, isNew: context.isNew, store: store)
        appState.closePanel()
        if isSheet { dismiss() }
    }
}

/// Renders HTML descriptions into an AttributedString in the app's type.
enum HTMLNotes {
    private static let tagPattern = try! NSRegularExpression(pattern: "<(/?)(a|b|i|u|p|br|div|span|ul|ol|li|strong|em|h[1-6]|table|tr|td|font)\\b[^>]*>", options: [.caseInsensitive])

    static func looksLikeHTML(_ text: String) -> Bool {
        tagPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// nil when the text isn't HTML (the plain editor is used instead).
    static func render(_ text: String) -> AttributedString? {
        guard looksLikeHTML(text), let data = text.data(using: .utf8) else { return nil }
        guard let ns = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        var attr = AttributedString(ns)
        for run in attr.runs {
            var bold = false
            var italic = false
            #if os(macOS)
            if let f = run.appKit.font {
                bold = f.fontDescriptor.symbolicTraits.contains(.bold)
                italic = f.fontDescriptor.symbolicTraits.contains(.italic)
            }
            #else
            if let f = run.uiKit.font {
                bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
            }
            #endif
            let range = run.range
            attr[range].font = CWT.ui(13)
            if italic { attr[range].font = CWT.ui(13).italic() }
            attr[range].foregroundColor = run.link != nil ? Color.accentColor : CWT.ink
            attr[range].backgroundColor = nil
            #if os(macOS)
            attr[range].appKit.paragraphStyle = nil
            #else
            attr[range].uiKit.paragraphStyle = nil
            #endif
        }
        // Trim the trailing newline the HTML importer adds
        while attr.characters.last?.isNewline == true {
            attr.characters.removeLast()
        }
        return attr
    }
}

private extension View {
    /// HIG prefers the system date picker; on macOS use the plain field
    /// variant (no stepper arrows) to sit with the CW&T controls.
    @ViewBuilder
    func fieldDatePickerStyle() -> some View {
        #if os(macOS)
        datePickerStyle(.field)
        #else
        self
        #endif
    }
}
