-- Redo (FR-46) and Undo (FR-47), M4.
--   Redo   start_session and report_conditions let a person replace their own
--          last attempt at a bar within redo_minutes (5) instead of refusing
--          it with the rate limit (FR-13). A redone timer is deleted when the
--          new one finishes; a redone Report conditions is deleted at once.
--   Undo   reopen_session reopens a timer stopped less than 5 minutes ago.
--
-- Same conventions as separate_rate_limits_test.sql: now() is fixed for the
-- whole transaction, each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)), and each person is a separate anonymous ID.
-- Person n's session and report IDs are 1000 * n + k, so every ID is unique.
-- Seed bars: 1 = Doggie's Pub, 2 = The Phyrst, 3 = Cafe 210 West. Estimate
-- checks use a bar of their own.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(143);

-- Helpers ----------------------------------------------------------------------------

create temp table res (name text primary key, j jsonb);
create temp table marks (name text primary key, n bigint);

insert into app.bars (name, address, door_lat, door_lon, display_order)
values ('Undo test bar', 'Test address', 40.7940, -77.8610, 100);

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

create function pg_temp.ago(p_minutes integer) returns timestamptz
language sql stable as
$$ select now() - make_interval(mins => p_minutes) $$;

create function pg_temp.bar(p_order integer) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.display_order = p_order and not b.is_test $$;

create function pg_temp.ubar() returns bigint
language sql stable as
$$ select b.id from app.bars b where b.name = 'Undo test bar' $$;

create function pg_temp.r(p_name text) returns jsonb
language sql stable as
$$ select x.j from pg_temp.res x where x.name = p_name $$;

create function pg_temp.session(p_n integer) returns app.wait_sessions
language sql stable as
$$ select s.* from app.wait_sessions s where s.client_session_id = pg_temp.uid(p_n) $$;

create function pg_temp.has_session(p_n integer) returns boolean
language sql stable as
$$ select exists (select 1 from app.wait_sessions s where s.client_session_id = pg_temp.uid(p_n)) $$;

create function pg_temp.sessions(p_person integer) returns bigint
language sql stable as
$$ select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(p_person) $$;

create function pg_temp.report(p_n integer) returns app.reports
language sql stable as
$$ select r.* from app.reports r where r.client_report_id = pg_temp.uid(p_n) $$;

create function pg_temp.has_report(p_n integer) returns boolean
language sql stable as
$$ select exists (select 1 from app.reports r where r.client_report_id = pg_temp.uid(p_n)) $$;

create function pg_temp.reports(p_person integer) returns bigint
language sql stable as
$$ select count(*) from app.reports r where r.anon_id = pg_temp.uid(p_person) $$;

create function pg_temp.holds(p_person integer) returns bigint
language sql stable as
$$ select count(*) from app.rate_limit_holds h where h.anon_id = pg_temp.uid(p_person) $$;

create function pg_temp.deletions() returns bigint
language sql stable as
$$ select count(*) from app.deletions $$;

create function pg_temp.mark(p_name text) returns bigint
language sql stable as
$$ select m.n from pg_temp.marks m where m.name = p_name $$;

-- The Undo test bar's live estimate now.
create function pg_temp.est() returns jsonb
language sql stable as
$$ select app.bar_estimate(pg_temp.ubar(), now(), false, 'live') $$;

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

-- Line-size update in a session.
create function pg_temp.line(p_person integer, p_report integer, p_session integer,
                             p_at timestamptz, p_line integer)
