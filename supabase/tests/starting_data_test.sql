-- Starting data: the three bars (PRD 7.3) and the default settings (FR-37).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(17);

-- Bars --------------------------------------------------------------------------------

select set_eq(
  $$select b.name from app.bars b where b.active$$,
  array['Doggie''s Pub', 'The Phyrst', 'Cafe 210 West'],
  'the three starting bars are active');
select is((select count(*) from app.bars), 3::bigint, 'there are no other bars');
select is((select count(*) from app.bars where is_test), 0::bigint, 'no starting bar is a test row');
select is(
  (select array_agg(b.address order by b.display_order) from app.bars b),
  array['108 S Pugh St, State College, PA 16801',
        '111 E Beaver Ave, State College, PA 16801',
        '210 W College Ave, State College, PA 16801'],
  'the bars have the PRD addresses, in display order');
select is(
  (select count(*) from app.bars b
   where b.door_lat between 40.78 and 40.81 and b.door_lon between -77.88 and -77.84),
  3::bigint, 'every door pin is in downtown State College');

-- Settings ----------------------------------------------------------------------------

select is(
  (select array_agg(k order by k) from unnest(array[
     'active_nights', 'active_window_end', 'active_window_start', 'agree_within',
     'fresh_minutes', 'majority_min_others', 'night_boundary_hour', 'rate_limit_minutes',
     'retention_days', 'session_timeout_minutes', 'stale_minutes', 'test_anon_ids',
     'uncertain_accuracy_m', 'uncertain_distance_m', 'uncertain_fix_age_s']) as k
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
select is(app.setting('active_nights'), '[4, 5, 6]'::jsonb, 'active nights are Thursday to Saturday');
select is(app.setting('test_anon_ids'), '[]'::jsonb, 'no test IDs at launch');

select is(
  (select count(*) from app.config c
   where not exists (select 1 from app.config_history h where h.config_key = c.key and h.old_value is null)),
  0::bigint, 'every starting setting was logged in config_history');

select * from finish();
rollback;
