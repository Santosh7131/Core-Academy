// Puts a built admin app and its update feed into a branch's private storage, where
// GET /admin/app finds it for the developer login (and nobody else). Run by release-admin.ps1:
//   node tools/upload-admin.ts --env .env.main --apk tools/out/core-academy-admin-1.0.0.apk --version 1.0.0 --build 1 --notes notes.txt
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
const apkPath = arg('--apk');
const version = arg('--version');
const build = Number(arg('--build'));
if (!apkPath || !existsSync(apkPath) || !version || !Number.isInteger(build)) {
  throw new Error('Usage: --env <file> --apk <file> --version 1.0.0 --build 1 [--notes <file>]');
}
const notesFile = arg('--notes');
const notes = notesFile && existsSync(notesFile) ? readFileSync(notesFile, 'utf8').trim().replace(/\*\*/g, '') : '';

// Each branch's storage has its own endpoint, named after the branch like its API is.
let endpoint = process.env.AWS_ENDPOINT_URL_S3;
if (!endpoint) {
  const host = new URL(process.env.NEON_FUNCTION_API_BASE_URL ?? '').host; // br-xxx-api.compute.c-3.ap-southeast-1.aws.neon.tech
  const m = /^(br-[a-z0-9-]+)-api\.compute\.(.+)$/.exec(host);
  if (!m) throw new Error(`Cannot tell the storage endpoint from ${host}`);
  endpoint = `https://${m[1]}.storage.${m[2]}`;
}
const s3 = new S3Client({ endpoint, forcePathStyle: true, region: process.env.AWS_REGION });

const bytes = readFileSync(apkPath);
const key = `admin/apk/core-academy-admin-${version}.apk`;
const feed = { version, build, key, sha256: createHash('sha256').update(bytes).digest('hex'), size: bytes.length, notes };
await s3.send(new PutObjectCommand({ Bucket: 'uploads', Key: key, Body: bytes, ContentType: 'application/vnd.android.package-archive' }));
// The feed goes last, so it never names an APK that is not there yet.
await s3.send(new PutObjectCommand({ Bucket: 'uploads', Key: 'admin/update.json', Body: JSON.stringify(feed, null, 2), ContentType: 'application/json' }));
console.log(`Admin ${version} (build ${build}, ${bytes.length} bytes) is in ${process.env.NEON_BRANCH}'s private storage.`);
