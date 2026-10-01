-- cancel_session: discards a line started by mistake (FR-39).
--
-- Deletes the session and every report in it, so nothing counts: not the
-- estimate, not the people count, and not the rate limit. Only a session that
-- is still open (or that timed out) can be cancelled; a finished wait stays.
-- Cancelling a session that never reached the server (or someone else's) is a
-- harmless no-op, so the offline queue can always send it.

create function public.cancel_session(
  p_client_session_id uuid,
  p_anon_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s app.wait_sessions%rowtype;
begin
  if p_client_session_id is null or p_anon_id is null then
    perform app.bad_input('client_session_id and anon_id are required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_anon_id::text, 0));

  select * into s from app.wait_sessions ws
  where ws.client_session_id = p_client_session_id and ws.anon_id = p_anon_id;
  if not found then
    return jsonb_build_object('ok', true, 'removed', false);
  end if;
  if s.status not in ('open', 'unfinished') then
    return jsonb_build_object('ok', false, 'error', 'session_not_open', 'status', s.status);
  end if;

  delete from app.reports r where r.wait_session_id = s.id;
  delete from app.wait_sessions ws where ws.id = s.id;
  return jsonb_build_object('ok', true, 'removed', true);
end;
$$;

revoke all on function public.cancel_session(uuid, uuid) from public, anon, authenticated;
grant execute on function public.cancel_session(uuid, uuid) to anon;
