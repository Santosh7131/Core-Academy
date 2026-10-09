-- Uploading a paper should not stall or leave questions blank.
--
-- name_auto: a paper starts with a name made from the date ("Paper 10 Oct"), so nothing waits for the tutor
-- to type one. AI replaces it with the paper's own title when it finds one; a name the tutor typed stays.
-- answer_tries: how many times AI has looked for a question's answer. A model that skipped a question is
-- asked again (twice at most) instead of the question being left blank without a word.
-- writer_differs: AI marked the answer because two models agreed on it, but the model that wrote the
-- question had chosen another option, so the card asks the tutor to check it.

alter table papers add column name_auto boolean not null default false;
alter table paper_drafts add column answer_tries smallint not null default 0;
alter table paper_drafts drop constraint if exists paper_drafts_ai_note_check;
alter table paper_drafts add constraint paper_drafts_ai_note_check
  check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank', 'disagree', 'unsure', 'writer_differs'));
