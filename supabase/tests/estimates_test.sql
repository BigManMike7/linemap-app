-- Live estimates (FR-17 to FR-21).
--
-- Each scenario gets its own bar, and rows are inserted straight into the app
-- tables, so the rules are tested through app.pick_signal, app.bar_estimate,
-- and app.estimates at fixed times. T is Friday Oct 2, 2026, 11 p.m. Eastern.
-- Since logic version 3 there is no active window: the same rules apply at
-- every hour. Since logic version 4 busyness is ignored (always null) and line
-- sizes are compared by size rank (app.line_size_rank).

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(98);

-- Helpers ----------------------------------------------------------------------------

create function pg_temp.uid(p_n integer) returns uuid
language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid $$;

-- T minus some minutes.
create function pg_temp.ago(p_minutes integer) returns timestamptz
language sql stable as
$$ select timestamptz '2026-10-03 03:00:00+00' - make_interval(mins => p_minutes) $$;

create function pg_temp.new_bar(p_name text, p_is_test boolean default false) returns bigint
language sql as $$
  insert into app.bars (name, address, door_lat, door_lon, display_order, is_test)
  values (p_name, 'Test address', 40.7940, -77.8610, 100, p_is_test)
  returning id
$$;

create function pg_temp.bar(p_name text) returns bigint
language sql stable as
$$ select b.id from app.bars b where b.name = p_name $$;

-- A report from person p_person. Codes are only stored when given.
create function pg_temp.rep(p_person integer, p_bar bigint, p_at timestamptz,
                            p_line integer default null, p_busy integer default null,
                            p_wait integer default null, p_hidden boolean default false,
                            p_is_test boolean default false)
returns void
language sql as $$
  insert into app.reports (
    client_report_id, anon_id, install_id, bar_id, night_date, position, kind,
    line_size, line_size_state, busyness, busyness_state, recalled_wait, recalled_wait_state,
    phone_time, location_status, uncertain, hidden, hidden_reason,
    app_version, definitions_version, is_test)
  values (
    gen_random_uuid(), pg_temp.uid(p_person), pg_temp.uid(p_person), p_bar,
    app.night_date(p_at), 'inside', 'inside',
    p_line, case when p_line is not null then 'answered' end,
    p_busy, case when p_busy is not null then 'answered' end,
    p_wait, case when p_wait is not null then 'answered' end,
    p_at, 'denied', true, p_hidden, case when p_hidden then 'hidden in test' end,
    '1.0', 1, p_is_test)
$$;

-- A finished timed wait (I'm in).
create function pg_temp.measured(p_person integer, p_bar bigint, p_start timestamptz,
                                 p_end timestamptz, p_offset integer default 0,
                                 p_is_test boolean default false)
returns void
language sql as $$
  insert into app.wait_sessions (
    client_session_id, anon_id, install_id, bar_id, night_date, started_at,
    start_offset_minutes, ended_at, status, ended_by, is_test)
  values (
    gen_random_uuid(), pg_temp.uid(p_person), pg_temp.uid(p_person), p_bar,
    app.night_date(p_start), p_start, p_offset, p_end, 'entered', 'im_in', p_is_test)
$$;

create function pg_temp.sig(p_bar bigint, p_signal text, p_at timestamptz,
                            p_include_test boolean default false) returns jsonb
language sql stable as
$$ select app.pick_signal(p_bar, p_signal, p_at, p_include_test) $$;

-- One bar's entry from app.estimates.
create function pg_temp.est(p_bar bigint, p_at timestamptz, p_include_test boolean default false)
returns jsonb
language sql stable as $$
  select e
  from jsonb_array_elements(app.estimates(p_at, p_include_test) -> 'bars') as e
  where (e ->> 'bar_id')::bigint = p_bar
$$;

select pg_temp.new_bar(n) from unnest(array[
  'Fresh', 'People', 'Newest', 'One other', 'One far', 'Same person', 'Majority', 'Within one',
  'Two apart', 'Stale others', 'Busyness', 'Wait mix', 'Wait aging', 'Wait expired',
  'Rounding', 'Tie same person', 'Tie two people', 'Hidden', 'Test rows', 'Empty',
  'After 2 am', 'Weekday empty', 'Weekday stale', 'Weekday fresh', 'Crowd only',
  'Rank agree', 'Rank disagree', 'Rank votes', 'Rank cant see']) as n;
select pg_temp.new_bar('Test bar', true);

-- Freshness boundaries (FR-17) -----------------------------------------------------------
-- One line-size report at R = T - 60 min (10 p.m.), read at different times.

select pg_temp.rep(1, pg_temp.bar('Fresh'), pg_temp.ago(60), p_line => 2);

select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(30)) ->> 'freshness', 'fresh',
  'a report exactly 30 minutes old is fresh');
