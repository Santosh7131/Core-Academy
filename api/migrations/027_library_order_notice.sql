-- Library: files can be put in the tutor's own order, and students are told when new files are added (app 1.8.0).
--
-- position: where a file sits in its section, counted from 1. Files made before this column existed all hold 0 and keep their old
--   order (the date they were added, then the name); a new file goes to the end.
-- announced_at: when the students of the shelf were told about the file (POST /teacher/library/announce). Files that were already
--   there are marked as told, so nobody is sent a notice about an old file.
--
-- Only adds columns that are nullable or have a default, so the API from before keeps working against it: run it before the new API
-- is deployed.

alter table class_files
  add column if not exists position integer not null default 0,
  add column if not exists announced_at timestamptz;

update class_files set announced_at = coalesce(ready_at, created_at) where announced_at is null;
