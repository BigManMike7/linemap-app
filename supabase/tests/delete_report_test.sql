-- Made a wrong report? (FR-41, approved 2026-10-04): my_recent_reports,
-- delete_report, rate-limit holds (FR-13), and the deletion log (FR-32).
--
-- Same conventions as reporting_api_test.sql: now() is fixed for the whole
-- transaction, each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)), and each person is a separate anonymous ID.
-- Seed bars: 1 = Doggie's Pub, 2 = The Phyrst, 3 = Cafe 210 West. Estimate
-- checks use a bar of their own, so no other scenario reaches them.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(101);

-- Helpers ----------------------------------------------------------------------------

create temp table res (name text primary key, j jsonb);

insert into app.bars (name, address, door_lat, door_lon, display_order)
values ('Delete test bar', 'Test address', 40.7940, -77.8610, 100);

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

create function pg_temp.ago(p_minutes integer) returns timestamptz
language sql stable as
$$ select now() - make_interval(mins => p_minutes) $$;

create function pg_temp.bar(p_order integer) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.display_order = p_order and not b.is_test $$;

create function pg_temp.dbar() returns bigint
language sql stable as
$$ select b.id from app.bars b where b.name = 'Delete test bar' $$;

create function pg_temp.r(p_name text) returns jsonb
language sql stable as
$$ select x.j from pg_temp.res x where x.name = p_name $$;

create function pg_temp.session(p_n integer) returns app.wait_sessions
language sql stable as
$$ select s.* from app.wait_sessions s where s.client_session_id = pg_temp.uid(p_n) $$;

create function pg_temp.holds(p_person integer) returns bigint
language sql stable as
$$ select count(*) from app.rate_limit_holds h where h.anon_id = pg_temp.uid(p_person) $$;

create function pg_temp.last_deletion() returns app.deletions
language sql stable as
$$ select d.* from app.deletions d order by d.id desc limit 1 $$;

create function pg_temp.recent(p_person integer) returns jsonb
language sql stable as
$$ select public.my_recent_reports(pg_temp.uid(p_person)) $$;

-- The delete test bar's estimate.
create function pg_temp.est() returns jsonb
language sql stable as $$
  select e
  from jsonb_array_elements(public.get_estimates() -> 'bars') as e
  where (e ->> 'bar_id')::bigint = pg_temp.dbar()
$$;

-- Person n uses anon ID uid(n) and install ID uid(n + 500).

-- I'm in line.
create function pg_temp.start(p_person integer, p_session integer, p_report integer,
                              p_bar bigint, p_at timestamptz,
                              p_line integer default null, p_line_state text default null)
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
    p_definitions_version => 1::smallint,
    p_line_size           => p_line::smallint,
    p_line_size_state     => p_line_state)
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
                               p_wait integer default null, p_wait_state text default null,
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
    p_recalled_wait       => p_wait::smallint,
    p_recalled_wait_state => p_wait_state,
    p_client_session_id   => pg_temp.uid(p_session))
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

-- Tables -----------------------------------------------------------------------------

select has_table('app'::name, 'rate_limit_holds'::name, 'app.rate_limit_holds exists');
select is(
  (select array_agg(a.attname::text order by a.attname::text)
   from pg_attribute a
   where a.attrelid = 'app.rate_limit_holds'::regclass and a.attnum > 0 and not a.attisdropped),
  array['anon_id', 'bar_id', 'created_at', 'id', 'is_test', 'kind', 'phone_time'],
  'a hold keeps only a person, a bar, a report kind, and a phone time');
select ok((select c.relrowsecurity from pg_class c where c.oid = 'app.rate_limit_holds'::regclass),
  'rate_limit_holds has row-level security enabled');
select is((select count(*) from pg_policies where schemaname = 'app' and tablename = 'rate_limit_holds'),
  0::bigint, 'rate_limit_holds has no RLS policies');
select is(
  (select array_agg(x order by x) from (
     select r.rolname || ':' || p.priv as x
     from (values ('anon'), ('authenticated')) as r (rolname)
     cross join (values ('select'), ('insert'), ('update'), ('delete'),
                        ('truncate'), ('references'), ('trigger')) as p (priv)
     where has_table_privilege(r.rolname, 'app.rate_limit_holds'::regclass::oid, p.priv)) g),
  null::text[],
  'anon and authenticated hold no privilege on rate_limit_holds');
