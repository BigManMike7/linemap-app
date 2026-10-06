-- Event nights (FR-23): unused since 2026-10-06. With no active window there is
-- nothing to override or extend, but the empty table is kept for later. These
-- tests check that it is still there and still locked down, and that rows in it
-- change nothing. All dates are in October 2026 (EDT).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(15);

-- Still there, unchanged, and locked down ---------------------------------------------------

select has_table('app', 'event_nights', 'event_nights still exists, kept for later');
select columns_are('app', 'event_nights',
  array['id', 'created_at', 'is_test', 'night_date', 'label', 'type', 'window_start', 'window_end'],
  'its columns are unchanged');
select is((select count(*) from app.event_nights), 0::bigint, 'event_nights is empty');
select is((select c.relrowsecurity from pg_class c where c.oid = 'app.event_nights'::regclass), true,
  'event_nights has row-level security on');
select is((select count(*) from pg_policies p where p.schemaname = 'app' and p.tablename = 'event_nights'), 0::bigint,
  'with no policies, so direct access is always denied');
select is(
  (select array_agg(r.rolname || ':' || p.priv order by r.rolname, p.priv)
   from (values ('anon'), ('authenticated')) as r (rolname)
   cross join (values ('select'), ('insert'), ('update'), ('delete'),
                      ('truncate'), ('references'), ('trigger')) as p (priv)
   where has_table_privilege(r.rolname, 'app.event_nights', p.priv)),
  null::text[], 'anon and authenticated hold no privilege on it');
select ok(obj_description('app.event_nights'::regclass, 'pg_class') ~ 'nothing reads this table',
  'its comment says nothing reads it');

-- Table rules still hold, for whoever uses it later -----------------------------------------

insert into app.event_nights (night_date, label, type, window_start, window_end) values
  ('2026-10-07', 'Override Wednesday', 'override', '20:00', '03:00'),
  ('2026-10-09', 'Closed Friday', 'override', null, null),
  ('2026-10-10', 'Wide Saturday', 'extend', '20:00', '03:00');

select throws_ok(
  $$insert into app.event_nights (night_date, label, type) values ('2026-10-20', 'Bad extend', 'extend')$$,
  '23514', null, 'an extend needs a window');
select throws_ok(
  $$insert into app.event_nights (night_date, label, type, window_start) values ('2026-10-21', 'Half window', 'override', '22:00')$$,
  '23514', null, 'a window needs both a start and an end');
select throws_ok(
  $$insert into app.event_nights (night_date, label, type) values ('2026-10-07', 'Duplicate', 'override')$$,
  '23505', null, 'one event per night');

-- Rows in it change nothing ------------------------------------------------------------------
-- Friday Oct 9 has an override with no window, which used to mean "no active
-- window that night". A fresh report still shows, and History still covers
-- the whole night day.

insert into app.bars (name, address, door_lat, door_lon, display_order)
values ('Event bar', 'Test address', 40.7940, -77.8610, 100);

insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                         line_size, line_size_state, phone_time, location_status, uncertain,
                         app_version, definitions_version)
select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), b.id, '2026-10-09', 'inside', 'inside',
       2, 'answered', '2026-10-09 21:55 America/New_York', 'denied', true, '1.0', 1
from app.bars b where b.name = 'Event bar';

select is(app.estimates('2026-10-09 22:00 America/New_York', false) ->> 'window_state', 'live',
  'an override with no window does not change window_state');
select is(
  app.bar_estimate((select b.id from app.bars b where b.name = 'Event bar'),
                   '2026-10-09 22:00 America/New_York', false) ->> 'display',
  'estimate', 'nor what a bar shows');
select is(
  (app.history((select b.id from app.bars b where b.name = 'Event bar'), '2026-10-09',
               '2026-10-12 12:00 America/New_York', false) ->> 'start')::timestamptz,
  '2026-10-09 04:00 America/New_York'::timestamptz, 'nor where History starts');

-- The app roles can't read it ------------------------------------------------------------------

set local role anon;
select throws_ok('select * from app.event_nights', '42501', null, 'anon cannot read app.event_nights');
reset role;

set local role authenticated;
select throws_ok('select * from app.event_nights', '42501', null, 'authenticated cannot read app.event_nights');
reset role;

select * from finish();
rollback;
