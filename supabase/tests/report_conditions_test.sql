-- Report conditions and Adjust time in whole minutes (approved 2026-10-04).
-- FR-7, FR-11 to FR-13, FR-16, FR-26, FR-27, FR-32, FR-38.
--
-- Same conventions as reporting_api_test.sql: now() is fixed for the whole
-- transaction, each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)), and each person is a separate anonymous ID.
-- Seed bars: 1 = Doggie's Pub, 2 = The Phyrst, 3 = Cafe 210 West.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(115);

-- Helpers ----------------------------------------------------------------------------

create temp table res (name text primary key, j jsonb);

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

create function pg_temp.ago(p_minutes integer) returns timestamptz
language sql stable as
$$ select now() - make_interval(mins => p_minutes) $$;

create function pg_temp.bar(p_order integer) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.display_order = p_order and not b.is_test $$;

create function pg_temp.r(p_name text) returns jsonb
language sql stable as
$$ select x.j from pg_temp.res x where x.name = p_name $$;

create function pg_temp.session(p_n integer) returns app.wait_sessions
language sql stable as
$$ select s.* from app.wait_sessions s where s.client_session_id = pg_temp.uid(p_n) $$;

create function pg_temp.report(p_n integer) returns app.reports
language sql stable as
$$ select r.* from app.reports r where r.client_report_id = pg_temp.uid(p_n) $$;

-- Person n uses anon ID uid(n) and install ID uid(n + 500).

-- I'm in line.
create function pg_temp.start(p_person integer, p_session integer, p_report integer,
                              p_bar bigint, p_at timestamptz, p_offset integer default null)
returns jsonb
language sql as $$
  select public.start_session(
    p_client_session_id    => pg_temp.uid(p_session),
    p_client_report_id     => pg_temp.uid(p_report),
    p_anon_id              => pg_temp.uid(p_person),
    p_install_id           => pg_temp.uid(p_person + 500),
    p_bar_id               => p_bar,
    p_phone_time           => p_at,
    p_location_status      => 'denied',
    p_app_version          => '1.0',
    p_definitions_version  => 1::smallint,
    p_start_offset_minutes => p_offset::smallint)
$$;

-- I'm in or Gave up.
create function pg_temp.end_line(p_person integer, p_session integer, p_outcome text, p_at timestamptz)
returns jsonb
language sql as $$
  select public.end_session(
    p_client_session_id => pg_temp.uid(p_session),
    p_anon_id           => pg_temp.uid(p_person),
    p_outcome           => p_outcome,
    p_phone_time        => p_at)
$$;

-- Report conditions.
create function pg_temp.cond(p_person integer, p_report integer, p_bar bigint, p_at timestamptz,
                             p_line integer default null, p_line_state text default null,
                             p_busy integer default null, p_busy_state text default null)
returns jsonb
language sql as $$
  select public.report_conditions(
    p_client_report_id    => pg_temp.uid(p_report),
    p_anon_id             => pg_temp.uid(p_person),
    p_install_id          => pg_temp.uid(p_person + 500),
    p_bar_id              => p_bar,
    p_phone_time          => p_at,
    p_location_status     => 'denied',
    p_app_version         => '1.0',
    p_definitions_version => 1::smallint,
    p_line_size           => p_line::smallint,
    p_line_size_state     => p_line_state,
    p_busyness            => p_busy::smallint,
    p_busyness_state      => p_busy_state)
$$;

-- A report row written straight into the table, to test the table checks.
create function pg_temp.raw(p_report integer, p_position text, p_kind text, p_session bigint)
returns void
language sql as $$
  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    wait_session_id, phone_time, location_status, uncertain, app_version, definitions_version)
  values (
    pg_temp.uid(p_report), pg_temp.uid(99), pg_temp.uid(599), pg_temp.bar(1), current_date,
    p_position, p_kind, p_session, now(), 'denied', true, '1.0', 1)
$$;

-- Adjust time: any whole minute from 0 to 90 (FR-7) --------------------------------------

insert into res values ('p1_start', pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(300), p_offset => 0));

