-- Papers get a category (where their questions came from), and AI now reads a paper before its
-- details are filled in: it suggests the name, class, subject, category and chapter, finds the
-- paper's own answer key, and marks an answer itself only when it is sure.
-- Schools and paper years go too, in 009, once no running API reads them any more.

-- Where a paper's questions came from, e.g. "NCERT Exemplar". The Questions tab groups by it.
alter table papers add column category text check (category is null or length(trim(category)) between 1 and 60);

-- The paper's chapter, when the whole paper is one chapter. Its questions default to it.
alter table papers add column chapter_id uuid references chapters(id) on delete set null;

-- A paper is uploaded before its details are known, so its class and subject can be unknown
-- until AI finds them or the teacher fills them in. ai_details keeps what AI found, for the record.
alter table papers alter column class_level drop not null;
alter table papers alter column subject_id drop not null;
alter table papers alter column subject_id drop default;
alter table papers add column ai_details jsonb;

-- Each page's printed answer key: question number -> the option as printed ("b", "C", "3").
alter table paper_pages add column answer_key jsonb;

-- Where a draft's marked answer came from: the teacher, the paper's own answer key, or AI when it
-- was sure. answer_checked means AI has already looked for an answer to this draft.
alter table paper_drafts add column answer_source text check (answer_source in ('teacher', 'key', 'ai'));
alter table paper_drafts add column ai_confidence real check (ai_confidence between 0 and 1);
alter table paper_drafts add column answer_checked boolean not null default false;
update paper_drafts set answer_source = 'teacher' where correct_option is not null;
