-- Settings history (FR-37), estimate snapshots (FR-36), and scheduled jobs (PRD 7.2).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(27);

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
-- Friday Oct 2, 2026, 11 p.m. Eastern is live.

insert into app.bars (name, address, door_lat, door_lon, active)
values ('Closed for good', 'Test address', 40.7940, -77.8610, false);
insert into app.bars (name, address, door_lat, door_lon, is_test)
values ('Snapshot test bar', 'Test address', 40.7940, -77.8610, true);

-- A test report at a real bar must not reach the snapshot.
insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                         line_size, line_size_state, phone_time, location_status, uncertain,
                         app_version, definitions_version, is_test)
select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), b.id, '2026-10-02', 'inside', 'inside',
       3, 'answered', '2026-10-02 22:55 America/New_York', 'denied', true, '1.0', 1, true
from app.bars b where b.name = 'The Phyrst';

select is(app.take_snapshots('2026-10-02 23:00 America/New_York'), 3,
  'a live snapshot saves one row per active non-test bar');
select is((select count(*) from app.estimate_snapshots where taken_at = '2026-10-02 23:00 America/New_York'), 3::bigint,
  'three snapshot rows are saved');
select set_eq(
  $$select s.bar_id from app.estimate_snapshots s$$,
  $$select b.id from app.bars b where b.active and not b.is_test$$,
  'snapshots cover exactly the active non-test bars');
select is((select bool_and(s.logic_version = app.logic_version()) from app.estimate_snapshots s), true,
  'snapshots record the logic version');
select is((select s.estimate ->> 'display' from app.estimate_snapshots s join app.bars b on b.id = s.bar_id
           where b.name = 'The Phyrst'),
  'not_enough_data', 'snapshots never include test rows');
select is((select s.estimate ->> 'bar_id' from app.estimate_snapshots s join app.bars b on b.id = s.bar_id
           where b.name = 'The Phyrst'),
  (select b.id::text from app.bars b where b.name = 'The Phyrst'), 'a snapshot holds the full bar estimate');

select is(app.take_snapshots('2026-10-03 02:30 America/New_York'), 0, 'no snapshots while closed');
select is(app.take_snapshots('2026-10-05 20:00 America/New_York'), 0, 'no snapshots outside hours');
select is((select count(*) from app.estimate_snapshots), 3::bigint, 'only the live snapshot was saved');

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

select * from finish();
rollback;