select is(pg_temp.r('p1_start') ->> 'ok', 'true', 'start_session with offset 0 succeeds');
select is((pg_temp.session(1101)).start_offset_minutes, 0::smallint, 'Adjust time accepts 0 minutes');

insert into res values ('p1_1', pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(299), p_offset => 1));
select is((pg_temp.session(1101)).start_offset_minutes, 1::smallint, 'Adjust time accepts 1 minute');

insert into res values ('p1_37', pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(299), p_offset => 37));
select is((pg_temp.session(1101)).start_offset_minutes, 37::smallint, 'Adjust time accepts 37 minutes');

insert into res values ('p1_90', pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(299), p_offset => 90));
select is(pg_temp.r('p1_90') ->> 'ok', 'true', 're-sending the session with offset 90 succeeds');
select is((pg_temp.session(1101)).start_offset_minutes, 90::smallint, 'Adjust time accepts 90 minutes');

select throws_ok($$select pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(299), p_offset => -1)$$,
  '22023', 'start_offset_minutes must be between 0 and 90', 'an offset of -1 is rejected');
select throws_ok($$select pg_temp.start(1, 1101, 2101, pg_temp.bar(1), pg_temp.ago(299), p_offset => 91)$$,
  '22023', 'start_offset_minutes must be between 0 and 90', 'an offset of 91 is rejected');
select throws_ok($$select pg_temp.start(2, 1201, 2201, pg_temp.bar(1), pg_temp.ago(300), p_offset => 91)$$,
  '22023', 'start_offset_minutes must be between 0 and 90', 'a new session with an offset of 91 is rejected');
select is((pg_temp.session(1101)).start_offset_minutes, 90::smallint, 'rejected offsets change nothing');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(2)), 0::bigint,
  'a rejected new session is not saved');

select throws_ok(
  $$update app.wait_sessions set start_offset_minutes = 91 where client_session_id = pg_temp.uid(1101)$$,
  '23514', null, 'the table check rejects an offset of 91');
select throws_ok(
  $$update app.wait_sessions set start_offset_minutes = -1 where client_session_id = pg_temp.uid(1101)$$,
  '23514', null, 'the table check rejects a negative offset');

-- Measured wait with a 45-minute offset: 20 minutes timed + 45 = 65 minutes.
insert into res values ('p3_start', pg_temp.start(3, 1301, 2301, pg_temp.bar(2), pg_temp.ago(300), p_offset => 45));
insert into res values ('p3_end', pg_temp.end_line(3, 1301, 'entered', pg_temp.ago(280)));

select is((pg_temp.session(1301)).start_offset_minutes, 45::smallint, 'a new session keeps an offset of 45');
select is(pg_temp.r('p3_end') ->> 'measured_wait_seconds', '3900', 'measured wait with offset 45 = 20 + 45 minutes');
select is((pg_temp.session(1301)).measured_wait_seconds, 3900, 'the stored measured wait includes the offset');

-- Report conditions: both answers --------------------------------------------------------

insert into res values ('p10', pg_temp.cond(10, 1001, pg_temp.bar(1), pg_temp.ago(200),
                                            p_line => 3, p_line_state => 'answered',
                                            p_busy => 4, p_busy_state => 'answered'));

select is(pg_temp.r('p10'), '{"ok": true, "kind": "conditions"}'::jsonb, 'report_conditions returns ok and its kind');
select is((pg_temp.report(1001)).position, 'unspecified', 'the position is unspecified');
select is((pg_temp.report(1001)).kind, 'conditions', 'the kind is conditions');
select is((pg_temp.report(1001)).wait_session_id, null::bigint, 'a conditions report has no session');
select is((pg_temp.report(1001)).line_size, 3::smallint, 'the line size is saved');
select is((pg_temp.report(1001)).line_size_state, 'answered', 'the line size state is answered');
select is((pg_temp.report(1001)).busyness, 4::smallint, 'the busyness is saved');
select is((pg_temp.report(1001)).busyness_state, 'answered', 'the busyness state is answered');
select is((pg_temp.report(1001)).recalled_wait_state, null::text, 'no recalled wait is asked');
select is((pg_temp.report(1001)).phone_time, pg_temp.ago(200), 'the report keeps the phone time');
select is((pg_temp.report(1001)).night_date, app.night_date(pg_temp.ago(200)), 'the night date is set on the server (FR-22)');
select is((pg_temp.report(1001)).anon_id, pg_temp.uid(10), 'the report keeps the anonymous ID');
select is((pg_temp.report(1001)).install_id, pg_temp.uid(510), 'the report keeps the install ID');
select is((pg_temp.report(1001)).is_test, false, 'a real ID''s report is not a test row');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(10)), 0::bigint,
  'report_conditions creates no session');

