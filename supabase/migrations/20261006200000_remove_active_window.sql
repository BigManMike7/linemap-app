-- No more active window (PRD 5.4, FR-17, FR-23, FR-36, FR-43). M4, 2026-10-06.
--
-- Approved by Max on 2026-10-06: bars are open most of the day, so LineMap has
-- no hours. The Thu-Sat 9 p.m.-2 a.m. window stopped hiding anything in logic
-- version 2; this removes what was left of it.
--
-- Changes:
--   - app.bar_estimate(bigint, timestamptz, boolean, text) is dropped and
--     replaced by app.bar_estimate(bigint, timestamptz, boolean): no window
--     state. `display` is 'estimate' when any signal is within the last 60
--     minutes, else 'not_enough_data', at every hour. It never returns
--     'closed' or 'outside_hours' now. Same output keys, volatility, security
--     (invoker), and search_path.
--   - app.estimates: `window_state` is always 'live' (app builds up to 19
--     decode it as required). Everything else is unchanged.
--   - app.take_snapshots (FR-36): runs at any hour, and saves a row only for
--     active, non-test bars whose live estimate is 'estimate' (a report within
--     the last hour). Returns the number saved. The take-snapshots cron job
--     (every 5 minutes) is unchanged.
--   - app.window_state(timestamptz) and app.night_window(date) are dropped.
--   - The settings active_nights, active_window_start, and active_window_end
--     are deleted. The config_log_delete trigger records each deletion in
--     app.config_history (old value, no new value), like any other change.
--   - app.event_nights (FR-23) stays exactly as it is (empty, RLS on, no
--     grants), kept for later. Nothing reads it now.
--   - History (FR-43): app.history keeps its signature and output keys, but
--     each point now summarizes only its own quarter hour, [at, at + 15
--     minutes), capped at p_at, with the live combination rules. `start` and
--     `end` are now the night day's bounds, 4 a.m. Eastern on the night's date
--     to 4 a.m. the next day.
--   - To share the live rules with History without copying them,
--     app.signal_people and app.bar_activity take an optional exclusive upper
--     bound (p_before, default null = none); they are dropped and recreated
--     because the signature changes. The new app.pick_signal_in holds the
--     pick logic with explicit bounds, and app.pick_signal (same signature) now
--     calls it with the live 60/30-minute windows, so live estimates are
--     unchanged.
--   - app.logic_version: 2 -> 3.
--   - No table, column, index, answer code, or public API change. The public
--     functions keep their signatures and grants.

-- Logic version (FR-21) ------------------------------------------------------------------
-- Version of the estimate logic. Bump it whenever the rules in these SQL
-- functions change meaning.
--   1  first release
--   2  2026-10-06: display uses the live rule at every hour; 'outside_hours'
--      is no longer a display value
--   3  2026-10-06: no active window: no 'closed', window_state always 'live',
--      snapshots at any hour for bars with a recent report, and each History
--      point covers only its own quarter hour
create or replace function app.logic_version()
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$ select 3 $$;

-- Building blocks with an optional upper bound -----------------------------------------