select has_index('app'::name, 'rate_limit_holds'::name, 'rate_limit_holds_anon_bar_time'::name,
  array['anon_id', 'bar_id', 'phone_time']::name[],
  'the rate-limit lookup is indexed by anon_id, bar_id, phone_time');
select col_not_null('app'::name, 'deletions'::name, 'scope'::name, 'deletions.scope is not null');
select throws_ok(
  $$insert into app.deletions (reason, scope, rows_removed) values ('user_request', 'some', 1)$$,
  '23514', null, 'deletions.scope is only all or one');

-- my_recent_reports ------------------------------------------------------------------
-- Person 1, oldest first: two items from more than 24 hours ago, a timed wait
-- (line size 2, then 3, then a skip; a busyness-only answer after I'm in,
-- which stores nothing since 2026-10-07), a Report conditions (later hidden),
-- an I'm inside, a wait given up, and an open wait. Busyness is always null.

insert into res values ('p1_old_cond', pg_temp.cond(1, 1101, pg_temp.bar(1), pg_temp.ago(1500),
                                                    p_line => 2, p_line_state => 'answered'));
insert into res values ('p1_old_start', pg_temp.start(1, 1102, 1103, pg_temp.bar(2), pg_temp.ago(1450)));
insert into res values ('p1_old_end', pg_temp.end_line(1, 1102, 'entered', pg_temp.ago(1430)));
insert into res values ('p1_start', pg_temp.start(1, 1201, 1202, pg_temp.bar(1), pg_temp.ago(300),
                                                  p_line => 2, p_line_state => 'answered'));
insert into res values ('p1_line', pg_temp.line(1, 1203, 1201, pg_temp.ago(295), 'answered', 3));
insert into res values ('p1_skip', pg_temp.line(1, 1204, 1201, pg_temp.ago(290), 'skipped'));
insert into res values ('p1_end', pg_temp.end_line(1, 1201, 'entered', pg_temp.ago(280)));
insert into res values ('p1_busy', pg_temp.inside(1, 1205, pg_temp.bar(1), pg_temp.ago(279),
                                                  p_busy => 4, p_busy_state => 'answered', p_session => 1201));
insert into res values ('p1_cond', pg_temp.cond(1, 1301, pg_temp.bar(2), pg_temp.ago(200),
                                                p_line => 1, p_line_state => 'answered',
                                                p_busy => 2, p_busy_state => 'answered'));
insert into res values ('p1_inside', pg_temp.inside(1, 1401, pg_temp.bar(3), pg_temp.ago(100),
                                                    p_busy_state => 'skipped',
                                                    p_wait => 3, p_wait_state => 'answered'));
insert into res values ('p1_gave_start', pg_temp.start(1, 1501, 1502, pg_temp.bar(2), pg_temp.ago(50)));
insert into res values ('p1_gave_up', pg_temp.end_line(1, 1501, 'gave_up', pg_temp.ago(45)));
insert into res values ('p1_open', pg_temp.start(1, 1601, 1602, pg_temp.bar(3), pg_temp.ago(10)));

update app.reports set hidden = true, hidden_reason = 'Test: hidden by an admin'
where client_report_id = pg_temp.uid(1301);

select is(jsonb_typeof(pg_temp.recent(1)), 'array', 'my_recent_reports returns a JSON array');
select is(jsonb_array_length(pg_temp.recent(1)), 4,
  'it lists the 4 items from the last 24 hours, leaving out the open wait');
select is(
  (select array_agg(coalesce(x.e ->> 'client_session_id', x.e ->> 'client_report_id') order by x.k)
   from jsonb_array_elements(pg_temp.recent(1)) with ordinality as x (e, k)),
  array[pg_temp.uid(1501)::text, pg_temp.uid(1401)::text, pg_temp.uid(1301)::text, pg_temp.uid(1201)::text],
  'items are newest first');
