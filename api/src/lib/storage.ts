import { DeleteObjectsCommand, GetObjectCommand, HeadObjectCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

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

/** A URL the phone can PUT the bytes to directly, so images never pass through the API. */
export const uploadUrl = (key: string, contentType = 'image/jpeg') =>
  getSignedUrl(s3, new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: contentType }), { expiresIn: 900 });

export const viewUrl = (key: string, seconds = 3600) =>
  getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: seconds });

export async function maybeViewUrl(key: string | null | undefined) {
  return key ? viewUrl(key) : null;
}

export async function readObject(key: string, maxBytes = MAX_IMAGE_BYTES): Promise<{ bytes: Buffer; type: string }> {
  const r = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
  if ((r.ContentLength ?? 0) > maxBytes) throw new Error(`The stored file is larger than ${maxBytes} bytes.`);
  const bytes = Buffer.from(await r.Body!.transformToByteArray());
  return { bytes, type: r.ContentType ?? 'image/jpeg' };
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

/** Every object under a prefix: its key, size and when it was written. */
export async function listObjects(prefix = ''): Promise<{ key: string; size: number; modified: Date | null }[]> {
  const out: { key: string; size: number; modified: Date | null }[] = [];
  let token: string | undefined;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix || undefined, ContinuationToken: token }));
    for (const o of r.Contents ?? []) out.push({ key: o.Key ?? '', size: o.Size ?? 0, modified: o.LastModified ?? null });
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);
  return out;
}
