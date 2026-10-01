-- Delete my data (FR-32) and the retention job (FR-33).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(29);

-- Helpers ----------------------------------------------------------------------------

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

create function pg_temp.ago(p_minutes integer) returns timestamptz
language sql stable as
$$ select now() - make_interval(mins => p_minutes) $$;

create function pg_temp.bar(p_order integer) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.display_order = p_order and not b.is_test $$;

-- Rows per table for one anonymous ID.
create function pg_temp.counts(p_anon uuid) returns text
language sql stable as $$
  select format('installs=%s sessions=%s reports=%s views=%s feedback=%s',
    (select count(*) from app.installs where anon_id = p_anon),
    (select count(*) from app.wait_sessions where anon_id = p_anon),
    (select count(*) from app.reports where anon_id = p_anon),
    (select count(*) from app.views where anon_id = p_anon),
    (select count(*) from app.feedback where anon_id = p_anon))
$$;

-- Everything one person can create through the API: an install, a timed wait
-- with a line update, an I'm inside report, a view, and feedback (7 rows).
create function pg_temp.use_app(p_person integer) returns void
language plpgsql as $$
declare
  a uuid := pg_temp.uid(p_person);
  i uuid := pg_temp.uid(p_person + 500);
begin
  perform public.register_install(a, i, '1.0', '18.0', 'iPhone16,1');
  perform public.start_session(
    p_client_session_id => pg_temp.uid(p_person * 100 + 1), p_client_report_id => pg_temp.uid(p_person * 100 + 2),
    p_anon_id => a, p_install_id => i, p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(60),
    p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint);
  perform public.update_line_size(
    p_client_report_id => pg_temp.uid(p_person * 100 + 3), p_client_session_id => pg_temp.uid(p_person * 100 + 1),
    p_anon_id => a, p_install_id => i, p_phone_time => pg_temp.ago(55), p_line_size_state => 'answered',
    p_location_status => 'denied', p_app_version => '1.0', p_definitions_version => 1::smallint,
    p_line_size => 2::smallint);
  perform public.end_session(pg_temp.uid(p_person * 100 + 1), a, 'entered', pg_temp.ago(40));
  perform public.submit_report(
    p_client_report_id => pg_temp.uid(p_person * 100 + 4), p_anon_id => a, p_install_id => i,
    p_bar_id => pg_temp.bar(2), p_phone_time => pg_temp.ago(20), p_location_status => 'denied',
    p_app_version => '1.0', p_definitions_version => 1::smallint,
    p_busyness => 3::smallint, p_busyness_state => 'answered');
  perform public.log_view(
    p_anon_id => a, p_install_id => i, p_view_kind => 'map', p_app_open_id => pg_temp.uid(p_person * 100 + 5),
    p_viewed_at => pg_temp.ago(10), p_showed_no_data => false);
  perform public.send_feedback(a, i, pg_temp.bar(1), pg_temp.ago(5), '{"display": "estimate"}');
end;
$$;

create temp table res (name text primary key, j jsonb);

-- Delete my data (FR-32) -------------------------------------------------------------------

select pg_temp.use_app(60);
select pg_temp.use_app(61);

select is(pg_temp.counts(pg_temp.uid(60)), 'installs=1 sessions=1 reports=3 views=1 feedback=1',
  'person 60 has data in every table');
select is((select count(*) from app.deletions), 0::bigint, 'no deletions are logged yet');

insert into res values ('delete_60', public.delete_my_data(pg_temp.uid(60)));

select is((select j ->> 'ok' from res where name = 'delete_60'), 'true', 'delete_my_data succeeds');
select is((select j ->> 'rows_removed' from res where name = 'delete_60'), '7', 'it reports 7 rows removed');
select is(pg_temp.counts(pg_temp.uid(60)), 'installs=0 sessions=0 reports=0 views=0 feedback=0',
  'every row tied to the ID is gone');
select is(pg_temp.counts(pg_temp.uid(61)), 'installs=1 sessions=1 reports=3 views=1 feedback=1',
  'another person''s rows are untouched');
select is((select count(*) from app.deletions), 1::bigint, 'one deletion is logged');
select is((select d.reason from app.deletions d), 'user_request', 'the deletion reason is user_request');
select is((select d.rows_removed from app.deletions d), 7, 'the deletion log has the count');
select is((select d.is_test from app.deletions d), false, 'a real user''s deletion is not a test row');
select is(
  (select array_agg(a.attname::text order by a.attname::text)
   from pg_attribute a
   where a.attrelid = 'app.deletions'::regclass and a.attnum > 0 and not a.attisdropped),
  array['created_at', 'id', 'is_test', 'reason', 'rows_removed'],
  'the deletion log has no column that could hold an ID');

insert into res values ('delete_60_again', public.delete_my_data(pg_temp.uid(60)));

select is((select j ->> 'rows_removed' from res where name = 'delete_60_again'), '0', 'deleting again removes nothing');

-- A test ID's deletion is a test row.
update app.config set value = '["00000000-0000-4000-8000-000000000062"]' where key = 'test_anon_ids';
select pg_temp.use_app(62);
insert into res values ('delete_62', public.delete_my_data(pg_temp.uid(62)));

select is((select j ->> 'rows_removed' from res where name = 'delete_62'), '7', 'a test ID''s data is deleted too');
select is((select d.is_test from app.deletions d order by d.id desc limit 1), true, 'a test ID''s deletion is a test row');

