-- Night boundary (FR-22), daylight saving, and no active window (PRD 5.4).
--
-- Since 2026-10-06 (logic version 3) LineMap has no hours: the Thu-Sat 9 p.m.-
-- 2 a.m. window, "Closed" from 2 to 4 a.m., and their settings and functions
-- are gone. Only the night boundary is left.
--
-- Times are written in Eastern wall-clock time where unambiguous, and in UTC
-- around the DST changes. 2026 DST: starts Sun Mar 8 at 2:00 EST (07:00 UTC),
-- ends Sun Nov 1 at 2:00 EDT (06:00 UTC).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(32);

-- Night boundary (FR-22) -------------------------------------------------------------

select is(app.night_date('2026-10-04 03:59:59 America/New_York'), '2026-10-03'::date,
  '3:59:59 a.m. Sunday belongs to Saturday night');
select is(app.night_date('2026-10-04 04:00:00 America/New_York'), '2026-10-04'::date,
  '4:00 a.m. Sunday starts Sunday');
select is(app.night_date('2026-10-04 01:00 America/New_York'), '2026-10-03'::date,
  '1 a.m. Sunday belongs to Saturday night');
select is(app.night_date('2026-10-03 23:30 America/New_York'), '2026-10-03'::date,
  '11:30 p.m. Saturday is Saturday night');
select is(app.night_date('2026-10-03 12:00 America/New_York'), '2026-10-03'::date,
  'noon Saturday is Saturday');
select is(app.night_date('2026-12-06 03:59 America/New_York'), '2026-12-05'::date,
  '3:59 a.m. in winter (EST) belongs to the night before');
select is(app.night_date('2026-12-06 04:00 America/New_York'), '2026-12-06'::date,
  '4:00 a.m. in winter (EST) starts the new day');
select is(app.night_date('2026-10-04 07:59:59+00'), '2026-10-03'::date,
  'the boundary is 4 a.m. Eastern, not 4 a.m. UTC (EDT)');
select is(app.night_date('2026-12-06 08:59:59+00'), '2026-12-05'::date,
  'the boundary is 4 a.m. Eastern, not 4 a.m. UTC (EST)');

-- Spring forward: night of Sat Mar 7, 2026. 1:59:59 EST is followed by 3:00 EDT.
select is(app.night_date('2026-03-08 06:59:59+00'), '2026-03-07'::date,
  'spring forward: 1:59:59 a.m. EST belongs to Saturday');
select is(app.night_date('2026-03-08 07:00:00+00'), '2026-03-07'::date,
  'spring forward: 3:00 a.m. EDT belongs to Saturday');
select is(app.night_date('2026-03-08 07:59:59+00'), '2026-03-07'::date,
  'spring forward: 3:59:59 a.m. EDT belongs to Saturday');
select is(app.night_date('2026-03-08 08:00:00+00'), '2026-03-08'::date,
  'spring forward: 4:00 a.m. EDT starts Sunday');

-- Fall back: night of Sat Oct 31, 2026. 1:00-1:59 a.m. happens twice.
select is(app.night_date('2026-11-01 05:30:00+00'), '2026-10-31'::date,
  'fall back: the first 1:30 a.m. (EDT) belongs to Oct 31');
select is(app.night_date('2026-11-01 06:30:00+00'), '2026-10-31'::date,
  'fall back: the repeated 1:30 a.m. (EST) belongs to Oct 31');
select is(app.night_date('2026-11-01 08:59:59+00'), '2026-10-31'::date,
  'fall back: 3:59:59 a.m. EST belongs to Oct 31');
select is(app.night_date('2026-11-01 09:00:00+00'), '2026-11-01'::date,
  'fall back: 4:00 a.m. EST starts Nov 1');

-- No active window (PRD 5.4) -------------------------------------------------------------

select ok(to_regprocedure('app.window_state(timestamptz)') is null, 'app.window_state is gone');
select ok(to_regprocedure('app.night_window(date)') is null, 'app.night_window is gone');
select ok(to_regprocedure('app.bar_estimate(bigint, timestamptz, boolean, text)') is null,
  'bar_estimate no longer takes a window state');
select ok(to_regprocedure('app.bar_estimate(bigint, timestamptz, boolean)') is not null,
  'bar_estimate takes the bar, the moment, and include_test');

