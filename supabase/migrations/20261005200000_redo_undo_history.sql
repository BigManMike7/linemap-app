-- Redo (FR-46), Undo (FR-47), and bar history (FR-43). M4, 2026-10-05.
--
-- Data model changes:
--   - New setting redo_minutes (5) in app.config, logged in config_history
--     by the usual trigger. No table, column, index, answer code, report
--     kind, or position changes.
--   - New internal functions: app.redo_allowed, app.delete_replaced_sessions,
--     app.history.
--   - start_session, report_conditions, and end_session are redefined with
--     identical signatures and return shapes.
--   - New API functions: reopen_session (Undo) and bar_history (History &
--     details). The app may now call 15 functions; with submit_report (older
--     builds) the API has 16.
--
-- Redo (FR-46): a person can replace their own last attempt at a bar within
-- redo_minutes instead of being refused by the rate limit (FR-13).
--   Timers (timed clock): a new Start line timer is allowed when the timer it
--     would replace stopped (I'm in or Gave up) less than redo_minutes before
--     the new start. The earlier timer is deleted only when the new one
--     finishes through end_session (I'm in or Gave up), with all its reports.
--     If the new one is cancelled (FR-39), times out (FR-10), or is closed by a
--     line at another bar (FR-14), the earlier one stays.
--   Report conditions (manual clock): a new report is allowed when the one it
--     would replace was sent less than redo_minutes before it, and replaces it
--     at once.
--   A report or wait already deleted with delete_report (FR-41) left a
--     rate-limit hold with the deleted item's phone time (for a wait, its
--     start). A hold of kind line_start or conditions counts the same way: it
--     can be redone while its phone time is less than redo_minutes before the
--     new one's. Nothing is left to replace, so nothing more is deleted.
--   Replaced attempts are deleted like a cancelled line: no deletion count and
--   no rate-limit hold. The newest attempt keeps the clock running.
--   I'm inside (older builds, kind inside) is never redone or replaced: it
--   blocks the manual clock for the full rate_limit_minutes, as before, and
--   submit_report is unchanged.
--
-- Undo (FR-47): reopen_session reopens the person's own timer that stopped
-- (I'm in or Gave up) less than redo_minutes ago, if no other timer of theirs
-- is open.
--
-- History (FR-43): bar_history computes a bar's estimate as of every 5 minutes
-- of one night's usual window from the reports, so deleted, replaced, and
-- hidden reports never appear.

-- Setting ------------------------------------------------------------------------------

insert into app.config (key, value, description) values
  ('redo_minutes', '5',
   'A person can redo their own last timer or Report conditions at a bar within this many minutes instead of being refused by the rate limit (FR-46), and Undo works this long after a timer stops (FR-47).');

-- Redo check (FR-46) ---------------------------------------------------------------------
-- Called only when rate_limit_wait says a clock is blocked. Says whether the
-- new attempt at p_at is a redo, which the rate limit lets through.
--
-- The blockers are exactly what rate_limit_wait counts on this clock: the
-- person's reports and holds at this bar within rate_limit_minutes of p_at,
-- in either direction. An item "can be replaced" when:
--   line_start report  its timer ended as entered or gave_up, at or before
--                      p_at and less than redo_minutes before it
--   conditions report  its phone time is at or before p_at and less than
--                      redo_minutes before it
--   line_start or conditions hold
--                      the same, by the hold's phone time
--   inside report or hold (older builds)
--                      never
-- It is a redo when the newest blocker can be replaced, every blocking report
-- can be replaced (so the ones the new attempt replaces are all the ones that
-- count), and no blocker is an inside item or later than p_at (so a late
-- offline retry never replaces something newer). Older holds of a replaceable
-- kind may sit further back: they count nowhere but the rate limit, so a
-- chain of redos can pass them.

create function app.redo_allowed(p_anon_id uuid, p_bar_id bigint, p_at timestamptz, p_clock text)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_limit interval := app.setting_minutes('rate_limit_minutes');
  v_redo  interval := app.setting_minutes('redo_minutes');
  v_kinds text[];
  v_ok    boolean;
begin
  v_kinds := case p_clock
               when 'timed'  then array['line_start']
               when 'manual' then array['inside', 'conditions']
             end;
  if v_kinds is null then
    perform app.bad_input('unknown rate-limit clock: ' || coalesce(p_clock, 'null'));
  end if;

  with blockers as (
    select r.phone_time,
           false as is_hold,
           r.kind in ('line_start', 'conditions') as replaceable_kind,
           -- When the attempt stopped: a timer when it ended, a report when sent.
           case when r.kind = 'line_start'
                then case when s.status in ('entered', 'gave_up') then s.ended_at end
                else r.phone_time
           end as done_at
    from app.reports r
    left join app.wait_sessions s on s.id = r.wait_session_id
    where r.anon_id = p_anon_id
      and r.bar_id = p_bar_id
      and r.kind = any (v_kinds)
      and r.phone_time > p_at - v_limit
      and r.phone_time < p_at + v_limit
    union all
    select h.phone_time, true, h.kind in ('line_start', 'conditions'), h.phone_time
    from app.rate_limit_holds h
    where h.anon_id = p_anon_id
      and h.bar_id = p_bar_id
      and h.kind = any (v_kinds)
      and h.phone_time > p_at - v_limit
      and h.phone_time < p_at + v_limit
  ), judged as (
    select b.phone_time,
           b.is_hold,
           b.replaceable_kind and b.phone_time <= p_at as may_pass,
           coalesce(b.replaceable_kind
                    and b.phone_time <= p_at
                    and b.done_at <= p_at
                    and p_at - b.done_at < v_redo, false) as in_redo
    from blockers b
  )
  select bool_and(case when j.is_hold then j.may_pass else j.in_redo end)
         and (array_agg(j.in_redo order by j.phone_time desc, j.is_hold))[1]
  into v_ok
  from judged j;

  return coalesce(v_ok, false);
end;
$$;

-- Replaced timers (FR-46) ------------------------------------------------------------------
-- When a timer finishes (I'm in or Gave up through end_session), deletes the
-- same person's earlier timers at the same bar that it redid: those that
-- ended as entered or gave_up at or before its start, less than redo_minutes
-- before it, with every report in them. Exactly the timers app.redo_allowed
-- treats as replaceable. Not logged in app.deletions and leaves no hold, like
-- a cancelled line (FR-39). Returns the number of timers deleted.

create function app.delete_replaced_sessions(p_session_id bigint)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_redo interval := app.setting_minutes('redo_minutes');
  v_ids  bigint[];
begin
  select coalesce(array_agg(o.id), '{}'::bigint[])
  into v_ids
  from app.wait_sessions s
  join app.wait_sessions o
    on o.anon_id = s.anon_id
   and o.bar_id = s.bar_id
   and o.id <> s.id
  where s.id = p_session_id
    and o.status in ('entered', 'gave_up')
    and o.ended_at <= s.started_at
    and s.started_at - o.ended_at < v_redo;

  -- Reports first: they reference the session.
  delete from app.reports r where r.wait_session_id = any (v_ids);
  delete from app.wait_sessions ws where ws.id = any (v_ids);
  return cardinality(v_ids);
end;
$$;

-- start_session: Start line timer (FR-6, FR-7, FR-14, FR-46) ------------------------------
-- Creates the session and its line_start report. Re-sending the same session
-- ID sets Adjust time (0 to 90 minutes) or the first line-size answer.
-- Checks only the timed clock (FR-13), and lets a redo through (FR-46): the
-- earlier timer stays until this one finishes (see end_session).

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
  perform app.check_answer('line_size', p_line_size, p_line_size_state, 0::smallint, 5::smallint);
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

-- end_session: I'm in (FR-8) or Gave up (FR-9) ----------------------------------------
-- Past the timeout, the session is unfinished and I'm in does nothing (FR-10).
-- Ending an already-ended session returns its state unchanged.
-- When it does end the session, any earlier timer at the same bar that this
-- one redid is deleted now (FR-46).

create or replace function public.end_session(
  p_client_session_id uuid,
  p_anon_id           uuid,
  p_outcome           text,
  p_phone_time        timestamptz,
  p_location_status   text default 'no_fix',
  p_lat               double precision default null,
  p_lon               double precision default null,
  p_accuracy_m        double precision default null,
  p_fix_age_s         double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s   app.wait_sessions%rowtype;
  v_at  timestamptz := app.capped_time(p_phone_time);
  loc record;
begin
  if p_client_session_id is null then perform app.bad_input('client_session_id is required'); end if;
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  if p_outcome is null or p_outcome not in ('entered', 'gave_up') then
    perform app.bad_input('outcome must be entered or gave_up');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));
  perform app.expire_session_if_due(p_anon_id, v_at);

  select * into s from app.wait_sessions ws
  where ws.client_session_id = p_client_session_id and ws.anon_id = p_anon_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found');
  end if;

  -- An offline I'm in that happened before the timeout still counts, even if
  -- the expire job got there first (FR-16).
  if s.status = 'open'
     or (s.status = 'unfinished' and s.ended_by = 'timeout'
         and v_at < s.started_at + app.setting_minutes('session_timeout_minutes')) then
    select * into loc
    from app.locate(s.bar_id, coalesce(p_location_status, 'no_fix'),
                    p_lat, p_lon, p_accuracy_m, p_fix_age_s);
    update app.wait_sessions ws
    set status = p_outcome,
        ended_by = case p_outcome when 'entered' then 'im_in' else 'gave_up' end,
        ended_at = greatest(v_at, ws.started_at),
        distance_end_m = loc.distance_m
    where ws.id = s.id
    returning * into s;

    -- FR-46: only the newest attempt counts.
    perform app.delete_replaced_sessions(s.id);
  end if;

  return jsonb_build_object('ok', true, 'status', s.status,
                            'measured_wait_seconds', s.measured_wait_seconds);
end;
$$;

-- report_conditions: Report conditions (FR-11, FR-12, FR-13, FR-46) ---------------------
-- Two optional answers, line size and busyness; at least one must be
-- answered. A state not sent is stored as skipped. The reporter may be in
-- line, inside, or walking by, so the position is unspecified. Checks only the
-- manual clock, and never starts, ends, or joins a wait session.
-- A redo (FR-46) is let through and deletes the Report conditions it replaces
-- at once: no deletion count, no hold.
-- Re-sending a report ID returns the same answer and changes nothing; it is
-- found before the rate limit, so it is never treated as a redo of itself.

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
  perform app.check_answer('line_size', p_line_size, p_line_size_state, 0::smallint, 5::smallint);
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
    null, p_line_size, v_line_state, p_busyness, v_busy_state,
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true, 'kind', 'conditions');
end;
$$;

-- reopen_session: Undo after I'm in or Gave up (FR-47) ------------------------------------
-- Reopens the person's own timer as if it had never stopped: same start time
-- and Adjust time; the end, what ended it, the distance at the end, and so the
-- measured wait are cleared. end_session creates no reports, so none are
-- removed. Allowed only when the timer
--   - ended through end_session (I'm in or Gave up; not by a new line at
--     another bar, I'm inside from older builds, or the timeout),
--   - ended less than redo_minutes ago by server time, and
--   - is the person's only timer that would be open.
-- A reopened timer older than session_timeout_minutes becomes unfinished at
-- the next expire job, as usual (FR-10). Earlier timers its finish already
-- replaced (FR-46) stay deleted.
-- Returns
--   {"ok": true, "status": "open", "reopened": true}    reopened
--   {"ok": true, "status": "open", "reopened": false}   already open (a retry)
--   {"ok": true, "reopened": false, "removed": true}    no such timer for this
--       person (never reached the server, deleted, or someone else's), so the
--       offline queue can drop it
--   {"ok": false, "error": "too_late"}
--   {"ok": false, "error": "other_session_open"}
--   {"ok": false, "error": "session_not_reopenable", "status": "..."}

create function public.reopen_session(
  p_client_session_id uuid,
  p_anon_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s app.wait_sessions%rowtype;
begin
  if p_client_session_id is null or p_anon_id is null then
    perform app.bad_input('client_session_id and anon_id are required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));
  -- A timer past the timeout is unfinished, not open (FR-10).
  perform app.expire_session_if_due(p_anon_id, now());

  select * into s from app.wait_sessions ws
  where ws.client_session_id = p_client_session_id and ws.anon_id = p_anon_id;
  if not found then
    return jsonb_build_object('ok', true, 'reopened', false, 'removed', true);
  end if;
  if s.status = 'open' then
    return jsonb_build_object('ok', true, 'status', 'open', 'reopened', false);
  end if;
  if s.status not in ('entered', 'gave_up') or s.ended_by not in ('im_in', 'gave_up') then
    return jsonb_build_object('ok', false, 'error', 'session_not_reopenable', 'status', s.status);
  end if;
  if now() - s.ended_at >= app.setting_minutes('redo_minutes') then
    return jsonb_build_object('ok', false, 'error', 'too_late');
  end if;
  if exists (select 1 from app.wait_sessions ws
             where ws.anon_id = p_anon_id and ws.status = 'open') then
    return jsonb_build_object('ok', false, 'error', 'other_session_open');
  end if;

  -- measured_wait_seconds is generated, so it clears with the status.
  update app.wait_sessions ws
  set status = 'open', ended_at = null, ended_by = null, distance_end_m = null
  where ws.id = s.id;

  return jsonb_build_object('ok', true, 'status', 'open', 'reopened', true);
end;
$$;

-- History (FR-43) ---------------------------------------------------------------------
-- One bar's history for one night, as of p_at:
--   start, end  the night's usual window from active_window_start to
--               active_window_end (Eastern, so daylight saving is handled;
--               an end at or before the start is the next day). Event-night
--               windows (FR-23) are not used: every chart covers the same hours.
--   points      every 5 minutes from start through end, never after p_at, each
--               the bar's estimate as of that moment by the live rules
--               (app.bar_estimate): only combined values, no IDs or report
--               times. Deleted, replaced, and hidden reports are not in the
--               tables the rules read, so they never appear.
--   nights      every night with visible data at this bar (reports not
--               hidden, or finished waits that ended as entered) within
--               retention_days, newest first.
-- p_night null means tonight. Test rows count only when p_include_test.

create function app.history(p_bar_id bigint, p_night date, p_at timestamptz, p_include_test boolean)
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
  v_cutoff    date := app.night_date(p_at) - app.setting_int('retention_days');
  v_start     timestamptz;
  v_end       timestamptz;
  v_nights    jsonb;
  v_points    jsonb;
begin
  v_start := app.eastern(v_night, v_win_start);
  v_end := app.eastern(case when v_win_end <= v_win_start then v_night + 1 else v_night end, v_win_end);

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
  from generate_series(v_start, least(v_end, p_at), interval '5 minutes') as g (t)
  cross join lateral (
    select app.bar_estimate(p_bar_id, g.t, p_include_test, 'live') as v
  ) e;

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

-- bar_history: History & details (FR-43) ---------------------------------------------------
-- p_bar_id is required and must be an active bar this caller can see (test
-- bars only for test IDs). p_night defaults to tonight. Test rows count only
-- for test IDs, as in get_estimates. Read-only.

create function public.bar_history(
  p_anon_id uuid default null,
  p_bar_id  bigint default null,
  p_night   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_test boolean := p_anon_id is not null and app.is_test_anon(p_anon_id);
begin
  if p_bar_id is null
     or not exists (select 1 from app.bars b
                    where b.id = p_bar_id and b.active and (v_test or not b.is_test)) then
    perform app.bad_input('unknown bar');
  end if;
  return app.history(p_bar_id, p_night, now(), v_test);
end;
$$;

-- Grants ----------------------------------------------------------------------------
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

revoke all on function public.end_session(
  uuid, uuid, text, timestamptz, text,
  double precision, double precision, double precision, double precision
) from public, anon, authenticated;
grant execute on function public.end_session(
  uuid, uuid, text, timestamptz, text,
  double precision, double precision, double precision, double precision
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

revoke all on function public.reopen_session(uuid, uuid) from public, anon, authenticated;
grant execute on function public.reopen_session(uuid, uuid) to anon;

revoke all on function public.bar_history(uuid, bigint, date) from public, anon, authenticated;
grant execute on function public.bar_history(uuid, bigint, date) to anon;