select is(
  (select array_agg(x.e ->> 'type' order by x.k)
   from jsonb_array_elements(pg_temp.recent(1)) with ordinality as x (e, k)),
  array['wait', 'report', 'report', 'wait'],
  'each item says whether it is a report or a wait');
select is(pg_temp.recent(1) -> 0,
  jsonb_build_object('type', 'wait', 'client_session_id', pg_temp.uid(1501), 'bar_id', pg_temp.bar(2),
                     'at', pg_temp.ago(50), 'ended_at', pg_temp.ago(45), 'status', 'gave_up',
                     'measured_wait_seconds', null, 'start_offset_minutes', 0,
                     'line_size', null, 'busyness', null),
  'a wait given up on: no measured wait and no answers');
select is(pg_temp.recent(1) -> 1,
  jsonb_build_object('type', 'report', 'kind', 'inside', 'client_report_id', pg_temp.uid(1401),
                     'bar_id', pg_temp.bar(3), 'at', pg_temp.ago(100),
                     'line_size', null, 'busyness', null, 'recalled_wait', 3),
  'an I''m inside item has only its answered codes (a skipped busyness is null)');
select is(pg_temp.recent(1) -> 2,
  jsonb_build_object('type', 'report', 'kind', 'conditions', 'client_report_id', pg_temp.uid(1301),
                     'bar_id', pg_temp.bar(2), 'at', pg_temp.ago(200),
                     'line_size', 1, 'busyness', null, 'recalled_wait', null),
  'a Report conditions item is listed with its codes, even when hidden (busyness is never stored)');
select is(pg_temp.recent(1) -> 3,
  jsonb_build_object('type', 'wait', 'client_session_id', pg_temp.uid(1201), 'bar_id', pg_temp.bar(1),
                     'at', pg_temp.ago(300), 'ended_at', pg_temp.ago(280), 'status', 'entered',
                     'measured_wait_seconds', 1200, 'start_offset_minutes', 0,
                     'line_size', 3, 'busyness', null),
  'a timed wait has its measured wait and its newest answered line size; busyness is null');
select ok((pg_temp.recent(1) -> 0 ->> 'at') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?[+-]\d{2}:\d{2}$',
  'times are ISO 8601 with an offset, like get_estimates');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.recent(1)) as e
                      where e ->> 'client_session_id' = pg_temp.uid(1601)::text),
  'an open wait is not listed');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.recent(1)) as e
                      where coalesce(e ->> 'client_session_id', e ->> 'client_report_id')
                            in (pg_temp.uid(1101)::text, pg_temp.uid(1102)::text)),
  'a report from 25 hours ago and a wait started 24 h 10 min ago are not listed');

-- Person 2 only sees their own.
insert into res values ('p2_cond', pg_temp.cond(2, 2101, pg_temp.bar(1), pg_temp.ago(30),
                                                p_line => 3, p_line_state => 'answered'));

select is(jsonb_array_length(pg_temp.recent(2)), 1, 'another person sees only their own report');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.recent(1)) as e
                      where e ->> 'client_report_id' = pg_temp.uid(2101)::text),
  'nobody sees someone else''s reports');

-- Person 3: a wait past the timeout (FR-10).
insert into res values ('p3_start', pg_temp.start(3, 3101, 3102, pg_temp.bar(1), pg_temp.ago(200)));
insert into res values ('expire_sessions', to_jsonb(app.expire_sessions()));

select is(pg_temp.recent(3),
  jsonb_build_array(jsonb_build_object(
    'type', 'wait', 'client_session_id', pg_temp.uid(3101), 'bar_id', pg_temp.bar(1),
    'at', pg_temp.ago(200), 'ended_at', pg_temp.ago(110), 'status', 'unfinished',
    'measured_wait_seconds', null, 'start_offset_minutes', 0, 'line_size', null, 'busyness', null)),
  'an unfinished wait is listed, ended at the timeout');

select is(pg_temp.recent(4), '[]'::jsonb, 'a person with no reports gets an empty array');
select throws_ok($$select public.my_recent_reports(null)$$,
  '22023', 'anon_id is required', 'my_recent_reports needs an anon ID');

