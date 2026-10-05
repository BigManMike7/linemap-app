# LineMap backend

Postgres on Supabase. The server is the source of truth for estimates and the night boundary. Requirement IDs refer to `PRD.md`.

## Layout

| Path | What |
| --- | --- |
| `migrations/*_schema.sql` | Tables, indexes, row-level security, settings log |
| `migrations/*_helpers.sql` | Settings lookups, night boundary, active window, location math |
| `migrations/*_estimates.sql` | Estimate rules and snapshots |
| `migrations/*_api.sql`, `*_cancel_session.sql`, `*_report_conditions.sql`, `*_delete_report.sql`, `*_separate_rate_limits.sql`, `*_redo_undo_history.sql` | The 16 API functions: 15 the app calls, plus `submit_report` for older builds |
| `migrations/*_jobs.sql` | Scheduled jobs (`pg_cron`); `*_delete_report.sql` adds `expire-rate-limit-holds` |
| `migrations/*_starting_data.sql` | Default settings and the three starting bars |
| `tests/` | pgTAP tests, run in CI on every push |

CI runs the tests on a local database, then applies new migrations to the live project after they pass on `main`.

## Security model

- All tables live in the private `app` schema. The Data API doesn't expose it, and row-level security is on with no policies, so the app can't read or write tables directly (NFR-5).
- The app calls only the functions in `public` listed below. They run as their owner (`SECURITY DEFINER`), with an empty `search_path`, and only the `anon` role can run them.
- Identity is the anonymous ID the app sends. No Supabase Auth.
- Coordinates go into the functions but are never stored. Only distance, direction, accuracy, and fix age are kept (FR-26).

## Answer codes (definitions version 1, never change meaning)

| Question | Codes |
| --- | --- |
| Line size | 0 nobody, 1 = 1–10, 2 = 10–25, 3 = 25–50, 4 = 50+, 5 = can't see the end |
| Busyness | 1 quiet, 2 comfortable, 3 busy, 4 packed |
| Recalled wait | 1 under 5, 2 = 5–15, 3 = 15–30, 4 = 30–60, 5 = 60+ min |
| Adjust time (start offset) | Any whole number of minutes, 0 to 90 (0, 5, 10, or 20 before 2026-10-04) |
| Answer state | `answered`, `cant_tell`, `skipped`; empty if not asked |

Since 2026-10-01 the app no longer offers line size 5 ("can't see the end") or `cant_tell`. Both stay valid on the server and keep their meaning, so older rows read the same.

Line size wording (2026-10-04, from build 8): Line size on the wait card now asks for the whole line ("How many people are in line?"). Builds 7 and earlier asked "Roughly how many people are ahead of you?" for in-line updates; Report conditions in build 7 asked "How long is the line?". The codes keep the same ranges; only those older in-line answers counted people ahead rather than the whole line. All such answers so far are Max's test data. Definitions version stays 1.

Two answers agree when their codes are at most one apart (FR-19).

### Report kinds and positions

| Kind | Position | What | Rate limit (FR-13) |
| --- | --- | --- | --- |
| `line_start` | `line` | Start line timer | Timed clock |
| `line_update` | `line` | Line-size update in an open session | Exempt |
| `inside` | `inside` | I'm inside (older builds only) | Manual clock |
| `inside_after_entry` | `inside` | Busyness after I'm in, or I'm inside that ended a session (older builds only) | Exempt |
| `conditions` | `unspecified` | Report conditions (since 2026-10-04): line size and/or busyness from someone in line, inside, or walking by | Manual clock |

Since 2026-10-04 there are two separate clocks per person per bar, each `rate_limit_minutes` (10) long, by phone time:

- **Timed clock:** `line_start`. `start_session` checks only this one.
- **Manual clock:** `conditions` and `inside`. `report_conditions` and `submit_report` check only this one.

Two reports on the same clock at the same bar within 10 minutes: the second is refused, unless it is a redo (below). A manual report never blocks Start line timer, and a line never blocks a manual report. `app.rate_limit_wait(anon_id, bar_id, at, clock)` takes `'timed'` or `'manual'`; any other clock name is bad input. (Before 2026-10-04 all counted reports shared one clock.)

Only `line_start`, `line_update`, and `inside_after_entry` belong to a wait session.

### Redo (FR-46, since 2026-10-05)

