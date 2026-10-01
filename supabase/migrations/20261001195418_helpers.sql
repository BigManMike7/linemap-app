-- Internal helpers: settings, time rules, and location math.
-- All live in the private `app` schema; the app cannot call them.

-- Settings ----------------------------------------------------------------------

-- Reads one setting. Missing settings are a bug, so they raise.
create function app.setting(p_key text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v jsonb;
begin
  select c.value into v from app.config c where c.key = p_key;
  if v is null then
    raise exception 'missing setting: %', p_key;
  end if;
  return v;
end;
$$;

create function app.setting_int(p_key text)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$ select (app.setting(p_key) #>> '{}')::integer $$;

create function app.setting_num(p_key text)
returns double precision
language sql
stable
security invoker
set search_path = ''
as $$ select (app.setting(p_key) #>> '{}')::double precision $$;

create function app.setting_minutes(p_key text)
returns interval
language sql
stable
security invoker
set search_path = ''
as $$ select make_interval(mins => app.setting_int(p_key)) $$;

-- Version of the estimate and window logic (FR-21). Bump it whenever the
-- rules in these SQL functions change meaning.
create function app.logic_version()
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$ select 1 $$;

-- The answer definitions version this server understands (NFR-10).
create function app.supported_definitions_version()
returns smallint
language sql
immutable
security invoker
set search_path = ''
as $$ select 1::smallint $$;

-- Test data (FR-38): rows from IDs listed in test_anon_ids are test rows.
create function app.is_test_anon(p_anon_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- Case-insensitive: iOS prints UUIDs in uppercase, Postgres in lowercase.
  select exists (
    select 1
    from jsonb_array_elements_text(app.setting('test_anon_ids')) as t (id)
    where lower(t.id) = p_anon_id::text
  )
$$;

-- Time rules (FR-22, FR-23, PRD 5.4) ----------------------------------------------
-- All rules use America/New_York. A night runs until night_boundary_hour
-- (4 a.m.), so 1 a.m. Sunday belongs to Saturday night.

create function app.night_date(p_at timestamptz)
returns date
language sql
stable
security invoker
set search_path = ''
as $$
  select ((p_at at time zone 'America/New_York')
          - make_interval(hours => app.setting_int('night_boundary_hour')))::date
$$;

-- Eastern wall-clock time on a date, as an absolute time. Handles daylight
-- saving: the offset is the one in effect at that wall-clock time.
create function app.eastern(p_date date, p_time time)
returns timestamptz
language sql
stable
security invoker
set search_path = ''
as $$ select (p_date + p_time) at time zone 'America/New_York' $$;

-- The active window for a night, or no row if that night has none.
-- An end at or before the start means the next calendar day.
create function app.night_window(p_night date)
returns table (window_start timestamptz, window_end timestamptz)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  usual_active boolean;
  usual_start  time := (app.setting('active_window_start') #>> '{}')::time;
  usual_end    time := (app.setting('active_window_end') #>> '{}')::time;
  ev           app.event_nights%rowtype;
  s            time;
  e            time;
begin
  usual_active := app.setting('active_nights') @> to_jsonb(extract(isodow from p_night)::integer);

  select * into ev from app.event_nights where night_date = p_night;

  if found and ev.type = 'override' then
    if ev.window_start is null then
      return;
    end if;
    s := ev.window_start;
    e := ev.window_end;
  elsif found and ev.type = 'extend' then
    if usual_active then
      -- Shift by 12 hours to compare, so times after midnight sort after
      -- evening times (02:00 is later in the night than 23:00).
      s := case when (ev.window_start + interval '12 hours')::time < (usual_start + interval '12 hours')::time
                then ev.window_start else usual_start end;
      e := case when (ev.window_end + interval '12 hours')::time > (usual_end + interval '12 hours')::time
                then ev.window_end else usual_end end;
    else
      s := ev.window_start;
      e := ev.window_end;
    end if;
  elsif usual_active then
    s := usual_start;
    e := usual_end;
  else
    return;
  end if;

  window_start := app.eastern(p_night, s);
  window_end := app.eastern(case when e <= s then p_night + 1 else p_night end, e);
  return next;
end;
$$;

-- What bars show at a moment: live (in the active window), closed (after an
-- active night's window until the night boundary), or outside_hours.
create function app.window_state(p_at timestamptz)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  n date := app.night_date(p_at);
  w record;
  boundary_hour integer := app.setting_int('night_boundary_hour');
begin
  -- Check tonight and last night, in case an event window runs past the boundary.
  for w in
    select nw.window_start, nw.window_end, d.night
    from (values (n), (n - 1)) as d (night)
    cross join lateral app.night_window(d.night) nw
  loop
    if p_at >= w.window_start and p_at < w.window_end then
      return 'live';
    end if;
    if p_at >= w.window_end
       and p_at < app.eastern(w.night + 1, make_time(boundary_hour, 0, 0)) then
      return 'closed';
    end if;
  end loop;
  return 'outside_hours';
end;
$$;

-- Phone time, never later than server time (FR-16).
create function app.capped_time(p_phone_time timestamptz)
returns timestamptz
language sql
stable
security invoker
set search_path = ''
as $$ select least(coalesce(p_phone_time, now()), now()) $$;

-- Location (FR-26, FR-27) -----------------------------------------------------------

-- Great-circle distance in meters (haversine).
create function app.distance_m(lat1 double precision, lon1 double precision,
                               lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
security invoker
set search_path = ''
as $$
  select 2 * 6371008.8 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  ))
$$;

-- Initial bearing from point 1 to point 2, degrees clockwise from north.
create function app.bearing_deg(lat1 double precision, lon1 double precision,
                                lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
security invoker
set search_path = ''
as $$
  select mod(degrees(atan2(
    sin(radians(lon2 - lon1)) * cos(radians(lat2)),
    cos(radians(lat1)) * sin(radians(lat2))
      - sin(radians(lat1)) * cos(radians(lat2)) * cos(radians(lon2 - lon1))
  ))::numeric + 360, 360)::double precision
$$;

-- Turns a fix into what gets stored: distance from the door, direction from
-- the door to the reporter, and the uncertain flag. The coordinates go no
-- further than this function. Location never causes a rejection.
create function app.locate(p_bar_id bigint, p_location_status text,
                           p_lat double precision, p_lon double precision,
                           p_accuracy_m double precision, p_fix_age_s double precision)
returns table (distance_m real, bearing_deg real, uncertain boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  b app.bars%rowtype;
  has_fix boolean;
begin
  select * into b from app.bars where id = p_bar_id;

  -- coalesce: a missing coordinate means no fix, never a null flag.
  has_fix := coalesce(p_location_status in ('precise', 'approximate')
                      and p_lat between -90 and 90
                      and p_lon between -180 and 180, false);

  if has_fix then
    distance_m := app.distance_m(b.door_lat, b.door_lon, p_lat, p_lon);
    bearing_deg := app.bearing_deg(b.door_lat, b.door_lon, p_lat, p_lon);
  end if;

  uncertain := not has_fix
    or p_location_status <> 'precise'
    or distance_m > app.setting_num('uncertain_distance_m')
    or p_accuracy_m is null
    or p_accuracy_m > app.setting_num('uncertain_accuracy_m')
    or p_accuracy_m < 0
    or coalesce(p_fix_age_s > app.setting_num('uncertain_fix_age_s'), false);
  return next;
end;
$$;

-- Wait minutes to the recalled-wait code, so measured and reported waits can
-- be compared (FR-19).
create function app.wait_code(p_seconds integer)
returns smallint
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when p_seconds < 5 * 60 then 1
    when p_seconds < 15 * 60 then 2
    when p_seconds < 30 * 60 then 3
    when p_seconds < 60 * 60 then 4
    else 5
  end::smallint
$$;

revoke all on all functions in schema app from public, anon, authenticated;