-- Person 5: 105 reports in the last 2 hours; only the newest 100 are listed.
insert into app.reports (client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
                         busyness, busyness_state, phone_time, location_status, uncertain,
                         app_version, definitions_version)
select pg_temp.uid(50000 + g), pg_temp.uid(5), pg_temp.uid(505), pg_temp.bar(1), current_date,
       'unspecified', 'conditions', 2, 'answered', pg_temp.ago(g), 'denied', true, '1.0', 1
from generate_series(1, 105) as g;

select is(jsonb_array_length(pg_temp.recent(5)), 100, 'at most 100 items are listed');
select is(pg_temp.recent(5) -> 0 ->> 'client_report_id', pg_temp.uid(50001)::text,
  'the newest item comes first');
select is(pg_temp.recent(5) -> 99 ->> 'client_report_id', pg_temp.uid(50100)::text,
  'the 5 oldest are left out');
select is(pg_temp.recent(5) -> 0 -> 'busyness', 'null'::jsonb,
  'busyness is always null, even for an older row that stored one');
select ok(pg_temp.recent(5) -> 0 ? 'busyness', 'the busyness key stays for older builds');

-- delete_report: one Report conditions, and the rate-limit hold -------------------------

insert into res values ('p10_cond', pg_temp.cond(10, 10001, pg_temp.bar(1), pg_temp.ago(30),
                                                 p_line => 2, p_line_state => 'answered'));
insert into res values ('p10_del', pg_temp.del_report(10, 10001));

select is(pg_temp.r('p10_del'), '{"ok": true, "rows_removed": 1}'::jsonb,
  'deleting a report returns ok and the rows removed');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(10001)), 0::bigint,
  'the report is really deleted');
select is(pg_temp.holds(10), 1::bigint, 'deleting a counted report leaves one rate-limit hold');
select is((select h.bar_id from app.rate_limit_holds h where h.anon_id = pg_temp.uid(10)), pg_temp.bar(1),
  'the hold is at the report''s bar');
select is((select h.phone_time from app.rate_limit_holds h where h.anon_id = pg_temp.uid(10)), pg_temp.ago(30),
  'the hold has the report''s phone time');
select is((select h.is_test from app.rate_limit_holds h where h.anon_id = pg_temp.uid(10)), false,
  'a real ID''s hold is not a test row');
select is((pg_temp.last_deletion()).scope, 'one', 'the deletion is logged with scope one');
select is((pg_temp.last_deletion()).reason, 'user_request', 'the deletion reason is user_request');
select is((pg_temp.last_deletion()).rows_removed, 1, 'the deletion log has the count');
select is(pg_temp.recent(10), '[]'::jsonb, 'a deleted report is no longer listed');

-- The deleted report's clock (manual) keeps running from it (FR-13); the
-- timed clock (I'm in line) is separate.
insert into res values ('p10_again', pg_temp.cond(10, 10002, pg_temp.bar(1), pg_temp.ago(25),
                                                  p_line => 2, p_line_state => 'answered'));
insert into res values ('p10_line', pg_temp.start(10, 10003, 10004, pg_temp.bar(1), pg_temp.ago(22)));
insert into res values ('p10_other_bar', pg_temp.cond(10, 10005, pg_temp.bar(2), pg_temp.ago(22),
                                                      p_line => 2, p_line_state => 'answered'));
insert into res values ('p10_later', pg_temp.cond(10, 10006, pg_temp.bar(1), pg_temp.ago(19),
                                                  p_line => 2, p_line_state => 'answered'));

select is(pg_temp.r('p10_again') ->> 'error', 'rate_limited',
  'Report conditions 5 minutes after a deleted one is still rate-limited');
select is(pg_temp.r('p10_again') ->> 'retry_after_seconds', '300',
  'the limit runs from the deleted report''s phone time');
select is(pg_temp.r('p10_line') ->> 'ok', 'true',
  'I''m in line 8 minutes after a deleted Report conditions is allowed: its hold is on the manual clock');
select is((select h.kind from app.rate_limit_holds h where h.anon_id = pg_temp.uid(10)), 'conditions',
  'the hold keeps the deleted report''s kind');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(10)), 1::bigint,
  'the line is saved');
