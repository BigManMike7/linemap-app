-- Two separate rate-limit clocks (FR-13, approved 2026-10-04), and the
-- rate-limit holds that keep each clock running after a delete (FR-41).
--   timed   line_start (I'm in line), checked by start_session
--   manual  conditions and inside, checked by report_conditions and submit_report
--
-- Same conventions as reporting_api_test.sql: now() is fixed for the whole
-- transaction, each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)), and each person is a separate anonymous ID.
-- Person n's session and report IDs are 1000 * n + k, so every ID is unique.
-- Seed bars: 1 = Doggie's Pub, 2 = The Phyrst, 3 = Cafe 210 West.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(62);

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

create function pg_temp.holds(p_person integer) returns bigint
language sql stable as
$$ select count(*) from app.rate_limit_holds h where h.anon_id = pg_temp.uid(p_person) $$;

create function pg_temp.hold_kind(p_person integer) returns text
language sql stable as
$$ select h.kind from app.rate_limit_holds h where h.anon_id = pg_temp.uid(p_person) $$;

-- Person n uses anon ID uid(n) and install ID uid(n + 500).

-- I'm in line.
create function pg_temp.start(p_person integer, p_session integer, p_report integer,
                              p_bar bigint, p_at timestamptz)
returns jsonb
language sql as $$
  select public.start_session(
    p_client_session_id   => pg_temp.uid(p_session),
    p_client_report_id    => pg_temp.uid(p_report),
    p_anon_id             => pg_temp.uid(p_person),
    p_install_id          => pg_temp.uid(p_person + 500),
    p_bar_id              => p_bar,
    p_phone_time          => p_at,
    p_location_status     => 'denied',
    p_app_version         => '1.0',
    p_definitions_version => 1::smallint)
$$;

-- Line-size update in a session.
create function pg_temp.line(p_person integer, p_report integer, p_session integer,
                             p_at timestamptz, p_state text, p_line integer default null)
returns jsonb
language sql as $$
  select public.update_line_size(
    p_client_report_id    => pg_temp.uid(p_report),
    p_client_session_id   => pg_temp.uid(p_session),
    p_anon_id             => pg_temp.uid(p_person),
    p_install_id          => pg_temp.uid(p_person + 500),
    p_phone_time          => p_at,
    p_line_size_state     => p_state,
    p_location_status     => 'denied',
    p_app_version         => '1.0',
    p_definitions_version => 1::smallint,
    p_line_size           => p_line::smallint)
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

-- I'm inside (older builds), or the busyness answer after I'm in with p_session.
create function pg_temp.inside(p_person integer, p_report integer, p_bar bigint, p_at timestamptz,
                               p_busy integer default null, p_busy_state text default null,
                               p_session integer default null)
returns jsonb
language sql as $$
  select public.submit_report(
    p_client_report_id    => pg_temp.uid(p_report),
    p_anon_id             => pg_temp.uid(p_person),
    p_install_id          => pg_temp.uid(p_person + 500),
    p_bar_id              => p_bar,
    p_phone_time          => p_at,
    p_location_status     => 'denied',
    p_app_version         => '1.0',
    p_definitions_version => 1::smallint,
    p_busyness            => p_busy::smallint,
    p_busyness_state      => p_busy_state,
    p_client_session_id   => pg_temp.uid(p_session))
$$;

-- Report conditions (busyness 2 unless told otherwise).
create function pg_temp.cond(p_person integer, p_report integer, p_bar bigint, p_at timestamptz,
                             p_busy integer default 2)
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
    p_busyness            => p_busy::smallint,
    p_busyness_state      => 'answered')
$$;

-- Delete one report, or one wait.
create function pg_temp.del_report(p_person integer, p_report integer) returns jsonb
language sql as $$
  select public.delete_report(p_anon_id => pg_temp.uid(p_person),
                              p_client_report_id => pg_temp.uid(p_report))
$$;

create function pg_temp.del_wait(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.delete_report(p_anon_id => pg_temp.uid(p_person),
                              p_client_session_id => pg_temp.uid(p_session))
$$;

-- Structure ----------------------------------------------------------------------------

select ok(to_regprocedure('app.rate_limit_wait(uuid, bigint, timestamptz, text)') is not null,
  'app.rate_limit_wait takes a clock as its fourth parameter');
select ok(to_regprocedure('app.rate_limit_wait(uuid, bigint, timestamptz)') is null,
  'the old 3-parameter rate_limit_wait is gone');
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'rate_limit_wait'),
  1::bigint, 'there is exactly one rate_limit_wait');
select ok(
  (select not p.prosecdef
          and coalesce(p.proconfig, '{}'::text[])
              && array['search_path=""', 'search_path=', $q$search_path=''$q$]
   from pg_proc p
   where p.oid = 'app.rate_limit_wait(uuid, bigint, timestamptz, text)'::regprocedure),
  'rate_limit_wait is SECURITY INVOKER with an empty search_path');
