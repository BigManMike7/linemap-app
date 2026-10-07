-- Time in lines (Settings tracker). Approved by Max on 2026-10-07.
--
-- my_wait_stats sums the person's own finished waits, so Settings can show how
-- much time they have spent in lines. Read-only: it writes nothing and never
-- expires a timer.
--
-- A wait counts when its status is entered or gave_up, whatever ended it:
--   im_in, gave_up   I'm in or Gave up (end_session)
--   im_inside        I'm inside at the same bar (older builds, FR-15)
--   new_line         a line started at another bar (FR-14); the end is that
--                    new start, so the time is real, if an upper bound
-- Never counted:
--   open             still running (or reopened by Undo, FR-47)
--   unfinished       the 90-minute timeout (FR-10); the end time is unknown
-- Started by mistake (FR-39), deleted through Made a wrong report? (FR-41),
-- and timers replaced by a redo (FR-46) are deleted rows, so they drop out on
-- their own. A redo deletes the earlier timer in the same transaction that
-- finishes the new one through end_session. But a redo closed by a line at
-- another bar (new_line) keeps the earlier timer (FR-46), so a wait that a
-- later finished wait redid is skipped here, by the same rule as
-- app.delete_replaced_sessions: same person and bar, the later one started
-- less than redo_minutes after this one ended. Within that time the rate
-- limit allows a second timer at the bar only as a redo.
--
-- Time in line is the same formula as the generated measured_wait_seconds
-- (which covers only entered): ended_at - started_at + Adjust time, clamped
-- at 0. Test rows are counted: it is the person's own total. Waits older than
-- retention_days (365) are already purged, so there is no date filter.
--
-- Returns {"total_seconds": n, "waits": n, "longest_seconds": n or null}.
--
-- No table, field, or answer-code change; one new read-only function.

create function public.my_wait_stats(p_anon_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_redo interval := app.setting_minutes('redo_minutes');
  result jsonb;
begin
  if p_anon_id is null then perform app.bad_input('anon_id is required'); end if;

  select jsonb_build_object(
           'total_seconds', coalesce(sum(w.seconds), 0),
           'waits', count(*),
           'longest_seconds', max(w.seconds)
         )
  into result
  from (
    select greatest(
             extract(epoch from s.ended_at - s.started_at)::integer
               + s.start_offset_minutes * 60,
             0
           )::bigint as seconds
    from app.wait_sessions s
    where s.anon_id = p_anon_id
      and s.status in ('entered', 'gave_up')
      -- Not replaced by a later finished redo (see above).
      and not exists (
        select 1
        from app.wait_sessions n
        where n.anon_id = s.anon_id
          and n.bar_id = s.bar_id
          and n.id <> s.id
          and n.status in ('entered', 'gave_up')
          and s.ended_at <= n.started_at
          and n.started_at - s.ended_at < v_redo
      )
  ) w;

  return result;
end;
$$;

revoke all on function public.my_wait_stats(uuid) from public, anon, authenticated;
grant execute on function public.my_wait_stats(uuid) to anon;