select is(pg_temp.r('p10_other_bar') ->> 'ok', 'true', 'a hold only covers its own bar');
select is(pg_temp.r('p10_later') ->> 'ok', 'true', 'Report conditions 11 minutes after the deleted one is accepted');

insert into res values ('p10_del_again', pg_temp.del_report(10, 10001));

select is(pg_temp.r('p10_del_again'), '{"ok": false, "error": "not_found"}'::jsonb,
  'deleting the same report twice returns not_found');
select is(pg_temp.holds(10), 1::bigint, 'a second delete leaves no second hold');

-- delete_report: a finished wait, and estimates (FR-17 to FR-19) ----------------------------

insert into res values ('p12_start', pg_temp.start(12, 12001, 12002, pg_temp.dbar(), pg_temp.ago(50),
                                                   p_line => 2, p_line_state => 'answered'));
insert into res values ('p12_line', pg_temp.line(12, 12003, 12001, pg_temp.ago(45), 'answered', 3));
insert into res values ('p12_end', pg_temp.end_line(12, 12001, 'entered', pg_temp.ago(30)));
insert into res values ('p12_busy', pg_temp.inside(12, 12004, pg_temp.dbar(), pg_temp.ago(29),
                                                   p_busy => 4, p_busy_state => 'answered', p_session => 12001));

select is(pg_temp.est() -> 'wait' ->> 'source', 'measured', 'before the delete, the measured wait shows');
select is(pg_temp.est() -> 'wait' ->> 'minutes', '20', 'the measured wait is 20 minutes');
select is(pg_temp.est() -> 'line_size' ->> 'code', '3', 'the wait''s newest line size shows');

insert into res values ('p12_del', pg_temp.del_wait(12, 12001));

select is(pg_temp.r('p12_del'), '{"ok": true, "rows_removed": 3}'::jsonb,
  'deleting a wait removes the session and its 2 reports (the busyness-only answer stored none)');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(12)), 0::bigint,
  'the session is deleted');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(12)), 0::bigint,
  'every report in the wait is deleted');
select is(pg_temp.holds(12), 1::bigint, 'only the wait''s I''m in line leaves a hold');
select is((select h.phone_time from app.rate_limit_holds h where h.anon_id = pg_temp.uid(12)), pg_temp.ago(50),
  'the hold has the line start''s phone time');
select is(pg_temp.est() -> 'wait', 'null'::jsonb, 'the deleted measured wait no longer counts in estimates');
select is(pg_temp.est() -> 'line_size', 'null'::jsonb, 'the deleted wait''s line size no longer counts');
select is(pg_temp.est() ->> 'people', '0', 'the person no longer counts at the bar');
select is((pg_temp.last_deletion()).scope || ':' || (pg_temp.last_deletion()).rows_removed, 'one:3',
  'the wait deletion is logged as scope one with 3 rows');

insert into res values ('p12_again', pg_temp.start(12, 12005, 12006, pg_temp.dbar(), pg_temp.ago(45)));

select is(pg_temp.r('p12_again') ->> 'error', 'rate_limited',
  'a new line 5 minutes after a deleted wait''s start is rate-limited');

-- A deleted Report conditions no longer counts.
insert into res values ('p15_cond', pg_temp.cond(15, 15001, pg_temp.dbar(), pg_temp.ago(8),
                                                 p_line => 4, p_line_state => 'answered',
                                                 p_busy => 1, p_busy_state => 'answered'));

select is(pg_temp.est() -> 'line_size' ->> 'code', '4', 'a conditions report shows in estimates');

insert into res values ('p15_del', pg_temp.del_report(15, 15001));

select is(pg_temp.est() -> 'line_size', 'null'::jsonb, 'a deleted conditions report no longer counts in estimates');
select is(pg_temp.est() -> 'busyness', 'null'::jsonb, 'its busyness no longer counts either');

-- Refusals ---------------------------------------------------------------------------

-- Person 13: an open wait is cancelled from the wait card, not deleted here.
insert into res values ('p13_start', pg_temp.start(13, 13001, 13002, pg_temp.bar(2), pg_temp.ago(20)));
insert into res values ('p13_del', pg_temp.del_wait(13, 13001));

