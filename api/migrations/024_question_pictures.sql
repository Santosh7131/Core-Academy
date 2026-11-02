-- Where each question and its figure sit on the paper's pages, and questions that ran over a page edge (app 1.8.0).
--
-- question_boxes: where the question is printed, so the app can show its picture from the page: a list of
--   {"page": 3, "box": [x1, y1, x2, y2]}, the box as fractions of the page (0,0 top left, 1,1 bottom right).
--   Two entries when a question ran onto the next page and was joined.
-- figure_box: {"page": 3, "box": [...]} where the question's figure or diagram is printed; the app cuts it out of the page
--   and attaches it (image_key). Remembered so the tutor can cut it again from where she last cut.
-- cont_next / cont_prev: the page reader said this question goes on over the bottom of its page / is the rest of one from the page
--   before. A pair of them is joined into one question (joined = true, joined_from holds what both were before, so the tutor can undo it).
-- keep_apart: the tutor undid a join, so these two are not joined again.
--
-- Only adds columns that are nullable or have a default, so the API from before keeps working against it: run it before the
-- new API is deployed.

alter table paper_drafts
  add column if not exists question_boxes jsonb,
  add column if not exists figure_box jsonb,
  add column if not exists cont_next boolean not null default false,
  add column if not exists cont_prev boolean not null default false,
  add column if not exists joined boolean not null default false,
  add column if not exists joined_from jsonb,
  add column if not exists keep_apart boolean not null default false;
