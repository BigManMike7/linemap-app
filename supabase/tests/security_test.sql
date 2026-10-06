-- Security model (NFR-5) and no stored coordinates (FR-26).
-- The app reaches data only through the 16 API functions in PRD 7.2; every
-- table is private, has RLS on, and no role but the owner can touch it.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

select plan(70);

-- Schema and table lockdown ----------------------------------------------------

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'app' and c.relkind = 'r'),
  13::bigint,
  'app has 13 tables: the 12 from PRD 7.3 and rate_limit_holds (FR-41)');

select is(
  (select array_agg(c.relname::text order by c.relname::text)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'app' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  null::text[],
  'every app table has row-level security enabled');

select is(
  (select count(*) from pg_policies where schemaname = 'app'),
  0::bigint,
  'no RLS policies exist, so direct access is always denied');

select ok(not has_schema_privilege('anon', 'app', 'usage'), 'anon has no usage on schema app');
select ok(not has_schema_privilege('authenticated', 'app', 'usage'), 'authenticated has no usage on schema app');

select is(
  (select array_agg(x order by x) from (
     select r.rolname || ':' || c.relname::text || ':' || p.priv as x
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'), ('authenticated')) as r (rolname)
     cross join (values ('select'), ('insert'), ('update'), ('delete'),
                        ('truncate'), ('references'), ('trigger')) as p (priv)
     where n.nspname = 'app' and c.relkind = 'r'
       and has_table_privilege(r.rolname, c.oid, p.priv)) g),
  null::text[],
  'anon and authenticated hold no privilege on any app table');

select is(
  (select array_agg(x order by x) from (
     select p.oid::regprocedure::text as x
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute'))) g),
  null::text[],
  'anon and authenticated cannot execute any app function');

-- The public API ------------------------------------------------------------------

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('get_bars', 'get_estimates', 'submit_report', 'start_session',
                       'update_line_size', 'end_session', 'send_feedback',
                       'register_install', 'log_view', 'delete_my_data', 'cancel_session',
                       'report_conditions', 'my_recent_reports', 'delete_report',
                       'reopen_session', 'bar_history')),
  16::bigint,
  'each of the 16 API functions exists exactly once (no overloads)');

-- Functions created by the migrations' owner in public that anon can run.
select set_eq(
  $$select p.proname::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proowner = (select q.proowner from pg_proc q where q.oid = 'public.get_bars(uuid)'::regprocedure)
      and has_function_privilege('anon', p.oid, 'execute')$$,
  array['get_bars', 'get_estimates', 'submit_report', 'start_session', 'update_line_size',
        'end_session', 'send_feedback', 'register_install', 'log_view', 'delete_my_data',
        'cancel_session', 'report_conditions', 'my_recent_reports', 'delete_report',
        'reopen_session', 'bar_history'],
  'anon can execute exactly the 16 API functions');

select is(
  (select array_agg(p.proname::text order by p.proname::text)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('get_bars', 'get_estimates', 'submit_report', 'start_session',
                       'update_line_size', 'end_session', 'send_feedback',
                       'register_install', 'log_view', 'delete_my_data', 'cancel_session',
                       'report_conditions', 'my_recent_reports', 'delete_report',
                       'reopen_session', 'bar_history')
     and has_function_privilege('authenticated', p.oid, 'execute')),
  null::text[],
  'authenticated cannot execute any API function');

select is(
  (select array_agg(p.proname::text order by p.proname::text)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('get_bars', 'get_estimates', 'submit_report', 'start_session',
                       'update_line_size', 'end_session', 'send_feedback',
                       'register_install', 'log_view', 'delete_my_data', 'cancel_session',
                       'report_conditions', 'my_recent_reports', 'delete_report',
                       'reopen_session', 'bar_history')
     and not p.prosecdef),
  null::text[],
  'every API function is SECURITY DEFINER');

select is(
  (select array_agg(p.proname::text order by p.proname::text)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('get_bars', 'get_estimates', 'submit_report', 'start_session',
                       'update_line_size', 'end_session', 'send_feedback',
                       'register_install', 'log_view', 'delete_my_data', 'cancel_session',
                       'report_conditions', 'my_recent_reports', 'delete_report',
                       'reopen_session', 'bar_history')
     and not (coalesce(p.proconfig, '{}'::text[])
              && array['search_path=""', 'search_path=', $q$search_path=''$q$])),
  null::text[],
  'every API function pins search_path to an empty string');

select ok(
  (select bool_and(p.prosecdef
                   and coalesce(p.proconfig, '{}'::text[])
                       && array['search_path=""', 'search_path=', $q$search_path=''$q$])
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'report_conditions'),
  'report_conditions is SECURITY DEFINER with an empty search_path');

select ok(
  (select count(*) = 2
          and bool_and(p.prosecdef
                       and coalesce(p.proconfig, '{}'::text[])
                           && array['search_path=""', 'search_path=', $q$search_path=''$q$])
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('my_recent_reports', 'delete_report')),
  'my_recent_reports and delete_report are SECURITY DEFINER with an empty search_path');

-- No coordinates are stored (FR-26) -------------------------------------------------

select is(
  (select array_agg(x order by x) from (
     select c.relname::text || '.' || a.attname::text as x
     from pg_attribute a
     join pg_class c on c.oid = a.attrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'app'
       and c.relname in ('reports', 'wait_sessions', 'views', 'feedback', 'installs', 'deletions',
                         'rate_limit_holds')
       and a.attnum > 0 and not a.attisdropped
       and a.attname::text ~ '(^|_)(lat|lon|lng|latitude|longitude|coord|coords|coordinates)(_|$)') g),
  null::text[],
  'reports, wait_sessions, views, feedback, installs, deletions, and rate_limit_holds have no coordinate columns');

-- Behavior as anon: direct access fails --------------------------------------------

set local role anon;

select throws_ok('select * from app.bars', '42501', null, 'anon cannot select app.bars');
select throws_ok('select * from app.installs', '42501', null, 'anon cannot select app.installs');
select throws_ok('select * from app.wait_sessions', '42501', null, 'anon cannot select app.wait_sessions');
select throws_ok('select * from app.reports', '42501', null, 'anon cannot select app.reports');
select throws_ok('select * from app.views', '42501', null, 'anon cannot select app.views');
select throws_ok('select * from app.feedback', '42501', null, 'anon cannot select app.feedback');
select throws_ok('select * from app.config', '42501', null, 'anon cannot select app.config');
select throws_ok('select * from app.config_history', '42501', null, 'anon cannot select app.config_history');
select throws_ok('select * from app.event_nights', '42501', null, 'anon cannot select app.event_nights');
select throws_ok('select * from app.estimate_snapshots', '42501', null, 'anon cannot select app.estimate_snapshots');
select throws_ok('select * from app.spot_checks', '42501', null, 'anon cannot select app.spot_checks');
select throws_ok('select * from app.deletions', '42501', null, 'anon cannot select app.deletions');
select throws_ok('select * from app.rate_limit_holds', '42501', null, 'anon cannot select app.rate_limit_holds');

select throws_ok('insert into app.bars default values', '42501', null, 'anon cannot insert into app.bars');
select throws_ok('insert into app.installs default values', '42501', null, 'anon cannot insert into app.installs');
select throws_ok('insert into app.wait_sessions default values', '42501', null, 'anon cannot insert into app.wait_sessions');
select throws_ok('insert into app.reports default values', '42501', null, 'anon cannot insert into app.reports');
select throws_ok('insert into app.views default values', '42501', null, 'anon cannot insert into app.views');
select throws_ok('insert into app.feedback default values', '42501', null, 'anon cannot insert into app.feedback');
select throws_ok('insert into app.config default values', '42501', null, 'anon cannot insert into app.config');
select throws_ok('insert into app.config_history default values', '42501', null, 'anon cannot insert into app.config_history');
select throws_ok('insert into app.event_nights default values', '42501', null, 'anon cannot insert into app.event_nights');
select throws_ok('insert into app.estimate_snapshots default values', '42501', null, 'anon cannot insert into app.estimate_snapshots');
select throws_ok('insert into app.spot_checks default values', '42501', null, 'anon cannot insert into app.spot_checks');
select throws_ok('insert into app.deletions default values', '42501', null, 'anon cannot insert into app.deletions');
select throws_ok('insert into app.rate_limit_holds default values', '42501', null, 'anon cannot insert into app.rate_limit_holds');

select throws_ok('update app.config set value = ''1''', '42501', null, 'anon cannot update app.config');
select throws_ok('delete from app.reports', '42501', null, 'anon cannot delete from app.reports');

select throws_ok('select app.estimates(now(), true)', '42501', null, 'anon cannot call app.estimates');
select throws_ok($$select app.setting('fresh_minutes')$$, '42501', null, 'anon cannot call app.setting');
select throws_ok('select app.expire_sessions()', '42501', null, 'anon cannot call app.expire_sessions');
select throws_ok('select app.purge_old_data()', '42501', null, 'anon cannot call app.purge_old_data');
select throws_ok('select app.take_snapshots()', '42501', null, 'anon cannot call app.take_snapshots');
select throws_ok('select app.expire_rate_limit_holds()', '42501', null, 'anon cannot call app.expire_rate_limit_holds');

-- Behavior as anon: the API works -------------------------------------------------

select lives_ok('select public.get_bars()', 'anon can call get_bars');
select is(jsonb_array_length(public.get_bars()), 3, 'anon sees the 3 starting bars');
select lives_ok('select public.get_estimates()', 'anon can call get_estimates');
select is((public.get_estimates() ->> 'logic_version')::integer, 2, 'get_estimates carries the logic version (FR-21)');
select lives_ok(
  $$select public.register_install('5ec00000-0000-4000-8000-000000000001',
                                   '5ec00000-0000-4000-8000-000000000002',
                                   '1.0', '18.0', 'iPhone16,1')$$,
  'anon can call register_install');
select lives_ok(
  $$select public.report_conditions(
      p_client_report_id    => '5ec00000-0000-4000-8000-000000000003',
      p_anon_id             => '5ec00000-0000-4000-8000-000000000001',
      p_install_id          => '5ec00000-0000-4000-8000-000000000002',
      p_bar_id              => (public.get_bars() -> 0 ->> 'id')::bigint,
      p_phone_time          => now(),
      p_location_status     => 'denied',
      p_app_version         => '1.0',
      p_definitions_version => 1::smallint,
      p_busyness            => 2::smallint,
      p_busyness_state      => 'answered')$$,
  'anon can call report_conditions');
select is(
  jsonb_array_length(public.my_recent_reports('5ec00000-0000-4000-8000-000000000001')), 1,
  'anon can call my_recent_reports and sees its own report');
select is(
  public.delete_report(p_anon_id => '5ec00000-0000-4000-8000-000000000001',
                       p_client_report_id => '5ec00000-0000-4000-8000-000000000099') ->> 'error',
  'not_found',
  'anon can call delete_report');
select is(
  public.reopen_session('5ec00000-0000-4000-8000-000000000098', '5ec00000-0000-4000-8000-000000000001'),
  '{"ok": true, "reopened": false, "removed": true}'::jsonb,
  'anon can call reopen_session');
select is(
  (public.bar_history(p_bar_id => (public.get_bars() -> 0 ->> 'id')::bigint) ->> 'logic_version')::integer, 2,
  'anon can call bar_history');

reset role;

select is(
  (select count(*) from app.installs where anon_id = '5ec00000-0000-4000-8000-000000000001'),
  1::bigint,
  'the install written through the API as anon was saved');
select is(
  (select count(*) from app.reports
   where anon_id = '5ec00000-0000-4000-8000-000000000001' and kind = 'conditions'),
  1::bigint,
  'the conditions report written through the API as anon was saved');

-- Behavior as authenticated: no API access -------------------------------------------

set local role authenticated;

select throws_ok('select public.get_bars()', '42501', null, 'authenticated cannot call get_bars');
select throws_ok('select public.get_estimates()', '42501', null, 'authenticated cannot call get_estimates');
select throws_ok(
  $$select public.delete_my_data('5ec00000-0000-4000-8000-000000000001')$$,
  '42501', null, 'authenticated cannot call delete_my_data');
select throws_ok(
  $$select public.report_conditions(
      p_client_report_id    => '5ec00000-0000-4000-8000-000000000004',
      p_anon_id             => '5ec00000-0000-4000-8000-000000000001',
      p_install_id          => '5ec00000-0000-4000-8000-000000000002',
      p_bar_id              => 1,
      p_phone_time          => now(),
      p_location_status     => 'denied',
      p_app_version         => '1.0',
      p_definitions_version => 1::smallint,
      p_busyness            => 2::smallint,
      p_busyness_state      => 'answered')$$,
  '42501', null, 'authenticated cannot call report_conditions');
select throws_ok(
  $$select public.my_recent_reports('5ec00000-0000-4000-8000-000000000001')$$,
  '42501', null, 'authenticated cannot call my_recent_reports');
select throws_ok(
  $$select public.delete_report(p_anon_id => '5ec00000-0000-4000-8000-000000000001',
                                p_client_report_id => '5ec00000-0000-4000-8000-000000000003')$$,
  '42501', null, 'authenticated cannot call delete_report');
select throws_ok(
  $$select public.reopen_session('5ec00000-0000-4000-8000-000000000098', '5ec00000-0000-4000-8000-000000000001')$$,
  '42501', null, 'authenticated cannot call reopen_session');
select throws_ok(
  $$select public.bar_history(p_bar_id => 1)$$,
  '42501', null, 'authenticated cannot call bar_history');
select throws_ok('select * from app.reports', '42501', null, 'authenticated cannot select app.reports');

reset role;

select * from finish();
rollback;
