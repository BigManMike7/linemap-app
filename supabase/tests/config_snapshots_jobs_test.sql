-- Settings history (FR-37), estimate snapshots (FR-36), and scheduled jobs (PRD 7.2).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(32);

-- Config history (FR-37) ---------------------------------------------------------------

create temp table before_counts as
select (select count(*) from app.config_history) as total,
       (select count(*) from app.config_history where config_key = 'fresh_minutes') as fresh;

update app.config set value = '35' where key = 'fresh_minutes';

select is((select count(*) from app.config_history where config_key = 'fresh_minutes'),
  (select fresh + 1 from before_counts), 'changing a setting logs one history row');
select is((select h.old_value from app.config_history h where h.config_key = 'fresh_minutes' order by h.id desc limit 1),
  '30'::jsonb, 'the history row has the old value');
select is((select h.new_value from app.config_history h where h.config_key = 'fresh_minutes' order by h.id desc limit 1),
  '35'::jsonb, 'the history row has the new value');
select is((select h.changed_by from app.config_history h where h.config_key = 'fresh_minutes' order by h.id desc limit 1),
  current_user::text, 'the history row records who changed it');
select is(app.setting_int('fresh_minutes'), 35, 'the new value is used right away');

update app.config set value = '35' where key = 'fresh_minutes';

select is((select count(*) from app.config_history where config_key = 'fresh_minutes'),
  (select fresh + 1 from before_counts), 'an update that keeps the same value logs nothing');

update app.config set description = 'Edited description.' where key = 'fresh_minutes';

select is((select count(*) from app.config_history where config_key = 'fresh_minutes'),
  (select fresh + 1 from before_counts), 'changing only the description logs nothing');

insert into app.config (key, value, description) values ('test_setting', '1', 'A test setting.');

select is((select h.old_value from app.config_history h where h.config_key = 'test_setting' order by h.id desc limit 1),
  null::jsonb, 'a new setting is logged with no old value');
select is((select h.new_value from app.config_history h where h.config_key = 'test_setting' order by h.id desc limit 1),
  '1'::jsonb, 'a new setting is logged with its value');

delete from app.config where key = 'test_setting';

select is((select h.new_value from app.config_history h where h.config_key = 'test_setting' order by h.id desc limit 1),
  null::jsonb, 'a deleted setting is logged with no new value');
select is((select count(*) from app.config_history), (select total + 3 from before_counts),
  'exactly three history rows were added (change, insert, delete)');

select throws_ok($$select app.setting('no_such_setting')$$, 'P0001', 'missing setting: no_such_setting',
  'a missing setting raises');

-- Snapshots (FR-36) ----------------------------------------------------------------------
-- At any hour (since 2026-10-06), one row per active non-test bar with a real
-- report within the last hour. A bar with no snapshot was showing "No live
-- reports".

insert into app.bars (name, address, door_lat, door_lon, active)
values ('Closed for good', 'Test address', 40.7940, -77.8610, false);
insert into app.bars (name, address, door_lat, door_lon, is_test)
values ('Snapshot test bar', 'Test address', 40.7940, -77.8610, true);

-- A line-size report (code 3) at a bar, by name.
create function pg_temp.rep(p_bar text, p_at timestamptz, p_is_test boolean default false)
returns void
language sql as $$
  insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                           line_size, line_size_state, phone_time, location_status, uncertain,
                           app_version, definitions_version, is_test)
  select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), b.id, app.night_date(p_at), 'inside', 'inside',
         3, 'answered', p_at, 'denied', true, '1.0', 1, p_is_test
  from app.bars b where b.name = p_bar
$$;

-- Tuesday Oct 6, 2026, a weekday morning: a real report at Doggie's Pub at
-- 10:50 a.m.; a test report at Brothers Bar & Grill (must not reach a snapshot); real
-- reports at an inactive bar and at a test bar (never snapshotted). Cafe 210
-- West has a report only on Saturday Oct 3 at 2:20 a.m., after a Friday night
-- (the old "Closed" hours).
select pg_temp.rep('Doggie''s Pub', '2026-10-06 10:50 America/New_York');
select pg_temp.rep('Brothers Bar & Grill', '2026-10-06 10:55 America/New_York', p_is_test => true);
select pg_temp.rep('Closed for good', '2026-10-06 10:55 America/New_York');
select pg_temp.rep('Snapshot test bar', '2026-10-06 10:55 America/New_York');
select pg_temp.rep('Cafe 210 West', '2026-10-03 02:20 America/New_York');

