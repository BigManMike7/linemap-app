# LineMap backend

Postgres on Supabase. The server is the source of truth for estimates and the night boundary. Requirement IDs refer to `PRD.md`.

## Layout

| Path | What |
| --- | --- |
| `migrations/*_schema.sql` | Tables, indexes, row-level security, settings log |
| `migrations/*_helpers.sql` | Settings lookups, night boundary, active window, location math |
| `migrations/*_estimates.sql` | Estimate rules and snapshots |
| `migrations/*_api.sql`, `*_cancel_session.sql`, `*_report_conditions.sql`, `*_delete_report.sql`, `*_separate_rate_limits.sql` | The 14 functions the app can call |
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

Two reports on the same clock at the same bar within 10 minutes: the second is refused. A manual report never blocks Start line timer, and a line never blocks a manual report. `app.rate_limit_wait(anon_id, bar_id, at, clock)` takes `'timed'` or `'manual'`; any other clock name is bad input. (Before 2026-10-04 all counted reports shared one clock.)

Only `line_start`, `line_update`, and `inside_after_entry` belong to a wait session.

### Deleting a single report (FR-41)

- `delete_report` really deletes the rows, so they stop counting in estimates at once.
- Each counted report it deletes leaves a row in `app.rate_limit_holds` (person, bar, `kind`, phone time; no report ID). `kind` is the deleted report's kind (`line_start`, `inside`, or `conditions`), so `rate_limit_wait` counts the hold on the same clock as the report: a deleted wait holds the timed clock, a deleted Report conditions or I'm inside holds the manual clock. Delete-and-re-report can't get around the 10-minute limit. Holds that existed when `kind` was added (2026-10-04) were set to `conditions`. The `expire-rate-limit-holds` job (every 5 minutes) deletes holds older than `rate_limit_minutes`. Holds live minutes, so the daily retention job never needs them. Delete my data removes them too.
- `app.deletions.scope` tells the two kinds of delete apart: `all` (Delete my data, and the retention job) or `one` (a single report or wait). Neither stores an ID.

## API

Call with `POST /rest/v1/rpc/<name>` and named JSON parameters. Writes return `{"ok": true, ...}` or `{"ok": false, "error": "..."}` for expected refusals (`rate_limited`, `session_not_found`, `session_not_open`, `session_open`, `not_found`). Bad input is HTTP 400.

| Function | Use |
| --- | --- |
| `get_bars(p_anon_id?)` | Active bars with door pins |
| `get_estimates(p_anon_id?)` | Every bar's current estimate (shape below) |
| `register_install(...)` | On launch: anon ID, install ID, versions, device model |
| `start_session(...)` | Start line timer. Creates the session and its first report. Rate-limited on the timed clock. Re-send the same `p_client_session_id` to set or undo Adjust time (`p_start_offset_minutes`, 0 to 90; 0 undoes it) |
| `update_line_size(...)` | Line-size update in an open session. Re-send the same report ID to change the answer |
| `end_session(p_outcome)` | `entered` (I'm in) or `gave_up` |
| `cancel_session(...)` | Cancel line (FR-39): deletes an open session and its reports, so nothing counts. A finished wait returns `session_not_open` |
| `report_conditions(...)` | Report conditions. Line size (0–5) and busyness (1–4), each optional, but at least one must be `answered`; a state not sent is stored as `skipped`. Rate-limited on the manual clock, and never starts, ends, or joins a wait session. Re-sending the same report ID returns `{"ok": true, "kind": "conditions"}` and changes nothing |
| `submit_report(...)` | Older builds only (the app stopped calling it on 2026-10-04). I'm inside. With an open session at that bar it counts as I'm in. A plain I'm inside is rate-limited on the manual clock. Pass `p_client_session_id` for the busyness answer after I'm in. Re-send the same report ID to add answers |
| `send_feedback(...)` | This looks wrong |
| `log_view(...)` | A map or bar-sheet view |
| `my_recent_reports(p_anon_id)` | Made a wrong report? (FR-41): the person's own reports and finished waits from the last 24 hours, newest first, at most 100 (shape below) |
| `delete_report(p_anon_id, p_client_report_id?, p_client_session_id?)` | Deletes one item from that list: exactly one ID. A report ID deletes a standalone report; a session ID deletes a finished wait and every report in it. Returns `{"ok": true, "rows_removed": n}`, `{"ok": false, "error": "session_open"}` for an open wait (cancel it instead), or `{"ok": false, "error": "not_found"}` for anything not theirs, older than 24 hours, inside a wait, or already deleted. The rate limit keeps running from what was deleted, on its own clock |
| `delete_my_data(p_anon_id)` | Deletes everything for the ID (holds included); the app then makes a new one |

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
