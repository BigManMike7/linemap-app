-- Bar history by night (FR-43): app.history and public.bar_history.
--
-- app.history takes the moment to compute "as of" (p_at), so most checks use
-- fixed times. Night N is Friday Oct 2, 2026; its night day runs from 4 a.m.
-- EDT Oct 2 to 4 a.m. EDT Oct 3 (08:00 UTC Oct 2 to 08:00 UTC Oct 3), with a
-- point every 15 minutes, and its usual window is 9 p.m. to 2 a.m. EDT, which
-- is 01:00 to 06:00 UTC on Oct 3. P is a moment well after it (Oct 6, 16:00 UTC). public.bar_history uses now(), so its checks are
-- relative to tonight. Each scenario has its own bar; rows are inserted
-- straight into the app tables, as in estimates_test.sql, or through the API
-- with past phone times.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(102);

-- Helpers ----------------------------------------------------------------------------

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

create function pg_temp.p() returns timestamptz
language sql immutable as
$$ select timestamptz '2026-10-06 16:00:00+00' $$;

create function pg_temp.new_bar(p_name text, p_is_test boolean default false, p_active boolean default true)
returns bigint
language sql as $$
  insert into app.bars (name, address, door_lat, door_lon, display_order, is_test, active)
  values (p_name, 'Test address', 40.7940, -77.8610, 100, p_is_test, p_active)
  returning id
$$;

create function pg_temp.bar(p_name text) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.name = p_name $$;

-- A report from person p_person. Codes are only stored when given.
create function pg_temp.rep(p_person integer, p_bar bigint, p_at timestamptz,
                            p_line integer default null, p_busy integer default null,
                            p_wait integer default null, p_hidden boolean default false,
                            p_is_test boolean default false)
returns void
language sql as $$
  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    line_size, line_size_state, busyness, busyness_state, recalled_wait, recalled_wait_state,
    phone_time, location_status, uncertain, hidden, hidden_reason,
    app_version, definitions_version, is_test)
  values (
    gen_random_uuid(), pg_temp.uid(p_person), pg_temp.uid(p_person), p_bar,
    app.night_date(p_at), 'inside', 'inside',
    p_line, case when p_line is not null then 'answered' end,
    p_busy, case when p_busy is not null then 'answered' end,
    p_wait, case when p_wait is not null then 'answered' end,
    p_at, 'denied', true, p_hidden, case when p_hidden then 'hidden in test' end,
    '1.0', 1, p_is_test)
$$;

