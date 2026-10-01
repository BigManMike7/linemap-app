-- Live estimates (FR-17 to FR-21) and snapshots (FR-36).
--
-- Each signal (line size, wait, busyness) is picked separately:
--   1. Take each person's newest report for the signal within the stale
--      window (60 min), so one person counts once (FR-18).
--   2. The newest report wins (FR-19)...
--   3. ...unless it is fresh (30 min) and disagrees with the fresh reports of
--      majority_min_others (2) or more other people. "Disagree" means codes
--      more than agree_within (1) apart. Then the most common fresh code
--      wins, ties going to the most recent; the winner is that code's newest
--      report.
-- Waits combine measured waits (aged from when the person got in) and
-- recalled ranges. Measured waits are compared by their range code.
-- Uncertain reports count like any other (FR-20). Hidden reports never count.
-- Times are phone times capped at server time, so late offline reports count
-- only while their phone time is fresh (FR-16).

-- Each person's newest value for one signal at one bar, within [p_since, p_at].
create function app.signal_people(p_bar_id bigint, p_signal text, p_since timestamptz,
                                  p_at timestamptz, p_include_test boolean)
returns table (anon_id uuid, at timestamptz, code smallint, minutes integer, source text)
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct on (c.anon_id) c.anon_id, c.at, c.code, c.minutes, c.source
  from (
    select r.anon_id, r.phone_time as at, r.line_size as code,
           null::integer as minutes, 'reported' as source
    from app.reports r
    where p_signal = 'line_size' and r.bar_id = p_bar_id
      and r.line_size is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select r.anon_id, r.phone_time, r.busyness, null, 'reported'
    from app.reports r
    where p_signal = 'busyness' and r.bar_id = p_bar_id
      and r.busyness is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select r.anon_id, r.phone_time, r.recalled_wait, null, 'reported'
    from app.reports r
    where p_signal = 'wait' and r.bar_id = p_bar_id
      and r.recalled_wait is not null and not r.hidden
      and (p_include_test or not r.is_test)
    union all
    select s.anon_id, s.ended_at, app.wait_code(s.measured_wait_seconds),
           round(s.measured_wait_seconds / 60.0)::integer, 'measured'
    from app.wait_sessions s
    where p_signal = 'wait' and s.bar_id = p_bar_id
      and s.status = 'entered'
      and (p_include_test or not s.is_test)
  ) c
  where c.at >= p_since and c.at <= p_at
  -- On a tie, a measured wait beats a reported range.
  order by c.anon_id, c.at desc, c.source
$$;

-- The shown value for one signal, or null when there is none.
create function app.pick_signal(p_bar_id bigint, p_signal text, p_at timestamptz,
                                p_include_test boolean)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  fresh_since  timestamptz := p_at - app.setting_minutes('fresh_minutes');
  stale_since  timestamptz := p_at - app.setting_minutes('stale_minutes');
  agree_within integer := app.setting_int('agree_within');
  min_others   integer := app.setting_int('majority_min_others');
  newest       record;
  winner       record;
  disagreeing  integer;
begin
  select * into newest
  from app.signal_people(p_bar_id, p_signal, stale_since, p_at, p_include_test) p
  order by p.at desc, p.source
  limit 1;

  if not found then
    return null;
  end if;

  winner := newest;

  if newest.at >= fresh_since then
    select count(*) into disagreeing
    from app.signal_people(p_bar_id, p_signal, fresh_since, p_at, p_include_test) p
    where p.anon_id <> newest.anon_id
      and abs(p.code - newest.code) > agree_within;

    if disagreeing >= min_others then
      with fresh as (
        select * from app.signal_people(p_bar_id, p_signal, fresh_since, p_at, p_include_test)
      ), votes as (
        select f.code, count(*) as n, max(f.at) as last_at
        from fresh f
        group by f.code
      )
      select f.* into winner
      from fresh f
      join votes v on v.code = f.code
      order by v.n desc, v.last_at desc, f.at desc, f.source
      limit 1;
    end if;
  end if;

  return jsonb_build_object(
    'code', winner.code,
    'minutes', winner.minutes,
    'source', winner.source,
    'at', winner.at,
    'freshness', case when winner.at >= fresh_since then 'fresh' else 'stale' end,
    'rule', case when winner.anon_id = newest.anon_id and winner.at = newest.at
                 then 'newest' else 'majority' end
  );
