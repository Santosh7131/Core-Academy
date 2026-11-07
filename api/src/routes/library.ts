import { waitUntil } from '@neon/functions';
import { Hono, type Context } from 'hono';
import { tuitionOf, type AppEnv } from '../lib/auth.ts';
import { ownCourse } from '../lib/courses.ts';
import { tq, tq1, tx } from '../lib/db.ts';
import { bad, HttpError, notFound, str, uuid } from '../lib/http.ts';
import { levelParam } from '../lib/levels.ts';
import {
  announceFiles, bytesUsed, discardObjects, downloadName, FILE_COLUMNS, fileType, groupIdOf, looksLike, MAX_FILE_BYTES, MAX_FILES_PER_SECTION, MAX_SECTIONS,
  newFileKey, ownFile, ownSection, PART_BYTES, partSizes, putInOrder, quotaBytes, shelfOf, STUDENT_FILE_JOINS, STUDENT_SEES, sweepStaleUploads,
  withShelfLock, type FileRow, type Shelf,
} from '../lib/library.ts';
import { fileUrl, finishMultipart, objectSize, partUrl, peekObject, startMultipart, uploadedParts, uploadUrl } from '../lib/storage.ts';
import { taughtSubject } from '../lib/tuition.ts';
import { readBody } from './body.ts';

// The Library: files a tutor puts on the shelf of a group or a course, for its people to read and download. A shelf has sections ("PDFs",
// "Books"), a section has files, a file is a PDF or a photo of up to 100 MB (025_class_files.sql). The bytes never pass through this
// function: the phone sends them straight to storage on a signed link, in one request or, for a big file, in parts, and then says it is
// done, and the server looks at what arrived before the file shows to anyone.
//
// libraryRoutes is mounted with the teacher routes (behind requireUser('teacher')); every tutor of the tuition shares every shelf.
// studentLibrary is mounted inside the student routes: students read and download, nothing else.
export const libraryRoutes = new Hono<AppEnv>();
export const studentLibrary = new Hono<AppEnv>();

/** What a screen shows of a file. */
const shape = (f: Pick<FileRow, 'id' | 'section_id' | 'name' | 'kind' | 'content_type' | 'size_bytes' | 'created_at'>) => ({
  id: f.id, section_id: f.section_id, name: f.name, kind: f.kind, content_type: f.content_type, size_bytes: Number(f.size_bytes), created_at: f.created_at,
});

// ---------------------------------------------------------------- a shelf

async function shelfResponse(T: string, shelf: Shelf | null) {
  const shelfNow = await shelfOf(T, shelf);
  return { library: { ...shelfNow, used_bytes: await bytesUsed(T), quota_bytes: quotaBytes(), max_file_bytes: MAX_FILE_BYTES } };
}

async function groupShelf(c: Context<AppEnv>, create: boolean): Promise<{ T: string; shelf: Shelf | null }> {
  const T = tuitionOf(c).id;
  const cls = await levelParam(c.req.param('cls'), T);
  const subjectId = uuid(c.req.param('subject'), 'subject');
  await taughtSubject(T, subjectId);
  const id = await groupIdOf(T, cls, subjectId, create);
  return { T, shelf: id ? { column: 'group_id', id } : null };
}

async function courseShelf(c: Context<AppEnv>): Promise<{ T: string; shelf: Shelf }> {
  const T = tuitionOf(c).id;
  const co = await ownCourse(T, uuid(c.req.param('id'), 'course id'));
  return { T, shelf: { column: 'course_id', id: co.id } };
}

/** A group's shelf: its sections, each with its finished files. */
libraryRoutes.get('/groups/:cls/:subject/library', async (c) => {
  const { T, shelf } = await groupShelf(c, false);
  waitUntil(sweepStaleUploads(T).catch(() => {}));
  return c.json(await shelfResponse(T, shelf));
});

libraryRoutes.get('/courses/:id/library', async (c) => {
  const { T, shelf } = await courseShelf(c);
  waitUntil(sweepStaleUploads(T).catch(() => {}));
  return c.json(await shelfResponse(T, shelf));
});

// ---------------------------------------------------------------- sections

