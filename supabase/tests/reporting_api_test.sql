-- Reporting API (FR-6 to FR-16, FR-26, FR-27, FR-34, FR-35, FR-38).
--
-- now() is fixed for the whole transaction and phone times are capped at
-- now(), so each step passes an explicit phone time in the past
-- (pg_temp.ago(minutes)). Each person is a separate anonymous ID, so the
-- rate limit and session rules of one scenario never touch another.
-- Seed bars: 1 = Doggie's Pub, 2 = The Phyrst, 3 = Cafe 210 West.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(201);

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
                              p_bar bigint, p_at timestamptz, p_offset integer default null,
                              p_line integer default null, p_line_state text default null)
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
    p_start_offset_minutes => p_offset::smallint,
    p_line_size            => p_line::smallint,
    p_line_size_state      => p_line_state)
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

-- I'm inside (or the busyness answer after I'm in, with p_session).
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

-- app.locate at Doggie's Pub, with the reporter p_north_m meters north of the door.
create function pg_temp.loc(p_status text, p_north_m double precision, p_accuracy_m double precision,
                            p_fix_age_s double precision, p_with_coords boolean default true)
returns table (distance_m real, bearing_deg real, uncertain boolean)
language sql stable as $$
  select l.distance_m, l.bearing_deg, l.uncertain
  from app.bars b
  cross join lateral app.locate(
    b.id, p_status,
    case when p_with_coords then b.door_lat + p_north_m / 111195.08 end,
    case when p_with_coords then b.door_lon end,
    p_accuracy_m, p_fix_age_s) as l
  where b.name = 'Doggie''s Pub'
$$;

-- Person 1: I'm in line, been here a while, line size, I'm in (FR-6 to FR-8) -------------

insert into res values ('p1_start', pg_temp.start(1, 1001, 2001, pg_temp.bar(1), pg_temp.ago(300)));

select is(pg_temp.r('p1_start') ->> 'ok', 'true', 'start_session succeeds');
select is(pg_temp.r('p1_start') ->> 'already_open', 'false', 'start_session: not already open');
select is(pg_temp.r('p1_start') ->> 'client_session_id', pg_temp.uid(1001)::text, 'start_session returns the session ID');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(1)), 1::bigint, 'one session is created');
select is((pg_temp.session(1001)).status, 'open', 'the session is open');
select is((pg_temp.session(1001)).started_at, pg_temp.ago(300), 'the session starts at the phone time');
select is((pg_temp.session(1001)).night_date, app.night_date(pg_temp.ago(300)), 'the session night date is set on the server');
select is((pg_temp.session(1001)).start_offset_minutes, 0::smallint, 'no start offset by default');
select is((pg_temp.report(2001)).kind, 'line_start', 'a line_start report is created');
select is((pg_temp.report(2001)).position, 'line', 'the line_start report is in line');
select is((pg_temp.report(2001)).wait_session_id, (pg_temp.session(1001)).id, 'the line_start report belongs to the session');
select is((pg_temp.report(2001)).line_size_state, null::text, 'line size was not asked yet');
select is((pg_temp.report(2001)).night_date, app.night_date(pg_temp.ago(300)), 'the report night date is set on the server (FR-22)');
select is((pg_temp.report(2001)).phone_time, pg_temp.ago(300), 'the report keeps the phone time');

-- Re-sending the same session ID sets "been here a while" and the first line size.
insert into res values ('p1_resend', pg_temp.start(1, 1001, 2002, pg_temp.bar(1), pg_temp.ago(299),
                                                   p_offset => 10, p_line => 2, p_line_state => 'answered'));

select is(pg_temp.r('p1_resend') ->> 'ok', 'true', 're-sending the session succeeds');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(1)), 1::bigint, 're-sending does not duplicate the session');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(1)), 1::bigint, 're-sending does not duplicate the report');
select is((pg_temp.session(1001)).start_offset_minutes, 10::smallint, 'been here ~10 min is saved (FR-7)');
select is((pg_temp.report(2001)).line_size, 2::smallint, 'the first line size is saved on the line_start report');
select is((pg_temp.report(2001)).line_size_state, 'answered', 'the line size state is answered');
select is((pg_temp.session(1001)).started_at, pg_temp.ago(300), 're-sending keeps the original start time');

-- Line-size update (rate-limit exempt, FR-13) and its retry.
insert into res values ('p1_line', pg_temp.line(1, 2003, 1001, pg_temp.ago(295), 'answered', 4));

select is(pg_temp.r('p1_line') ->> 'ok', 'true', 'update_line_size succeeds 5 minutes after the line start');
select is((pg_temp.report(2003)).kind, 'line_update', 'a line_update report is created');
select is((pg_temp.report(2003)).line_size, 4::smallint, 'the updated line size is saved');
select is((pg_temp.report(2003)).wait_session_id, (pg_temp.session(1001)).id, 'the update belongs to the session');

insert into res values ('p1_line_again', pg_temp.line(1, 2003, 1001, pg_temp.ago(295), 'cant_tell'));