-- A retry (FR-16): same answer, nothing changes, not rate-limited by itself.
insert into res values ('p10_retry', pg_temp.cond(10, 1001, pg_temp.bar(1), pg_temp.ago(199),
                                                  p_line => 1, p_line_state => 'answered'));

select is(pg_temp.r('p10_retry'), '{"ok": true, "kind": "conditions"}'::jsonb, 'a retry returns the same answer');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(10)), 1::bigint,
  'a retry does not duplicate the report');
select is((pg_temp.report(1001)).line_size, 3::smallint, 'a retry does not change the saved answers');
select is((pg_temp.report(1001)).phone_time, pg_temp.ago(200), 'a retry does not change the phone time');

-- One answer: the other is stored as skipped (FR-12) --------------------------------------

insert into res values ('p11', pg_temp.cond(11, 1011, pg_temp.bar(1), pg_temp.ago(200),
                                            p_line => 0, p_line_state => 'answered'));

select is(pg_temp.r('p11') ->> 'ok', 'true', 'line size alone is accepted');
select is((pg_temp.report(1011)).line_size, 0::smallint, 'line size 0 (nobody) is saved');
select is((pg_temp.report(1011)).busyness_state, 'skipped', 'busyness not sent is stored as skipped');
select is((pg_temp.report(1011)).busyness, null::smallint, 'skipped busyness has no value');

insert into res values ('p12', pg_temp.cond(12, 1021, pg_temp.bar(1), pg_temp.ago(200),
                                            p_line_state => 'skipped',
                                            p_busy => 1, p_busy_state => 'answered'));

select is(pg_temp.r('p12') ->> 'ok', 'true', 'busyness alone is accepted');
select is((pg_temp.report(1021)).busyness, 1::smallint, 'busyness 1 (quiet) is saved');
select is((pg_temp.report(1021)).line_size_state, 'skipped', 'an explicit skip is stored as skipped');
select is((pg_temp.report(1021)).line_size, null::smallint, 'skipped line size has no value');

insert into res values ('p13', pg_temp.cond(13, 1031, pg_temp.bar(1), pg_temp.ago(200),
                                            p_line => 5, p_line_state => 'answered',
                                            p_busy_state => 'cant_tell'));

select is((pg_temp.report(1031)).line_size, 5::smallint, 'reserved line size 5 is still valid');
select is((pg_temp.report(1031)).busyness_state, 'cant_tell', 'reserved cant_tell is still stored');

-- Bad input raises 22023 and saves nothing --------------------------------------------------

select throws_ok($$select pg_temp.cond(14, 1041, pg_temp.bar(1), pg_temp.ago(100))$$,
  '22023', 'report at least one answer', 'a report with no answers is rejected');
select throws_ok($$select pg_temp.cond(14, 1042, pg_temp.bar(1), pg_temp.ago(100),
                                       p_line_state => 'skipped', p_busy_state => 'skipped')$$,
  '22023', 'report at least one answer', 'a report with both answers skipped is rejected');
select throws_ok($$select pg_temp.cond(14, 1043, pg_temp.bar(1), pg_temp.ago(100),
                                       p_line_state => 'cant_tell')$$,
  '22023', 'report at least one answer', 'cant_tell alone is not an answer');
select throws_ok($$select pg_temp.cond(14, 1044, pg_temp.bar(1), pg_temp.ago(100), p_line => 6, p_line_state => 'answered')$$,
  '22023', null, 'line size code 6 is out of range');
select throws_ok($$select pg_temp.cond(14, 1045, pg_temp.bar(1), pg_temp.ago(100), p_line => -1, p_line_state => 'answered')$$,
  '22023', null, 'line size code -1 is out of range');