select ok(
  not has_function_privilege('anon', 'app.rate_limit_wait(uuid, bigint, timestamptz, text)', 'execute')
  and not has_function_privilege('authenticated', 'app.rate_limit_wait(uuid, bigint, timestamptz, text)', 'execute'),
  'anon and authenticated cannot execute rate_limit_wait');
select throws_ok(
  $$select app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(1), now(), 'hourly')$$,
  '22023', 'unknown rate-limit clock: hourly', 'rate_limit_wait rejects an unknown clock name');
select throws_ok(
  $$select app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(1), now(), null::text)$$,
  '22023', 'unknown rate-limit clock: null', 'rate_limit_wait rejects a missing clock');

select col_not_null('app'::name, 'rate_limit_holds'::name, 'kind'::name, 'rate_limit_holds.kind is not null');
select is(
  (select count(*) from pg_constraint c
   where c.conrelid = 'app.rate_limit_holds'::regclass and c.contype = 'c'
     and c.conname = 'rate_limit_holds_kind_check'),
  1::bigint, 'the hold kind check exists under its name');
select throws_ok(
  $$insert into app.rate_limit_holds (anon_id, bar_id, kind, phone_time)
    values (pg_temp.uid(99), pg_temp.bar(1), 'line_update', now())$$,
  '23514', null, 'a hold cannot have an exempt kind');
select throws_ok(
  $$insert into app.rate_limit_holds (anon_id, bar_id, phone_time)
    values (pg_temp.uid(99), pg_temp.bar(1), now())$$,
  '23502', null, 'a hold needs a kind');

-- Person 1: Report conditions, then I'm in line at the same bar -------------------------------

insert into res values ('p1_cond', pg_temp.cond(1, 1001, pg_temp.bar(1), pg_temp.ago(100)));
insert into res values ('p1_start', pg_temp.start(1, 1002, 1003, pg_temp.bar(1), pg_temp.ago(95)));

select is(pg_temp.r('p1_cond') ->> 'ok', 'true', 'Report conditions is accepted');
select is(pg_temp.r('p1_start') ->> 'ok', 'true',
  'I''m in line 5 minutes after Report conditions at the same bar is allowed');
select is((pg_temp.session(1002)).status, 'open', 'the line is open');
select is((pg_temp.report(1003)).kind, 'line_start', 'the line has its line_start report');

-- Each clock, read directly: the conditions report at 100, the line start at 95.
select is(app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(1), pg_temp.ago(97), 'manual'), 420,
  'manual clock: 3 minutes after the conditions report, 7 minutes are left');
select is(app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(1), pg_temp.ago(97), 'timed'), 480,
  'timed clock: 2 minutes before the line start, 8 minutes are left');
select is(app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(2), pg_temp.ago(97), 'manual'), 0,
  'neither clock reaches another bar');

-- Person 2: I'm in line, then Report conditions, then each clock on its own ---------------------

insert into res values ('p2_start', pg_temp.start(2, 2001, 2002, pg_temp.bar(1), pg_temp.ago(100)));
insert into res values ('p2_cond', pg_temp.cond(2, 2003, pg_temp.bar(1), pg_temp.ago(95)));

select is(pg_temp.r('p2_cond') ->> 'ok', 'true',
  'Report conditions 5 minutes after I''m in line at the same bar is allowed');
select is((pg_temp.session(2001)).status, 'open', 'the line stays open');
select is((pg_temp.report(2003)).wait_session_id, null::bigint, 'the conditions report is not linked to the line');

-- A second manual report within 10 minutes.
insert into res values ('p2_cond_again', pg_temp.cond(2, 2004, pg_temp.bar(1), pg_temp.ago(92)));

select is(pg_temp.r('p2_cond_again') ->> 'error', 'rate_limited',
  'a second Report conditions 3 minutes later is rate_limited');
select is(pg_temp.r('p2_cond_again') ->> 'retry_after_seconds', '420', 'it is told the time left');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(2004)), 0::bigint,
  'the refused report is not saved');

-- Gave up, then I'm in line again at the same bar within 10 minutes.
insert into res values ('p2_gave_up', pg_temp.end_line(2, 2001, 'gave_up', pg_temp.ago(94)));
insert into res values ('p2_start_again', pg_temp.start(2, 2005, 2006, pg_temp.bar(1), pg_temp.ago(93)));

select is(pg_temp.r('p2_start_again') ->> 'error', 'rate_limited',
  'I''m in line 7 minutes after the last one, after giving up, is rate_limited');
