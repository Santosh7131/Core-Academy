-- Push notifications through Firebase Cloud Messaging. Each phone's token belongs to the login
-- session it registered under, so logging out (or a PIN reset, which ends every session) stops
-- that phone's notifications. The scheduled job (/cron/notify) announces tests as they open,
-- reminds students before a test closes, and sends the teacher an evening summary;
-- announced_at, reminded_at and daily_summaries make each one go out once.
create table device_tokens (
  token         text primary key,
  session_hash  text not null references sessions(token_hash) on delete cascade,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);
create index device_tokens_session_idx on device_tokens(session_hash);

alter table tests add column announced_at timestamptz;
alter table tests add column reminded_at timestamptz;

-- Tests already published when notifications arrive are not announced again.
update tests set announced_at = now() where status = 'published';

create table daily_summaries (
  day      date primary key,             -- the date in India
  sent_at  timestamptz not null default now()
);
