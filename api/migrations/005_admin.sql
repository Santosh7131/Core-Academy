-- The developer's admin app: a developer account, the phones each account uses, login history,
-- request counts, server errors, and when the database woke (to estimate compute hours).

alter table users drop constraint users_role_check;
alter table users add constraint users_role_check check (role in ('teacher', 'student', 'developer'));

-- One row per installed copy of an app. The app makes the id up on first launch and sends it,
-- with the phone model, Android version and app version, on every request (from 1.2.1).
create table app_installs (
  install_id     text primary key,
  app            text not null default 'core_academy' check (app in ('core_academy', 'admin')),
  model          text,
  os_version     text,
  app_version    text,
  app_build      int,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now()
);

-- Which accounts have used which installs. A phone two students share has two rows.
create table account_devices (
  user_id        uuid not null references users(id) on delete cascade,
  install_id     text not null references app_installs(install_id) on delete cascade,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  primary key (user_id, install_id)
);
create index account_devices_install_idx on account_devices(install_id);

-- The install a session lives on. Null for sessions made by apps older than 1.2.1.
alter table sessions add column install_id text;
create index sessions_install_idx on sessions(install_id);

-- Every login attempt. Kept 90 days.
create table auth_events (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  username     text not null,
  user_id      uuid references users(id) on delete cascade,
  outcome      text not null check (outcome in ('ok', 'wrong_secret', 'lockout', 'locked', 'inactive', 'unknown_user')),
  install_id   text,
  app_version  text
);
create index auth_events_at_idx on auth_events(at desc);
create index auth_events_user_idx on auth_events(user_id, at desc);

-- Server errors (HTTP 500). Kept 30 days.
create table api_errors (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  method       text not null,
  route        text not null,
  status       int not null,
  message      text,
  user_id      uuid references users(id) on delete set null,
  install_id   text,
  app_version  text
);
create index api_errors_at_idx on api_errors(at desc);

-- Signed-in requests per route per day, India time. Kept 90 days.
create table api_daily (
  day        date not null,
  route      text not null,
  requests   int not null default 0,
  errors     int not null default 0,
  total_ms   bigint not null default 0,
  max_ms     int not null default 0,
  primary key (day, route)
);

-- Each start of the database compute (Neon starts it on demand and stops it 5 minutes after the
-- last query) and the last request it served. Neon's own usage figures read 0 on the free plan.
create table compute_wakes (
  started_at    timestamptz primary key,
  last_seen_at  timestamptz not null
);
