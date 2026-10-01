-- Scheduled jobs (PRD 7.2). pg_cron runs in UTC; time rules live in the
-- functions, so the schedules themselves need no time zone.

create extension if not exists pg_cron with schema pg_catalog;

-- FR-10: open sessions past the timeout become unfinished.
create function app.expire_sessions(p_at timestamptz default now())
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  n integer;
begin
  update app.wait_sessions s
  set status = 'unfinished',
      ended_by = 'timeout',
      ended_at = s.started_at + app.setting_minutes('session_timeout_minutes')
  where s.status = 'open'
    and s.started_at + app.setting_minutes('session_timeout_minutes') <= p_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- FR-33: delete ID-linked data older than retention_days. Snapshots, spot
-- checks, and settings have no IDs and are kept.
create function app.purge_old_data(p_at timestamptz default now())
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  cutoff timestamptz := p_at - make_interval(days => app.setting_int('retention_days'));
  n      integer;
  total  integer := 0;
begin
  delete from app.reports r
  where r.created_at < cutoff
     or r.wait_session_id in (select s.id from app.wait_sessions s where s.created_at < cutoff);
  get diagnostics n = row_count; total := total + n;
  delete from app.wait_sessions where created_at < cutoff;
  get diagnostics n = row_count; total := total + n;
  delete from app.views where created_at < cutoff;
  get diagnostics n = row_count; total := total + n;
  delete from app.feedback where created_at < cutoff;
  get diagnostics n = row_count; total := total + n;
  -- An install still in use keeps its row.
  delete from app.installs where last_seen_at < cutoff;
  get diagnostics n = row_count; total := total + n;

  if total > 0 then
    insert into app.deletions (reason, rows_removed) values ('retention', total);
  end if;
  return total;
end;
$$;

revoke all on function app.expire_sessions(timestamptz) from public, anon, authenticated;
revoke all on function app.purge_old_data(timestamptz) from public, anon, authenticated;

-- cron.schedule replaces a job with the same name, so this is safe to re-run.
select cron.schedule('expire-sessions', '*/5 * * * *', 'select app.expire_sessions()');
select cron.schedule('take-snapshots', '*/5 * * * *', 'select app.take_snapshots()');
-- 09:15 UTC is 4:15 or 5:15 a.m. Eastern, after the night boundary.
select cron.schedule('purge-old-data', '15 9 * * *', 'select app.purge_old_data()');
