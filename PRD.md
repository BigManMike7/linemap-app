# LineMap Beta — PRD

LineMap is an iPhone beta that shows live, community-reported lines and waits at three State College bars. It ships on TestFlight to learn whether students will report, and how accurate crowd-sourced estimates can be.

This file is the full product spec. `CLAUDE.md` holds the working rules and points here.

## 1. Summary

- **Problem.** Students heading downtown can't tell how long a bar's line is until they walk there. Lines move fast on busy nights, so word of mouth is quickly out of date.
- **Solution.** People at a bar tap **Start line timer** or **Report line size**. Everyone else sees the current line size, the wait, and how fresh that information is. Waits are measured with a simple in-app timer, not guessed.
- **Context.** LineMap is a learning project, not a business. It launches with six bars: Pmans, Doggie's Pub, Brothers Bar & Grill, Champs Downtown, Cafe 210 West, and The Gaff (2026-10-06; it started with Doggie's Pub, The Phyrst, and Cafe 210 West).

## 2. Goals and success metrics

**Goals**

- Ship a polished, working iPhone app to a public TestFlight link.
- Collect clean, comparable data from day one.
- Learn whether students report, whether they come back, and how accurate the estimates are.
- Keep the app simple and modular, so later features are additions, not rewrites.

**Non-goals for the beta**

- Making money, ads, or bar partnerships.
- Averages or predictions. The beta shows live estimates and each bar's past nights (FR-43), never averages across nights.
- Accounts, social features, or messaging.
- Android or web.

**Success metrics**, judged at the checkpoint at the end of Phase 2:

| Metric | Target |
| --- | --- |
| Unique reporters per week | 15 |
| Users who come back the following week | 30% |
| Line size and wait within one range of a spot check | 70% |
| Timer completion: wait sessions ending in "I'm in" or "Gave up" | Set after the first two weekends |
| Viewer-to-reporter ratio | Track; no target yet |

## 3. Users and user stories

| User | Who | Main need |
| --- | --- | --- |
| Viewer | A student deciding where to go | Know the line and wait before walking over |
| Reporter | A student in line or inside a bar | Report in a few taps, one-handed, at night |
| Admin | Max | Manage bars and rules, hide bad reports, analyze the data |

**User stories**

- As a viewer, I can see each bar's line size, wait, and how fresh that is, so I can pick where to go.
- As a viewer, I can see every bar in one list, shortest wait first.
- As a viewer, I'm told plainly when there isn't enough data, so I don't trust a stale number.
- As a viewer, I can look back at earlier tonight or any past night at a bar, so reports stay useful after they go stale.
- As a viewer, I can get walking directions to a bar in one tap.
- As a reporter in line, I tap once to start a timer and tap again when I get in, so my wait is measured without guessing.
- As a reporter at a bar, I can report the line size in a few taps, on one screen.
- As a reporter, I can skip any question, cancel a line I started by mistake, or delete a wrong report I made in the last 24 hours.
- As a reporter, I can undo an I'm in or Gave up I tapped by accident, and redo a timer or report I got wrong within a few minutes without being told to wait.
- As any user, I can use the app without an account or giving my age, and delete my data from Settings.
- As the admin, I can add a bar, change a threshold, or hide a report from the dashboard without shipping an app update.

## 4. Scope

| In v1 | Later (Phase 2) | Out of scope for the beta |
| --- | --- | --- |
| Map with bar pins, and bar sheet | Live Activity lock-screen timer | Averages and predictions |
| Report flow with timed waits | Event nights | Machine learning |
| Live estimates with freshness | More bars (up to 5–8) | Geofencing and passive detection |
| Location check on reports | Threshold tuning from data | Notifications and alerts |
| Anonymous ID, Delete my data | App Attest, if spam appears | Cover charge, specials, partnerships |
| "This looks wrong" feedback | | Android and web |
| Offline report queue | | Accounts and social features |
| Logging, snapshots, admin via dashboard | | |
| Directions, Delete a report, thank-you | | |
| Bar history by night (M4) | | |
| Tab bar, Bars list, and History screen (M4) | | |
| Undo and Redo for timers and reports (M4) | | |

## 5. Functional requirements

All v1 requirements must be done before launch. Every threshold named here is a server setting in the `config` table, not hard-coded.