-- A finished timed wait, entered (I'm in) or gave_up.
create function pg_temp.sess(p_person integer, p_bar bigint, p_start timestamptz, p_end timestamptz,
                             p_status text default 'entered')
returns void
language sql as $$
  insert into app.wait_sessions (
    client_session_id, anon_id, install_id, bar_id, night_date, started_at,
    ended_at, status, ended_by)
  values (
    gen_random_uuid(), pg_temp.uid(p_person), pg_temp.uid(p_person), p_bar,
    app.night_date(p_start), p_start, p_end, p_status,
    case p_status when 'entered' then 'im_in' else 'gave_up' end)
$$;

-- History as of P for a night, real rows only unless told otherwise.
create function pg_temp.h(p_bar bigint, p_night date, p_at timestamptz default null,
                          p_include_test boolean default false)
returns jsonb
language sql stable as
$$ select app.history(p_bar, p_night, coalesce(p_at, pg_temp.p()), p_include_test) $$;

-- One point of a history, by its time.
create function pg_temp.pt(p_history jsonb, p_at timestamptz) returns jsonb
language sql immutable as $$
  select p
  from jsonb_array_elements(p_history -> 'points') as p
  where (p ->> 'at')::timestamptz = p_at
$$;

create function pg_temp.npoints(p_history jsonb) returns integer
language sql immutable as
$$ select jsonb_array_length(p_history -> 'points') $$;

-- How many points show anything at all.
create function pg_temp.nonempty(p_history jsonb) returns bigint
language sql immutable as $$
  select count(*)
  from jsonb_array_elements(p_history -> 'points') as p
  where (p ->> 'people')::integer > 0
     or jsonb_typeof(p -> 'line_size') = 'object'
     or jsonb_typeof(p -> 'wait') = 'object'
     or jsonb_typeof(p -> 'busyness') = 'object'
$$;

select pg_temp.new_bar(n) from unnest(array[
  'History bar', 'History other bar', 'History hidden bar', 'History replaced bar',
  'History afternoon bar']) as n;
select pg_temp.new_bar('History test bar', p_is_test => true);
select pg_temp.new_bar('History closed bar', p_active => false);

-- Night N at the History bar ------------------------------------------------------------
--   22:02 EDT  person 1: line size 2
--   23:05-23:30 EDT  person 2: a 25-minute measured wait (code 3)
--   00:25 EDT  person 3: a reported wait range, code 2
--   00:40 EDT  person 4: busyness 4
--   01:00 EDT  person 5: line size 4, a test row

select pg_temp.rep(1, pg_temp.bar('History bar'), '2026-10-03 02:02:00+00', p_line => 2);
select pg_temp.sess(2, pg_temp.bar('History bar'), '2026-10-03 03:05:00+00', '2026-10-03 03:30:00+00');
select pg_temp.rep(3, pg_temp.bar('History bar'), '2026-10-03 04:25:00+00', p_wait => 2);
select pg_temp.rep(4, pg_temp.bar('History bar'), '2026-10-03 04:40:00+00', p_busy => 4);
select pg_temp.rep(5, pg_temp.bar('History bar'), '2026-10-03 05:00:00+00', p_line => 4, p_is_test => true);

-- Other nights, for the nights list.
select pg_temp.rep(6, pg_temp.bar('History bar'), '2026-09-27 01:30:00+00', p_busy => 2);          -- night Sep 26
select pg_temp.rep(6, pg_temp.bar('History bar'), '2026-09-26 02:00:00+00', p_busy => 2,
                   p_hidden => true);                                                               -- Sep 25, hidden
select pg_temp.rep(7, pg_temp.bar('History bar'), '2026-09-25 02:00:00+00', p_busy => 2,
                   p_is_test => true);                                                              -- Sep 24, test
select pg_temp.sess(8, pg_temp.bar('History bar'), '2026-09-24 02:00:00+00', '2026-09-24 02:20:00+00',
                    'gave_up');                                                                     -- Sep 23, gave up
select pg_temp.sess(8, pg_temp.bar('History bar'), '2026-09-23 02:00:00+00', '2026-09-23 02:20:00+00'); -- Sep 22
select pg_temp.rep(9, pg_temp.bar('History bar'), '2025-09-01 02:00:00+00', p_busy => 2);          -- past retention
select pg_temp.rep(9, pg_temp.bar('History other bar'), '2026-10-01 02:00:00+00', p_busy => 2);    -- another bar

-- An event-night override for night N must not move the chart (FR-23 is for live windows).
insert into app.event_nights (night_date, label, type, window_start, window_end)
values ('2026-10-02', 'History test override', 'override', '18:00', '23:00');

create temp table hist as
select pg_temp.h(pg_temp.bar('History bar'), '2026-10-02') as j,
       pg_temp.h(pg_temp.bar('History bar'), '2026-10-02', p_include_test => true) as t;

-- Shape -------------------------------------------------------------------------------------

select is(
  (select array_agg(k order by k) from hist, jsonb_object_keys(hist.j) as k),
  array['bar_id', 'end', 'logic_version', 'night', 'nights', 'points', 'start', 'tonight'],
  'the history has exactly the contract''s keys');
select is((select (j ->> 'logic_version')::integer from hist), 1, 'it carries the logic version');
select is((select (j ->> 'bar_id')::bigint from hist), pg_temp.bar('History bar'), 'it names the bar');
select is((select j ->> 'night' from hist), '2026-10-02', 'night is the date asked for, as YYYY-MM-DD');
select is((select j ->> 'tonight' from hist), '2026-10-06', 'tonight is the night of the moment asked about');
select is((select (j ->> 'start')::timestamptz from hist), '2026-10-03 01:00:00+00'::timestamptz,
  'start is still the usual window''s 9 p.m. EDT');
select is((select (j ->> 'end')::timestamptz from hist), '2026-10-03 06:00:00+00'::timestamptz,
  'end is still the usual window''s 2 a.m. EDT, ignoring the event-night override');
select is((select pg_temp.npoints(j) from hist), 96, 'a past night has 96 points, every 15 minutes of 24 hours');
select is((select (j -> 'points' -> 0 ->> 'at')::timestamptz from hist), '2026-10-02 08:00:00+00'::timestamptz,
  'the first point is 4:00 a.m. EDT on the night''s date');
select is((select (j -> 'points' -> 95 ->> 'at')::timestamptz from hist), '2026-10-03 07:45:00+00'::timestamptz,
  'the last point is 3:45 a.m. EDT the next day, not the next night''s 4 a.m.');
select is(
  (select count(*) from (
     select (p ->> 'at')::timestamptz - lag((p ->> 'at')::timestamptz) over (order by o) as gap
     from hist, jsonb_array_elements(hist.j -> 'points') with ordinality as x (p, o)) gaps
   where gap is not null and gap <> interval '15 minutes'),
  0::bigint, 'points are in order, 15 minutes apart');
select is(
  (select count(*) from hist, jsonb_array_elements(hist.j -> 'points') as p
   where app.night_date((p ->> 'at')::timestamptz) <> '2026-10-02'),
  0::bigint, 'every point belongs to the night (FR-22)');
select ok(
  (select bool_or((p ->> 'at')::timestamptz = (j ->> 'start')::timestamptz)
      and bool_or((p ->> 'at')::timestamptz = (j ->> 'end')::timestamptz)
   from hist, jsonb_array_elements(hist.j -> 'points') as p),
  'the usual window''s start and end each have a point');
select is(
  (select array_agg(k order by k) from hist, jsonb_object_keys(hist.j -> 'points' -> 0) as k),
  array['at', 'busyness', 'line_size', 'people', 'wait'],
  'a point has only at, people, and the three signals: no IDs or report times');
select is((select pg_temp.pt(j, '2026-10-03 01:00:00+00') from hist),
  jsonb_build_object('at', '2026-10-03 01:00:00+00'::timestamptz, 'people', 0,
                     'line_size', null, 'wait', null, 'busyness', null),
  'an empty point has 0 people and null signals');

-- As of each moment ---------------------------------------------------------------------------

select is((select pg_temp.pt(j, '2026-10-03 02:00:00+00') -> 'line_size' from hist), 'null'::jsonb,
  'a report does not show before its time');
select is((select pg_temp.pt(j, '2026-10-03 02:00:00+00') ->> 'people' from hist), '0',
  'nor does its reporter');
select is((select pg_temp.pt(j, '2026-10-03 02:15:00+00') -> 'line_size' from hist),
  '{"code": 2, "freshness": "fresh"}'::jsonb, 'it shows from the next point, fresh');
select is((select pg_temp.pt(j, '2026-10-03 02:15:00+00') ->> 'people' from hist), '1', 'with one person');
select is((select pg_temp.pt(j, '2026-10-03 02:30:00+00') -> 'line_size' ->> 'freshness' from hist), 'fresh',
  '28 minutes later it is still fresh');
select is((select pg_temp.pt(j, '2026-10-03 02:45:00+00') -> 'line_size' ->> 'freshness' from hist), 'stale',
  '43 minutes later it is stale');
select is((select pg_temp.pt(j, '2026-10-03 02:45:00+00') ->> 'people' from hist), '1',
  'a stale stretch still counts its people');
select is((select pg_temp.pt(j, '2026-10-03 03:00:00+00') -> 'line_size' ->> 'freshness' from hist), 'stale',
  '58 minutes later it is still stale');
select is((select pg_temp.pt(j, '2026-10-03 03:15:00+00') -> 'line_size' from hist), 'null'::jsonb,
  '73 minutes later it is gone');
select is((select pg_temp.pt(j, '2026-10-03 03:15:00+00') ->> 'people' from hist), '0',
  'and nobody is counted');

select is((select pg_temp.pt(j, '2026-10-03 03:15:00+00') -> 'wait' from hist), 'null'::jsonb,
  'a measured wait does not show before the person got in');
select is((select pg_temp.pt(j, '2026-10-03 03:30:00+00') -> 'wait' from hist),
  '{"code": 3, "minutes": 25, "freshness": "fresh"}'::jsonb,
  'a measured wait shows its minutes and range from when the person got in');
select is((select pg_temp.pt(j, '2026-10-03 04:15:00+00') -> 'wait' ->> 'freshness' from hist), 'stale',
  'and ages like any report');
select is((select pg_temp.pt(j, '2026-10-03 04:30:00+00') -> 'wait' from hist),
  '{"code": 2, "minutes": null, "freshness": "fresh"}'::jsonb,
  'a reported wait range has null minutes');
select is((select pg_temp.pt(j, '2026-10-03 04:30:00+00') ->> 'people' from hist), '1',
  'people counts only the fresh reporters when the bar is fresh');
select is((select pg_temp.pt(j, '2026-10-03 04:45:00+00') -> 'busyness' from hist),
  '{"code": 4, "freshness": "fresh"}'::jsonb, 'busyness shows its code and freshness');

-- Outside the usual window: a report at 2 p.m. EDT (18:00 UTC) on the night's
-- date shows in the points around 2 p.m.

select pg_temp.rep(10, pg_temp.bar('History afternoon bar'), '2026-10-02 18:00:00+00', p_line => 3);

create temp table ahist as
select pg_temp.h(pg_temp.bar('History afternoon bar'), '2026-10-02') as j;

select is((select pg_temp.pt(j, '2026-10-02 17:45:00+00') -> 'line_size' from ahist), 'null'::jsonb,
  'a 2 p.m. report does not show at 1:45 p.m.');
select is((select pg_temp.pt(j, '2026-10-02 18:00:00+00') -> 'line_size' from ahist),
  '{"code": 3, "freshness": "fresh"}'::jsonb, 'it shows at 2 p.m. with its line size, fresh');
select is((select pg_temp.pt(j, '2026-10-02 18:00:00+00') ->> 'people' from ahist), '1',
  'with its person');
select is((select pg_temp.pt(j, '2026-10-02 18:30:00+00') -> 'line_size' from ahist),
  '{"code": 3, "freshness": "fresh"}'::jsonb, 'and at 2:30 p.m.');
select is((select pg_temp.pt(j, '2026-10-02 18:45:00+00') -> 'line_size' from ahist),
  '{"code": 3, "freshness": "stale"}'::jsonb, 'grayed out at 2:45 p.m.');
select is((select pg_temp.pt(j, '2026-10-02 19:15:00+00') -> 'line_size' from ahist), 'null'::jsonb,
  'and gone by 3:15 p.m.');
select is((select pg_temp.nonempty(j) from ahist), 5::bigint,
  'only the five points from 2 to 3 p.m. show anything');
select is((select j -> 'nights' from ahist), '["2026-10-02"]'::jsonb,
  'its night is the night of its date');

-- Test rows (FR-38) ---------------------------------------------------------------------------

select is((select pg_temp.pt(j, '2026-10-03 05:00:00+00') -> 'line_size' from hist), 'null'::jsonb,
  'a test row never shows to real users');
select is((select pg_temp.pt(j, '2026-10-03 05:00:00+00') ->> 'people' from hist), '1',
  'nor counts as a person for them');
select is((select pg_temp.pt(t, '2026-10-03 05:00:00+00') -> 'line_size' from hist),
  '{"code": 4, "freshness": "fresh"}'::jsonb, 'test IDs see test rows');
select is((select pg_temp.pt(t, '2026-10-03 05:00:00+00') ->> 'people' from hist), '2',
  'and count them as people');

-- Nights list -------------------------------------------------------------------------------------

select is((select j -> 'nights' from hist), '["2026-10-02", "2026-09-26", "2026-09-22"]'::jsonb,
  'nights with visible data at this bar, newest first: no hidden, test, gave-up-only, expired, or other-bar nights');
select is((select t -> 'nights' from hist), '["2026-10-02", "2026-09-26", "2026-09-24", "2026-09-22"]'::jsonb,
  'test IDs also see nights with only test rows');
select is(pg_temp.h(pg_temp.bar('History other bar'), '2026-10-02') -> 'nights', '["2026-09-30"]'::jsonb,
  'each bar has its own nights');
select is(pg_temp.h(pg_temp.bar('History hidden bar'), '2026-10-02') -> 'nights', '[]'::jsonb,
  'a bar with no data has no nights');

-- Hidden, deleted, replaced, and cancelled reports never appear ---------------------------------------

select pg_temp.rep(20, pg_temp.bar('History hidden bar'), '2026-10-03 02:02:00+00', p_line => 3, p_hidden => true);
select pg_temp.rep(21, pg_temp.bar('History hidden bar'), '2026-10-03 03:02:00+00', p_line => 1);
delete from app.reports r where r.anon_id = pg_temp.uid(21);

select is(pg_temp.nonempty(pg_temp.h(pg_temp.bar('History hidden bar'), '2026-10-02')), 0::bigint,
  'hidden and deleted (FR-41) reports never appear');
select is(pg_temp.h(pg_temp.bar('History hidden bar'), '2026-10-02') -> 'nights', '[]'::jsonb,
  'nor do their nights');

-- Through the API, with past phone times: a Report conditions redone (FR-46), a
-- timer redone (FR-46), and a line cancelled (FR-39).
create temp table api_calls as
select public.report_conditions(
         p_client_report_id => pg_temp.uid(3001), p_anon_id => pg_temp.uid(30), p_install_id => pg_temp.uid(530),
         p_bar_id => pg_temp.bar('History replaced bar'), p_phone_time => '2026-10-03 02:00:00+00',
         p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint,
         p_busyness => 4::smallint, p_busyness_state => 'answered') as a,
       null::jsonb as b, null::jsonb as c, null::jsonb as d, null::jsonb as e, null::jsonb as f,
       null::jsonb as g, null::jsonb as h, null::jsonb as i;

update api_calls set b = public.report_conditions(
  p_client_report_id => pg_temp.uid(3002), p_anon_id => pg_temp.uid(30), p_install_id => pg_temp.uid(530),
  p_bar_id => pg_temp.bar('History replaced bar'), p_phone_time => '2026-10-03 02:03:00+00',
  p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint,
  p_busyness => 1::smallint, p_busyness_state => 'answered');
update api_calls set c = public.start_session(
  p_client_session_id => pg_temp.uid(3101), p_client_report_id => pg_temp.uid(3102),
  p_anon_id => pg_temp.uid(31), p_install_id => pg_temp.uid(531),
  p_bar_id => pg_temp.bar('History replaced bar'), p_phone_time => '2026-10-03 01:10:00+00',
  p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint);
update api_calls set d = public.end_session(
  p_client_session_id => pg_temp.uid(3101), p_anon_id => pg_temp.uid(31),
  p_outcome => 'entered', p_phone_time => '2026-10-03 01:20:00+00');
update api_calls set e = public.start_session(
  p_client_session_id => pg_temp.uid(3103), p_client_report_id => pg_temp.uid(3104),
  p_anon_id => pg_temp.uid(31), p_install_id => pg_temp.uid(531),
  p_bar_id => pg_temp.bar('History replaced bar'), p_phone_time => '2026-10-03 01:22:00+00',
  p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint);
update api_calls set f = public.end_session(
  p_client_session_id => pg_temp.uid(3103), p_anon_id => pg_temp.uid(31),
  p_outcome => 'entered', p_phone_time => '2026-10-03 01:50:00+00');
update api_calls set g = public.start_session(
  p_client_session_id => pg_temp.uid(3201), p_client_report_id => pg_temp.uid(3202),
  p_anon_id => pg_temp.uid(32), p_install_id => pg_temp.uid(532),
  p_bar_id => pg_temp.bar('History replaced bar'), p_phone_time => '2026-10-03 02:30:00+00',
  p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint,
  p_line_size => 4::smallint, p_line_size_state => 'answered');
update api_calls set h = public.cancel_session(p_client_session_id => pg_temp.uid(3201), p_anon_id => pg_temp.uid(32));

create temp table rhist as
select pg_temp.h(pg_temp.bar('History replaced bar'), '2026-10-02') as j;

select is((select b ->> 'ok' from api_calls), 'true', 'the second Report conditions redoes the first');
select is((select f ->> 'measured_wait_seconds' from api_calls), '1680', 'the redone timer measures 28 minutes');
select is((select h ->> 'removed' from api_calls), 'true', 'the mistaken line is cancelled');
select is((select pg_temp.pt(j, '2026-10-03 02:00:00+00') -> 'busyness' from rhist), 'null'::jsonb,
  'a replaced Report conditions is gone even from the moments it was the newest');
select is((select pg_temp.pt(j, '2026-10-03 02:15:00+00') -> 'busyness' ->> 'code' from rhist), '1',
  'the report that replaced it shows from its own time');
select is(
  (select count(*) from rhist, jsonb_array_elements(rhist.j -> 'points') p where p -> 'busyness' ->> 'code' = '4'),
  0::bigint, 'no point shows the replaced busyness');
select is((select pg_temp.pt(j, '2026-10-03 01:30:00+00') -> 'wait' from rhist), 'null'::jsonb,
  'a replaced timer''s wait is gone');
select is((select pg_temp.pt(j, '2026-10-03 02:00:00+00') -> 'wait' from rhist),
  '{"code": 3, "minutes": 28, "freshness": "fresh"}'::jsonb, 'the timer that replaced it shows');
select is(
  (select count(*) from rhist, jsonb_array_elements(rhist.j -> 'points') p where p -> 'wait' ->> 'minutes' = '10'),
  0::bigint, 'no point shows the replaced wait');
select is(
  (select count(*) from rhist, jsonb_array_elements(rhist.j -> 'points') p where p -> 'line_size' ->> 'code' = '4'),
  0::bigint, 'a cancelled line never shows');

-- Tonight in progress, before it starts, and the future -------------------------------------------------

select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:02:00+00')), 77,
  'tonight at 11:02 p.m. has the 77 points from 4 a.m. up to 11:00 p.m.');
