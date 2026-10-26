import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { requireUser, type AppEnv } from './lib/auth.ts';
import { geminiConfigured } from './lib/gemini.ts';
import { aiConfigured } from './lib/groq.ts';
import { HttpError } from './lib/http.ts';
import { countRequest, logError } from './lib/metrics.ts';
import { pushConfigured } from './lib/push.ts';
import { adminRoutes } from './routes/admin.ts';
import { authRoutes } from './routes/auth.ts';
import { courseRoutes } from './routes/courses.ts';
import { notifyRoutes } from './routes/notify.ts';
import { paperRoutes } from './routes/papers.ts';
import { studentOpenRoutes, studentRoutes } from './routes/student.ts';
import { teacherRoutes } from './routes/teacher.ts';
import { tuitionRoutes } from './routes/tuition.ts';

const app = new Hono<AppEnv>();

// A large request body that no route reads (a route that ignores it, or one that answers 401 first) can stay in the platform's connection to this
// function, and the next request on that connection then gets no answer for a minute. The security test found it. So every body is read away
// before any route runs, and one over MAX_BODY (the app sends a few KB at most) is read away and refused.
const MAX_BODY = 1_000_000;
const tooBig = () => new HttpError(413, 'too_big', 'That is too much data to send at once.');
app.use('*', async (c, next) => {
  const body = c.req.raw.body;
  if (!body) return next();
  if (Number(c.req.header('content-length')) > MAX_BODY) {
    const reader = body.getReader();
    while (!(await reader.read()).done) { /* read away, not kept */ }
    throw tooBig();
  }
  // A copy is read, so the route can still read the request itself (the notification trigger does).
  if ((await c.req.raw.clone().arrayBuffer()).byteLength > MAX_BODY) throw tooBig();
  return next();
});

// The Android apps need no CORS. A browser build is let in only from the origins named in CORS_ORIGINS
// (comma separated), which the live function never sets: no website can call it from a page.
const origins = (process.env.CORS_ORIGINS ?? '').split(',').map((o) => o.trim()).filter(Boolean);
if (origins.length) {
  app.use('*', cors({
    origin: origins,
    allowHeaders: ['authorization', 'content-type', 'x-install-id', 'x-app', 'x-device', 'x-os', 'x-tuition'],
    allowMethods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  }));
}

// Requests per route per day, for the admin app (lib/metrics.ts says which ones count).
app.use('*', async (c, next) => {
  const started = performance.now();
  await next();
  countRequest(c, performance.now() - started);
});

app.get('/', (c) =>
  c.json({
    name: 'Core Academy API', branch: process.env.NEON_BRANCH ?? null,
    ai: aiConfigured(), gemini: geminiConfigured(), push: pushConfigured(),
  }));

app.route('/auth', authRoutes);
app.route('/student', studentOpenRoutes);
app.route('/student', studentRoutes);
app.route('/', notifyRoutes);

const teacher = new Hono<AppEnv>();
teacher.use('*', requireUser('teacher'));
teacher.route('/', teacherRoutes);
teacher.route('/', tuitionRoutes);
teacher.route('/', courseRoutes);
teacher.route('/', paperRoutes);
app.route('/teacher', teacher);

const admin = new Hono<AppEnv>();
admin.use('*', requireUser('developer'));
admin.route('/', adminRoutes);
app.route('/admin', admin);

app.notFound((c) => c.json({ error: { code: 'not_found', message: 'Not found.' } }, 404));

app.onError((err, c) => {
  if (err instanceof HttpError) {
    return c.json({ error: { code: err.code, message: err.message } }, err.status as 400);
  }
  console.error(err);
  logError(c, err);
  return c.json({ error: { code: 'server_error', message: 'Something went wrong on the server. Please try again.' } }, 500);
});

export default app;
