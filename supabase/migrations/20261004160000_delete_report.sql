-- Made a wrong report? (FR-41, approved 2026-10-04).
--
-- In Settings, a person sees their own reports from the last 24 hours and can
-- delete any one of them. The delete is real: the rows are gone, so they stop
-- counting in estimates right away. Two things stay behind, neither with a
-- report or session ID:
--   1. A rate-limit hold: the bar and phone time of each counted report that
--      was deleted, so the 10-minute limit keeps running (FR-13) and
--      delete-and-re-report cannot be used to spam. Holds expire on their own
--      once they are older than the limit (every-5-minutes job below).
--   2. A line in app.deletions with scope 'one' and the number of rows
--      removed, like Delete my data (FR-32).
--
-- Data model changes:
--   - New table app.rate_limit_holds.
--   - New column app.deletions.scope: 'all' (Delete my data, and the
--     retention job) or 'one' (a single report or wait deleted here).
--     Existing rows become 'all'.
--   - New index on app.wait_sessions (anon_id, started_at) for the list.
--   - app.rate_limit_wait and public.delete_my_data are redefined to include
--     holds.
-- No answer code, report kind, or position changes meaning.

-- Rate-limit holds -------------------------------------------------------------------

create table app.rate_limit_holds (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  is_test    boolean not null default false,
  anon_id    uuid not null,
  bar_id     bigint not null references app.bars (id),
  -- Phone time of the deleted report, capped at server time (as stored).
  phone_time timestamptz not null
);

comment on table app.rate_limit_holds is
  'Bar and phone time of each counted report deleted with delete_report (FR-41), so the rate limit (FR-13) keeps running from it. Expired every 5 minutes once older than rate_limit_minutes.';

-- The rate-limit lookup, and Delete my data, go by person and bar.
create index rate_limit_holds_anon_bar_time on app.rate_limit_holds (anon_id, bar_id, phone_time);

alter table app.rate_limit_holds enable row level security;
revoke all on table app.rate_limit_holds from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;

-- Deletions: a full delete or a single report ----------------------------------------

alter table app.deletions
  add column scope text not null default 'all'
    constraint deletions_scope_check check (scope in ('all', 'one'));

comment on column app.deletions.scope is
  'all = Delete my data (FR-32) or the retention job (FR-33); one = a single report or wait deleted from Settings (FR-41). Never holds an ID.';

-- The list of a person's recent waits goes by person and start time.
create index wait_sessions_anon_started on app.wait_sessions (anon_id, started_at desc);

-- How far back a person can see and delete their own reports (FR-41).
create function app.recent_reports_window()
returns interval
language sql
immutable
security invoker
set search_path = ''
as $$ select interval '24 hours' $$;

-- Rate limit (FR-13) ---------------------------------------------------------------
-- One counted report (line_start, inside, or conditions) per bar per
-- rate_limit_minutes per person, by phone time. A hold left by a deleted
-- counted report (FR-41) counts exactly like the report did. Returns seconds
-- to wait, or 0.

create or replace function app.rate_limit_wait(p_anon_id uuid, p_bar_id bigint, p_at timestamptz)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(max(ceil(extract(epoch from
           app.setting_minutes('rate_limit_minutes') - abs_gap))::integer), 0)
  from (
    select case when t.phone_time > p_at then t.phone_time - p_at
                else p_at - t.phone_time end as abs_gap
    from (
      select r.phone_time
      from app.reports r
      where r.anon_id = p_anon_id
        and r.bar_id = p_bar_id
        and r.kind in ('line_start', 'inside', 'conditions')
      union all
      select h.phone_time
      from app.rate_limit_holds h
      where h.anon_id = p_anon_id
        and h.bar_id = p_bar_id
    ) t
  ) g
  where g.abs_gap < app.setting_minutes('rate_limit_minutes')
$$;

