import Foundation
import Combine

enum GuestNotifyPolicy: String, CaseIterable, Identifiable {
    case always, never, ask
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "Always email guests"
        case .never: return "Never email guests"
        case .ask: return "Ask each time"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 0 = system, 1 = Sunday, 2 = Monday (Calendar.firstWeekday convention)
    @Published var firstWeekday: Int { didSet { UserDefaults.standard.set(firstWeekday, forKey: "firstWeekday") } }
    /// Minutes
    @Published var defaultDuration: Int { didSet { UserDefaults.standard.set(defaultDuration, forKey: "defaultDuration") } }
    @Published var showDeclined: Bool {
        didSet {
            UserDefaults.standard.set(showDeclined, forKey: "showDeclined")
            WidgetBridge.mirror(showDeclined: showDeclined)
        }
    }
    @Published var showWeekends: Bool { didSet { UserDefaults.standard.set(showWeekends, forKey: "showWeekends") } }
    /// Month view: hide timed-event chips, keep only all-day/multi-day bars
    @Published var monthAllDayOnly: Bool { didSet { UserDefaults.standard.set(monthAllDayOnly, forKey: "monthAllDayOnly") } }
    /// Extra time-zone columns in the time gutter (TimeZone identifiers, in order)
    @Published var secondaryTZs: [String] { didSet { UserDefaults.standard.set(secondaryTZs, forKey: "secondaryTZs") } }
    /// Personal Zoom meeting URL, used by "Add conferencing"
    @Published var zoomLink: String { didSet { UserDefaults.standard.set(zoomLink, forKey: "zoomLink") } }
    /// Per-calendar color overrides (calendarIdentifier → hex "RRGGBB")
    @Published var calendarColors: [String: String] {
        didSet {
            UserDefaults.standard.set(calendarColors, forKey: "calendarColors")
            WidgetBridge.mirror(calendarColors: calendarColors)
        }
    }
    /// Google OAuth desktop-app client (user-supplied, from console.cloud.google.com)
    @Published var googleClientID: String { didSet { UserDefaults.standard.set(googleClientID, forKey: "googleClientID") } }
    @Published var googleClientSecret: String { didSet { UserDefaults.standard.set(googleClientSecret, forKey: "googleClientSecret") } }
    /// Optional iOS-type OAuth client (custom-scheme redirect); falls back to the desktop client.
    @Published var googleIOSClientID: String { didSet { UserDefaults.standard.set(googleIOSClientID, forKey: "googleIOSClientID") } }
    /// Background sync cadence in seconds; 0 = manual only (⌘R).
    @Published var syncInterval: Int { didSet { UserDefaults.standard.set(syncInterval, forKey: "syncInterval") } }
    /// Sync when the app comes to the foreground / window becomes key.
    @Published var syncOnActivate: Bool { didSet { UserDefaults.standard.set(syncOnActivate, forKey: "syncOnActivate") } }
    /// RSVP: email the organizer (Google sendUpdates=all) or answer silently.
    @Published var rsvpNotifyOrganizer: Bool { didSet { UserDefaults.standard.set(rsvpNotifyOrganizer, forKey: "rsvpNotifyOrganizer") } }
    /// Creating/editing/deleting events that have guests: notify them?
    @Published var guestNotifyPolicy: GuestNotifyPolicy { didSet { UserDefaults.standard.set(guestNotifyPolicy.rawValue, forKey: "guestNotifyPolicy") } }
    /// Calendar for new events (calendarIdentifier); empty = first account's primary.
    @Published var defaultCalendarID: String { didSet { UserDefaults.standard.set(defaultCalendarID, forKey: "defaultCalendarID") } }
    /// Manual sidebar ordering (calendarIdentifiers, display order). Calendars
    /// not listed sort after listed ones with the default primary/title rules.
    @Published var calendarOrder: [String] { didSet { UserDefaults.standard.set(calendarOrder, forKey: "calendarOrder") } }
    /// Personal OS (optional): base URL, and the capture token — kept in
    /// UserDefaults like the Google refresh tokens. Both set = integration on.
    @Published var personalOSURL: String { didSet { UserDefaults.standard.set(personalOSURL, forKey: "personalOSURL") } }
    @Published var personalOSToken: String { didSet { UserDefaults.standard.set(personalOSToken, forKey: "personalOSToken") } }

