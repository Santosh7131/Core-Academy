-- The second opinion on a question is a separate step now, so the tutor sees the paper without waiting for it.
--
-- ai_votes: set when the first two AI checks could not settle a question but at least one of them gave
-- an answer. It holds what each said, so the stronger model that is asked next can be counted with them:
-- {"solver": {"answer": 2, "confidence": 0.9}, "checker": {"answer": 1, "confidence": 0.95}, "tries": 0}
-- (a check that gave nothing is left out; tries counts the times a second opinion was asked for and none
-- came back). A question is waiting for its second opinion while this is set; it is cleared when the
-- stronger model has answered, when two tries have come back empty, or when the tutor rewords the question.

alter table paper_drafts add column ai_votes jsonb;
