import { assignedCte, EVERYONE_DONE, TEST_COUNTS } from './attempts.ts';
import { tq } from './db.ts';

/**
 * The tests that finished most lately, for the tutor's Home: those past their closing time and those every
 * student has handed in. A group's and a course's tests are mixed, newest first; a course's carries its name
 * and a group's its class and subject. Posted tests and those still open are the Home's own lists.
 */
export async function recentFinished(tuition: string, limit = 5) {
  return tq<any>(
    tuition,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.class_level, t.subject_id, (select name from subjects where id = t.subject_id) as subject,
            t.course_id, (select name from courses where id = t.course_id) as course,
            t.closes_at, ${TEST_COUNTS}
       from tests t
      where t.tuition_id = @T and t.status = 'published' and (t.opens_at is null or t.opens_at <= now())
        and not (exists (select 1 from attempts x where x.test_id = t.id and x.submitted_at is null
                          and (x.deadline_at is null or x.deadline_at > now()))
                 or ((t.closes_at is null or t.closes_at > now()) and not ${EVERYONE_DONE}))
      order by least(coalesce(t.closes_at, now()), now()) desc, t.created_at desc
      limit $1`,
    [limit],
  );
}

/**
 * The papers the tutor started in the last 30 days and has not finished, so Home can take her back to them: a
 * paper with a page AI has not read, with questions still to check, or with questions saved but no test made from it.
 * A paper the tutor has finished with (every question saved or skipped, or a test made) is not listed.
 */
export async function papersToFinish(tuition: string, limit = 20) {
  return tq<any>(
    tuition,
    `select * from (
       select p.id, p.exam_name, p.class_level, p.subject_id, (select name from subjects where id = p.subject_id) as subject,
              p.course_id, (select name from courses where id = p.course_id) as course, p.page_count, p.created_at,
              (select count(*) from paper_pages pp where pp.paper_id = p.id and pp.ai_status = 'done') as pages_read,
              (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'draft' and d.kind = 'mcq') as to_check,
              (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved,
              exists (select 1 from tests x where x.paper_id = p.id) as has_test
         from papers p
        where p.tuition_id = @T and p.created_at > now() - interval '30 days'
     ) q
      where q.to_check > 0 or q.pages_read < q.page_count or (q.saved > 0 and not q.has_test)
      order by q.created_at desc
      limit $1`,
    [limit],
  );
}
