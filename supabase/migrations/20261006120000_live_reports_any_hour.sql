-- Recent reports show at every hour (FR-17, FR-21). M4, 2026-10-06.
--
-- Approved by Max on 2026-10-06: outside the active window, a report 30 to 60
-- minutes old was hidden ("outside hours") even though the same report shows
-- (grayed out) during the window. Now every hour uses the live rule.
--
-- Changes:
--   - app.bar_estimate: `display` is 'closed' while the window is closed (2-4
--     a.m. after an active night), as before. Every other time, inside the
--     window or not, it is 'estimate' when any signal is within the last 60
--     minutes (stale ones still marked stale), else 'not_enough_data'. It no
--     longer returns 'outside_hours'. Same signature, volatility, security
--     (invoker), search_path, and output keys.
--   - app.logic_version: 1 -> 2, since the display rule changed meaning.
--   - Not changed: app.window_state, app.estimates (its `window_state` can
--     still be 'outside_hours'; older app builds decode it), take_snapshots
--     (still only while live), history, event nights, settings, tables,
--     columns, answer codes, and grants. create or replace keeps each
--     function's owner and privileges, so the lockdown (no EXECUTE for public,
--     anon, or authenticated) stays as set in earlier migrations.

-- Version of the estimate and window logic (FR-21). Bump it whenever the
-- rules in these SQL functions change meaning.
--   1  first release
--   2  2026-10-06: display uses the live rule at every hour; 'outside_hours'
--      is no longer a display value
create or replace function app.logic_version()
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$ select 2 $$;

-- One bar's estimate. `display` tells the app which state to show:
--   estimate         show the signals (stale ones grayed out)
--   not_enough_data  nothing within 60 minutes
--   closed           2-4 a.m. after an active night
--   outside_hours    no longer returned since logic version 2; kept in the
--                    contract for older builds
create or replace function app.bar_estimate(p_bar_id bigint, p_at timestamptz,
                                            p_include_test boolean, p_window_state text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  fresh_since timestamptz := p_at - app.setting_minutes('fresh_minutes');
  stale_since timestamptz := p_at - app.setting_minutes('stale_minutes');
  line_size   jsonb := app.pick_signal(p_bar_id, 'line_size', p_at, p_include_test);
  wait        jsonb := app.pick_signal(p_bar_id, 'wait', p_at, p_include_test);
  busyness    jsonb := app.pick_signal(p_bar_id, 'busyness', p_at, p_include_test);
  latest      timestamptz;
  freshness   text;
  people      integer := 0;
  display     text;
begin
  select max(a.at) into latest
  from app.bar_activity(p_bar_id, stale_since, p_at, p_include_test) a;

  freshness := case
    when latest is null then 'none'
    when latest >= fresh_since then 'fresh'
    else 'stale'
  end;

  if freshness <> 'none' then
    select count(distinct a.anon_id) into people
    from app.bar_activity(
      p_bar_id,
      case when freshness = 'fresh' then fresh_since else stale_since end,
      p_at, p_include_test) a;
  end if;

  display := case
    when p_window_state = 'closed' then 'closed'
    when coalesce(line_size, wait, busyness) is not null then 'estimate'
    else 'not_enough_data'
  end;

  return jsonb_build_object(
    'bar_id', p_bar_id,
    'display', display,
    'freshness', freshness,
    'people', people,
    'latest_at', latest,
    'line_size', line_size,
    'wait', wait,
    'busyness', busyness
  );
end;
$$;

-- Belt and braces, as in earlier migrations: no app function is callable by clients.
revoke all on all functions in schema app from public, anon, authenticated;
