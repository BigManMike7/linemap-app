-- Event nights (FR-23): override or extend the active window for a date.
-- All dates are in October 2026 (EDT). Usual window: Thu-Sat 9 p.m.-2 a.m.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(38);

select is((select count(*) from app.event_nights), 0::bigint, 'event_nights starts empty');

insert into app.event_nights (night_date, label, type, window_start, window_end) values
  -- Override with a window on a normally inactive Wednesday.
  ('2026-10-07', 'Override Wednesday', 'override', '20:00', '03:00'),
  -- Override with no window: Friday is not active.
  ('2026-10-09', 'Closed Friday', 'override', null, null),
  -- Override that narrows a normal Thursday.
  ('2026-10-15', 'Short Thursday', 'override', '22:00', '00:30'),
  -- Extend a normally inactive Monday.
  ('2026-10-05', 'Extended Monday', 'extend', '22:00', '01:00'),
  -- Extend that widens a normal Saturday on both ends.
  ('2026-10-10', 'Wide Saturday', 'extend', '20:00', '03:00'),
  -- Extend inside the usual window: the usual window still applies.
  ('2026-10-16', 'Narrow extend Friday', 'extend', '22:00', '01:00'),
  -- Override whose window runs past the 4 a.m. boundary.
  ('2026-10-13', 'Late Tuesday', 'override', '22:00', '05:00');

-- Override with a window ----------------------------------------------------------

select is((select w.window_start from app.night_window('2026-10-07') w),
  '2026-10-07 20:00 America/New_York'::timestamptz, 'override: window starts at the event start');
select is((select w.window_end from app.night_window('2026-10-07') w),
  '2026-10-08 03:00 America/New_York'::timestamptz, 'override: an end before the start is the next day');
select is(app.window_state('2026-10-07 19:59:59 America/New_York'), 'outside_hours', 'override: before the start is outside hours');
select is(app.window_state('2026-10-07 20:00 America/New_York'), 'live', 'override: the start is live');
select is(app.window_state('2026-10-08 02:59:59 America/New_York'), 'live', 'override: 2:59:59 a.m. is live');
select is(app.window_state('2026-10-08 03:00 America/New_York'), 'closed', 'override: the end is closed');
select is(app.window_state('2026-10-08 03:59:59 America/New_York'), 'closed', 'override: closed until 4 a.m.');
select is(app.window_state('2026-10-08 04:00 America/New_York'), 'outside_hours', 'override: 4 a.m. is outside hours');

-- Override that narrows a normal night.
select is(app.window_state('2026-10-15 21:30 America/New_York'), 'outside_hours', 'narrowing override: the usual start no longer applies');
select is(app.window_state('2026-10-15 22:00 America/New_York'), 'live', 'narrowing override: the event start is live');
select is(app.window_state('2026-10-16 00:30 America/New_York'), 'closed', 'narrowing override: closed from the event end');
select is(app.window_state('2026-10-16 01:30 America/New_York'), 'closed', 'narrowing override: still closed at the usual hours');

-- Override with no window --------------------------------------------------------------

select is((select count(*) from app.night_window('2026-10-09')), 0::bigint, 'null override: the night has no window');
select is(app.window_state('2026-10-09 22:00 America/New_York'), 'outside_hours', 'null override: Friday 10 p.m. is outside hours');
select is(app.window_state('2026-10-10 01:00 America/New_York'), 'outside_hours', 'null override: Saturday 1 a.m. is outside hours');
select is(app.window_state('2026-10-10 02:30 America/New_York'), 'outside_hours', 'null override: never closed');
select is(app.window_state('2026-10-09 01:00 America/New_York'), 'live', 'null override: the Thursday night before is untouched');

-- Extend a normally inactive night --------------------------------------------------------

select is((select w.window_start from app.night_window('2026-10-05') w),
  '2026-10-05 22:00 America/New_York'::timestamptz, 'extend inactive night: starts at the event start');
select is((select w.window_end from app.night_window('2026-10-05') w),
  '2026-10-06 01:00 America/New_York'::timestamptz, 'extend inactive night: ends at the event end');
select is(app.window_state('2026-10-05 21:59:59 America/New_York'), 'outside_hours', 'extend inactive night: before the start is outside hours');
select is(app.window_state('2026-10-05 22:00 America/New_York'), 'live', 'extend inactive night: the start is live');
select is(app.window_state('2026-10-06 00:59:59 America/New_York'), 'live', 'extend inactive night: just before the end is live');
select is(app.window_state('2026-10-06 01:00 America/New_York'), 'closed', 'extend inactive night: closed from the end');
select is(app.window_state('2026-10-06 04:00 America/New_York'), 'outside_hours', 'extend inactive night: 4 a.m. is outside hours');

-- Extend that widens a normal night --------------------------------------------------------

select is((select w.window_start from app.night_window('2026-10-10') w),
  '2026-10-10 20:00 America/New_York'::timestamptz, 'widening extend: the earlier start wins');
select is((select w.window_end from app.night_window('2026-10-10') w),
  '2026-10-11 03:00 America/New_York'::timestamptz, 'widening extend: the later end wins');
select is(app.window_state('2026-10-10 19:59:59 America/New_York'), 'outside_hours', 'widening extend: before the start is outside hours');
select is(app.window_state('2026-10-10 20:00 America/New_York'), 'live', 'widening extend: 8 p.m. is live');
select is(app.window_state('2026-10-11 02:30 America/New_York'), 'live', 'widening extend: 2:30 a.m. is live');
select is(app.window_state('2026-10-11 03:00 America/New_York'), 'closed', 'widening extend: 3 a.m. is closed');

-- Extend inside the usual window keeps the usual window.
select is((select w.window_start from app.night_window('2026-10-16') w),
  '2026-10-16 21:00 America/New_York'::timestamptz, 'narrow extend: the usual start is kept');
select is((select w.window_end from app.night_window('2026-10-16') w),
  '2026-10-17 02:00 America/New_York'::timestamptz, 'narrow extend: the usual end is kept');

-- A window past the 4 a.m. boundary ------------------------------------------------------

select is(app.window_state('2026-10-14 04:30 America/New_York'), 'live', 'late override: 4:30 a.m. is still live');
select is(app.window_state('2026-10-14 05:00 America/New_York'), 'outside_hours', 'late override: outside hours after its end');

-- Table rules ------------------------------------------------------------------------------

select throws_ok(
  $$insert into app.event_nights (night_date, label, type) values ('2026-10-20', 'Bad extend', 'extend')$$,
  '23514', null, 'an extend needs a window');
select throws_ok(
  $$insert into app.event_nights (night_date, label, type, window_start) values ('2026-10-21', 'Half window', 'override', '22:00')$$,
  '23514', null, 'a window needs both a start and an end');
select throws_ok(
  $$insert into app.event_nights (night_date, label, type) values ('2026-10-07', 'Duplicate', 'override')$$,
  '23505', null, 'one event per night');

select * from finish();
rollback;