select is(pg_temp.r('p1_line_again') ->> 'ok', 'true', 're-sending a line update succeeds');
select is((pg_temp.report(2003)).line_size, null::smallint, 're-sending changes the answer in place');
select is((pg_temp.report(2003)).line_size_state, 'cant_tell', 'the new state is cant_tell');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(1) and r.kind = 'line_update'), 1::bigint,
  're-sending a line update does not duplicate it');

-- I'm in: measured wait = end - start + offset = 30 + 10 minutes.
insert into res values ('p1_end', pg_temp.end_line(1, 1001, 'entered', pg_temp.ago(270)));

select is(pg_temp.r('p1_end') ->> 'status', 'entered', 'I''m in ends the session as entered (FR-8)');
select is(pg_temp.r('p1_end') ->> 'measured_wait_seconds', '2400', 'measured wait = end - start + offset');
select is((pg_temp.session(1001)).ended_by, 'im_in', 'ended_by is im_in');
select is((pg_temp.session(1001)).ended_at, pg_temp.ago(270), 'ended_at is the phone time of I''m in');

insert into res values ('p1_end_again', pg_temp.end_line(1, 1001, 'gave_up', pg_temp.ago(260)));

select is(pg_temp.r('p1_end_again') ->> 'ok', 'true', 'ending again succeeds');
select is(pg_temp.r('p1_end_again') ->> 'status', 'entered', 'ending again keeps the first outcome');
select is(pg_temp.r('p1_end_again') ->> 'measured_wait_seconds', '2400', 'ending again keeps the measured wait');
select is((pg_temp.session(1001)).ended_at, pg_temp.ago(270), 'ending again keeps the end time');

insert into res values ('p1_line_late', pg_temp.line(1, 2004, 1001, pg_temp.ago(265), 'answered', 1));

select is(pg_temp.r('p1_line_late') ->> 'error', 'session_not_open', 'no line updates after the session ends');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(2004)), 0::bigint,
  'the refused line update is not saved');

insert into res values ('p1_end_unknown', pg_temp.end_line(1, 1999, 'entered', pg_temp.ago(260)));

select is(pg_temp.r('p1_end_unknown') ->> 'error', 'session_not_found', 'ending an unknown session is refused');

-- Person 2: Gave up (FR-9) ----------------------------------------------------------------

insert into res values ('p2_start', pg_temp.start(2, 1021, 2021, pg_temp.bar(1), pg_temp.ago(300)));
insert into res values ('p2_end', pg_temp.end_line(2, 1021, 'gave_up', pg_temp.ago(290)));

select is(pg_temp.r('p2_end') ->> 'status', 'gave_up', 'Gave up ends the session as gave_up');
select is(pg_temp.r('p2_end') ->> 'measured_wait_seconds', null::text, 'a gave-up session has no measured wait');
select is((pg_temp.session(1021)).ended_by, 'gave_up', 'ended_by is gave_up');
select is((pg_temp.session(1021)).measured_wait_seconds, null::integer, 'measured_wait_seconds is null when gave up');

-- Person 3: busyness after I'm in is rate-limit exempt (FR-13) ----------------------------

insert into res values ('p3_start', pg_temp.start(3, 1031, 2031, pg_temp.bar(2), pg_temp.ago(300)));
insert into res values ('p3_end', pg_temp.end_line(3, 1031, 'entered', pg_temp.ago(295)));

select is(pg_temp.r('p3_end') ->> 'measured_wait_seconds', '300', 'a 5-minute wait is 300 seconds');

insert into res values ('p3_busy', pg_temp.inside(3, 2032, pg_temp.bar(2), pg_temp.ago(294),
                                                  p_busy => 3, p_busy_state => 'answered', p_session => 1031));

select is(pg_temp.r('p3_busy') ->> 'ok', 'true', 'the busyness answer after I''m in is accepted 6 minutes after the line start');
select is(pg_temp.r('p3_busy') ->> 'kind', 'inside_after_entry', 'it is an inside_after_entry report');
select is(pg_temp.r('p3_busy') ->> 'session_ended', 'false', 'it does not end anything');
select is((pg_temp.report(2032)).wait_session_id, (pg_temp.session(1031)).id, 'it is linked to the session');
select is((pg_temp.report(2032)).busyness, 3::smallint, 'the busyness is saved');

insert into res values ('p3_busy_twice', pg_temp.inside(3, 2039, pg_temp.bar(2), pg_temp.ago(293),
                                                        p_busy => 1, p_busy_state => 'answered', p_session => 1031));

-- Not exempt, but the line start is on the timed clock, so the manual clock is free.
select is(pg_temp.r('p3_busy_twice') ->> 'kind', 'inside',
  'a second report after the same I''m in is not exempt: it is a counted inside report');
select is((pg_temp.report(2039)).wait_session_id, null::bigint,
  'the second report after I''m in is not linked to the session');

insert into res values ('p3_early', pg_temp.inside(3, 2033, pg_temp.bar(2), pg_temp.ago(290),
                                                   p_busy => 2, p_busy_state => 'answered'));

