-- Library: files a tutor puts on the shelf of a group or a course, for its people to read and download (app 1.8.0).
--
-- A section is a titled box on that shelf ("PDFs", "Books", "Test papers"). It belongs to exactly one group or exactly one
-- course. A file belongs to one section, and is a PDF or a photo of up to 100 MB. The bytes live in object storage under
-- library/<tuition>/<uuid>.<ext>; this table only says what the object is and who may see it. A file is `uploading` from the
-- moment the tutor's phone asks to send it until the server has seen all of it arrive, and students see `ready` files only.
-- Large files go up in parts (a multipart upload), so upload_id holds the storage's id for the upload that is in progress.
--
-- The tables are called class_sections and class_files, not library_*, because 003_library.sql already gave "library" another
-- meaning (the ready-made questions), and nothing of that is part of this.
--
-- Only adds tables, so the API from before keeps working against it: run it before the API that knows the Library is deployed.

create table class_sections (
  id          uuid primary key default gen_random_uuid(),
  tuition_id  uuid not null references tuitions(id) on delete cascade,
  group_id    uuid references groups(id) on delete cascade,
  course_id   uuid references courses(id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 40),
  position    integer not null default 0,
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz not null default now(),
  check ((group_id is null) <> (course_id is null))
);
create unique index class_sections_group_name  on class_sections (group_id,  lower(name)) where group_id  is not null;
create unique index class_sections_course_name on class_sections (course_id, lower(name)) where course_id is not null;
create index class_sections_tuition_idx on class_sections (tuition_id);

create table class_files (
  id            uuid primary key default gen_random_uuid(),
  section_id    uuid not null references class_sections(id) on delete cascade,
  tuition_id    uuid not null references tuitions(id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 120),
  kind          text not null check (kind in ('pdf', 'photo')),
  content_type  text not null,
  size_bytes    bigint not null check (size_bytes between 1 and 104857600),
  object_key    text not null unique,
  upload_id     text,
  status        text not null default 'uploading' check (status in ('uploading', 'ready')),
  created_by    uuid references users(id) on delete set null,
  created_at    timestamptz not null default now(),
  ready_at      timestamptz
);
create index class_files_section_idx on class_files (section_id, created_at);
create index class_files_tuition_idx on class_files (tuition_id, status);
