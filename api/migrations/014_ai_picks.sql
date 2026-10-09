-- What each AI check chose for a question it could not settle, so the card can say so instead of
-- only asking the tutor to mark the answer: {"writer": 3, "solver": 2, "checker": 2} (option numbers
-- 0 to 3; a key is left out when that check gave none). "unsure" is a question the checks could not
-- settle without disagreeing: one could not tell, or both were right but under 90% sure.

alter table paper_drafts add column ai_picks jsonb;
alter table paper_drafts drop constraint if exists paper_drafts_ai_note_check;
alter table paper_drafts add constraint paper_drafts_ai_note_check
  check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank', 'disagree', 'unsure'));