select is(pg_temp.r('p3_early') ->> 'ok', 'false', 'a new I''m inside 3 minutes after the counted one is refused');
select is(pg_temp.r('p3_early') ->> 'error', 'rate_limited', 'the refusal is rate_limited');
select is(pg_temp.r('p3_early') ->> 'retry_after_seconds', '420', 'retry_after_seconds is the time left');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(2033)), 0::bigint,
  'a rate-limited report is not saved');

insert into res values ('p3_later', pg_temp.inside(3, 2034, pg_temp.bar(2), pg_temp.ago(282)));

select is(pg_temp.r('p3_later') ->> 'ok', 'true', 'I''m inside 11 minutes after the counted one is accepted');
select is(pg_temp.r('p3_later') ->> 'kind', 'inside', 'it is a counted inside report');

-- Person 4: I'm in after 90 minutes does nothing (FR-10) ------------------------------------

insert into res values ('p4_start', pg_temp.start(4, 1041, 2041, pg_temp.bar(1), pg_temp.ago(300)));
insert into res values ('p4_end', pg_temp.end_line(4, 1041, 'entered', pg_temp.ago(200)));

select is(pg_temp.r('p4_end') ->> 'ok', 'true', 'a late I''m in is not an error');
select is(pg_temp.r('p4_end') ->> 'status', 'unfinished', 'a late I''m in finds the session unfinished');
select is(pg_temp.r('p4_end') ->> 'measured_wait_seconds', null::text, 'a late I''m in measures nothing');
select is((pg_temp.session(1041)).ended_by, 'timeout', 'the session ended by timeout');
select is((pg_temp.session(1041)).ended_at, pg_temp.ago(210), 'the timeout end is start + 90 minutes');

insert into res values ('p4_line', pg_temp.line(4, 2042, 1041, pg_temp.ago(205), 'answered', 1));

select is(pg_temp.r('p4_line') ->> 'error', 'session_not_open', 'no line updates on an unfinished session');

-- Person 40: an offline I'm in from before the timeout, arriving after the job ran (FR-16) ----

insert into res values ('p40_start', pg_temp.start(40, 1401, 2401, pg_temp.bar(3), pg_temp.ago(300)));
select is(app.expire_sessions() >= 1, true, 'the job expires the open session');
select is((pg_temp.session(1401)).status, 'unfinished', 'the session is unfinished before the late I''m in arrives');

insert into res values ('p40_end', pg_temp.end_line(40, 1401, 'entered', pg_temp.ago(250)));

select is(pg_temp.r('p40_end') ->> 'status', 'entered', 'an I''m in from 50 minutes after the start still counts');
select is(pg_temp.r('p40_end') ->> 'measured_wait_seconds', '3000', 'its measured wait is 50 minutes');
select is((pg_temp.session(1401)).ended_by, 'im_in', 'ended_by becomes im_in');

-- Person 41: cancel a line started by mistake (FR-39) -----------------------------------------

create function pg_temp.cancel(p_person integer, p_session integer) returns jsonb
language sql as $$
  select public.cancel_session(p_client_session_id => pg_temp.uid(p_session),
                               p_anon_id => pg_temp.uid(p_person))
$$;

insert into res values ('p41_start', pg_temp.start(41, 1411, 2411, pg_temp.bar(1), pg_temp.ago(300)));
insert into res values ('p41_line', pg_temp.line(41, 2412, 1411, pg_temp.ago(299), 'answered', 3));
insert into res values ('p41_cancel', pg_temp.cancel(41, 1411));

select is(pg_temp.r('p41_cancel') ->> 'ok', 'true', 'cancel_session succeeds');
select is(pg_temp.r('p41_cancel') ->> 'removed', 'true', 'cancel_session removes the session');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(41)), 0::bigint,
  'the cancelled session is deleted');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(41)), 0::bigint,
  'the cancelled session''s reports are deleted');

insert into res values ('p41_again', pg_temp.start(41, 1413, 2413, pg_temp.bar(1), pg_temp.ago(298)));
select is(pg_temp.r('p41_again') ->> 'ok', 'true', 'a cancelled line does not count toward the rate limit');

select is(pg_temp.cancel(41, 1499) ->> 'removed', 'false', 'cancelling an unknown session is a no-op');
select is(pg_temp.cancel(42, 1413) ->> 'removed', 'false', 'nobody can cancel someone else''s session');
select is((select count(*) from app.wait_sessions s where s.client_session_id = pg_temp.uid(1413)), 1::bigint,
  'the other person''s session is untouched');

insert into res values ('p41_end', pg_temp.end_line(41, 1413, 'entered', pg_temp.ago(290)));
select is(pg_temp.cancel(41, 1413) ->> 'error', 'session_not_open', 'a finished wait cannot be cancelled');
select is((pg_temp.session(1413)).status, 'entered', 'the finished wait stays');

-- Person 5: one line at a time (FR-14) ------------------------------------------------------

