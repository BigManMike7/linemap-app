-- Report conditions, and Adjust time in whole minutes (approved 2026-10-04).
--
-- 1. A new report kind, `conditions`, with position `unspecified`. In the app,
--    "Report conditions" replaces I'm inside on the bar sheet: two optional
--    answers, line size and busyness, from someone who may be in line, inside,
--    or walking by. It is rate-limited like I'm in line and I'm inside, and it
--    never touches a wait session. Existing kinds, positions, and answer codes
--    keep their meaning; submit_report stays for older builds.
-- 2. Adjust time (FR-7) takes any whole number of minutes from 0 to 90,
--    instead of only 0, 5, 10, or 20.

-- Table checks ------------------------------------------------------------------
-- The checks being replaced were declared inline without names, so Postgres
-- named them (reports_position_check, reports_kind_check, reports_check4,
-- wait_sessions_start_offset_minutes_check). Look each one up by the exact
-- set of columns it covers instead of trusting the generated name; `strict`
-- fails the migration if a lookup finds none or more than one.

do $$
declare
  chk record;
  v_name name;
begin
  for chk in
    select t.rel, t.cols
    from (values
      ('app.reports'::regclass,       array['position']),
      ('app.reports'::regclass,       array['kind']),
      ('app.reports'::regclass,       array['kind', 'wait_session_id']),
      ('app.wait_sessions'::regclass, array['start_offset_minutes'])
    ) as t (rel, cols)
  loop
    select c.conname into strict v_name
    from pg_constraint c
    where c.conrelid = chk.rel
      and c.contype = 'c'
      and (select array_agg(a.attname::text order by a.attname::text)
           from pg_attribute a
           where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) = chk.cols;

    execute format('alter table %s drop constraint %I', chk.rel, v_name);
  end loop;
end;
$$;

alter table app.reports
  add constraint reports_position_check
    check (position in ('line', 'inside', 'unspecified')),
  add constraint reports_kind_check
    check (kind in ('line_start', 'line_update', 'inside', 'inside_after_entry', 'conditions')),
  -- Only line reports and busyness-after-I'm-in belong to a session.
  add constraint reports_session_matches_kind
    check ((wait_session_id is null) = (kind in ('inside', 'conditions'))),
  -- A conditions report, and only a conditions report, has no known position.
  add constraint reports_unspecified_is_conditions
    check ((position = 'unspecified') = (kind = 'conditions'));

alter table app.wait_sessions
  add constraint wait_sessions_start_offset_minutes_check
    check (start_offset_minutes between 0 and 90);

comment on column app.reports.position is
  'Where the reporter was: line, inside, or unspecified (Report conditions, which may come from in line, inside, or walking by).';
comment on column app.reports.kind is
  'What the report was, which decides the rate limit (FR-13): line_start (I''m in line, counted), line_update (line size in an open session, exempt), inside (I''m inside, counted), inside_after_entry (busyness after I''m in, or I''m inside that ended a session, exempt), conditions (Report conditions, counted; added 2026-10-04).';
comment on column app.wait_sessions.start_offset_minutes is
  'Adjust time (FR-7): whole minutes, 0 to 90, to move the start back.';

-- Rate limit (FR-13) ---------------------------------------------------------------
-- One counted report (line_start, inside, or conditions) per bar per
-- rate_limit_minutes per person, by phone time. Returns seconds to wait, or 0.

create or replace function app.rate_limit_wait(p_anon_id uuid, p_bar_id bigint, p_at timestamptz)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(max(ceil(extract(epoch from
           app.setting_minutes('rate_limit_minutes') - abs_gap))::integer), 0)
  from (
    select case when r.phone_time > p_at then r.phone_time - p_at
                else p_at - r.phone_time end as abs_gap
    from app.reports r
    where r.anon_id = p_anon_id
      and r.bar_id = p_bar_id
      and r.kind in ('line_start', 'inside', 'conditions')
  ) g
  where g.abs_gap < app.setting_minutes('rate_limit_minutes')
$$;

-- start_session: I'm in line (FR-6, FR-7, FR-14) --------------------------------------
-- Creates the session and its line_start report. Re-sending the same session
-- ID sets Adjust time (0 to 90 minutes) or the first line-size answer.

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

  wait_for := app.rate_limit_wait(p_anon_id, p_bar_id, v_at);
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
-- position is unspecified. Counts toward the rate limit, and never starts,
-- ends, or joins a wait session, even an open one at the same bar.
-- Re-sending a report ID returns the same answer and changes nothing.

create function public.report_conditions(
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

  wait_for := app.rate_limit_wait(p_anon_id, p_bar_id, v_at);
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

-- create or replace keeps each function's owner and grants; restate the
-- lockdown anyway so this migration leaves them exactly as the API expects.
revoke all on function app.rate_limit_wait(uuid, bigint, timestamptz) from public, anon, authenticated;
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