async function addSection(c: Context<AppEnv>, T: string, shelf: Shelf) {
  const name = str(await readBody(c), 'name', { max: 40 })!;
  const have = await tq1<{ n: number; next: number }>(
    T,
    `select count(*) as n, coalesce(max(position), -1) + 1 as next from class_sections where tuition_id = @T and ${shelf.column} = $1`,
    [shelf.id],
  );
  if ((have?.n ?? 0) >= MAX_SECTIONS) throw new HttpError(409, 'too_many_sections', `A group or course can have up to ${MAX_SECTIONS} sections.`);
  try {
    const s = await tq1(
      T,
      `insert into class_sections (tuition_id, ${shelf.column}, name, position, created_by) values (@T, $1, $2, $3, $4) returning id, name, position, created_at`,
      [shelf.id, name, have?.next ?? 0, c.get('user').id],
    );
    return c.json({ section: { ...s, files: [] } }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `There is already a section called ${name}.`);
    throw e;
  }
}

libraryRoutes.post('/groups/:cls/:subject/library/sections', async (c) => {
  const { T, shelf } = await groupShelf(c, true);
  return addSection(c, T, shelf!);
});

libraryRoutes.post('/courses/:id/library/sections', async (c) => {
  const { T, shelf } = await courseShelf(c);
  return addSection(c, T, shelf);
});

/** A list of ids sent in the body, as many as one shelf can hold. */
function idList(v: unknown, what: string): string[] {
  if (!Array.isArray(v) || v.length > Math.max(MAX_SECTIONS, MAX_FILES_PER_SECTION)) throw bad(`${what} must be a list.`);
  return v.map((x) => uuid(x, what));
}

/**
 * Puts a shelf's sections in the order sent: every section of the shelf once, first to last. The answer is the shelf as it now stands.
 * A list that is not exactly the shelf's sections (another tutor added or removed one) is refused, so nothing is scrambled.
 */
async function orderSections(c: Context<AppEnv>, T: string, shelf: Shelf | null) {
  const ids = idList((await readBody(c)).ids, 'ids');
  if (shelf) await putInOrder('class_sections', T, { sql: `${shelf.column} = $1`, params: [shelf.id] }, ids);
  else if (ids.length) throw new HttpError(409, 'out_of_date', 'This list changed since you opened it. Look at it again, then move things.');
  return c.json(await shelfResponse(T, shelf));
}

libraryRoutes.put('/groups/:cls/:subject/library/sections/order', async (c) => {
  const { T, shelf } = await groupShelf(c, false);
  return orderSections(c, T, shelf);
});

libraryRoutes.put('/courses/:id/library/sections/order', async (c) => {
  const { T, shelf } = await courseShelf(c);
  return orderSections(c, T, shelf);
});

/** Puts the files of a section in the order sent: every finished file of the section once, first to last. */
libraryRoutes.put('/library/sections/:id/files/order', async (c) => {
  const T = tuitionOf(c).id;
  const sec = await ownSection(T, uuid(c.req.param('id'), 'section id'));
  await putInOrder('class_files', T, { sql: `section_id = $1 and status = 'ready'`, params: [sec.id] }, idList((await readBody(c)).ids, 'ids'));
  const files = await tq(T, `select ${FILE_COLUMNS} from class_files f where f.section_id = $1 and f.tuition_id = @T and f.status = 'ready' order by f.position, f.created_at, f.name`, [sec.id]);
  return c.json({ files: files.map(shape) });
});

/**
 * Tells the students about files the tutor has just added (the app calls this once, when its uploads are done, so a batch of files is one
 * notification, and a tutor who does not want to disturb anyone simply does not call it). Each file is announced once.
 */
libraryRoutes.post('/library/announce', async (c) => {
  const ids = idList((await readBody(c)).file_ids, 'file ids');
  if (!ids.length) throw bad('Say which files were added.');
  return c.json(await announceFiles(tuitionOf(c).id, ids));
});

/** Renames a section. The files in it stay. */
libraryRoutes.patch('/library/sections/:id', async (c) => {
  const T = tuitionOf(c).id;
  const sec = await ownSection(T, uuid(c.req.param('id'), 'section id'));
  const name = str(await readBody(c), 'name', { max: 40 })!;
  try {
    const s = await tq1(T, 'update class_sections set name = $2 where id = $1 and tuition_id = @T returning id, name, position', [sec.id, name]);
    if (!s) throw notFound('This section');
    return c.json({ section: s });
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `There is already a section called ${name}.`);
    throw e;
  }
});

