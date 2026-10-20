# Fork Calendar

A native Notion-Calendar-style calendar app for macOS and iOS, built with SwiftUI on the Google Calendar API. Sign in to each Google account directly — no dependency on the system Calendar app, its accounts, or its sync.

**v0.14.6**

## Google accounts & sync

- Settings (⌘, / gear in the sidebar) → **Add Google account…** opens Google's sign-in page; add as many accounts as you like, each with its own calendars and its own token. Toggle sync per account, remove accounts any time.
- You supply the OAuth client (console.cloud.google.com → APIs & Services → Credentials, with the Calendar API enabled). macOS uses a **Desktop app** client (loopback redirect); iOS uses an **iOS** client for bundle ID `com.cwandt.forkcalendar.app` (falls back to the desktop client).
- Everything is cached locally (JSON in Application Support / the app group) and kept fresh with Google's incremental sync tokens. Launch shows the cache instantly, then syncs.
- **Sync control:** pick the background interval (manual / 1 / 2 / 5 / 15 min), whether to sync when the app becomes active, ⌘R (or R) for a full pass right now, and "clear cache and re-download" if something looks off. Edits go to Google immediately.
- **RSVP & notification control:** choose whether RSVPs email the organizer, and whether changes to events with guests (create, move, edit, delete, invite) email the guests — always, never, or ask each time. Guests and Google Meet links are part of the same save.
- Recurring events: "this event" patches the instance; "this and all future" patches the series when it's the first occurrence, otherwise ends the old series and starts a new one.
- iOS widget reads the app's published snapshot (today + 2 days).

## Features

- Day / N-day (1–9) / Week / Month / Year views
- Month view scrolls continuously through the year; drag event chips between days
- Year view: whole year as a stack of weeks with event dots (Y)
- Right-hand event panel (Notion-style): click an event to open, edit inline
- Sidebar with mini-month and per-calendar show/hide toggles, grouped by account
- Calendar focus sets: save which calendars are showing as a named set (sidebar FOCUS → +), click a set to switch to it (the active one is checked), right-click to update, rename or delete; ALL / NONE show or hide every calendar. Also in ⌘K ("Focus: …", "Show all calendars", "Hide all calendars", "Save calendar set…") and View ▸ Calendar Sets (⌥⌘1–9)
- Solo a calendar: ⌥-click it in the sidebar to show only that one (⌥-click again to show all), or right-click → Show only this calendar
- Hide declined events in one click: view menu (Week ▾) → Show declined events, ⌘K, or View ▸ Show Declined Events (⇧⌘D)
- Header ‹ Today › buttons step to the previous / next week (or day, month, year — whatever the view shows) on macOS
- Time grid: red now-line, overlapping-event layout, all-day row, past events dimmed
- Drag on empty grid to create; drag events to move (15-min snap, across days); drag top/bottom edges to resize; ⌥-drag to duplicate
- Right-click context menus: join meeting, duplicate, move to calendar, copy title, delete
- ⌘K command menu: commands, event search (±1 year), "go to date", and natural-language quick add ("Lunch with Amy tomorrow 1pm")
- Share availability: press S, drag slots, copy as text
- Recurring events (daily/weekdays/weekly/biweekly/monthly/yearly) with "this event / all future" prompts
- Attendees with RSVP status; join-meeting detection (Zoom, Meet, Teams, Webex, …)
- Add conferencing: Zoom personal room (set in Settings), Google Meet create-and-paste, or paste any link
- Invite people by email — added to the Google guest list on save (email per your notification setting)
- Multi-day/all-day events render as single continuous bars across days (week + month views)
- Week/day views side-scroll smoothly day-by-day (trackpad); a light snap engages only within a day of full-week framing
- Custom per-calendar colors (hover a sidebar calendar → palette, presets or any color)
- Guest lists, auto-created Google Meet links, and RSVP (Going/Maybe/No) from the event panel or right-click — per account, so invites to any signed-in account can be answered
- Events awaiting your RSVP show a dotted outline; merged copies across calendars get one color strip per calendar, dashed while that copy awaits your RSVP
- Undo (⌘Z) for moves, edits, deletes, and creates
- macOS menu bar agenda with next event + Join buttons
- Settings (⌘,): accounts, sync cadence, guest/RSVP emails, default calendar, week start, default duration, weekends, declined events, secondary time zones in the gutter

