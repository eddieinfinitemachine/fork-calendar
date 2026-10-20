#if os(macOS)
import AppKit
import SwiftUI

/// Notion-Calendar-style single-key shortcuts (T/D/W/M/C/S, 1–9, arrows, Esc,
/// Delete, Enter) plus ⌘Z routing. Keys pass through untouched while a text
/// field is being edited, except palette navigation keys.
@MainActor
enum KeyMonitor {
    private static var monitor: Any?
    private static var scrollMonitor: Any?
    private static var snapWork: DispatchWorkItem?

    static func install(appState: AppState, store: CalendarStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event, appState: appState, store: store) ? nil : event
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                handleScroll(event, appState: appState) ? nil : event
            }
        }
    }

    // MARK: - Horizontal pan (smooth day-granular side-scroll)

    /// Axis decision for the scroll gesture in flight. Latched once per
    /// gesture: a horizontal gesture pans the grid until it (and its momentum)
    /// ends; a vertical one passes through untouched — so vertical scrolling
    /// never gets swallowed sample-by-sample the way per-event decisions did.
    private enum ScrollCapture { case idle, deciding, horizontal, passthrough }
    private static var capture: ScrollCapture = .idle
    private static var decideX: CGFloat = 0
    private static var decideAbsX: CGFloat = 0
    private static var decideAbsY: CGFloat = 0
    private static var panSession = 0

    private static func handleScroll(_ event: NSEvent, appState: AppState) -> Bool {
        switch appState.viewMode {
        case .day, .week, .days: break
        default: return false
        }
        guard !appState.paletteOpen else { return false }
        guard appState.gridColumnWidth > 4 else { return false }

        // Navigation (Today, go-to-date) invalidates the gesture in flight so
        // leftover momentum can't re-anchor the grid it just left.
        if panSession != appState.panSession {
            panSession = appState.panSession
            if capture == .horizontal || capture == .deciding { capture = .passthrough }
        }
        // Never start a pan mid-pinch (pinches leak small scroll deltas).
        if appState.isZooming, capture != .horizontal { capture = .passthrough }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // Classic scroll wheel: no gesture phases, decide per event.
        if event.phase == [] && event.momentumPhase == [] {
            guard abs(dx) > abs(dy) else { return false }
            appState.isPanning = true
            appState.applyPan(dx)
            scheduleSettle(appState, delay: 0.25)
            return true
        }

        // Momentum keeps whatever the gesture decided.
        if event.momentumPhase != [] {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                let wasPan = capture == .horizontal
                capture = .idle
                if wasPan { settlePan(appState) }
                return wasPan
            }
            guard capture == .horizontal else { return false }
            snapWork?.cancel()
            appState.applyPan(dx)
            return true
        }

        switch event.phase {
        case .began, .mayBegin:
            if capture == .horizontal { settlePan(appState) } // momentum never arrived
            capture = .deciding
            decideX = 0
            decideAbsX = 0
            decideAbsY = 0
            return false
        case .ended, .cancelled:
            if capture == .horizontal {
                // Fingers lifted; momentum may still arrive — settle after a beat
                scheduleSettle(appState, delay: 0.08)
                return true
            }
            capture = .idle
            return false
        case .changed:
            break
        default:
            return false
        }

        switch capture {
        case .horizontal:
            snapWork?.cancel()
            appState.applyPan(dx)
            return true
        case .passthrough:
            return false
        case .idle, .deciding:
            // Accumulate until the direction is unambiguous, then latch.
            capture = .deciding
            decideX += dx
            decideAbsX += abs(dx)
            decideAbsY += abs(dy)
            guard decideAbsX + decideAbsY >= 5 else { return false }
            if decideAbsX > decideAbsY * 1.2 {
                capture = .horizontal
                appState.isPanning = true
                snapWork?.cancel()
                appState.applyPan(decideX)
                return true
            }
            if decideAbsY >= decideAbsX { capture = .passthrough }
            return false
        }
    }

    private static func scheduleSettle(_ appState: AppState, delay: TimeInterval) {
        snapWork?.cancel()
        let work = DispatchWorkItem { settlePan(appState) }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func settlePan(_ appState: AppState) {
        snapWork?.cancel()
        appState.settlePan { capture == .horizontal }
    }

    private static func handle(_ event: NSEvent, appState: AppState, store: CalendarStore) -> Bool {
        let isTyping = NSApp.keyWindow?.firstResponder is NSTextView
            || NSApp.keyWindow?.firstResponder is NSTextField

        // Palette navigation works even while its text field is focused
        if appState.paletteOpen {
            switch event.keyCode {
            case 125: appState.palette.move(1); return true    // down
            case 126: appState.palette.move(-1); return true   // up
            case 36, 76: // return (⌘↩: ask Claude)
                if event.modifierFlags.contains(.command) {
                    appState.palette.askTick += 1
                } else {
                    appState.palette.confirmTick += 1
                }
                return true
            case 53: appState.paletteOpen = false; return true // esc
            default:
                // FocusState on the palette's field can fail to land (the
                // overlay inserts mid-event stream), leaving typing with no
                // destination — route it straight into the query so search
                // works even with a dead text field.
                guard !isTyping else { return false }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods.subtracting([.shift, .option, .capsLock]).isEmpty else { return false }
                if event.keyCode == 51 { // delete
                    if !appState.palette.query.isEmpty { appState.palette.query.removeLast() }
                    return true
                }
                guard let chars = event.characters, !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) })
                else { return false }
                appState.palette.query += chars
                return true
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘Z / ⌘C / ⌘V → app undo / copy event / paste event, but only when
        // not editing text (then the Edit menu gets them as usual).
        if flags == .command, !isTyping {
            switch event.charactersIgnoringModifiers {
            case "z": store.undo(); return true
            case "c": appState.copyEvent(store: store); return true
            case "v": appState.pasteEvent(store: store); return true
            default: break
            }
        }
        guard flags.isEmpty || flags == .numericPad || flags == .function || flags == [.numericPad, .function] else { return false }

        // Esc works even while typing (cancel panel / availability)
        if event.keyCode == 53 {
            if isTyping, appState.panelContext == nil { return false }
            appState.handleEscape()
            return true
        }
        if isTyping { return false }

        switch event.keyCode {
        case 123: appState.step(-1); return true  // left
        case 124: appState.step(1); return true   // right
        case 51, 117:                              // delete / fwd delete
            if let ctx = appState.panelContext, !ctx.isNew {
                appState.requestDelete(ctx.event, store: store)
                return true
            }
            return false
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": appState.goToToday(); return true
        case "d": appState.setViewMode(.day); return true
        case "w": appState.setViewMode(.week); return true
        case "m": appState.setViewMode(.month); return true
        case "y": appState.setViewMode(.year); return true
        case "c": appState.newEvent(store: store); return true
        case "s": appState.toggleAvailabilityMode(); return true
        case "r": store.refresh(); return true
        case "b": appState.billEvent(); return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(event.charactersIgnoringModifiers ?? "") {
                appState.setDayCount(n)
                return true
            }
            return false
        default:
            return false
        }
    }
}
#endif