select throws_ok($$select pg_temp.cond(14, 1046, pg_temp.bar(1), pg_temp.ago(100), p_busy => 0, p_busy_state => 'answered')$$,
  '22023', null, 'busyness code 0 is out of range');
select throws_ok($$select pg_temp.cond(14, 1047, pg_temp.bar(1), pg_temp.ago(100), p_busy => 5, p_busy_state => 'answered')$$,
  '22023', null, 'busyness code 5 is out of range');
select throws_ok($$select pg_temp.cond(14, 1048, pg_temp.bar(1), pg_temp.ago(100), p_busy => 2)$$,
  '22023', null, 'a value without a state is rejected');
select throws_ok($$select pg_temp.cond(14, 1049, pg_temp.bar(1), pg_temp.ago(100), p_line_state => 'answered')$$,
  '22023', null, 'answered without a value is rejected');
select throws_ok($$select pg_temp.cond(14, 1050, pg_temp.bar(1), pg_temp.ago(100), p_busy_state => 'maybe')$$,
  '22023', null, 'an unknown answer state is rejected');
select throws_ok($$select pg_temp.cond(14, 1051, 999999, pg_temp.ago(100), p_busy => 2, p_busy_state => 'answered')$$,
  '22023', 'unknown bar', 'an unknown bar is rejected');
select throws_ok(
  $$select public.report_conditions(
      p_client_report_id => null, p_anon_id => pg_temp.uid(14), p_install_id => pg_temp.uid(514),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'denied',
      p_app_version => '1.0', p_definitions_version => 1::smallint,
      p_busyness => 2::smallint, p_busyness_state => 'answered')$$,
  '22023', 'client_report_id is required', 'a missing client_report_id is rejected');
select throws_ok(
  $$select public.report_conditions(
      p_client_report_id => pg_temp.uid(1052), p_anon_id => null, p_install_id => pg_temp.uid(514),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'denied',
      p_app_version => '1.0', p_definitions_version => 1::smallint,
      p_busyness => 2::smallint, p_busyness_state => 'answered')$$,
  '22023', 'anon_id is required', 'a missing anon ID is rejected');
select throws_ok(
  $$select public.report_conditions(
      p_client_report_id => pg_temp.uid(1053), p_anon_id => pg_temp.uid(14), p_install_id => pg_temp.uid(514),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'gps',
      p_app_version => '1.0', p_definitions_version => 1::smallint,
      p_busyness => 2::smallint, p_busyness_state => 'answered')$$,
  '22023', 'invalid location_status', 'an unknown location status is rejected');
select throws_ok(
  $$select public.report_conditions(
      p_client_report_id => pg_temp.uid(1054), p_anon_id => pg_temp.uid(14), p_install_id => pg_temp.uid(514),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'denied',
      p_app_version => '1.0', p_definitions_version => 2::smallint,
      p_busyness => 2::smallint, p_busyness_state => 'answered')$$,
  '22023', 'unsupported definitions_version', 'an unsupported definitions version is rejected');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(14)), 0::bigint,
  'rejected reports save nothing');

-- A report ID that belongs to another report --------------------------------------------------

select throws_ok($$select pg_temp.cond(15, 1001, pg_temp.bar(1), pg_temp.ago(100), p_busy => 2, p_busy_state => 'answered')$$,
  '22023', 'client_report_id belongs to another report', 'another anon reusing a conditions report ID is rejected');

insert into res values ('p16_start', pg_temp.start(16, 1601, 2601, pg_temp.bar(2), pg_temp.ago(300)));

select throws_ok($$select pg_temp.cond(16, 2601, pg_temp.bar(2), pg_temp.ago(200), p_busy => 2, p_busy_state => 'answered')$$,
  '22023', 'client_report_id belongs to another report', 'reusing one''s own line_start report ID is rejected');
select is((pg_temp.report(2601)).kind, 'line_start', 'the line_start report keeps its kind');
select is((pg_temp.report(1001)).anon_id, pg_temp.uid(10), 'the conditions report keeps its owner');

-- Rate limit (FR-13): conditions is on the manual clock with I'm inside ----------------------
-- I'm in line has its own timed clock, so neither blocks the other.