-- Each person's newest value for one signal at one bar, within [p_since, p_at],
-- and before p_before when it is given (History's quarter hours are half open).
drop function app.signal_people(bigint, text, timestamptz, timestamptz, boolean);

create function app.signal_people(p_bar_id bigint, p_signal text, p_since timestamptz,
                                  p_at timestamptz, p_include_test boolean,
                                  p_before timestamptz default null)
returns table (anon_id uuid, at timestamptz, code smallint, minutes integer, source text)
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct on (c.anon_id) c.anon_id, c.at, c.code, c.minutes, c.source
  from (
    select r.anon_id, r.phone_time as at, r.line_size as code,
           null::integer as minutes, 'reported' as source
    from app.reports r
    where p_signal = 'line_size' and r.bar_id = p_bar_id
      and r.line_size is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select r.anon_id, r.phone_time, r.busyness, null, 'reported'
    from app.reports r
    where p_signal = 'busyness' and r.bar_id = p_bar_id
      and r.busyness is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select r.anon_id, r.phone_time, r.recalled_wait, null, 'reported'
    from app.reports r
    where p_signal = 'wait' and r.bar_id = p_bar_id
      and r.recalled_wait is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select s.anon_id, s.ended_at, app.wait_code(s.measured_wait_seconds),
           round(s.measured_wait_seconds / 60.0)::integer, 'measured'
    from app.wait_sessions s
    where p_signal = 'wait' and s.bar_id = p_bar_id
      and s.status = 'entered'
      and (p_include_test or not s.is_test)
  ) c
  where c.at >= p_since and c.at <= p_at
    and c.at < coalesce(p_before, 'infinity'::timestamptz)
  -- On a tie, a measured wait beats a reported range.
  order by c.anon_id, c.at desc, c.source
$$;

-- Everyone who reported at a bar within [p_since, p_at], and before p_before
-- when it is given: any visible report, or a finished wait.
drop function app.bar_activity(bigint, timestamptz, timestamptz, boolean);

create function app.bar_activity(p_bar_id bigint, p_since timestamptz, p_at timestamptz,
                                 p_include_test boolean, p_before timestamptz default null)
returns table (anon_id uuid, at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select r.anon_id, r.phone_time
  from app.reports r
  where r.bar_id = p_bar_id and not r.hidden
    and (p_include_test or not r.is_test)
    and r.phone_time >= p_since and r.phone_time <= p_at
    and r.phone_time < coalesce(p_before, 'infinity'::timestamptz)
  union all
  select s.anon_id, s.ended_at
  from app.wait_sessions s
  where s.bar_id = p_bar_id and s.status = 'entered'
    and (p_include_test or not s.is_test)
    and s.ended_at >= p_since and s.ended_at <= p_at
    and s.ended_at < coalesce(p_before, 'infinity'::timestamptz)
$$;

-- The shown value for one signal from the reports in [p_since, p_at] (and
-- before p_before when given), or null when there is none (FR-18, FR-19):
--   1. Take each person's newest report for the signal in the range, so one
--      person counts once.
--   2. The newest report wins...
--   3. ...unless it is at or after p_fresh_since and disagrees with the
--      reports from p_fresh_since of majority_min_others (2) or more other
--      people. "Disagree" means codes more than agree_within (1) apart. Then
--      the most common code among those reports wins, ties going to the most
--      recent; the winner is that code's newest report.
-- A value is 'fresh' when it is at or after p_fresh_since, else 'stale'.
create function app.pick_signal_in(p_bar_id bigint, p_signal text, p_since timestamptz,
                                   p_fresh_since timestamptz, p_at timestamptz,
                                   p_before timestamptz, p_include_test boolean)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  agree_within integer := app.setting_int('agree_within');
  min_others   integer := app.setting_int('majority_min_others');
  newest       record;
  winner       record;
  disagreeing  integer;
begin
  select * into newest
  from app.signal_people(p_bar_id, p_signal, p_since, p_at, p_include_test, p_before) p
  order by p.at desc, p.source
  limit 1;

  if not found then
    return null;
  end if;

  winner := newest;

  if newest.at >= p_fresh_since then
    select count(*) into disagreeing
    from app.signal_people(p_bar_id, p_signal, p_fresh_since, p_at, p_include_test, p_before) p
    where p.anon_id <> newest.anon_id
      and abs(p.code - newest.code) > agree_within;

    if disagreeing >= min_others then
      with fresh as (
        select * from app.signal_people(p_bar_id, p_signal, p_fresh_since, p_at, p_include_test, p_before)
      ), votes as (
        select f.code, count(*) as n, max(f.at) as last_at
        from fresh f
        group by f.code
      )
      select f.* into winner
      from fresh f
      join votes v on v.code = f.code
      order by v.n desc, v.last_at desc, f.at desc, f.source
      limit 1;
    end if;
  end if;

  return jsonb_build_object(
    'code', winner.code,
    'minutes', winner.minutes,
    'source', winner.source,
    'at', winner.at,
    'freshness', case when winner.at >= p_fresh_since then 'fresh' else 'stale' end,
    'rule', case when winner.anon_id = newest.anon_id and winner.at = newest.at
                 then 'newest' else 'majority' end
  );
end;
$$;

-- The live value for one signal: the last stale_minutes (60), with the
-- majority rule over the last fresh_minutes (30). Same rules as before.
create or replace function app.pick_signal(p_bar_id bigint, p_signal text, p_at timestamptz,
                                           p_include_test boolean)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.pick_signal_in(p_bar_id, p_signal,
                            p_at - app.setting_minutes('stale_minutes'),
                            p_at - app.setting_minutes('fresh_minutes'),
                            p_at, null, p_include_test)
$$;

-- Live estimates --------------------------------------------------------------------------

-- One bar's estimate. `display` tells the app which state to show:
--   estimate         show the signals (stale ones grayed out)
--   not_enough_data  nothing within 60 minutes ("No live reports")
-- The same at every hour. 'closed' and 'outside_hours' are no longer returned
-- (since logic version 3 and 2), but older builds still accept them.
create function app.bar_estimate(p_bar_id bigint, p_at timestamptz, p_include_test boolean)
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

drop function app.bar_estimate(bigint, timestamptz, boolean, text);

-- Every active bar's estimate at a moment. Real users never see test rows;
-- test IDs see test rows too, so Max can check his own reports.
-- window_state is always 'live': there is no window any more, but app builds
-- up to 19 decode the key as required.
create or replace function app.estimates(p_at timestamptz, p_include_test boolean)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  return jsonb_build_object(
    'logic_version', app.logic_version(),
    'generated_at', p_at,
    'window_state', 'live',
    'bars', coalesce((
      select jsonb_agg(app.bar_estimate(b.id, p_at, p_include_test)
                       order by b.display_order, b.id)
      from app.bars b
      where b.active and (p_include_test or not b.is_test)
    ), '[]'::jsonb)
  );
end;
$$;

-- Snapshots (FR-36) ------------------------------------------------------------------------
-- Saves what each bar shows, at any hour, for active non-test bars with a
-- report within the last hour (display 'estimate'). A bar with no snapshot at
-- a moment was showing "No live reports". Snapshots never include test rows.
-- Returns the number of rows saved.
create or replace function app.take_snapshots(p_at timestamptz default now())
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  saved integer;
begin
  insert into app.estimate_snapshots (bar_id, taken_at, estimate, logic_version)
  select b.id, p_at, e.estimate, app.logic_version()
  from app.bars b
  cross join lateral (select app.bar_estimate(b.id, p_at, false) as estimate) e
  where b.active and not b.is_test
    and e.estimate ->> 'display' = 'estimate';

  get diagnostics saved = row_count;
  return saved;
end;
$$;

-- History (FR-43) --------------------------------------------------------------------------
-- One bar's history for one night, as of p_at:
--   start, end  the night day: night_boundary_hour (4 a.m.) Eastern on the
--               night's date to the same hour the next day, the boundary
--               app.night_date uses. Computed per date, so daylight saving is
--               handled.
--   points      one per quarter hour of the night day, never after p_at. The
--               point at t covers only the reports in its own quarter hour,
--               [t, t + 15 minutes), and for tonight's current quarter only
--               those up to p_at. Points are 15 real minutes apart, so a
--               normal night has 96, the night daylight saving starts (spring
--               forward) 92, and the night it ends (fall back) 100. Within a
--               quarter hour the live rules apply (app.pick_signal_in): each
--               person's newest report per signal counts once, the newest
--               wins unless 2 or more other people in that quarter hour
--               disagree and the majority wins, and a measured wait counts
--               when the person got in. Every value is therefore 'fresh'.
--               `people` is how many distinct people reported in that quarter
--               hour. A single report fills exactly one point. Only combined
--               values, no IDs or report times. Deleted, replaced, and hidden
--               reports are not in the rows the rules read, so they never
--               appear.
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
  v_tonight  date := app.night_date(p_at);
  v_night    date := coalesce(p_night, app.night_date(p_at));
  v_boundary time := make_time(app.setting_int('night_boundary_hour'), 0, 0);
  v_cutoff   date := app.night_date(p_at) - app.setting_int('retention_days');
  v_start    timestamptz;
  v_end      timestamptz;
  v_nights   jsonb;
  v_points   jsonb;
begin
  v_start := app.eastern(v_night, v_boundary);
  v_end := app.eastern(v_night + 1, v_boundary);

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
           'people', q.people,
           'line_size', case when q.line_size is not null then
                          jsonb_build_object('code', q.line_size -> 'code',
                                             'freshness', q.line_size -> 'freshness') end,
           'wait', case when q.wait is not null then
                     jsonb_build_object('code', q.wait -> 'code',
                                        'minutes', q.wait -> 'minutes',
                                        'freshness', q.wait -> 'freshness') end,
           'busyness', case when q.busyness is not null then
                         jsonb_build_object('code', q.busyness -> 'code',
                                            'freshness', q.busyness -> 'freshness') end
         ) order by g.t), '[]'::jsonb)
  into v_points
  from generate_series(v_start, least(v_end, p_at), interval '15 minutes') as g (t)
  cross join lateral (
    select
      app.pick_signal_in(p_bar_id, 'line_size', g.t, g.t, p_at, g.t + interval '15 minutes', p_include_test)
        as line_size,
      app.pick_signal_in(p_bar_id, 'wait', g.t, g.t, p_at, g.t + interval '15 minutes', p_include_test)
        as wait,
      app.pick_signal_in(p_bar_id, 'busyness', g.t, g.t, p_at, g.t + interval '15 minutes', p_include_test)
        as busyness,
      (select count(distinct a.anon_id)::integer
       from app.bar_activity(p_bar_id, g.t, p_at, p_include_test, g.t + interval '15 minutes') a)
        as people
  ) q
  -- The day's end is the next night's first moment.
  where g.t < v_end;

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

-- The window is gone ------------------------------------------------------------------------

drop function app.window_state(timestamptz);
drop function app.night_window(date);

-- The config_log_delete trigger logs each of these in app.config_history.
delete from app.config
where key in ('active_nights', 'active_window_start', 'active_window_end');

comment on table app.event_nights is
  'Event nights (FR-23). Unused since 2026-10-06, when the active window was removed: nothing reads this table. Kept, empty, for later.';

-- Grants -------------------------------------------------------------------------------------
-- New app functions get EXECUTE for PUBLIC by default; take it away. create or
-- replace keeps an existing function's owner and grants; restate the lockdown
-- anyway. The public API functions are not touched.

revoke all on all functions in schema app from public, anon, authenticated;