select is(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:02:00+00') ->> 'night', '2026-10-02',
  'with no night given, it is tonight');
select is(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:02:00+00') ->> 'tonight', '2026-10-02',
  'tonight is the same night');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:02:00+00') -> 'points' -> 76 ->> 'at')::timestamptz,
  '2026-10-03 03:00:00+00'::timestamptz, 'the last point is the last quarter hour before now');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:00:00+00')), 77,
  'a point exactly at now is included');
select is(
  (select count(*) from jsonb_array_elements(
     pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 03:02:00+00') -> 'points') as p
   where (p ->> 'at')::timestamptz > '2026-10-03 03:02:00+00'),
  0::bigint, 'no point is after now');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 00:59:00+00')), 68,
  'at 8:59 p.m. tonight already has the 68 points since 4 a.m.');
select is((pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 00:59:00+00') ->> 'start')::timestamptz,
  '2026-10-03 01:00:00+00'::timestamptz, 'and still says when the usual window starts');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-02 08:00:00+00')), 1,
  'at 4:00 a.m. the new night has its first point');
select is(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-02 08:00:00+00') ->> 'night', '2026-10-02',
  'and 4:00 a.m. is the new night (FR-22)');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), '2026-10-02', '2026-10-02 07:59:00+00')), 0,
  'at 3:59 a.m. the coming night has no points yet');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 07:30:00+00')), 95,
  'at 3:30 a.m. tonight is still the same night, with the 95 points up to 3:30 a.m.');
