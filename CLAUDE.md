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

- **Permission.** Ask only on the first report or a tap on Settings' Location row, never on launch. The map shows the user's location dot only if permission was already granted (FR-1, FR-24).
- **Never reject for location.** Bad or missing location only sets the `uncertain` flag (FR-27).

**Reporting**

- **Rate limit.** Two separate 10-minute limits per person per bar, enforced on the server: timed lines (Start line timer) and manual reports (Report line size, called Report conditions before 2026-10-06). Neither blocks the other. Not limited: line-size updates in an open session (each its own row), I'm in, and Gave up (FR-13). Redo (FR-46) lets a person replace their own last attempt within `redo_minutes` (5); a replaced timer is deleted only when the new one finishes. Undo (FR-47) reopens a timer stopped by I'm in or Gave up.
- **Sessions.** Only one open wait session at a time (FR-14). Report line size never touches a session; the server's I'm inside rule (FR-15) remains only for older builds. Sessions become unfinished after 90 minutes (FR-10). Adjust time moves the start back 0–90 minutes (FR-7).
- **Answers.** Every answer can be skipped (FR-12). Line size and Adjust time send when Save is tapped (swiping away skips); both use Apple's SwiftUI wheel, which picks only once it stops, so an unmoved wheel says No change (Line size: unless the last send was 5+ minutes ago, FR-6). Report line size sends once. Line sizes are No line, 1–10, 10–25, 25–50, 50–100, 100+ (codes 0, 1, 2, 3, 6, 7); compare them by size rank, never raw code. The app no longer offers 50+ (code 4), "I can't tell", "Can't see the end" (5), the recalled-wait question, or the crowd (busyness 1–4, removed 2026-10-06), but their stored codes stay reserved and never change meaning.
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
- [x] Privacy policy (M4, `docs/privacy.md`). Max asked Claude to check and publish it on 2026-10-08; GitHub Pages serves `/docs` from main.
- [x] M4 data model change: the setting `redo_minutes` (5). No table, field, or answer-code change (approved 2026-10-05).
- [x] M4 data model change (2026-10-07): one new read-only function, `my_wait_stats` (Time in lines, FR-48), and the full bar names (data only). No table, field, or answer-code change. Reviewed by Claude at Max's request on 2026-10-08: anon-only grant, `search_path` empty, reads only the caller's own waits, 37 pgTAP tests.
- [x] M4 data model changes (approved 2026-10-06): no active window (settings `active_nights`, `active_window_start`, `active_window_end` removed; `event_nights` kept unused), line sizes 6 and 7 (`reports.line_size` 0–7, definitions version 2), the crowd dropped (column kept, codes reserved), all data wiped, six bars. Logic version 4.

## Status

- [x] **M1. Setup:** repo, XcodeGen project, LineMapCore package, CI pipeline. Done when an empty app builds in CI and installs on Max's iPhone through TestFlight.
- [x] **M2. Backend:** tables, RLS, functions, cron jobs, seed bars, pgTAP tests.
- [x] **M3. App:** map, bar sheet, report flow, wait card, location, IDs, offline queue, feedback, Settings, Directions (FR-40), Made a wrong report? (FR-41), thank-you (FR-42).
- [ ] **M4. Polish:** tab bar (FR-44), Bars list (FR-45), History (FR-43), Redo and Undo (FR-46, FR-47), Time in lines (FR-48), dark mode, accessibility, empty and error states, GitHub Pages docs, App Store Connect.
- [ ] **M5. Field test:** downtown testing, then Beta App Review.
- [ ] **M6. Launch:** public TestFlight link.

**Current milestone: M4** (in progress).

## Where we left off (2026-10-08)

