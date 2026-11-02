-- A paper made as one of several at once remembers the test the tutor planned for it.
--
-- plan: {"opens_at": ISO or null, "closes_at": ISO, "time_limit_min": 1 to 300 or null, "shuffle": true or false}. A null
-- time_limit_min means "a minute and a half a question", worked out when the test is posted, because how many questions there
-- are is not known until the paper has been read. A paper with a plan is posted as that test: from the screen that made it, or
-- later from the paper's own page. A paper with no plan (every paper before this) is posted as before.
--
-- Only adds a nullable column, so the API from before keeps working against it: run it before the new API is deployed.

alter table papers add column if not exists plan jsonb;
alter table papers drop constraint if exists papers_plan_object;
alter table papers add constraint papers_plan_object check (plan is null or jsonb_typeof(plan) = 'object');