-- Person 17: I'm in line, then Report conditions at the same bar 5 minutes later.
insert into res values ('p17_start', pg_temp.start(17, 1701, 2701, pg_temp.bar(1), pg_temp.ago(100)));
insert into res values ('p17_cond', pg_temp.cond(17, 1702, pg_temp.bar(1), pg_temp.ago(95),
                                                 p_busy => 2, p_busy_state => 'answered'));

select is(pg_temp.r('p17_cond') ->> 'ok', 'true', 'Report conditions 5 minutes after I''m in line is allowed: separate clocks');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(1702)), 1::bigint,
  'the conditions report is saved');
select is((pg_temp.session(1701)).status, 'open', 'the line stays open');
select is((pg_temp.report(1702)).wait_session_id, null::bigint, 'the conditions report is not linked to the line');

insert into res values ('p17_other', pg_temp.cond(17, 1703, pg_temp.bar(2), pg_temp.ago(95),
                                                  p_busy => 2, p_busy_state => 'answered'));

select is(pg_temp.r('p17_other') ->> 'ok', 'true', 'Report conditions at a different bar is fine');

-- Person 18: Report conditions, then other manual reports at the same bar, then I'm in line.
insert into res values ('p18_cond', pg_temp.cond(18, 1801, pg_temp.bar(1), pg_temp.ago(100),
                                                 p_line => 2, p_line_state => 'answered'));
insert into res values ('p18_cond_again', pg_temp.cond(18, 1803, pg_temp.bar(1), pg_temp.ago(97),
                                                       p_line => 3, p_line_state => 'answered'));
insert into res values ('p18_inside', public.submit_report(
  p_client_report_id => pg_temp.uid(1804), p_anon_id => pg_temp.uid(18), p_install_id => pg_temp.uid(518),
  p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(96), p_location_status => 'denied',
  p_app_version => '1.0', p_definitions_version => 1::smallint));

select is(pg_temp.r('p18_cond') ->> 'ok', 'true', 'the first conditions report is accepted');
select is(pg_temp.r('p18_cond_again') ->> 'error', 'rate_limited', 'a second conditions report 3 minutes later is rate-limited');
select is(pg_temp.r('p18_inside') ->> 'error', 'rate_limited',
  'I''m inside (older builds) after Report conditions is rate-limited: same manual clock');

insert into res values ('p18_start', pg_temp.start(18, 1802, 2802, pg_temp.bar(1), pg_temp.ago(95)));

select is(pg_temp.r('p18_start') ->> 'ok', 'true', 'I''m in line 5 minutes after Report conditions is allowed: separate clocks');
select is((pg_temp.session(1802)).status, 'open', 'the line is open');
select is((pg_temp.report(2802)).kind, 'line_start', 'the line has its line_start report');

insert into res values ('p18_later', pg_temp.cond(18, 1805, pg_temp.bar(1), pg_temp.ago(89),
                                                  p_line => 3, p_line_state => 'answered'));

select is(pg_temp.r('p18_later') ->> 'ok', 'true', 'Report conditions 11 minutes later is accepted');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(18) and r.kind = 'conditions'), 2::bigint,
  'only the two accepted conditions reports are saved');

-- Wait sessions are never touched ------------------------------------------------------------
-- Person 19 is in line at bar 1 and reports conditions at bar 1 and bar 2.

insert into res values ('p19_start', pg_temp.start(19, 1901, 2901, pg_temp.bar(1), pg_temp.ago(60)));
insert into res values ('p19_cond', pg_temp.cond(19, 1902, pg_temp.bar(1), pg_temp.ago(45),
                                                 p_line => 2, p_line_state => 'answered',
                                                 p_busy => 3, p_busy_state => 'answered'));

select is(pg_temp.r('p19_cond') ->> 'ok', 'true', 'Report conditions with an open session at that bar succeeds');
select is((pg_temp.session(1901)).status, 'open', 'the open session at the same bar stays open (no FR-15)');
select is((pg_temp.session(1901)).ended_by, null::text, 'the session has not ended');
select is((pg_temp.report(1902)).wait_session_id, null::bigint, 'the conditions report is not linked to the session');