-- Expiring holds ---------------------------------------------------------------------
-- A hold older than the rate limit can no longer block anything, so it goes.
-- Runs every 5 minutes as its own job. Not logged in app.deletions: holds are
-- not something the person removed, and they live minutes, not days, so the
-- daily retention job (FR-33) never needs to look at them.

create function app.expire_rate_limit_holds(p_at timestamptz default now())
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  n integer;
begin
  delete from app.rate_limit_holds h
  where h.phone_time < p_at - app.setting_minutes('rate_limit_minutes');
  get diagnostics n = row_count;
  return n;
end;
$$;

-- cron.schedule replaces a job with the same name, so this is safe to re-run.
select cron.schedule('expire-rate-limit-holds', '*/5 * * * *', 'select app.expire_rate_limit_holds()');

-- my_recent_reports (FR-41) ------------------------------------------------------------
-- The person's own reports from the last 24 hours (by server time, against the
-- stored phone time), newest first, at most 100. Hidden reports are listed
-- too: they are the person's own. Two kinds of item:
--   report  a standalone Report conditions or I'm inside (no wait session)
--   wait    a finished wait (entered, gave_up, or unfinished), with its line
--           size and busyness answers. Open waits are not listed; the wait
--           card cancels those (FR-39).
-- Answer fields hold the code when answered, else null.