select is(pg_temp.r('p2_start_again') ->> 'retry_after_seconds', '180', 'it is told the time left');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(2)), 1::bigint,
  'the refused line creates no session');

-- After 10 minutes each clock is free again.
insert into res values ('p2_start_later', pg_temp.start(2, 2007, 2008, pg_temp.bar(1), pg_temp.ago(89)));
insert into res values ('p2_cond_later', pg_temp.cond(2, 2009, pg_temp.bar(1), pg_temp.ago(84)));

select is(pg_temp.r('p2_start_later') ->> 'ok', 'true', 'I''m in line 11 minutes after the last one is accepted');
select is(pg_temp.r('p2_cond_later') ->> 'ok', 'true', 'Report conditions 11 minutes after the last one is accepted');
select is((pg_temp.session(2007)).status, 'open', 'the new line stays open');

-- Person 3: I'm inside (older builds) blocks Report conditions, not I'm in line -------------------

insert into res values ('p3_inside', pg_temp.inside(3, 3001, pg_temp.bar(2), pg_temp.ago(100)));
insert into res values ('p3_cond', pg_temp.cond(3, 3002, pg_temp.bar(2), pg_temp.ago(96)));
insert into res values ('p3_start', pg_temp.start(3, 3003, 3004, pg_temp.bar(2), pg_temp.ago(95)));

select is(pg_temp.r('p3_inside') ->> 'kind', 'inside', 'a plain I''m inside is a counted inside report');
select is(pg_temp.r('p3_cond') ->> 'error', 'rate_limited',
  'Report conditions 4 minutes after I''m inside is rate_limited: the same manual clock');
select is(pg_temp.r('p3_cond') ->> 'retry_after_seconds', '360', 'it is told the time left');
select is(pg_temp.r('p3_start') ->> 'ok', 'true', 'I''m in line 5 minutes after I''m inside is allowed');
select is((pg_temp.session(3003)).status, 'open', 'the line is open');

insert into res values ('p3_cond_later', pg_temp.cond(3, 3005, pg_temp.bar(2), pg_temp.ago(89)));

select is(pg_temp.r('p3_cond_later') ->> 'ok', 'true',
  'Report conditions 11 minutes after I''m inside is accepted, with a line open');

-- Person 4: Report conditions blocks I'm inside, not I'm in line ------------------------------------

insert into res values ('p4_cond', pg_temp.cond(4, 4001, pg_temp.bar(3), pg_temp.ago(100)));
insert into res values ('p4_inside', pg_temp.inside(4, 4002, pg_temp.bar(3), pg_temp.ago(97)));
insert into res values ('p4_start', pg_temp.start(4, 4003, 4004, pg_temp.bar(3), pg_temp.ago(96)));

select is(pg_temp.r('p4_cond') ->> 'ok', 'true', 'Report conditions is accepted');
select is(pg_temp.r('p4_inside') ->> 'error', 'rate_limited',
  'I''m inside 3 minutes after Report conditions is rate_limited: the same manual clock');
select is(pg_temp.r('p4_inside') ->> 'retry_after_seconds', '420', 'it is told the time left');
select is(pg_temp.r('p4_start') ->> 'ok', 'true', 'I''m in line 4 minutes after Report conditions is allowed');

-- Person 5: a deleted Report conditions holds the manual clock only ----------------------------------

insert into res values ('p5_cond', pg_temp.cond(5, 5001, pg_temp.bar(1), pg_temp.ago(60)));
insert into res values ('p5_del', pg_temp.del_report(5, 5001));
insert into res values ('p5_again', pg_temp.cond(5, 5002, pg_temp.bar(1), pg_temp.ago(57)));
insert into res values ('p5_start', pg_temp.start(5, 5003, 5004, pg_temp.bar(1), pg_temp.ago(56)));

select is(pg_temp.r('p5_del') ->> 'ok', 'true', 'the conditions report is deleted');
select is(pg_temp.hold_kind(5), 'conditions', 'its hold carries the kind conditions');
select is(pg_temp.r('p5_again') ->> 'error', 'rate_limited',
  'Report conditions 3 minutes after the deleted one is still rate_limited');
select is(pg_temp.r('p5_again') ->> 'retry_after_seconds', '420', 'the limit runs from the deleted report');
select is(pg_temp.r('p5_start') ->> 'ok', 'true', 'I''m in line 4 minutes after the deleted report is allowed');
select is((pg_temp.session(5003)).status, 'open', 'the line is open');

-- Person 6: a deleted wait holds the timed clock only ---------------------------------------------------