/** Deletes a section with the files in it, but only with ?with_files=1 when it has any, like deleting a course with results. */
libraryRoutes.delete('/library/sections/:id', async (c) => {
  const T = tuitionOf(c).id;
  const sec = await ownSection(T, uuid(c.req.param('id'), 'section id'));
  const files = await tq<{ object_key: string; upload_id: string | null; status: string }>(
    T,
    'select object_key, upload_id, status from class_files where section_id = $1 and tuition_id = @T',
    [sec.id],
  );
  const ready = files.filter((f) => f.status === 'ready').length;
  if (ready > 0 && c.req.query('with_files') !== '1') {
    throw new HttpError(409, 'has_files', `${ready === 1 ? 'This section has 1 file' : `This section has ${ready} files`}. Deleting it deletes ${ready === 1 ? 'that file' : 'them'} too.`);
  }
  await tx(async (cx) => {
    await cx.query('delete from class_files where section_id = $1', [sec.id]);
    await cx.query('delete from class_sections where id = $1', [sec.id]);
  });
  await discardObjects(files);
  return c.json({ ok: true, files_deleted: ready });
});

// ---------------------------------------------------------------- adding a file

type UploadPlan =
  | { mode: 'single'; url: string; headers: Record<string, string> }
  | { mode: 'multipart'; part_size: number; parts: { n: number; size: number; done: boolean; url?: string }[] };

/** The links the phone sends a file's bytes to: one for a small file, one per part for a big one (skipping the parts storage already has). */
async function uploadPlan(f: Pick<FileRow, 'object_key' | 'upload_id' | 'content_type' | 'size_bytes'>, have: Set<number> = new Set()): Promise<UploadPlan> {
  const size = Number(f.size_bytes);
  if (!f.upload_id) {
    return { mode: 'single', url: await uploadUrl(f.object_key, f.content_type, size), headers: { 'content-type': f.content_type } };
  }
  const sizes = partSizes(size);
  return {
    mode: 'multipart',
    part_size: PART_BYTES,
    parts: await Promise.all(
      sizes.map(async (s, i) => {
        const n = i + 1;
        return have.has(n) ? { n, size: s, done: true } : { n, size: s, done: false, url: await partUrl(f.object_key, f.upload_id!, n, s) };
      }),
    ),
  };
}

/**
 * Starts adding a file to a section: says what it is (name, type, size in bytes) and gets back the links to send it to. The file does not
 * show to anyone until /complete has seen all of it arrive.
 */
libraryRoutes.post('/library/sections/:id/files', async (c) => {
  const T = tuitionOf(c).id;
  waitUntil(sweepStaleUploads(T).catch(() => {}));
  const sec = await ownSection(T, uuid(c.req.param('id'), 'section id'));
  const b = await readBody(c);
  const name = str(b, 'name', { max: 120 })!;
  const type = fileType(b.content_type);
  const size = b.size;
  if (typeof size !== 'number' || !Number.isInteger(size) || size < 1) throw bad('Say how many bytes the file has.');
  if (size > MAX_FILE_BYTES) throw new HttpError(413, 'too_big', 'That file is too big. Files can be up to 100 MB.');
  // The count, the room and the new row are one step, held apart from other files starting at the same moment (withShelfLock).
  const f = await withShelfLock(T, async (cx) => {
    const inSection = await tq1<{ n: number }>(T, 'select count(*) as n from class_files where section_id = $1 and tuition_id = @T', [sec.id], cx);
    if ((inSection?.n ?? 0) >= MAX_FILES_PER_SECTION) throw new HttpError(409, 'too_many_files', `A section can hold up to ${MAX_FILES_PER_SECTION} files.`);
    const used = await bytesUsed(T, cx);
    if (used + size > quotaBytes()) {
      throw new HttpError(413, 'library_full', 'There is no room for this file. The Library holds up to 2 GB for the whole tuition, so delete some files first.');
    }
    return tq1<FileRow>(
      T,
      `insert into class_files (section_id, tuition_id, name, kind, content_type, size_bytes, object_key, created_by)
       values ($1, @T, $2, $3, $4, $5, $6, $7)
       returning id, section_id, name, kind, content_type, size_bytes, object_key, upload_id, status, created_at`,
      [sec.id, name, type.kind, type.type, size, newFileKey(T, type.ext), c.get('user').id],
      cx,
    );
  });
  try {
    if (size > PART_BYTES) {
      const uploadId = await startMultipart(f!.object_key, type.type);
      f!.upload_id = uploadId;
      await tq(T, 'update class_files set upload_id = $2 where id = $1 and tuition_id = @T', [f!.id, uploadId]);
    }
    return c.json({ file: { ...shape(f!), status: 'uploading' }, upload: await uploadPlan(f!) }, 201);
  } catch (e) {
    await tq(T, 'delete from class_files where id = $1 and tuition_id = @T', [f!.id]);
    throw e;
  }
});

