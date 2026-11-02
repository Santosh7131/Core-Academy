import { randomUUID } from 'node:crypto';
import { pool, q, tq, tq1, type Db } from './db.ts';
import { bad, notFound } from './http.ts';
import { abortMultipart, deleteObjects } from './storage.ts';
import { ensureGroup } from './tuition.ts';

// The Library: files a tutor puts on the shelf of a group or a course, for its people to read and download
// (025_class_files.sql). The routes are in routes/library.ts; what they share is here.

/** The most one file may weigh. */
export const MAX_FILE_BYTES = 100 * 1024 * 1024;

/** A file of up to this many bytes goes up in one request; a bigger one goes up in parts of this size (the last may be smaller). */
export const PART_BYTES = 8 * 1024 * 1024;

/** A group or a course has up to this many sections, and a section up to this many files: the pages are lists a person scrolls. */
export const MAX_SECTIONS = 20;
export const MAX_FILES_PER_SECTION = 100;

/** What a whole tuition may keep on its shelves. LIBRARY_QUOTA_BYTES changes it without a new release. */
export const quotaBytes = () => Number(process.env.LIBRARY_QUOTA_BYTES) || 2 * 1024 * 1024 * 1024;

/** An upload nobody finished is thrown away after this long. */
const STALE_UPLOAD = '6 hours';

/** The kinds of file the Library takes: PDFs and photos. */
const TYPES: Record<string, { kind: 'pdf' | 'photo'; ext: string; magic: (b: Buffer) => boolean }> = {
  'application/pdf': { kind: 'pdf', ext: 'pdf', magic: (b) => b.subarray(0, 5).toString('latin1') === '%PDF-' },
  'image/jpeg': { kind: 'photo', ext: 'jpg', magic: (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  'image/png': { kind: 'photo', ext: 'png', magic: (b) => b.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47])) },
  'image/webp': { kind: 'photo', ext: 'webp', magic: (b) => b.subarray(0, 4).toString('latin1') === 'RIFF' && b.subarray(8, 12).toString('latin1') === 'WEBP' },
};

export function fileType(contentType: unknown): { kind: 'pdf' | 'photo'; ext: string; type: string } {
  const type = typeof contentType === 'string' ? contentType.toLowerCase().split(';')[0].trim() : '';
  const t = TYPES[type === 'image/jpg' ? 'image/jpeg' : type];
  if (!t) throw bad('Add a PDF or a photo (JPG, PNG or WebP).', 'unsupported_type');
  return { kind: t.kind, ext: t.ext, type: type === 'image/jpg' ? 'image/jpeg' : type };
}

/** True when the first bytes of the file are what its type says they should be. */
export const looksLike = (contentType: string, head: Buffer) => TYPES[contentType]?.magic(head) ?? false;

/** A new key for a file's bytes. It names the tuition, so a key is only ever one tuition's. */
export const newFileKey = (tuition: string, ext: string) => `library/${tuition}/${randomUUID()}.${ext}`;

/** How many bytes the parts of a file of this size are: PART_BYTES each, and what is left in the last. */
export function partSizes(size: number): number[] {
  const n = Math.ceil(size / PART_BYTES);
  return Array.from({ length: n }, (_, i) => (i < n - 1 ? PART_BYTES : size - PART_BYTES * (n - 1)));
}

/** The name a file is saved under: its own name, with the extension its type needs when the name has none. */
export function downloadName(name: string, contentType: string): string {
  const t = TYPES[contentType];
  if (!t) return name;
  const ok = t.kind === 'pdf' ? /\.pdf$/i : /\.(jpe?g|png|webp)$/i;
  return ok.test(name) ? name : `${name}.${t.ext}`;
}

/** What a screen shows of a file. */
export const FILE_COLUMNS = 'f.id, f.section_id, f.name, f.kind, f.content_type, f.size_bytes, f.created_at';

// ---------------------------------------------------------------- who owns what