returns jsonb
language sql as $$
  select public.update_line_size(
    p_client_report_id    => pg_temp.uid(p_report),
    p_client_session_id   => pg_temp.uid(p_session),
    p_anon_id             => pg_temp.uid(p_person),
    p_install_id          => pg_temp.uid(p_person + 500),
    p_phone_time          => p_at,
    p_line_size_state     => 'answered',
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

-- Started it by mistake.
create function pg_temp.cancel(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.cancel_session(p_client_session_id => pg_temp.uid(p_session),
                               p_anon_id => pg_temp.uid(p_person))
$$;

-- Undo.
create function pg_temp.reopen(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.reopen_session(p_client_session_id => pg_temp.uid(p_session),
                               p_anon_id => pg_temp.uid(p_person))
$$;

-- I'm inside (older builds).
create function pg_temp.inside(p_person integer, p_report integer, p_bar bigint, p_at timestamptz)
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
    p_busyness            => 2::smallint,
    p_busyness_state      => 'answered')
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

-- Delete one report, or one wait (FR-41).
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

-- The setting and the helpers -----------------------------------------------------------

select is(app.setting_int('redo_minutes'), 5, 'redo_minutes is 5 (FR-46, FR-47)');
select ok(
  exists (select 1 from app.config_history h
          where h.config_key = 'redo_minutes' and h.old_value is null and h.new_value = '5'::jsonb),
  'adding redo_minutes was logged in config_history');
select is((select c.is_test from app.config c where c.key = 'redo_minutes'), false,
  'redo_minutes is not a test row');

select ok(
  (select not p.prosecdef
          and coalesce(p.proconfig, '{}'::text[])
              && array['search_path=""', 'search_path=', $q$search_path=''$q$]
   from pg_proc p
   where p.oid = 'app.redo_allowed(uuid, bigint, timestamptz, text)'::regprocedure),
  'redo_allowed is SECURITY INVOKER with an empty search_path');
select ok(
  not has_function_privilege('anon', 'app.redo_allowed(uuid, bigint, timestamptz, text)', 'execute')
  and not has_function_privilege('anon', 'app.delete_replaced_sessions(bigint)', 'execute')
  and not has_function_privilege('anon', 'app.history(bigint, date, timestamptz, boolean)', 'execute'),
  'anon cannot execute the new internal functions');
select throws_ok(
  $$select app.redo_allowed(pg_temp.uid(1), pg_temp.bar(1), now(), 'hourly')$$,
  '22023', 'unknown rate-limit clock: hourly', 'redo_allowed rejects an unknown clock name');
select is(app.redo_allowed(pg_temp.uid(1), pg_temp.bar(1), now(), 'timed'), false,
  'with nothing to replace, nothing is a redo');

-- Timers: redo after I'm in (person 1, bar 1) ---------------------------------------------

insert into res values ('p1_start', pg_temp.start(1, 1001, 1002, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p1_line', pg_temp.line(1, 1003, 1001, pg_temp.ago(29), 3));
insert into res values ('p1_end', pg_temp.end_line(1, 1001, 'entered', pg_temp.ago(26)));

select is(app.rate_limit_wait(pg_temp.uid(1), pg_temp.bar(1), pg_temp.ago(23), 'timed'), 180,
  'the timed clock alone would refuse a new timer 7 minutes after the last start');
select is(app.redo_allowed(pg_temp.uid(1), pg_temp.bar(1), pg_temp.ago(23), 'timed'), true,
  '3 minutes after I''m in, a new timer is a redo');

insert into res values ('p1_redo', pg_temp.start(1, 1004, 1005, pg_temp.bar(1), pg_temp.ago(23)));

select is(pg_temp.r('p1_redo') ->> 'ok', 'true', 'a new timer 3 minutes after I''m in is allowed (FR-46)');
select is(pg_temp.r('p1_redo') ->> 'already_open', 'false', 'it is a new session');
select is((pg_temp.session(1004)).status, 'open', 'the new timer is open');
select is((pg_temp.session(1001)).status, 'entered', 'the earlier timer stays while the new one runs');
select is((select count(*) from app.reports r where r.wait_session_id = (pg_temp.session(1001)).id), 2::bigint,
  'and so do its reports');

insert into marks values ('p1', pg_temp.deletions());
insert into res values ('p1_line2', pg_temp.line(1, 1006, 1004, pg_temp.ago(22), 2));
insert into res values ('p1_end2', pg_temp.end_line(1, 1004, 'entered', pg_temp.ago(15)));

select is(pg_temp.r('p1_end2') ->> 'status', 'entered', 'the new timer ends with I''m in');
select is(pg_temp.r('p1_end2') ->> 'measured_wait_seconds', '480', 'its own wait is measured');
select is(pg_temp.has_session(1001), false, 'when the new timer finishes, the earlier timer is deleted');
select is(pg_temp.has_report(1002) or pg_temp.has_report(1003), false, 'with every report in it');
select is(pg_temp.reports(1), 2::bigint, 'only the new timer''s two reports are left');
select is(pg_temp.holds(1), 0::bigint, 'a replaced timer leaves no rate-limit hold');
select is(pg_temp.deletions(), pg_temp.mark('p1'), 'a replaced timer logs no deletion count');

-- Timers: redo after Gave up (person 2, bar 2) ----------------------------------------------

insert into res values ('p2_start', pg_temp.start(2, 2001, 2002, pg_temp.bar(2), pg_temp.ago(40)));
insert into res values ('p2_end', pg_temp.end_line(2, 2001, 'gave_up', pg_temp.ago(38)));
insert into res values ('p2_redo', pg_temp.start(2, 2003, 2004, pg_temp.bar(2), pg_temp.ago(36)));

select is(pg_temp.r('p2_redo') ->> 'ok', 'true', 'a new timer 2 minutes after Gave up is allowed');
select is(pg_temp.has_session(2001), true, 'the given-up timer stays while the new one runs');

insert into res values ('p2_end2', pg_temp.end_line(2, 2003, 'gave_up', pg_temp.ago(34)));

select is(pg_temp.has_session(2001), false, 'when the new timer is given up too, the earlier one is deleted');
select is((pg_temp.session(2003)).status, 'gave_up', 'the new timer is kept');

-- Timers: refused from 5 to 10 minutes (person 3, bar 3) -------------------------------------

insert into res values ('p3_start', pg_temp.start(3, 3001, 3002, pg_temp.bar(3), pg_temp.ago(40)));
insert into res values ('p3_end', pg_temp.end_line(3, 3001, 'entered', pg_temp.ago(39)));
insert into res values ('p3_at5', pg_temp.start(3, 3003, 3004, pg_temp.bar(3), pg_temp.ago(34)));
insert into res values ('p3_at6', pg_temp.start(3, 3005, 3006, pg_temp.bar(3), pg_temp.ago(33)));

select is(pg_temp.r('p3_at5') ->> 'error', 'rate_limited', 'exactly 5 minutes after I''m in is past the redo');
select is(pg_temp.r('p3_at5') ->> 'retry_after_seconds', '240', 'the normal limit runs from the last start');
select is(pg_temp.r('p3_at6') ->> 'error', 'rate_limited', '6 minutes after I''m in is refused');
select is(pg_temp.r('p3_at6') ->> 'retry_after_seconds', '180', 'it is told the time left');
select is(pg_temp.sessions(3), 1::bigint, 'the refused timers create no session');

insert into res values ('p3_later', pg_temp.start(3, 3007, 3008, pg_temp.bar(3), pg_temp.ago(29)));
insert into res values ('p3_later_end', pg_temp.end_line(3, 3007, 'entered', pg_temp.ago(25)));

select is(pg_temp.r('p3_later') ->> 'ok', 'true', 'a new timer 11 minutes after the last start is allowed');
select is((pg_temp.session(3001)).status, 'entered',
  'a timer stopped 10 minutes before the next one started is not replaced');
select is(pg_temp.sessions(3), 2::bigint, 'both timers are kept');

-- Timers: a cancelled redo keeps the earlier timer (person 4, bar 1) ------------------------------

insert into res values ('p4_start', pg_temp.start(4, 4001, 4002, pg_temp.bar(1), pg_temp.ago(40)));
insert into res values ('p4_end', pg_temp.end_line(4, 4001, 'entered', pg_temp.ago(38)));
insert into res values ('p4_redo', pg_temp.start(4, 4003, 4004, pg_temp.bar(1), pg_temp.ago(37)));
insert into res values ('p4_cancel', pg_temp.cancel(4, 4003));

select is(pg_temp.r('p4_redo') ->> 'ok', 'true', 'the redo is allowed');
select is(pg_temp.r('p4_cancel') ->> 'removed', 'true', 'and then cancelled as started by mistake (FR-39)');
select is((pg_temp.session(4001)).status, 'entered', 'the earlier timer stays');
select is(pg_temp.sessions(4), 1::bigint, 'only the earlier timer is left');

insert into res values ('p4_again', pg_temp.start(4, 4005, 4006, pg_temp.bar(1), pg_temp.ago(36)));
insert into res values ('p4_again_end', pg_temp.end_line(4, 4005, 'gave_up', pg_temp.ago(35)));

select is(pg_temp.r('p4_again') ->> 'ok', 'true', 'a timer started again is still a redo of the earlier one');
select is(pg_temp.has_session(4001), false, 'which is deleted when the new timer finishes');
select is((pg_temp.session(4005)).status, 'gave_up', 'the new timer is kept');

-- Timers: a chain of redos (person 5, bar 2) ---------------------------------------------------

insert into res values ('p5_a', pg_temp.start(5, 5001, 5002, pg_temp.bar(2), pg_temp.ago(50)));
insert into res values ('p5_a_end', pg_temp.end_line(5, 5001, 'entered', pg_temp.ago(49)));
insert into res values ('p5_b', pg_temp.start(5, 5003, 5004, pg_temp.bar(2), pg_temp.ago(47)));

select is(pg_temp.r('p5_b') ->> 'ok', 'true', 'B redoes A');
select is(pg_temp.has_session(5001), true, 'A stays while B runs');

insert into res values ('p5_b_end', pg_temp.end_line(5, 5003, 'entered', pg_temp.ago(46)));

select is(pg_temp.has_session(5001), false, 'A is deleted when B finishes');

insert into res values ('p5_c', pg_temp.start(5, 5005, 5006, pg_temp.bar(2), pg_temp.ago(44)));

select is(pg_temp.r('p5_c') ->> 'ok', 'true', 'C redoes B, 2 minutes after B stopped and 3 after B started');
select is(pg_temp.has_session(5003), true, 'B stays while C runs');

insert into res values ('p5_c_end', pg_temp.end_line(5, 5005, 'gave_up', pg_temp.ago(43)));

select is(pg_temp.has_session(5003), false, 'B is deleted when C finishes');
select is(pg_temp.sessions(5), 1::bigint, 'only C is left');
select is(pg_temp.reports(5), 1::bigint, 'with only its own line start');

-- Timers: other bars and other people are untouched (people 6 and 7) --------------------------------

insert into res values ('p7_start', pg_temp.start(7, 7001, 7002, pg_temp.bar(3), pg_temp.ago(40)));
insert into res values ('p7_end', pg_temp.end_line(7, 7001, 'entered', pg_temp.ago(37)));

insert into res values ('p6_x', pg_temp.start(6, 6001, 6002, pg_temp.bar(3), pg_temp.ago(40)));
insert into res values ('p6_x_end', pg_temp.end_line(6, 6001, 'entered', pg_temp.ago(39)));
insert into res values ('p6_y', pg_temp.start(6, 6003, 6004, pg_temp.bar(2), pg_temp.ago(38)));
insert into res values ('p6_y_end', pg_temp.end_line(6, 6003, 'entered', pg_temp.ago(37)));
insert into res values ('p6_z', pg_temp.start(6, 6005, 6006, pg_temp.bar(3), pg_temp.ago(36)));
insert into res values ('p6_z_end', pg_temp.end_line(6, 6005, 'entered', pg_temp.ago(35)));

select is(pg_temp.r('p6_z') ->> 'ok', 'true', 'a redo at bar 3 after a timer at bar 2 in between');
select is(pg_temp.has_session(6001), false, 'the earlier timer at the same bar is replaced');
select is((pg_temp.session(6003)).status, 'entered', 'the timer at another bar is kept');
select is((pg_temp.session(7001)).status, 'entered', 'another person''s timer at the same bar is kept');

-- Timers: re-sending a start behaves as before (person 8, bar 1) -------------------------------------

insert into res values ('p8_start', pg_temp.start(8, 8001, 8002, pg_temp.bar(1), pg_temp.ago(40)));
insert into res values ('p8_end', pg_temp.end_line(8, 8001, 'entered', pg_temp.ago(39)));
insert into res values ('p8_redo', pg_temp.start(8, 8003, 8004, pg_temp.bar(1), pg_temp.ago(37)));
insert into res values ('p8_resend', pg_temp.start(8, 8003, 8004, pg_temp.bar(1), pg_temp.ago(37)));
insert into res values ('p8_offset', pg_temp.start(8, 8003, 8004, pg_temp.bar(1), pg_temp.ago(37), p_offset => 4));
insert into res values ('p8_resend_old', pg_temp.start(8, 8001, 8002, pg_temp.bar(1), pg_temp.ago(40)));
insert into res values ('p8_open', pg_temp.start(8, 8005, 8006, pg_temp.bar(1), pg_temp.ago(36)));

select is(pg_temp.r('p8_redo') ->> 'ok', 'true', 'the redo is allowed');
select is(pg_temp.r('p8_resend'),
  jsonb_build_object('ok', true, 'client_session_id', pg_temp.uid(8003), 'status', 'open', 'already_open', false),
  're-sending the redo returns the same answer');
select is((pg_temp.session(8003)).start_offset_minutes, 4::smallint, 're-sending it with Adjust time still sets it');
select is(pg_temp.r('p8_resend_old'),
  jsonb_build_object('ok', true, 'client_session_id', pg_temp.uid(8001), 'status', 'entered', 'already_open', false),
  're-sending the earlier start returns its state unchanged');
select is(pg_temp.r('p8_open') ->> 'already_open', 'true', 'a new start while the redo is open is already_open');
select is(pg_temp.r('p8_open') ->> 'client_session_id', pg_temp.uid(8003)::text, 'and returns the open redo');
select is(pg_temp.sessions(8), 2::bigint, 'no extra session is created');

-- Timers: a deleted wait's hold can be redone (people 9 and 10, bar 2) ----------------------------------

insert into res values ('p9_start', pg_temp.start(9, 9001, 9002, pg_temp.bar(2), pg_temp.ago(40)));
insert into res values ('p9_end', pg_temp.end_line(9, 9001, 'gave_up', pg_temp.ago(39)));
insert into res values ('p9_del', pg_temp.del_wait(9, 9001));
insert into res values ('p9_redo', pg_temp.start(9, 9003, 9004, pg_temp.bar(2), pg_temp.ago(37)));

select is(pg_temp.r('p9_del') ->> 'ok', 'true', 'the wait is deleted (FR-41)');
select is(pg_temp.r('p9_redo') ->> 'ok', 'true',
  'a new timer 3 minutes after the deleted wait''s start is allowed: its hold can be redone');
select is(pg_temp.holds(9), 1::bigint, 'the hold stays until it expires');

insert into res values ('p9_redo_end', pg_temp.end_line(9, 9003, 'entered', pg_temp.ago(36)));
insert into res values ('p9_chain', pg_temp.start(9, 9005, 9006, pg_temp.bar(2), pg_temp.ago(33)));

select is(pg_temp.r('p9_chain') ->> 'ok', 'true',
  'a further redo 3 minutes after the last timer stopped passes the older hold');
select is((pg_temp.session(9003)).status, 'entered', 'the timer it redoes stays until the new one finishes');

insert into res values ('p10_start', pg_temp.start(10, 10001, 10002, pg_temp.bar(2), pg_temp.ago(40)));
insert into res values ('p10_end', pg_temp.end_line(10, 10001, 'gave_up', pg_temp.ago(39)));
insert into res values ('p10_del', pg_temp.del_wait(10, 10001));
insert into res values ('p10_again', pg_temp.start(10, 10003, 10004, pg_temp.bar(2), pg_temp.ago(34)));

select is(pg_temp.r('p10_again') ->> 'error', 'rate_limited',
  '6 minutes after the deleted wait''s start, its hold is past the redo');
select is(pg_temp.r('p10_again') ->> 'retry_after_seconds', '240', 'the limit still runs from the hold');

-- Report conditions: redo replaces at once (person 20, bar 1) ---------------------------------------

insert into marks values ('p20', pg_temp.deletions());
insert into res values ('p20_a', pg_temp.cond(20, 20001, pg_temp.bar(1), pg_temp.ago(30), p_busy => 2));
insert into res values ('p20_b', pg_temp.cond(20, 20002, pg_temp.bar(1), pg_temp.ago(27), p_busy => 4));

select is(pg_temp.r('p20_b'), '{"ok": true, "kind": "conditions"}'::jsonb,
  'Report conditions 3 minutes after the last one is allowed (FR-46)');
select is(pg_temp.has_report(20001), false, 'the earlier report is deleted at once');
select is((pg_temp.report(20002)).busyness, 4::smallint, 'the new report is saved');
select is(pg_temp.holds(20), 0::bigint, 'a replaced report leaves no hold');
select is(pg_temp.deletions(), pg_temp.mark('p20'), 'a replaced report logs no deletion count');

insert into res values ('p20_c', pg_temp.cond(20, 20003, pg_temp.bar(1), pg_temp.ago(24), p_busy => 3));

select is(pg_temp.r('p20_c') ->> 'ok', 'true', 'a further redo 3 minutes later is allowed');
select is(pg_temp.has_report(20002), false, 'it replaces the last one');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(20) and r.kind = 'conditions'), 1::bigint,
  'only the newest report is left');

-- Report conditions: refused from 5 to 10 minutes (person 21, bar 1) -----------------------------------

insert into res values ('p21_a', pg_temp.cond(21, 21001, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p21_at5', pg_temp.cond(21, 21002, pg_temp.bar(1), pg_temp.ago(25)));
insert into res values ('p21_at6', pg_temp.cond(21, 21003, pg_temp.bar(1), pg_temp.ago(24)));

select is(pg_temp.r('p21_at5') ->> 'error', 'rate_limited', 'exactly 5 minutes later is past the redo');
select is(pg_temp.r('p21_at5') ->> 'retry_after_seconds', '300', 'the normal limit applies');
select is(pg_temp.r('p21_at6') ->> 'error', 'rate_limited', '6 minutes later is refused');
select is(pg_temp.r('p21_at6') ->> 'retry_after_seconds', '240', 'it is told the time left');
select is(pg_temp.has_report(21001), true, 'a refused report replaces nothing');

-- Report conditions: a deleted report's hold can be redone (people 22 and 23, bar 2) ------------------

insert into res values ('p22_a', pg_temp.cond(22, 22001, pg_temp.bar(2), pg_temp.ago(30)));
insert into res values ('p22_del', pg_temp.del_report(22, 22001));
insert into res values ('p22_b', pg_temp.cond(22, 22002, pg_temp.bar(2), pg_temp.ago(27)));

select is(pg_temp.r('p22_del') ->> 'ok', 'true', 'the report is deleted (FR-41)');
select is(pg_temp.r('p22_b') ->> 'ok', 'true', 'Report conditions 3 minutes after the deleted one is allowed');
select is(pg_temp.has_report(22002), true, 'the new report is saved');

insert into res values ('p23_a', pg_temp.cond(23, 23001, pg_temp.bar(2), pg_temp.ago(30)));
insert into res values ('p23_del', pg_temp.del_report(23, 23001));
insert into res values ('p23_b', pg_temp.cond(23, 23002, pg_temp.bar(2), pg_temp.ago(24)));

select is(pg_temp.r('p23_b') ->> 'error', 'rate_limited', '6 minutes after the deleted one is refused');
select is(pg_temp.r('p23_b') ->> 'retry_after_seconds', '240', 'the limit still runs from the hold');

-- Report conditions: re-sending (person 24, bar 3) ---------------------------------------------------------

insert into res values ('p24_a', pg_temp.cond(24, 24001, pg_temp.bar(3), pg_temp.ago(30), p_busy => 2));
insert into res values ('p24_b', pg_temp.cond(24, 24002, pg_temp.bar(3), pg_temp.ago(28), p_busy => 3));
insert into res values ('p24_b_again', pg_temp.cond(24, 24002, pg_temp.bar(3), pg_temp.ago(28), p_busy => 3));

select is(pg_temp.r('p24_b') ->> 'ok', 'true', 'the redo is allowed');
select is(pg_temp.r('p24_b_again'), '{"ok": true, "kind": "conditions"}'::jsonb,
  're-sending the same report ID returns the same answer');
select is(pg_temp.has_report(24002), true, 'a re-sent report never replaces itself');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(24)), 1::bigint, 'one report is left');

insert into res values ('p24_a_again', pg_temp.cond(24, 24001, pg_temp.bar(3), pg_temp.ago(30), p_busy => 2));

select is(pg_temp.r('p24_a_again') ->> 'error', 'rate_limited',
  'a late retry of the replaced report never replaces the newer one');
select is(pg_temp.has_report(24001) or not pg_temp.has_report(24002), false, 'the newer report stays');

-- Report conditions and timers stay on separate clocks (person 25, bar 2) ------------------------------------

insert into res values ('p25_start', pg_temp.start(25, 25001, 25002, pg_temp.bar(2), pg_temp.ago(30)));
insert into res values ('p25_cond', pg_temp.cond(25, 25003, pg_temp.bar(2), pg_temp.ago(29)));
insert into res values ('p25_cond_redo', pg_temp.cond(25, 25004, pg_temp.bar(2), pg_temp.ago(28)));

select is(pg_temp.r('p25_cond_redo') ->> 'ok', 'true', 'a Report conditions redo with a timer open');
select is(pg_temp.has_report(25003), false, 'replaces the earlier conditions report');
select is((pg_temp.session(25001)).status, 'open', 'and leaves the timer open');
select is(pg_temp.has_report(25002), true, 'and its line start');

insert into res values ('p25_end', pg_temp.end_line(25, 25001, 'gave_up', pg_temp.ago(27)));
insert into res values ('p25_redo', pg_temp.start(25, 25005, 25006, pg_temp.bar(2), pg_temp.ago(26)));
insert into res values ('p25_redo_end', pg_temp.end_line(25, 25005, 'entered', pg_temp.ago(25)));

select is(pg_temp.r('p25_redo') ->> 'ok', 'true', 'a timer redo after Report conditions');
select is(pg_temp.has_session(25001), false, 'replaces the earlier timer when it finishes');
select is(pg_temp.has_report(25004), true, 'and leaves the conditions report alone');

-- I'm inside (older builds) is never redone or replaced (people 26, 29, 30) ------------------------------------

insert into res values ('p26_inside', pg_temp.inside(26, 26001, pg_temp.bar(3), pg_temp.ago(30)));
insert into res values ('p26_cond', pg_temp.cond(26, 26002, pg_temp.bar(3), pg_temp.ago(28)));

select is(pg_temp.r('p26_cond') ->> 'error', 'rate_limited',
  'Report conditions 2 minutes after I''m inside is still refused');
select is(pg_temp.has_report(26001), true, 'the I''m inside report is not replaced');

insert into res values ('p29_a', pg_temp.inside(29, 29001, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p29_b', pg_temp.inside(29, 29002, pg_temp.bar(1), pg_temp.ago(28)));
insert into res values ('p30_cond', pg_temp.cond(30, 30001, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p30_inside', pg_temp.inside(30, 30002, pg_temp.bar(1), pg_temp.ago(28)));

select is(pg_temp.r('p29_b') ->> 'error', 'rate_limited', 'submit_report has no redo: I''m inside twice is refused');
select is(pg_temp.r('p30_inside') ->> 'error', 'rate_limited',
  'I''m inside 2 minutes after Report conditions is refused');
select is(pg_temp.has_report(30001), true, 'and replaces nothing');

-- Report conditions: other bars and other people are untouched (people 27 and 28) ------------------------------

insert into res values ('p27_a', pg_temp.cond(27, 27001, pg_temp.bar(1), pg_temp.ago(30)));
insert into res values ('p27_other_bar', pg_temp.cond(27, 27002, pg_temp.bar(2), pg_temp.ago(29)));
insert into res values ('p28_a', pg_temp.cond(28, 28001, pg_temp.bar(1), pg_temp.ago(29)));
insert into res values ('p27_redo', pg_temp.cond(27, 27003, pg_temp.bar(1), pg_temp.ago(28)));

select is(pg_temp.r('p27_redo') ->> 'ok', 'true', 'the redo is allowed');
select is(pg_temp.has_report(27001), false, 'it replaces the report at the same bar');
select is(pg_temp.has_report(27002), true, 'not the one at another bar');
select is(pg_temp.has_report(28001), true, 'nor another person''s');

-- Undo after I'm in (person 40, its own bar) ---------------------------------------------------------

insert into res values ('p40_start', pg_temp.start(40, 40001, 40002, pg_temp.ubar(), pg_temp.ago(20)));
insert into res values ('p40_adjust', pg_temp.start(40, 40001, 40002, pg_temp.ubar(), pg_temp.ago(20), p_offset => 7));
insert into res values ('p40_line', pg_temp.line(40, 40003, 40001, pg_temp.ago(15), 2));
insert into res values ('p40_end', pg_temp.end_line(40, 40001, 'entered', pg_temp.ago(2)));

select is(pg_temp.r('p40_end') ->> 'measured_wait_seconds', '1500', 'I''m in measures 18 minutes plus 7 adjusted');
select is(pg_temp.est() -> 'wait' ->> 'minutes', '25', 'the measured wait shows in estimates');

insert into res values ('p40_undo', pg_temp.reopen(40, 40001));

select is(pg_temp.r('p40_undo'), '{"ok": true, "status": "open", "reopened": true}'::jsonb,
  'Undo 2 minutes after I''m in reopens the timer (FR-47)');
select is((pg_temp.session(40001)).status, 'open', 'the timer is open again');
select is((pg_temp.session(40001)).ended_at, null::timestamptz, 'its end is cleared');
select is((pg_temp.session(40001)).ended_by, null::text, 'what ended it is cleared');
select is((pg_temp.session(40001)).distance_end_m, null::real, 'its end distance is cleared');
select is((pg_temp.session(40001)).measured_wait_seconds, null::integer, 'its measured wait is cleared');
select is((pg_temp.session(40001)).started_at, pg_temp.ago(20), 'its start time is kept');
select is((pg_temp.session(40001)).start_offset_minutes, 7::smallint, 'its Adjust time is kept');
select is((select count(*) from app.reports r where r.wait_session_id = (pg_temp.session(40001)).id), 2::bigint,
  'its reports are kept');
select is(pg_temp.est() -> 'wait', 'null'::jsonb, 'the wait no longer counts in estimates');
select is(pg_temp.est() -> 'line_size' ->> 'code', '2', 'its line size still counts, as in any open timer');

insert into res values ('p40_undo_again', pg_temp.reopen(40, 40001));

select is(pg_temp.r('p40_undo_again'), '{"ok": true, "status": "open", "reopened": false}'::jsonb,
  'a second Undo (a retry) changes nothing');

insert into res values ('p40_end_again', pg_temp.end_line(40, 40001, 'entered', pg_temp.ago(1)));

select is(pg_temp.r('p40_end_again') ->> 'measured_wait_seconds', '1560', 'I''m in again measures from the same start');
select is(pg_temp.est() -> 'wait' ->> 'minutes', '26', 'and the new wait counts');

-- Undo after Gave up (person 41) ---------------------------------------------------------------------------

insert into res values ('p41_start', pg_temp.start(41, 41001, 41002, pg_temp.bar(1), pg_temp.ago(10)));
insert into res values ('p41_end', pg_temp.end_line(41, 41001, 'gave_up', pg_temp.ago(1)));
insert into res values ('p41_undo', pg_temp.reopen(41, 41001));

select is(pg_temp.r('p41_undo') ->> 'reopened', 'true', 'Undo after Gave up reopens the timer');
select is((pg_temp.session(41001)).status, 'open', 'the timer is open again');
select is((pg_temp.session(41001)).started_at, pg_temp.ago(10), 'with its start time');

-- Undo refusals ---------------------------------------------------------------------------------------------

insert into res values ('p42_start', pg_temp.start(42, 42001, 42002, pg_temp.bar(2), pg_temp.ago(20)));
insert into res values ('p42_end', pg_temp.end_line(42, 42001, 'entered', pg_temp.ago(6)));
insert into res values ('p42_undo', pg_temp.reopen(42, 42001));

select is(pg_temp.r('p42_undo'), '{"ok": false, "error": "too_late"}'::jsonb, 'Undo 6 minutes after I''m in is too late');
select is((pg_temp.session(42001)).status, 'entered', 'the timer stays ended');

insert into res values ('p43_start', pg_temp.start(43, 43001, 43002, pg_temp.bar(2), pg_temp.ago(20)));
insert into res values ('p43_end', pg_temp.end_line(43, 43001, 'gave_up', pg_temp.ago(5)));

select is(pg_temp.reopen(43, 43001) ->> 'error', 'too_late', 'Undo exactly 5 minutes after is too late');

insert into res values ('p44_start', pg_temp.start(44, 44001, 44002, pg_temp.bar(1), pg_temp.ago(20)));
insert into res values ('p44_end', pg_temp.end_line(44, 44001, 'entered', pg_temp.ago(2)));
insert into res values ('p44_other', pg_temp.start(44, 44003, 44004, pg_temp.bar(2), pg_temp.ago(1)));
insert into res values ('p44_undo', pg_temp.reopen(44, 44001));

select is(pg_temp.r('p44_undo'), '{"ok": false, "error": "other_session_open"}'::jsonb,
  'Undo while another timer is open is refused');
select is((pg_temp.session(44001)).status, 'entered', 'the timer stays ended');
select is((pg_temp.session(44003)).status, 'open', 'the other timer stays open');

insert into res values ('p45_start', pg_temp.start(45, 45001, 45002, pg_temp.bar(3), pg_temp.ago(200)));
insert into res values ('p45_undo', pg_temp.reopen(45, 45001));

select is(pg_temp.r('p45_undo'), '{"ok": false, "error": "session_not_reopenable", "status": "unfinished"}'::jsonb,
  'an unfinished timer (FR-10) cannot be reopened');

insert into res values ('p46_a', pg_temp.start(46, 46001, 46002, pg_temp.bar(1), pg_temp.ago(5)));
insert into res values ('p46_b', pg_temp.start(46, 46003, 46004, pg_temp.bar(2), pg_temp.ago(3)));
insert into res values ('p46_cancel', pg_temp.cancel(46, 46003));
insert into res values ('p46_undo', pg_temp.reopen(46, 46001));

select is((pg_temp.session(46001)).ended_by, 'new_line', 'a line at another bar closed the first timer (FR-14)');
select is(pg_temp.r('p46_undo'), '{"ok": false, "error": "session_not_reopenable", "status": "gave_up"}'::jsonb,
  'a timer closed by a new line, not by I''m in or Gave up, cannot be reopened');

insert into res values ('p47_other', public.reopen_session(pg_temp.uid(42001), pg_temp.uid(47)));
insert into res values ('p47_unknown', pg_temp.reopen(47, 47999));

select is(pg_temp.r('p47_other'), '{"ok": true, "reopened": false, "removed": true}'::jsonb,
  'nobody can reopen someone else''s timer: it is treated as gone');
select is((pg_temp.session(42001)).status, 'entered', 'the other person''s timer is untouched');
select is(pg_temp.r('p47_unknown'), '{"ok": true, "reopened": false, "removed": true}'::jsonb,
  'reopening a timer that never reached the server is a no-op the queue can drop');

select throws_ok($$select public.reopen_session(null, pg_temp.uid(47))$$,
  '22023', 'client_session_id and anon_id are required', 'reopen_session needs a session ID');
select throws_ok($$select public.reopen_session(pg_temp.uid(47999), null)$$,
  '22023', 'client_session_id and anon_id are required', 'reopen_session needs an anonymous ID');

-- Undo after a redo (person 48, bar 3) ---------------------------------------------------------------------

insert into res values ('p48_a', pg_temp.start(48, 48001, 48002, pg_temp.bar(3), pg_temp.ago(12)));
insert into res values ('p48_a_end', pg_temp.end_line(48, 48001, 'entered', pg_temp.ago(8)));
insert into res values ('p48_b', pg_temp.start(48, 48003, 48004, pg_temp.bar(3), pg_temp.ago(6)));
insert into res values ('p48_b_end', pg_temp.end_line(48, 48003, 'entered', pg_temp.ago(2)));
insert into res values ('p48_undo', pg_temp.reopen(48, 48003));

select is(pg_temp.r('p48_b') ->> 'ok', 'true', 'B redoes A');
select is(pg_temp.r('p48_undo') ->> 'reopened', 'true', 'Undo reopens B');
select is(pg_temp.has_session(48001), false, 'A, replaced when B finished, stays deleted');
select is(pg_temp.sessions(48), 1::bigint, 'only B is left, open');

select * from finish();
rollback;
