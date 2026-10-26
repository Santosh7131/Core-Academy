-- Courses: a list of people of its own, with its own papers, questions and tests.
--
-- A group is a class studying one subject, and its students are worked out from their class and subjects.
-- A course is not worked out from anything: a tutor makes one, and adds the people they choose, from any
-- class or from outside every class. A person can be in any number of groups and any number of courses,
-- and nothing of a course (its papers, questions, tests, results) is ever part of a group, or the other way
-- round: every row that belongs to a course says so in course_id, and the API keeps those rows out of every
-- group query.
--
-- Everything here only adds, or relaxes a check, so the API from before courses keeps working against it:
-- it never creates a course row, and it never meets a row it cannot read until a tutor makes a course. Apply
-- this before the API that knows courses is deployed.

create table courses (
  id          uuid primary key default gen_random_uuid(),
  tuition_id  uuid not null references tuitions(id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 60),
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index courses_tuition_idx on courses (tuition_id, created_at desc);
create unique index courses_name_key on courses (tuition_id, lower(name));

create table course_members (
  course_id   uuid not null references courses(id) on delete cascade,
  student_id  uuid not null references users(id) on delete cascade,
  added_at    timestamptz not null default now(),
  primary key (course_id, student_id)
);
create index course_members_student_idx on course_members (student_id);

-- A course's papers, questions and tests. The API deletes them in order when the course goes (tests first,
-- because a test holds on to its questions); the cascade is only the backstop.
alter table tests     add column course_id uuid references courses(id) on delete cascade;
alter table papers    add column course_id uuid references courses(id) on delete cascade;
alter table questions add column course_id uuid references courses(id) on delete cascade;
create index tests_course_idx     on tests (course_id)     where course_id is not null;
create index papers_course_idx    on papers (course_id)    where course_id is not null;
create index questions_course_idx on questions (course_id) where course_id is not null;

-- A course's tests and questions have no class and no subject, which a group's always have.
alter table tests     alter column class_level drop not null;
alter table tests     alter column subject_id  drop not null;
alter table questions alter column class_level drop not null;
alter table questions alter column subject_id  drop not null;
alter table tests     add constraint tests_scope_check
  check (course_id is not null or (class_level is not null and subject_id is not null));
alter table questions add constraint questions_scope_check
  check (course_id is not null or (class_level is not null and subject_id is not null));

-- A student may have no class: a person who is only in courses. Only students can have one at all.
alter table users       drop constraint users_check;
alter table users       add constraint users_check check (role = 'student' or class_level is null);
alter table memberships drop constraint memberships_check;
alter table memberships add constraint memberships_check check (role = 'student' or class_level is null);
