import { tq, tq1, tx } from './db.ts';
import { bad, HttpError, notFound, uuid } from './http.ts';

/** Maths: the default subject, with a fixed id (002_subjects.sql). Older app versions never send a subject. */
export const MATHS = '00000000-0000-4000-8000-000000000001';

export function subjectIds(v: unknown): string[] {
  if (!Array.isArray(v)) throw bad('subject_ids must be a list.');
  return [...new Set(v.map((x) => uuid(x, 'subject id')))];
}

/**
 * A student's subjects in one tuition as [{ id, name }], in subject order. Needs `u` for the student
 * row; `tuition` is the SQL that holds the tuition's id ('@T' inside tq()).
 */
export const studentSubjects = (tuition: string) => `coalesce((
  select json_agg(json_build_object('id', sj.id, 'name', sj.name) order by sj.sort_order, sj.name)
    from student_subjects ss join subjects sj on sj.id = ss.subject_id
   where ss.student_id = u.id and ss.tuition_id = ${tuition}), '[]') as subjects`;

/**
 * The tables that hold a subject's id together with a tuition's id: everything a tuition has under a subject. These are all the
 * foreign keys to subjects(id), so a subject moved by moveSubject leaves nothing behind (tools/subjects-test.ts checks the list
 * against the database).
 */
export const BY_SUBJECT = ['chapters', 'questions', 'papers', 'tests', 'groups', 'student_subjects', 'tuition_subjects'] as const;

/**
 * Renames one of a tuition's subjects. A subject the tuition made itself is renamed where it stands. A standard subject (Maths, Science
 * and the rest) is shared by every tuition, so it cannot change for one: the tuition gets a subject of its own with the new name and
 * everything it kept under the old one (chapters, questions, papers, tests, groups, students, the Library shelves of its groups) moves
 * to it in the same step. Nothing changes for any other tuition. No two subjects of a tuition may have the same name.
 */
export async function renameSubject(tuition: string, id: string, name: string): Promise<{ id: string; name: string; sort_order: number }> {
  const duplicate = new HttpError(409, 'duplicate', `${name} is already a subject.`);
  try {
    return await tx(async (cx) => {
      // Locked, so two renames of one subject cannot run over each other.
      const own = await tq1<{ tuition_id: string | null; name: string; sort_order: number }>(
        tuition,
        `select sj.tuition_id, sj.name, sj.sort_order from tuition_subjects ts join subjects sj on sj.id = ts.subject_id
          where ts.tuition_id = @T and ts.subject_id = $1 for update of ts`,
        [id],
        cx,
      );
      if (!own) throw notFound('This subject');
      if (own.name === name) return { id, name: own.name, sort_order: own.sort_order };
      const same = await tq1(
        tuition,
        `select 1 as x from subjects sj join tuition_subjects ts on ts.subject_id = sj.id and ts.tuition_id = @T where lower(sj.name) = lower($1) and sj.id <> $2`,
        [name, id],
        cx,
      );
      if (same) throw duplicate;
      if (own.tuition_id === tuition) {
        return (await tq1(tuition, 'update subjects set name = $2 where id = $1 and tuition_id = @T returning id, name, sort_order', [id, name], cx))!;
      }
      const copy = (await tq1<{ id: string; name: string; sort_order: number }>(
        tuition,
        'insert into subjects (name, sort_order, tuition_id) values ($1, $2, @T) returning id, name, sort_order',
        [name, own.sort_order],
        cx,
      ))!;
      for (const table of BY_SUBJECT) {
        await tq(tuition, `update ${table} set subject_id = $1 where tuition_id = @T and subject_id = $2`, [copy.id, id], cx);
      }
      return copy;
    });
  } catch (e: any) {
    if (e.code === '23505') throw duplicate;
    throw e;
  }
}
