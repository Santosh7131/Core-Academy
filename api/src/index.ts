import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { requireUser, type AppEnv } from './lib/auth.ts';
import { aiConfigured } from './lib/groq.ts';
import { HttpError } from './lib/http.ts';
import { authRoutes } from './routes/auth.ts';
import { paperRoutes } from './routes/papers.ts';
import { studentRoutes } from './routes/student.ts';
import { teacherRoutes } from './routes/teacher.ts';

const app = new Hono<AppEnv>();

// The Android app does not need CORS; the web version planned for later will.
app.use('*', cors({ origin: '*', allowHeaders: ['authorization', 'content-type'], allowMethods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'] }));

app.get('/', (c) => c.json({ name: 'Core Academy API', branch: process.env.NEON_BRANCH ?? null, ai: aiConfigured() }));

app.route('/auth', authRoutes);
app.route('/student', studentRoutes);

const teacher = new Hono<AppEnv>();
teacher.use('*', requireUser('teacher'));
teacher.route('/', teacherRoutes);
teacher.route('/', paperRoutes);
app.route('/teacher', teacher);

app.notFound((c) => c.json({ error: { code: 'not_found', message: 'Not found.' } }, 404));

app.onError((err, c) => {
  if (err instanceof HttpError) {
    return c.json({ error: { code: err.code, message: err.message } }, err.status as 400);
  }
  console.error(err);
  return c.json({ error: { code: 'server_error', message: 'Something went wrong on the server. Please try again.' } }, 500);
});

export default app;
