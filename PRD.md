# LineMap Beta — PRD

LineMap is an iPhone beta that shows live, community-reported lines and crowds at three State College bars. It ships on TestFlight to learn whether students will report, and how accurate crowd-sourced estimates can be.

This file is the full product spec. `CLAUDE.md` holds the working rules and points here.

## 1. Summary

- **Problem.** Students heading downtown can't tell whether a bar has a long line or is packed until they walk there. Lines move fast on busy nights, so word of mouth is quickly out of date.
- **Solution.** People at a bar tap **I'm in line** or **Report conditions**. Everyone else sees the current line size, the wait, how busy the bar is, and how fresh that information is. Waits are measured with a simple in-app timer, not guessed.
- **Context.** LineMap is a learning project, not a business. It launches with Doggie's Pub, The Phyrst and Cafe 210 West, and grows to 5–8 bars if reporting keeps up.

## 2. Goals and success metrics

**Goals**

- Ship a polished, working iPhone app to a public TestFlight link.
- Collect clean, comparable data from day one.
- Learn whether students report, whether they come back, and how accurate the estimates are.
- Keep the app simple and modular, so later features are additions, not rewrites.

**Non-goals for the beta**

- Making money, ads, or bar partnerships.
- Averages, history, or predictions. The beta is live-only.
- Accounts, social features, or messaging.
- Android or web.

**Success metrics**, judged at the checkpoint at the end of Phase 2:

| Metric | Target |
| --- | --- |
| Coverage: share of bar × half-hour slots in the active window with a fresh report | 40% |
| Unique reporters per week | 15 |
| Users who come back the following week | 30% |
| Line size and wait within one range of a spot check | 70% |
| Timer completion: wait sessions ending in "I'm in" or "Gave up" | Set after the first two weekends |
| Viewer-to-reporter ratio | Track; no target yet |

## 3. Users and user stories

| User | Who | Main need |
| --- | --- | --- |
| Viewer | A student deciding where to go | Know the line and crowd before walking over |
| Reporter | A student in line or inside a bar | Report in a few taps, one-handed, at night |
| Admin | Max | Manage bars and rules, hide bad reports, analyze the data |

**User stories**

- As a viewer, I can see each bar's line size, wait, busyness, and how fresh that is, so I can pick where to go.
- As a viewer, I'm told plainly when there isn't enough data, so I don't trust a stale number.
- As a reporter in line, I tap once to start a timer and tap again when I get in, so my wait is measured without guessing.
- As a reporter at a bar, I can report the line size and how busy it is on one screen, answering either or both.
- As a reporter, I can skip any question, or cancel a line I started by mistake.
- As any user, I can use the app without an account or giving my age, and delete my data from Settings.
- As the admin, I can add a bar, change a threshold, or hide a report from the dashboard without shipping an app update.

## 4. Scope

| In v1 | Later (Phase 2) | Out of scope for the beta |
| --- | --- | --- |
| Map with bar pins, and bar sheet | Live Activity lock-screen timer | Averages, history, and predictions |
| Report flow with timed waits | Event nights in the active window | Machine learning |
| Live estimates with freshness | More bars (up to 5–8) | Geofencing and passive detection |
| Location check on reports | Threshold tuning from data | Notifications and alerts |
| Anonymous ID, Delete my data | App Attest, if spam appears | Cover charge, specials, partnerships |
| "This looks wrong" feedback | | Android and web |
| Offline report queue | | Accounts and social features |
| Logging, snapshots, admin via dashboard | | |

## 5. Functional requirements

All v1 requirements must be done before launch. Every threshold named here is a server setting in the `config` table, not hard-coded.

### 5.1 Screens

