-- History covers the whole night day, every 15 minutes (FR-43). M4, 2026-10-05.
--
-- Approved by Max on 2026-10-05: college bars get busy early, especially on
-- football Saturdays, so a report at 2 p.m. must show in History. Before this,
-- points covered only the usual window (9 p.m. to 2 a.m.) every 5 minutes.
--
-- Changes:
--   - app.history is redefined with the same signature, security (invoker),
--     search_path, and output keys. Only `points` changes: every 15 minutes
--     over the whole night day instead of every 5 minutes over the usual
--     window. `start` and `end` keep their meaning (the usual window), so the
--     app still knows which rows always show.
--   - No table, column, index, setting, answer code, or grant changes.
--     create or replace keeps the function's owner and privileges, so its
--     lockdown (no EXECUTE for public, anon, or authenticated) stays as set in
--     20261005200000_redo_undo_history.sql. public.bar_history is unchanged.
--   - The estimate rules are unchanged, so logic_version stays 1.

-- History (FR-43) ---------------------------------------------------------------------
-- One bar's history for one night, as of p_at:
--   start, end  the night's usual window from active_window_start to
--               active_window_end (Eastern, so daylight saving is handled;
--               an end at or before the start is the next day). Event-night
--               windows (FR-23) are not used. The app always shows the rows
--               in this window; points outside it are for reports earlier or
--               later in the day.
--   points      every 15 minutes of the night day, never after p_at. The night
--               day for night D runs from night_boundary_hour (4 a.m.) Eastern
--               on D up to, but not including, the same hour on D + 1: the
--               boundary app.night_date uses, so every point's night date is D.
--               Points are 15 real minutes apart, so a normal night has 96, the
--               night daylight saving starts (spring forward) 92, and the night
--               it ends (fall back) 100. Each point is the bar's estimate as of
--               that moment by the live rules (app.bar_estimate): only combined
--               values, no IDs or report times. Deleted, replaced, and hidden
--               reports are not in the tables the rules read, so they never
--               appear. The signals don't depend on the window, so a fresh
--               report outside the usual window shows like any other.
--   nights      every night with visible data at this bar (reports not
--               hidden, or finished waits that ended as entered) within
--               retention_days, newest first.
-- p_night null means tonight. Test rows count only when p_include_test.

create or replace function app.history(p_bar_id bigint, p_night date, p_at timestamptz, p_include_test boolean)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tonight   date := app.night_date(p_at);
  v_night     date := coalesce(p_night, app.night_date(p_at));
  v_win_start time := (app.setting('active_window_start') #>> '{}')::time;
  v_win_end   time := (app.setting('active_window_end') #>> '{}')::time;
  v_boundary  time := make_time(app.setting_int('night_boundary_hour'), 0, 0);
  v_cutoff    date := app.night_date(p_at) - app.setting_int('retention_days');
  v_start     timestamptz;
  v_end       timestamptz;
  v_day_start timestamptz;
  v_day_end   timestamptz;
  v_nights    jsonb;
  v_points    jsonb;
begin
  v_start := app.eastern(v_night, v_win_start);
  v_end := app.eastern(case when v_win_end <= v_win_start then v_night + 1 else v_night end, v_win_end);
  v_day_start := app.eastern(v_night, v_boundary);
  v_day_end := app.eastern(v_night + 1, v_boundary);

  select coalesce(jsonb_agg(to_jsonb(n.night_date) order by n.night_date desc), '[]'::jsonb)
  into v_nights
  from (
    select r.night_date
    from app.reports r
    where r.bar_id = p_bar_id
      and not r.hidden
      and (p_include_test or not r.is_test)
      and r.night_date between v_cutoff and v_tonight
    union
    select s.night_date
    from app.wait_sessions s
    where s.bar_id = p_bar_id
      and s.status = 'entered'
      and (p_include_test or not s.is_test)
      and s.night_date between v_cutoff and v_tonight
  ) n;

  select coalesce(jsonb_agg(jsonb_build_object(
           'at', g.t,
           'people', (e.v ->> 'people')::integer,
           'line_size', case when jsonb_typeof(e.v -> 'line_size') = 'object' then
                          jsonb_build_object('code', e.v -> 'line_size' -> 'code',
                                             'freshness', e.v -> 'line_size' -> 'freshness') end,
           'wait', case when jsonb_typeof(e.v -> 'wait') = 'object' then
                     jsonb_build_object('code', e.v -> 'wait' -> 'code',
                                        'minutes', e.v -> 'wait' -> 'minutes',
                                        'freshness', e.v -> 'wait' -> 'freshness') end,
           'busyness', case when jsonb_typeof(e.v -> 'busyness') = 'object' then
                         jsonb_build_object('code', e.v -> 'busyness' -> 'code',
                                            'freshness', e.v -> 'busyness' -> 'freshness') end
         ) order by g.t), '[]'::jsonb)
  into v_points
  from generate_series(v_day_start, least(v_day_end, p_at), interval '15 minutes') as g (t)
  cross join lateral (
    select app.bar_estimate(p_bar_id, g.t, p_include_test, 'live') as v
  ) e
  -- The day's end is the next night's first moment.
  where g.t < v_day_end;

  return jsonb_build_object(
    'logic_version', app.logic_version(),
    'bar_id', p_bar_id,
    'night', v_night,
    'tonight', v_tonight,
    'start', v_start,
    'end', v_end,
    'nights', v_nights,
    'points', v_points
  );
end;
$$;
