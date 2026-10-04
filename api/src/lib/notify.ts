import { ASSIGNED_CTE } from './attempts.ts';
import { q, q1, tx } from './db.ts';
import { pushConfigured, pushToUsers } from './push.ts';
import { putObject, readObject } from './storage.ts';

// What students and the teacher are told, and when:
//   - a new test, as soon as it opens (straight away when it is published already open);
//   - a reminder, an hour before a test closes, to students who have not started it;
//   - the teacher's summary of the day at 8 pm.
//
// Neon's trigger calls /cron/notify every five minutes, but the database is only woken when one
// of these is due. The time of the next one is kept in a small object in the bucket, and every
// run that touches the database writes it again. Waking the 0.25 CU compute every five minutes
// would keep it running all month: 186 compute-hours, against the free plan's 100.

const NEXT_KEY = 'notify/next.json';
const REMIND_MIN = 60;
const SUMMARY_AT = '20:00';
const IST = 'Asia/Kolkata';

// ---------------------------------------------------------------- wording

const IST_OFFSET = 330 * 60_000; // India has no daylight saving
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const ist = (d: Date) => new Date(d.getTime() + IST_OFFSET);
const dayNo = (d: Date) => Math.floor(ist(d).getTime() / 86_400_000);

function clock(d: Date) {
  const t = ist(d);
  const h = t.getUTCHours();
  return `${h % 12 || 12}:${String(t.getUTCMinutes()).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
}

/** "today 9:00 pm", "tomorrow 9:00 pm", "Tue 6 Oct, 9:00 pm": the app's own wording. */
export function when(d: Date, now: Date) {
  const diff = dayNo(d) - dayNo(now);
  if (diff === 0) return `today ${clock(d)}`;
  if (diff === 1) return `tomorrow ${clock(d)}`;
  const t = ist(d);
  return `${DAYS[t.getUTCDay()]} ${t.getUTCDate()} ${MONTHS[t.getUTCMonth()]}, ${clock(d)}`;
}

const count = (n: number, one: string) => `${n} ${n === 1 ? one : `${one}s`}`;

// ---------------------------------------------------------------- jobs

type Sent = { title: string; people: number; phones: number };

/** Tells students about tests that have opened. Each test is claimed once, so it is told once. */
async function announce(now: Date): Promise<Sent[]> {
  const tests = await q<{ id: string; title: string; time_limit_min: number | null; closes_at: Date | null; questions: number }>(
    `update tests set announced_at = now()
      where status = 'published' and announced_at is null
        and (opens_at is null or opens_at <= now()) and (closes_at is null or closes_at > now())
      returning id, title, time_limit_min, closes_at,
                (select count(*) from test_questions tq where tq.test_id = tests.id) as questions`,
  );
  const out: Sent[] = [];
  for (const t of tests) {
    if (t.closes_at && t.closes_at.getTime() - now.getTime() < 5 * 60_000) continue; // closing anyway
    const people = await q<{ student_id: string }>(`with ${ASSIGNED_CTE} select student_id from assigned where test_id = $1`, [t.id]);
    const facts = [count(t.questions, 'question')];
    if (t.time_limit_min) facts.push(`${t.time_limit_min} min`);
    if (t.closes_at) facts.push(`closes ${when(t.closes_at, now)}`);
    const phones = await pushToUsers(people.map((p) => p.student_id), { title: t.title, body: `New test · ${facts.join(' · ')}` });
    out.push({ title: t.title, people: people.length, phones });
  }
  return out;
}

/**
 * An hour before a test closes, reminds the students who have not started it. Only for tests
 * students have known about for two hours or more: for a shorter window, the announcement has
 * just told them when it closes.
 */
async function remind(now: Date): Promise<Sent[]> {
  const tests = await q<{ id: string; title: string; closes_at: Date }>(
    `update tests set reminded_at = now()
      where status = 'published' and reminded_at is null
        and announced_at is not null and announced_at <= closes_at - interval '2 hours'
        and closes_at > now() and closes_at <= now() + make_interval(mins => $1)
      returning id, title, closes_at`,
    [REMIND_MIN],
  );
  const out: Sent[] = [];
  for (const t of tests) {
    const people = await q<{ student_id: string }>(
      `with ${ASSIGNED_CTE}
       select a.student_id from assigned a
        where a.test_id = $1
          and not exists (select 1 from attempts x where x.test_id = a.test_id and x.student_id = a.student_id)`,
      [t.id],
    );
    const body = `Closes ${when(t.closes_at, now)}. You have not started it yet.`;
    const phones = await pushToUsers(people.map((p) => p.student_id), { title: t.title, body });
    out.push({ title: t.title, people: people.length, phones });
  }
  return out;
}

/** From 8 pm, once a day: what was written today and who missed a test that closed today. */
async function summarise(): Promise<{ body: string; phones: number } | null> {
  const day = await q1(
    `insert into daily_summaries (day)
     select (now() at time zone '${IST}')::date where (now() at time zone '${IST}')::time >= $1::time
     on conflict do nothing returning day`,
    [SUMMARY_AT],
  );
  if (!day) return null;
  await q('select finalize_expired_attempts()');
  const s = await q1<{ written: number; students: number; avg: number | null; missed: number }>(
    `with ${ASSIGNED_CTE},
          d as (select date_trunc('day', now() at time zone '${IST}') at time zone '${IST}' as d0)
     select (select count(*) from attempts x, d where x.submitted_at >= d.d0) as written,
            (select count(distinct x.student_id) from attempts x, d where x.submitted_at >= d.d0) as students,
            (select avg(x.score / x.max_score) from attempts x, d where x.submitted_at >= d.d0 and x.max_score > 0) as avg,
            (select count(distinct a.student_id) from assigned a join tests t on t.id = a.test_id, d
              where t.closes_at >= d.d0 and t.closes_at <= now()
                and not exists (select 1 from attempts x
                                 where x.test_id = t.id and x.student_id = a.student_id and x.submitted_at is not null)) as missed`,
  );
  if (!s || (s.written === 0 && s.missed === 0)) return { body: 'Nothing to report.', phones: 0 };
  const lines = [];
  if (s.written > 0) {
    const avg = s.avg === null ? '' : `, average ${Math.round(s.avg * 100)}%`;
    lines.push(`${count(s.students, 'student')} wrote ${count(s.written, 'test')} today${avg}.`);
  } else {
    lines.push('No tests were written today.');
  }
  if (s.missed > 0) lines.push(`${count(s.missed, 'student')} missed a test that closed today.`);
  const body = lines.join(' ');
  const teachers = await q<{ id: string }>(`select id from users where role = 'teacher' and active`);
  return { body, phones: await pushToUsers(teachers.map((t) => t.id), { title: "Today's tests", body }) };
}

// ---------------------------------------------------------------- schedule

/** Works out when the next notification is due and writes it to the bucket. */
async function planNext(): Promise<Date> {
  return tx(async (c) => {
    // One planner at a time, so a slower run cannot overwrite a newer plan with an older one.
    await c.query(`select pg_advisory_xact_lock(hashtext('notify-plan'))`);
    const r = await q1<{ due: Date }>(
      `select least(
         (select min(coalesce(opens_at, now())) from tests
           where status = 'published' and announced_at is null and (closes_at is null or closes_at > now())),
         (select min(closes_at - make_interval(mins => $1)) from tests
           where status = 'published' and reminded_at is null and announced_at is not null
             and announced_at <= closes_at - interval '2 hours' and closes_at > now()),
         ((now() at time zone '${IST}')::date
            + (select count(*)::int from daily_summaries where day = (now() at time zone '${IST}')::date)
            + $2::time) at time zone '${IST}'
       ) as due`,
      [REMIND_MIN, SUMMARY_AT],
      c,
    );
    await putObject(NEXT_KEY, Buffer.from(JSON.stringify({ due: r!.due })), 'application/json');
    return r!.due;
  });
}

async function readDue(): Promise<Date | null> {
  try {
    const due = new Date(JSON.parse((await readObject(NEXT_KEY)).bytes.toString('utf8')).due);
    return Number.isNaN(due.getTime()) ? null : due;
  } catch {
    return null; // missing or unreadable: ask the database
  }
}

/** The scheduled run. Without Firebase set up it does nothing at all. */
export async function runIfDue(now = new Date()) {
  if (!pushConfigured()) return { push: false };
  const due = await readDue();
  if (due && now < due) return { push: true, ran: false, due };
  const announced = await announce(now);
  const reminded = await remind(now);
  const summary = await summarise();
  return { push: true, ran: true, announced, reminded, summary, next: await planNext() };
}

/** After a test is published or its times change: announce it if it is open, and re-plan. */
export async function afterTestChange() {
  if (!pushConfigured()) return;
  try {
    await announce(new Date());
    await planNext();
  } catch (e) {
    console.error(e);
  }
}