select is(pg_temp.r('p13_del'), '{"ok": false, "error": "session_open"}'::jsonb,
  'an open wait returns session_open');
select is((pg_temp.session(13001)).status, 'open', 'the open wait stays');
select is(pg_temp.holds(13), 0::bigint, 'a refused delete leaves no hold');

-- Person 14 tries to delete other people's items.
insert into res values ('p14_report', pg_temp.del_report(14, 1301));
insert into res values ('p14_wait', pg_temp.del_wait(14, 1201));
insert into res values ('p14_open', pg_temp.del_wait(14, 13001));

select is(pg_temp.r('p14_report'), '{"ok": false, "error": "not_found"}'::jsonb,
  'someone else''s report is not_found');
select is(pg_temp.r('p14_wait'), '{"ok": false, "error": "not_found"}'::jsonb,
  'someone else''s wait is not_found');
select is(pg_temp.r('p14_open'), '{"ok": false, "error": "not_found"}'::jsonb,
  'someone else''s open wait is not_found, which says nothing about it');
select is((select count(*) from app.reports r where r.client_report_id in (pg_temp.uid(1301), pg_temp.uid(1202))),
  2::bigint, 'the other person''s report and wait are untouched');

-- Older than 24 hours, and a report inside a wait.
insert into res values ('p1_del_old', pg_temp.del_report(1, 1101));
insert into res values ('p1_del_old_wait', pg_temp.del_wait(1, 1102));
insert into res values ('p1_del_line', pg_temp.del_report(1, 1202));

select is(pg_temp.r('p1_del_old'), '{"ok": false, "error": "not_found"}'::jsonb,
  'a report from more than 24 hours ago is not_found');
select is(pg_temp.r('p1_del_old_wait'), '{"ok": false, "error": "not_found"}'::jsonb,
  'a wait started more than 24 hours ago is not_found');
select is((select count(*) from app.reports r where r.client_report_id in (pg_temp.uid(1101), pg_temp.uid(1103))),
  2::bigint, 'the old report and wait stay');
select is(pg_temp.r('p1_del_line'), '{"ok": false, "error": "not_found"}'::jsonb,
  'a report inside a wait is not_found: the whole wait is deleted instead');

-- Bad input raises 22023.
select throws_ok($$select public.delete_report(p_anon_id => pg_temp.uid(1))$$,
  '22023', 'send exactly one of client_report_id and client_session_id', 'neither ID is bad input');
select throws_ok(
  $$select public.delete_report(p_anon_id => pg_temp.uid(1), p_client_report_id => pg_temp.uid(1301),
                                p_client_session_id => pg_temp.uid(1201))$$,
  '22023', 'send exactly one of client_report_id and client_session_id', 'both IDs is bad input');
select throws_ok($$select public.delete_report(p_anon_id => null, p_client_report_id => pg_temp.uid(1301))$$,
  '22023', 'anon_id is required', 'a missing anon ID is bad input');
select is((select count(*) from app.deletions d where d.scope = 'one'), 3::bigint,
  'only the 3 successful single deletes are logged');

-- Every other kind of item can be deleted ---------------------------------------------------

insert into res values ('p1_del_inside', pg_temp.del_report(1, 1401));
insert into res values ('p1_del_hidden', pg_temp.del_report(1, 1301));
insert into res values ('p3_del', pg_temp.del_wait(3, 3101));
insert into res values ('p1_del_gave_up', pg_temp.del_wait(1, 1501));

select is(pg_temp.r('p1_del_inside'), '{"ok": true, "rows_removed": 1}'::jsonb,
  'an I''m inside report (older builds) can be deleted');
select is((select count(*) from app.rate_limit_holds h where h.anon_id = pg_temp.uid(1) and h.bar_id = pg_temp.bar(3)),
  1::bigint, 'it leaves a hold at its bar');
select is(pg_temp.r('p1_del_hidden') ->> 'ok', 'true', 'a hidden report can still be deleted by its owner');
select is(pg_temp.r('p3_del'), '{"ok": true, "rows_removed": 2}'::jsonb, 'an unfinished wait can be deleted');
select is(pg_temp.r('p1_del_gave_up') ->> 'rows_removed', '2', 'a wait given up on can be deleted');
select is(jsonb_array_length(pg_temp.recent(1)), 1, 'person 1''s list now has only the timed wait');