insert into res values ('p5_a', pg_temp.start(5, 1051, 2051, pg_temp.bar(1), pg_temp.ago(300)));
insert into res values ('p5_b', pg_temp.start(5, 1052, 2052, pg_temp.bar(2), pg_temp.ago(290)));

select is(pg_temp.r('p5_b') ->> 'ok', 'true', 'starting a line at another bar succeeds');
select is(pg_temp.r('p5_b') ->> 'already_open', 'false', 'the new line is a new session');
select is((pg_temp.session(1051)).status, 'gave_up', 'the old session ends as gave_up');
select is((pg_temp.session(1051)).ended_by, 'new_line', 'the old session was ended by a new line');
select is((pg_temp.session(1051)).ended_at, pg_temp.ago(290), 'the old session ends when the new line starts');
select is((pg_temp.session(1052)).status, 'open', 'the new session is open');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(5) and s.status = 'open'), 1::bigint,
  'only one session is open');

insert into res values ('p5_c', pg_temp.start(5, 1053, 2053, pg_temp.bar(2), pg_temp.ago(280)));

select is(pg_temp.r('p5_c') ->> 'already_open', 'true', 'starting again at the same bar returns already_open');
select is(pg_temp.r('p5_c') ->> 'client_session_id', pg_temp.uid(1052)::text, 'already_open returns the open session');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(5)), 2::bigint, 'no third session is created');
select is((select count(*) from app.reports r where r.client_report_id = pg_temp.uid(2053)), 0::bigint, 'no report is created');

-- Person 6: I'm inside with an open session counts as I'm in (FR-15) ---------------------------

insert into res values ('p6_start', pg_temp.start(6, 1061, 2061, pg_temp.bar(3), pg_temp.ago(300)));
insert into res values ('p6_inside', pg_temp.inside(6, 2062, pg_temp.bar(3), pg_temp.ago(280),
                                                    p_busy => 2, p_busy_state => 'answered'));

select is(pg_temp.r('p6_inside') ->> 'ok', 'true', 'I''m inside with an open session succeeds');
select is(pg_temp.r('p6_inside') ->> 'kind', 'inside_after_entry', 'it is an inside_after_entry report');
select is(pg_temp.r('p6_inside') ->> 'session_ended', 'true', 'it ends the session');
select is(pg_temp.r('p6_inside') ->> 'measured_wait_seconds', '1200', 'it measures the wait');
select is((pg_temp.session(1061)).status, 'entered', 'the session is entered');
select is((pg_temp.session(1061)).ended_by, 'im_inside', 'ended_by is im_inside');
select is((pg_temp.report(2062)).wait_session_id, (pg_temp.session(1061)).id, 'the report is linked to the session');
select is((pg_temp.report(2062)).position, 'inside', 'the report is inside');

-- Person 7: rate limit (FR-13): I'm inside is on the manual clock -------------------------------

insert into res values ('p7_a', pg_temp.inside(7, 2071, pg_temp.bar(1), pg_temp.ago(300)));

select is(pg_temp.r('p7_a') ->> 'kind', 'inside', 'a plain I''m inside is a counted inside report');

insert into res values ('p7_b', pg_temp.inside(7, 2072, pg_temp.bar(1), pg_temp.ago(295)));

select is(pg_temp.r('p7_b') ->> 'ok', 'false', 'a second report at the same bar 5 minutes later is refused');
select is(pg_temp.r('p7_b') ->> 'error', 'rate_limited', 'the refusal is rate_limited');
select is(pg_temp.r('p7_b') ->> 'retry_after_seconds', '300', 'retry after 5 more minutes');

insert into res values ('p7_c', pg_temp.inside(7, 2073, pg_temp.bar(2), pg_temp.ago(294)));

select is(pg_temp.r('p7_c') ->> 'ok', 'true', 'a report at a different bar is fine');

insert into res values ('p7_d', pg_temp.inside(7, 2074, pg_temp.bar(1), pg_temp.ago(289)));

select is(pg_temp.r('p7_d') ->> 'ok', 'true', 'the same bar 11 minutes later is fine');

insert into res values ('p7_f', pg_temp.inside(7, 2076, pg_temp.bar(1), pg_temp.ago(305)));

select is(pg_temp.r('p7_f') ->> 'error', 'rate_limited', 'a late (offline) report 5 minutes before a counted one is also limited');

-- I'm in line has its own (timed) clock, so I'm inside never blocks it.
insert into res values ('p7_e', pg_temp.start(7, 1071, 2075, pg_temp.bar(1), pg_temp.ago(285)));

select is(pg_temp.r('p7_e') ->> 'ok', 'true', 'I''m in line 4 minutes after I''m inside is allowed: separate clocks');
select is((select count(*) from app.wait_sessions s where s.anon_id = pg_temp.uid(7)), 1::bigint,
  'the line start creates a session');
select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(7)), 4::bigint,
  'the three accepted I''m inside reports and the line start are saved');

-- Person 8: line-size updates do not count toward the limit -------------------------------------

