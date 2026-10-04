-- Two separate rate-limit clocks (FR-13, approved 2026-10-04).
--
-- Until now one clock per person per bar covered every counted report. Now
-- there are two, each rate_limit_minutes long, by phone time:
--   timed   line_start (I'm in line). Checked by start_session.
--   manual  conditions (Report conditions) and inside (I'm inside, older
--           builds). Checked by report_conditions and submit_report.
-- A manual report never blocks starting a line, and a line never blocks a
-- manual report. line_update and inside_after_entry stay exempt.
--
-- Data model changes:
--   - New column app.rate_limit_holds.kind: the deleted report's kind, so a
--     hold counts on the same clock the report did. Holds already there (at
--     most 10 minutes old) can't know their kind; they become 'conditions'.
--   - app.rate_limit_wait takes a fourth parameter, p_clock ('timed' or
--     'manual'). The 3-parameter version is dropped.
--   - start_session, report_conditions, submit_report, and delete_report are
--     redefined with identical signatures; only the rate-limit lines change.
-- No answer code, report kind, or position changes meaning.

-- Holds carry their kind ----------------------------------------------------------

alter table app.rate_limit_holds add column kind text;

update app.rate_limit_holds set kind = 'conditions' where kind is null;

alter table app.rate_limit_holds
  alter column kind set not null,
  add constraint rate_limit_holds_kind_check
    check (kind in ('line_start', 'inside', 'conditions'));

comment on table app.rate_limit_holds is
  'Bar, kind, and phone time of each counted report deleted with delete_report (FR-41), so its rate-limit clock (FR-13) keeps running from it. Expired every 5 minutes once older than rate_limit_minutes.';
comment on column app.rate_limit_holds.kind is
  'Kind of the deleted report: line_start (timed clock), or inside or conditions (manual clock). Holds that existed when this column was added (2026-10-04) were set to conditions.';

comment on column app.reports.kind is
  'What the report was, which decides the rate limit (FR-13): line_start (I''m in line, timed clock), line_update (line size in an open session, exempt), inside (I''m inside, manual clock), inside_after_entry (busyness after I''m in, or I''m inside that ended a session, exempt), conditions (Report conditions, manual clock; added 2026-10-04). One shared clock before 2026-10-04.';

-- Rate limit (FR-13) ---------------------------------------------------------------
-- One report per clock per bar per rate_limit_minutes per person, by phone
-- time. p_clock picks the clock:
--   timed   line_start
--   manual  inside, conditions
-- A hold left by a deleted report (FR-41) counts on its kind's clock exactly
-- like the report did. Returns seconds to wait, or 0. An unknown clock is bad
-- input.

create function app.rate_limit_wait(p_anon_id uuid, p_bar_id bigint, p_at timestamptz, p_clock text)
returns integer
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_kinds text[];
  v_limit interval := app.setting_minutes('rate_limit_minutes');
  v_wait  integer;
begin
  v_kinds := case p_clock
               when 'timed'  then array['line_start']
               when 'manual' then array['inside', 'conditions']
             end;
  if v_kinds is null then
    perform app.bad_input('unknown rate-limit clock: ' || coalesce(p_clock, 'null'));
  end if;

  select coalesce(max(ceil(extract(epoch from v_limit - g.abs_gap))::integer), 0)
  into v_wait
  from (
    select case when t.phone_time > p_at then t.phone_time - p_at
                else p_at - t.phone_time end as abs_gap
    from (
      select r.phone_time
      from app.reports r
      where r.anon_id = p_anon_id
        and r.bar_id = p_bar_id
        and r.kind = any (v_kinds)
      union all
      select h.phone_time
      from app.rate_limit_holds h
      where h.anon_id = p_anon_id
        and h.bar_id = p_bar_id
        and h.kind = any (v_kinds)
    ) t
  ) g
  where g.abs_gap < v_limit;

  return v_wait;
end;
$$;

-- start_session: I'm in line (FR-6, FR-7, FR-14) --------------------------------------
-- Creates the session and its line_start report. Re-sending the same session
-- ID sets Adjust time (0 to 90 minutes) or the first line-size answer.
-- Checks only the timed clock (FR-13).

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

  wait_for := app.rate_limit_wait(p_anon_id, p_bar_id, v_at, 'timed');
  if wait_for > 0 then
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

-- report_conditions: Report conditions (FR-11, FR-12, FR-13) ---------------------------
-- Replaces I'm inside in the app as of 2026-10-04. Two optional answers, line
-- size and busyness; at least one must be answered. A state not sent is stored
-- as skipped. The reporter may be in line, inside, or walking by, so the
-- position is unspecified. Checks only the manual clock, and never starts,
-- ends, or joins a wait session, even an open one at the same bar.
-- Re-sending a report ID returns the same answer and changes nothing.

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
    return jsonb_build_object('ok', false, 'error', 'rate_limited',
                              'retry_after_seconds', wait_for);
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

-- submit_report: I'm inside, and the busyness answer after I'm in ------------------
-- Older builds only. With an open session at this bar, I'm inside counts as
-- I'm in (FR-15). Pass p_client_session_id for the busyness answer that
-- follows I'm in. A plain I'm inside checks only the manual clock.

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
  existing app.reports%rowtype;
  s        app.wait_sessions%rowtype;
  v_at       timestamptz := app.capped_time(p_phone_time);
  loc      record;
  v_kind   text := 'inside';
  ended    boolean := false;
  wait_s   integer;
begin
  if p_client_report_id is null then perform app.bad_input('client_report_id is required'); end if;
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_answer('busyness', p_busyness, p_busyness_state, 1::smallint, 4::smallint);
  perform app.check_answer('recalled_wait', p_recalled_wait, p_recalled_wait_state, 1::smallint, 5::smallint);

  -- A retry or a later answer: update the answers sent.
  select * into existing from app.reports r where r.client_report_id = p_client_report_id;
  if found then
    if existing.anon_id <> p_anon_id or existing.position <> 'inside' then
      perform app.bad_input('client_report_id belongs to another report');
    end if;
    update app.reports r
    set busyness            = case when p_busyness_state is null then r.busyness else p_busyness end,
        busyness_state      = coalesce(p_busyness_state, r.busyness_state),
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
    -- The busyness answer after I'm in: exempt once per session.
    v_kind := 'inside_after_entry';
  else
    s := null;
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
    s.id, p_busyness, p_busyness_state, p_recalled_wait, p_recalled_wait_state,
    v_at, p_location_status, loc.distance_m, loc.bearing_deg, p_accuracy_m, p_fix_age_s,
    loc.uncertain, p_app_version, p_definitions_version, p_source, app.is_test_anon(p_anon_id)
  );

  return jsonb_build_object('ok', true, 'kind', v_kind, 'session_ended', ended,
                            'measured_wait_seconds', wait_s);
