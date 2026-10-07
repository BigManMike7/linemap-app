-- Time in lines (Settings tracker, approved by Max on 2026-10-07): my_wait_stats.
--   Counts the person's own waits that ended as entered or gave_up, whatever
--   ended them: ended_at - started_at + Adjust time, never below 0. Open and
--   unfinished (timed-out) waits never count; cancelled, deleted, and
--   replaced (redo) waits are gone, so they drop out on their own. A wait
--   redone by a timer that a line elsewhere closed is kept, but not counted.
--
-- Same conventions as redo_undo_test.sql: now() is fixed for the whole
-- transaction, each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)), and each person is a separate anonymous ID.
-- Person n's session and report IDs are 1000 * n + k, so every ID is unique.
-- Seed bars (by display_order): 1 = Primanti Bros., 2 = Doggie's Pub, 3 = Brothers Bar & Grill.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(37);

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

create function pg_temp.has_session(p_n integer) returns boolean
language sql stable as
$$ select exists (select 1 from app.wait_sessions s where s.client_session_id = pg_temp.uid(p_n)) $$;

create function pg_temp.stats(p_person integer) returns jsonb
language sql stable as
$$ select public.my_wait_stats(pg_temp.uid(p_person)) $$;

create function pg_temp.expect(p_total integer, p_waits integer, p_longest integer) returns jsonb
language sql immutable as
$$ select jsonb_build_object('total_seconds', p_total, 'waits', p_waits, 'longest_seconds', p_longest) $$;

-- Person n uses anon ID uid(n) and install ID uid(n + 500).

-- Start line timer.
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