create function public.my_recent_reports(p_anon_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - app.recent_reports_window();
  items  jsonb;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;

  select coalesce(jsonb_agg(i.item order by i.item_at desc, i.item_type, i.item_id desc), '[]'::jsonb)
  into items
  from (
    select u.item, u.item_at, u.item_type, u.item_id
    from (
      select jsonb_build_object(
               'type', 'report',
               'kind', r.kind,
               'client_report_id', r.client_report_id,
               'bar_id', r.bar_id,
               'at', r.phone_time,
               'line_size', r.line_size,
               'busyness', r.busyness,
               'recalled_wait', r.recalled_wait
             ) as item,
             r.phone_time as item_at,
             'report'::text as item_type,
             r.id as item_id
      from app.reports r
      where r.anon_id = p_anon_id
        and r.wait_session_id is null
        and r.phone_time >= cutoff
      union all
      select jsonb_build_object(
               'type', 'wait',
               'client_session_id', s.client_session_id,
               'bar_id', s.bar_id,
               'at', s.started_at,
               'ended_at', s.ended_at,
               'status', s.status,
               'measured_wait_seconds', s.measured_wait_seconds,
               'start_offset_minutes', s.start_offset_minutes,
               -- The newest answered line size in the wait.
               'line_size', (select r.line_size
                             from app.reports r
                             where r.wait_session_id = s.id
                               and r.kind in ('line_start', 'line_update')
                               and r.line_size is not null
                             order by r.phone_time desc, r.id desc
                             limit 1),
               -- The busyness answer after I'm in.
               'busyness', (select r.busyness
                            from app.reports r
                            where r.wait_session_id = s.id
                              and r.kind = 'inside_after_entry'
                              and r.busyness is not null
                            order by r.phone_time desc, r.id desc
                            limit 1)
             ),
             s.started_at,
             'wait'::text,
             s.id
      from app.wait_sessions s
      where s.anon_id = p_anon_id
        and s.status <> 'open'
        and s.started_at >= cutoff
    ) u
    order by u.item_at desc, u.item_type, u.item_id desc
    limit 100
  ) i;

  return items;
end;
$$;

-- delete_report (FR-41) ----------------------------------------------------------------
-- Deletes one item from my_recent_reports: pass exactly one of
--   p_client_report_id   a standalone report (Report conditions or I'm inside)
--   p_client_session_id  a finished wait, with every report in it
-- Only the person's own, from the last 24 hours. Anything else, including a
-- second delete of the same item, is not_found, which never says whether the
-- item exists for someone else. An open wait returns session_open; the wait
-- card cancels it instead (FR-39).
-- Each counted report deleted leaves a rate-limit hold. The deletion is logged
-- as a count with scope 'one', never an ID.

create function public.delete_report(
  p_anon_id           uuid,
  p_client_report_id  uuid default null,
  p_client_session_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - app.recent_reports_window();
  r      app.reports%rowtype;
  s      app.wait_sessions%rowtype;
  n      integer;
  total  integer := 0;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  if (p_client_report_id is null) = (p_client_session_id is null) then
    perform app.bad_input('send exactly one of client_report_id and client_session_id');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));

  if p_client_report_id is not null then
    -- A report inside a wait is deleted with its wait, never on its own.
    select * into r from app.reports x
    where x.client_report_id = p_client_report_id
      and x.anon_id = p_anon_id
      and x.wait_session_id is null
      and x.phone_time >= cutoff;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;

    -- Keep the rate limit running from the deleted report (FR-13).
    insert into app.rate_limit_holds (anon_id, bar_id, phone_time, is_test)
    select x.anon_id, x.bar_id, x.phone_time, x.is_test
    from app.reports x
    where x.id = r.id
      and x.kind in ('line_start', 'inside', 'conditions');

    delete from app.reports x where x.id = r.id;
    get diagnostics n = row_count; total := total + n;
  else
    -- A wait past the timeout is unfinished, not open (FR-10).
    perform app.expire_session_if_due(p_anon_id, now());

    select * into s from app.wait_sessions ws
    where ws.client_session_id = p_client_session_id
      and ws.anon_id = p_anon_id
      and ws.started_at >= cutoff;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    if s.status = 'open' then
      return jsonb_build_object('ok', false, 'error', 'session_open');
    end if;

    -- Keep the rate limit running from the wait's I'm in line (FR-13).
    insert into app.rate_limit_holds (anon_id, bar_id, phone_time, is_test)
    select x.anon_id, x.bar_id, x.phone_time, x.is_test
    from app.reports x
    where x.wait_session_id = s.id
      and x.kind in ('line_start', 'inside', 'conditions');

    -- Reports first: they reference the session.
    delete from app.reports x where x.wait_session_id = s.id;
    get diagnostics n = row_count; total := total + n;
    delete from app.wait_sessions ws where ws.id = s.id;
    get diagnostics n = row_count; total := total + n;
  end if;

  insert into app.deletions (reason, scope, rows_removed, is_test)
  values ('user_request', 'one', total, app.is_test_anon(p_anon_id));

  return jsonb_build_object('ok', true, 'rows_removed', total);
end;
$$;

-- delete_my_data (FR-32) ---------------------------------------------------------
-- Deletes everything tied to the ID, now including rate-limit holds, and
-- records only a count. The app then makes a new anonymous ID.

create or replace function public.delete_my_data(p_anon_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n     integer;
  total integer := 0;
  test  boolean;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));
  test := app.is_test_anon(p_anon_id);

  delete from app.reports where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.wait_sessions where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.views where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.feedback where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.installs where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;
  delete from app.rate_limit_holds where anon_id = p_anon_id;
  get diagnostics n = row_count; total := total + n;

  insert into app.deletions (reason, scope, rows_removed, is_test)
  values ('user_request', 'all', total, test);

  return jsonb_build_object('ok', true, 'rows_removed', total);
end;
$$;

-- Grants ----------------------------------------------------------------------------
-- New app functions get EXECUTE for PUBLIC by default; take it away.
-- create or replace keeps an existing function's owner and grants; restate the
-- lockdown anyway so this migration leaves them exactly as the API expects.

revoke all on all functions in schema app from public, anon, authenticated;

revoke all on function public.my_recent_reports(uuid) from public, anon, authenticated;
grant execute on function public.my_recent_reports(uuid) to anon;

revoke all on function public.delete_report(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_report(uuid, uuid, uuid) to anon;

revoke all on function public.delete_my_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_my_data(uuid) to anon;
