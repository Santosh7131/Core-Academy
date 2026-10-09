-- How much each client (a tuition) uses the service: API requests per client per day, for the admin app's
-- Clients screen. A request counts when it is signed in and belongs to a tuition (the developer's own
-- requests never do). What AI costs a client comes from ai_usage, which has had a tuition since 012.

create table api_daily_tuition (
  day         date not null,
  tuition_id  uuid not null references tuitions(id) on delete cascade,
  requests    int not null default 0,
  errors      int not null default 0,
  total_ms    bigint not null default 0,
  primary key (day, tuition_id)
);
create index api_daily_tuition_idx on api_daily_tuition (tuition_id, day desc);
