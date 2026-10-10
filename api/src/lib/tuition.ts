import { randomInt, randomUUID } from 'node:crypto';
import { pool, q1, tq, tq1, type Db } from './db.ts';
import { bad, HttpError } from './http.ts';
import { MATHS } from './subjects.ts';

/** The tuition every row that existed was given when tuitions arrived (012_tuitions.sql). */
export const FIRST_TUITION = '00000000-0000-4000-8000-0000000000a1';

// Join codes: six characters with no 0, O, 1 or I, so they survive being read out or typed from a message.
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export function newJoinCode(): string {
  return Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(0, CODE_ALPHABET.length)]).join('');
}

export async function freeJoinCode(db: Db = pool): Promise<string> {
  for (;;) {
    const code = newJoinCode();
    if (!(await q1('select 1 as x from tuitions where join_code = $1', [code], db))) return code;
  }
}

/** A code as typed: any case, with spaces or dashes. */
export function readCode(raw: unknown): string {
  const s = typeof raw === 'string' ? raw.toUpperCase().replace(/[^A-Z0-9]/g, '') : '';
  if (!/^[A-HJ-NP-Z2-9]{6}$/.test(s)) throw bad('That code is not right. It has six letters and numbers.', 'invalid_code');
  return s;
}

/** "KR7-4MQ": how a code is shown. */
export const showCode = (code: string) => `${code.slice(0, 3)}-${code.slice(3)}`;

/** A subject this tuition teaches (a standard one it picked, or one of its own). */
export async function taughtSubject(tuition: string, id: string, db: Db = pool): Promise<{ id: string; name: string }> {
  const s = await tq1<{ id: string; name: string }>(
    tuition,
    `select sj.id, sj.name from subjects sj join tuition_subjects ts on ts.subject_id = sj.id and ts.tuition_id = @T where sj.id = $1`,
    [id],
    db,
  );
  if (!s) throw bad('That subject is not one this tuition teaches.', 'unknown_subject');
  return s;
}

/** Every id must be a subject this tuition teaches. */
export async function taughtSubjectIds(tuition: string, ids: string[], db: Db = pool) {
  if (!ids.length) return;
  const n = await tq1<{ n: number }>(
    tuition,
    `select count(*) as n from tuition_subjects where tuition_id = @T and subject_id = any($1::uuid[])`,
    [ids],
    db,
  );
  if (!n || n.n !== ids.length) throw bad('One of those subjects is not one this tuition teaches.', 'unknown_subject');
}

/**
 * The subject a request that names none means: Maths when the tuition teaches it (the apps from
 * before subjects never send one), else the tuition's first subject.
 */
export async function defaultSubject(tuition: string, db: Db = pool): Promise<string> {
  const s = await tq1<{ id: string }>(
    tuition,
    `select sj.id from tuition_subjects ts join subjects sj on sj.id = ts.subject_id where ts.tuition_id = @T
      order by (sj.id = '${MATHS}') desc, sj.sort_order, sj.name limit 1`,
    [],
    db,
  );
  if (!s) throw bad('Add a subject to this tuition first.', 'no_subjects');
  return s.id;
}

/** A class and subject exist as a group of the tuition from the moment anything is made for them. */
export async function ensureGroup(tuition: string, classLevel: number, subjectId: string, db: Db = pool) {
  await tq(
    tuition,
    `insert into groups (tuition_id, class_level, subject_id) values (@T, $1, $2) on conflict do nothing`,
    [classLevel, subjectId],
    db,
  );
}

/** The tuition's students, by id (an unknown or foreign id is an error, not skipped). */
export async function memberStudents(tuition: string, ids: string[], db: Db = pool) {
  if (!ids.length) return;
  const n = await tq1<{ n: number }>(
    tuition,
    `select count(*) as n from memberships where tuition_id = @T and role = 'student' and status in ('active', 'off') and user_id = any($1::uuid[])`,
    [ids],
    db,
  );
  if (!n || n.n !== ids.length) throw bad('One of those students is not in this tuition.', 'unknown_student');
}

/** The questions must all be this tuition's own: a question id from another tuition is refused. */
export async function ownQuestions(tuition: string, ids: string[], db: Db = pool) {
  if (!ids.length) return;
  const n = await tq1<{ n: number }>(tuition, `select count(*) as n from questions where tuition_id = @T and id = any($1::uuid[])`, [ids], db);
  if (!n || n.n !== ids.length) throw bad('One of those questions is not in this tuition.', 'unknown_question');
}

/** A chapter id the client sent must be one of this tuition's own (null when none was sent). */
export async function ownChapter(tuition: string, id: string | null, db: Db = pool): Promise<string | null> {
  if (!id) return null;
  const ch = await tq1(tuition, 'select 1 as x from chapters where id = $1 and tuition_id = @T', [id], db);
  if (!ch) throw bad('That chapter is not in this tuition.', 'unknown_chapter');
  return id;
}

/** A new key for a question's diagram. It names the tuition, so a key can only ever be used by the tuition it was made for. */
export const newImageKey = (tuition: string) => `questions/${tuition}/${randomUUID()}.jpg`;

/**
 * The image key a client sent for a question or draft. The server made every key it will accept, so a
 * client cannot point a question at someone else's file (a signed link to it would then be handed out):
 * it must be one of this tuition's own, or the one the row already has.
 */
export function ownImageKey(tuition: string, key: unknown, current: string | null = null): string | null {
  if (typeof key !== 'string' || !key) return null;
  if (key === current) return key;
  if (key.startsWith(`questions/${tuition}/`) && /^questions\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.jpg$/i.test(key)) return key;
  throw bad('That picture does not belong to this tuition. Add it again.', 'unknown_image');
}

/** True when the person has an active or waiting place in some other tuition than this one. */
export async function elsewhere(tuition: string, userId: string, db: Db = pool): Promise<boolean> {
  const r = await tq1(
    tuition,
    `select 1 as x from memberships where user_id = $1 and tuition_id <> @T and status in ('active', 'pending')`,
    [userId],
    db,
  );
  return !!r;
}

/**
 * A person's login is on while they have an active or waiting place somewhere. Turning a member off
 * in one tuition turns the login off only when it was their last place.
 */
export async function refreshLogin(userId: string, db: Db = pool): Promise<boolean> {
  const r = await q1<{ active: boolean }>(
    `update users u set active = exists (select 1 from memberships m where m.user_id = u.id and m.status in ('active', 'pending'))
      where u.id = $1 returning u.active`,
    [userId],
    db,
  );
  return r?.active ?? false;
}

export const noTuition = (who: 'teacher' | 'student') =>
  new HttpError(409, 'no_tuition', who === 'teacher' ? 'Create your tuition first.' : 'You have not joined a tuition yet.');
