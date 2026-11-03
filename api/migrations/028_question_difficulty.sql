-- How hard a question is: easy, medium or hard, so a tutor can see the mix of a test and choose questions by it (app 1.8.0).
--
-- difficulty: null until someone says. difficulty_by tells who: 'tutor' (set by hand, and never changed by AI after that) or 'ai'
--   (a guess made when AI read the paper or wrote the question, shown as a suggestion).
-- paper_drafts carries the same two columns, so a guess made while reading a page reaches the question when it is saved.
--
-- Only adds nullable columns, so the API from before keeps working against it: run it before the new API is deployed.

alter table questions
  add column if not exists difficulty text check (difficulty in ('easy', 'medium', 'hard')),
  add column if not exists difficulty_by text check (difficulty_by in ('tutor', 'ai'));

alter table paper_drafts
  add column if not exists difficulty text check (difficulty in ('easy', 'medium', 'hard')),
  add column if not exists difficulty_by text check (difficulty_by in ('tutor', 'ai'));