insert into res values ('p19_cond_b', pg_temp.cond(19, 1903, pg_temp.bar(2), pg_temp.ago(44),
                                                   p_busy => 2, p_busy_state => 'answered'));

select is(pg_temp.r('p19_cond_b') ->> 'ok', 'true', 'Report conditions at another bar succeeds');
select is((pg_temp.session(1901)).status, 'open', 'a report at another bar does not end the session (no FR-14)');
select is((pg_temp.report(2901)).line_size_state, null::text, 'the line_start report is untouched');

insert into res values ('p19_end', pg_temp.end_line(19, 1901, 'entered', pg_temp.ago(40)));

select is(pg_temp.r('p19_end') ->> 'measured_wait_seconds', '1200', 'I''m in still measures the whole wait');

-- Location (FR-26, FR-27) and time ---------------------------------------------------------------

insert into res values ('p20', public.report_conditions(
  p_client_report_id    => pg_temp.uid(2001),
  p_anon_id             => pg_temp.uid(20),
  p_install_id          => pg_temp.uid(520),
  p_bar_id              => pg_temp.bar(1),
  p_phone_time          => pg_temp.ago(100),
  p_location_status     => 'precise',
  p_app_version         => '1.0',
  p_definitions_version => 1::smallint,
  p_lat                 => (select b.door_lat from app.bars b where b.id = pg_temp.bar(1)),
  p_lon                 => (select b.door_lon from app.bars b where b.id = pg_temp.bar(1)),
  p_accuracy_m          => 12,
  p_fix_age_s           => 3,
  p_busyness            => 2::smallint,
  p_busyness_state      => 'answered'));

select is((pg_temp.report(2001)).uncertain, false, 'a precise report at the door is not uncertain');
select ok((pg_temp.report(2001)).distance_m < 1, 'distance at the door is about 0 m');
select is((pg_temp.report(2001)).accuracy_m, 12::real, 'accuracy is stored');
select is((pg_temp.report(2001)).location_status, 'precise', 'location status is stored');

insert into res values ('p21', public.report_conditions(
  p_client_report_id    => pg_temp.uid(2111),
  p_anon_id             => pg_temp.uid(21),
  p_install_id          => pg_temp.uid(521),
  p_bar_id              => pg_temp.bar(1),
  p_phone_time          => pg_temp.ago(100),
  p_location_status     => 'no_fix',
  p_app_version         => '1.0',
  p_definitions_version => 1::smallint,
  p_busyness            => 2::smallint,
  p_busyness_state      => 'answered'));

select is(pg_temp.r('p21') ->> 'ok', 'true', 'a report with no fix is accepted, not rejected (FR-27)');
select is((pg_temp.report(2111)).uncertain, true, 'a report with no fix is uncertain');
select is((pg_temp.report(2111)).distance_m, null::real, 'a report with no fix has no distance');

insert into res values ('p22', pg_temp.cond(22, 2201, pg_temp.bar(1), now() + interval '2 hours',
                                            p_busy => 2, p_busy_state => 'answered'));

select is((pg_temp.report(2201)).phone_time, now(), 'a phone time in the future is capped at server time');

-- Test data (FR-38) --------------------------------------------------------------------------------

update app.config set value = '["ABCDEF00-0000-4000-8000-0000000000AA"]' where key = 'test_anon_ids';

insert into res values ('t_cond', public.report_conditions(
  p_client_report_id => pg_temp.uid(9001), p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa',
  p_install_id => pg_temp.uid(9002), p_bar_id => pg_temp.bar(3), p_phone_time => pg_temp.ago(10),
  p_location_status => 'no_fix', p_app_version => '1.0', p_definitions_version => 1::smallint,
  p_line_size => 1::smallint, p_line_size_state => 'answered'));

select is((pg_temp.report(9001)).is_test, true, 'a test ID''s conditions report is a test row');

-- Estimates use conditions reports (FR-17 to FR-19) ------------------------------------------------

insert into app.bars (name, address, door_lat, door_lon, display_order)
values ('Conditions bar', 'Test address', 40.7940, -77.8610, 100);

