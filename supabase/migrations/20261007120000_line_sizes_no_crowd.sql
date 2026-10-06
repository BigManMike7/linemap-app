-- Bigger line sizes, no crowd, and a fresh start (NFR-10, FR-11, FR-17 to
-- FR-19, FR-41, FR-43). Approved by Max on 2026-10-06.
--
-- A. Wipe: every report, wait, install, view, feedback row, snapshot, spot
--    check, deletion count, and rate-limit hold is deleted. Everything so far
--    was Max's own testing. Bars, settings, the settings log, and event nights
--    stay. In a fresh database this deletes nothing.
-- B. No crowd: the busyness question is gone from the app.
--    - The busyness and busyness_state columns and the busyness codes 1-4 stay,
--      reserved; they never change meaning and are never reused.
--    - Estimates and History ignore busyness: the `busyness` key stays in their
--      JSON (older builds decode it) but is always null. `display` is
--      'estimate' only when there is a line size or a wait.
--    - report_conditions and submit_report keep their signatures and grants
--      and still accept a busyness answer, but never store it: the row gets
--      busyness null and busyness_state 'skipped' (submit_report keeps a null
--      state when none was sent). A call whose only answer was busyness
--      (crowd-only: report_conditions without an answered line size;
--      submit_report without an answered recalled wait that doesn't end a
--      session) returns its usual success reply but stores no row and uses no
--      rate limit, so an older build's offline queue drops it and nobody
--      counts as reporting. A retry with the same ID does the same.
--    - my_recent_reports keeps its `busyness` keys, always null.
-- C. New line sizes (definitions version 2):
--      0 nobody, 1 = 1-10, 2 = 10-25, 3 = 25-50, 4 = 50+ (reserved since
--      version 2), 5 = can't see the end (reserved), 6 = 50-100 (new),
--      7 = 100+ (new)
--    - Only schema change: the reports.line_size check widens from 0-5 to 0-7.
--    - The server accepts definitions versions 1 and 2. A version 1 report may
--      use line sizes 0-5; a version 2 report 0, 1, 2, 3, 6, or 7. Anything
--      else is bad input. app.supported_definitions_version() (internal, not
--      returned to the app) now says 2, the newest.
--    - app.line_size_rank orders line sizes by size: 0, 1, 2, 3 keep their
--      code; 50+ (4), 50-100 (6), and can't see the end (5) are rank 4; 100+
--      (7) is rank 5. The majority rule (FR-19) compares line sizes by rank, so
--      50+, 50-100, and 100+ agree with each other, and votes by rank. Waits
--      still compare their codes, unchanged.
-- D. app.logic_version: 3 -> 4.
--
-- Functions created: app.line_size_rank, app.line_size_codes,
-- app.check_line_size. Replaced (same signatures, security, search_path,
-- volatility, and grants): app.logic_version, app.supported_definitions_version,
-- app.check_report_meta, app.pick_signal_in, app.bar_estimate, app.history,
-- public.start_session, public.update_line_size, public.report_conditions,
-- public.submit_report, public.my_recent_reports. Nothing is dropped.

-- A. Wipe all data ----------------------------------------------------------------------
-- No triggers fire on these tables (only app.config has triggers), so nothing
-- is logged or written elsewhere. Reports go before wait sessions, which they
-- reference. Bars, config, config_history, and event_nights are kept.

delete from app.rate_limit_holds;
delete from app.deletions;
delete from app.spot_checks;
delete from app.estimate_snapshots;
delete from app.feedback;
delete from app.views;
delete from app.reports;
delete from app.wait_sessions;
delete from app.installs;

-- C. Line size codes 0-7 ----------------------------------------------------------------
-- The check was declared inline without a name (Postgres called it
-- reports_line_size_check). Look it up by the exact column set, like the
-- report_conditions migration did; `strict` fails the migration if it finds
-- none or more than one.

do $$
declare
  v_name name;
