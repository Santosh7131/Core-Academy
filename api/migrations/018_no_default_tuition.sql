-- Every row says which tuition it belongs to; none falls back to the first one.
--
-- Migration 012 gave each new tuition_id column the first tuition (the one the app was built for) as a
-- default, so the API from before tuitions kept working while it was switched over. That API is gone,
-- and a default would now be a quiet way to put one tutor's data into another's tuition if a new insert
-- ever forgot to say which tuition it is for. Without it such an insert fails loudly instead.
--
-- Apply this only after the API that always names the tuition is deployed.

alter table chapters         alter column tuition_id drop default;
alter table questions        alter column tuition_id drop default;
alter table papers           alter column tuition_id drop default;
alter table tests            alter column tuition_id drop default;
alter table student_subjects alter column tuition_id drop default;
alter table daily_summaries  alter column tuition_id drop default;