/** A group's id, or null when it has none yet. With `create` it is made first: a group exists from the moment anything is made for it. */
export async function groupIdOf(tuition: string, cls: number, subjectId: string, create: boolean, db: Db = pool): Promise<string | null> {
  if (create) await ensureGroup(tuition, cls, subjectId, db);
  const g = await tq1<{ id: string }>(tuition, 'select id from groups where tuition_id = @T and class_level = $1 and subject_id = $2', [cls, subjectId], db);
  return g?.id ?? null;
}

export type Section = { id: string; name: string; group_id: string | null; course_id: string | null };

/** A section of this tuition, by id. A section of another tuition is not found. */
export async function ownSection(tuition: string, id: string, db: Db = pool): Promise<Section> {
  const s = await tq1<Section>(tuition, 'select id, name, group_id, course_id from class_sections where id = $1 and tuition_id = @T', [id], db);
  if (!s) throw notFound('This section');
  return s;
}

export type FileRow = {
  id: string; section_id: string; name: string; kind: 'pdf' | 'photo'; content_type: string; size_bytes: number;
  object_key: string; upload_id: string | null; status: 'uploading' | 'ready'; created_at: Date;
};

/** A file of this tuition, by id. A file of another tuition is not found. */
export async function ownFile(tuition: string, id: string, db: Db = pool): Promise<FileRow> {
  const f = await tq1<FileRow>(
    tuition,
    `select f.id, f.section_id, f.name, f.kind, f.content_type, f.size_bytes, f.object_key, f.upload_id, f.status, f.created_at
       from class_files f where f.id = $1 and f.tuition_id = @T`,
    [id],
    db,
  );
  if (!f) throw notFound('This file');
  return f;
}

// ---------------------------------------------------------------- the shelf of one group or course

/** `where` for sections of a group (by id) or of a course: the column a section is of. */
export type Shelf = { column: 'group_id' | 'course_id'; id: string };

/** The sections of a shelf with their finished files, in the order the tutor made them and added the files. */
export async function shelfOf(tuition: string, shelf: Shelf | null) {
  if (!shelf) return { sections: [], files: 0, bytes: 0 };
  const sections = await tq<{ id: string; name: string; position: number; created_at: Date }>(
    tuition,
    `select id, name, position, created_at from class_sections where tuition_id = @T and ${shelf.column} = $1 order by position, created_at, name`,
    [shelf.id],
  );
  const files = await tq(
    tuition,
    `select ${FILE_COLUMNS} from class_files f join class_sections s on s.id = f.section_id
      where f.tuition_id = @T and s.${shelf.column} = $1 and f.status = 'ready' order by f.created_at, f.name`,
    [shelf.id],
  );
  return {
    sections: sections.map((s) => ({ ...s, files: files.filter((f) => f.section_id === s.id) })),
    files: files.length,
    bytes: files.reduce((n, f) => n + Number(f.size_bytes), 0),
  };
}

/** How many finished files a shelf holds: the number on the Library tab. */
export async function shelfCount(tuition: string, shelf: Shelf | null): Promise<number> {
  if (!shelf) return 0;
  const r = await tq1<{ n: number }>(
    tuition,
    `select count(*) as n from class_files f join class_sections s on s.id = f.section_id
      where f.tuition_id = @T and s.${shelf.column} = $1 and f.status = 'ready'`,
    [shelf.id],
  );
  return Number(r?.n ?? 0);
}

/** How many finished files a group's shelf holds: the number on the Library tab of its page. */
export async function groupLibraryCount(tuition: string, cls: number, subjectId: string): Promise<number> {
  const id = await groupIdOf(tuition, cls, subjectId, false);
  return shelfCount(tuition, id ? { column: 'group_id', id } : null);
}

export const courseLibraryCount = (tuition: string, courseId: string) => shelfCount(tuition, { column: 'course_id', id: courseId });