begin
  select c.conname into strict v_name
  from pg_constraint c
  where c.conrelid = 'app.reports'::regclass
    and c.contype = 'c'
    and (select array_agg(a.attname::text order by a.attname::text)
         from pg_attribute a
         where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = array['line_size'];

  execute format('alter table app.reports drop constraint %I', v_name);
end;
$$;

alter table app.reports
  add constraint reports_line_size_check check (line_size between 0 and 7);

comment on column app.reports.line_size is
  'How many people are in line, as a fixed code (NFR-10): 0 nobody, 1 = 1-10, 2 = 10-25, 3 = 25-50, 4 = 50+ (definitions version 1 only), 5 = can''t see the end (reserved), 6 = 50-100 and 7 = 100+ (definitions version 2, since 2026-10-07).';
comment on column app.reports.busyness is
  'Reserved: the crowd answer, 1 quiet, 2 comfortable, 3 busy, 4 packed. Never stored since 2026-10-07 (always null); the codes keep their meaning.';
comment on column app.reports.definitions_version is
  'Answer definitions the app used (NFR-10): 1 (line sizes 0-5) or 2 (since 2026-10-07: line sizes 0, 1, 2, 3, 6, 7).';

-- Logic version (FR-21) ------------------------------------------------------------------
-- Version of the estimate logic. Bump it whenever the rules in these SQL
-- functions change meaning.
--   1  first release
--   2  2026-10-06: display uses the live rule at every hour; 'outside_hours'
--      is no longer a display value
--   3  2026-10-06: no active window: no 'closed', window_state always 'live',
--      snapshots at any hour for bars with a recent report, and each History
--      point covers only its own quarter hour
--   4  2026-10-07: busyness is ignored (always null), display needs a line
--      size or a wait, and line sizes are compared by size rank (50-100 and
--      100+ added)
create or replace function app.logic_version()
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$ select 4 $$;

-- Definitions version (NFR-10) ----------------------------------------------------------
-- The newest answer definitions version this server understands. Every
-- version from 1 up to this one is accepted.
--   1  line sizes 0-5
--   2  2026-10-07: line sizes 0, 1, 2, 3, 6 (50-100), 7 (100+); 4 (50+) and
--      5 (can't see the end) are no longer offered
create or replace function app.supported_definitions_version()
returns smallint
language sql
immutable
security invoker
set search_path = ''
as $$ select 2::smallint $$;

-- The line size codes a definitions version may send, or null for a version
-- the server doesn't know.
create function app.line_size_codes(p_definitions_version smallint)
returns smallint[]
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_definitions_version
    when 1 then '{0,1,2,3,4,5}'::smallint[]
    when 2 then '{0,1,2,3,6,7}'::smallint[]
  end
$$;

-- Line sizes in size order, for comparing them (FR-19). Codes are fixed
-- forever, so 6 and 7 sort by what they mean, not by their number:
--   0 nobody 0, 1-10 1, 10-25 2, 25-50 3,
--   50+ (4), 50-100 (6), can't see the end (5)  4,
--   100+ (7) 5
create function app.line_size_rank(p_code smallint)
returns smallint
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_code
    when 0 then 0
    when 1 then 1
    when 2 then 2
    when 3 then 3
    when 4 then 4
    when 5 then 4
    when 6 then 4
    when 7 then 5
  end::smallint
$$;

-- Validation ------------------------------------------------------------------------------

-- Report metadata. Any definitions version from 1 to the newest is accepted.
create or replace function app.check_report_meta(p_location_status text, p_app_version text,
                                                  p_definitions_version smallint, p_source text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_location_status is null
     or p_location_status not in ('precise', 'approximate', 'denied', 'no_fix') then
    perform app.bad_input('invalid location_status');
  end if;
  if p_app_version is null or length(p_app_version) not between 1 and 32 then
    perform app.bad_input('invalid app_version');
  end if;
  if p_definitions_version is null
     or p_definitions_version not between 1 and app.supported_definitions_version() then
    perform app.bad_input('unsupported definitions_version');
  end if;
  if p_source is null or p_source not in ('app', 'live_activity') then
    perform app.bad_input('invalid source');
  end if;
end;
$$;

-- A line size answer: the usual (value, state) rules, and an answered code
-- must be one its definitions version offers (version 1: 0-5; version 2: 0,
-- 1, 2, 3, 6, 7). Checked before retries too, so a retry can't store a code
-- its version doesn't have.
create function app.check_line_size(p_value smallint, p_state text, p_definitions_version smallint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_codes smallint[] := app.line_size_codes(p_definitions_version);
begin
  perform app.check_answer('line_size', p_value, p_state, 0::smallint, 7::smallint);
  if p_state = 'answered' then
    if v_codes is null then
      perform app.bad_input('unsupported definitions_version');
    end if;
    if p_value <> all (v_codes) then
      perform app.bad_input('line_size: answered needs a valid code');
    end if;
  end if;
end;
$$;

-- Picking a value (FR-18, FR-19) --------------------------------------------------------
-- The shown value for one signal from the reports in [p_since, p_at] (and
-- before p_before when given), or null when there is none:
--   1. Take each person's newest report for the signal in the range, so one
--      person counts once.
--   2. The newest report wins...
--   3. ...unless it is at or after p_fresh_since and disagrees with the
--      reports from p_fresh_since of majority_min_others (2) or more other
--      people. "Disagree" means more than agree_within (1) apart: line sizes
--      by app.line_size_rank (since logic version 4), waits by code. Then the
--      most common rank (line size) or code (wait) among those reports wins,
--      ties going to the most recent; the winner is that rank's or code's
--      newest report, shown with its own code.
-- A value is 'fresh' when it is at or after p_fresh_since, else 'stale'.
create or replace function app.pick_signal_in(p_bar_id bigint, p_signal text, p_since timestamptz,
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
  newest_level smallint;
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
    newest_level := case when p_signal = 'line_size' then app.line_size_rank(newest.code)
                         else newest.code end;

    select count(*) into disagreeing
    from app.signal_people(p_bar_id, p_signal, p_fresh_since, p_at, p_include_test, p_before) p
    where p.anon_id <> newest.anon_id
      and abs(case when p_signal = 'line_size' then app.line_size_rank(p.code) else p.code end
              - newest_level) > agree_within;

    if disagreeing >= min_others then
      with fresh as (
        select f.anon_id, f.at, f.code, f.minutes, f.source,
               case when p_signal = 'line_size' then app.line_size_rank(f.code) else f.code end as level
        from app.signal_people(p_bar_id, p_signal, p_fresh_since, p_at, p_include_test, p_before) f
      ), votes as (
        select f.level, count(*) as n, max(f.at) as last_at
        from fresh f
        group by f.level
      )
      select f.anon_id, f.at, f.code, f.minutes, f.source into winner
      from fresh f
      join votes v on v.level = f.level
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

-- Live estimates (FR-17 to FR-21) --------------------------------------------------------
-- One bar's estimate. `display` tells the app which state to show:
--   estimate         a line size or a wait within 60 minutes (stale ones
--                    grayed out)
--   not_enough_data  neither ("No live reports")
-- The same at every hour. 'closed' and 'outside_hours' are no longer returned
-- (since logic version 3 and 2), but older builds still accept them.
-- `busyness` is always null since logic version 4; the key stays because
-- older builds decode it.
create or replace function app.bar_estimate(p_bar_id bigint, p_at timestamptz, p_include_test boolean)
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
    when coalesce(line_size, wait) is not null then 'estimate'
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
    'busyness', null::jsonb
  );
end;
$$;

-- History (FR-43) --------------------------------------------------------------------------
-- Unchanged from logic version 3 except that `busyness` is always null (the
-- key stays for older builds). One bar's history for one night, as of p_at:
--   start, end  the night day: night_boundary_hour (4 a.m.) Eastern on the
--               night's date to the same hour the next day.
--   points      one per quarter hour of the night day, never after p_at,
--               each covering only its own quarter hour [t, t + 15 minutes)
--               with the live rules (app.pick_signal_in). `people` is how
--               many distinct people reported in that quarter hour.
--   nights      every night with visible data at this bar within
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
           'busyness', null::jsonb
         ) order by g.t), '[]'::jsonb)
  into v_points
  from generate_series(v_start, least(v_end, p_at), interval '15 minutes') as g (t)
  cross join lateral (
    select
      app.pick_signal_in(p_bar_id, 'line_size', g.t, g.t, p_at, g.t + interval '15 minutes', p_include_test)
        as line_size,
      app.pick_signal_in(p_bar_id, 'wait', g.t, g.t, p_at, g.t + interval '15 minutes', p_include_test)
        as wait,
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

-- start_session: Start line timer (FR-6, FR-7, FR-14, FR-46) ------------------------------
-- Unchanged except that the line size is checked against its definitions
-- version (app.check_line_size).

create or replace function public.start_session(
  p_client_session_id    uuid,
  p_client_report_id     uuid,
  p_anon_id              uuid,
  p_install_id           uuid,
  p_bar_id               bigint,
  p_phone_time           timestamptz,
  p_location_status      text,
  p_app_version          text,
  p_definitions_version  smallint,
  p_lat                  double precision default null,
  p_lon                  double precision default null,
  p_accuracy_m           double precision default null,
  p_fix_age_s            double precision default null,
  p_start_offset_minutes smallint default null,
  p_line_size            smallint default null,
  p_line_size_state      text default null,
  p_source               text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing app.wait_sessions%rowtype;
  other    app.wait_sessions%rowtype;
  v_at       timestamptz := app.capped_time(p_phone_time);
  loc      record;
  new_id   bigint;
  wait_for integer;
begin
  if p_client_session_id is null or p_client_report_id is null then
    perform app.bad_input('client_session_id and client_report_id are required');
  end if;
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_line_size(p_line_size, p_line_size_state, p_definitions_version);
  if p_start_offset_minutes is not null and p_start_offset_minutes not between 0 and 90 then
    perform app.bad_input('start_offset_minutes must be between 0 and 90');
  end if;

  -- A retry or a later answer.
  select * into existing from app.wait_sessions ws where ws.client_session_id = p_client_session_id;
  if found then
    if existing.anon_id <> p_anon_id then
      perform app.bad_input('client_session_id belongs to another session');
    end if;
    if p_start_offset_minutes is not null then
      update app.wait_sessions ws set start_offset_minutes = p_start_offset_minutes
      where ws.id = existing.id;
    end if;
    if p_line_size_state is not null then
      update app.reports r set line_size = p_line_size, line_size_state = p_line_size_state
      where r.wait_session_id = existing.id and r.kind = 'line_start';
    end if;
    return jsonb_build_object('ok', true, 'client_session_id', existing.client_session_id,
                              'status', existing.status, 'already_open', false);
  end if;

  perform app.check_bar(p_bar_id);
  perform app.check_report_meta(p_location_status, p_app_version, p_definitions_version, p_source);
  perform app.expire_session_if_due(p_anon_id, v_at);

  select * into other from app.wait_sessions ws
  where ws.anon_id = p_anon_id and ws.status = 'open';

  -- Already in line here: keep that session.
  if found and other.bar_id = p_bar_id then
    return jsonb_build_object('ok', true, 'client_session_id', other.client_session_id,
                              'status', 'open', 'already_open', true);
  end if;

  -- FR-13, with the one exception of a redo (FR-46).
  wait_for := app.rate_limit_wait(p_anon_id, p_bar_id, v_at, 'timed');
  if wait_for > 0 and not app.redo_allowed(p_anon_id, p_bar_id, v_at, 'timed') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited',
                              'retry_after_seconds', wait_for);
  end if;

  -- FR-14: one line at a time; a line at another bar ends the old one.
  if other.id is not null then
    update app.wait_sessions ws
    set status = 'gave_up', ended_by = 'new_line', ended_at = greatest(v_at, ws.started_at)
    where ws.id = other.id;
  end if;

  select * into loc
  from app.locate(p_bar_id, p_location_status, p_lat, p_lon, p_accuracy_m, p_fix_age_s);

  insert into app.wait_sessions (
    client_session_id, anon_id, install_id, bar_id, night_date, started_at,
    start_offset_minutes, distance_start_m, is_test
  ) values (
    p_client_session_id, p_anon_id, p_install_id, p_bar_id, app.night_date(v_at), v_at,
    coalesce(p_start_offset_minutes, 0), loc.distance_m, app.is_test_anon(p_anon_id)
  ) returning id into new_id;

  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    wait_session_id, line_size, line_size_state,
    phone_time, location_status, distance_m, bearing_deg, accuracy_m, fix_age_s,
    uncertain, app_version, definitions_version, source, is_test
  ) values (
    p_client_report_id, p_anon_id, p_install_id, p_bar_id, app.night_date(v_at), 'line', 'line_start',
    new_id, p_line_size, p_line_size_state,
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true, 'client_session_id', p_client_session_id,
                            'status', 'open', 'already_open', false);
end;
$$;

-- update_line_size: a line-size update in an open session (exempt from the
-- rate limit). Re-sending a report ID changes that report's answer.
-- Unchanged except that the line size is checked against its definitions
-- version (app.check_line_size).

create or replace function public.update_line_size(
  p_client_report_id    uuid,
  p_client_session_id   uuid,
  p_anon_id             uuid,
  p_install_id          uuid,
  p_phone_time          timestamptz,
  p_line_size_state     text,
  p_location_status     text,
  p_app_version         text,
  p_definitions_version smallint,
  p_line_size           smallint default null,
  p_lat                 double precision default null,
  p_lon                 double precision default null,
  p_accuracy_m          double precision default null,
  p_fix_age_s           double precision default null,
  p_source              text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing app.reports%rowtype;
  s        app.wait_sessions%rowtype;
  v_at       timestamptz := app.capped_time(p_phone_time);
  loc      record;
begin
  if p_client_report_id is null or p_client_session_id is null then
    perform app.bad_input('client_report_id and client_session_id are required');
  end if;
  if p_line_size_state is null then perform app.bad_input('line_size_state is required'); end if;
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_line_size(p_line_size, p_line_size_state, p_definitions_version);

  select * into existing from app.reports r where r.client_report_id = p_client_report_id;
  if found then
    if existing.anon_id <> p_anon_id or existing.position <> 'line' then
      perform app.bad_input('client_report_id belongs to another report');
    end if;
    update app.reports r set line_size = p_line_size, line_size_state = p_line_size_state
    where r.id = existing.id;
    return jsonb_build_object('ok', true);
  end if;

  perform app.check_report_meta(p_location_status, p_app_version, p_definitions_version, p_source);
  perform app.expire_session_if_due(p_anon_id, v_at);

  select * into s from app.wait_sessions ws
  where ws.client_session_id = p_client_session_id and ws.anon_id = p_anon_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;
  if s.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'session_not_open', 'status', s.status);
  end if;

  select * into loc
  from app.locate(s.bar_id, p_location_status, p_lat, p_lon, p_accuracy_m, p_fix_age_s);

  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    wait_session_id, line_size, line_size_state,
    phone_time, location_status, distance_m, bearing_deg, accuracy_m, fix_age_s,
    uncertain, app_version, definitions_version, source, is_test
  ) values (
    p_client_report_id, p_anon_id, p_install_id, s.bar_id, app.night_date(v_at), 'line', 'line_update',
    s.id, p_line_size, p_line_size_state,
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true);
end;
$$;