-- Person 6: a wait past the timeout that the job has not reached yet counts as
-- unfinished (FR-10), so it can be deleted.
insert into res values ('p6_start', pg_temp.start(6, 6001, 6002, pg_temp.bar(3), pg_temp.ago(120)));

select is((pg_temp.session(6001)).status, 'open', 'a wait past the timeout is still open before the job runs');

insert into res values ('p6_del', pg_temp.del_wait(6, 6001));

select is(pg_temp.r('p6_del') ->> 'ok', 'true', 'it is treated as unfinished and can be deleted');

-- Delete my data (FR-32) removes holds -------------------------------------------------------

insert into res values ('p16_a', pg_temp.cond(16, 16001, pg_temp.bar(3), pg_temp.ago(8),
                                              p_line => 2, p_line_state => 'answered'));
insert into res values ('p16_b', pg_temp.cond(16, 16002, pg_temp.bar(1), pg_temp.ago(7),
                                              p_line => 2, p_line_state => 'answered'));
insert into res values ('p16_del', pg_temp.del_report(16, 16001));

select is(pg_temp.holds(16), 1::bigint, 'person 16 has a hold');

insert into res values ('p16_all', public.delete_my_data(pg_temp.uid(16)));

select is(pg_temp.r('p16_all') ->> 'rows_removed', '2', 'delete_my_data counts the report and the hold');
select is(pg_temp.holds(16), 0::bigint, 'delete_my_data removes the person''s holds');
select is(pg_temp.holds(10), 1::bigint, 'other people''s holds are untouched');
select is((pg_temp.last_deletion()).scope, 'all', 'Delete my data is logged with scope all');
select is((pg_temp.last_deletion()).rows_removed, 2, 'Delete my data logs the count, holds included');

-- Test data (FR-38) ------------------------------------------------------------------------

update app.config set value = '["ABCDEF00-0000-4000-8000-0000000000AA"]' where key = 'test_anon_ids';

insert into res values ('t_cond', public.report_conditions(
  p_client_report_id => pg_temp.uid(9001), p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa',
  p_install_id => pg_temp.uid(9002), p_bar_id => pg_temp.bar(2), p_phone_time => pg_temp.ago(8),
  p_location_status => 'no_fix', p_app_version => '1.0', p_definitions_version => 1::smallint,
  p_line_size => 2::smallint, p_line_size_state => 'answered'));
insert into res values ('t_del', public.delete_report(
  p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa', p_client_report_id => pg_temp.uid(9001)));

select is((select h.is_test from app.rate_limit_holds h where h.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'),
  true, 'a test ID''s hold is a test row');
select is((pg_temp.last_deletion()).is_test, true, 'a test ID''s single delete is a test row');

-- Expiring holds (every 5 minutes) ------------------------------------------------------------
-- Holds now: persons 10 (30 min old), 12 (50), 1 (100, 200, 50), 3 (200), and
-- 6 (120) are past the 10-minute limit; person 15 and the test ID (8) are not.

insert into res values ('expire_holds', to_jsonb(app.expire_rate_limit_holds()));

select is(pg_temp.r('expire_holds'), '7'::jsonb, 'the job removes the 7 holds older than the rate limit');
select is(pg_temp.holds(10), 0::bigint, 'a hold older than the limit is gone');
select is(pg_temp.holds(15), 1::bigint, 'a hold still inside the limit stays');
select is(app.expire_rate_limit_holds(now() + interval '1 hour'), 2,
  'an hour later, the last 2 holds are gone');
select is((select count(*) from app.rate_limit_holds), 0::bigint, 'no holds are left');

-- Retention (FR-33) is logged with the default scope.
insert into res values ('purge', to_jsonb(app.purge_old_data(now() + interval '2 years')));

select is((select d.scope from app.deletions d where d.reason = 'retention' order by d.id desc limit 1), 'all',
  'a retention purge is logged with scope all (the default)');

select * from finish();
rollback;