| ID | Requirement |
| --- | --- |
| FR-1 | **Map home screen.** The app opens straight to an Apple Map (MapKit, no API key needed), centered on downtown State College and framing every active bar. Each bar is a pin labeled with its name and line time, e.g. "The Phyrst · 25 min". There is no separate list screen. The map shows the user's location dot only if location permission was already granted. It never asks for permission on launch. |
| FR-2 | **Pin labels.** Line time is the bar's current wait estimate (FR-17 to FR-19): either the last measured wait ("25 min") or a reported range ("15–30 min"). If there's no wait estimate but there is a fresh line size, the label shows the line size ("~10–25 in line"). Otherwise it shows "No data", "Closed", or "Outside hours". Labels based on reports 30–60 minutes old are grayed out. |
| FR-3 | **Bar sheet.** Tapping a pin opens a bottom sheet over the map. It shows: line size now; the wait, matching the pin (a measured wait like "25 min, got in 10 min ago", or a reported range); busyness; freshness as "N people · latest X min ago"; a **This looks wrong** button; and **I'm in line** and **Report conditions** buttons. While the person is in line at that bar, Report conditions is replaced by **I'm in**. No trend arrows in v1. |
| FR-4 | **Wait card.** While a wait session is open, a card floats over the map every time the app opens. It shows the running timer, a large **I'm in**, then **Line size** and **Adjust time**, plus a large ✕ that stops the timer: it asks whether the person gave up (FR-9) or started the line by mistake (FR-39). Tapping the timer opens that bar's sheet. |
| FR-5 | **Settings.** Opened from a small gear button on the map. Contains Delete my data, links to the privacy policy and support page, and the contact email. |

### 5.2 Reporting

| ID | Requirement |
| --- | --- |
| FR-6 | **I'm in line** starts a wait session saved on the server in one tap and asks nothing else. **Line size** on the wait card reports it at any time while waiting: 0, 1–10, 10–25, 25–50, or 50+. ("Can't see the end" was dropped from the app on 2026-10-01; its stored code 5 stays reserved.) |
| FR-7 | **Adjust time** on the wait card asks how long the person was in line before starting the timer: just started, ~5 min, ~10 min, or **More…**, a wheel of every minute from 11 to 90. It moves the session's start time back by that much (0–90 minutes), and can be changed or undone while the session is open. (Before 2026-10-04 the choices were ~5, ~10, and ~20 min; those stored values keep their meaning.) |
| FR-8 | **I'm in** ends the session as entered and asks nothing. Measured wait = end time − adjusted start time. (The busyness question after I'm in was dropped on 2026-10-04.) |
| FR-9 | **Gave up**, chosen from the wait card's ✕, ends the session as gave up. |
| FR-10 | **Unanswered sessions.** After 90 minutes the server marks the session unfinished. A later "I'm in" does nothing. |
| FR-11 | **Report conditions** opens one screen with two optional answers: line size (0, 1–10, 10–25, 25–50, or 50+) and busyness (Quiet, Comfortable, Busy, or Packed, relative to the bar's size). **Send report** stays off until at least one is picked, and the report is sent once. It works whether the person is in line, inside, or nearby, so its position is stored as unspecified. It never touches a wait session. (It replaced **I'm inside** on 2026-10-04. The app no longer asks how long it took to get in; the recalled-wait codes stay reserved.) |
| FR-12 | **Answers.** Every question is optional and can be skipped; a skip is stored. Line size and Adjust time are saved as soon as they're given; Report conditions is saved when sent. ("I can't tell" was dropped from the app on 2026-10-01; the stored `cant_tell` state stays reserved.) |
| FR-13 | **Rate limit.** One report per bar every 10 minutes per person, enforced on the server. Report conditions counts as a report. Exceptions: line-size updates in an open session, I'm in, Gave up, and the busyness answer after I'm in (sent only by builds before 2026-10-04). |
| FR-14 | **One line at a time.** Starting a line at another bar closes the open session as gave up. |
| FR-15 | **I'm inside with an open session** at that bar counts as I'm in. The app no longer has I'm inside (2026-10-04); the server keeps this rule for older builds. |
| FR-39 | **Cancel line.** "Started it by mistake", chosen from the wait card's ✕, discards the line: the server deletes the session and its reports, so nothing from it counts, including toward the rate limit. A finished wait can't be cancelled. |
| FR-16 | **Offline queue.** Reports and session events queue on the phone when offline and retry with a client-generated ID, so nothing is saved twice. The queue survives app restarts. Late reports are always stored, but count toward live estimates only if their phone time is within the freshness window. |