/** The bytes a tuition has on its shelves, counting uploads still going (they have been promised the room). */
export async function bytesUsed(tuition: string): Promise<number> {
  const r = await tq1<{ n: number }>(tuition, 'select coalesce(sum(size_bytes), 0) as n from class_files where tuition_id = @T');
  return Number(r?.n ?? 0);
}

// ---------------------------------------------------------------- throwing files away

/**
 * Removes the objects behind files that are going: the finished ones' bytes, and an upload in progress with the parts it holds.
 * Rows are deleted by the caller; a failure here only leaves an object nobody can reach, so it is swallowed.
 */
export async function discardObjects(files: { object_key: string; upload_id: string | null }[]) {
  for (const f of files) if (f.upload_id) await abortMultipart(f.object_key, f.upload_id);
  await deleteObjects(files.map((f) => f.object_key)).catch(() => {});
}

/** Throws away uploads nobody finished: their rows, and the parts or the object they left in storage. */
export async function sweepStaleUploads(tuition: string) {
  const old = await tq<{ id: string; object_key: string; upload_id: string | null }>(
    tuition,
    `delete from class_files where tuition_id = @T and status = 'uploading' and created_at < now() - interval '${STALE_UPLOAD}'
      returning id, object_key, upload_id`,
  );
  if (old.length) await discardObjects(old);
}

/** The keys (and upload ids) of every file on a shelf, so a group's or course's files can be thrown away with it. */
export async function shelfObjects(shelf: Shelf, db: Db = pool) {
  return q<{ object_key: string; upload_id: string | null }>(
    `select f.object_key, f.upload_id from class_files f join class_sections s on s.id = f.section_id where s.${shelf.column} = $1`,
    [shelf.id],
    db,
  );
}

/** How many files (finished or not) a group (by class and subject) holds, for the checks that refuse to remove a group that has some. */
export async function groupFileCount(tuition: string, cls: number, subjectId: string): Promise<number> {
  const r = await tq1<{ n: number }>(
    tuition,
    `select count(*) as n from class_files f join class_sections s on s.id = f.section_id join groups g on g.id = s.group_id
      where f.tuition_id = @T and g.class_level = $1 and g.subject_id = $2`,
    [cls, subjectId],
  );
  return Number(r?.n ?? 0);
}

/** How many files a subject's groups hold altogether. */
export async function subjectFileCount(tuition: string, subjectId: string): Promise<number> {
  const r = await tq1<{ n: number }>(
    tuition,
    `select count(*) as n from class_files f join class_sections s on s.id = f.section_id join groups g on g.id = s.group_id
      where f.tuition_id = @T and g.subject_id = $1`,
    [subjectId],
  );
  return Number(r?.n ?? 0);
}

// ---------------------------------------------------------------- the student's side

/**
 * SQL for the files a student may see, from the file `f` and its section `s`, with the section's group `g` and course `co` joined:
 * those of the groups they are in (their class, one of their subjects) and of the courses they are in. $1 is the student, $2 their class.
 */
export const STUDENT_SEES = `f.status = 'ready' and f.tuition_id = @T and (
    (g.id is not null and g.class_level = $2
       and exists (select 1 from student_subjects ss where ss.tuition_id = @T and ss.student_id = $1 and ss.subject_id = g.subject_id))
    or (co.id is not null and exists (select 1 from course_members cm where cm.course_id = co.id and cm.student_id = $1)))`;

export const STUDENT_FILE_JOINS = `class_files f join class_sections s on s.id = f.section_id
    left join groups g on g.id = s.group_id left join subjects sj on sj.id = g.subject_id left join courses co on co.id = s.course_id`;

/** How many finished files this student can see in the tuition: the Library tab shows only when it is more than none. */
export async function studentFileCount(tuition: string, studentId: string, classLevel: number | null, db: Db = pool): Promise<number> {
  const r = await tq1<{ n: number }>(tuition, `select count(*) as n from ${STUDENT_FILE_JOINS} where ${STUDENT_SEES}`, [studentId, classLevel], db);
  return Number(r?.n ?? 0);
}
