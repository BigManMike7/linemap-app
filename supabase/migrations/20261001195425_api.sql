-- The app's API (PRD 7.2): the only functions the `anon` role may call.
--
-- Each is SECURITY DEFINER, so it runs as its owner and can reach the private
-- `app` schema, and has an empty search_path with fully qualified names, so a
-- caller cannot redirect it to other objects. EXECUTE is revoked from everyone
-- and granted back to `anon` only (bottom of file).
--
-- Identity is the anonymous ID passed in (no Supabase Auth). Writes for one ID
-- are serialized with an advisory lock, so the rate limit and the
-- one-open-session rule hold under concurrent calls.
--
-- Bad input raises SQLSTATE 22023 (HTTP 400). Expected refusals, such as the
-- rate limit, return {"ok": false, "error": "..."}.
--
-- Retries are safe: reports and sessions are keyed by client-generated IDs
-- (FR-16). Re-sending a report ID updates its answers, which is also how each
-- answer is saved as soon as it is given (FR-12).

-- Validation helpers ------------------------------------------------------------

create function app.bad_input(p_message text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception using errcode = '22023', message = p_message;
end;
$$;

create function app.check_identity(p_anon_id uuid, p_install_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  if p_install_id is null then perform app.bad_input('install_id is required'); end if;
  -- One writer per person at a time.
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));
end;
$$;

create function app.check_bar(p_bar_id bigint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not exists (select 1 from app.bars b where b.id = p_bar_id and b.active) then
    perform app.bad_input('unknown bar');
  end if;
end;
$$;

create function app.check_report_meta(p_location_status text, p_app_version text,
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
  if p_definitions_version is distinct from app.supported_definitions_version() then
    perform app.bad_input('unsupported definitions_version');
  end if;
  if p_source is null or p_source not in ('app', 'live_activity') then
    perform app.bad_input('invalid source');
  end if;
end;
$$;

-- An answer is a (value, state) pair. A null state means "not sent".
create function app.check_answer(p_name text, p_value smallint, p_state text,
                                 p_min smallint, p_max smallint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_state is null then
    if p_value is not null then
      perform app.bad_input(p_name || ': value sent without a state');
    end if;
  elsif p_state = 'answered' then
    if p_value is null or p_value not between p_min and p_max then
      perform app.bad_input(p_name || ': answered needs a valid code');
    end if;
  elsif p_state in ('cant_tell', 'skipped') then
    if p_value is not null then
      perform app.bad_input(p_name || ': ' || p_state || ' takes no value');
    end if;
  else
    perform app.bad_input(p_name || ': invalid state');
  end if;
end;
$$;

-- Rate limit (FR-13): one counted report (line_start or inside) per bar per
-- rate_limit_minutes per person, by phone time. Returns seconds to wait, or 0.
create function app.rate_limit_wait(p_anon_id uuid, p_bar_id bigint, p_at timestamptz)
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
      and r.kind in ('line_start', 'inside')
  ) g
  where g.abs_gap < app.setting_minutes('rate_limit_minutes')
$$;

-- Closes a person's open session if it has passed the timeout (FR-10).
create function app.expire_session_if_due(p_anon_id uuid, p_at timestamptz)
returns void
language sql
security invoker
set search_path = ''
as $$
  update app.wait_sessions s
  set status = 'unfinished',
      ended_by = 'timeout',
      ended_at = s.started_at + app.setting_minutes('session_timeout_minutes')
  where s.anon_id = p_anon_id
    and s.status = 'open'
    and s.started_at + app.setting_minutes('session_timeout_minutes') <= p_at
$$;

revoke all on all functions in schema app from public, anon, authenticated;

-- get_bars ------------------------------------------------------------------------

create function public.get_bars(p_anon_id uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id,
           'name', b.name,
           'address', b.address,
           'door_lat', b.door_lat,
           'door_lon', b.door_lon,
           'size_class', b.size_class,
           'display_order', b.display_order
         ) order by b.display_order, b.id), '[]'::jsonb)
  from app.bars b
  where b.active
    and (not b.is_test or (p_anon_id is not null and app.is_test_anon(p_anon_id)))
$$;

-- get_estimates (FR-17 to FR-21) -----------------------------------------------------