### 5.3 Estimates (computed on the server)

| ID | Requirement |
| --- | --- |
| FR-17 | **Freshness.** A report is fresh for 30 minutes. From 30 to 60 minutes it shows as older and grayed out. After 60 minutes the bar shows "Not enough data". Measured waits age from when the person got in. |
| FR-18 | **People count.** Freshness counts distinct people, so one person reporting twice counts once. |
| FR-19 | **Shown value.** For each signal separately (line size, wait, busyness), the newest report wins. The exception: if it disagrees with 2 or more fresh reports from other people, the majority wins. "Agree" means within one range. |
| FR-20 | **Uncertain reports** count like any other in v1. |
| FR-21 | **Server logic.** Estimates are computed by SQL functions on the server. Each response carries a logic version. |

### 5.4 Active window

| Time (Eastern) | What bars show |
| --- | --- |
| Thu–Sat, 9 p.m.–2 a.m. | Live estimates, or "Not enough data" |
| 2–4 a.m. after an active night | "Closed" |
| Any other time | "Outside usual hours, no recent reports", unless a fresh report exists |

| ID | Requirement |
| --- | --- |
| FR-22 | **Night boundary.** A night runs until 4 a.m. Eastern, so 1 a.m. Sunday belongs to Saturday night. Each report stores its night date, set on the server. Daylight-saving changes are handled. |
| FR-23 | **Event nights.** A server table can extend or override the window for specific dates. It starts empty. |

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
| FR-32 | **Delete my data** permanently deletes the anonymous ID's reports, wait sessions, views, install rows, and feedback. It records a deletion count with no ID, then creates a new anonymous ID. |
| FR-33 | **Retention.** A daily job deletes data tied to an anonymous ID once it's 1 year old. Estimate snapshots have no IDs and are kept. |

### 5.7 Logging and admin

| ID | Requirement |
| --- | --- |
| FR-34 | **Views.** Every view of the map or a bar sheet is logged with the anonymous ID, the estimate shown, the logic version, whether it showed "no data", and an app-open ID. No location. |
| FR-35 | **Feedback.** "This looks wrong" saves the bar, the estimate shown, and the time. |
| FR-36 | **Snapshots.** Every 5 minutes during the active window, the server saves what each bar would show. |
| FR-37 | **Admin via the Supabase dashboard.** Add or edit bars; change settings, with every change logged in `config_history`; hide a report with a reason; log spot checks; add event nights. |
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
| NFR-10 | Data stability | Answer ranges are stored as fixed codes. Every report records the app version and definitions version. |

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