insert into res values ('p8_a', pg_temp.start(8, 1081, 2081, pg_temp.bar(1), pg_temp.ago(300)));
insert into res values ('p8_b', pg_temp.line(8, 2082, 1081, pg_temp.ago(292), 'answered', 3));
insert into res values ('p8_c', pg_temp.end_line(8, 1081, 'gave_up', pg_temp.ago(291)));
insert into res values ('p8_d', pg_temp.inside(8, 2083, pg_temp.bar(1), pg_temp.ago(289)));

select is(pg_temp.r('p8_b') ->> 'ok', 'true', 'a line update 8 minutes after the start is accepted');
select is(pg_temp.r('p8_d') ->> 'ok', 'true', 'a line update 3 minutes earlier does not rate-limit I''m inside');

-- Person 9: answers (FR-12) ------------------------------------------------------------------

insert into res values ('p9_a', pg_temp.inside(9, 2091, pg_temp.bar(2), pg_temp.ago(300),
                                               p_busy_state => 'cant_tell', p_wait_state => 'skipped'));

select is(pg_temp.r('p9_a') ->> 'ok', 'true', 'a report with cant_tell and skipped is accepted');
select is((pg_temp.report(2091)).busyness_state, 'cant_tell', 'cant_tell is stored');
select is((pg_temp.report(2091)).busyness, null::smallint, 'cant_tell has no value');
select is((pg_temp.report(2091)).recalled_wait_state, 'skipped', 'skipped is stored separately from cant_tell');

insert into res values ('p9_b', pg_temp.inside(9, 2091, pg_temp.bar(2), pg_temp.ago(300),
                                               p_wait => 3, p_wait_state => 'answered'));

select is(pg_temp.r('p9_b') ->> 'ok', 'true', 'a later answer for the same report is accepted');
select is((pg_temp.report(2091)).recalled_wait, 3::smallint, 'the later answer is saved');
select is((pg_temp.report(2091)).recalled_wait_state, 'answered', 'the later answer state is answered');
select is((pg_temp.report(2091)).busyness_state, 'cant_tell', 'answers not re-sent are kept');

insert into res values ('p9_c', pg_temp.inside(9, 2091, pg_temp.bar(2), pg_temp.ago(300),
                                               p_wait => 3, p_wait_state => 'answered'));

select is((select count(*) from app.reports r where r.anon_id = pg_temp.uid(9)), 1::bigint,
  'retrying the same client_report_id does not duplicate the report (FR-16)');

insert into res values ('p9_d', pg_temp.inside(9, 2092, pg_temp.bar(3), pg_temp.ago(300)));

select is((pg_temp.report(2092)).busyness_state, null::text, 'a question not asked has a null state, unlike skipped');

select throws_ok($$select pg_temp.inside(10, 2091, pg_temp.bar(2), pg_temp.ago(250))$$,
  '22023', null, 'another anon reusing a client_report_id is rejected');

-- Bad input raises 22023 ---------------------------------------------------------------------

select throws_ok($$select pg_temp.inside(11, 2111, pg_temp.bar(1), pg_temp.ago(100), p_busy => 2)$$,
  '22023', null, 'a value without a state is rejected');
select throws_ok($$select pg_temp.inside(11, 2112, pg_temp.bar(1), pg_temp.ago(100), p_busy_state => 'answered')$$,
  '22023', null, 'answered without a value is rejected');
select throws_ok($$select pg_temp.inside(11, 2113, pg_temp.bar(1), pg_temp.ago(100), p_busy => 2, p_busy_state => 'cant_tell')$$,
  '22023', null, 'cant_tell with a value is rejected');
select throws_ok($$select pg_temp.inside(11, 2114, pg_temp.bar(1), pg_temp.ago(100), p_wait => 2, p_wait_state => 'skipped')$$,
  '22023', null, 'skipped with a value is rejected');
select throws_ok($$select pg_temp.inside(11, 2115, pg_temp.bar(1), pg_temp.ago(100), p_busy => 5, p_busy_state => 'answered')$$,
  '22023', null, 'busyness code 5 is out of range');
select throws_ok($$select pg_temp.inside(11, 2116, pg_temp.bar(1), pg_temp.ago(100), p_wait => 6, p_wait_state => 'answered')$$,
  '22023', null, 'recalled wait code 6 is out of range');
select throws_ok($$select pg_temp.inside(11, 2117, pg_temp.bar(1), pg_temp.ago(100), p_busy_state => 'maybe')$$,
  '22023', null, 'an unknown answer state is rejected');
select throws_ok($$select pg_temp.start(11, 1111, 2118, pg_temp.bar(1), pg_temp.ago(100), p_line => 6, p_line_state => 'answered')$$,
  '22023', null, 'line size code 6 is out of range');
select throws_ok($$select pg_temp.start(11, 1112, 2119, pg_temp.bar(1), pg_temp.ago(100), p_offset => 91)$$,
  '22023', null, 'a start offset over 90 minutes is rejected');
select throws_ok($$select pg_temp.inside(11, 2120, 999999, pg_temp.ago(100))$$,
  '22023', null, 'an unknown bar is rejected');
