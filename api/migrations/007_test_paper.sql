-- A test made from a question paper remembers it, so the paper can show its test instead of
-- offering to publish the same questions twice.
alter table tests add column paper_id uuid references papers(id) on delete set null;
create index tests_paper_idx on tests(paper_id);
