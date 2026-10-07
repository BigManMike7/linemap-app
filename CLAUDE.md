# LineMap

An iPhone beta that shows live, community-reported lines and waits at State College bars. People at a bar tap "Start line timer" or "Report line size", and everyone else sees each bar's line and wait on a map. This is a learning project: keep it simple, polished, and modular.

**The full spec is `PRD.md`.** Read it before starting any milestone. Requirement IDs (FR-x, NFR-x) refer to it. If the PRD and the code disagree, or the PRD is unclear, ask Max. Don't guess.

## How to work

- **One milestone at a time.** Build the current milestone (see Status), then stop so Max can test. Don't start the next milestone until he says to.
- **Simplest thing that works.** Ask before adding a dependency, an account system, a new screen, or anything not in the PRD.
- **Keep it modular.** The Live Activity, more bars, and outside data will be added later, so they must fit without rewrites.
- **Explain data model changes.** Explain any change to tables, fields, or answer codes before making it. Answer ranges are fixed codes and must never change meaning.
- **Small commits.** Use clear messages that reference requirement IDs where relevant.
- **Update Status** at the bottom of this file when a milestone is done.

## Subagents

Use subagents, and pick the model by the kind of work:

- **Sonnet 5.5 (`model: "sonnet"`) for repetitive tasks.** Examples: boilerplate, renaming across files, writing similar test cases, file sweeps, log trawls, and formatting docs.
- **Opus 5.5 (`model: "opus"`) for complex logic.** Examples: SQL estimate and night-boundary functions, RLS and the security model, session and rate-limit rules, the offline queue, CI and signing failures, and architecture decisions.
- If you're unsure, use Opus. Review a subagent's output before committing it.

## Environment: there is no Mac

- Max develops without a Mac, so you can't run `xcodebuild`, the simulator, or SwiftUI previews locally.
- **All iOS builds and tests run in GitHub Actions on macOS runners.** Push, then check results with `gh run list`, `gh run watch`, and `gh run view --log-failed`.
- **Batch changes.** Each CI round trip plus TestFlight install takes 20–40 minutes, so get as much right per push as you can.
- **Seeing the UI.** A UI test takes a screenshot of every screen on a simulator and uploads them as build artifacts. Use those, plus Max's phone, to check what the app looks like.
- **Database work** (SQL, pgTAP tests) runs in CI on a free Linux runner using the Supabase CLI. If Docker is available locally, it can also run locally.
- **The repo is public.** Never commit secrets. Use GitHub Secrets for: App Store Connect API key (key ID, issuer ID, `.p8` contents), Apple team ID, Supabase access token, and database password. The Supabase URL and anon key are public by design and may live in app config.

## Stack

| Part | Choice |
| --- | --- |
| App | SwiftUI, iPhone only, iOS 17+, MapKit for the map (no API key) |
| Project file | XcodeGen: edit `project.yml`, never hand-edit `.xcodeproj` |
| App logic | Swift package `LineMapCore`: models, answer codes, pin labels, wait timer, offline queue. Unit-tested |
| Backend | Supabase (US East): Postgres, SQL functions, `pg_cron` jobs, row-level security |
| Server logic | Estimates and the night boundary are SQL functions, tested with pgTAP. The server is the source of truth |
| CI/CD | GitHub Actions + fastlane, App Store Connect API key, upload to TestFlight |
| Signing | Prefer automatic, cloud-managed signing with the API key. If that fails, propose fastlane match and ask before setting it up |

## Skills

Load the matching skill before writing code in that area.

| Work | Skill |
| --- | --- |
| Tables, RLS, SQL functions, `pg_cron`, pgTAP | `supabase-postgres-best-practices`, plus `supabase` for CLI and platform questions |
| Swift in `LineMapCore` or the app | `write-swift`; `swift-core-skills:swift-testing` for tests |
| SwiftUI views and sheets | `swiftui-skills:swiftui-patterns`, `swiftui-skills:swiftui-navigation` |
| Map, pins, location | `ios-app-framework-skills:mapkit` |
| Keychain IDs | `ios-engineering-skills:swift-security` |
| M4 accessibility, M5 Beta App Review | `ios-engineering-skills:ios-accessibility`, `ios-engineering-skills:app-store-review` |
| Live Activity (Phase 2) | `ios-app-framework-skills:activitykit` |

Where the `supabase` skill's generic advice doesn't fit this project:

- **No Supabase MCP and no local database by default.** Write migrations as files in `supabase/migrations/` (create them with `supabase migration new`) and verify them with pgTAP in CI. Don't use `db pull` or `execute_sql` unless Docker is running locally.
- **No Supabase Auth.** The app uses the `anon` role with no user, so `auth.uid()` policy patterns don't apply. Identity is the anonymous ID passed to the PRD 7.2 functions. Confirm the function security model (definer vs. invoker, grants, `search_path`) with Max in M2.

## Repo layout (target)

```
CLAUDE.md
PRD.md
docs/                      # privacy.md, support.md, index.md (GitHub Pages)
project.yml                # XcodeGen
App/                       # SwiftUI app target: views, MapKit, location, Keychain
Packages/LineMapCore/      # pure Swift logic + tests
supabase/migrations/       # tables, RLS, functions, cron jobs (SQL)
supabase/tests/            # pgTAP tests
supabase/migrations/*_starting_data.sql  # default config + the three original bars
supabase/migrations/*_bar_list.sql       # the six launch bars (the Phyrst inactive)
fastlane/
.github/workflows/         # ci.yml (tests + screenshots), testflight.yml, keepalive.yml
```

## Rules that are easy to get wrong

These are summaries. The PRD has the details.

**Security and privacy**

- **No direct table access.** The app never reads or writes tables directly. Row-level security denies everything, and the app only calls the SQL functions listed in PRD 7.2. The service key never goes in the app or the repo.
- **No stored coordinates.** The server computes distance, direction, accuracy, and fix age, then discards the coordinates (FR-26).
- **No barriers to use.** No accounts, sign-in, or age question (FR-31). No third-party analytics or tracking SDKs (NFR-6).

**Identity**

- **Anonymous ID** lives in the Keychain, device-only, not synced, so it survives reinstalling (FR-29).
- **Install ID** lives in regular app storage and is new on every install (FR-30).
- **Delete my data** deletes everything tied to the anonymous ID and logs a count with no ID (FR-32). Since 2026-10-07 it is not in the app: people email support with their ID, and Max runs `public.delete_my_data` in the SQL Editor within 30 days. The phone keeps its ID. Older builds still have the button, which also made a new ID.
- **Made a wrong report?** in Settings deletes one report or finished wait from the last 24 hours, for real. Its rate limit keeps running through a short-lived hold (anon ID, bar, kind, time only), and the deletion logs a count with no ID (FR-41).

**Time**

- **Time zone.** All rules use America/New_York.
- **Night boundary.** A night runs until 4 a.m. Eastern, and `night_date` is set on the server (FR-22). Test daylight-saving changes.

**Location**

- **Permission.** Ask only on the first report, never on launch. The map shows the user's location dot only if permission was already granted (FR-1, FR-24).
- **Never reject for location.** Bad or missing location only sets the `uncertain` flag (FR-27).

**Reporting**

- **Rate limit.** Two separate 10-minute limits per person per bar, enforced on the server: timed lines (Start line timer) and manual reports (Report line size, called Report conditions before 2026-10-06). Neither blocks the other. Not limited: line-size updates in an open session (each its own row), I'm in, and Gave up (FR-13). Redo (FR-46) lets a person replace their own last attempt within `redo_minutes` (5); a replaced timer is deleted only when the new one finishes. Undo (FR-47) reopens a timer stopped by I'm in or Gave up.
- **Sessions.** Only one open wait session at a time (FR-14). Report line size never touches a session; the server's I'm inside rule (FR-15) remains only for older builds. Sessions become unfinished after 90 minutes (FR-10). Adjust time moves the start back 0–90 minutes (FR-7).
- **Answers.** Every answer can be skipped (FR-12). Line size and Adjust time send when Save is tapped (swiping away skips); Report line size sends once. Line sizes are No line, 1–10, 10–25, 25–50, 50–100, 100+ (codes 0, 1, 2, 3, 6, 7); compare them by size rank, never raw code. The app no longer offers 50+ (code 4), "I can't tell", "Can't see the end" (5), the recalled-wait question, or the crowd (busyness 1–4, removed 2026-10-06), but their stored codes stay reserved and never change meaning.
- **Offline queue.** Every report and session event has a client-generated ID, so retries never duplicate. The queue survives restarts (FR-16).

**Estimates**