-- report_conditions: Report conditions (FR-11, FR-12, FR-13, FR-46) ---------------------
-- Line size, checked against its definitions version. A busyness answer is
-- still accepted from older builds (at least one of the two must be
-- answered, as before), but never stored: the row gets busyness null and
-- busyness_state 'skipped'.
-- Crowd-only: a call without an answered line size returns
-- {"ok": true, "kind": "conditions"} and stores nothing and uses no rate
-- limit, so an older build's queue drops it. Its retry does the same.
-- Otherwise unchanged: the position is unspecified, only the manual clock is
-- checked, a redo (FR-46) deletes the Report conditions it replaces at once,
-- and a retry of a saved report returns the same answer and changes nothing.

create or replace function public.report_conditions(
  p_client_report_id    uuid,
  p_anon_id             uuid,
  p_install_id          uuid,
  p_bar_id              bigint,
  p_phone_time          timestamptz,
  p_location_status     text,
  p_app_version         text,
  p_definitions_version smallint,
  p_lat                 double precision default null,
  p_lon                 double precision default null,
  p_accuracy_m          double precision default null,
  p_fix_age_s           double precision default null,
  p_line_size           smallint default null,
  p_line_size_state     text default null,
  p_busyness            smallint default null,
  p_busyness_state      text default null,
  p_source              text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing     app.reports%rowtype;
  v_at         timestamptz := app.capped_time(p_phone_time);
  loc          record;
  wait_for     integer;
  v_line_state text := coalesce(p_line_size_state, 'skipped');
  v_busy_state text := coalesce(p_busyness_state, 'skipped');
begin
  if p_client_report_id is null then perform app.bad_input('client_report_id is required'); end if;
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_line_size(p_line_size, p_line_size_state, p_definitions_version);
  perform app.check_answer('busyness', p_busyness, p_busyness_state, 1::smallint, 4::smallint);
  if v_line_state <> 'answered' and v_busy_state <> 'answered' then
    perform app.bad_input('report at least one answer');
  end if;

  -- A retry: the report is already saved.
  select * into existing from app.reports r where r.client_report_id = p_client_report_id;
  if found then
    if existing.anon_id <> p_anon_id or existing.kind <> 'conditions' then
      perform app.bad_input('client_report_id belongs to another report');
    end if;
    return jsonb_build_object('ok', true, 'kind', 'conditions');
  end if;

  perform app.check_bar(p_bar_id);
  perform app.check_report_meta(p_location_status, p_app_version, p_definitions_version, p_source);

  -- Crowd-only: busyness is no longer stored, so there is nothing to save.
  if v_line_state <> 'answered' then
    return jsonb_build_object('ok', true, 'kind', 'conditions');
  end if;

  wait_for := app.rate_limit_wait(p_anon_id, p_bar_id, v_at, 'manual');
  if wait_for > 0 then
    if not app.redo_allowed(p_anon_id, p_bar_id, v_at, 'manual') then
      return jsonb_build_object('ok', false, 'error', 'rate_limited',
                                'retry_after_seconds', wait_for);
    end if;

    -- FR-46: replace the earlier Report conditions at once. app.redo_allowed
    -- checked that every report blocking this one is one of these.
    delete from app.reports r
    where r.anon_id = p_anon_id
      and r.bar_id = p_bar_id
      and r.kind = 'conditions'
      and r.phone_time <= v_at
      and v_at - r.phone_time < app.setting_minutes('redo_minutes');
  end if;

  select * into loc
  from app.locate(p_bar_id, p_location_status, p_lat, p_lon, p_accuracy_m, p_fix_age_s);

  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    wait_session_id, line_size, line_size_state, busyness, busyness_state,
    phone_time, location_status, distance_m, bearing_deg, accuracy_m, fix_age_s,
    uncertain, app_version, definitions_version, source, is_test
  ) values (
    p_client_report_id, p_anon_id, p_install_id, p_bar_id, app.night_date(v_at), 'unspecified', 'conditions',
    null, p_line_size, v_line_state, null, 'skipped',
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true, 'kind', 'conditions');
end;
$$;

