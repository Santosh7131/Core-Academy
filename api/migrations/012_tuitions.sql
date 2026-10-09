-- More than one tuition. A tuition is a tutor's business: its own students, groups, subjects,
-- papers, questions and tests. A person (tutor or student) has one login and belongs to tuitions
-- through memberships, so a student can learn from several tutors and a tutor can run a tuition
-- of their own.
--
-- Everything that exists now becomes tuition 1 (the tuition this app was built for), and every
-- new tuition_id column defaults to it. An API that knows nothing of tuitions therefore keeps
-- working through the switchover: the rows it writes land in tuition 1, and it sees each
-- person's first tuition. Migration 013 drops the defaults once no such API runs any more.

create table tuitions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 60),
  -- What a student types to ask to join: six characters, no 0, O, 1 or I.
  join_code   text not null unique check (join_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  join_open   boolean not null default true,
  plan        text not null default 'free' check (plan in ('free', 'tutor', 'tuition', 'institute')),
  plan_until  timestamptz,
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz not null default now()
);

insert into tuitions (id, name, join_code, created_by)
select '00000000-0000-4000-8000-0000000000a1'::uuid,
       coalesce((select value #>> '{}' from app_settings where key = 'tuition_name'), 'Core Academy'),
       (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
          from generate_series(1, 6)),
       (select id from users where role = 'teacher' order by created_at limit 1);

-- A person in a tuition. A student asks to join (pending), and a tutor lets them in (active).
-- A tutor can turn a member off for their tuition without touching the person's other tuitions.
-- A student's class is per tuition: tutor B regrouping a student must not move them in tutor A's.
create table memberships (
  tuition_id   uuid not null references tuitions(id) on delete cascade,
  user_id      uuid not null references users(id) on delete cascade,
  role         text not null check (role in ('owner', 'tutor', 'student')),
  status       text not null default 'active' check (status in ('active', 'pending', 'off')),
  class_level  smallint check (class_level between 6 and 12),
  joined_at    timestamptz not null default now(),
  primary key (tuition_id, user_id),
  check ((role = 'student') = (class_level is not null))
);
create index memberships_user_idx on memberships(user_id, status, joined_at);
create index memberships_tuition_idx on memberships(tuition_id, role, status);

insert into memberships (tuition_id, user_id, role, status, class_level, joined_at)
select '00000000-0000-4000-8000-0000000000a1'::uuid, u.id,
       case when u.role = 'student' then 'student'
            when u.id = (select id from users where role = 'teacher' order by created_at limit 1) then 'owner'
            else 'tutor' end,
       case when u.active then 'active' else 'off' end,
       u.class_level, u.created_at
  from users u where u.role in ('teacher', 'student');

-- ------------------------------------------------------------------ subjects
-- Standard subjects (tuition_id null) are shared by every tuition. A subject a tutor typed in
-- themselves belongs to their tuition. Each tuition lists the subjects it teaches.

alter table subjects add column tuition_id uuid references tuitions(id) on delete cascade;

-- Subjects added by hand before now were added in tuition 1.
update subjects set tuition_id = '00000000-0000-4000-8000-0000000000a1'
 where lower(name) not in ('maths', 'science', 'physics', 'chemistry', 'biology', 'english', 'hindi', 'tamil',
                           'social science', 'computer science');

create table tuition_subjects (
  tuition_id  uuid not null references tuitions(id) on delete cascade,
  subject_id  uuid not null references subjects(id) on delete cascade,
  primary key (tuition_id, subject_id)
);
create index tuition_subjects_subject_idx on tuition_subjects(subject_id);

-- Tuition 1 teaches every subject there is right now (the standard ones added below are not its).
insert into tuition_subjects (tuition_id, subject_id) select '00000000-0000-4000-8000-0000000000a1'::uuid, id from subjects;

insert into subjects (name, sort_order)
select x.name, x.ord
  from (values ('Physics', 10), ('Chemistry', 11), ('Biology', 12), ('English', 13), ('Hindi', 14),
               ('Tamil', 15), ('Social Science', 16), ('Computer Science', 17)) as x(name, ord)
 where not exists (select 1 from subjects s where s.tuition_id is null and lower(s.name) = lower(x.name));

alter table subjects drop constraint subjects_name_key;
create unique index subjects_name_idx on subjects (coalesce(tuition_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));

-- ------------------------------------------------------------------ what a tuition owns

alter table chapters  add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
alter table questions add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
alter table papers    add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
alter table tests     add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
create index chapters_tuition_idx  on chapters(tuition_id, class_level, subject_id);
create index questions_tuition_idx on questions(tuition_id, class_level, subject_id);
create index papers_tuition_idx    on papers(tuition_id, created_at desc);
create index tests_tuition_idx     on tests(tuition_id, status);

alter table chapters drop constraint chapters_class_subject_name_key;
alter table chapters add constraint chapters_tuition_class_subject_name_key unique (tuition_id, class_level, subject_id, name);

-- The subjects a student studies in a tuition: with the student's class there, they make the groups.
alter table student_subjects add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
alter table student_subjects drop constraint student_subjects_pkey;
alter table student_subjects add primary key (tuition_id, student_id, subject_id);

-- The evening summary goes out once a day to each tuition's tutors.
alter table daily_summaries add column tuition_id uuid not null default '00000000-0000-4000-8000-0000000000a1' references tuitions(id) on delete cascade;
alter table daily_summaries drop constraint daily_summaries_pkey;
alter table daily_summaries add primary key (day, tuition_id);

-- Which tuition an AI call was for, so its cost can be told per tuition.
alter table ai_usage add column tuition_id uuid references tuitions(id) on delete set null;
update ai_usage set tuition_id = '00000000-0000-4000-8000-0000000000a1';
create index ai_usage_tuition_idx on ai_usage(tuition_id, created_at);

-- ------------------------------------------------------------------ groups
-- A group is a class with a subject inside a tuition ("10th Science"). Its students are the tuition's
-- students of that class who study that subject. A group exists on its own, so a new tutor can set
-- theirs up before any student is added.

create table groups (
  id           uuid primary key default gen_random_uuid(),
  tuition_id   uuid not null references tuitions(id) on delete cascade,
  class_level  smallint not null check (class_level between 6 and 12),
  subject_id   uuid not null references subjects(id) on delete cascade,
  created_at   timestamptz not null default now(),
  unique (tuition_id, class_level, subject_id)
);

insert into groups (tuition_id, class_level, subject_id)
select '00000000-0000-4000-8000-0000000000a1'::uuid, m.class_level, ss.subject_id
  from student_subjects ss join memberships m on m.user_id = ss.student_id and m.tuition_id = ss.tuition_id and m.role = 'student'
union
select '00000000-0000-4000-8000-0000000000a1'::uuid, t.class_level, t.subject_id from tests t;

-- ------------------------------------------------------------------ signing up and joining

-- Joining a tuition with its code: failed tries are counted so a code cannot be guessed.
create table join_attempts (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references users(id) on delete cascade,
  at       timestamptz not null default now(),
  ok       boolean not null
);
create index join_attempts_user_idx on join_attempts(user_id, at desc);

-- New tutors sign themselves up; the login history records it.
alter table auth_events drop constraint auth_events_outcome_check;
alter table auth_events add constraint auth_events_outcome_check
  check (outcome in ('ok', 'wrong_secret', 'lockout', 'locked', 'inactive', 'unknown_user', 'signup'));
