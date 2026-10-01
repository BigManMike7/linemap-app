-- LineMap schema (PRD 7.3).
--
-- Security model (NFR-5): every table lives in the private `app` schema, which
-- the Data API does not expose. Row-level security is enabled on every table
-- with no policies, so direct access is denied even if a grant slips in. The
-- app reaches data only through the SECURITY DEFINER functions in `public`
-- (see the api migration).
--
-- Every table has id, created_at, and is_test (FR-38).
--
-- Answer codes are fixed forever (NFR-10). Definitions version 1:
--   line_size      0 = nobody, 1 = 1-10, 2 = 10-25, 3 = 25-50, 4 = 50+,
--                  5 = can't see the end
--   busyness       1 = quiet, 2 = comfortable, 3 = busy, 4 = packed
--   recalled_wait  1 = under 5, 2 = 5-15, 3 = 15-30, 4 = 30-60, 5 = 60+ min
--   *_state        answered | cant_tell | skipped; null = not asked
-- "Agree" (FR-19) means codes at most one apart.

create schema app;
revoke all on schema app from public, anon, authenticated;

-- Bars ----------------------------------------------------------------------

create table app.bars (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  is_test       boolean not null default false,
  name          text not null unique,
  address       text not null,
  door_lat      double precision not null check (door_lat between -90 and 90),
  door_lon      double precision not null check (door_lon between -180 and 180),
  size_class    text not null default 'medium'
                check (size_class in ('small', 'medium', 'large')),
  active        boolean not null default true,
  display_order integer not null default 0,
  date_added    date not null default current_date
);

-- Installs (FR-29, FR-30) ---------------------------------------------------

create table app.installs (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  is_test       boolean not null default false,
  anon_id       uuid not null,
  install_id    uuid not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  app_version   text not null,
  ios_version   text not null,
  device_model  text not null,
  unique (anon_id, install_id)
);

-- Wait sessions (FR-6 to FR-10, FR-14, FR-15) -------------------------------

create table app.wait_sessions (
  id                   bigint generated always as identity primary key,
  created_at           timestamptz not null default now(),
  is_test              boolean not null default false,
  client_session_id    uuid not null unique,
  anon_id              uuid not null,
  install_id           uuid not null,
  bar_id               bigint not null references app.bars (id),
  night_date           date not null,
  -- Phone time of "I'm in line", capped at server time.
  started_at           timestamptz not null,
  -- "Been here a while?" (FR-7): minutes to move the start back.
  start_offset_minutes smallint not null default 0
                       check (start_offset_minutes in (0, 5, 10, 20)),
  ended_at             timestamptz,
  status               text not null default 'open'
                       check (status in ('open', 'entered', 'gave_up', 'unfinished')),
  -- What ended it: I'm in, Gave up, I'm inside at the same bar (FR-15),
  -- a new line at another bar (FR-14), or the 90-minute timeout (FR-10).
  ended_by             text check (ended_by in ('im_in', 'gave_up', 'im_inside', 'new_line', 'timeout')),
  distance_start_m     real,
  distance_end_m       real,
  -- FR-8: measured wait = end time - adjusted start time.
  measured_wait_seconds integer generated always as (
    case when status = 'entered'
      then extract(epoch from ended_at - started_at)::integer + start_offset_minutes * 60
    end
  ) stored,
  check ((status = 'open') = (ended_at is null)),
  check ((status = 'open') = (ended_by is null))
);

-- FR-14: one open session per person.
create unique index wait_sessions_one_open_per_person
  on app.wait_sessions (anon_id) where status = 'open';
create index wait_sessions_open_started on app.wait_sessions (started_at) where status = 'open';
create index wait_sessions_bar_ended on app.wait_sessions (bar_id, ended_at) where status = 'entered';

-- Reports (FR-6 to FR-13, FR-16, FR-26, FR-27) -------------------------------

create table app.reports (
  id                  bigint generated always as identity primary key,
  -- Server time the report was first received.
  created_at          timestamptz not null default now(),
  is_test             boolean not null default false,
  client_report_id    uuid not null unique,
  anon_id             uuid not null,
  install_id          uuid not null,
  bar_id              bigint not null references app.bars (id),
  night_date          date not null,
  position            text not null check (position in ('line', 'inside')),
  -- What the report was, which decides the rate limit (FR-13):
  --   line_start          I'm in line (rate-limited)
  --   line_update         line-size update in an open session (exempt)
  --   inside              I'm inside (rate-limited)
  --   inside_after_entry  busyness after I'm in, or I'm inside that ended a session (exempt)
  kind                text not null
                      check (kind in ('line_start', 'line_update', 'inside', 'inside_after_entry')),
  wait_session_id     bigint references app.wait_sessions (id),

  line_size           smallint check (line_size between 0 and 5),
  line_size_state     text check (line_size_state in ('answered', 'cant_tell', 'skipped')),
  busyness            smallint check (busyness between 1 and 4),
  busyness_state      text check (busyness_state in ('answered', 'cant_tell', 'skipped')),
  recalled_wait       smallint check (recalled_wait between 1 and 5),
  recalled_wait_state text check (recalled_wait_state in ('answered', 'cant_tell', 'skipped')),

  -- Phone time of the report, capped at server time. Freshness uses this (FR-16).
  phone_time          timestamptz not null,

  -- Location (FR-26): computed on the server; coordinates are never stored.
  location_status     text not null
                      check (location_status in ('precise', 'approximate', 'denied', 'no_fix')),
  distance_m          real,
  bearing_deg         real,
  accuracy_m          real,
  fix_age_s           real,
  uncertain           boolean not null,

  hidden              boolean not null default false,
  hidden_reason       text,

  app_version         text not null,
  definitions_version smallint not null,
  source              text not null default 'app' check (source in ('app', 'live_activity')),

  -- A value is stored exactly when its state is "answered".
  check ((line_size is not null) = (line_size_state is not distinct from 'answered')),
  check ((busyness is not null) = (busyness_state is not distinct from 'answered')),
  check ((recalled_wait is not null) = (recalled_wait_state is not distinct from 'answered')),
  check (not hidden or hidden_reason is not null),
  check ((wait_session_id is null) = (kind = 'inside'))
);

