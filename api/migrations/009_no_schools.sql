-- Schools and paper years are gone: students and papers no longer name a school, and papers
-- have no year. This runs only after the API that no longer reads them is live (the one before
-- it read users.school_id on every signed-in request). "if exists": the dev branch dropped them
-- in an earlier copy of 006.
alter table users drop column if exists school_id;
alter table papers drop column if exists school_id;
drop table if exists schools;
alter table papers drop column if exists year;