select is(pg_temp.h(pg_temp.bar('History bar'), null, '2026-10-03 07:30:00+00') ->> 'tonight', '2026-10-02',
  'before 4 a.m. tonight is still the night before (FR-22)');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), '2026-10-09')), 0, 'a future night has no points');
select is((pg_temp.h(pg_temp.bar('History bar'), '2026-10-09') ->> 'start')::timestamptz,
  '2026-10-10 01:00:00+00'::timestamptz, 'a future night still has its start');

-- Daylight saving (FR-22) -----------------------------------------------------------------------------

select is((pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00') ->> 'start')::timestamptz,
  '2026-11-01 01:00:00+00'::timestamptz, 'fall back: the night of Oct 31 starts at 9 p.m. EDT');
select is((pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00') ->> 'end')::timestamptz,
  '2026-11-01 07:00:00+00'::timestamptz, 'and ends at 2 a.m. EST');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00')), 100,
  'its night day is 25 hours, so it has 100 points');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00') -> 'points' -> 0 ->> 'at')::timestamptz,
  '2026-10-31 08:00:00+00'::timestamptz, 'from 4 a.m. EDT on Oct 31');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00') -> 'points' -> 99 ->> 'at')::timestamptz,
  '2026-11-01 08:45:00+00'::timestamptz, 'to 3:45 a.m. EST on Nov 1');
