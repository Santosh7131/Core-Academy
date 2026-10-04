import { DeleteObjectsCommand, GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

// Credentials, endpoint and region come from the AWS_* variables Neon injects for the branch.
// Neon Object Storage only supports path-style addressing.
const s3 = new S3Client({ forcePathStyle: true });
export const BUCKET = 'uploads';

/** A URL the phone can PUT the bytes to directly, so images never pass through the API. */
export const uploadUrl = (key: string, contentType = 'image/jpeg') =>
  getSignedUrl(s3, new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: contentType }), { expiresIn: 900 });

export const viewUrl = (key: string, seconds = 3600) =>
  getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: seconds });

export async function maybeViewUrl(key: string | null | undefined) {
  return key ? viewUrl(key) : null;
}

export async function readObject(key: string): Promise<{ bytes: Buffer; type: string }> {
  const r = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
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