end;
$$;

-- delete_report (FR-41) ----------------------------------------------------------------
-- Deletes one item from my_recent_reports: pass exactly one of
--   p_client_report_id   a standalone report (Report conditions or I'm inside)
--   p_client_session_id  a finished wait, with every report in it
-- Only the person's own, from the last 24 hours. Anything else, including a
-- second delete of the same item, is not_found, which never says whether the
-- item exists for someone else. An open wait returns session_open; the wait
-- card cancels it instead (FR-39).
-- Each counted report deleted leaves a rate-limit hold with its kind, so it
-- keeps counting on its own clock. The deletion is logged as a count with
-- scope 'one', never an ID.

create or replace function public.delete_report(
  p_anon_id           uuid,
  p_client_report_id  uuid default null,
  p_client_session_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - app.recent_reports_window();
  r      app.reports%rowtype;
  s      app.wait_sessions%rowtype;
  n      integer;
  total  integer := 0;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  if (p_client_report_id is null) = (p_client_session_id is null) then
    perform app.bad_input('send exactly one of client_report_id and client_session_id');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));

  if p_client_report_id is not null then
    -- A report inside a wait is deleted with its wait, never on its own.
    select * into r from app.reports x
    where x.client_report_id = p_client_report_id
      and x.anon_id = p_anon_id
      and x.wait_session_id is null
      and x.phone_time >= cutoff;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;

    -- Keep the report's rate-limit clock running from it (FR-13).
    insert into app.rate_limit_holds (anon_id, bar_id, kind, phone_time, is_test)
    select x.anon_id, x.bar_id, x.kind, x.phone_time, x.is_test
    from app.reports x
    where x.id = r.id
      and x.kind in ('line_start', 'inside', 'conditions');

    delete from app.reports x where x.id = r.id;
    get diagnostics n = row_count; total := total + n;
  else
    -- A wait past the timeout is unfinished, not open (FR-10).
    perform app.expire_session_if_due(p_anon_id, now());

    select * into s from app.wait_sessions ws
    where ws.client_session_id = p_client_session_id
      and ws.anon_id = p_anon_id
      and ws.started_at >= cutoff;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    if s.status = 'open' then
      return jsonb_build_object('ok', false, 'error', 'session_open');
    end if;

    -- Keep the timed clock running from the wait's I'm in line (FR-13).
    insert into app.rate_limit_holds (anon_id, bar_id, kind, phone_time, is_test)
    select x.anon_id, x.bar_id, x.kind, x.phone_time, x.is_test
    from app.reports x
    where x.wait_session_id = s.id
      and x.kind in ('line_start', 'inside', 'conditions');

    -- Reports first: they reference the session.
    delete from app.reports x where x.wait_session_id = s.id;
    get diagnostics n = row_count; total := total + n;
    delete from app.wait_sessions ws where ws.id = s.id;
    get diagnostics n = row_count; total := total + n;
  end if;

  insert into app.deletions (reason, scope, rows_removed, is_test)
  values ('user_request', 'one', total, app.is_test_anon(p_anon_id));

  return jsonb_build_object('ok', true, 'rows_removed', total);
end;
$$;

-- The old one-clock rate limit ---------------------------------------------------------
-- Every caller above now passes a clock, so nothing calls the 3-parameter
-- version any more.

drop function app.rate_limit_wait(uuid, bigint, timestamptz);

-- Grants ----------------------------------------------------------------------------
-- New app functions get EXECUTE for PUBLIC by default; take it away.
-- create or replace keeps an existing function's owner and grants; restate the
-- lockdown anyway so this migration leaves them exactly as the API expects.

revoke all on all functions in schema app from public, anon, authenticated;
revoke all on function app.rate_limit_wait(uuid, bigint, timestamptz, text) from public, anon, authenticated;

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

revoke all on function public.delete_report(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_report(uuid, uuid, uuid) to anon;
