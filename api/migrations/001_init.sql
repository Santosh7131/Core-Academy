-- Core Academy schema. Applied by tools/migrate.ts.
-- Every row the seed adds carries is_sample = true so "delete sample data" can remove it.

create table schools (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  is_sample   boolean not null default false,
  created_at  timestamptz not null default now()
);

create table users (
  id             uuid primary key default gen_random_uuid(),
  role           text not null check (role in ('teacher', 'student')),
  username       text not null unique check (username ~ '^[a-z0-9._]{3,24}$'),
  display_name   text not null check (length(trim(display_name)) > 0),
  class_level    smallint check (class_level between 6 and 12),
  school_id      uuid references schools(id) on delete set null,
  secret_hash    text not null,          -- PBKDF2 of the PIN (student) or password (teacher)
  secret_salt    text not null,
  active         boolean not null default true,
  failed_count   int not null default 0,
  locked_until   timestamptz,
  last_seen_at   timestamptz,
  is_sample      boolean not null default false,
  created_at     timestamptz not null default now(),
  check ((role = 'student') = (class_level is not null))
);

create table sessions (
  token_hash    text primary key,        -- sha256 of the opaque bearer token
  user_id       uuid not null references users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now(),
  expires_at    timestamptz not null
);
create index sessions_user_idx on sessions(user_id);

create table chapters (
  id           uuid primary key default gen_random_uuid(),
  class_level  smallint not null check (class_level between 6 and 12),
  name         text not null check (length(trim(name)) > 0),
  sort_order   int not null default 0,
  is_sample    boolean not null default false,
  unique (class_level, name)
);

create table papers (
  id           uuid primary key default gen_random_uuid(),
  school_id    uuid references schools(id) on delete set null,
  class_level  smallint not null check (class_level between 6 and 12),
  exam_name    text not null,
  year         smallint check (year between 2000 and 2100),
  page_count   int not null default 0,
  uploaded_by  uuid references users(id) on delete set null,
  is_sample    boolean not null default false,
  created_at   timestamptz not null default now()
);

create table paper_pages (
  id          uuid primary key default gen_random_uuid(),
  paper_id    uuid not null references papers(id) on delete cascade,
  page_no     int not null check (page_no >= 1),
  object_key  text not null,
  uploaded    boolean not null default false,
  ai_status   text not null default 'pending' check (ai_status in ('pending', 'reading', 'done', 'failed')),
  ai_error    text,
  read_at     timestamptz,
  unique (paper_id, page_no)
);