select throws_ok(
  $$select public.submit_report(
      p_client_report_id => pg_temp.uid(2121), p_anon_id => pg_temp.uid(11), p_install_id => pg_temp.uid(511),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'denied',
      p_app_version => '1.0', p_definitions_version => 2::smallint)$$,
  '22023', null, 'an unsupported definitions version is rejected');
select throws_ok(
  $$select public.submit_report(
      p_client_report_id => pg_temp.uid(2122), p_anon_id => pg_temp.uid(11), p_install_id => pg_temp.uid(511),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'gps',
      p_app_version => '1.0', p_definitions_version => 1::smallint)$$,
  '22023', null, 'an unknown location status is rejected');
select throws_ok(
  $$select public.submit_report(
      p_client_report_id => pg_temp.uid(2123), p_anon_id => null, p_install_id => pg_temp.uid(511),
      p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(100), p_location_status => 'denied',
      p_app_version => '1.0', p_definitions_version => 1::smallint)$$,
  '22023', null, 'a missing anon ID is rejected');
select throws_ok($$select pg_temp.end_line(1, 1001, 'maybe', pg_temp.ago(100))$$,
  '22023', null, 'an unknown end outcome is rejected');
select throws_ok($$select pg_temp.line(11, 2124, 1001, pg_temp.ago(100), null)$$,
  '22023', null, 'a line update needs a state');
select throws_ok($$select pg_temp.start(12, 1001, 2125, pg_temp.bar(3), pg_temp.ago(100))$$,
  '22023', null, 'another anon reusing a client_session_id is rejected');
select throws_ok($$select pg_temp.line(12, 2001, 1001, pg_temp.ago(100), 'answered', 1)$$,
  '22023', null, 'another anon reusing a line report ID is rejected');
select throws_ok(
  $$select public.log_view(p_anon_id => pg_temp.uid(11), p_install_id => pg_temp.uid(511), p_view_kind => 'bar',
                           p_app_open_id => pg_temp.uid(3011), p_viewed_at => pg_temp.ago(1), p_showed_no_data => false)$$,
  '22023', null, 'a bar view needs a bar');
select throws_ok(
  $$select public.log_view(p_anon_id => pg_temp.uid(11), p_install_id => pg_temp.uid(511), p_view_kind => 'map',
                           p_app_open_id => pg_temp.uid(3011), p_viewed_at => pg_temp.ago(1), p_showed_no_data => false,
                           p_bar_id => pg_temp.bar(1))$$,
  '22023', null, 'a map view takes no bar');
select throws_ok(
  $$select public.register_install(pg_temp.uid(11), pg_temp.uid(511), '', '18.0', 'iPhone16,1')$$,
  '22023', null, 'an empty app version is rejected');
select is(
  (select count(*) from app.reports r where r.anon_id in (pg_temp.uid(10), pg_temp.uid(11), pg_temp.uid(12)))
  + (select count(*) from app.wait_sessions s where s.anon_id in (pg_temp.uid(10), pg_temp.uid(11), pg_temp.uid(12))),
  0::bigint, 'rejected calls save nothing');

-- Location (FR-26, FR-27) ------------------------------------------------------------------------

insert into res values ('p13', public.submit_report(
  p_client_report_id    => pg_temp.uid(2131),
  p_anon_id             => pg_temp.uid(13),
  p_install_id          => pg_temp.uid(513),
  p_bar_id              => pg_temp.bar(1),
  p_phone_time          => pg_temp.ago(100),
  p_location_status     => 'precise',
  p_app_version         => '1.0',
  p_definitions_version => 1::smallint,
  p_lat                 => (select b.door_lat from app.bars b where b.id = pg_temp.bar(1)),
  p_lon                 => (select b.door_lon from app.bars b where b.id = pg_temp.bar(1)),
  p_accuracy_m          => 12,
  p_fix_age_s           => 3));

select is(pg_temp.r('p13') ->> 'ok', 'true', 'a precise report at the door is accepted');
select is((pg_temp.report(2131)).uncertain, false, 'precise and close is not uncertain');
select ok((pg_temp.report(2131)).distance_m < 1, 'distance at the door is about 0 m');
select is((pg_temp.report(2131)).accuracy_m, 12::real, 'accuracy is stored');
select is((pg_temp.report(2131)).fix_age_s, 3::real, 'fix age is stored');
select is((pg_temp.report(2131)).location_status, 'precise', 'location status is stored');
select is((pg_temp.report(2071)).uncertain, true, 'a report with location denied is uncertain, not rejected');
select is((pg_temp.report(2071)).distance_m, null::real, 'a denied report has no distance');

