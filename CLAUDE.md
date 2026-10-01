# LineMap

An iPhone beta that shows live, community-reported lines and crowds at State College bars. People at a bar tap "I'm in line" or "I'm inside", and everyone else sees each bar's line and wait on a map. This is a learning project: keep it simple, polished, and modular.

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
supabase/seed.sql          # the three starting bars + default config
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

**Time**

- **Time zone.** All rules use America/New_York.
- **Night boundary.** A night runs until 4 a.m. Eastern, and `night_date` is set on the server (FR-22). Test daylight-saving changes.

**Location**

- **Permission.** Ask only on the first report, never on launch. The map shows the user's location dot only if permission was already granted (FR-1, FR-24).
- **Never reject for location.** Bad or missing location only sets the `uncertain` flag (FR-27).

**Reporting**

- **Rate limit.** One report per bar every 10 minutes per person, enforced on the server. Exceptions: line-size updates in an open session, I'm in, Gave up, and the busyness answer after I'm in (FR-13).
- **Sessions.** Only one open wait session at a time (FR-14). Tapping "I'm inside" with an open session at that bar counts as I'm in (FR-15). Sessions become unfinished after 90 minutes (FR-10).
- **Answers.** Each one is saved immediately. "I can't tell" is stored separately from skipped (FR-12).
- **Offline queue.** Every report and session event has a client-generated ID, so retries never duplicate. The queue survives restarts (FR-16).

**Estimates**

- **Freshness.** Fresh up to 30 minutes, grayed out from 30 to 60, then "Not enough data" (FR-17).
- **Counting.** Count distinct people, not reports (FR-18). The newest report wins unless 2 or more fresh reports from other people disagree; then the majority wins (FR-19).
- **Thresholds** live in the `config` table, not in code. Log every change to `config_history`.

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

## Status

- [x] **M1. Setup:** repo, XcodeGen project, LineMapCore package, CI pipeline. Done when an empty app builds in CI and installs on Max's iPhone through TestFlight.
- [ ] **M2. Backend:** tables, RLS, functions, cron jobs, seed bars, pgTAP tests.
- [ ] **M3. App:** map, bar sheet, report flow, wait card, location, IDs, offline queue, feedback, Settings.
- [ ] **M4. Polish:** dark mode, accessibility, empty and error states, GitHub Pages docs, App Store Connect.
- [ ] **M5. Field test:** downtown testing, then Beta App Review.
- [ ] **M6. Launch:** public TestFlight link.

**Current milestone: M2** (waiting for Max to say start).