insert into res values ('p6_start', pg_temp.start(6, 6001, 6002, pg_temp.bar(2), pg_temp.ago(60)));
insert into res values ('p6_line', pg_temp.line(6, 6003, 6001, pg_temp.ago(58), 'answered', 3));
insert into res values ('p6_gave_up', pg_temp.end_line(6, 6001, 'gave_up', pg_temp.ago(57)));
insert into res values ('p6_del', pg_temp.del_wait(6, 6001));
insert into res values ('p6_again', pg_temp.start(6, 6004, 6005, pg_temp.bar(2), pg_temp.ago(55)));
insert into res values ('p6_cond', pg_temp.cond(6, 6006, pg_temp.bar(2), pg_temp.ago(55)));

select is(pg_temp.r('p6_del') ->> 'rows_removed', '3', 'the wait, its line start, and its update are deleted');
select is(pg_temp.holds(6), 1::bigint, 'only the line start leaves a hold, not the line-size update');
select is(pg_temp.hold_kind(6), 'line_start', 'the hold carries the kind line_start');
select is(pg_temp.r('p6_again') ->> 'error', 'rate_limited',
  'I''m in line 5 minutes after the deleted wait''s start is rate_limited');
select is(pg_temp.r('p6_again') ->> 'retry_after_seconds', '300', 'the limit runs from the deleted line start');
select is(pg_temp.r('p6_cond') ->> 'ok', 'true', 'Report conditions 5 minutes after the deleted wait''s start is allowed');

-- Each clock, read directly: the line_start hold at 60, the conditions report at 55.
select is(app.rate_limit_wait(pg_temp.uid(6), pg_temp.bar(2), pg_temp.ago(52), 'timed'), 120,
  'timed clock: counts the line_start hold');
select is(app.rate_limit_wait(pg_temp.uid(6), pg_temp.bar(2), pg_temp.ago(52), 'manual'), 420,
  'manual clock: counts the conditions report, not the line_start hold');

-- Person 7: a deleted I'm inside holds the manual clock ----------------------------------------------------

insert into res values ('p7_inside', pg_temp.inside(7, 7001, pg_temp.bar(3), pg_temp.ago(60)));
insert into res values ('p7_del', pg_temp.del_report(7, 7001));
insert into res values ('p7_cond', pg_temp.cond(7, 7002, pg_temp.bar(3), pg_temp.ago(58)));

select is(pg_temp.hold_kind(7), 'inside', 'a deleted I''m inside leaves a hold with the kind inside');
select is(pg_temp.r('p7_cond') ->> 'error', 'rate_limited',
  'Report conditions 2 minutes after a deleted I''m inside is rate_limited');

-- Person 8: line-size updates are never limited, and each is its own row ---------------------------------------

insert into res values ('p8_start', pg_temp.start(8, 8001, 8002, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p8_line_a', pg_temp.line(8, 8003, 8001, pg_temp.ago(29), 'answered', 2));
insert into res values ('p8_line_b', pg_temp.line(8, 8004, 8001, pg_temp.ago(28), 'answered', 3));
insert into res values ('p8_line_c', pg_temp.line(8, 8005, 8001, pg_temp.ago(27), 'answered', 4));
insert into res values ('p8_line_d', pg_temp.line(8, 8006, 8001, pg_temp.ago(27), 'skipped'));

select is((select count(*) from pg_temp.res x where x.name like 'p8_line_%' and x.j ->> 'ok' = 'true'), 4::bigint,
  'four line-size updates within 3 minutes are all accepted');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(8) and r.kind = 'line_update'), 4::bigint,
  'each line-size update is its own row');
select is(app.rate_limit_wait(pg_temp.uid(8), pg_temp.bar(1), pg_temp.ago(19), 'timed'), 0,
  'line-size updates do not count on the timed clock');
select is(app.rate_limit_wait(pg_temp.uid(8), pg_temp.bar(1), pg_temp.ago(19), 'manual'), 0,
  'line-size updates do not count on the manual clock');

-- Person 9: the busyness answer after I'm in does not count on the manual clock --------------------------

insert into res values ('p9_start', pg_temp.start(9, 9001, 9002, pg_temp.bar(2), pg_temp.ago(40)));
insert into res values ('p9_end', pg_temp.end_line(9, 9001, 'entered', pg_temp.ago(35)));
insert into res values ('p9_busy', pg_temp.inside(9, 9003, pg_temp.bar(2), pg_temp.ago(34),
                                                  p_busy => 3, p_busy_state => 'answered', p_session => 9001));
insert into res values ('p9_cond', pg_temp.cond(9, 9004, pg_temp.bar(2), pg_temp.ago(32), p_busy => 4));

select is(pg_temp.r('p9_busy') ->> 'kind', 'inside_after_entry', 'the busyness answer after I''m in is exempt');
select is(pg_temp.r('p9_cond') ->> 'ok', 'true',
  'Report conditions 2 minutes after the busyness answer and 8 after the line start is allowed');

select * from finish();
rollback;