    private init() {
        let d = UserDefaults.standard
        firstWeekday = d.integer(forKey: "firstWeekday")
        defaultDuration = d.object(forKey: "defaultDuration") as? Int ?? 60
        showDeclined = d.object(forKey: "showDeclined") as? Bool ?? true
        showWeekends = d.object(forKey: "showWeekends") as? Bool ?? true
        monthAllDayOnly = d.object(forKey: "monthAllDayOnly") as? Bool ?? false
        secondaryTZs = d.stringArray(forKey: "secondaryTZs") ?? []
        zoomLink = d.string(forKey: "zoomLink") ?? ""
        calendarColors = d.dictionary(forKey: "calendarColors") as? [String: String] ?? [:]
        googleClientID = d.string(forKey: "googleClientID") ?? ""
        googleClientSecret = d.string(forKey: "googleClientSecret") ?? ""
        googleIOSClientID = d.string(forKey: "googleIOSClientID") ?? ""
        syncInterval = d.object(forKey: "syncInterval") as? Int ?? 120
        syncOnActivate = d.object(forKey: "syncOnActivate") as? Bool ?? true
        calendarOrder = d.stringArray(forKey: "calendarOrder") ?? []
        rsvpNotifyOrganizer = d.object(forKey: "rsvpNotifyOrganizer") as? Bool ?? true
        guestNotifyPolicy = GuestNotifyPolicy(rawValue: d.string(forKey: "guestNotifyPolicy") ?? "") ?? .never
        defaultCalendarID = d.string(forKey: "defaultCalendarID") ?? ""
        personalOSURL = d.string(forKey: "personalOSURL") ?? PersonalOS.defaultURL
        personalOSToken = d.string(forKey: "personalOSToken") ?? ""
    }

    // MARK: - Setup transfer (Mac → iPhone via Universal Clipboard)

    private static let transferPrefix = "forkcal-setup:"

    struct SetupTransfer: Codable {
        var clientID: String
        var clientSecret: String
        var iosClientID: String
        var accounts: [GoogleAccount]
        var hiddenCalendarIDs: [String]
        var calendarColors: [String: String]
        var defaultCalendarID: String
    }

    /// Encodes OAuth client, signed-in accounts and calendar visibility/colors as one pasteable string.
    func setupTransferString(accounts: [GoogleAccount], hiddenCalendarIDs: Set<String>) -> String {
        let payload = SetupTransfer(
            clientID: googleClientID, clientSecret: googleClientSecret, iosClientID: googleIOSClientID,
            accounts: accounts, hiddenCalendarIDs: Array(hiddenCalendarIDs),
            calendarColors: calendarColors, defaultCalendarID: defaultCalendarID)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return Self.transferPrefix + data.base64EncodedString()
    }

    /// Decodes a string produced by `setupTransferString`; nil if unrecognized.
    static func decodeSetupTransfer(_ string: String?) -> SetupTransfer? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.hasPrefix(transferPrefix),
              let data = Data(base64Encoded: String(string.dropFirst(transferPrefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(SetupTransfer.self, from: data)
    }

    /// Applies the settings half of a transfer (accounts/visibility are applied by the caller).
    func applySetupTransfer(_ t: SetupTransfer) {
        if !t.clientID.isEmpty { googleClientID = t.clientID }
        googleClientSecret = t.clientSecret
        if !t.iosClientID.isEmpty { googleIOSClientID = t.iosClientID }
        calendarColors.merge(t.calendarColors) { _, new in new }
        if !t.defaultCalendarID.isEmpty { defaultCalendarID = t.defaultCalendarID }
    }

    /// Leading gutter shared by the time grid (hour labels) and the month
    /// view (month labels) so their day columns align exactly — the grid↔month
    /// zoom depends on the two layouts matching pixel for pixel.
    var gridGutterWidth: CGFloat { 54 + CGFloat(secondaryTimeZones.count) * 42 }

    var secondaryTimeZones: [TimeZone] {
        secondaryTZs.compactMap(TimeZone.init(identifier:))
    }

    static let curatedTimeZones: [String] = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
        "America/Sao_Paulo", "Europe/London", "Europe/Paris", "Europe/Berlin",
        "Europe/Madrid", "Africa/Cairo", "Asia/Dubai", "Asia/Kolkata",
        "Asia/Shanghai", "Asia/Tokyo", "Asia/Seoul", "Asia/Singapore",
        "Australia/Sydney", "Pacific/Auckland", "UTC",
    ]

    static func timeZoneLabel(_ id: String) -> String {
        (id.components(separatedBy: "/").last ?? id).replacingOccurrences(of: "_", with: " ")
    }
}