- **Freshness.** Fresh up to 30 minutes, grayed out from 30 to 60, then "No live reports" (FR-17), at any hour: there is no active window (logic version 3).
- **Counting.** Count distinct people, not reports (FR-18). The newest report wins unless 2 or more fresh reports from other people disagree; then the majority wins (FR-19).
- **Thresholds** live in the `config` table, not in code. Log every change to `config_history`.
- **History (M4)** is computed from reports as of each past moment, never from snapshots, so deleted and hidden reports never show. Only combined estimates, never individual reports (FR-43).

**Data hygiene**

- **Test rows.** Every row has `is_test`. Mark data from Max's own testing as test data.

## Fixed values

- App name: LineMap. Bundle ID: `io.github.bigmanmike7.linemapapp`.
- Contact email: line.map.support@gmail.com
- Location permission text: "LineMap checks your location only when you send a report, to confirm you're near the bar. Your exact location is never stored."
- Info.plist: `ITSAppUsesNonExemptEncryption` = NO.
- Bars at launch, in display order (Max, 2026-10-06; pins geocoded with OpenStreetMap; full names since 2026-10-07, before Pmans and The Gaff):
  - Primanti Bros., 130 Heister St
  - Doggie's Pub, 108 S Pugh St
  - Brothers Bar & Grill, 134 S Allen St
  - Champs Downtown, 139 S Allen St
  - Cafe 210 West, 210 W College Ave
  - The Shandygaff, 212 E College Ave (rear)
  - All are in State College, PA 16801. The Phyrst (111 E Beaver Ave) stays in the data, inactive.

## Max checks these himself

The data model before launch, the database tests, location on a real phone, that Delete my data removes rows, and the privacy policy. Point these out when they're ready for review.

- [x] Data model (approved 2026-10-01, as built in M2). Point out any later change to tables, fields, or answer codes again.
- [x] Database tests (approved 2026-10-01, 493 pgTAP tests).
- [ ] Location on a real phone (M3/M5)
- [x] Delete my data removes rows (checked 2026-10-05 with the Data check workflow: 0 rows left for the deleted ID).
- [ ] Privacy policy (M4). Draft in `docs/privacy.md` (covers Made a wrong report?, Undo and Redo, and history). Waiting for Max; GitHub Pages stays off until he approves it.
- [x] M4 data model change: the setting `redo_minutes` (5). No table, field, or answer-code change (approved 2026-10-05).
- [x] M4 data model changes (approved 2026-10-06): no active window (settings `active_nights`, `active_window_start`, `active_window_end` removed; `event_nights` kept unused), line sizes 6 and 7 (`reports.line_size` 0–7, definitions version 2), the crowd dropped (column kept, codes reserved), all data wiped, six bars. Logic version 4.

## Status

- [x] **M1. Setup:** repo, XcodeGen project, LineMapCore package, CI pipeline. Done when an empty app builds in CI and installs on Max's iPhone through TestFlight.
- [x] **M2. Backend:** tables, RLS, functions, cron jobs, seed bars, pgTAP tests.
- [x] **M3. App:** map, bar sheet, report flow, wait card, location, IDs, offline queue, feedback, Settings, Directions (FR-40), Made a wrong report? (FR-41), thank-you (FR-42).
- [ ] **M4. Polish:** tab bar (FR-44), Bars list (FR-45), History (FR-43), Redo and Undo (FR-46, FR-47), dark mode, accessibility, empty and error states, GitHub Pages docs, App Store Connect.
- [ ] **M5. Field test:** downtown testing, then Beta App Review.
- [ ] **M6. Launch:** public TestFlight link.

**Current milestone: M4** (in progress).

## Where we left off (2026-10-07)

**Build 23 is on TestFlight (uploaded 2026-10-07).** CI is green and `main` is clean. Next: Max tries build 23. If he hasn't yet, he adds his test ID: Settings, Copy ID, then in the Supabase SQL Editor: `update app.config set value = value || jsonb_build_array('<ID>') where key = 'test_anon_ids';` Don't commit his ID.

**New in build 23:** History calendar dots (accent purple) under days with reports; Settings has Time in lines first with no description, then Made a wrong report?; Apple's places on the map when zoomed in about twice as close as the opening view (`Downtown.placesBelowSpan`, 0.0065° of longitude), excluding nightlife, breweries, and wineries; not tappable. Max should say whether that zoom level feels right.