select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(30) + interval '1 second') ->> 'freshness', 'stale',
  'a report 30 minutes and 1 second old is stale');
select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(0)) ->> 'freshness', 'stale',
  'a report exactly 60 minutes old is still shown, as stale');
select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(0) + interval '1 second'), null::jsonb,
  'a report over 60 minutes old is not shown');
select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(61)), null::jsonb,
  'a report with a later phone time does not count yet');
select is(pg_temp.sig(pg_temp.bar('Fresh'), 'line_size', pg_temp.ago(30)) ->> 'code', '2',
  'the shown code is the reported code');

select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(30)) ->> 'display', 'estimate', 'fresh: display is estimate');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(30)) ->> 'freshness', 'fresh', 'fresh: bar freshness is fresh');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(30)) ->> 'people', '1', 'fresh: one person');
select is((pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(30)) ->> 'latest_at')::timestamptz, pg_temp.ago(60),
  'latest_at is the newest report time');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(15)) ->> 'display', 'estimate', 'stale: display is still estimate');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(15)) ->> 'freshness', 'stale', 'stale: bar freshness is stale');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(15)) -> 'line_size' ->> 'freshness', 'stale', 'stale: the line size is grayed out');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(-1)) ->> 'display', 'not_enough_data', 'over 60 minutes: not enough data');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(-1)) ->> 'freshness', 'none', 'over 60 minutes: freshness none');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(-1)) ->> 'people', '0', 'over 60 minutes: zero people');
select is(pg_temp.est(pg_temp.bar('Fresh'), pg_temp.ago(-1)) ->> 'line_size', null::text, 'over 60 minutes: no line size');

-- Distinct people (FR-18) -----------------------------------------------------------------

select pg_temp.rep(1, pg_temp.bar('People'), pg_temp.ago(20), p_line => 2);
select pg_temp.rep(1, pg_temp.bar('People'), pg_temp.ago(10), p_line => 2);
select pg_temp.rep(2, pg_temp.bar('People'), pg_temp.ago(5), p_line => 2);
select pg_temp.rep(3, pg_temp.bar('People'), pg_temp.ago(45), p_line => 2);

select is(pg_temp.est(pg_temp.bar('People'), pg_temp.ago(0)) ->> 'people', '2',
  'two fresh people reporting three times count as 2 (the stale one is not counted while fresh)');
select is((select count(*) from app.signal_people(pg_temp.bar('People'), 'line_size', pg_temp.ago(30), pg_temp.ago(0), false)),
  2::bigint, 'signal_people keeps one row per person');
select is(pg_temp.est(pg_temp.bar('People'), pg_temp.ago(-31)) ->> 'people', '2',
  'when only stale reports remain, stale people are counted once each');

-- Newest wins, majority exception (FR-19) -------------------------------------------------

