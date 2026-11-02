import {
  AbortMultipartUploadCommand, CompleteMultipartUploadCommand, CreateMultipartUploadCommand, DeleteObjectsCommand, GetObjectCommand,
  HeadObjectCommand, ListObjectsV2Command, ListPartsCommand, PutObjectCommand, S3Client, UploadPartCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { HttpError } from './http.ts';

// Credentials, endpoint and region come from the AWS_* variables Neon injects for the branch.
// Neon Object Storage only supports path-style addressing.
const s3 = new S3Client({ forcePathStyle: true });
export const BUCKET = 'uploads';

/** The most a photo or page image may weigh. A phone photo is a few MB; a presigned upload cannot cap the size itself. */
export const MAX_IMAGE_BYTES = 15 * 1024 * 1024;

/** The size of a stored object, or null when there is none. */
export async function objectSize(key: string): Promise<number | null> {
  try {
    return (await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }))).ContentLength ?? null;
  } catch {
    return null;
  }
}

/**
 * A URL the phone can PUT the bytes to directly, so images never pass through the API. Given the size the phone is
 * about to send, the URL is signed for exactly that many bytes and storage refuses any other length (checked on
 * Neon's storage). Without a size the upload is unbounded, which only an app from before 1.5.0 still asks for: the
 * server then looks at what arrived (objectSize), and REQUIRE_UPLOAD_SIZE=1 refuses the request once those apps are gone.
 */
export const uploadUrl = (key: string, contentType = 'image/jpeg', size?: number) =>
  getSignedUrl(s3, new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: contentType, ...(size ? { ContentLength: size } : {}) }), { expiresIn: 900 });

/** A size the phone says it will upload: a whole number of bytes up to the limit, or none (null) when it says nothing. */
export function declaredSize(v: unknown): number | null {
  if (v === undefined || v === null) {
    if (process.env.REQUIRE_UPLOAD_SIZE === '1') throw new HttpError(400, 'size_required', 'Update the app to upload pictures.');
    return null;
  }
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 1 || v > MAX_IMAGE_BYTES) {
    throw new HttpError(413, 'too_big', 'That picture is too big. Use one under 15 MB.');
  }
  return v;
}

export const viewUrl = (key: string, seconds = 3600) =>
  getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: seconds });

/**
 * A link that reads a stored file under the name and type the person should see. With `download` the answer says "attachment",
 * so a browser saves it with that name instead of showing it; without, it says "inline".
 */
export const fileUrl = (key: string, o: { name: string; contentType: string; download: boolean }, seconds = 3600) =>
  getSignedUrl(
    s3,
    new GetObjectCommand({
      Bucket: BUCKET,
      Key: key,
      ResponseContentType: o.contentType,
      ResponseContentDisposition: contentDisposition(o.name, o.download),
    }),
    { expiresIn: seconds },
  );

/** `attachment; filename="Chapter 4 notes.pdf"; filename*=UTF-8''...`: plain ASCII for old readers, the real name for the rest. */
export function contentDisposition(name: string, download: boolean): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  return `${download ? 'attachment' : 'inline'}; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name).replace(/['()*]/g, (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`)}`;
}

// ---------------------------------------------------------------- multipart: a big file goes up in parts

/** Starts an upload in parts and returns the storage's id for it. */
export async function startMultipart(key: string, contentType: string): Promise<string> {
  const r = await s3.send(new CreateMultipartUploadCommand({ Bucket: BUCKET, Key: key, ContentType: contentType }));
  if (!r.UploadId) throw new Error('Storage did not start the upload.');
  return r.UploadId;
}

/** A URL the phone can PUT one part to, signed for exactly that many bytes. Parts are numbered from 1. */
export const partUrl = (key: string, uploadId: string, part: number, size: number, seconds = 3600) =>
  getSignedUrl(s3, new UploadPartCommand({ Bucket: BUCKET, Key: key, UploadId: uploadId, PartNumber: part, ContentLength: size }), { expiresIn: seconds });

/** The parts storage has received so far for an upload in progress: their numbers, sizes and ETags. */
export async function uploadedParts(key: string, uploadId: string): Promise<{ part: number; size: number; etag: string }[]> {
  const out: { part: number; size: number; etag: string }[] = [];
  let marker: string | undefined;
  for (;;) {
    const r = await s3.send(new ListPartsCommand({ Bucket: BUCKET, Key: key, UploadId: uploadId, PartNumberMarker: marker }));
    for (const p of r.Parts ?? []) out.push({ part: p.PartNumber ?? 0, size: p.Size ?? 0, etag: p.ETag ?? '' });
    if (!r.IsTruncated || r.NextPartNumberMarker === undefined) return out;
    marker = r.NextPartNumberMarker;
  }
}

/** Puts the parts together into the finished object. */
export async function finishMultipart(key: string, uploadId: string, parts: { part: number; etag: string }[]) {
  await s3.send(
    new CompleteMultipartUploadCommand({
      Bucket: BUCKET,
      Key: key,
      UploadId: uploadId,
      MultipartUpload: { Parts: parts.map((p) => ({ PartNumber: p.part, ETag: p.etag })) },
    }),
  );
}

/** Throws away an upload that will not be finished, with every part it holds. An upload storage no longer knows is already gone. */
export async function abortMultipart(key: string, uploadId: string) {
  await s3.send(new AbortMultipartUploadCommand({ Bucket: BUCKET, Key: key, UploadId: uploadId })).catch(() => {});
}

export async function maybeViewUrl(key: string | null | undefined) {
  return key ? viewUrl(key) : null;
}

export async function readObject(key: string, maxBytes = MAX_IMAGE_BYTES): Promise<{ bytes: Buffer; type: string }> {
  const r = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
  if ((r.ContentLength ?? 0) > maxBytes) throw new Error(`The stored file is larger than ${maxBytes} bytes.`);
  const bytes = Buffer.from(await r.Body!.transformToByteArray());
  return { bytes, type: r.ContentType ?? 'image/jpeg' };
}

/** The first bytes of a stored object, to see what kind of file it really is. Null when there is no such object. */
export async function peekObject(key: string, bytes = 16): Promise<Buffer | null> {
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key, Range: `bytes=0-${bytes - 1}` }));
    return Buffer.from(await r.Body!.transformToByteArray());
  } catch {
    return null;
  }
}

export async function putObject(key: string, body: Buffer, contentType: string) {
  await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: key, Body: body, ContentType: contentType }));
}

export async function deleteObjects(keys: string[]) {
  for (let i = 0; i < keys.length; i += 1000) {
    const chunk = keys.slice(i, i + 1000);
    if (chunk.length) {
      await s3.send(new DeleteObjectsCommand({ Bucket: BUCKET, Delete: { Objects: chunk.map((Key) => ({ Key })) } }));
    }
  }
}

/** Every object under a prefix (or the first pages holding `max` of them): its key, size and when it was written. */
export async function listObjects(prefix = '', max = Infinity): Promise<{ key: string; size: number; modified: Date | null }[]> {
  const out: { key: string; size: number; modified: Date | null }[] = [];
  let token: string | undefined;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix || undefined, ContinuationToken: token }));
    for (const o of r.Contents ?? []) out.push({ key: o.Key ?? '', size: o.Size ?? 0, modified: o.LastModified ?? null });
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token && out.length < max);
  return out;
}