-- Retention (FR-33) --------------------------------------------------------------------------
-- Person 70's rows are 400 days old; person 71's are new. A new line update that
-- belongs to an old session goes with its session.

insert into app.wait_sessions (client_session_id, anon_id, install_id, bar_id, night_date, started_at,
                               ended_at, status, ended_by, created_at)
values (pg_temp.uid(7001), pg_temp.uid(70), pg_temp.uid(570), pg_temp.bar(1), current_date - 400,
        now() - interval '400 days', now() - interval '400 days' + interval '20 minutes',
        'entered', 'im_in', now() - interval '400 days');

insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                         wait_session_id, phone_time, location_status, uncertain, app_version,
                         definitions_version, created_at)
values
  (pg_temp.uid(7002), pg_temp.uid(70), pg_temp.uid(570), pg_temp.bar(1), current_date - 400, 'line', 'line_start',
   (select s.id from app.wait_sessions s where s.client_session_id = pg_temp.uid(7001)),
   now() - interval '400 days', 'denied', true, '1.0', 1, now() - interval '400 days'),
  (pg_temp.uid(7003), pg_temp.uid(70), pg_temp.uid(570), pg_temp.bar(1), current_date, 'line', 'line_update',
   (select s.id from app.wait_sessions s where s.client_session_id = pg_temp.uid(7001)),
   now(), 'denied', true, '1.0', 1, now()),
  (pg_temp.uid(7004), pg_temp.uid(70), pg_temp.uid(570), pg_temp.bar(2), current_date - 400, 'inside', 'inside',
   null, now() - interval '400 days', 'denied', true, '1.0', 1, now() - interval '400 days'),
  (pg_temp.uid(7101), pg_temp.uid(71), pg_temp.uid(571), pg_temp.bar(2), current_date - 300, 'inside', 'inside',
   null, now() - interval '300 days', 'denied', true, '1.0', 1, now() - interval '300 days');

insert into app.views (anon_id, install_id, view_kind, viewed_at, showed_no_data, app_open_id, created_at)
values (pg_temp.uid(70), pg_temp.uid(570), 'map', now() - interval '400 days', true, pg_temp.uid(7005), now() - interval '400 days'),
       (pg_temp.uid(71), pg_temp.uid(571), 'map', now(), true, pg_temp.uid(7105), now());

insert into app.feedback (anon_id, install_id, bar_id, phone_time, created_at)
values (pg_temp.uid(70), pg_temp.uid(570), pg_temp.bar(1), now() - interval '400 days', now() - interval '400 days'),
       (pg_temp.uid(71), pg_temp.uid(571), pg_temp.bar(1), now(), now());

insert into app.installs (anon_id, install_id, first_seen_at, last_seen_at, app_version, ios_version, device_model, created_at)
values (pg_temp.uid(70), pg_temp.uid(570), now() - interval '500 days', now() - interval '400 days', '1.0', '17.0', 'iPhone15,2', now() - interval '500 days'),
       -- Installed long ago but still in use: kept.
       (pg_temp.uid(71), pg_temp.uid(571), now() - interval '500 days', now(), '1.0', '17.0', 'iPhone15,2', now() - interval '500 days');

insert into app.estimate_snapshots (bar_id, taken_at, estimate, logic_version, created_at)
values (pg_temp.bar(1), now() - interval '400 days', '{"display": "estimate"}', 1, now() - interval '400 days');

select is(app.purge_old_data(), 7, 'purge_old_data removes the 7 old ID-linked rows');
select is(pg_temp.counts(pg_temp.uid(70)), 'installs=0 sessions=0 reports=0 views=0 feedback=0',
  'every old row for person 70 is gone, including a new update in an old session');
select is(pg_temp.counts(pg_temp.uid(71)), 'installs=1 sessions=0 reports=1 views=1 feedback=1',
  'person 71''s newer rows and in-use install are kept');
select is((select count(*) from app.estimate_snapshots), 1::bigint, 'estimate snapshots are kept');
select is((select count(*) from app.deletions where reason = 'retention'), 1::bigint, 'the purge is logged');
select is((select d.rows_removed from app.deletions d where d.reason = 'retention'), 7, 'the purge log has the count');
select is(pg_temp.counts(pg_temp.uid(61)), 'installs=1 sessions=1 reports=3 views=1 feedback=1',
  'today''s rows are untouched by the purge');

select is(app.purge_old_data(), 0, 'a second purge removes nothing');
select is((select count(*) from app.deletions where reason = 'retention'), 1::bigint, 'a purge that removes nothing is not logged');

-- Retention follows the setting.
update app.config set value = '200' where key = 'retention_days';

select is(app.purge_old_data(), 1, 'a shorter retention removes person 71''s 300-day-old report');
select is(pg_temp.counts(pg_temp.uid(71)), 'installs=1 sessions=0 reports=0 views=1 feedback=1',
  'only rows older than retention_days are removed');

-- Left: person 61's 7 rows and person 71's install, view, and feedback.
select is(app.purge_old_data(now() + interval '1 year'), 10,
  'purge_old_data takes a time: a year from now, today''s rows are old');
select is(pg_temp.counts(pg_temp.uid(61)), 'installs=0 sessions=0 reports=0 views=0 feedback=0',
  'the time-shifted purge removes everything older than the cutoff');
select is((select count(*) from app.deletions where reason = 'retention'), 3::bigint, 'each purge that removes rows is logged');
select is((select count(*) from app.estimate_snapshots), 1::bigint, 'snapshots survive every purge');

select * from finish();
rollback;
