import { bad, uuid } from './http.ts';

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