create table questions (
  id                 uuid primary key default gen_random_uuid(),
  class_level        smallint not null check (class_level between 6 and 12),
  chapter_id         uuid references chapters(id) on delete set null,
  text               text not null check (length(trim(text)) > 0),
  options            text[] not null check (array_length(options, 1) = 4),
  correct_option     smallint not null check (correct_option between 0 and 3),
  solution           text,
  marks              numeric(4,1) not null default 1 check (marks > 0),
  keep_option_order  boolean not null default false,  -- e.g. "Both (a) and (b)" must not be shuffled
  image_key          text,
  source             text not null default 'manual' check (source in ('manual', 'paper')),
  paper_id           uuid references papers(id) on delete set null,
  created_by         uuid references users(id) on delete set null,
  is_sample          boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index questions_class_idx on questions(class_level, chapter_id);

-- AI-read questions waiting for the teacher to check them.
create table paper_drafts (
  id               uuid primary key default gen_random_uuid(),
  paper_id         uuid not null references papers(id) on delete cascade,
  page_no          int not null,
  seq              int not null,
  number_label     text,                 -- the question number as printed
  kind             text not null check (kind in ('mcq', 'other')),
  text             text not null,
  options          text[],
  correct_option   smallint check (correct_option between 0 and 3),   -- set by the teacher, never by AI
  chapter_id       uuid references chapters(id) on delete set null,
  ai_chapter_guess text,
  needs_diagram    boolean not null default false,
  image_key        text,
  status           text not null default 'draft' check (status in ('draft', 'saved', 'discarded')),
  question_id      uuid references questions(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index paper_drafts_paper_idx on paper_drafts(paper_id, page_no, seq);

create table tests (
  id              uuid primary key default gen_random_uuid(),
  title           text not null check (length(trim(title)) > 0),
  class_level     smallint not null check (class_level between 6 and 12),
  time_limit_min  int check (time_limit_min between 1 and 300),
  opens_at        timestamptz,
  closes_at       timestamptz,
  shuffle         boolean not null default true,
  assign_all      boolean not null default true,   -- whole class, or only test_students
  status          text not null default 'draft' check (status in ('draft', 'published')),
  created_by      uuid references users(id) on delete set null,
  is_sample       boolean not null default false,
  created_at      timestamptz not null default now(),
  check (opens_at is null or closes_at is null or opens_at < closes_at)
);

create table test_questions (
  test_id      uuid not null references tests(id) on delete cascade,
  question_id  uuid not null references questions(id) on delete restrict,
  position     int not null,
  primary key (test_id, question_id)
);

create table test_students (
  test_id     uuid not null references tests(id) on delete cascade,
  student_id  uuid not null references users(id) on delete cascade,
  primary key (test_id, student_id)
);

create table attempts (
  id              uuid primary key default gen_random_uuid(),
  test_id         uuid not null references tests(id) on delete cascade,
  student_id      uuid not null references users(id) on delete cascade,
  attempt_no      int not null default 1,
  started_at      timestamptz not null default now(),
  deadline_at     timestamptz,                 -- null: no time limit and no closing time
  submitted_at    timestamptz,
  auto_submitted  boolean not null default false,
  question_order  uuid[] not null,
  option_orders   jsonb not null,              -- { question_id: [original option index per display slot] }
  score           numeric(6,1),
  max_score       numeric(6,1),
  correct_count   int,
  wrong_count     int,
  skipped_count   int,
  unique (test_id, student_id, attempt_no)
);
create index attempts_student_idx on attempts(student_id);
create index attempts_open_idx on attempts(deadline_at) where submitted_at is null;

create table answers (
  attempt_id     uuid not null references attempts(id) on delete cascade,
  question_id    uuid not null references questions(id) on delete cascade,
  chosen_option  smallint check (chosen_option between 0 and 3),   -- original option index
  flagged        boolean not null default false,
  answered_at    timestamptz not null default now(),
  is_correct     boolean,
  primary key (attempt_id, question_id)
);

create table retake_grants (
  id          uuid primary key default gen_random_uuid(),
  test_id     uuid not null references tests(id) on delete cascade,
  student_id  uuid not null references users(id) on delete cascade,
  granted_at  timestamptz not null default now(),
  used_at     timestamptz
);

create table ai_usage (
  id                 bigint generated always as identity primary key,
  user_id            uuid references users(id) on delete set null,
  task               text not null,
  model              text not null,
  key_slot           int,
  prompt_tokens      int,
  completion_tokens  int,
  ok                 boolean not null,
  error              text,
  ms                 int,
  created_at         timestamptz not null default now()
);

create table app_settings (
  key    text primary key,
  value  jsonb not null
);
insert into app_settings (key, value) values ('tuition_name', '"Core Academy"');

-- Grades one attempt from its saved answers. Idempotent.
create function grade_attempt(p_attempt uuid) returns void
language sql as $$
  update answers a
     set is_correct = (a.chosen_option is not null and a.chosen_option = q.correct_option)
    from questions q
   where a.attempt_id = p_attempt and q.id = a.question_id;

  update attempts t
     set score         = s.score,
         max_score     = s.max_score,
         correct_count = s.correct,
         wrong_count   = s.wrong,
         skipped_count = s.skipped
    from (
      select coalesce(sum(case when a.chosen_option = q.correct_option then q.marks else 0 end), 0) as score,
             coalesce(sum(q.marks), 0)                                                            as max_score,
             count(*) filter (where a.chosen_option = q.correct_option)                           as correct,
             count(*) filter (where a.chosen_option is not null and a.chosen_option <> q.correct_option) as wrong,
             count(*) filter (where a.chosen_option is null)                                      as skipped
        from attempts x
        cross join lateral unnest(x.question_order) as qo(qid)
        join questions q on q.id = qo.qid
        left join answers a on a.attempt_id = x.id and a.question_id = q.id
       where x.id = p_attempt
    ) s
   where t.id = p_attempt;
$$;

-- Submits and grades every attempt whose deadline (plus a 30 s grace) has passed.
create function finalize_expired_attempts() returns int
language plpgsql as $$
declare
  r record;
  n int := 0;
begin
  for r in
    update attempts
       set submitted_at = deadline_at, auto_submitted = true
     where submitted_at is null
       and deadline_at is not null
       and now() > deadline_at + interval '30 seconds'
    returning id
  loop
    perform grade_attempt(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
