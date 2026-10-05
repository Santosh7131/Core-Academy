-- Who has been told about which test. A student is told once per test, the moment it is open for
-- them: when it is published, or later if they join its group or are added to it.
create table test_notices (
  test_id     uuid not null references tests(id) on delete cascade,
  student_id  uuid not null references users(id) on delete cascade,
  at          timestamptz not null default now(),
  primary key (test_id, student_id)
);

-- Tests already published count as told, so turning notifications on does not send everyone a
-- message about old tests. Only tests published from now on are announced.
update tests set announced_at = coalesce(announced_at, now()) where status = 'published';
insert into test_notices (test_id, student_id)
select t.id, u.id
  from tests t join users u on u.role = 'student' and u.class_level = t.class_level
 where t.status = 'published' and (t.assign_all or t.assign_group)
   and exists (select 1 from student_subjects ss where ss.student_id = u.id and ss.subject_id = t.subject_id)
union
select ts.test_id, ts.student_id from test_students ts join tests t on t.id = ts.test_id where t.status = 'published'
on conflict do nothing;
