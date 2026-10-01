-- Night boundary (FR-22), the active window (PRD 5.4), and daylight saving.
--
-- Times are written in Eastern wall-clock time where unambiguous, and in UTC
-- around the DST changes. 2026 DST: starts Sun Mar 8 at 2:00 EST (07:00 UTC),
-- ends Sun Nov 1 at 2:00 EDT (06:00 UTC).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(57);

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

-- Window state on ordinary nights (EDT, week of Oct 1, 2026) --------------------------
-- Thu Oct 1, Fri Oct 2, Sat Oct 3 are active nights.

select is(app.window_state('2026-10-01 20:59:59 America/New_York'), 'outside_hours',
  'Thursday 8:59:59 p.m. is outside hours');
select is(app.window_state('2026-10-01 21:00 America/New_York'), 'live',
  'Thursday 9:00 p.m. is live');
select is(app.window_state('2026-10-02 01:59:59 America/New_York'), 'live',
  'Friday 1:59:59 a.m. (Thursday night) is live');
select is(app.window_state('2026-10-02 02:00 America/New_York'), 'closed',
  'Friday 2:00 a.m. (Thursday night) is closed');
select is(app.window_state('2026-10-02 03:59:59 America/New_York'), 'closed',
  'Friday 3:59:59 a.m. is closed');
select is(app.window_state('2026-10-02 04:00 America/New_York'), 'outside_hours',
  'Friday 4:00 a.m. is outside hours');
select is(app.window_state('2026-10-02 12:00 America/New_York'), 'outside_hours',
  'Friday noon is outside hours');
select is(app.window_state('2026-10-02 22:00 America/New_York'), 'live',
  'Friday 10 p.m. is live');
select is(app.window_state('2026-10-03 23:00 America/New_York'), 'live',
  'Saturday 11 p.m. is live');
select is(app.window_state('2026-10-04 01:00 America/New_York'), 'live',
  'Sunday 1 a.m. (Saturday night) is live');
select is(app.window_state('2026-10-04 02:30 America/New_York'), 'closed',
  'Sunday 2:30 a.m. (Saturday night) is closed');
select is(app.window_state('2026-10-04 04:00 America/New_York'), 'outside_hours',
  'Sunday 4:00 a.m. is outside hours');
select is(app.window_state('2026-10-04 22:00 America/New_York'), 'outside_hours',
  'Sunday 10 p.m. is outside hours');
select is(app.window_state('2026-10-05 01:00 America/New_York'), 'outside_hours',
  'Monday 1 a.m. (Sunday night) is outside hours');
select is(app.window_state('2026-10-05 03:00 America/New_York'), 'outside_hours',
  'Monday 3 a.m. is outside hours, not closed (Sunday was not active)');
select is(app.window_state('2026-10-06 22:00 America/New_York'), 'outside_hours',
  'Tuesday 10 p.m. is outside hours');
select is(app.window_state('2026-10-07 23:00 America/New_York'), 'outside_hours',
  'Wednesday 11 p.m. is outside hours');
select is(app.window_state('2026-10-08 02:30 America/New_York'), 'outside_hours',
  'Thursday 2:30 a.m. (Wednesday night) is outside hours, not closed');
select is(app.window_state('2026-12-04 21:30 America/New_York'), 'live',
  'Friday 9:30 p.m. in winter (EST) is live');
select is(app.window_state('2026-12-05 02:00 America/New_York'), 'closed',
  'Saturday 2:00 a.m. in winter (EST) is closed');

-- Spring forward: Sat Mar 7 night. 21:00 EST = 02:00 UTC. "2:00 a.m." does not
-- exist that night; Postgres reads it with the offset in effect before the
-- jump (EST), i.e. 07:00 UTC, which is exactly when clocks show 3:00 EDT. So
-- the window ends at the instant 1:59:59 EST turns into 3:00 EDT, and the
-- night is closed only from 3:00 to 4:00 a.m. EDT (one real hour).

select is((select w.window_start from app.night_window('2026-03-07') w), '2026-03-08 02:00:00+00'::timestamptz,
  'spring forward: the window starts at 9 p.m. EST');
select is((select w.window_end from app.night_window('2026-03-07') w), '2026-03-08 07:00:00+00'::timestamptz,
  'spring forward: the window ends when the clocks jump (2:00 EST = 3:00 EDT)');
select is(app.window_state('2026-03-08 01:59:59+00'), 'outside_hours',
  'spring forward: 8:59:59 p.m. EST Saturday is outside hours');
select is(app.window_state('2026-03-08 02:00:00+00'), 'live',
  'spring forward: 9:00 p.m. EST Saturday is live');
select is(app.window_state('2026-03-08 06:59:59+00'), 'live',
  'spring forward: 1:59:59 a.m. EST is live');
select is(app.window_state('2026-03-08 07:00:00+00'), 'closed',
  'spring forward: 3:00 a.m. EDT is closed');
select is(app.window_state('2026-03-08 07:59:59+00'), 'closed',
  'spring forward: 3:59:59 a.m. EDT is closed');
select is(app.window_state('2026-03-08 08:00:00+00'), 'outside_hours',
  'spring forward: 4:00 a.m. EDT is outside hours');

-- Fall back: Sat Oct 31 night. 21:00 EDT = 01:00 UTC; 2:00 a.m. EST = 07:00 UTC,
-- so this night's window is six real hours and both 1:30s are live.

select is((select w.window_start from app.night_window('2026-10-31') w), '2026-11-01 01:00:00+00'::timestamptz,
  'fall back: the window starts at 9 p.m. EDT');
select is((select w.window_end from app.night_window('2026-10-31') w), '2026-11-01 07:00:00+00'::timestamptz,
  'fall back: the window ends at 2:00 a.m. EST');
select is(app.window_state('2026-11-01 00:59:59+00'), 'outside_hours',
  'fall back: 8:59:59 p.m. EDT Saturday is outside hours');
select is(app.window_state('2026-11-01 01:00:00+00'), 'live',
  'fall back: 9:00 p.m. EDT Saturday is live');
select is(app.window_state('2026-11-01 05:30:00+00'), 'live',
  'fall back: the first 1:30 a.m. (EDT) is live');
select is(app.window_state('2026-11-01 06:30:00+00'), 'live',
  'fall back: the repeated 1:30 a.m. (EST) is live');
select is(app.window_state('2026-11-01 06:59:59+00'), 'live',
  'fall back: 1:59:59 a.m. EST is live');
select is(app.window_state('2026-11-01 07:00:00+00'), 'closed',
  'fall back: 2:00 a.m. EST is closed');
select is(app.window_state('2026-11-01 08:59:59+00'), 'closed',
  'fall back: 3:59:59 a.m. EST is closed');
select is(app.window_state('2026-11-01 09:00:00+00'), 'outside_hours',
  'fall back: 4:00 a.m. EST is outside hours');

-- Inactive nights have no window -----------------------------------------------------

select is((select count(*) from app.night_window('2026-10-05')), 0::bigint,
  'Monday has no window');
select is((select count(*) from app.night_window('2026-10-04')), 0::bigint,
  'Sunday has no window');

select * from finish();
rollback;
