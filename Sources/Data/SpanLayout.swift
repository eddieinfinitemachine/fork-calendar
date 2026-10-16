import SwiftUI

/// A multi-day/all-day event drawn as one continuous bar across day columns.
struct SpanBar: Identifiable {
    let event: CalEvent
    /// Identical copies on other calendars, merged into this bar.
    var duplicates: [CalEvent] = []
    let startIndex: Int
    let endIndex: Int // inclusive
    let lane: Int
    var id: String { eventKey(event) + "-\(startIndex)" }
}

enum SpanLayout {
    private static let byStart: (CalEvent, CalEvent) -> Bool = {
        if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
        return $0.endDate > $1.endDate
    }

    /// Lays out spanning events over the given ordered day columns
    /// (handles gaps, e.g. hidden weekends).
    ///
    /// With `stableLanes`, lane assignment runs over every fetched spanning
    /// event (not just the visible window), so bars keep their row while the
    /// grid side-scrolls; the window merely clips the result. Without it,
    /// lanes pack densely within the window (used by month rows, which don't
    /// slide).
    @MainActor
    static func bars(days: [Date], store: CalendarStore, calendar: Calendar, stableLanes: Bool = false) -> [SpanBar] {
        guard let first = days.first, let last = days.last else { return [] }
        let rangeStart = calendar.startOfDay(for: first)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return [] }
        let dayKeys = days.map { calendar.startOfDay(for: $0) }

        let bySidebar: (CalEvent) -> Int = { store.sidebarRank($0.calendar?.calendarIdentifier) }
        let events = EventLayout.mergeDuplicates(store.spanningEvents(from: rangeStart, to: rangeEnd).sorted(by: byStart), rank: bySidebar)

        var globalLanes: [String: Int] = [:]
        if stableLanes {
            // Greedy sweep in calendar-day ordinals over the full fetched set;
            // an event's lane depends only on its neighbors, not the window.
            let all = EventLayout.mergeDuplicates(store.spanningEvents(from: .distantPast, to: .distantFuture).sorted(by: byStart), rank: bySidebar).map(\.primary)
            var laneEnds: [Int] = []
            for event in all {
                guard let start = event.startDate, let end = event.endDate else { continue }
                let s = dayOrdinal(calendar.startOfDay(for: start), calendar: calendar, epoch: rangeStart)
                let e = dayOrdinal(calendar.startOfDay(for: max(end.addingTimeInterval(-1), start)), calendar: calendar, epoch: rangeStart)
                if let free = laneEnds.indices.first(where: { laneEnds[$0] < s }) {
                    globalLanes[eventKey(event)] = free
                    laneEnds[free] = e
                } else {
                    globalLanes[eventKey(event)] = laneEnds.count
                    laneEnds.append(e)
                }
            }
        }

        var laneEnds: [Int] = []
        var result: [SpanBar] = []
        for (event, duplicates) in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let eventStartDay = calendar.startOfDay(for: start)
            let lastMomentDay = calendar.startOfDay(for: max(end.addingTimeInterval(-1), start))
            guard let startIndex = dayKeys.firstIndex(where: { $0 >= eventStartDay }),
                  let endIndex = dayKeys.lastIndex(where: { $0 <= lastMomentDay }),
                  endIndex >= startIndex else { continue }
            let lane: Int
            if stableLanes {
                lane = globalLanes[eventKey(event)] ?? 0
            } else if let free = laneEnds.firstIndex(where: { $0 < startIndex }) {
                lane = free
                laneEnds[free] = endIndex
            } else {
                lane = laneEnds.count
                laneEnds.append(endIndex)
            }
            result.append(SpanBar(event: event, duplicates: duplicates, startIndex: startIndex, endIndex: endIndex, lane: lane))
        }
        return result
    }

    private static func dayOrdinal(_ day: Date, calendar: Calendar, epoch: Date) -> Int {
        calendar.dateComponents([.day], from: epoch, to: day).day ?? 0
    }
}

struct SpanBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    @ObservedObject private var personalOS = PersonalOS.shared
    let event: CalEvent
    var duplicates: [CalEvent] = []
    var compact = false

    private var copies: [CalEvent] { [event] + duplicates }

    /// Where the title (or a Personal OS todo's checkbox) starts: after the
    /// calendar strips. The host overlays `PersonalOSCheckbox` here.
    static func contentInset(copies: Int) -> CGFloat {
        3 + CalendarStrips.totalWidth(count: copies) + 3
    }

    /// EC todo with Personal OS on: the "✓ "/"✗ " prefix becomes the
    /// host's checkbox, so drop it from the title and leave room.
    private var isTodo: Bool { personalOS.isConfigured && event.personalOSTodoID != nil }

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        let awaiting = event.needsMyResponse
        let todo = isTodo
        let shape = CWT.eventShape(compact: compact)
        Text((todo ? PersonalOS.displayTitle(event.title) : event.title) ?? "Untitled")
            .font(CWT.ui(compact ? 10 : 11))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.leading, Self.contentInset(copies: copies.count) + (todo ? PersonalOSCheckbox.boxSize + 4 : 0))
            .padding(.trailing, 6)
            .padding(.vertical, compact ? 0 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(color.opacity(
                awaiting ? 0.06 : isSelected ? 0.32 : 0.18
            )))
            .overlay(alignment: .leading) {
                // One strip per calendar this event lives on; dashed = awaiting my RSVP.
                CalendarStrips(copies: copies)
                    .padding(.vertical, 1)
            }
            // The strips follow the rounded corners.
            .clipShape(shape)
            .overlay { if event.myParticipantStatus == .declined { DeclinedSlash(color: color) } }
            .overlay {
                if awaiting {
                    shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.select(event) }
    }
}

/// Left-edge color strips for an event and its merged copies from other
/// calendars: one strip per calendar, solid when that copy needs no answer
/// from me, dashed while its invite is still awaiting my RSVP.
struct CalendarStrips: View {
    @EnvironmentObject var store: CalendarStore
    let copies: [CalEvent]
    var width: CGFloat = 3

    static func totalWidth(count: Int, width: CGFloat = 3) -> CGFloat {
        CGFloat(count) * width + CGFloat(max(count - 1, 0))
    }

    var body: some View {
        // Stack order follows the sidebar's calendar list: the calendar
        // highest in the list draws first (leftmost strip).
        let ordered = copies.sorted {
            store.sidebarRank($0.calendar?.calendarIdentifier) < store.sidebarRank($1.calendar?.calendarIdentifier)
        }
        HStack(spacing: 1) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, copy in
                let color = copy.calendar?.displayColor ?? Color.accentColor
                if copy.needsMyResponse {
                    DashedStrip()
                        .stroke(color, style: StrokeStyle(lineWidth: width, dash: [3, 2]))
                        .frame(width: width)
                } else {
                    Rectangle()
                        .fill(color.opacity(copy.myParticipantStatus == .declined ? 0.35 : 1))
                        .frame(width: width)
                }
            }
        }
    }

    private struct DashedStrip: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return p
        }
    }
}

/// Diagonal slash (bottom-left → top-right) drawn across a declined event.
struct DeclinedSlash: View {
    let color: Color

    var body: some View {
        Slash().stroke(color, lineWidth: 1).allowsHitTesting(false)
    }

    private struct Slash: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return p
        }
    }
}
