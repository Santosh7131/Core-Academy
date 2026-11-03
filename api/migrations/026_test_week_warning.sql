-- A test left open for a week: the tutor is told, and can close it or remind the students who have not handed in (app 1.8.0).
--
-- published_at: when the test was posted (set by POST /teacher/tests/:id/publish). A test posted before this column existed is
--   dated from when its students were first told, else when it opens, else when it was made.
-- stale_notified_at: when the tutor was last sent the "open for a week" notification about this test, so a test is told about once
--   a week at most.
-- nudged_at: when the tutor last used "Remind the students" on it. The warning on Home stays away for a week after that.
--
-- Only adds nullable columns, so the API from before keeps working against it: run it before the new API is deployed.

alter table tests
  add column if not exists published_at timestamptz,
  add column if not exists stale_notified_at timestamptz,
  add column if not exists nudged_at timestamptz;

update tests set published_at = coalesce(announced_at, opens_at, created_at) where status = 'published' and published_at is null;