**Functions the app calls.** These are the only way the app reaches the database: get bars, get estimates, report conditions, start session, update line size, end session, cancel session, send feedback, register install, log view, delete my data. `submit_report` (I'm inside) stays on the server for builds before 2026-10-04, but the app no longer calls it.

**Scheduled jobs**

- **Every 5 minutes:** mark sessions older than 90 minutes as unfinished.
- **Every 5 minutes during the active window:** save estimate snapshots.
- **Daily:** delete ID-linked data older than 1 year.
- **Daily (GitHub Action):** call the database so the project doesn't pause.

### 7.3 Data model

Every table also has `id`, `created_at`, and `is_test`. Weather and football data aren't stored; they can be filled in later from historical sources.

| Table | What it holds | Key fields |
| --- | --- | --- |
| `bars` | The bar list | name, address, door coordinates, size class, active, display order, date added |
| `installs` | One row per install | anon ID, install ID, first and last seen, app version, iOS version, device model |
| `reports` | Every report | client report ID, anon ID, install ID, bar, night date, position (line, inside, or unspecified for Report conditions), kind, wait session ID, line size, busyness, and recalled wait (each with an answer state: answered, can't tell, skipped), phone time, server time, location status, distance, direction, accuracy, fix age, uncertain, hidden and hidden reason, app version, definitions version, source (app now, Live Activity later) |
| `wait_sessions` | One timed wait | client ID, anon ID, bar, night date, start time, Adjust time offset (0–90 min), end time, status (open, entered, gave up, unfinished), what ended it, distance at start and at end |
| `views` | Every view of the map or a bar sheet | anon ID, install ID, map or bar, time, estimate shown, logic version, whether it showed "no data", app-open ID |
| `feedback` | "This looks wrong" taps | anon ID, bar, estimate shown, time |
| `config`, `config_history` | Current settings, and every change to them | key, value, changed at |
| `event_nights` | Special nights (empty at launch) | date, label, type, window override |
| `estimate_snapshots` | What each bar showed, every 5 minutes | bar, time, full estimate, logic version |
| `spot_checks` | Admin ground truth | bar, time, line count seen, wait timed, notes |
| `deletions` | A count of data deletions | time, rows removed (no ID) |

**Starting bars.** Pins are geocoded from these addresses and can be adjusted later in the dashboard.

| Bar | Address |
| --- | --- |
| Doggie's Pub | 108 S Pugh St, State College, PA 16801 |
| The Phyrst | 111 E Beaver Ave, State College, PA 16801 (downstairs, below Local Whiskey) |
| Cafe 210 West | 210 W College Ave, State College, PA 16801 |

## 8. Release plan

Build in order, and test each milestone before starting the next.

### Phase 1: Build the beta

| Milestone | Includes | Done when |
| --- | --- | --- |
| M1. Setup | Repo, XcodeGen project, LineMapCore package, CI pipeline | An empty app builds in CI and installs on Max's iPhone through TestFlight |
| M2. Backend | All tables, row-level security, functions, scheduled jobs, the three starting bars | Database tests pass; a bar and a setting can be changed from the dashboard |
| M3. App | Screens, report flow, wait card, location, IDs, offline queue, feedback, Settings | The full flow works end to end on a phone |
| M4. Polish | Dark mode, accessibility, empty and error states, privacy policy and support pages on GitHub Pages, App Store Connect filled in | Every screen has been reviewed in CI screenshots and on the phone |
| M5. Field test | Downtown on a quiet night and a busy one: location (allow, deny, approximate), offline queue, timers | No blocking bugs; Beta App Review submitted |
| M6. Launch | Public TestFlight link; 5–10 friends report on opening nights; recruit students | The first busy weekend is live |

### Phase 2: Collect and analyze

- Each active night, watch reports, finished timers, views, and "no data" views. Hide bad reports.
- Do spot checks: count a line, time a wait, and compare with the snapshot from that moment.
- Review weekly: coverage, unique reporters, return visits, timer completion, deletions, and reinstalls.
- Tune freshness, agreement rules, and the active window from the server. Add event nights once dates are known.
- Ship the Live Activity, a lock-screen version of the same wait session. It needs no push server.
- Add bars only when the current ones stay fresh for most of the active window.
- At the checkpoint, compare against the success metrics and decide whether to continue, change direction, or stop.

### Phase 3: Only if the beta earns it

In order: averages and history, then throughput-based wait predictions, then outside data (weather, football, calendar), then machine learning once it beats simple averages. Other candidates: geofencing, line-drop alerts, cover charge and specials, more bars or towns, App Attest, Android or web.

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

**TestFlight beta description:** "LineMap shows live, community-reported lines and crowds at State College bars. Tap 'I'm in line' or 'Report conditions' to help others, and check before you head out."

**Beta App Review notes:** "No sign-in required. Reports work from anywhere. Outside bar hours (Thu–Sat 9 p.m.–2 a.m. Eastern), bars show 'Outside usual hours' until someone reports. Location is requested only when sending a report."

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| People view but don't report | Friends report on opening nights; watch the first weekends closely |
| Real data only appears on busy weekends | Launch on a busy weekend; add event nights later |
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