select is((select l.uncertain from pg_temp.loc('precise', 0, 10, 5) l), false, 'locate: precise at the door is certain');
select ok((select l.distance_m < 1 from pg_temp.loc('precise', 0, 10, 5) l), 'locate: distance at the door is ~0');
select is((select l.uncertain from pg_temp.loc('precise', 140, 10, 5) l), false, 'locate: 140 m away is within 150 m');
select is((select l.uncertain from pg_temp.loc('precise', 300, 10, 5) l), true, 'locate: 300 m away is uncertain');
select ok((select l.distance_m between 295 and 305 from pg_temp.loc('precise', 300, 10, 5) l), 'locate: 300 m north measures ~300 m');
select ok((select l.bearing_deg < 1 or l.bearing_deg > 359 from pg_temp.loc('precise', 300, 10, 5) l),
  'locate: due north has a bearing of ~0 degrees');
select is((select l.uncertain from pg_temp.loc('approximate', 0, 10, 5) l), true, 'locate: approximate location is uncertain');
select ok((select l.distance_m < 1 from pg_temp.loc('approximate', 0, 10, 5) l), 'locate: approximate still gets a distance');
select is((select l.uncertain from pg_temp.loc('denied', 0, 10, 5) l), true, 'locate: denied is uncertain');
select is((select l.distance_m from pg_temp.loc('denied', 0, 10, 5) l), null::real, 'locate: coordinates sent with denied are ignored');
select is((select l.uncertain from pg_temp.loc('denied', null, null, null, false) l), true, 'locate: denied without coordinates is uncertain');
select is((select l.uncertain from pg_temp.loc('no_fix', null, null, null, false) l), true, 'locate: no fix in time is uncertain');
select is((select l.uncertain from pg_temp.loc('precise', 0, 250, 5) l), true, 'locate: poor accuracy is uncertain');
select is((select l.uncertain from pg_temp.loc('precise', 0, null, 5) l), true, 'locate: unknown accuracy is uncertain');
select is((select l.uncertain from pg_temp.loc('precise', 0, 10, 600) l), true, 'locate: an old fix is uncertain');
select is((select l.uncertain from pg_temp.loc('precise', null, 10, 5, false) l), true,
  'locate: precise with missing coordinates is uncertain, never null');

-- Night date and phone time are set on the server (FR-16, FR-22) -------------------------------------

select is((pg_temp.report(2071)).night_date, app.night_date(pg_temp.ago(300)), 'night_date comes from the phone time');

insert into res values ('p15', pg_temp.inside(15, 2151, pg_temp.bar(1), now() + interval '2 hours'));

select is((pg_temp.report(2151)).phone_time, now(), 'a phone time in the future is capped at server time');
select is((pg_temp.report(2151)).night_date, app.night_date(now()), 'the night date uses the capped time');

-- Test data (FR-38): IDs in test_anon_ids, matched case-insensitively ----------------------------------

update app.config set value = '["ABCDEF00-0000-4000-8000-0000000000AA"]' where key = 'test_anon_ids';

select ok(app.is_test_anon('abcdef00-0000-4000-8000-0000000000aa'), 'an uppercase test ID matches');
select ok(not app.is_test_anon(pg_temp.uid(1)), 'other IDs are not test IDs');

insert into res values ('t_install', public.register_install(
  'abcdef00-0000-4000-8000-0000000000aa', pg_temp.uid(9001), '1.0', '18.0', 'iPhone16,1'));
insert into res values ('t_start', public.start_session(
  p_client_session_id => pg_temp.uid(9101), p_client_report_id => pg_temp.uid(9201),
  p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa', p_install_id => pg_temp.uid(9001),
  p_bar_id => pg_temp.bar(1), p_phone_time => pg_temp.ago(10), p_location_status => 'no_fix',
  p_app_version => '1.0', p_definitions_version => 1::smallint));
insert into res values ('t_inside', public.submit_report(
  p_client_report_id => pg_temp.uid(9202), p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa',
  p_install_id => pg_temp.uid(9001), p_bar_id => pg_temp.bar(2), p_phone_time => pg_temp.ago(10),
  p_location_status => 'no_fix', p_app_version => '1.0', p_definitions_version => 1::smallint));
insert into res values ('t_view', public.log_view(
  p_anon_id => 'abcdef00-0000-4000-8000-0000000000aa', p_install_id => pg_temp.uid(9001),
  p_view_kind => 'map', p_app_open_id => pg_temp.uid(9301), p_viewed_at => pg_temp.ago(10),
  p_showed_no_data => true));
insert into res values ('t_feedback', public.send_feedback(
  'abcdef00-0000-4000-8000-0000000000aa', pg_temp.uid(9001), pg_temp.bar(1), pg_temp.ago(10), '{}'::jsonb));

