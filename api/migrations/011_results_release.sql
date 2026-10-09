-- A test's marks and answers open to its students when the test closes, when the last student
-- has finished it, or when a tutor opens them. results_released_at is set by the last two (the
-- first is just the closing time passing), and once set it stays set.
alter table tests add column results_released_at timestamptz;

-- Tests with no closing time (from before closing became compulsory) have nothing to wait for, and
-- tests that have already closed are open by their closing time: both stay visible as they are.
update tests set results_released_at = now() where status = 'published' and (closes_at is null or closes_at <= now());

-- Questions the AI wrote in the chat: the answer its writer meant. Two other models solve each
-- question without seeing it; it is marked only when they agree with it and with each other.
alter table paper_drafts add column proposed_option smallint check (proposed_option between 0 and 3);
alter table paper_drafts drop constraint if exists paper_drafts_ai_note_check;
alter table paper_drafts add constraint paper_drafts_ai_note_check
  check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank', 'disagree'));