A person can replace their own last attempt at a bar within `redo_minutes` (5, in `app.config`) instead of being refused. `app.redo_allowed(anon_id, bar_id, at, clock)` decides, and is asked only when `rate_limit_wait` says the clock is blocked. All times are phone times, and "within" means less than 5 minutes, so exactly 5 minutes is refused.

- **Timers.** A new Start line timer is a redo when every `line_start` blocking it belongs to a timer that ended as `entered` or `gave_up` less than 5 minutes before the new start (a timer closed by a line at another bar, FR-14, ended as `gave_up` too). The earlier timer is **not** deleted at start. When the new timer finishes through `end_session` (I'm in or Gave up), every earlier timer of that person at that bar that ended less than 5 minutes before the new one started is deleted with all its reports (`app.delete_replaced_sessions`). If the new timer is cancelled (FR-39), times out (FR-10), or is closed by a line at another bar, the earlier one stays. Chains work: A stops, B starts; B finishes and A is deleted; C starts within 5 minutes of B stopping; C finishes and B is deleted.
- **Report conditions.** A new Report conditions is a redo when every report blocking it is a `conditions` report sent less than 5 minutes before it. Those reports are deleted at once, before the new one is saved.
- **Holds.** A hold left by `delete_report` (FR-41) with kind `line_start` or `conditions` counts the same way, by its phone time (for a deleted wait, its start): it can be redone while that is less than 5 minutes before the new attempt. Nothing is left to delete. An older hold doesn't stop a chain once something newer can be redone.
- **Never redone:** I'm inside (`inside` reports and holds, older builds) still blocks the manual clock for the full 10 minutes, and `submit_report` has no redo. A blocker later than the new attempt's phone time (a late offline retry) is never replaced, so re-sending a replaced report is refused instead of bringing it back.
- Replaced attempts are deleted like a cancelled line: no `app.deletions` count and no rate-limit hold. The newest attempt keeps the clock running, so only it ever counts.

### Undo (FR-47, since 2026-10-05)

`reopen_session` reopens the person's own timer that ended through `end_session` (I'm in or Gave up) less than `redo_minutes` ago by server time, if no other timer of theirs is open. The status goes back to `open`; `ended_at`, `ended_by`, and `distance_end_m` are cleared, and so is the generated `measured_wait_seconds`. The start time and Adjust time stay. `end_session` creates no reports, so none are removed. A timer that timed out (`unfinished`), was closed by a line at another bar, or was ended by I'm inside from an older build can't be reopened. A reopened timer older than 90 minutes is expired as usual. Earlier timers that its finish already replaced stay deleted.

### History (FR-43, since 2026-10-05)

`bar_history` computes one bar's estimate as of every 15 minutes of a night with the live rules (`app.bar_estimate`), straight from `app.reports` and `app.wait_sessions`. Deleted, replaced, and hidden reports aren't there, so they never appear; snapshots are not used. Points cover the whole night day (since 2026-10-05, approved by Max: bars get busy early, especially on football Saturdays): from `night_boundary_hour` (4 a.m.) Eastern on the night's date up to, but not including, 4 a.m. the next day, the same boundary as `app.night_date`, so every point belongs to the night. They are 15 real minutes apart, so a normal night has 96 points, the spring-forward night (2026-03-07) 92, and the fall-back night (2026-10-31) 100. A fresh report at 2 p.m. shows in the 2 p.m. points like any other, since the signals don't depend on the active window. `start` and `end` are still the usual window from `active_window_start` to `active_window_end` (9 p.m. to 2 a.m. Eastern, computed per date so daylight saving is right), never an event-night window; the app uses them to pick the rows it always shows. Points stop at now, so tonight shows only what has happened and a future night shows none. The nights list holds every night with visible data at the bar (reports not hidden, or waits that ended as `entered`), within `retention_days`, newest first; the app adds Tonight, Last night, and Same night last week itself. Test rows count only for test IDs, as in `get_estimates`. The internal `app.history(bar_id, night, at, include_test)` takes the moment, so tests can fix it.

### Deleting a single report (FR-41)

- `delete_report` really deletes the rows, so they stop counting in estimates at once.
- Each counted report it deletes leaves a row in `app.rate_limit_holds` (person, bar, `kind`, phone time; no report ID). `kind` is the deleted report's kind (`line_start`, `inside`, or `conditions`), so `rate_limit_wait` counts the hold on the same clock as the report: a deleted wait holds the timed clock, a deleted Report conditions or I'm inside holds the manual clock. Delete-and-re-report can't get around the 10-minute limit. Holds that existed when `kind` was added (2026-10-04) were set to `conditions`. The `expire-rate-limit-holds` job (every 5 minutes) deletes holds older than `rate_limit_minutes`. Holds live minutes, so the daily retention job never needs them. Delete my data removes them too.
- `app.deletions.scope` tells the two kinds of delete apart: `all` (Delete my data, and the retention job) or `one` (a single report or wait). Neither stores an ID.