select is(
  (select count(*) from app.config c where c.key in ('active_nights', 'active_window_start', 'active_window_end')),
  0::bigint, 'the active-window settings are gone');
select is(
  (select count(*) from app.config_history h
   where h.config_key in ('active_nights', 'active_window_start', 'active_window_end') and h.new_value is null),
  3::bigint, 'each deleted setting was logged in config_history with no new value');
select is(
  (select jsonb_object_agg(h.config_key, h.old_value) from app.config_history h
   where h.config_key in ('active_nights', 'active_window_start', 'active_window_end') and h.new_value is null),
  '{"active_nights": [4, 5, 6], "active_window_start": "21:00", "active_window_end": "02:00"}'::jsonb,
  'and with its old value');

select is(
  (select array_agg(n.nspname || '.' || p.proname order by n.nspname, p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app', 'public')
     and p.prosrc ~ '(night_window|active_window|active_nights|app\.window_state|event_nights)'),
  null::text[], 'no app or public function reads the window, its settings, or event_nights');

-- window_state is always live, display is never closed or outside_hours -------------------

select is(
  (select count(*)
   from generate_series(timestamptz '2026-10-01 00:00 America/New_York',
                        timestamptz '2026-10-08 00:00 America/New_York', interval '1 hour') as t
   where app.estimates(t, false) ->> 'window_state' <> 'live'),
  0::bigint, 'window_state is live at every hour of a week (older builds still read it)');
select is(app.estimates('2026-03-08 07:30:00+00', false) ->> 'window_state', 'live',
  'spring forward: 3:30 a.m. EDT is live');
select is(app.estimates('2026-11-01 06:30:00+00', false) ->> 'window_state', 'live',
  'fall back: the repeated 1:30 a.m. (EST) is live');

-- One bar with a line-size report at 2:25 a.m. Eastern every day of the week of
-- Oct 1, 2026, the old "Closed" hours after Thu-Sat nights and plain weekday
-- early mornings alike.
insert into app.bars (name, address, door_lat, door_lon, display_order)
values ('Late bar', 'Test address', 40.7940, -77.8610, 100);

insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                         line_size, line_size_state, phone_time, location_status, uncertain,
                         app_version, definitions_version)
select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), b.id,
       app.night_date((d::date + time '02:25') at time zone 'America/New_York'), 'inside', 'inside',
       2, 'answered', (d::date + time '02:25') at time zone 'America/New_York', 'denied', true, '1.0', 1
from app.bars b
cross join generate_series(date '2026-10-01', date '2026-10-07', interval '1 day') as d
where b.name = 'Late bar';

select is(
  app.bar_estimate((select b.id from app.bars b where b.name = 'Late bar'),
                   '2026-10-03 02:30 America/New_York', false) ->> 'display',
  'estimate', 'Saturday 2:30 a.m., after a Friday night: a fresh report shows (no more closed)');
select is(
  app.bar_estimate((select b.id from app.bars b where b.name = 'Late bar'),
                   '2026-10-03 02:30 America/New_York', false),
  (select e from jsonb_array_elements(app.estimates('2026-10-03 02:30 America/New_York', false) -> 'bars') as e
   where e ->> 'bar_id' = (select b.id::text from app.bars b where b.name = 'Late bar')),
  'app.estimates lists exactly what app.bar_estimate gives');
select is(
  (select count(*)
   from generate_series(date '2026-10-01', date '2026-10-07', interval '1 day') as d
   where app.bar_estimate((select b.id from app.bars b where b.name = 'Late bar'),
                          (d::date + time '02:30') at time zone 'America/New_York', false) ->> 'display'
         <> 'estimate'),
  0::bigint, 'every 2:30 a.m. of the week shows its fresh report, whatever the night');
select is(
  (select count(*)
   from generate_series(timestamptz '2026-10-01 00:00 America/New_York',
                        timestamptz '2026-10-08 00:00 America/New_York', interval '30 minutes') as t
   cross join lateral jsonb_array_elements(app.estimates(t, false) -> 'bars') as e
   where e ->> 'display' not in ('estimate', 'not_enough_data')),
  0::bigint, 'every half hour of a week, display is only estimate or not_enough_data');

select * from finish();
rollback;
