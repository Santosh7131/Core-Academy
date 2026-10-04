-- Subjects, and the groups they make with classes. A student studies one or more subjects, and
-- the group "10th Science" is every Class 10 student who studies Science. Chapters, questions,
-- papers and tests each belong to one subject. A test goes to the whole class (assign_all), to
-- the group of its class and subject (assign_group), or to chosen students (neither).
--
-- Older app versions know nothing about subjects, so every new column has a default that keeps
-- their requests working: Maths, and assign_group = false.

create table subjects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- Maths has a fixed id because it is the default subject; the API never deletes it.
insert into subjects (id, name, sort_order) values ('00000000-0000-4000-8000-000000000001', 'Maths', 0);
insert into subjects (name, sort_order) values ('Science', 1);

-- Everything made before subjects existed was maths: the tuition started as a maths tuition.
alter table chapters  add column subject_id uuid not null default '00000000-0000-4000-8000-000000000001' references subjects(id);
alter table questions add column subject_id uuid not null default '00000000-0000-4000-8000-000000000001' references subjects(id);
alter table papers    add column subject_id uuid not null default '00000000-0000-4000-8000-000000000001' references subjects(id);
alter table tests     add column subject_id uuid not null default '00000000-0000-4000-8000-000000000001' references subjects(id);
create index questions_subject_idx on questions(class_level, subject_id);

-- Two subjects can each have a chapter with the same name in the same class.
alter table chapters drop constraint chapters_class_level_name_key;
alter table chapters add constraint chapters_class_subject_name_key unique (class_level, subject_id, name);

create table student_subjects (
  student_id  uuid not null references users(id) on delete cascade,
  subject_id  uuid not null references subjects(id) on delete cascade,
  primary key (student_id, subject_id)
);
create index student_subjects_subject_idx on student_subjects(subject_id);

insert into student_subjects (student_id, subject_id)
select id, '00000000-0000-4000-8000-000000000001' from users where role = 'student';

alter table tests add column assign_group boolean not null default false;
alter table tests add constraint tests_one_audience check (not (assign_all and assign_group));