-- Started it by mistake.
create function pg_temp.cancel(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.cancel_session(p_client_session_id => pg_temp.uid(p_session),
                               p_anon_id => pg_temp.uid(p_person))
$$;

-- Made a wrong report? on a finished wait.
create function pg_temp.del_wait(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.delete_report(p_anon_id => pg_temp.uid(p_person),
                              p_client_session_id => pg_temp.uid(p_session))
$$;

-- Undo.
create function pg_temp.reopen(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.reopen_session(p_client_session_id => pg_temp.uid(p_session),
                               p_anon_id => pg_temp.uid(p_person))
$$;

-- The function -------------------------------------------------------------------------

select ok(
  (select p.prosecdef
          and coalesce(p.proconfig, '{}'::text[])
              && array['search_path=""', 'search_path=', $q$search_path=''$q$]
   from pg_proc p where p.oid = 'public.my_wait_stats(uuid)'::regprocedure),
  'my_wait_stats is SECURITY DEFINER with an empty search_path');
select is(
  (select p.provolatile::text from pg_proc p where p.oid = 'public.my_wait_stats(uuid)'::regprocedure),
  's', 'my_wait_stats is stable (read-only)');
select ok(has_function_privilege('anon', 'public.my_wait_stats(uuid)', 'execute'),
  'anon can execute my_wait_stats');
select ok(not has_function_privilege('authenticated', 'public.my_wait_stats(uuid)', 'execute'),
  'authenticated cannot execute my_wait_stats (so neither can PUBLIC)');

select throws_ok($$select public.my_wait_stats(null)$$,
  '22023', 'anon_id is required', 'my_wait_stats needs an anon ID');

-- No waits -------------------------------------------------------------------------------

select is(pg_temp.stats(1), '{"total_seconds": 0, "waits": 0, "longest_seconds": null}'::jsonb,
  'no waits: 0 seconds, 0 waits, longest null');

-- Person 2: I'm in with Adjust time, Gave up, unfinished, open ---------------------------

-- I'm in after 20 minutes, with Adjust time 10: 30 minutes.
insert into res values ('p2_s1', pg_temp.start(2, 2001, 2002, pg_temp.bar(1), pg_temp.ago(300), 10));
insert into res values ('p2_e1', pg_temp.end_line(2, 2001, 'entered', pg_temp.ago(280)));
select is(pg_temp.r('p2_e1') ->> 'status', 'entered', 'person 2''s first timer ends with I''m in');
select is(pg_temp.stats(2), pg_temp.expect(1800, 1, 1800),
  'I''m in counts, Adjust time included: 20 minutes + 10 = 1800 seconds');

-- Gave up after 5 minutes.
insert into res values ('p2_s2', pg_temp.start(2, 2003, 2004, pg_temp.bar(2), pg_temp.ago(250)));
insert into res values ('p2_e2', pg_temp.end_line(2, 2003, 'gave_up', pg_temp.ago(245)));
select is(pg_temp.r('p2_e2') ->> 'status', 'gave_up', 'person 2''s second timer ends with Gave up');
select is((pg_temp.session(2003)).measured_wait_seconds, null::integer,
  'a Gave up has no measured_wait_seconds');
select is(pg_temp.stats(2), pg_temp.expect(2100, 2, 1800),
  'Gave up counts too: 1800 + 300 seconds, 2 waits, longest still 1800');

-- A timer left running past 90 minutes becomes unfinished when the next one starts.
insert into res values ('p2_s3', pg_temp.start(2, 2005, 2006, pg_temp.bar(3), pg_temp.ago(200)));
insert into res values ('p2_s4', pg_temp.start(2, 2007, 2008, pg_temp.bar(1), pg_temp.ago(60)));
select is((pg_temp.session(2005)).status, 'unfinished', 'the forgotten timer timed out (FR-10)');
select is((pg_temp.session(2007)).status, 'open', 'the newest timer is open');
select is(pg_temp.stats(2), pg_temp.expect(2100, 2, 1800),
  'unfinished and open timers don''t count');

-- Person 3: a timer closed by a line at another bar (FR-14) ------------------------------

insert into res values ('p3_s1', pg_temp.start(3, 3001, 3002, pg_temp.bar(1), pg_temp.ago(120)));
insert into res values ('p3_s2', pg_temp.start(3, 3003, 3004, pg_temp.bar(2), pg_temp.ago(100)));
select is((pg_temp.session(3001)).status, 'gave_up', 'a new line elsewhere ends the first timer as gave_up');
select is((pg_temp.session(3001)).ended_by, 'new_line', '... ended by new_line');
select is(pg_temp.stats(3), pg_temp.expect(1200, 1, 1200),
  'it counts up to the new start: 20 minutes; the new open timer doesn''t');
insert into res values ('p3_e2', pg_temp.end_line(3, 3003, 'entered', pg_temp.ago(90)));
select is(pg_temp.stats(3), pg_temp.expect(1800, 2, 1200),
  'the second timer adds its 10 minutes');

-- Person 4: started by mistake and Made a wrong report? ----------------------------------

insert into res values ('p4_s1', pg_temp.start(4, 4001, 4002, pg_temp.bar(1), pg_temp.ago(100)));
insert into res values ('p4_c1', pg_temp.cancel(4, 4001));
select is(pg_temp.r('p4_c1') ->> 'removed', 'true', 'person 4 cancels a timer started by mistake');

insert into res values ('p4_s2', pg_temp.start(4, 4003, 4004, pg_temp.bar(2), pg_temp.ago(80)));
insert into res values ('p4_e2', pg_temp.end_line(4, 4003, 'entered', pg_temp.ago(70)));
select is(pg_temp.stats(4), pg_temp.expect(600, 1, 600), 'the finished wait counts before it is deleted');
insert into res values ('p4_d2', pg_temp.del_wait(4, 4003));
select is(pg_temp.r('p4_d2') ->> 'ok', 'true', 'person 4 deletes the wait (FR-41)');

insert into res values ('p4_s3', pg_temp.start(4, 4005, 4006, pg_temp.bar(3), pg_temp.ago(60)));
insert into res values ('p4_e3', pg_temp.end_line(4, 4005, 'gave_up', pg_temp.ago(55)));
select is(pg_temp.stats(4), pg_temp.expect(300, 1, 300),
  'cancelled and deleted waits don''t count; only the 5-minute Gave up does');

-- Person 5: Redo (FR-46) and Undo (FR-47) ---------------------------------------------------

insert into res values ('p5_s1', pg_temp.start(5, 5001, 5002, pg_temp.bar(1), pg_temp.ago(10)));
insert into res values ('p5_e1', pg_temp.end_line(5, 5001, 'entered', pg_temp.ago(8)));
insert into res values ('p5_s2', pg_temp.start(5, 5003, 5004, pg_temp.bar(1), pg_temp.ago(6)));
select is(pg_temp.r('p5_s2') ->> 'ok', 'true', 'a new timer 2 minutes after I''m in is a redo');
select is(pg_temp.stats(5), pg_temp.expect(120, 1, 120),
  'while the redo runs, only the earlier 2-minute wait counts');
insert into res values ('p5_e2', pg_temp.end_line(5, 5003, 'entered', pg_temp.ago(1)));
select ok(not pg_temp.has_session(5001), 'finishing the redo deletes the earlier timer');
select is(pg_temp.stats(5), pg_temp.expect(300, 1, 300),
  'after the redo finishes, only the new 5-minute wait counts (no double count)');
insert into res values ('p5_u2', pg_temp.reopen(5, 5003));
select is(pg_temp.r('p5_u2') ->> 'reopened', 'true', 'Undo reopens the timer');
select is(pg_temp.stats(5), '{"total_seconds": 0, "waits": 0, "longest_seconds": null}'::jsonb,
  'a reopened timer is open again, so nothing counts');

-- Person 7: a redo closed by a line at another bar (FR-14, FR-46) -------------------------
-- end_session never runs on the redo, so the earlier timer stays; it isn't counted.

insert into res values ('p7_s1', pg_temp.start(7, 7001, 7002, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p7_e1', pg_temp.end_line(7, 7001, 'gave_up', pg_temp.ago(25)));
-- The redo, 2 minutes later, with Adjust time 5 reaching back into the first timer.
insert into res values ('p7_s2', pg_temp.start(7, 7003, 7004, pg_temp.bar(1), pg_temp.ago(23), 5));
select is(pg_temp.r('p7_s2') ->> 'ok', 'true', 'person 7''s new timer 2 minutes after Gave up is a redo');
-- A line at another bar closes the redo.
insert into res values ('p7_s3', pg_temp.start(7, 7005, 7006, pg_temp.bar(2), pg_temp.ago(13)));
select is((pg_temp.session(7003)).ended_by, 'new_line', 'the redo was ended by a line elsewhere');
select ok(pg_temp.has_session(7001), 'so the earlier timer was never deleted');
select is(pg_temp.stats(7), pg_temp.expect(900, 1, 900),
  'only the redo counts: 10 minutes + 5 = 900 seconds, not the replaced 5-minute timer too');

-- Person 6: older builds, test rows, and the clamp at 0 ------------------------------------

insert into app.wait_sessions (
  client_session_id, anon_id, install_id, bar_id, night_date, started_at,
  start_offset_minutes, ended_at, status, ended_by, is_test
) values
  -- I'm inside from an older build (FR-15), a test row: 10 minutes + 5.
  (pg_temp.uid(6001), pg_temp.uid(6), pg_temp.uid(506), pg_temp.bar(1),
   app.night_date(pg_temp.ago(40)), pg_temp.ago(40), 5, pg_temp.ago(30), 'entered', 'im_inside', true),
  -- An end before the start (never written by the API): clamped to 0.
  (pg_temp.uid(6002), pg_temp.uid(6), pg_temp.uid(506), pg_temp.bar(2),
   app.night_date(pg_temp.ago(20)), pg_temp.ago(20), 0, pg_temp.ago(25), 'gave_up', 'gave_up', false);
select is(pg_temp.stats(6), pg_temp.expect(900, 2, 900),
  'I''m inside and test rows count; a negative time counts as 0 seconds but still a wait');

-- Other people ----------------------------------------------------------------------------

select is(pg_temp.stats(1), '{"total_seconds": 0, "waits": 0, "longest_seconds": null}'::jsonb,
  'other people''s waits never count for person 1');
select is(pg_temp.stats(2), pg_temp.expect(2100, 2, 1800),
  'person 2''s total is unchanged by everyone else''s waits');

-- As anon and authenticated ------------------------------------------------------------------

set local role anon;
select is(public.my_wait_stats('00000000-0000-4000-8000-000000000003'),
  '{"total_seconds": 1800, "waits": 2, "longest_seconds": 1200}'::jsonb,
  'anon can call my_wait_stats');
reset role;

set local role authenticated;
select throws_ok($$select public.my_wait_stats('00000000-0000-4000-8000-000000000003')$$,
  '42501', null, 'authenticated cannot call my_wait_stats');
reset role;

select * from finish();
rollback;
