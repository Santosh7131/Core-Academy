import { assignedCte, EVERYONE_DONE, TEST_COUNTS } from './attempts.ts';
import { pool, tq, tq1, type Db } from './db.ts';
import { notFound } from './http.ts';

/** A course of this tuition, by id. A course of another tuition is not found. */
export async function ownCourse(tuition: string, id: string, db: Db = pool): Promise<{ id: string; name: string }> {
  const co = await tq1<{ id: string; name: string }>(tuition, 'select id, name from courses where id = $1 and tuition_id = @T', [id], db);
  if (!co) throw notFound('This course');
  return co;
}

/** The people of course `co` counted the way a group counts its students: those whose place and login are on. */
export const COURSE_PEOPLE = `(select count(*) from course_members cm
    join memberships m on m.tuition_id = co.tuition_id and m.user_id = cm.student_id and m.role = 'student' and m.status = 'active'
    join users u on u.id = cm.student_id and u.active
   where cm.course_id = co.id)`;

/**
 * Every course of the tuition, each with the tests its people can write now (live) and the ones posted to
 * open later, shaped like a group on the tutor's Home. Courses with something running come first, then the
 * rest, newest first.
 */
export async function courseCards(tuition: string) {
  const courses = await tq<any>(
    tuition,
    `select co.id, co.name, co.created_at, ${COURSE_PEOPLE} as people from courses co where co.tuition_id = @T`,
  );
  const tests = await tq<any>(
    tuition,
    `with ${assignedCte('@T')}
     select t.id, t.course_id, t.title, t.opens_at, t.closes_at, t.time_limit_min, now() as now, ${TEST_COUNTS}
       from tests t
      where t.tuition_id = @T and t.status = 'published' and t.course_id is not null
        and (exists (select 1 from attempts x where x.test_id = t.id and x.submitted_at is null
                      and (x.deadline_at is null or x.deadline_at > now()))
             or ((t.closes_at is null or t.closes_at > now()) and not ${EVERYONE_DONE}))
      order by t.closes_at nulls last, coalesce(t.opens_at, t.created_at) desc`,
  );
  const out = courses.map((co) => ({ id: co.id, name: co.name, created_at: co.created_at, people: Number(co.people), live: [] as any[], posted: [] as any[] }));
  for (const x of tests) {
    const co = out.find((y) => y.id === x.course_id);
    if (!co) continue;
    const { now, course_id, ...row } = x;
    (x.opens_at && x.opens_at > now ? co.posted : co.live).push(row);
  }
  const busy = (co: (typeof out)[number]) => co.live.length + co.posted.length > 0;
  return out.sort((a, b) => Number(busy(b)) - Number(busy(a)) || b.created_at.getTime() - a.created_at.getTime() || a.name.localeCompare(b.name));
}