end;
$$;

-- Everyone who reported at a bar within [p_since, p_at]: any visible report,
-- or a finished wait.
create function app.bar_activity(p_bar_id bigint, p_since timestamptz, p_at timestamptz,
                                 p_include_test boolean)
returns table (anon_id uuid, at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select r.anon_id, r.phone_time
  from app.reports r
  where r.bar_id = p_bar_id and not r.hidden
    and (p_include_test or not r.is_test)
    and r.phone_time >= p_since and r.phone_time <= p_at
  union all
  select s.anon_id, s.ended_at
  from app.wait_sessions s
  where s.bar_id = p_bar_id and s.status = 'entered'
    and (p_include_test or not s.is_test)
    and s.ended_at >= p_since and s.ended_at <= p_at
$$;

-- One bar's estimate. `display` tells the app which state to show:
--   estimate         show the signals (stale ones grayed out)
--   not_enough_data  in the active window, but nothing within 60 minutes
--   closed           2-4 a.m. after an active night
--   outside_hours    outside the window and no fresh signal
create function app.bar_estimate(p_bar_id bigint, p_at timestamptz,
                                 p_include_test boolean, p_window_state text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  fresh_since timestamptz := p_at - app.setting_minutes('fresh_minutes');
  stale_since timestamptz := p_at - app.setting_minutes('stale_minutes');
  line_size   jsonb := app.pick_signal(p_bar_id, 'line_size', p_at, p_include_test);
  wait        jsonb := app.pick_signal(p_bar_id, 'wait', p_at, p_include_test);
  busyness    jsonb := app.pick_signal(p_bar_id, 'busyness', p_at, p_include_test);
  latest      timestamptz;
  freshness   text;
  people      integer := 0;
  display     text;
begin
  select max(a.at) into latest
  from app.bar_activity(p_bar_id, stale_since, p_at, p_include_test) a;

  freshness := case
    when latest is null then 'none'
    when latest >= fresh_since then 'fresh'
    else 'stale'
  end;

  if freshness <> 'none' then
    select count(distinct a.anon_id) into people
    from app.bar_activity(
      p_bar_id,
      case when freshness = 'fresh' then fresh_since else stale_since end,
      p_at, p_include_test) a;
  end if;

  display := case
    when p_window_state = 'closed' then 'closed'
    when p_window_state = 'live' then
      case when coalesce(line_size, wait, busyness) is not null
           then 'estimate' else 'not_enough_data' end
    when 'fresh' in (line_size ->> 'freshness', wait ->> 'freshness', busyness ->> 'freshness')
      then 'estimate'
    else 'outside_hours'
  end;

  return jsonb_build_object(
    'bar_id', p_bar_id,
    'display', display,
    'freshness', freshness,
    'people', people,
    'latest_at', latest,
    'line_size', line_size,
    'wait', wait,
    'busyness', busyness
  );
end;
$$;

-- Every active bar's estimate at a moment. Real users never see test rows;
-- test IDs see test rows too, so Max can check his own reports.
create function app.estimates(p_at timestamptz, p_include_test boolean)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  ws text := app.window_state(p_at);
begin
  return jsonb_build_object(
    'logic_version', app.logic_version(),
    'generated_at', p_at,
    'window_state', ws,
    'bars', coalesce((
      select jsonb_agg(app.bar_estimate(b.id, p_at, p_include_test, ws)
                       order by b.display_order, b.id)
      from app.bars b
      where b.active and (p_include_test or not b.is_test)
    ), '[]'::jsonb)
  );
end;
$$;

-- Saves what each bar would show, during the active window only (FR-36).
-- Snapshots never include test rows.
create function app.take_snapshots(p_at timestamptz default now())
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  saved integer;
begin
  if app.window_state(p_at) <> 'live' then
    return 0;
  end if;

  insert into app.estimate_snapshots (bar_id, taken_at, estimate, logic_version)
  select b.id, p_at, app.bar_estimate(b.id, p_at, false, 'live'), app.logic_version()
  from app.bars b
  where b.active and not b.is_test;

  get diagnostics saved = row_count;
  return saved;
end;
$$;

revoke all on all functions in schema app from public, anon, authenticated;
