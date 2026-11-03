-- Every question has a level (app 1.8.0): AI sets it when it reads or writes the question, and it is Medium when AI could not tell or
-- nobody said. Questions from before levels become Medium; difficulty_by stays empty for them, because nobody judged them.
--
-- Only fills empty values and adds a default, so the API from before keeps working against it: run it before the new API is deployed.
-- Not-null is left off on purpose: the code already always gives a level, and a refused save on a tutor's phone is worse than a Medium.

update questions set difficulty = 'medium' where difficulty is null;
update paper_drafts set difficulty = 'medium' where difficulty is null;

alter table questions alter column difficulty set default 'medium';
alter table paper_drafts alter column difficulty set default 'medium';