## Personal OS (optional)

Hooks into a [Personal OS](https://personal-os-two-gold.vercel.app) instance — a todo / people / call-sheet web app that mirrors every dated todo into a Google calendar ("EC") as an all-day event. Off until you set it up: Settings (⌘,) → **Personal OS** → paste the base URL and your capture token, then **Test connection**. With both set:

- **Two-way EC todos:** todo events get a checkbox on their all-day bar (click to mark done / not done; dropped todos show a struck, inactive box), plus the same in the right-click menu and the event panel. Dragging a todo to another day (or editing its date, or undoing a move) moves the todo's due date too.
- **Follow-up todos:** right-click any other event (or use its panel button, or ⌘K with the event open) → **Follow up in Personal OS** creates "Follow up: *event title*" due the next weekday, with the time and attendees in the notes and a link back to the event.
- **Call sheet:** today's people to call appear in the sidebar under CALL SHEET, refreshed with every sync. Tick a person's checkbox to mark them done (again to undo); click the name to open their profile. **Get someone else** (the ⟳ swap control on hover — always shown on iOS — or right-click) asks Personal OS to swap that person for another; if nobody's left to swap in, its message shows as a toast.

The token is stored locally with the rest of the app's settings, like the Google tokens.

## Claude assistant (optional)

Type what you want in ⌘K and let Claude do it: "schedule a 30 min meeting with Amy Thursday afternoon", "cancel my meetings this week", "what's on Friday?", "move standup to 10". Off until you set it up: Settings (⌘,) → **Claude assistant** → paste an [Anthropic API key](https://console.anthropic.com/settings/keys), pick a model (Claude Opus 5.5 by default; Sonnet 5.5 and Haiku 5.5 are faster), then **Test**.

- With a key set, ⌘K shows an **Ask Claude** row for whatever you've typed (⌘↩ sends it straight away). Quick add, commands and event search work as before.
- Claude looks at your calendars (events, free time, people you meet with) to work out a plan. **It never changes anything on its own:** the palette lists exactly what will happen ("Delete · Weekly Leads · Tue 12:00–1:15 PM · 4 guests (no email)", "Decline · … · tell organizer", "Create · Coffee with Amy · Thu 3:00–3:30 PM · Work · invite amy@…"), and nothing happens until you press **Confirm** (↩). Esc discards it.
- Cancelling: meetings you organize (or that have nobody else on them) are deleted; meetings someone else organizes are declined, never deleted. For a repeating meeting only that occurrence is touched. Guest and organizer emails follow your Settings.
- If your request is ambiguous ("Amy" could be two people), Claude asks — type the answer in the same box. It only invites addresses that appear in your events or that you typed.
- After you confirm, one ⌘Z undoes the whole batch.

The key is stored locally with the app's other settings and sent only to `api.anthropic.com`; requests include the events Claude looks up. Never commit a key — this repo is public.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| T | Today |
| D / W / M / Y | Day / Week / Month / Year view |
| 1–9 | Show N days |
| ← / → (or ‹ › in the header) | Previous / next period |
| ⇧⌘D | Show / hide declined events |
| ⌥⌘1–9 | Apply calendar set 1–9 |
| ⌥-click a calendar | Show only that calendar (again: show all) |
| C | Create event |
| S | Share availability |
| ⌘K | Search & commands |
| ⌘↩ (in ⌘K) | Ask Claude (with an API key set) |
| ⌘Z | Undo |
| ⌘C / ⌘V | Copy selected event / paste it at the slot or day under the pointer |
| ⌘N | New event |
| ⌘\ | Toggle sidebar |
| Esc | Close panel / palette / availability |
| ⌫ | Delete selected event |

## Building

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
# macOS
xcodebuild -project ForkCalendar.xcodeproj -scheme ForkCalendar build
# iOS simulator
xcodebuild -project ForkCalendar.xcodeproj -scheme ForkCalendar-iOS -destination 'generic/platform=iOS Simulator' build
```

Targets: macOS 15+, iOS 18+. Add a Google account on first launch.

## License

MIT — see [LICENSE](LICENSE). JetBrains Mono is bundled under the [SIL Open Font License](https://scripts.sil.org/OFL). The chrome is set in Helvetica Now Text (licensed, not in the repo — drop the .otf files into `Sources/Fonts`; without them the UI falls back to the system font).
