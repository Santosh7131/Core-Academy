-- The AI question maker replaces a question its checks cannot settle with a new one, instead of leaving it for the tutor.
--
-- papers.ai_request: what the tutor asked AI to write ("easy and medium questions on quadratic equations"). It is kept so a
-- question can be replaced by a new one on the same request, whenever the checks have finished with it. Papers written
-- before this have none, so their questions are left to the tutor as they were.
-- paper_drafts.edited: the tutor has marked this question, reworded it, said it looks right or brought it back from Skipped.
-- A question like that is hers: AI never replaces it.
-- ai_note 'replaced': the question was written by AI, the checks could not settle its answer (or settled it against what the
-- writer meant), and a new question took its place. It stays under Skipped, with the reason.
--
-- Everything here only adds, or widens a check, so the API from before keeps working against it: run it before the new API is deployed.

alter table papers add column ai_request text;
alter table paper_drafts add column edited boolean not null default false;
alter table paper_drafts drop constraint if exists paper_drafts_ai_note_check;
alter table paper_drafts add constraint paper_drafts_ai_note_check
  check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank', 'disagree', 'unsure', 'writer_differs', 'replaced'));