## API

Call with `POST /rest/v1/rpc/<name>` and named JSON parameters. Writes return `{"ok": true, ...}` or `{"ok": false, "error": "..."}` for expected refusals (`rate_limited`, `session_not_found`, `session_not_open`, `session_open`, `not_found`, `too_late`, `other_session_open`, `session_not_reopenable`). Bad input is HTTP 400.

| Function | Use |
| --- | --- |
| `get_bars(p_anon_id?)` | Active bars with door pins |
| `get_estimates(p_anon_id?)` | Every bar's current estimate (shape below) |
| `register_install(...)` | On launch: anon ID, install ID, versions, device model |
| `start_session(...)` | Start line timer. Creates the session and its first report. Rate-limited on the timed clock, except for a redo (FR-46). Re-send the same `p_client_session_id` to set or undo Adjust time (`p_start_offset_minutes`, 0 to 90; 0 undoes it) |
| `update_line_size(...)` | Line-size update in an open session. Re-send the same report ID to change the answer |
| `end_session(p_outcome)` | `entered` (I'm in) or `gave_up`. When it ends the timer, it deletes any earlier timer at that bar that this one redid (FR-46) |
| `reopen_session(p_client_session_id, p_anon_id)` | Undo (FR-47). Returns `{"ok": true, "status": "open", "reopened": true}`; `{"ok": true, "status": "open", "reopened": false}` if already open (a retry); `{"ok": true, "reopened": false, "removed": true}` if the timer doesn't exist for this ID (never arrived, deleted, or someone else's), so the queue can drop it; `{"ok": false, "error": "too_late"}` 5 minutes or more after it stopped; `{"ok": false, "error": "other_session_open"}`; or `{"ok": false, "error": "session_not_reopenable", "status": "..."}` for a timer that timed out or wasn't ended by I'm in or Gave up |
| `cancel_session(...)` | Cancel line (FR-39): deletes an open session and its reports, so nothing counts. A finished wait returns `session_not_open` |
| `report_conditions(...)` | Report conditions. Line size (0–5) and busyness (1–4), each optional, but at least one must be `answered`; a state not sent is stored as `skipped`. Rate-limited on the manual clock, except for a redo (FR-46), which deletes the report it replaces at once. Never starts, ends, or joins a wait session. Re-sending the same report ID returns `{"ok": true, "kind": "conditions"}` and changes nothing |
| `submit_report(...)` | Older builds only (the app stopped calling it on 2026-10-04). I'm inside. With an open session at that bar it counts as I'm in. A plain I'm inside is rate-limited on the manual clock. Pass `p_client_session_id` for the busyness answer after I'm in. Re-send the same report ID to add answers |
| `send_feedback(...)` | This looks wrong |
| `log_view(...)` | A map or bar-sheet view |
| `my_recent_reports(p_anon_id)` | Made a wrong report? (FR-41): the person's own reports and finished waits from the last 24 hours, newest first, at most 100 (shape below) |
| `delete_report(p_anon_id, p_client_report_id?, p_client_session_id?)` | Deletes one item from that list: exactly one ID. A report ID deletes a standalone report; a session ID deletes a finished wait and every report in it. Returns `{"ok": true, "rows_removed": n}`, `{"ok": false, "error": "session_open"}` for an open wait (cancel it instead), or `{"ok": false, "error": "not_found"}` for anything not theirs, older than 24 hours, inside a wait, or already deleted. The rate limit keeps running from what was deleted, on its own clock |
| `delete_my_data(p_anon_id)` | Deletes everything for the ID (holds included); the app then makes a new one |
| `bar_history(p_anon_id?, p_bar_id, p_night?)` | History (FR-43): one bar's estimate every 15 minutes of a night day, 4 a.m. to 4 a.m. Eastern (default tonight), and its nights with data (shape below). Read-only. A missing, unknown, or inactive bar, or a test bar for a real ID, is bad input |

Every report and session carries a client-generated ID, so the offline queue can retry safely (FR-16). Phone times are capped at server time.

### Estimate shape

