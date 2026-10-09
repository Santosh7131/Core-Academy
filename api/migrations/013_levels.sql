-- Classes 1 to 12, and levels a tuition names itself (LKG, "NEET 2027", "B.Com year 1").
--
-- A class is stored as a number. 1 to 12 are Class 1 to Class 12. A level a tuition names itself is
-- 101 or more, with its name in tuition_levels, so the same columns, indexes and groups serve both.
-- Everything that held a class from 6 to 12 now holds 1 to 999. The apps and the API from before this
-- change keep working: they only ever send 6 to 12.

alter table users       drop constraint if exists users_class_level_check;
alter table chapters    drop constraint if exists chapters_class_level_check;
alter table papers      drop constraint if exists papers_class_level_check;
alter table questions   drop constraint if exists questions_class_level_check;
alter table tests       drop constraint if exists tests_class_level_check;
alter table memberships drop constraint if exists memberships_class_level_check;
alter table groups      drop constraint if exists groups_class_level_check;

alter table users       add constraint users_class_level_check       check (class_level between 1 and 999);
alter table chapters    add constraint chapters_class_level_check    check (class_level between 1 and 999);
alter table papers      add constraint papers_class_level_check      check (class_level between 1 and 999);
alter table questions   add constraint questions_class_level_check   check (class_level between 1 and 999);
alter table tests       add constraint tests_class_level_check       check (class_level between 1 and 999);
alter table memberships add constraint memberships_class_level_check check (class_level between 1 and 999);
alter table groups      add constraint groups_class_level_check      check (class_level between 1 and 999);

-- The classes a tuition has named itself. A tutor adds them; the API allows 20 a tuition.
create table tuition_levels (
  tuition_id  uuid not null references tuitions(id) on delete cascade,
  code        smallint not null check (code between 101 and 999),
  label       text not null check (length(trim(label)) between 1 and 30),
  created_at  timestamptz not null default now(),
  primary key (tuition_id, code)
);
create unique index tuition_levels_label_key on tuition_levels (tuition_id, lower(label));
