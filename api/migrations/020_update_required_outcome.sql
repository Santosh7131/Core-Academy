-- A login turned away because the app is too old (or from before courses, for a student with no class) is
-- written to the login history like any other, so the admin app shows who is still on an old version.
-- The history lists its outcomes in a check; this adds the new one.

alter table auth_events drop constraint auth_events_outcome_check;
alter table auth_events add constraint auth_events_outcome_check
  check (outcome in ('ok', 'wrong_secret', 'lockout', 'locked', 'inactive', 'unknown_user', 'signup', 'update_required'));