select is((select bool_and(i.is_test) from app.installs i where i.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'), true,
  'the test ID''s install is a test row');
select is((select bool_and(s.is_test) from app.wait_sessions s where s.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'), true,
  'the test ID''s session is a test row');
select is((select count(*) filter (where r.is_test) from app.reports r where r.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'), 2::bigint,
  'both of the test ID''s reports are test rows');
select is((select bool_and(v.is_test) from app.views v where v.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'), true,
  'the test ID''s view is a test row');
select is((select bool_and(f.is_test) from app.feedback f where f.anon_id = 'abcdef00-0000-4000-8000-0000000000aa'), true,
  'the test ID''s feedback is a test row');
select is((pg_temp.report(2071)).is_test, false, 'other people''s reports are not test rows');
select is((pg_temp.session(1001)).is_test, false, 'other people''s sessions are not test rows');

insert into app.bars (name, address, door_lat, door_lon, is_test)
values ('Max test bar', 'Test address', 40.7940, -77.8610, true);

select is(jsonb_array_length(public.get_bars()), 3, 'get_bars hides test bars');
select is(jsonb_array_length(public.get_bars(pg_temp.uid(1))), 3, 'get_bars hides test bars from real IDs');
select is(jsonb_array_length(public.get_bars('abcdef00-0000-4000-8000-0000000000aa')), 4, 'get_bars shows test bars to test IDs');
select is(jsonb_array_length(public.get_estimates() -> 'bars'), 3, 'get_estimates hides test bars');
select is(jsonb_array_length(public.get_estimates('abcdef00-0000-4000-8000-0000000000aa') -> 'bars'), 4,
  'get_estimates shows test bars to test IDs');
select is((public.get_estimates() ->> 'logic_version')::integer, 1, 'get_estimates carries the logic version');

-- Installs, views, feedback (FR-30, FR-34, FR-35) ------------------------------------------------------

insert into res values ('reg_1', public.register_install(pg_temp.uid(20), pg_temp.uid(520), '1.0', '18.0', 'iPhone16,1'));
insert into res values ('reg_2', public.register_install(pg_temp.uid(20), pg_temp.uid(520), '1.1', '18.1', 'iPhone16,1'));

select is(pg_temp.r('reg_2') ->> 'ok', 'true', 'register_install can be called again');
select is((select count(*) from app.installs i where i.anon_id = pg_temp.uid(20)), 1::bigint, 'the same install is one row');
select is((select i.app_version from app.installs i where i.anon_id = pg_temp.uid(20)), '1.1', 'the install row is updated');

insert into res values ('reg_3', public.register_install(pg_temp.uid(20), pg_temp.uid(521), '1.1', '18.1', 'iPhone16,1'));

select is((select count(*) from app.installs i where i.anon_id = pg_temp.uid(20)), 2::bigint, 'a reinstall is a new row');

insert into res values ('view_map', public.log_view(
  p_anon_id => pg_temp.uid(20), p_install_id => pg_temp.uid(520), p_view_kind => 'map',
  p_app_open_id => pg_temp.uid(3001), p_viewed_at => pg_temp.ago(5), p_showed_no_data => true));
insert into res values ('view_bar', public.log_view(
  p_anon_id => pg_temp.uid(20), p_install_id => pg_temp.uid(520), p_view_kind => 'bar',
  p_app_open_id => pg_temp.uid(3001), p_viewed_at => pg_temp.ago(4), p_showed_no_data => false,
  p_bar_id => pg_temp.bar(2), p_estimate_shown => '{"display": "estimate"}', p_logic_version => 1));

select is(pg_temp.r('view_map') ->> 'ok', 'true', 'log_view accepts a map view');
select is((select count(*) from app.views v where v.anon_id = pg_temp.uid(20)), 2::bigint, 'both views are logged');
select is((select v.logic_version from app.views v where v.anon_id = pg_temp.uid(20) and v.view_kind = 'bar'), 1,
  'a bar view keeps the logic version');

insert into res values ('feedback', public.send_feedback(
  pg_temp.uid(20), pg_temp.uid(520), pg_temp.bar(3), pg_temp.ago(5), '{"display": "estimate"}'));

select is(pg_temp.r('feedback') ->> 'ok', 'true', 'send_feedback succeeds');
select is((select f.phone_time from app.feedback f where f.anon_id = pg_temp.uid(20)), pg_temp.ago(5), 'feedback keeps the time');
select is((select f.estimate_shown ->> 'display' from app.feedback f where f.anon_id = pg_temp.uid(20)), 'estimate',
  'feedback keeps the estimate shown');

-- The expire-sessions job (FR-10) ---------------------------------------------------------------------

insert into res values ('p16', pg_temp.start(16, 1161, 2161, pg_temp.bar(1), pg_temp.ago(120)));
insert into res values ('p17', pg_temp.start(17, 1171, 2171, pg_temp.bar(2), pg_temp.ago(30)));

select ok(app.expire_sessions() >= 1, 'expire_sessions closes overdue sessions');
select is((pg_temp.session(1161)).status, 'unfinished', 'a session open for 120 minutes is unfinished');
select is((pg_temp.session(1161)).ended_by, 'timeout', 'it ended by timeout');
select is((pg_temp.session(1161)).ended_at, pg_temp.ago(30), 'it ended at start + 90 minutes');
select is((pg_temp.session(1171)).status, 'open', 'a session open for 30 minutes stays open');
select ok(app.expire_sessions(now() + interval '61 minutes') >= 1, 'expire_sessions takes a time');
select is((pg_temp.session(1171)).status, 'unfinished', 'the 30-minute session expires 61 minutes later');

select * from finish();
rollback;
