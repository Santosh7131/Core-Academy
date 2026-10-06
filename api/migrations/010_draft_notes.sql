-- What AI noticed about a draft, shown on its card so the teacher knows what to check:
--   unclear    part of it could not be read on the page (smudged, cut off, or printed as boxes
--              like ■), and AI filled it in or left the ■;
--   no_option  both AI models found no option that fits the question as it was read;
--   duplicate  it repeats an earlier question of the same paper (duplicate_of), so it is skipped;
--   in_bank    the question bank already has it, so saving skipped it.
alter table paper_drafts add column ai_note text check (ai_note in ('unclear', 'no_option', 'duplicate', 'in_bank'));
alter table paper_drafts add column duplicate_of uuid references paper_drafts(id) on delete set null;

-- AI answers a paper in several calls at once, each taking its own batch of questions. A call
-- stamps the questions it has taken; a stamp older than a few minutes (the call failed, or the
-- app was closed) counts as free again.
alter table paper_drafts add column answer_claimed_at timestamptz;