/** New links for a file that is still going up (a part failed, or the links ran out), with the parts storage already has marked done. */
libraryRoutes.post('/library/files/:id/upload', async (c) => {
  const T = tuitionOf(c).id;
  const f = await ownFile(T, uuid(c.req.param('id'), 'file id'));
  if (f.status !== 'uploading') throw new HttpError(409, 'already_added', 'This file has already been added.');
  let have = new Set<number>();
  if (f.upload_id) {
    const got = await uploadedParts(f.object_key, f.upload_id).catch(() => null);
    if (!got) {
      await tq(T, 'delete from class_files where id = $1 and tuition_id = @T', [f.id]);
      await discardObjects([f]);
      throw new HttpError(409, 'upload_lost', 'That upload was lost. Add the file again.');
    }
    const want = partSizes(Number(f.size_bytes));
    have = new Set(got.filter((p) => p.size === want[p.part - 1]).map((p) => p.part));
  }
  return c.json({ file: { ...shape(f), status: 'uploading' }, upload: await uploadPlan(f, have) });
});

/**
 * The phone says every byte has been sent. For a file in parts, storage must hold every part at its right size; then the parts are put
 * together. The finished object must be exactly the size said, and must start the way its type does. Only then does the file show to anyone.
 * A file that did not arrive in full is thrown away; one still missing parts is kept, so the phone can send what is missing.
 */
libraryRoutes.post('/library/files/:id/complete', async (c) => {
  const T = tuitionOf(c).id;
  const f = await ownFile(T, uuid(c.req.param('id'), 'file id'));
  if (f.status === 'ready') return c.json({ file: shape(f) });
  const size = Number(f.size_bytes);
  const reject = async (code: string, message: string) => {
    await tq(T, 'delete from class_files where id = $1 and tuition_id = @T', [f.id]);
    await discardObjects([f]);
    return new HttpError(409, code, message);
  };
  if (f.upload_id) {
    const got = await uploadedParts(f.object_key, f.upload_id).catch(() => null);
    if (got) {
      const want = partSizes(size);
      if (got.length !== want.length || got.some((p) => p.size !== want[p.part - 1])) {
        throw new HttpError(409, 'incomplete', 'The file did not finish going up. Try again.');
      }
      await finishMultipart(f.object_key, f.upload_id, got.sort((a, b) => a.part - b.part));
    } else if ((await objectSize(f.object_key)) === null) {
      // Storage no longer knows the upload and has no object: there is nothing to finish.
      throw await reject('upload_lost', 'That upload was lost. Add the file again.');
    }
    // (If storage has no list of parts but does have the object, an earlier try already put the parts together; it is checked below.)
  }
  if ((await objectSize(f.object_key)) !== size) throw await reject('upload_failed', 'The file did not arrive in full. Add it again.');
  const head = await peekObject(f.object_key, 16);
  if (!head || !looksLike(f.content_type, head)) {
    throw await reject('not_that_type', `That does not look like a real ${f.kind === 'pdf' ? 'PDF' : 'photo'}. Check the file and add it again.`);
  }
  // A finished file goes to the end of its section.
  const ready = await tq1<FileRow>(
    T,
    `update class_files set status = 'ready', upload_id = null, ready_at = now(),
            position = (select coalesce(max(x.position), 0) + 1 from class_files x where x.section_id = $2 and x.status = 'ready')
      where id = $1 and tuition_id = @T
     returning id, section_id, name, kind, content_type, size_bytes, object_key, upload_id, status, created_at`,
    [f.id, f.section_id],
  );
  return c.json({ file: shape(ready!) });
});

// ---------------------------------------------------------------- a file

/** Renames a file, moves it to another section of the same group or course, or both. */
libraryRoutes.patch('/library/files/:id', async (c) => {
  const T = tuitionOf(c).id;
  const f = await ownFile(T, uuid(c.req.param('id'), 'file id'));
  const b = await readBody(c);
  const name = str(b, 'name', { max: 120, optional: true });
  let sectionId = f.section_id;
  if (b.section_id !== undefined && b.section_id !== f.section_id) {
    const to = await ownSection(T, uuid(b.section_id, 'section id'));
    const from = await ownSection(T, f.section_id);
    if (to.group_id !== from.group_id || to.course_id !== from.course_id) throw bad('A file can only move to another section of the same group or course.');
    sectionId = to.id;
  }
  if (name === undefined && sectionId === f.section_id) return c.json({ file: shape(f) });
  // The count of the new section and the move are one step, held apart from other files arriving at the same moment (withShelfLock).
  const row = await withShelfLock(T, async (cx) => {
    if (sectionId !== f.section_id) {
      const there = await tq1<{ n: number }>(T, 'select count(*) as n from class_files where section_id = $1 and tuition_id = @T', [sectionId], cx);
      if ((there?.n ?? 0) >= MAX_FILES_PER_SECTION) throw new HttpError(409, 'too_many_files', `A section can hold up to ${MAX_FILES_PER_SECTION} files.`);
    }
    // A file moved to another section goes to the end of it.
    return tq1<FileRow>(
      T,
      `update class_files set name = coalesce($2, name), section_id = $3,
              position = case when $3::uuid is distinct from section_id
                              then (select coalesce(max(x.position), 0) + 1 from class_files x where x.section_id = $3 and x.status = 'ready')
                              else position end
        where id = $1 and tuition_id = @T
       returning id, section_id, name, kind, content_type, size_bytes, object_key, upload_id, status, created_at`,
      [f.id, name ?? null, sectionId],
      cx,
    );
  });
  return c.json({ file: shape(row!) });
});

