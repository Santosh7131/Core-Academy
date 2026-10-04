// Imports the ready-made question library (tools/library) into a branch: each book's subject and
// chapters, its questions (source 'library'), and one draft chapter test per chapter that goes to
// the class's group for that subject. Safe to run again: rows are matched by library_key, and a
// chapter test the teacher has already published or edited is left alone.
// Usage: node tools/seed-library.ts [--env .env.local] [--class 10] [--subject Maths] [--allow-main]
import { createHash } from 'node:crypto';
import pg from 'pg';
import { arrange, books } from './library/index.ts';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
const branch = process.env.NEON_BRANCH ?? 'unknown';
if (branch === 'main' && !args.includes('--allow-main')) {
  throw new Error('Refusing to change the live (main) branch without --allow-main.');
}
const onlyClass = arg('--class') ? Number(arg('--class')) : null;
const onlySubject = arg('--subject')?.toLowerCase() ?? null;

const key = (...parts: (string | number)[]) => createHash('sha256').update(parts.join('|')).digest('hex').slice(0, 24);

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL });
await db.connect();
const q1 = async (sql: string, params: unknown[] = []) => (await db.query(sql, params)).rows[0];

try {
  const teacher = await q1(`select id from users where role = 'teacher' order by created_at limit 1`);
  if (!teacher) throw new Error(`Branch ${branch} has no teacher yet.`);
  let questions = 0;
  let tests = 0;
  let testsKept = 0;
  // The Tests screen lists newest first. Each chapter test is made one second older than the
  // one before it, so the drafts read in book order: Class 7 chapter 1, chapter 2, …
  let order = 0;
  await db.query('begin');
  for (const book of books) {
    if (onlyClass && book.classLevel !== onlyClass) continue;
    if (onlySubject && book.subject.toLowerCase() !== onlySubject) continue;
    const subject =
      (await q1('select id from subjects where lower(name) = lower($1)', [book.subject])) ??
      (await q1(`insert into subjects (name, sort_order) values ($1, (select coalesce(max(sort_order) + 1, 0) from subjects)) returning id`, [book.subject]));

    for (const [ci, chapter] of book.chapters.entries()) {
      const ch = await q1(
        `insert into chapters (class_level, subject_id, name, sort_order) values ($1, $2, $3, $4)
         on conflict (class_level, subject_id, name) do update set sort_order = excluded.sort_order returning id`,
        [book.classLevel, subject.id, chapter.name, ci],
      );
      const ids: string[] = [];
      for (const qq of chapter.questions) {
        const { options, correct } = arrange(qq);
        const row = await q1(
          `insert into questions (class_level, chapter_id, subject_id, text, options, correct_option, solution, marks, source, library_key, created_by)
           values ($1, $2, $3, $4, $5, $6, $7, 1, 'library', $8, $9)
           on conflict (library_key) do update set chapter_id = excluded.chapter_id, subject_id = excluded.subject_id, text = excluded.text,
             options = excluded.options, correct_option = excluded.correct_option, solution = excluded.solution, updated_at = now()
           returning id`,
          [book.classLevel, ch.id, subject.id, qq.text, options, correct, qq.solution,
            key('question', book.classLevel, book.subject, chapter.name, qq.text), teacher.id],
        );
        ids.push(row.id);
        questions++;
      }

      // One draft test per chapter, for the class's group in this subject. A draft keeps its
      // questions in step with the library; once published or written it is the teacher's.
      const testKey = key('chapter-test', book.classLevel, book.subject, chapter.name);
      const existing = await q1(
        `select t.id, t.status, (select count(*) from attempts a where a.test_id = t.id)::int as attempts from tests t where t.library_key = $1`,
        [testKey],
      );
      const age = order++;
      if (existing && (existing.status !== 'draft' || existing.attempts > 0)) {
        testsKept++;
        continue;
      }
      const test = existing ?? await q1(
        `insert into tests (title, class_level, subject_id, time_limit_min, shuffle, assign_all, assign_group, status, created_by, library_key)
         values ($1, $2, $3, $4, true, false, true, 'draft', $5, $6) returning id`,
        [`${chapter.name}: chapter test`, book.classLevel, subject.id, Math.max(10, Math.ceil(chapter.questions.length * 1.5)), teacher.id, testKey],
      );
      await db.query(`update tests set created_at = now() - make_interval(secs => $2) where id = $1`, [test.id, age]);
      await db.query('delete from test_questions where test_id = $1', [test.id]);
      await db.query(
        `insert into test_questions (test_id, question_id, position) select $1, x.id, x.ord from unnest($2::uuid[]) with ordinality as x(id, ord)`,
        [test.id, ids],
      );
      tests++;
    }
    console.log(`Class ${book.classLevel} ${book.subject}: ${book.chapters.length} chapters`);
  }
  await db.query('commit');
  console.log(`branch ${branch}: ${questions} questions and ${tests} draft chapter tests in place${testsKept ? `, ${testsKept} published tests left as they are` : ''}`);
} catch (e) {
  await db.query('rollback');
  throw e;
} finally {
  await db.end();
}