select is(
  (select count(*) from jsonb_array_elements(
     pg_temp.h(pg_temp.bar('History bar'), '2026-10-31', '2026-12-01 00:00+00') -> 'points') as p
   where app.night_date((p ->> 'at')::timestamptz) <> '2026-10-31'),
  0::bigint, 'every point of the fall-back night belongs to it');
select is((pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00') ->> 'start')::timestamptz,
  '2026-03-08 02:00:00+00'::timestamptz, 'spring forward: the night of Mar 7 starts at 9 p.m. EST');
select is((pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00') ->> 'end')::timestamptz,
  '2026-03-08 07:00:00+00'::timestamptz, 'and ends when 2 a.m. EST becomes 3 a.m. EDT');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00')), 92,
  'its night day is 23 hours, so it has 92 points');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00') -> 'points' -> 0 ->> 'at')::timestamptz,
  '2026-03-07 09:00:00+00'::timestamptz, 'from 4 a.m. EST on Mar 7');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00') -> 'points' -> 91 ->> 'at')::timestamptz,
  '2026-03-08 07:45:00+00'::timestamptz, 'to 3:45 a.m. EDT on Mar 8');
select is(
  (select count(*) from jsonb_array_elements(
     pg_temp.h(pg_temp.bar('History bar'), '2026-03-07', '2026-12-01 00:00+00') -> 'points') as p
   where app.night_date((p ->> 'at')::timestamptz) <> '2026-03-07'),
  0::bigint, 'every point of the spring-forward night belongs to it');
