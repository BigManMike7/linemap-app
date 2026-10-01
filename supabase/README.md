# LineMap backend

Postgres on Supabase. The server is the source of truth for estimates and the night boundary. Requirement IDs refer to `PRD.md`.

## Layout

| Path | What |
| --- | --- |
| `migrations/*_schema.sql` | Tables, indexes, row-level security, settings log |
| `migrations/*_helpers.sql` | Settings lookups, night boundary, active window, location math |
| `migrations/*_estimates.sql` | Estimate rules and snapshots |
| `migrations/*_api.sql` | The 10 functions the app calls |
| `migrations/*_jobs.sql` | Scheduled jobs (`pg_cron`) |
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
| Been here a while | 5, 10, or 20 minutes |
| Answer state | `answered`, `cant_tell`, `skipped`; empty if not asked |

Two answers agree when their codes are at most one apart (FR-19).

## API

Call with `POST /rest/v1/rpc/<name>` and named JSON parameters. Writes return `{"ok": true, ...}` or `{"ok": false, "error": "..."}` for expected refusals (`rate_limited`, `session_not_found`, `session_not_open`). Bad input is HTTP 400.

| Function | Use |
| --- | --- |
| `get_bars(p_anon_id?)` | Active bars with door pins |
| `get_estimates(p_anon_id?)` | Every bar's current estimate (shape below) |
| `register_install(...)` | On launch: anon ID, install ID, versions, device model |
| `start_session(...)` | I'm in line. Creates the session and its first report. Re-send the same `p_client_session_id` to set "been here a while" or the first line size |
| `update_line_size(...)` | Line-size update in an open session. Re-send the same report ID to change the answer |
| `end_session(p_outcome)` | `entered` (I'm in) or `gave_up` |
| `submit_report(...)` | I'm inside. With an open session at that bar it counts as I'm in. Pass `p_client_session_id` for the busyness answer after I'm in. Re-send the same report ID to add answers |
| `send_feedback(...)` | This looks wrong |
| `log_view(...)` | A map or bar-sheet view |
| `delete_my_data(p_anon_id)` | Deletes everything for the ID; the app then makes a new one |

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

## Admin in the dashboard (FR-37)

Use the Table Editor and pick the `app` schema.

- **Bars:** add or edit rows in `app.bars`. To retire a bar, set `active` to false.
- **Settings:** edit `value` in `app.config`. Every change is logged in `app.config_history`.
- **Mark your own testing:** add your phone's anonymous ID to `test_anon_ids` in `app.config`, for example `["0A1B..."]`. Rows from that ID get `is_test = true`. Real users never see them, but your own phone still does.
- **Hide a report:** set `hidden = true` and fill in `hidden_reason` in `app.reports`.
- **Spot checks and event nights:** add rows to `app.spot_checks` and `app.event_nights`.
