-- Starting data: the bar list (PRD 7.3, *_bar_list.sql, approved by Max on
-- 2026-10-06) and the default settings (FR-37), and what the 2026-10-07 data
-- wipe leaves.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(24);

-- Bars --------------------------------------------------------------------------------
-- Six active bars. The Phyrst, a starting bar, is kept but inactive (FR-37).

select is(
  (select array_agg(b.name order by b.display_order) from app.bars b where b.active),
  array['Primanti Bros.', 'Doggie''s Pub', 'Brothers Bar & Grill', 'Champs Downtown', 'Cafe 210 West', 'The Shandygaff'],
  'the six active bars, in display order');
select is(
  (select array_agg(b.display_order order by b.display_order) from app.bars b where b.active),
  array[1, 2, 3, 4, 5, 6],
  'the active bars are numbered 1 to 6');
select is(
  (select array_agg(b.address order by b.display_order) from app.bars b where b.active),
  array['130 Heister St, State College, PA 16801',
        '108 S Pugh St, State College, PA 16801',
        '134 S Allen St, State College, PA 16801',
        '139 S Allen St, State College, PA 16801',
        '210 W College Ave, State College, PA 16801',
        '212 E College Ave (rear), State College, PA 16801'],
  'the active bars have the approved addresses, in display order');
select is(
  (select array_agg(array[b.door_lat, b.door_lon] order by b.display_order) from app.bars b where b.active),
  array[[40.7966833, -77.8569426],
        [40.7950443, -77.8602538],
        [40.7936366, -77.8607833],
        [40.7937545, -77.8605492],
        [40.7931773, -77.8630037],
        [40.7953248, -77.8595640]]::double precision[],
  'the active bars have the OpenStreetMap door pins, in display order');
select is(
  (select b.active from app.bars b where b.name = 'The Phyrst'),
  false, 'The Phyrst is kept, inactive (never deleted, so its id is never reused)');
select is((select count(*) from app.bars), 7::bigint, 'there are no other bars');
select is((select count(*) from app.bars where is_test), 0::bigint, 'no bar is a test row');
select is((select count(*) from app.bars where size_class <> 'medium'), 0::bigint, 'every bar is medium');
select is(
  (select count(*) from app.bars b
   where b.door_lat between 40.78 and 40.81 and b.door_lon between -77.88 and -77.84),
  7::bigint, 'every door pin is in downtown State College');

-- Settings ----------------------------------------------------------------------------

select is(
  (select array_agg(k order by k) from unnest(array[
     'agree_within', 'fresh_minutes', 'majority_min_others', 'night_boundary_hour',
     'rate_limit_minutes', 'redo_minutes', 'retention_days', 'session_timeout_minutes',
     'stale_minutes', 'test_anon_ids', 'uncertain_accuracy_m', 'uncertain_distance_m',
     'uncertain_fix_age_s']) as k
   where not exists (select 1 from app.config c where c.key = k)),
  null::text[],
  'every setting the functions read exists');

select is(app.setting_int('fresh_minutes'), 30, 'fresh for 30 minutes (FR-17)');
select is(app.setting_int('stale_minutes'), 60, 'stale until 60 minutes (FR-17)');
select is(app.setting_int('agree_within'), 1, 'agree within one range (FR-19)');
select is(app.setting_int('majority_min_others'), 2, 'majority needs 2 other people (FR-19)');
select is(app.setting_int('rate_limit_minutes'), 10, 'one report per bar per 10 minutes (FR-13)');
select is(app.setting_int('session_timeout_minutes'), 90, 'sessions time out after 90 minutes (FR-10)');
select is(app.setting_int('night_boundary_hour'), 4, 'nights end at 4 a.m. (FR-22)');
select is(app.setting_int('retention_days'), 365, 'ID-linked data is kept for 1 year (FR-33)');
select is(
  (select count(*) from app.config c where c.key in ('active_nights', 'active_window_start', 'active_window_end')),
  0::bigint, 'the active-window settings are gone (PRD 5.4, since 2026-10-06)');
select is(app.setting('test_anon_ids'), '[]'::jsonb, 'no test IDs at launch');

select is(
  (select count(*) from app.config c
   where not exists (select 1 from app.config_history h where h.config_key = c.key and h.old_value is null)),
  0::bigint, 'every starting setting was logged in config_history');

-- The 2026-10-07 wipe (*_line_sizes_no_crowd.sql) ------------------------------------------
-- The migration deletes every report, wait, install, view, feedback row,
-- snapshot, spot check, deletion count, and rate-limit hold, and keeps bars,
-- settings, the settings log, and event nights. This database is fresh, so
-- these check the state it leaves.

select is(
  (select array_agg(t.name order by t.name)
   from (values
     ('rate_limit_holds',   (select count(*) from app.rate_limit_holds)),
     ('deletions',          (select count(*) from app.deletions)),
     ('spot_checks',        (select count(*) from app.spot_checks)),
     ('estimate_snapshots', (select count(*) from app.estimate_snapshots)),
     ('feedback',           (select count(*) from app.feedback)),
     ('views',              (select count(*) from app.views)),
     ('reports',            (select count(*) from app.reports)),
     ('wait_sessions',      (select count(*) from app.wait_sessions)),
     ('installs',           (select count(*) from app.installs))
   ) as t (name, n)
   where t.n > 0),
  null::text[],
  'after the wipe every data table is empty');
select is((select count(*) from app.config c where c.key = 'redo_minutes'), 1::bigint,
  'the wipe keeps the settings');
select ok(
  exists (select 1 from app.config_history h where h.config_key = 'active_nights' and h.new_value is null),
  'the wipe keeps the settings log (it still has the 2026-10-06 removal of active_nights)');

select * from finish();
rollback;