select is((pg_temp.h(pg_temp.bar('History bar'), '2026-11-06', '2026-12-01 00:00+00') ->> 'start')::timestamptz,
  '2026-11-07 02:00:00+00'::timestamptz, 'a winter night starts at 9 p.m. EST');
select is(pg_temp.npoints(pg_temp.h(pg_temp.bar('History bar'), '2026-11-06', '2026-12-01 00:00+00')), 96,
  'and has 96 points');
select is(
  (pg_temp.h(pg_temp.bar('History bar'), '2026-11-06', '2026-12-01 00:00+00') -> 'points' -> 0 ->> 'at')::timestamptz,
  '2026-11-06 09:00:00+00'::timestamptz, 'from 4 a.m. EST');

-- public.bar_history ----------------------------------------------------------------------------------

select throws_ok($$select public.bar_history()$$, '22023', 'unknown bar', 'a bar is required');
select throws_ok($$select public.bar_history(p_bar_id => -1)$$, '22023', 'unknown bar', 'an unknown bar is bad input');
select throws_ok($$select public.bar_history(p_bar_id => pg_temp.bar('History closed bar'))$$,
  '22023', 'unknown bar', 'an inactive bar is bad input');
select throws_ok($$select public.bar_history(p_bar_id => pg_temp.bar('History test bar'))$$,
  '22023', 'unknown bar', 'a test bar is bad input with no ID');
