-- Ready-made questions and chapter tests imported from tools/library. library_key makes the
-- import idempotent: running it again updates the same rows instead of adding copies.
alter table questions drop constraint questions_source_check;
alter table questions add constraint questions_source_check check (source in ('manual', 'paper', 'library'));
alter table questions add column library_key text unique;
alter table tests add column library_key text unique;