### 5.1 Screens

| ID | Requirement |
| --- | --- |
| FR-1 | **Map home screen.** The app opens straight to an Apple Map (MapKit, no API key needed), centered on downtown State College and framing every active bar. Each bar is a pin labeled with its name and line time, e.g. "The Phyrst · 25 min". The Map is one of three tabs (FR-44); the Bars tab lists the same bars (FR-45). The map shows the user's location dot only if location permission was already granted. It never asks for permission on launch. |
| FR-2 | **Pin labels.** Line time is the bar's current wait estimate (FR-17 to FR-19): either the last measured wait ("25 min") or a reported range ("15–30 min"). If there's no wait estimate but there is a fresh line size, the label shows the line size ("~10–25 in line"). Otherwise it shows "No live reports". The label has two lines, the bar name over its status (2026-10-06; before, one line such as "The Phyrst · 25 min", which ran off the screen for long names). Labels based on reports 30–60 minutes old are grayed out. **Pin colors** (2026-10-05) show how hard the bar is to get into, from the same wait or line size the label shows: green with a check for a short line (a wait under 10 minutes, or No line or 1–10 in line), orange with a clock for some line (10–25 minutes, or 10–25 in line), red with an exclamation mark for a long line (25 minutes or more, or 25–50, 50–100, or 100+ in line). A reported wait range counts by its midpoint (under 5 is short, 5–15 and 15–30 are some, 30–60 and 60+ are long). The crowd (removed 2026-10-06) never changed the color. **Uncertain** (2026-10-05): when the wait and the line size contradict, one short and the other long (such as a 0-minute timer next to 100+ in line), the pin reads "Uncertain" with a gray question mark, and the app doesn't pick one; the bar sheet shows both so people can decide. One level apart (such as a 5–15 min wait and 100+ in line) is not a contradiction, and the wait shows. An Uncertain pin counts as older only when both the wait and the line size are. Uncertain bars sort after bars with only a line size (FR-45), and an Uncertain quarter hour in History gets a gray dot (FR-43). Pins from reports 30–60 minutes old are outlined instead of filled; no live reports is gray. The cutoffs live in the app, since they only color what's shown. |
| FR-3 | **Bar sheet.** Tapping a pin opens a bottom sheet over the map. It shows: the bar's name (no address); line size now; the wait (a measured wait like "25 min, got in 10 min ago", or a reported range), which matches the pin unless the pin reads Uncertain; freshness as "N people · latest X min ago"; a pill with the line level from FR-2 ("Short line", "Some line", or "Long line" in its color, or a gray "Uncertain" when the wait and line size contradict, so both rows above it are there to compare); a **Does this look wrong?** link that asks to confirm before sending (FR-35); and **Start line timer** and **Report line size** buttons. While the person is in line at that bar, Report line size is replaced by **I'm in**. It also has **Directions** (FR-40). History opens from the Bars list instead (FR-43, FR-45; moved 2026-10-05). No trend arrows in v1. |
| FR-4 | **Wait card.** While a wait session is open, a card floats over the map every time the app opens. It shows the running timer, a large **I'm in**, then **Line size** and **Adjust time**, plus a large ✕ that stops the timer: it asks whether the person gave up (FR-9) or started the line by mistake (FR-39). No Directions: the person is already there. Tapping the timer opens that bar's sheet. The card shows on the Map and Bars tabs, just above the tab bar, and is hidden on the Settings tab; the timer keeps running there. |
| FR-5 | **Settings.** The third tab (FR-44); there is no gear button on the map (2026-10-05; it was a gear button and sheet before). Contains **Made a wrong report?** (FR-41), Delete my data, links to the privacy policy and support page, and the contact email. |
| FR-40 | **Directions.** A Directions button on the bar sheet (not the wait card) opens Apple Maps with walking directions to the bar's door pin. It needs no location permission. |
| FR-44 | **Tab bar.** Three tabs along the bottom, each an icon with a short label: **Map**, **Bars**, and **Settings**. After a full close (or when iOS ends the app in the background) the app opens on Map. Going to the home screen and back returns to the tab and screen the person left, which is the iOS default. |
| FR-45 | **Bars list.** One simple card per active bar, showing what the pins and bar sheet show: name, line size, wait, and "N people · latest X min ago", grayed out when stale. Each card with a line level (FR-2) shows it as a colored pill by the name and a colored strip down its left edge, faded when stale. Order: fresh estimates first, then grayed-out ones; within each, bars with a wait (shortest first), then bars with only a line size (smallest first, by size rank, 2026-10-06), then Uncertain bars (FR-2). Bars showing No live reports come last, in dashboard order (`display_order`). The list re-sorts when new data arrives. Tapping a card switches to the Map tab, centers on that bar, and opens its bar sheet (FR-3). Each card also has its own **History** button (FR-43; named History & details until it lost Right now on 2026-10-05). Cards have no report buttons. |