select throws_ok($$select public.bar_history(p_anon_id => pg_temp.uid(98), p_bar_id => pg_temp.bar('History test bar'))$$,
  '22023', 'unknown bar', 'a test bar is bad input for a real ID');

update app.config set value = jsonb_build_array(pg_temp.uid(99)::text) where key = 'test_anon_ids';

select lives_ok($$select public.bar_history(p_anon_id => pg_temp.uid(99), p_bar_id => pg_temp.bar('History test bar'))$$,
  'a test ID can see a test bar''s history');
select is(
  pg_temp.pt(public.bar_history(p_anon_id => pg_temp.uid(99), p_bar_id => pg_temp.bar('History bar'),
                                p_night => '2026-10-02'), '2026-10-03 05:00:00+00') -> 'line_size' ->> 'code',
  '4', 'a test ID sees test rows');
select is(
  pg_temp.pt(public.bar_history(p_anon_id => pg_temp.uid(98), p_bar_id => pg_temp.bar('History bar'),
                                p_night => '2026-10-02'), '2026-10-03 05:00:00+00') -> 'line_size',
  'null'::jsonb, 'a real ID does not');

create temp table pub as
select public.bar_history(p_bar_id => pg_temp.bar('History bar')) as tonight,
       public.bar_history(p_bar_id => pg_temp.bar('History bar'), p_night => app.night_date(now()) - 7) as past,
       public.bar_history(p_bar_id => pg_temp.bar('History bar'), p_night => app.night_date(now()) + 7) as future;

select is((select tonight ->> 'tonight' from pub), app.night_date(now())::text, 'tonight is tonight''s night date');
select is((select tonight ->> 'night' from pub), app.night_date(now())::text, 'the night defaults to tonight');
select is(
  (select pg_temp.npoints(tonight) from pub),
  (select count(*)::integer
   from generate_series(app.eastern(app.night_date(now()), make_time(app.setting_int('night_boundary_hour'), 0, 0)),
                        now(), interval '15 minutes')),
  'tonight has points from 4 a.m. only up to now');
select is(
  (select pg_temp.npoints(past) from pub),
  (select (extract(epoch from
             app.eastern(app.night_date(now()) - 6, make_time(app.setting_int('night_boundary_hour'), 0, 0))
           - app.eastern(app.night_date(now()) - 7, make_time(app.setting_int('night_boundary_hour'), 0, 0)))
           / 900)::integer),
  'a night a week ago has every quarter hour of its night day');
select is((select pg_temp.npoints(future) from pub), 0, 'a night a week ahead has none');

select * from finish();
rollback;