create function pg_temp.est() returns jsonb
language sql stable as $$
  select e
  from jsonb_array_elements(public.get_estimates() -> 'bars') as e
  where (e ->> 'bar_id')::bigint = (select b.id from app.bars b where b.name = 'Conditions bar')
$$;

insert into res values ('p30', pg_temp.cond(30, 3001, (select b.id from app.bars b where b.name = 'Conditions bar'),
                                            pg_temp.ago(5), p_line => 2, p_line_state => 'answered',
                                            p_busy => 3, p_busy_state => 'answered'));

select is(pg_temp.est() -> 'line_size' ->> 'code', '2', 'get_estimates shows the line size from a conditions report');
select is(pg_temp.est() -> 'line_size' ->> 'freshness', 'fresh', 'the conditions line size is fresh');
select is(pg_temp.est() -> 'busyness' ->> 'code', '3', 'get_estimates shows the busyness from a conditions report');
select is(pg_temp.est() -> 'wait', 'null'::jsonb, 'a conditions report gives no wait');
select is(pg_temp.est() ->> 'people', '1', 'the reporter counts as one person');

-- Person 31 answers only line size; the skipped busyness is not a signal.
insert into res values ('p31', pg_temp.cond(31, 3101, (select b.id from app.bars b where b.name = 'Conditions bar'),
                                            pg_temp.ago(4), p_line => 1, p_line_state => 'answered'));

select is(pg_temp.est() -> 'line_size' ->> 'code', '1', 'the newest line size wins (FR-19)');
select is(pg_temp.est() -> 'busyness' ->> 'code', '3', 'a skipped busyness does not replace the last one');
select is(pg_temp.est() ->> 'people', '2', 'both reporters count');

-- Table checks --------------------------------------------------------------------------------------

select is(
  (select array_agg(c.conname::text order by c.conname::text)
   from pg_constraint c
   where c.conrelid = 'app.reports'::regclass and c.contype = 'c'
     and c.conname in ('reports_position_check', 'reports_kind_check',
                       'reports_session_matches_kind', 'reports_unspecified_is_conditions')),
  array['reports_kind_check', 'reports_position_check',
        'reports_session_matches_kind', 'reports_unspecified_is_conditions'],
  'the new report checks exist under their names');
select is(
  (select count(*) from pg_constraint c where c.conrelid = 'app.reports'::regclass and c.contype = 'c'),
  16::bigint,
  'app.reports has 16 checks: the 3 replaced ones are gone');
select is(
  (select count(*) from pg_constraint c
   where c.conrelid = 'app.wait_sessions'::regclass and c.contype = 'c'
     and c.conname = 'wait_sessions_start_offset_minutes_check'
     and pg_get_constraintdef(c.oid) like '%90%'),
  1::bigint,
  'wait_sessions has one start offset check, up to 90');

select throws_ok($$select pg_temp.raw(9101, 'unspecified', 'conditions', (pg_temp.session(1901)).id)$$,
  '23514', null, 'a conditions report cannot belong to a session');
select throws_ok($$select pg_temp.raw(9102, 'unspecified', 'inside', null)$$,
  '23514', null, 'only a conditions report has an unspecified position');
select throws_ok($$select pg_temp.raw(9103, 'inside', 'conditions', null)$$,
  '23514', null, 'a conditions report always has an unspecified position');
select throws_ok($$select pg_temp.raw(9104, 'outside', 'conditions', null)$$,
  '23514', null, 'an unknown position is rejected');
select lives_ok($$select pg_temp.raw(9105, 'inside', 'inside', null)$$,
  'existing kinds and positions still work');

-- Delete my data (FR-32) and retention (FR-33) -------------------------------------------------------

insert into res values ('delete_10', public.delete_my_data(pg_temp.uid(10)));

select is(pg_temp.r('delete_10') ->> 'rows_removed', '1', 'delete_my_data counts the conditions report');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(10)), 0::bigint,
  'delete_my_data removes conditions reports');

select ok(app.purge_old_data(now() + interval '2 years') > 0, 'a purge two years from now removes rows');
select is((select count(*) from app.reports r where r.kind = 'conditions'), 0::bigint,
  'retention removes old conditions reports');

select * from finish();
rollback;