### 5.2 Reporting

| ID | Requirement |
| --- | --- |
| FR-6 | **Start line timer** (named "I'm in line" before 2026-10-04) starts a wait session saved on the server in one tap and asks nothing else. **Line size** on the wait card asks "How many people are in line?" (the whole line, not just the people ahead) at any time while waiting, on one wheel: No line, 1–10, 10–25, 25–50, 50–100, or 100+ (2026-10-06; before, 0, 1–10, 10–25, 25–50, or 50+). The wheel opens on the last answer given in this wait, and **Save** sends it; there is no Skip button, so swiping the sheet away skips it (2026-10-05; before that each size was its own button, plus Skip). Every answer is saved as its own report and none is rate-limited. (Builds before 2026-10-04 asked how many people were ahead; see `supabase/README.md`. "Can't see the end" was dropped from the app on 2026-10-01; its stored code 5 stays reserved. Code 4, "50+", is no longer offered but keeps its meaning for old reports.) |
| FR-7 | **Adjust time** on the wait card asks how long the person was in line before starting the timer, on one wheel of every minute from 0 to 90. **Save** sends it; swiping the sheet away changes nothing (2026-10-05; before that it saved when the sheet closed). It moves the session's start time back by that much (0–90 minutes), and can be changed or undone while the session is open. (Before 2026-10-04 the choices were ~5, ~10, and ~20 min, then preset buttons plus a wheel; those stored values keep their meaning.) |
| FR-8 | **I'm in** ends the session as entered and asks nothing. Measured wait = end time − adjusted start time. (The busyness question after I'm in was dropped on 2026-10-04.) |
| FR-9 | **Gave up**, chosen from the wait card's ✕, ends the session as gave up. |
| FR-10 | **Unanswered sessions.** After 90 minutes the server marks the session unfinished. A later "I'm in" does nothing. |
| FR-11 | **Report line size** opens one screen with one question, "How many people are in line?", six choices (No line, 1–10, 10–25, 25–50, 50–100, or 100+), and **Send**. Send stays off until a choice is picked, and the report is sent once. It works whether the person is in line, inside, or nearby, so its position is stored as unspecified, and its kind is still `conditions`. It never touches a wait session. (It replaced **I'm inside** on 2026-10-04 as **Report conditions**, which also asked how busy the bar was inside: Quiet, Comfortable, Busy, or Packed. The crowd question was removed on 2026-10-06, and the button was renamed Report line size. The app no longer asks how long it took to get in; the recalled-wait codes stay reserved. Busyness codes 1–4 stay reserved and are never reused: the `busyness` column is kept but nothing is stored in it. Older builds may still send a crowd answer; the server accepts the report but drops the crowd part, and a crowd-only report is accepted but not stored.) |
| FR-12 | **Answers.** Every question is optional and can be skipped; a skip is stored. Line size and Adjust time are saved when the person taps Save, and swiping their sheet away skips them; Report line size is saved when sent. ("I can't tell" was dropped from the app on 2026-10-01; the stored `cant_tell` state stays reserved.) |
| FR-13 | **Rate limit.** Two separate limits per person per bar, each 10 minutes, enforced on the server: one timed line (Start line timer), and one manual report (Report line size, or I'm inside from older builds). Neither blocks the other, so someone can report and then get in line, or time a line and then report its size. A report deleted with FR-41 still counts toward its own limit until its 10 minutes are up. Not limited: line-size updates in an open session, I'm in, Gave up, and the busyness answer after I'm in (sent only by builds before 2026-10-04, and no longer stored since 2026-10-06). Redo (FR-46) is the one exception to the limit. (One shared limit until 2026-10-04.) |
| FR-14 | **One line at a time.** Starting a line at another bar closes the open session as gave up. |
| FR-15 | **I'm inside with an open session** at that bar counts as I'm in. The app no longer has I'm inside (2026-10-04); the server keeps this rule for older builds. |
| FR-39 | **Cancel line.** "Started it by mistake", chosen from the wait card's ✕, discards the line: the server deletes the session and its reports, so nothing from it counts, including toward the rate limit. A finished wait can't be cancelled. |
| FR-46 | **Redo.** A person can replace their own last attempt at a bar within `redo_minutes` (5, a server setting) instead of being refused by the rate limit. **Timers:** if their last timer at this bar stopped (I'm in or Gave up) less than 5 minutes before they start a new one there, the new one is allowed. The earlier one is deleted only when the new one finishes (I'm in or Gave up); if the new one is cancelled as started by mistake (FR-39), the earlier one stays. **Report line size:** if their last Report line size at this bar was sent less than 5 minutes ago, a new one is allowed and replaces it at once. A report already deleted with FR-41 counts the same way, so it can be redone within those 5 minutes. After 5 minutes the normal 10-minute limit applies. Only the newest attempt ever counts, so redoing can't add extra reports. Replaced attempts are deleted like a cancelled line (FR-39), with no deletion count. |
| FR-47 | **Undo.** After I'm in or Gave up, the message (FR-42) has an **Undo** button for about 5 seconds. Undo reopens the same timer with its original start time and Adjust time, as if it had never stopped. The server allows it only for the person's own timer, stopped less than `redo_minutes` ago, when no other timer is open and it hasn't become unfinished (FR-10). |
| FR-42 | **Thank-you.** After Report line size, I'm in, or Save on Line size, once the server has accepted it, a short message shows for 2–3 seconds with a light haptic: "Thanks! Your update is now visible to everyone." Save on Adjust time shows no message, only the light haptic, since the wait counts only once it ends; if the time is the same as before (usually because Save was tapped while the wheel was still spinning), it says "No change. Let the wheel stop, then tap Save." (2026-10-06; before that it said "Saved! Your timer now includes your time in line."). If the phone is offline it says "Thanks! Your update will send when you're back online." instead. Gave up shows "Timer stopped." After I'm in and Gave up the message carries **Undo** (FR-47) and stays about 5 seconds. A refused report shows the usual "Already reported" alert. |
| FR-16 | **Offline queue.** Reports and session events queue on the phone when offline and retry with a client-generated ID, so nothing is saved twice. The queue survives app restarts. Late reports are always stored, but count toward live estimates only if their phone time is within the freshness window. |

### 5.3 Estimates (computed on the server)

| ID | Requirement |
| --- | --- |
| FR-17 | **Freshness.** A report is fresh for 30 minutes. From 30 to 60 minutes it shows as older and grayed out. After 60 minutes the bar shows "No live reports". This holds at any time of day (2026-10-06: before then, outside the active window a bar showed "Outside usual hours, no recent reports" unless a report was under 30 minutes old, so 30–60-minute-old reports were hidden). Measured waits age from when the person got in. |
| FR-18 | **People count.** Freshness counts distinct people, so one person reporting twice counts once. Every report is still stored as its own data point; for each signal, the live estimate uses each person's newest answer. |
| FR-19 | **Shown value.** For each signal separately (line size and wait), the newest report wins. The exception: if it disagrees with 2 or more fresh reports from other people, the majority wins. "Agree" means within one range. Line size codes aren't in size order, so comparisons use a size rank: 50+, 50–100, and Can't see the end share a rank, and 100+ is above them (2026-10-06). The crowd is ignored by estimates and History. |
| FR-20 | **Uncertain reports** count like any other in v1. |
| FR-21 | **Server logic.** Estimates are computed by SQL functions on the server. Each response carries a logic version. It is 4 since 2026-10-06 (3: no active window; 4: no crowd, new line size ranks). |
| FR-43 | **History (M4).** Each card in the Bars list (FR-45) has a **History** button that opens a full-screen page for the bar, with the history in one card: Apple's standard calendar, opening on tonight and going back one year (the retention limit). A date means that night's whole day, from 4 a.m. to 4 a.m. Eastern (the night boundary, FR-22), so Saturday, Oct 3 runs from 4 a.m. Saturday to 4 a.m. Sunday and includes a football afternoon; after midnight the calendar still opens on the night in progress. Under the calendar, the night shows as a "Busiest around 11:30 PM" line and one row for every quarter hour of that day, 4:00 AM to 3:45 AM. Each row covers only its own quarter hour: the 10:30 PM row combines the reports made from 10:30:00 to 10:44:59, so a single report appears in exactly one row and a one-time report looks like one. Within a quarter hour the live rules apply (each person's newest report counts once, the newest wins unless 2 or more others disagree and the majority wins, a timer counts in the quarter hour the person got in). Each row has a dot in its line-level color (FR-2), the line size, wait, and how many people reported in that quarter hour. "Busiest around" ranks quarter hours by line size, then wait (2026-10-06; it counted the crowd before). A single quarter hour with nothing reads "No reports" with an empty ring; two or more in a row become one row such as "No reports, 4:00 AM – 8:45 PM". A night with no reports says so. Tonight shows rows only up to now, and the current quarter hour fills in as reports arrive. (2026-10-06: rows used to show what the map showed at each mark, so one report filled about four rows for up to an hour; rows ran from 9:00 p.m. to 1:45 a.m. stretched to cover reports; the night heading such as "Saturday night, Oct 3" was removed, since the calendar shows the date, and older rows are no longer grayed. 2026-10-05: Right now was removed, since the bar sheet and Bars card already show it; History covered only 9 p.m. to 2 a.m. in half hours before then.) History is computed from the reports each time it is opened, so deleted (FR-41), replaced (FR-46), and hidden reports never appear. It shows only combined estimates, never individual reports. (Decided 2026-10-05: the first build had a night menu, a Same night last week shortcut, and charts, opened from the bar sheet.) |

### 5.4 Any hour

Bars are open most of the day, so LineMap has no hours. People can report at any time, and every bar shows its live estimate, or "No live reports" with nothing in the last hour (FR-17), at every hour. (2026-10-06: there used to be an active window, Thu–Sat 9 p.m.–2 a.m. Outside it, reports older than 30 minutes were hidden behind "Outside usual hours", bars showed "Closed" from 2 to 4 a.m. after an active night, and snapshots were taken only inside it. Logic version 3 removed it.)

| ID | Requirement |
| --- | --- |
| FR-22 | **Night boundary.** A night runs until 4 a.m. Eastern, so 1 a.m. Sunday belongs to Saturday night. Each report stores its night date, set on the server. Daylight-saving changes are handled. |
| FR-23 | **Event nights.** Unused since 2026-10-06. The empty `event_nights` table is kept for later, but nothing reads it now that there is no active window. |

### 5.5 Location

| ID | Requirement |
| --- | --- |
| FR-24 | **Permission.** "While Using the App" only, requested the first time the user reports. The app works fully if permission is denied. |
| FR-25 | **When captured.** On each report, and when a wait session starts and ends. Never in the background. |
| FR-26 | **What's stored.** The server computes distance to the bar's door, direction, GPS accuracy, and fix age, then discards the coordinates. |
| FR-27 | **Uncertain flag.** Set when the report is far from the bar, accuracy is poor, location is approximate, permission is denied, or there's no fix in time. No report is rejected for its location. Thresholds are server settings. |
| FR-28 | **Door pins.** Each bar's pin starts at its geocoded street address and can be edited later in the dashboard. |

### 5.6 Identity and privacy

| ID | Requirement |
| --- | --- |
| FR-29 | **Anonymous ID.** A random ID stored in the Keychain, on this device only and not synced to iCloud. It survives reinstalling the app. |
| FR-30 | **Install ID.** A random ID in regular app storage, new on each install. |
| FR-31 | **No barriers.** No accounts, no sign-in, no age question. |
| FR-32 | **Delete my data** permanently deletes the anonymous ID's reports, wait sessions, views, install rows, feedback, and rate-limit holds. It records a deletion count with no ID, then creates a new anonymous ID. |
| FR-41 | **Made a wrong report?** In Settings, lists the person's own reports and finished timed waits from the last 24 hours (bar, time, and answers), each with Delete. Delete permanently removes the report, or the whole wait session and its reports, so it stops counting right away. A wait still running is cancelled from the wait card instead (FR-39). The rate limit keeps running from a deleted report: the server keeps only the anonymous ID, bar, and time until the 10 minutes are up, except that Redo (FR-46) still applies within its 5 minutes. Each deletion logs a count with no ID. |
| FR-33 | **Retention.** A daily job deletes data tied to an anonymous ID once it's 1 year old. Estimate snapshots have no IDs and are kept. |

### 5.7 Logging and admin

| ID | Requirement |
| --- | --- |
| FR-34 | **Views.** Every view of the map or a bar sheet is logged with the anonymous ID, the estimate shown, the logic version, whether it showed "no data", and an app-open ID. No location. |
| FR-35 | **Feedback.** "Does this look wrong?" on the bar sheet asks to confirm ("Yes, it looks wrong" or Cancel), so a stray tap sends nothing; only Yes saves the bar, the estimate shown, and the time. (It was a one-tap "This looks wrong" button before 2026-10-05.) |
| FR-36 | **Snapshots.** Every 5 minutes, at any hour, the server saves what each bar showed, for bars with a report in the last hour. A bar with no snapshot at a moment was showing "No live reports". (Before 2026-10-06: every bar, during the active window only.) |
| FR-37 | **Admin via the Supabase dashboard.** Add or edit bars; change settings, with every change logged in `config_history`; hide a report with a reason; log spot checks. |
| FR-38 | **Test data.** Every row has an `is_test` flag, so the admin's own testing never mixes with real data. |

## 6. Non-functional requirements

| ID | Area | Requirement |
| --- | --- | --- |
| NFR-1 | Speed | The map shows the last loaded pins instantly, then refreshes. Target: fresh data in under 3 seconds on a normal LTE signal. |
| NFR-2 | Weak signal | Reporting never blocks on the network or a GPS fix. Reports queue and send later (FR-16). |
| NFR-3 | Usability | Works one-handed at night: large tap targets, a report in 3 taps or fewer, dark mode. |
| NFR-4 | Accessibility | Supports Dynamic Type, with VoiceOver labels on every control. |
| NFR-5 | Security | Row-level security blocks direct table access; the app only calls database functions. The service key never ships in the app or the repo. |
| NFR-6 | Privacy | No third-party analytics, ads, or tracking SDKs. Exact coordinates are never stored. |
| NFR-7 | Reliability | A daily scheduled GitHub Action calls the database so the free Supabase project never pauses. |
| NFR-8 | Correctness | Database tests (pgTAP, on a free Linux runner) cover estimate rules, the 4 a.m. night boundary, and daylight-saving changes. Swift unit tests cover pin labels, the timer, and the offline queue. All tests run on every push. |
| NFR-9 | Modularity | Estimate and night logic live in server SQL functions; app logic lives in a separate Swift package. New report sources (e.g. Live Activity) need no data model changes. |
| NFR-10 | Data stability | Answer ranges are stored as fixed codes. Every report records the app version and definitions version. The definitions version is 2 since 2026-10-06 (line sizes No line, 1–10, 10–25, 25–50, 50–100, 100+ as codes 0, 1, 2, 3, 6, 7); the server accepts versions 1 and 2, and version 1 may use codes 0–5. Code 4 (50+) keeps its meaning and code 5 stays reserved. |

## 7. Architecture and data model

### 7.1 Stack

| Part | Choice |
| --- | --- |
| App | SwiftUI, iPhone, iOS 17+ |
| Project file | XcodeGen (`project.yml`), since there's no Mac to edit Xcode projects on |
| Core logic | Server: estimate rules and the night boundary as SQL functions, tested with pgTAP. App: a separate Swift package (LineMapCore) for models, pin labels, the wait timer, and the offline queue |
| Backend | Supabase in US East: Postgres, database functions, scheduled jobs. The dashboard is the admin tool |
| Build and release | GitHub Actions macOS runner + fastlane, signed with an App Store Connect API key |
| Repo | Public GitHub repo, so runner minutes are free. Keys live in GitHub Secrets |
| Distribution | TestFlight: internal for Max, public link for testers |
| Time zone | America/New_York for all rules |

### 7.2 Server functions and jobs

**Functions the app calls.** These are the only way the app reaches the database: get bars, get estimates, report line size (the `report_conditions` function), start session, update line size, end session, cancel session, send feedback, register install, log view, delete my data, my recent reports, delete report, and (M4) bar history and reopen session (Undo, FR-47). `submit_report` (I'm inside) stays on the server for builds before 2026-10-04, but the app no longer calls it.

**Scheduled jobs**

- **Every 5 minutes:** mark sessions older than 90 minutes as unfinished, and clear rate-limit holds older than 10 minutes.
- **Every 5 minutes:** save estimate snapshots for bars with a report in the last hour.
- **Daily:** delete ID-linked data older than 1 year.
- **Daily (GitHub Action):** call the database so the project doesn't pause.

### 7.3 Data model

Every table also has `id`, `created_at`, and `is_test`. All data stored before 2026-10-06 was deleted that day; it was Max's own testing, so no old crowd answers exist. Weather and football data aren't stored; they can be filled in later from historical sources.

| Table | What it holds | Key fields |
| --- | --- | --- |
| `bars` | The bar list | name, address, door coordinates, size class, active, display order, date added |
| `installs` | One row per install | anon ID, install ID, first and last seen, app version, iOS version, device model |
| `reports` | Every report | client report ID, anon ID, install ID, bar, night date, position (line, inside, or unspecified for Report line size), kind, wait session ID, line size (0–7), busyness (kept but unused since 2026-10-06), and recalled wait (each with an answer state: answered, can't tell, skipped), phone time, server time, location status, distance, direction, accuracy, fix age, uncertain, hidden and hidden reason, app version, definitions version, source (app now, Live Activity later) |
| `wait_sessions` | One timed wait | client ID, anon ID, bar, night date, start time, Adjust time offset (0–90 min), end time, status (open, entered, gave up, unfinished), what ended it, distance at start and at end |
| `views` | Every view of the map or a bar sheet | anon ID, install ID, map or bar, time, estimate shown, logic version, whether it showed "no data", app-open ID |
| `feedback` | "This looks wrong" taps | anon ID, bar, estimate shown, time |
| `config`, `config_history` | Current settings, and every change to them | key, value, changed at. M4 adds the setting `redo_minutes` (5) for Redo and Undo (FR-46, FR-47), and removes `active_nights`, `active_window_start`, and `active_window_end` with the active window (2026-10-06) |
| `event_nights` | Special nights (empty; unused since 2026-10-06, kept for later) | date, label, type, window override |
| `estimate_snapshots` | What each bar showed, every 5 minutes | bar, time, full estimate, logic version |
| `spot_checks` | Admin ground truth | bar, time, line count seen, wait timed, notes |
| `deletions` | A count of data deletions | time, rows removed, scope (all for Delete my data, one for a single report) (no ID) |
| `rate_limit_holds` | Keeps the rate limit running after a report is deleted (FR-41) | anon ID, bar, kind (which limit it holds), phone time; cleared after 10 minutes |

**Bars at launch** (Max, 2026-10-06), in display order. Pins are geocoded from these addresses (OpenStreetMap) and can be adjusted later in the dashboard. The Phyrst, a starting bar, is kept inactive.

| Bar | Address |
| --- | --- |
| Pmans (Primanti Bros.) | 130 Heister St, State College, PA 16801 |
| Doggie's Pub | 108 S Pugh St, State College, PA 16801 |
| Brothers Bar & Grill | 134 S Allen St, State College, PA 16801 |
| Champs Downtown | 139 S Allen St, State College, PA 16801 |
| Cafe 210 West | 210 W College Ave, State College, PA 16801 |
| The Gaff (The Shandygaff) | 212 E College Ave (rear entrance), State College, PA 16801 |

## 8. Release plan

Build in order, and test each milestone before starting the next.

### Phase 1: Build the beta

| Milestone | Includes | Done when |
| --- | --- | --- |
| M1. Setup | Repo, XcodeGen project, LineMapCore package, CI pipeline | An empty app builds in CI and installs on Max's iPhone through TestFlight |
| M2. Backend | All tables, row-level security, functions, scheduled jobs, the three starting bars | Database tests pass; a bar and a setting can be changed from the dashboard |
| M3. App | Screens, report flow, wait card, location, IDs, offline queue, feedback, Settings, Directions, Made a wrong report?, thank-you | The full flow works end to end on a phone |
| M4. Polish | Tab bar (FR-44), Bars list (FR-45), History (FR-43), Redo and Undo (FR-46, FR-47), dark mode, accessibility, empty and error states, privacy policy and support pages on GitHub Pages, App Store Connect filled in | Every screen has been reviewed in CI screenshots and on the phone |
| M5. Field test | Downtown on a quiet night and a busy one: location (allow, deny, approximate), offline queue, timers | No blocking bugs; Beta App Review submitted |
| M6. Launch | Public TestFlight link; 5–10 friends report on opening nights; recruit students | The first busy weekend is live |

### Phase 2: Collect and analyze

- Each active night, watch reports, finished timers, views, and "no data" views. Hide bad reports.
- Do spot checks: count a line, time a wait, and compare with the snapshot from that moment.
- Review weekly: unique reporters, return visits, timer completion, deletions, and reinstalls.
- Tune freshness and agreement rules from the server.
- Ship the Live Activity, a lock-screen version of the same wait session. It needs no push server.
- Add bars only when the current ones get regular reports on busy nights.
- At the checkpoint, compare against the success metrics and decide whether to continue, change direction, or stop.

### Phase 3: Only if the beta earns it

In order: averages across nights, then throughput-based wait predictions, then outside data (weather, football, calendar), then machine learning once it beats simple averages. Other candidates: geofencing, line-drop alerts, cover charge and specials, more bars or towns, App Attest, Android or web.

## 9. App Store requirements

| Item | Value |
| --- | --- |
| App name | LineMap. If taken, use "LineMap: State College"; the home-screen name stays LineMap |
| Bundle ID | `io.github.bigmanmike7.linemapapp`. Permanent after the first upload |
| Contact and feedback email | line.map.support@gmail.com |
| Privacy policy URL | `https://<github-username>.github.io/<repo>/privacy` |
| Support URL | `https://<github-username>.github.io/<repo>/support` |
| Export compliance | Set `ITSAppUsesNonExemptEncryption` = NO in Info.plist. The app uses standard HTTPS only |

**Age rating.** The rating is a store label only; the app has no age check. Answer "Alcohol, tobacco or drug use or references" as **Infrequent**, since LineMap shows bar names and line info, not drinks or drinking. Answer everything else None or No. That includes user-generated content, since reports are taps, not posts. If drink specials are ever added, change the answer to Frequent.

**App privacy labels.** None of these is used for tracking.

| Data type | Purpose | Linked to user |
| --- | --- | --- |
| Precise location (sent with a report, then discarded) | App functionality, analytics | Yes |
| Device ID (anonymous ID) | App functionality | Yes |
| Product interaction (views) | Analytics | Yes |
| Other user content (reports) | App functionality | Yes |
| Other diagnostic data (device model, iOS version) | Analytics | Yes |

**Location permission text (`NSLocationWhenInUseUsageDescription`):** "LineMap checks your location only when you send a report, to confirm you're near the bar. Your exact location is never stored."

**TestFlight beta description:** "LineMap shows live, community-reported lines and waits at State College bars. Tap 'Start line timer' or 'Report line size' to help others, and check before you head out."

**Beta App Review notes:** "No sign-in required. Reports work from anywhere. Bars show 'No live reports' until someone reports. Location is requested only when sending a report."

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| People view but don't report | Friends report on opening nights; watch the first weekends closely |
| Real data only appears on busy weekends | Launch on a busy weekend |
| TestFlight install friction for strangers | Clear install steps on the support page |
| Apple review and real-world GPS | Review notes; field test before launch |
| A wrong or joke report hurts trust | Distinct-people counts, majority rule, admin hide, "This looks wrong" |
| Spam, since the repo is public and there are no accounts | Accepted for the beta: admin hide now, App Attest later if needed |
| Slow test loop without a Mac | Batch changes; rely on CI tests and screenshots |

## 11. Open items

- [ ] Max's GitHub username and repo name, for the privacy and support URLs.
- [ ] Confirm "LineMap" is available when creating the app in App Store Connect.
- [ ] Event-night dates and hours, to be added later.
- [ ] Refine door pins on site if the address pins are off.