**Build 25 is on TestFlight; Max has checked everything through build 24** (the map places' zoom is good). CI is green and `main` is clean. All decisions are in PRD.md; this section only says what's next and what PRD.md doesn't.

**New in build 25:** 25–50 in line is some line (orange); a Bars card zooms in to about two blocks across (span 0.0025, was 0.007); Apple's my-location button on the map once permission is granted (with the compass and scale bar listed, since listing controls replaces the defaults); History's dot-color key, the Made a wrong report? footer, and "It stops counting right away." in the delete confirmation are gone. The location button can't show in the simulator (no permission), so Max checks it on his phone.

**GitHub Pages is on** (2026-10-08): https://bigmanmike7.github.io/linemap-app/ serves `/docs` from main; `/privacy` and `/support` return 200.

**Next steps for Max:**

1. Try build 25: the my-location button, the Bars zoom, and that Settings' privacy and support links open.
2. Add his test ID if he hasn't: Settings, Copy ID, then in the Supabase SQL Editor `update app.config set value = value || jsonb_build_array('<ID>') where key = 'test_anon_ids';`. Never commit his ID: anyone with it can call the functions as him. One install row from before may be real; mark it test later if so.
3. Fill in App Store Connect on the web from PRD section 9 (App Information, age rating, App Privacy; TestFlight Test Information can wait for M5).

**Still to do in M4:**

1. **App Store Connect:** Max fills it in from PRD section 9.
2. **Before anyone but Max uses the app** (M5 field test at the latest): in the SQL Editor, mark every row so far as test (or delete it) in `app.installs`, `app.wait_sessions`, `app.reports`, `app.views`, and `app.feedback` (`update app.reports set is_test = true where not is_test;`), and make sure Max's current ID is in `test_anon_ids`.
3. Recheck the light-mode and large-text screenshots (`L01`–`L08`) after any layout change.

**Phase 2, decided to wait:** the Live Activity (lock-screen timer with an I'm in button). Suggested to Max, not decided: auto-start with the timer, bar name and timer only, I'm in as the only button. A widget extension target means new signing work.

**Ideas raised but not built** (Max hasn't asked for them):

- An index on `wait_sessions(anon_id)` if Time in lines ever gets slow (`my_wait_stats` reads the whole table now).
- The History quarter-hour dots stay 10 pt at the largest text sizes; they could grow with the text.
- Very short timers (under a minute) could count as started by mistake on the server.
- Collision handling for pins (labels only when zoomed in); Max declined for now.
- Local database tests: Max may install Docker Desktop (enable SVM in the HP's BIOS, `wsl --install --no-distribution`, `winget install -e --id Docker.DockerDesktop`); the Supabase CLI runs through `npx supabase`.

**Things to know:**

- **Wheels:** Max wants Apple's SwiftUI wheels, nothing custom. A UIKit wrapper that grayed out Save mid-spin was built and reverted on 2026-10-07; besides Max's call, its motion watcher kept the app from looking idle to UI tests.
- **Deletion requests:** run `select public.delete_my_data('<ID>');` in the SQL Editor, then reply. The phone keeps its ID.
- **Older builds** (only Max has them): up to 21 have Delete my data in Settings; up to 20 ask the crowd and offer 50+ (the server accepts them and drops the crowd).
- On the fall-back night (Nov 1), 1:00–1:45 a.m. happen twice, so History shows those rows twice, each at its real time.
- **Server judgment calls** (point out if they matter): Undo's 5 minutes count by server time, so a late offline Undo gets "Couldn't undo"; a timer closed by a line elsewhere can be redone but not undone; I'm inside from older builds is never redone.
- **UI tests:** MapKit sometimes exposes the pins as its own map features on a second launch, so the light-mode walkthrough opens bars from the Bars tab. The thank-you stays 20 seconds under UI testing. `tapDialogButton` retries dropped dialog taps, and a failed test saves a `FAILED` screenshot plus a screen recording in the artifact. The test fixture's history marks tonight and a few earlier nights as having reports.
- **CI** often fails with "The job was not acquired by Runner" or an artifact-upload timeout: GitHub capacity, not a test failure. Rerun with `gh run rerun <id> --failed`. When a UI test really fails, the "Show test failures" step prints why.

- **Stored location precision** (Max, 2026-10-08): distance and direction stay unrounded, though with the door pin they rebuild the spot to about a meter; Claude suggested rounding (10 m, 8 compass points) and Max declined. So **move a pin only through a migration**, which keeps the old door in git and can re-measure that bar's reports from the new door (rebuild each spot from the old door, then recompute distance, direction, and `uncertain`). Timer end distances (`distance_end_m`) have no direction and can't be rebuilt exactly.

**Handy facts:**

- Ship a build: `gh workflow run testflight.yml`. CI deploys passing migrations to Supabase automatically.
- Supabase project ref `jjsccwmvgfzsxozhjlrt`. There is no local database access: the password lives only in GitHub Secrets, so Max runs one-off SQL in the dashboard SQL Editor.
- **Data check:** `gh workflow run data-check.yml` (optional input: a deleted anonymous ID) runs a read-only, counts-only check of the live database. Its logs are public, so it never prints IDs.
- The app calls 15 functions (PRD 7.2). The server also keeps `submit_report` and `delete_my_data` for older builds and support.