select is(app.take_snapshots('2026-10-06 11:00 America/New_York'), 1,
  'at 11 a.m. on a Tuesday, a snapshot is saved for the bar with a recent report');
select set_eq(
  $$select s.bar_id from app.estimate_snapshots s where s.taken_at = '2026-10-06 11:00 America/New_York'$$,
  $$select b.id from app.bars b where b.name = 'Doggie''s Pub'$$,
  'only that bar: not inactive bars, test bars, or bars without a real report');
select is(
  (select count(*) from app.estimate_snapshots s join app.bars b on b.id = s.bar_id
   where b.name in ('Brothers Bar & Grill', 'Cafe 210 West')),
  0::bigint, 'nothing is saved for a bar without a recent real report (snapshots never include test rows)');
select is((select bool_and(s.logic_version = app.logic_version()) from app.estimate_snapshots s), true,
  'snapshots record the logic version');
select is((select s.estimate ->> 'display' from app.estimate_snapshots s
           where s.taken_at = '2026-10-06 11:00 America/New_York'),
  'estimate', 'a saved snapshot shows an estimate');
select is((select s.estimate ->> 'bar_id' from app.estimate_snapshots s
           where s.taken_at = '2026-10-06 11:00 America/New_York'),
  (select b.id::text from app.bars b where b.name = 'Doggie''s Pub'), 'a snapshot holds the full bar estimate');
select is((select s.estimate -> 'line_size' ->> 'code' from app.estimate_snapshots s
           where s.taken_at = '2026-10-06 11:00 America/New_York'),
  '3', 'with its signals');

select is(app.take_snapshots('2026-10-06 11:35 America/New_York'), 1,
  'a 45-minute-old report still gets a snapshot');
select is((select s.estimate ->> 'freshness' from app.estimate_snapshots s
           where s.taken_at = '2026-10-06 11:35 America/New_York'),
  'stale', 'which shows it as stale, as the app did');
select is(app.take_snapshots('2026-10-06 11:51 America/New_York'), 0,
  'nothing is saved once the newest report is over an hour old');
select is(app.take_snapshots('2026-10-03 02:30 America/New_York'), 1,
  'snapshots are taken at 2:30 a.m. after a Friday night too (no more closed hours)');
select is((select count(*) from app.estimate_snapshots), 3::bigint, 'three snapshots were saved in all');

-- Scheduled jobs (PRD 7.2) ------------------------------------------------------------------

select is((select j.schedule from cron.job j where j.jobname = 'expire-sessions'), '*/5 * * * *',
  'expire-sessions runs every 5 minutes');
select is((select j.command from cron.job j where j.jobname = 'expire-sessions'), 'select app.expire_sessions()',
  'expire-sessions calls app.expire_sessions');
select is((select j.schedule from cron.job j where j.jobname = 'take-snapshots'), '*/5 * * * *',
  'take-snapshots runs every 5 minutes');
select is((select j.command from cron.job j where j.jobname = 'take-snapshots'), 'select app.take_snapshots()',
  'take-snapshots calls app.take_snapshots');
select is((select j.schedule from cron.job j where j.jobname = 'purge-old-data'), '15 9 * * *',
  'purge-old-data runs daily after the night boundary');
select is((select j.command from cron.job j where j.jobname = 'purge-old-data'), 'select app.purge_old_data()',
  'purge-old-data calls app.purge_old_data');
select is((select j.schedule from cron.job j where j.jobname = 'expire-rate-limit-holds'), '*/5 * * * *',
  'expire-rate-limit-holds runs every 5 minutes');
select is((select j.command from cron.job j where j.jobname = 'expire-rate-limit-holds'),
  'select app.expire_rate_limit_holds()', 'expire-rate-limit-holds calls app.expire_rate_limit_holds');

select * from finish();
rollback;