select pg_temp.rep(1, pg_temp.bar('Newest'), pg_temp.ago(20), p_line => 1);
select pg_temp.rep(2, pg_temp.bar('Newest'), pg_temp.ago(5), p_line => 2);
select is(pg_temp.sig(pg_temp.bar('Newest'), 'line_size', pg_temp.ago(0)) ->> 'code', '2', 'the newest report wins');
select is(pg_temp.sig(pg_temp.bar('Newest'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'newest', 'rule is newest');

-- Only one other person disagrees: the newest still wins.
select pg_temp.rep(1, pg_temp.bar('One other'), pg_temp.ago(20), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('One other'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('One other'), 'line_size', pg_temp.ago(0)) ->> 'code', '1',
  'one disagreeing person is not enough for the majority rule');
select is(pg_temp.sig(pg_temp.bar('One other'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'newest', 'one other: rule is newest');

-- Nearby answers agree with the newest; only one person is more than one range
-- away, so the newest still wins even though its exact code has fewer votes.
select pg_temp.rep(1, pg_temp.bar('One far'), pg_temp.ago(25), p_line => 3);
select pg_temp.rep(2, pg_temp.bar('One far'), pg_temp.ago(20), p_line => 3);
select pg_temp.rep(3, pg_temp.bar('One far'), pg_temp.ago(15), p_line => 4);
select pg_temp.rep(4, pg_temp.bar('One far'), pg_temp.ago(5), p_line => 2);
select is(pg_temp.sig(pg_temp.bar('One far'), 'line_size', pg_temp.ago(0)) ->> 'code', '2',
  'only people more than one range away count as disagreeing');

-- One person reporting twice is still one disagreeing person.
select pg_temp.rep(1, pg_temp.bar('Same person'), pg_temp.ago(20), p_line => 4);
select pg_temp.rep(1, pg_temp.bar('Same person'), pg_temp.ago(15), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('Same person'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('Same person'), 'line_size', pg_temp.ago(0)) ->> 'code', '1',
  'two reports from one person count as one disagreeing person');

-- Two other fresh people disagree: the majority wins.
select pg_temp.rep(1, pg_temp.bar('Majority'), pg_temp.ago(20), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('Majority'), pg_temp.ago(15), p_line => 4);
select pg_temp.rep(3, pg_temp.bar('Majority'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('Majority'), 'line_size', pg_temp.ago(0)) ->> 'code', '4',
  'two disagreeing fresh people: the majority wins');
select is(pg_temp.sig(pg_temp.bar('Majority'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'majority', 'rule is majority');
select is((pg_temp.sig(pg_temp.bar('Majority'), 'line_size', pg_temp.ago(0)) ->> 'at')::timestamptz, pg_temp.ago(15),
  'the shown majority report is the newest one with the winning code');

-- "Agree" means within one range.
select pg_temp.rep(1, pg_temp.bar('Within one'), pg_temp.ago(20), p_line => 3);
select pg_temp.rep(2, pg_temp.bar('Within one'), pg_temp.ago(15), p_line => 3);
select pg_temp.rep(3, pg_temp.bar('Within one'), pg_temp.ago(5), p_line => 2);
select is(pg_temp.sig(pg_temp.bar('Within one'), 'line_size', pg_temp.ago(0)) ->> 'code', '2',
  'codes one apart agree, so the newest wins');
select is(pg_temp.sig(pg_temp.bar('Within one'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'newest', 'within one: rule is newest');

select pg_temp.rep(1, pg_temp.bar('Two apart'), pg_temp.ago(20), p_line => 3);
select pg_temp.rep(2, pg_temp.bar('Two apart'), pg_temp.ago(15), p_line => 3);
select pg_temp.rep(3, pg_temp.bar('Two apart'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('Two apart'), 'line_size', pg_temp.ago(0)) ->> 'code', '3',
  'codes two apart disagree, so the majority wins');

-- Stale reports from others do not trigger the majority rule.
select pg_temp.rep(1, pg_temp.bar('Stale others'), pg_temp.ago(45), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('Stale others'), pg_temp.ago(40), p_line => 4);
select pg_temp.rep(3, pg_temp.bar('Stale others'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('Stale others'), 'line_size', pg_temp.ago(0)) ->> 'code', '1',
  'disagreeing stale reports do not count for the majority');
select is(pg_temp.sig(pg_temp.bar('Stale others'), 'line_size', pg_temp.ago(0)) ->> 'freshness', 'fresh',
  'stale others: the newest is fresh');

-- Each signal is picked separately. Busyness (older rows only) is ignored
-- since logic version 4: the key stays for older builds, always null.
select pg_temp.rep(1, pg_temp.bar('Busyness'), pg_temp.ago(20), p_busy => 4);
select pg_temp.rep(2, pg_temp.bar('Busyness'), pg_temp.ago(15), p_busy => 4);
select pg_temp.rep(3, pg_temp.bar('Busyness'), pg_temp.ago(5), p_busy => 1, p_line => 1);
select is(pg_temp.est(pg_temp.bar('Busyness'), pg_temp.ago(0)) -> 'busyness', 'null'::jsonb,
  'busyness is never shown: the estimate''s busyness is null');
select ok(pg_temp.est(pg_temp.bar('Busyness'), pg_temp.ago(0)) ? 'busyness',
  'the busyness key is still there for older builds');
select is(pg_temp.sig(pg_temp.bar('Busyness'), 'line_size', pg_temp.ago(0)) ->> 'code', '1',
  'line size is picked separately from busyness');
select is(pg_temp.est(pg_temp.bar('Busyness'), pg_temp.ago(0)) ->> 'wait', null::text,
  'a signal nobody answered is null');

-- Line sizes compare by size rank (logic version 4) -------------------------------------------
-- Ranks: 0 nobody 0, 1-10 1, 10-25 2, 25-50 3, 50+ (4) / 50-100 (6) / can't
-- see the end (5) 4, 100+ (7) 5.

select is(array(select app.line_size_rank(c::smallint) from generate_series(0, 7) as c order by c),
  array[0, 1, 2, 3, 4, 4, 4, 5]::smallint[],
  'line_size_rank: 0-3 keep their code, 4, 5, and 6 are rank 4, 7 is rank 5');

-- 50+ and 50-100 are one rank from 100+: they agree, so the newest wins.
select pg_temp.rep(1, pg_temp.bar('Rank agree'), pg_temp.ago(20), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('Rank agree'), pg_temp.ago(15), p_line => 6);
select pg_temp.rep(3, pg_temp.bar('Rank agree'), pg_temp.ago(5), p_line => 7);
select is(pg_temp.sig(pg_temp.bar('Rank agree'), 'line_size', pg_temp.ago(0)) ->> 'code', '7',
  '50+ and 50-100 agree with 100+ (one rank apart): the newest wins');
select is(pg_temp.sig(pg_temp.bar('Rank agree'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'newest',
  'rank agree: rule is newest');

-- 25-50 is two ranks from 100+: they disagree, so the majority wins.
select pg_temp.rep(1, pg_temp.bar('Rank disagree'), pg_temp.ago(20), p_line => 3);
select pg_temp.rep(2, pg_temp.bar('Rank disagree'), pg_temp.ago(15), p_line => 3);
select pg_temp.rep(3, pg_temp.bar('Rank disagree'), pg_temp.ago(5), p_line => 7);
select is(pg_temp.sig(pg_temp.bar('Rank disagree'), 'line_size', pg_temp.ago(0)) ->> 'code', '3',
  '25-50 and 100+ disagree (two ranks apart): the majority wins');
select is(pg_temp.sig(pg_temp.bar('Rank disagree'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'majority',
  'rank disagree: rule is majority');

-- 50+ and 50-100 are the same rank, so they vote together.
select pg_temp.rep(1, pg_temp.bar('Rank votes'), pg_temp.ago(20), p_line => 4);
select pg_temp.rep(2, pg_temp.bar('Rank votes'), pg_temp.ago(15), p_line => 6);
select pg_temp.rep(3, pg_temp.bar('Rank votes'), pg_temp.ago(5), p_line => 1);
select is(pg_temp.sig(pg_temp.bar('Rank votes'), 'line_size', pg_temp.ago(0)) ->> 'code', '6',
  '50+ and 50-100 vote as one size; the newest of them is shown');
select is(pg_temp.sig(pg_temp.bar('Rank votes'), 'line_size', pg_temp.ago(0)) ->> 'rule', 'majority',
  'rank votes: rule is majority');

-- Can't see the end (5, reserved) ranks with 50+, one from 25-50.
select pg_temp.rep(1, pg_temp.bar('Rank cant see'), pg_temp.ago(20), p_line => 5);
select pg_temp.rep(2, pg_temp.bar('Rank cant see'), pg_temp.ago(15), p_line => 5);
select pg_temp.rep(3, pg_temp.bar('Rank cant see'), pg_temp.ago(5), p_line => 3);
select is(pg_temp.sig(pg_temp.bar('Rank cant see'), 'line_size', pg_temp.ago(0)) ->> 'code', '3',
  'can''t see the end agrees with 25-50 (one rank apart): the newest wins');

-- Waits: measured and recalled in one signal ------------------------------------------------

-- Measured: 30 min in line plus "been here ~5 min" = 35 min, ended at T-10.
select pg_temp.measured(1, pg_temp.bar('Wait mix'), pg_temp.ago(40), pg_temp.ago(10), 5);
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'source', 'measured', 'a measured wait is a wait signal');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'minutes', '35', 'measured minutes include the start offset');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'code', '4', '35 minutes is range code 4 (30-60)');
select is((pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'at')::timestamptz, pg_temp.ago(10),
  'a measured wait is timed from when the person got in');

-- A newer recalled range from someone else wins (only one disagreeing person).
select pg_temp.rep(2, pg_temp.bar('Wait mix'), pg_temp.ago(5), p_wait => 1);
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'source', 'reported', 'a newer recalled range wins');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'code', '1', 'the recalled code is shown');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'minutes', null::text, 'a recalled range has no minutes');

-- A second person agreeing with the measured wait makes a majority.
select pg_temp.rep(3, pg_temp.bar('Wait mix'), pg_temp.ago(15), p_wait => 4);
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'rule', 'majority',
  'measured and recalled waits vote together');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'source', 'measured',
  'the majority shows its newest report, here the measured wait');
select is(pg_temp.sig(pg_temp.bar('Wait mix'), 'wait', pg_temp.ago(0)) ->> 'minutes', '35',
  'the majority shows the measured minutes');

-- A long wait that ended 40 minutes ago is stale, not gone.
select pg_temp.measured(1, pg_temp.bar('Wait aging'), pg_temp.ago(150), pg_temp.ago(40));
select is(pg_temp.sig(pg_temp.bar('Wait aging'), 'wait', pg_temp.ago(0)) ->> 'freshness', 'stale',
  'a measured wait ages from its end, not its start');
select is(pg_temp.sig(pg_temp.bar('Wait aging'), 'wait', pg_temp.ago(0)) ->> 'code', '5', '110 minutes is range code 5 (60+)');
select is(pg_temp.est(pg_temp.bar('Wait aging'), pg_temp.ago(0)) ->> 'people', '1', 'a finished wait counts as a person');
select is(pg_temp.est(pg_temp.bar('Wait aging'), pg_temp.ago(0)) ->> 'display', 'estimate',
  'a wait alone is enough for an estimate');

select pg_temp.measured(1, pg_temp.bar('Wait expired'), pg_temp.ago(80), pg_temp.ago(61));
select is(pg_temp.sig(pg_temp.bar('Wait expired'), 'wait', pg_temp.ago(0)), null::jsonb,
  'a measured wait that ended over 60 minutes ago is not shown');

-- Minutes are rounded: 25 min 31 s shows as 26.
select pg_temp.measured(1, pg_temp.bar('Rounding'), pg_temp.ago(40), pg_temp.ago(40) + interval '25 minutes 31 seconds');
select is((select s.measured_wait_seconds from app.wait_sessions s where s.bar_id = pg_temp.bar('Rounding')), 1531,
  'measured_wait_seconds is end minus start');
select is(pg_temp.sig(pg_temp.bar('Rounding'), 'wait', pg_temp.ago(0)) ->> 'minutes', '26', 'measured minutes are rounded');

-- At the exact same time, a measured wait beats a recalled range.
select pg_temp.measured(1, pg_temp.bar('Tie same person'), pg_temp.ago(30), pg_temp.ago(10));
select pg_temp.rep(1, pg_temp.bar('Tie same person'), pg_temp.ago(10), p_wait => 1);
select is(pg_temp.sig(pg_temp.bar('Tie same person'), 'wait', pg_temp.ago(0)) ->> 'source', 'measured',
  'same person, same time: the measured wait wins');
select is(pg_temp.sig(pg_temp.bar('Tie same person'), 'wait', pg_temp.ago(0)) ->> 'code', '3', 'tie: 20 minutes is code 3');

select pg_temp.measured(1, pg_temp.bar('Tie two people'), pg_temp.ago(30), pg_temp.ago(10));
select pg_temp.rep(2, pg_temp.bar('Tie two people'), pg_temp.ago(10), p_wait => 1);
select is(pg_temp.sig(pg_temp.bar('Tie two people'), 'wait', pg_temp.ago(0)) ->> 'source', 'measured',
  'two people, same time: the measured wait is the newest');

-- Hidden and test rows ------------------------------------------------------------------

select pg_temp.rep(1, pg_temp.bar('Hidden'), pg_temp.ago(5), p_line => 1, p_hidden => true);
select pg_temp.rep(2, pg_temp.bar('Hidden'), pg_temp.ago(20), p_line => 3);
select is(pg_temp.sig(pg_temp.bar('Hidden'), 'line_size', pg_temp.ago(0)) ->> 'code', '3', 'hidden reports never count');
select is(pg_temp.est(pg_temp.bar('Hidden'), pg_temp.ago(0)) ->> 'people', '1', 'hidden reports do not count as people');
select is((pg_temp.est(pg_temp.bar('Hidden'), pg_temp.ago(0)) ->> 'latest_at')::timestamptz, pg_temp.ago(20),
  'hidden reports do not set latest_at');

select pg_temp.rep(1, pg_temp.bar('Test rows'), pg_temp.ago(5), p_line => 1, p_is_test => true);
select pg_temp.rep(2, pg_temp.bar('Test rows'), pg_temp.ago(20), p_line => 3);
select pg_temp.measured(3, pg_temp.bar('Test rows'), pg_temp.ago(30), pg_temp.ago(2), p_is_test => true);
select is(pg_temp.sig(pg_temp.bar('Test rows'), 'line_size', pg_temp.ago(0)) ->> 'code', '3', 'test reports are excluded by default');
select is(pg_temp.sig(pg_temp.bar('Test rows'), 'line_size', pg_temp.ago(0), true) ->> 'code', '1', 'test reports count with include_test');
select is(pg_temp.sig(pg_temp.bar('Test rows'), 'wait', pg_temp.ago(0)), null::jsonb, 'test waits are excluded by default');
select is(pg_temp.sig(pg_temp.bar('Test rows'), 'wait', pg_temp.ago(0), true) ->> 'source', 'measured', 'test waits count with include_test');
select is(pg_temp.est(pg_temp.bar('Test rows'), pg_temp.ago(0)) ->> 'people', '1', 'test rows are not counted as people');
select is(pg_temp.est(pg_temp.bar('Test rows'), pg_temp.ago(0), true) ->> 'people', '3', 'with include_test, test people count');

select is(pg_temp.est(pg_temp.bar('Test bar'), pg_temp.ago(0)), null::jsonb, 'test bars are left out of estimates');
select isnt(pg_temp.est(pg_temp.bar('Test bar'), pg_temp.ago(0), true), null::jsonb, 'test bars are included with include_test');

-- Display states -------------------------------------------------------------------------

select is(pg_temp.est(pg_temp.bar('Empty'), pg_temp.ago(0)) ->> 'display', 'not_enough_data',
  'no reports: not enough data');

-- A crowd answer alone (older rows) is not an estimate: display needs a line
-- size or a wait (logic version 4).
select pg_temp.rep(1, pg_temp.bar('Crowd only'), pg_temp.ago(5), p_busy => 3);
select is(pg_temp.est(pg_temp.bar('Crowd only'), pg_temp.ago(0)) ->> 'display', 'not_enough_data',
  'only a crowd answer: not enough data');
select is(pg_temp.est(pg_temp.bar('Crowd only'), pg_temp.ago(0)) -> 'busyness', 'null'::jsonb,
  'only a crowd answer: busyness is still null');

-- Saturday 2:30 a.m., after Friday night: was "Closed" before logic version 3.
-- Now a fresh report shows like at any other hour.
select pg_temp.rep(1, pg_temp.bar('After 2 am'), '2026-10-03 02:25 America/New_York', p_line => 2);
select is(app.estimates('2026-10-03 02:30 America/New_York', false) ->> 'window_state', 'live',
  'Saturday 2:30 a.m. is live (window_state is always live)');
select is(pg_temp.est(pg_temp.bar('After 2 am'), '2026-10-03 02:30 America/New_York') ->> 'freshness', 'fresh',
  'the 2:25 a.m. report is fresh at 2:30 a.m.');
select is(pg_temp.est(pg_temp.bar('After 2 am'), '2026-10-03 02:30 America/New_York') ->> 'display', 'estimate',
  'no more closed: a fresh report at 2:30 a.m. after a Friday night shows');

-- Monday 8 p.m. used to be outside hours. The live rule applies at every hour:
-- anything within 60 minutes shows, stale grayed out.
select pg_temp.rep(1, pg_temp.bar('Weekday stale'), '2026-10-05 19:15 America/New_York', p_line => 2);
select pg_temp.rep(1, pg_temp.bar('Weekday fresh'), '2026-10-05 19:50 America/New_York', p_line => 2);
select is(app.estimates('2026-10-05 20:00 America/New_York', false) ->> 'window_state', 'live',
  'Monday 8 p.m. is live (window_state is always live)');
select is(pg_temp.est(pg_temp.bar('Weekday empty'), '2026-10-05 20:00 America/New_York') ->> 'display', 'not_enough_data',
  'Monday 8 p.m. with no reports: not enough data');
select is(pg_temp.est(pg_temp.bar('Weekday stale'), '2026-10-05 20:00 America/New_York') ->> 'display', 'estimate',
  'Monday 8 p.m. with a 45-minute-old report: estimate');
select is(pg_temp.est(pg_temp.bar('Weekday stale'), '2026-10-05 20:00 America/New_York') ->> 'freshness', 'stale',
  'Monday 8 p.m. with a 45-minute-old report: bar freshness is stale');
select is(pg_temp.est(pg_temp.bar('Weekday stale'), '2026-10-05 20:00 America/New_York') -> 'line_size' ->> 'freshness', 'stale',
  'Monday 8 p.m. with a 45-minute-old report: the line size is grayed out');
select is(pg_temp.est(pg_temp.bar('Weekday stale'), '2026-10-05 20:16 America/New_York') ->> 'display', 'not_enough_data',
  'Monday 8:16 p.m. with only a 61-minute-old report: not enough data');
select is(pg_temp.est(pg_temp.bar('Weekday fresh'), '2026-10-05 20:00 America/New_York') ->> 'display', 'estimate',
  'Monday 8 p.m. with a fresh report: estimate');
select is(
  (select count(*) from jsonb_array_elements(app.estimates('2026-10-05 20:00 America/New_York', false) -> 'bars') as e
   where e ->> 'display' not in ('estimate', 'not_enough_data')),
  0::bigint, 'display is only ever estimate or not_enough_data (no closed, no outside_hours)');

-- Response shape (FR-21) ----------------------------------------------------------------

select is((app.estimates(pg_temp.ago(0), false) ->> 'logic_version')::integer, app.logic_version(),
  'estimates carry the logic version');
select is((app.estimates('2026-10-05 20:00 America/New_York', false) ->> 'logic_version')::integer, 4,
  'the estimates response says logic version 4');
select is(app.logic_version(), 4, 'logic version is 4');
select is(app.estimates(pg_temp.ago(0), false) ->> 'window_state', 'live', 'Friday 11 p.m. is live');
select is((app.estimates(pg_temp.ago(0), false) ->> 'generated_at')::timestamptz, pg_temp.ago(0), 'generated_at is the time asked for');
select is(jsonb_array_length(app.estimates(pg_temp.ago(0), false) -> 'bars'), 35,
  'every active non-test bar is listed (6 real bars + 29 test scenarios)');
select is(app.estimates(pg_temp.ago(0), false) -> 'bars' -> 0 ->> 'bar_id',
  (select b.id::text from app.bars b where b.name = 'Primanti Bros.'),
  'bars are listed in display order');

select * from finish();
rollback;