**What to try on build 22:** Primanti Bros. and The Shandygaff by their full names; Line size: a different size sends with "Thanks! 10–25 in line is now visible…", the same size within 5 minutes says "No change. Let the wheel stop, then tap Save." (no check mark), the same size after 5 minutes sends; Settings: Time in lines (total, lines, longest), no Delete my data, and the email note under the ID; History: "No reports this day." and "No reports today yet."

**Decisions made 2026-10-07** (all in PRD.md):

- **Wheels stay Apple's SwiftUI wheel** (Max): no custom or UIKit wheel, no graying Save. It picks only once it stops, so the app can't see a mid-spin Save. Line size: a different size always sends; the same size sends only 5+ minutes after the last send (each send restarts the 5 minutes; `LineSizeSave` in LineMapCore), otherwise No change. Adjust time: an unchanged time says No change. The Line size thank-you names the size.
- **Full bar names** (migration `*_full_bar_names.sql`, data only): Pmans is Primanti Bros., The Gaff is The Shandygaff.
- **Delete my data left the app** (FR-32): people email support with their ID; Max runs `select public.delete_my_data('<ID>');` in the SQL Editor within 30 days and replies. The phone keeps its ID. The function stays for this and for older builds. Privacy policy and support page updated (still waiting for Max's review).
- **History calendar** (FR-43): Apple's UICalendarView with its own decorations (SwiftUI's DatePicker can't mark dates); dots come from `bar_history`'s `nights`, no server change.
- **Live Activity** stays Phase 2 (Max). Suggested to Max, not yet decided: auto-start with the timer, show the bar name and timer, an I'm in button only. A widget extension target means new signing work.
- **Time in lines** (FR-48): new read-only function `my_wait_stats` (security definer, anon only; no table change; Max approved the design). It counts I'm in and Gave up waits with Adjust time, skips open, unfinished, and a timer replaced by a redo that a line elsewhere closed. The app still calls 15 functions (`delete_my_data` out, `my_wait_stats` in). No index on `wait_sessions(anon_id)` yet; add one if it ever gets slow.

**Decisions made 2026-10-06** (all in PRD.md):

- **No active window** (logic version 3, PR #1): reports show at any hour; no "Closed"; snapshots every 5 minutes at any hour for bars with a report in the last hour; History covers 4 a.m. to 4 a.m., each row only its own quarter hour; coverage target dropped; `event_nights` kept, unused.
- **Line sizes and no crowd** (logic version 4, PR #2): new codes 6 (50–100) and 7 (100+); 50+ (4) no longer offered; size rank (`app.line_size_rank`, `LineSize.rank`) for comparisons; definitions version 2 (server accepts 1 and 2). The crowd is gone from the app and estimates; the server accepts older builds' crowd answers but never stores them. Report conditions is now **Report line size**.
- **Fresh start:** all data deleted on merge (Max's own testing). Bars: see Fixed values.
- **Reports show at any hour** (logic version 2): "No live reports" replaced No data, Not enough data, and Outside usual hours.
- **Pins** have two-line labels (name over status). Overlap at the opening zoom is accepted.
- **History:** no graying, no night heading. **Adjust time:** Save gives a haptic only; an unchanged time says "No change. Let the wheel stop, then tap Save." **Copy ID** shows "✓ Copied".
- **UI tests:** `tapDialogButton` retries dropped dialog taps; a failed test saves a `FAILED` screenshot.

**Open items:**

1. **Local database tests:** Max may install Docker Desktop (BIOS virtualization was off on his HP desktop: enable SVM, `wsl --install --no-distribution`, `winget install -e --id Docker.DockerDesktop`); the Supabase CLI runs through `npx supabase`.
2. The data-check workflow prints an old deleted anonymous ID in its job env (`DELETED_ANON_ID`); it's dead, but could move to an input.

**Ideas raised but not built** (Max hasn't asked for them):

- The History dots stay 10 pt at the largest text sizes; they could grow with the text.
- Very short timers (under a minute) could count as started by mistake on the server.
- A custom Adjust time wheel that saves whatever is under the center line even mid-spin (Max declined for now).
- Collision handling for pins (Apple's own markers, or labels only when zoomed in); Max declined for now.

**Things to know:**

- Builds up to 20 ask the crowd and offer 50+ (definitions version 1); the server still accepts them and drops the crowd. Builds up to 18 call it "Not enough data" where later builds say "No live reports". Builds 15–17 show History as half-hour rows from 4 a.m., since the server now sends the whole day. Only Max has them.
- On the fall-back night (Nov 1), 1:00–1:45 a.m. happen twice, so History shows those rows twice, each at its real time.
- CI often fails with "The job was not acquired by Runner" or an artifact-upload timeout. Those are GitHub capacity problems, not test failures: rerun with `gh run rerun <id> --failed`. When a UI test really fails, the "Show test failures" step prints why.

**M4 is mostly built.** Done and passing CI:

- Tab bar (FR-44), Bars list (FR-45), History (FR-43), Undo (FR-47), Redo on the server (FR-46), and line-level colors (FR-2).
- Server: migration `20261005200000_redo_undo_history.sql` adds `redo_minutes`, `reopen_session`, and `bar_history`. It is deployed. Built by an Opus subagent on branch `m4-sql`, reviewed, and merged. Migration `20261005220000_history_full_day.sql` (deployed) makes `bar_history` cover 4 a.m. to 4 a.m. every 15 minutes. pgTAP: 1077 tests after the 2026-10-06 changes (logic version 4, six bars).
- The app now calls 15 functions (`submit_report` stays for older builds only).
- Screenshots: the main walkthrough (20 screens, dark mode) and a light-mode walkthrough at a large accessibility text size (`L01`–`L08`).
- Docs drafted in `docs/` (privacy, support, index). Pages is not enabled.

Still to do in M4:

1. **Max reviews:** the privacy policy draft (updated 2026-10-06: no crowd, Report line size), and the new screens on the phone (build 21, the latest).
2. **After the privacy policy is approved:** enable GitHub Pages from `/docs` on main (`gh api -X POST repos/BigManMike7/linemap-app/pages -f "source[branch]=main" -f "source[path]=/docs"`), then check that the Settings links open.
3. **Review the light-mode and large-text screenshots** for anything clipped or unreadable, and fix it. Reviewed through build 21 (Bars cards, History rows, two-line map pins, Report line size); recheck after any layout change.
4. **App Store Connect:** privacy labels, age rating, beta description, and Beta App Review notes, as in PRD section 9. Max fills these in on the web.
5. **Test ID (done by the 2026-10-06 wipe, except adding Max's ID; see Where we left off).** The old note: Each Delete my data gives a new anonymous ID, so for now `test_anon_ids` stays empty and Max's rows are stored as real. Before anyone other than Max uses the app (the M5 field test with other people, or M6 at the latest), run one cleanup in the SQL Editor: mark every row so far as test (or delete it), then add Max's then-current ID:
   ```sql
   -- for each of app.installs, app.wait_sessions, app.reports, app.views, app.feedback:
   update app.reports set is_test = true where not is_test;
   update app.config set value = value || jsonb_build_array('<ID>') where key = 'test_anon_ids';
   ```
   After that, a Delete my data on his phone means adding the new ID again. Don't commit his ID to this public repo: anyone with it can call the functions as him.

**Judgment calls in the server work** (from the subagent's report; point them out to Max if they matter):

- Undo's 5 minutes count by server time, so an Undo sent late from the offline queue gets `too_late` and the app says "Couldn't undo".
- A timer closed by starting a line at another bar (FR-14) can be redone but not undone. Undo only reverses an I'm in or Gave up tap.
- Redo from a deleted wait's rate-limit hold uses the wait's start time, since holds don't store an end time.
- I'm inside from older builds is never redone.

**UI test notes:** MapKit sometimes exposes the pins as its own map features on a second app launch, so the light-mode walkthrough opens bars from the Bars tab. Bars-list cards zoom the map to a 0.007° span so nearby bars stay visible.

**Decisions made 2026-10-05** (already in PRD.md):

- **Line-level colors** (FR-2, FR-3, FR-43, FR-45): pins, Bars cards, the bar sheet, and History rows are green, orange, or red by the wait or line size the pin shows (under 10 min or 0–10 in line; 10–25; 25+). The crowd never counts. Older reports show outlined or faded. A wait and line size that contradict (one short, one long, such as a 0-minute timer next to 50+ in line) show **Uncertain**: a gray question mark, and the bar sheet shows both values (Max's call, 2026-10-05). Cutoffs live in `LineMapCore/LineLevel.swift`, not `config`. Each level also has its own symbol. The accent color changed from amber to indigo so it doesn't clash with orange.
- **History** (FR-43), revised again: Right now is gone (the bar sheet and Bars card show it), so the button and page are just History. It covers the night's whole day, 4 a.m. to 4 a.m., with a server point every 15 minutes, for early football crowds. Rows are quarter hours from 9:00 p.m. to 1:45 a.m., stretched to cover any quarter hour with reports; two or more empty quarter hours in a row collapse into one "No reports, 3:15 PM – 8:45 PM" row. `bar_history` keeps its fields; only its points change (no table, field, or answer-code change).

- **Tab bar** (FR-44): Map, Bars, Settings, icons with short labels. Opens on Map after a full close; going to the home screen and back resumes where the person left. The Settings gear and sheet go away (FR-5).
- **Bars list** (FR-45): simple cards, fresh before stale, shortest wait first, then line size only, then no data in `display_order`. Tapping a card switches to Map and opens that bar's sheet. No report buttons on cards.
- **Wait card** shows on Map and Bars above the tab bar, hidden on Settings (FR-4).
- **History & details** (FR-43, superseded by the History bullet above): a full-screen page from a **History & details button on each Bars card** (not the bar sheet), with Right now in full, then Apple's standard calendar (tonight back one year) and the chosen night as a "Busiest around" line plus one row per half hour, 9:00 p.m. to 1:30 a.m. No charts. Combined estimates only, never individual reports (Max confirmed).
- **Does this look wrong?** (FR-35): the bar sheet's "This looks wrong" became a question with a confirmation ("Yes, it looks wrong" or Cancel), so a stray tap sends nothing.
- **Redo** (FR-46) and **Undo** (FR-47): see the Reporting rules above. Undo is a button on the I'm in and Gave up messages for about 5 seconds; Gave up now shows "Timer stopped." (FR-42).
- **Data model check for Max:** no table, field, or answer-code change. New: the config setting `redo_minutes` (5), and two functions the app calls, `bar_history` and `reopen_session`, which bring the app to 15 functions. `start_session`, `end_session`, and `report_conditions` change their rate-limit rules. Point these out again when building.

**Decisions made 2026-10-04** (already in PRD.md):

- "I'm inside" became **Report conditions**: line size and crowd on one screen, both optional, sent once, position `unspecified`, kind `conditions` (FR-11). The recalled-wait question is gone; its codes stay reserved.
- I'm in asks nothing (FR-8). Adjust time is 0–90 minutes (FR-7). The Gave up button is gone; the ✕ asks gave up or started by mistake (FR-4, FR-9, FR-39).
- New: Directions (FR-40), Made a wrong report? with real delete and a 10-minute rate-limit hold (FR-41), thank-you message (FR-42). History of any past night is planned for M4 and is computed from reports, never snapshots (FR-43).
- The app calls 13 functions now; `submit_report` stays on the server for older builds only.
- Max approved the new tables and fields (`conditions` kind, `unspecified` position, 0–90 offset, `rate_limit_holds` with its `kind`, `deletions.scope`) on 2026-10-04.
- Two rate limits, timed and manual, instead of one (FR-13). Line size now asks "How many people are in line?" everywhere with no subtitle; older in-line answers counted people ahead. The change is noted in `supabase/README.md`, and the definitions version stays 1.

**Reversible change in testing (2026-10-04): map pins use MapKit selection.** Commit `366980e` replaced the pin Buttons with `Map(selection:)` plus `.tag(bar.id)` so a pinch that starts on a label still zooms. It touches only `App/MapScreen.swift` and `UITests/ScreenshotTests.swift`. If pins misbehave on the phone (taps not opening, pins stuck selected, VoiceOver not opening a bar), undo it with `git revert 366980e`. No database or PRD change.

**Handy facts**

- Ship a build: `gh workflow run testflight.yml`. CI deploys passing migrations to Supabase automatically.
- Supabase project ref `jjsccwmvgfzsxozhjlrt`. There is no local database access: the password lives only in GitHub Secrets, so Max runs one-off SQL in the dashboard SQL Editor.
- **Data check:** `gh workflow run data-check.yml` runs a read-only, counts-only check of the live database (rows left for a deleted ID, recent deletions, test and real rows per day). Its logs are public, so it never prints IDs.
- The privacy and support links in Settings point at GitHub Pages pages that M4 still has to write. The privacy policy must cover Made a wrong report? and history.