```json
{
  "logic_version": 1,
  "generated_at": "2026-10-02T02:15:00Z",
  "window_state": "live",
  "bars": [{
    "bar_id": 2,
    "display": "estimate",
    "freshness": "fresh",
    "people": 3,
    "latest_at": "2026-10-02T02:09:00Z",
    "line_size": {"code": 2, "minutes": null, "source": "reported", "at": "...", "freshness": "fresh", "rule": "newest"},
    "wait": {"code": 3, "minutes": 25, "source": "measured", "at": "...", "freshness": "fresh", "rule": "newest"},
    "busyness": null
  }]
}
```

- `display`: `estimate`, `not_enough_data`, `closed`, or `outside_hours`.
- `freshness` (bar and signal): `fresh` (30 minutes or less), `stale` (30 to 60, shown grayed out), or `none`.
- A wait with `source: measured` has `minutes`, and its `at` is when the person got in. A `reported` wait has only a range `code`.
- `rule`: `newest`, or `majority` when 2 or more other people's fresh reports disagreed with the newest one.

### History shape

Dates are `YYYY-MM-DD`; times are Postgres ISO 8601 with an offset, as in the other shapes. Signals are `null` when there is nothing within 60 minutes.

```json
{
  "logic_version": 1,
  "bar_id": 1,
  "night": "2026-10-02",
  "tonight": "2026-10-05",
  "start": "2026-10-03T01:00:00+00:00",
  "end": "2026-10-03T06:00:00+00:00",
  "nights": ["2026-10-04", "2026-10-02"],
  "points": [
    {"at": "2026-10-02T08:00:00+00:00", "people": 0, "line_size": null, "wait": null, "busyness": null},
    {"at": "2026-10-02T08:15:00+00:00", "people": 2,
     "line_size": {"code": 2, "freshness": "fresh"},
     "wait": {"code": 3, "minutes": 25, "freshness": "stale"},
     "busyness": {"code": 3, "freshness": "fresh"}}
  ]
}
```

- `night` is the night shown; `tonight` is tonight's night date (FR-22).
- `start` and `end` are the night's usual window (9 p.m. to 2 a.m. Eastern). `points` run every 15 minutes over the whole night day, from 4 a.m. Eastern on the night's date up to (not including) 4 a.m. the next day, but only up to now: 96 points on a normal night, 92 or 100 on a daylight-saving night. The usual window's start and end always fall on a point.
- `people` is how many distinct people reported within the freshness of the newest report, like the live estimate; 0 when nothing is within 60 minutes.
- `wait.minutes` is a measured wait in minutes, or `null` for a reported range. `freshness` is `fresh` or `stale` (drawn lighter).
- `nights`: nights with visible data at this bar, newest first.

### Recent reports shape

A JSON array (empty `[]` when there is nothing). Times are Postgres ISO 8601 with an offset, like `2026-10-04T01:15:00.123456+00:00`. Answer fields hold the code when answered, else `null`.

```json
[
  {"type": "report", "kind": "conditions", "client_report_id": "…", "bar_id": 2,
   "at": "…", "line_size": 2, "busyness": null, "recalled_wait": null},
  {"type": "wait", "client_session_id": "…", "bar_id": 1, "at": "…", "ended_at": "…",
   "status": "entered", "measured_wait_seconds": 1200, "start_offset_minutes": 0,
   "line_size": 3, "busyness": 4}
]
```

- `report`: a standalone Report conditions (`kind: conditions`) or I'm inside from older builds (`kind: inside`). `at` is its phone time.
- `wait`: a finished wait, `status` `entered`, `gave_up`, or `unfinished`. `at` is when Start line timer was tapped. `line_size` is the newest answered line size in the wait, `busyness` the answer after I'm in. Open waits are not listed.
- Hidden reports are still listed: they are the person's own.

## Admin in the dashboard (FR-37)

Use the Table Editor and pick the `app` schema.

- **Bars:** add or edit rows in `app.bars`. To retire a bar, set `active` to false.
- **Settings:** edit `value` in `app.config`. Every change is logged in `app.config_history`.
- **Mark your own testing:** add your phone's anonymous ID to `test_anon_ids` in `app.config`, for example `["0A1B..."]`. Rows from that ID get `is_test = true`. Real users never see them, but your own phone still does.
- **Hide a report:** set `hidden = true` and fill in `hidden_reason` in `app.reports`.
- **Spot checks and event nights:** add rows to `app.spot_checks` and `app.event_nights`.