-- submit_report: I'm inside, and the busyness answer after I'm in ------------------
-- Older builds only. Busyness is never stored: any busyness state sent is
-- saved as busyness null, busyness_state 'skipped'; not sent stays null (not
-- asked).
-- Crowd-only: a call whose busyness is answered and whose recalled wait is not
-- would now save nothing but a skip. Unless it ends a session (FR-15, below),
-- it returns the usual reply ({"ok": true, "kind": "inside" or
-- "inside_after_entry", "session_ended": false, "measured_wait_seconds":
-- null}) and stores no row and uses no rate limit; its retry does the same.
-- Otherwise unchanged: with an open session at this bar, I'm inside counts as
-- I'm in (FR-15) and its row is kept; pass p_client_session_id for the answer
-- that follows I'm in; a plain I'm inside checks only the manual clock.

create or replace function public.submit_report(
  p_client_report_id    uuid,
  p_anon_id             uuid,
  p_install_id          uuid,
  p_bar_id              bigint,
  p_phone_time          timestamptz,
  p_location_status     text,
  p_app_version         text,
  p_definitions_version smallint,
  p_lat                 double precision default null,
  p_lon                 double precision default null,
  p_accuracy_m          double precision default null,
  p_fix_age_s           double precision default null,
  p_busyness            smallint default null,
  p_busyness_state      text default null,
  p_recalled_wait       smallint default null,
  p_recalled_wait_state text default null,
  p_client_session_id   uuid default null,
  p_source              text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing     app.reports%rowtype;
  s            app.wait_sessions%rowtype;
  v_at         timestamptz := app.capped_time(p_phone_time);
  loc          record;
  v_kind       text := 'inside';
  ended        boolean := false;
  wait_s       integer;
  v_busy_state text := case when p_busyness_state is not null then 'skipped' end;
  v_crowd_only boolean := p_busyness_state is not distinct from 'answered'
                          and p_recalled_wait_state is distinct from 'answered';
begin
  if p_client_report_id is null then perform app.bad_input('client_report_id is required'); end if;
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_answer('busyness', p_busyness, p_busyness_state, 1::smallint, 4::smallint);
  perform app.check_answer('recalled_wait', p_recalled_wait, p_recalled_wait_state, 1::smallint, 5::smallint);

  -- A retry or a later answer: update the answers sent (never a busyness value).
  select * into existing from app.reports r where r.client_report_id = p_client_report_id;
  if found then
    if existing.anon_id <> p_anon_id or existing.position <> 'inside' then
      perform app.bad_input('client_report_id belongs to another report');
    end if;
    update app.reports r
    set busyness            = case when p_busyness_state is null then r.busyness end,
        busyness_state      = coalesce(v_busy_state, r.busyness_state),
        recalled_wait       = case when p_recalled_wait_state is null then r.recalled_wait else p_recalled_wait end,
        recalled_wait_state = coalesce(p_recalled_wait_state, r.recalled_wait_state)
    where r.id = existing.id;
    return jsonb_build_object('ok', true, 'kind', existing.kind, 'session_ended', false);
  end if;

  perform app.check_bar(p_bar_id);
  perform app.check_report_meta(p_location_status, p_app_version, p_definitions_version, p_source);
  perform app.expire_session_if_due(p_anon_id, v_at);

  -- Find the session this report belongs to, if any.
  if p_client_session_id is not null then
    select * into s from app.wait_sessions ws
    where ws.client_session_id = p_client_session_id
      and ws.anon_id = p_anon_id and ws.bar_id = p_bar_id;
  else
    select * into s from app.wait_sessions ws
    where ws.anon_id = p_anon_id and ws.bar_id = p_bar_id and ws.status = 'open';
  end if;

  select * into loc
  from app.locate(p_bar_id, p_location_status, p_lat, p_lon, p_accuracy_m, p_fix_age_s);

  if s.id is not null and s.status = 'open' then
    -- FR-15: I'm inside with an open session here counts as I'm in.
    update app.wait_sessions ws
    set status = 'entered', ended_by = 'im_inside',
        ended_at = greatest(v_at, ws.started_at), distance_end_m = loc.distance_m
    where ws.id = s.id
    returning ws.measured_wait_seconds into wait_s;
    v_kind := 'inside_after_entry';
    ended := true;
  elsif s.id is not null and s.status = 'entered'
        and not exists (select 1 from app.reports r
                        where r.wait_session_id = s.id and r.kind = 'inside_after_entry') then
    -- The answer after I'm in: exempt once per session.
    v_kind := 'inside_after_entry';
    if v_crowd_only then
      return jsonb_build_object('ok', true, 'kind', v_kind, 'session_ended', false,
                                'measured_wait_seconds', null);
    end if;
  else
    s := null;
    if v_crowd_only then
      return jsonb_build_object('ok', true, 'kind', v_kind, 'session_ended', false,
                                'measured_wait_seconds', null);
    end if;
    if app.rate_limit_wait(p_anon_id, p_bar_id, v_at, 'manual') > 0 then
      return jsonb_build_object('ok', false, 'error', 'rate_limited',
        'retry_after_seconds', app.rate_limit_wait(p_anon_id, p_bar_id, v_at, 'manual'));
    end if;
  end if;

  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    wait_session_id, busyness, busyness_state, recalled_wait, recalled_wait_state,
    phone_time, location_status, distance_m, bearing_deg, accuracy_m, fix_age_s,
    uncertain, app_version, definitions_version, source, is_test
  ) values (
    p_client_report_id, p_anon_id, p_install_id, p_bar_id, app.night_date(v_at), 'inside', v_kind,
    s.id, null, v_busy_state, p_recalled_wait, p_recalled_wait_state,
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true, 'kind', v_kind, 'session_ended', ended,
                            'measured_wait_seconds', wait_s);
