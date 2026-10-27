-- A question the AI checks could not be made on (the models were down or too busy, twice) is not a doubt about the question.
--
-- ai_note 'unchecked': the card says AI could not check this one just now. It is never replaced by the question maker, and it is
-- looked at again, from the start, three minutes later (answer_claimed_at holds it back till then): by itself while the paper stays
-- open on the tutor's screen (a few times), and whenever the paper is opened.
--
-- Only widens a check, so the API from before keeps working against it: run it before the new API is deployed.

alter table paper_drafts drop constraint if exists paper_drafts_ai_note_check;
alter table paper_drafts add constraint paper_drafts_ai_note_check
  check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank', 'disagree', 'unsure', 'writer_differs', 'replaced', 'unchecked'));
