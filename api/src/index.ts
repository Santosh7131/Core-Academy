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
import { notifyRoutes } from './routes/notify.ts';
import { paperRoutes } from './routes/papers.ts';
import { studentOpenRoutes, studentRoutes } from './routes/student.ts';
import { teacherRoutes } from './routes/teacher.ts';
import { tuitionRoutes } from './routes/tuition.ts';

const app = new Hono<AppEnv>();

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