create index reports_bar_phone_time on app.reports (bar_id, phone_time desc) where not hidden;
create index reports_anon_bar_created on app.reports (anon_id, bar_id, created_at desc);
create index reports_wait_session on app.reports (wait_session_id);

-- Views (FR-34) ---------------------------------------------------------------

create table app.views (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  is_test         boolean not null default false,
  anon_id         uuid not null,
  install_id      uuid not null,
  view_kind       text not null check (view_kind in ('map', 'bar')),
  bar_id          bigint references app.bars (id),
  viewed_at       timestamptz not null,
  estimate_shown  jsonb,
  logic_version   integer,
  showed_no_data  boolean not null,
  app_open_id     uuid not null,
  check ((view_kind = 'bar') = (bar_id is not null))
);

create index views_anon on app.views (anon_id);
create index views_bar on app.views (bar_id);

-- Feedback (FR-35) --------------------------------------------------------------

create table app.feedback (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  is_test         boolean not null default false,
  anon_id         uuid not null,
  install_id      uuid not null,
  bar_id          bigint not null references app.bars (id),
  estimate_shown  jsonb,
  phone_time      timestamptz not null
);

create index feedback_anon on app.feedback (anon_id);
create index feedback_bar on app.feedback (bar_id);

-- Settings (FR-37) ------------------------------------------------------------

create table app.config (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  is_test     boolean not null default false,
  key         text not null unique,
  value       jsonb not null,
  description text not null,
  updated_at  timestamptz not null default now()
);

create table app.config_history (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  is_test     boolean not null default false,
  config_key  text not null,
  old_value   jsonb,
  new_value   jsonb,
  changed_at  timestamptz not null default now(),
  changed_by  text not null default current_user
);

create index config_history_key on app.config_history (config_key, changed_at desc);

-- Logs every insert, change, and delete in config, including dashboard edits.
create function app.log_config_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.value is distinct from old.value then
      new.updated_at := now();
      insert into app.config_history (config_key, old_value, new_value, is_test)
      values (new.key, old.value, new.value, new.is_test);
    end if;
    return new;
  elsif tg_op = 'INSERT' then
    insert into app.config_history (config_key, old_value, new_value, is_test)
    values (new.key, null, new.value, new.is_test);
    return new;
  else
    insert into app.config_history (config_key, old_value, new_value, is_test)
    values (old.key, old.value, null, old.is_test);
    return old;
  end if;
end;
$$;

create trigger config_log_insert_update
  before insert or update on app.config
  for each row execute function app.log_config_change();

create trigger config_log_delete
  after delete on app.config
  for each row execute function app.log_config_change();

-- Event nights (FR-23), empty at launch ------------------------------------------
--   override: this night's window is exactly window_start to window_end
--             (both null = no active window that night)
--   extend:   this night is active, from the earlier start to the later end
--             of the usual window and this one

create table app.event_nights (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  is_test      boolean not null default false,
  night_date   date not null unique,
  label        text not null,
  type         text not null check (type in ('override', 'extend')),
  -- Eastern local times. An end at or before the start means after midnight.
  window_start time,
  window_end   time,
  check ((window_start is null) = (window_end is null)),
  check (type = 'override' or window_start is not null)
);

-- Estimate snapshots (FR-36): no IDs, kept forever ---------------------------------

create table app.estimate_snapshots (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  is_test       boolean not null default false,
  bar_id        bigint not null references app.bars (id),
  taken_at      timestamptz not null,
  estimate      jsonb not null,
  logic_version integer not null
);

create index estimate_snapshots_bar_taken on app.estimate_snapshots (bar_id, taken_at desc);

-- Spot checks (admin ground truth) --------------------------------------------------

create table app.spot_checks (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  is_test      boolean not null default false,
  bar_id       bigint not null references app.bars (id),
  checked_at   timestamptz not null,
  line_count   integer check (line_count >= 0),
  wait_minutes numeric(5, 1) check (wait_minutes >= 0),
  notes        text
);

create index spot_checks_bar on app.spot_checks (bar_id, checked_at desc);

-- Deletions (FR-32, FR-33): counts only, never an ID ----------------------------

create table app.deletions (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  is_test      boolean not null default false,
  reason       text not null check (reason in ('user_request', 'retention')),
  rows_removed integer not null check (rows_removed >= 0)
);

-- Lock everything down --------------------------------------------------------

alter table app.bars               enable row level security;
alter table app.installs           enable row level security;
alter table app.wait_sessions      enable row level security;
alter table app.reports            enable row level security;
alter table app.views              enable row level security;
alter table app.feedback           enable row level security;
alter table app.config             enable row level security;
alter table app.config_history     enable row level security;
alter table app.event_nights       enable row level security;
alter table app.estimate_snapshots enable row level security;
alter table app.spot_checks        enable row level security;
alter table app.deletions          enable row level security;

revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all sequences in schema app from public, anon, authenticated;
revoke all on all functions in schema app from public, anon, authenticated;
alter default privileges in schema app revoke all on tables from public, anon, authenticated;
alter default privileges in schema app revoke all on sequences from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;
