import { assignedCte, EVERYONE_DONE } from './attempts.ts';
import { tq, tq1, tx, type Db } from './db.ts';
import { HttpError, notFound } from './http.ts';

// A test left open for a week (app 1.8.0, 026_test_week_warning.sql). The tutor is told by a notification (lib/notify.ts) and by a warning
// on Home, and can close the test or remind the students who have not handed it in. Only the reminder tells students anything.

/** A test is warned about once it has been open this many days. */
export const STALE_DAYS = 7;

/** After the tutor reminds the students, the warning stays away this many days. */
const QUIET_DAYS = 7;

/** A test that closes within this is left alone: it is about to close by itself. */
const CLOSING_SOON = '1 day';

/** Students still writing when a test is closed from Home get this long to finish, not what is left of the old closing time. */
export const CLOSE_GRACE_MIN = 10;

const POSTED = 'coalesce(t.published_at, t.created_at)';

/** SQL: when the test became open to its students, which is its opening time, or when it was posted if that came later. Needs `t`. */
export const OPENED = `greatest(coalesce(t.opens_at, ${POSTED}), ${POSTED})`;

/** SQL condition: the test is posted, has been open a week, still has time to run, and someone has not handed it in. Needs `t` and the `assigned` CTE. */
export const STALE = `t.status = 'published' and ${OPENED} <= now() - interval '${STALE_DAYS} days'
  and (t.closes_at is null or t.closes_at > now() + interval '${CLOSING_SOON}')
  and not ${EVERYONE_DONE}
  and (t.nudged_at is null or t.nudged_at <= now() - interval '${QUIET_DAYS} days')`;

/** SQL: how many students the test was given to have not handed it in. Needs `t` and the `assigned` CTE. */
export const WAITING = `(select count(*) from assigned a where a.test_id = t.id
    and not exists (select 1 from attempts x where x.test_id = t.id and x.student_id = a.student_id and x.submitted_at is not null))`;

/** The tests of a tuition that have been open a week, oldest first: what the warning on Home lists. */
export async function staleTests(tuition: string) {
  return tq<any>(
    tuition,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.class_level, t.subject_id, (select name from subjects where id = t.subject_id) as subject,
            t.course_id, (select name from courses where id = t.course_id) as course,
            ${OPENED} as opened_at, floor(extract(epoch from now() - ${OPENED}) / 86400)::int as days_open, t.closes_at,
            (select count(*) from assigned a where a.test_id = t.id) as assigned, ${WAITING} as waiting
       from tests t
      where t.tuition_id = @T and ${STALE}
      order by ${OPENED}, t.title`,
  );
}

/**
 * Closes a test now: nobody can start it, and a student who is still writing has CLOSE_GRACE_MIN minutes left (or less, if their own
 * time ends sooner). Only a test that is posted, open and has time left can be closed.
 */
export async function closeTest(tuition: string, id: string) {
  return tx(async (cx) => {
    const t = await tq1<{ status: string; opens_at: Date | null; closes_at: Date | null; now: Date }>(
      tuition,
      'select status, opens_at, closes_at, now() as now from tests where id = $1 and tuition_id = @T for update',
      [id],
      cx,
    );
    if (!t) throw notFound('This test');
    if (t.status !== 'published') throw new HttpError(409, 'not_posted', 'This test is not posted, so there is nothing to close.');
    if (t.opens_at && t.opens_at > t.now) throw new HttpError(409, 'not_open', 'This test has not opened yet. Take it down instead.');
    if (t.closes_at && t.closes_at <= t.now) throw new HttpError(409, 'already_closed', 'This test has already closed.');
    // A test cannot close before it opens: one that opened this very second closes a second later.
    const row = (
      await cx.query(
        `update tests set closes_at = case when opens_at is not null and opens_at >= now() - interval '1 second' then opens_at + interval '1 second' else now() end
          where id = $1 returning id, closes_at`,
        [id],
      )
    ).rows[0];
    await cx.query(
      `update attempts set deadline_at = least(deadline_at, now() + make_interval(mins => $2))
        where test_id = $1 and submitted_at is null and (deadline_at is null or deadline_at > now() + make_interval(mins => $2))`,
      [id, CLOSE_GRACE_MIN],
    );
    return row as { id: string; closes_at: Date };
  });
}

/**
 * Takes the tutor's go at reminding the students: stamps nudged_at, but only when the students have not been reminded in the last day,
 * so a double tap (or two tutors) cannot send the notice twice. Returns the test, or throws why not.
 */
export async function claimReminder(tuition: string, id: string, db?: Db) {
  const t = await tq1<{ title: string; status: string; opens_at: Date | null; closes_at: Date | null; now: Date }>(
    tuition,
    'select title, status, opens_at, closes_at, now() as now from tests where id = $1 and tuition_id = @T',
    [id],
    db,
  );
  if (!t) throw notFound('This test');
  if (t.status !== 'published' || (t.opens_at && t.opens_at > t.now) || (t.closes_at && t.closes_at <= t.now)) {
    throw new HttpError(409, 'not_open', 'This test is not open, so there is nobody to remind.');
  }
  const claimed = await tq1(
    tuition,
    `update tests set nudged_at = now() where id = $1 and tuition_id = @T and (nudged_at is null or nudged_at <= now() - interval '1 day') returning id`,
    [id],
    db,
  );
  if (!claimed) throw new HttpError(409, 'just_reminded', 'You reminded the students about this test less than a day ago. Try again tomorrow.');
  return t;
}
