# LineMap

An iPhone beta that shows live, community-reported lines and crowds at State College bars. People at a bar tap "Start line timer" or "Report conditions", and everyone else sees each bar's line and wait on a map. This is a learning project: keep it simple, polished, and modular.

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
supabase/migrations/*_starting_data.sql  # the three starting bars + default config
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
- **Delete my data** deletes everything tied to the anonymous ID, logs a count with no ID, then creates a new anonymous ID (FR-32).
- **Made a wrong report?** in Settings deletes one report or finished wait from the last 24 hours, for real. Its rate limit keeps running through a short-lived hold (anon ID, bar, kind, time only), and the deletion logs a count with no ID (FR-41).

**Time**

- **Time zone.** All rules use America/New_York.
- **Night boundary.** A night runs until 4 a.m. Eastern, and `night_date` is set on the server (FR-22). Test daylight-saving changes.

**Location**

- **Permission.** Ask only on the first report, never on launch. The map shows the user's location dot only if permission was already granted (FR-1, FR-24).
- **Never reject for location.** Bad or missing location only sets the `uncertain` flag (FR-27).

**Reporting**

- **Rate limit.** Two separate 10-minute limits per person per bar, enforced on the server: timed lines (Start line timer) and manual reports (Report conditions). Neither blocks the other. Not limited: line-size updates in an open session (each its own row), I'm in, Gave up, and the busyness answer after I'm in, which only older builds send (FR-13).
- **Sessions.** Only one open wait session at a time (FR-14). Report conditions never touches a session; the server's I'm inside rule (FR-15) remains only for older builds. Sessions become unfinished after 90 minutes (FR-10). Adjust time moves the start back 0–90 minutes (FR-7).
- **Answers.** Every answer can be skipped (FR-12). Line size and Adjust time send when Save is tapped (swiping away skips); Report conditions sends once. The app no longer offers "I can't tell", "Can't see the end", or the recalled-wait question, but their stored codes stay reserved and never change meaning.
- **Offline queue.** Every report and session event has a client-generated ID, so retries never duplicate. The queue survives restarts (FR-16).

**Estimates**

- **Freshness.** Fresh up to 30 minutes, grayed out from 30 to 60, then "Not enough data" (FR-17).
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
- Starting bars (pins geocoded from these addresses):
  - Doggie's Pub, 108 S Pugh St
  - The Phyrst, 111 E Beaver Ave
  - Cafe 210 West, 210 W College Ave
  - All are in State College, PA 16801.

## Max checks these himself

The data model before launch, the database tests, location on a real phone, that Delete my data removes rows, and the privacy policy. Point these out when they're ready for review.

- [x] Data model (approved 2026-10-01, as built in M2). Point out any later change to tables, fields, or answer codes again.
- [x] Database tests (approved 2026-10-01, 493 pgTAP tests).
- [ ] Location on a real phone (M3/M5)
- [ ] Delete my data removes rows (M3)
- [ ] Privacy policy (M4). Must cover Made a wrong report? (FR-41) and history (FR-43).

## Status

- [x] **M1. Setup:** repo, XcodeGen project, LineMapCore package, CI pipeline. Done when an empty app builds in CI and installs on Max's iPhone through TestFlight.
- [x] **M2. Backend:** tables, RLS, functions, cron jobs, seed bars, pgTAP tests.
- [ ] **M3. App:** map, bar sheet, report flow, wait card, location, IDs, offline queue, feedback, Settings, Directions (FR-40), Made a wrong report? (FR-41), thank-you (FR-42).
- [ ] **M4. Polish:** bar history by night (FR-43), dark mode, accessibility, empty and error states, GitHub Pages docs, App Store Connect.
- [ ] **M5. Field test:** downtown testing, then Beta App Review.
- [ ] **M6. Launch:** public TestFlight link.

**Current milestone: M3** (built and on TestFlight; waiting for Max's end-to-end check).

## Where we left off (2026-10-04)

**M3 is built.** TestFlight build 12 is the latest (map-pin selection, the 0–90 Adjust time wheel, no Directions on the wait card). All CI passed: pgTAP (793 tests), LineMapCore unit tests, the 15-screen screenshot walkthrough, and the database deploy. M3 is done when Max confirms the full flow on his phone. Next session:

1. Have Max install build 12 and check:
   - Start line timer (one tap) → Line size (a wheel with Save and no Skip; the saved message shows) → Adjust time (one 0–90 wheel with Save; swiping away changes nothing) → I'm in (no question, thank-you shows).
   - Report conditions: one screen, Send off until an answer is picked, thank-you shows.
   - The ✕ on the wait card: "I gave up on the line" and "Started it by mistake".
   - Directions on the bar sheet opens Apple Maps. The wait card has no Directions.
   - Report conditions, then Start line timer at the same bar right away: allowed (separate limits, FR-13). A second Report conditions there within 10 minutes is refused.
   - Settings → Made a wrong report? lists and deletes a report; reporting that bar again within 10 minutes is still refused.
   - A report made in Airplane Mode says it will send later, then sends itself.
   - Settings → Delete my data.
2. After Delete my data his phone gets a new anonymous ID. Have him send it from Settings and run the `test_anon_ids` SQL again (`supabase/README.md`, Admin section) so his testing stays marked as test data.
3. If everything works: tick M3, tick "Delete my data removes rows" above, and stop for Max before M4. M4 starts with bar history (FR-43).

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
- Max's test anonymous ID: `cb1d32c5-1a2d-4d7d-898e-dcb9871ef2d7` (in `test_anon_ids`).
- The privacy and support links in Settings point at GitHub Pages pages that M4 still has to write. The privacy policy must cover Made a wrong report? and history.
- On 2026-10-01 Max was given SQL to delete all of his testing data. Still unconfirmed: check that `app.reports`, `app.wait_sessions`, `app.views`, `app.feedback`, and `app.installs` only hold rows from after that.