create function public.get_estimates(p_anon_id uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.estimates(now(), p_anon_id is not null and app.is_test_anon(p_anon_id))
$$;

-- submit_report: I'm inside, and the busyness answer after I'm in ------------------
-- With an open session at this bar, I'm inside counts as I'm in (FR-15).
-- Pass p_client_session_id for the busyness answer that follows I'm in.

create function public.submit_report(
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
    if app.rate_limit_wait(p_anon_id, p_bar_id, v_at) > 0 then
      return jsonb_build_object('ok', false, 'error', 'rate_limited',
        'retry_after_seconds', app.rate_limit_wait(p_anon_id, p_bar_id, v_at));
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

-- start_session: I'm in line (FR-6, FR-7, FR-14) --------------------------------------
-- Creates the session and its line_start report. Re-sending the same session
-- ID sets "been here a while" or the first line-size answer.

create function public.start_session(
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
  if p_start_offset_minutes is not null and p_start_offset_minutes not in (0, 5, 10, 20) then
    perform app.bad_input('start_offset_minutes must be 0, 5, 10, or 20');
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

-- update_line_size: a line-size update in an open session (exempt from the
-- rate limit). Re-sending a report ID changes that report's answer.

create function public.update_line_size(
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
  perform app.check_answer('line_size', p_line_size, p_line_size_state, 0::smallint, 5::smallint);

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

-- end_session: I'm in (FR-8) or Gave up (FR-9) ----------------------------------------
-- Past the timeout, the session is unfinished and I'm in does nothing (FR-10).
-- Ending an already-ended session returns its state unchanged.

create function public.end_session(
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
  end if;

  return jsonb_build_object('ok', true, 'status', s.status,
                            'measured_wait_seconds', s.measured_wait_seconds);
end;
$$;

-- send_feedback: "This looks wrong" (FR-35) ---------------------------------------

create function public.send_feedback(
  p_anon_id        uuid,
  p_install_id     uuid,
  p_bar_id         bigint,
  p_phone_time     timestamptz,
  p_estimate_shown jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.check_identity(p_anon_id, p_install_id);
  perform app.check_bar(p_bar_id);
  if pg_column_size(p_estimate_shown) > 8192 then
    perform app.bad_input('estimate_shown is too large');
  end if;

  insert into app.feedback (anon_id, install_id, bar_id, estimate_shown, phone_time, is_test)
  values (p_anon_id, p_install_id, p_bar_id, p_estimate_shown,
          app.capped_time(p_phone_time), app.is_test_anon(p_anon_id));

  return jsonb_build_object('ok', true);
end;
$$;

-- register_install (FR-29, FR-30) --------------------------------------------------

create function public.register_install(
  p_anon_id      uuid,
  p_install_id   uuid,
  p_app_version  text,
  p_ios_version  text,
  p_device_model text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.check_identity(p_anon_id, p_install_id);
  if p_app_version is null or length(p_app_version) not between 1 and 32
     or p_ios_version is null or length(p_ios_version) not between 1 and 32
     or p_device_model is null or length(p_device_model) not between 1 and 64 then
    perform app.bad_input('invalid version or device model');
  end if;

  insert into app.installs (anon_id, install_id, app_version, ios_version, device_model, is_test)
  values (p_anon_id, p_install_id, p_app_version, p_ios_version, p_device_model,
          app.is_test_anon(p_anon_id))
  on conflict (anon_id, install_id) do update
  set last_seen_at = now(),
      app_version = excluded.app_version,
      ios_version = excluded.ios_version,
      device_model = excluded.device_model,
      is_test = excluded.is_test;

  return jsonb_build_object('ok', true);
end;
$$;

-- log_view (FR-34) ------------------------------------------------------------------

create function public.log_view(
  p_anon_id        uuid,
  p_install_id     uuid,
  p_view_kind      text,
  p_app_open_id    uuid,
  p_viewed_at      timestamptz,
  p_showed_no_data boolean,
  p_bar_id         bigint default null,
  p_estimate_shown jsonb default null,
  p_logic_version  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.check_identity(p_anon_id, p_install_id);
  if p_view_kind is null or p_view_kind not in ('map', 'bar') then
    perform app.bad_input('view_kind must be map or bar');
  end if;
  if (p_view_kind = 'bar') <> (p_bar_id is not null) then
    perform app.bad_input('bar views need a bar_id; map views take none');
  end if;
  if p_bar_id is not null then perform app.check_bar(p_bar_id); end if;
  if p_app_open_id is null or p_showed_no_data is null then
    perform app.bad_input('app_open_id and showed_no_data are required');
  end if;
  if pg_column_size(p_estimate_shown) > 8192 then
    perform app.bad_input('estimate_shown is too large');
  end if;

  insert into app.views (anon_id, install_id, view_kind, bar_id, viewed_at, estimate_shown,
                         logic_version, showed_no_data, app_open_id, is_test)
  values (p_anon_id, p_install_id, p_view_kind, p_bar_id, app.capped_time(p_viewed_at),
          p_estimate_shown, p_logic_version, p_showed_no_data, p_app_open_id,
          app.is_test_anon(p_anon_id));

  return jsonb_build_object('ok', true);
end;
$$;

-- delete_my_data (FR-32) ---------------------------------------------------------
-- Deletes everything tied to the ID and records only a count. The app then
-- makes a new anonymous ID.

create function public.delete_my_data(p_anon_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n     integer;
  total integer := 0;
  test  boolean;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));
  test := app.is_test_anon(p_anon_id);

  delete from app.reports where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.wait_sessions where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.views where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.feedback where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.installs where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;

  insert into app.deletions (reason, rows_removed, is_test)
  values ('user_request', total, test);

  return jsonb_build_object('ok', true, 'rows_removed', total);
end;
$$;

-- Grants: only anon may call the API ------------------------------------------------

do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_bars', 'get_estimates', 'submit_report', 'start_session',
                        'update_line_size', 'end_session', 'send_feedback',
                        'register_install', 'log_view', 'delete_my_data')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to anon', f);
  end loop;
end;
$$;