end;
$$;

-- my_recent_reports (FR-41) ------------------------------------------------------------
-- Unchanged except that `busyness` is always null (the key stays for older
-- builds). The person's own reports from the last 24 hours, newest first, at
-- most 100:
--   report  a standalone Report conditions or I'm inside (no wait session)
--   wait    a finished wait (entered, gave_up, or unfinished) with its newest
--           answered line size. Open waits are not listed (FR-39).
-- Answer fields hold the code when answered, else null.

create or replace function public.my_recent_reports(p_anon_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - app.recent_reports_window();
  items  jsonb;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;

  select coalesce(jsonb_agg(i.item order by i.item_at desc, i.item_type, i.item_id desc), '[]'::jsonb)
  into items
  from (
    select u.item, u.item_at, u.item_type, u.item_id
    from (
      select jsonb_build_object(
               'type', 'report',
               'kind', r.kind,
               'client_report_id', r.client_report_id,
               'bar_id', r.bar_id,
               'at', r.phone_time,
               'line_size', r.line_size,
               'busyness', null::jsonb,
               'recalled_wait', r.recalled_wait
             ) as item,
             r.phone_time as item_at,
             'report'::text as item_type,
             r.id as item_id
      from app.reports r
      where r.anon_id = p_anon_id
        and r.wait_session_id is null
        and r.phone_time >= cutoff
      union all
      select jsonb_build_object(
               'type', 'wait',
               'client_session_id', s.client_session_id,
               'bar_id', s.bar_id,
               'at', s.started_at,
               'ended_at', s.ended_at,
               'status', s.status,
               'measured_wait_seconds', s.measured_wait_seconds,
               'start_offset_minutes', s.start_offset_minutes,
               -- The newest answered line size in the wait.
               'line_size', (select r.line_size
                             from app.reports r
                             where r.wait_session_id = s.id
                               and r.kind in ('line_start', 'line_update')
                               and r.line_size is not null
                             order by r.phone_time desc, r.id desc
                             limit 1),
               'busyness', null::jsonb
             ),
             s.started_at,
             'wait'::text,
             s.id
      from app.wait_sessions s
      where s.anon_id = p_anon_id
        and s.status <> 'open'
        and s.started_at >= cutoff
    ) u
    order by u.item_at desc, u.item_type, u.item_id desc
    limit 100
  ) i;

  return items;
end;
$$;

-- Grants -------------------------------------------------------------------------------------
-- New app functions get EXECUTE for PUBLIC by default; take it away.
-- create or replace keeps an existing function's owner and grants; restate the
-- lockdown anyway so this migration leaves them exactly as the API expects.

revoke all on all functions in schema app from public, anon, authenticated;

revoke all on function public.start_session(
  uuid, uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, smallint, text, text
) from public, anon, authenticated;
grant execute on function public.start_session(
  uuid, uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, smallint, text, text
) to anon;

revoke all on function public.update_line_size(
  uuid, uuid, uuid, uuid, timestamptz, text, text, text, smallint, smallint,
  double precision, double precision, double precision, double precision, text
) from public, anon, authenticated;
grant execute on function public.update_line_size(
  uuid, uuid, uuid, uuid, timestamptz, text, text, text, smallint, smallint,
  double precision, double precision, double precision, double precision, text
) to anon;

revoke all on function public.report_conditions(
  uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, text, smallint, text, text
) from public, anon, authenticated;
grant execute on function public.report_conditions(
  uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, text, smallint, text, text
) to anon;

revoke all on function public.submit_report(
  uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, text, smallint, text, uuid, text
) from public, anon, authenticated;
grant execute on function public.submit_report(
  uuid, uuid, uuid, bigint, timestamptz, text, text, smallint,
  double precision, double precision, double precision, double precision,
  smallint, text, smallint, text, uuid, text
) to anon;

revoke all on function public.my_recent_reports(uuid) from public, anon, authenticated;
grant execute on function public.my_recent_reports(uuid) to anon;