/** Deletes a file, or cancels one that is still going up. */
libraryRoutes.delete('/library/files/:id', async (c) => {
  const T = tuitionOf(c).id;
  const f = await ownFile(T, uuid(c.req.param('id'), 'file id'));
  await tq(T, 'delete from class_files where id = $1 and tuition_id = @T', [f.id]);
  await discardObjects([f]);
  return c.json({ ok: true });
});

/** A link that reads the file (or, with ?download=1, saves it under its own name), good for an hour. */
async function link(f: Pick<FileRow, 'object_key' | 'name' | 'kind' | 'content_type' | 'size_bytes'>, download: boolean) {
  return {
    url: await fileUrl(f.object_key, { name: downloadName(f.name, f.content_type), contentType: f.content_type, download }),
    name: f.name,
    kind: f.kind,
    content_type: f.content_type,
    size_bytes: Number(f.size_bytes),
    expires_in: 3600,
  };
}

libraryRoutes.get('/library/files/:id/url', async (c) => {
  const T = tuitionOf(c).id;
  const f = await ownFile(T, uuid(c.req.param('id'), 'file id'));
  if (f.status !== 'ready') throw notFound('This file');
  return c.json(await link(f, c.req.query('download') === '1'));
});

// ---------------------------------------------------------------- the student's side

/**
 * Every shelf this student can read in this tuition: the groups they are in and the courses they are in, each with its sections and their
 * finished files. A group or course with no file yet is left out, and so is a section with none.
 */
studentLibrary.get('/library', async (c) => {
  const me = c.get('user');
  const T = tuitionOf(c).id;
  const rows = await tq<any>(
    T,
    `select f.id, f.section_id, f.name, f.kind, f.content_type, f.size_bytes, f.created_at,
            s.name as section, s.group_id, s.course_id, g.class_level, g.subject_id, sj.name as subject, co.name as course
       from ${STUDENT_FILE_JOINS}
      where ${STUDENT_SEES}
      order by s.position, s.created_at, f.position, f.created_at, f.name`,
    [me.id, me.class_level],
  );
  type Sec = { id: string; name: string; files: ReturnType<typeof shape>[] };
  const groups = new Map<string, { class_level: number; subject_id: string; subject: string; sections: Sec[] }>();
  const courses = new Map<string, { id: string; name: string; sections: Sec[] }>();
  for (const r of rows) {
    const shelf = r.group_id
      ? groups.get(r.group_id) ?? groups.set(r.group_id, { class_level: r.class_level, subject_id: r.subject_id, subject: r.subject, sections: [] }).get(r.group_id)!
      : courses.get(r.course_id) ?? courses.set(r.course_id, { id: r.course_id, name: r.course, sections: [] }).get(r.course_id)!;
    let sec = shelf.sections.find((x) => x.id === r.section_id);
    if (!sec) shelf.sections.push((sec = { id: r.section_id, name: r.section, files: [] }));
    sec.files.push(shape(r));
  }
  return c.json({
    groups: [...groups.values()].sort((a, b) => a.class_level - b.class_level || a.subject.localeCompare(b.subject)),
    courses: [...courses.values()].sort((a, b) => a.name.localeCompare(b.name)),
  });
});

studentLibrary.get('/library/files/:id/url', async (c) => {
  const me = c.get('user');
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'file id');
  const f = await tq1<FileRow>(
    T,
    `select f.id, f.name, f.kind, f.content_type, f.size_bytes, f.object_key from ${STUDENT_FILE_JOINS} where f.id = $3 and ${STUDENT_SEES}`,
    [me.id, me.class_level, id],
  );
  if (!f) throw notFound('This file');
  return c.json(await link(f, c.req.query('download') === '1'));
});
