import pg from 'pg';
import { attachDatabasePool } from '@neon/functions';

// numeric and bigint come back as strings by default; every value we store fits a JS number.
pg.types.setTypeParser(1700, (v) => (v === null ? null : Number(v)));
pg.types.setTypeParser(20, (v) => (v === null ? null : Number(v)));

export const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
attachDatabasePool(pool);

export type Db = pg.Pool | pg.PoolClient;

export async function q<T = any>(sql: string, params: unknown[] = [], db: Db = pool): Promise<T[]> {
  return (await db.query(sql, params)).rows as T[];
}

export async function q1<T = any>(sql: string, params: unknown[] = [], db: Db = pool): Promise<T | undefined> {
  return (await q<T>(sql, params, db))[0];
}

/**
 * Queries for one tuition. Write `@T` where the tuition's id goes: it becomes the next parameter, so
 * the other parameters keep their numbers and no query can forget to send it.
 */
export const tq = <T = any>(tuition: string, sql: string, params: unknown[] = [], db: Db = pool) =>
  q<T>(sql.replaceAll('@T', `$${params.length + 1}`), [...params, tuition], db);

export async function tq1<T = any>(tuition: string, sql: string, params: unknown[] = [], db: Db = pool): Promise<T | undefined> {
  return (await tq<T>(tuition, sql, params, db))[0];
}

export async function tx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('begin');
    const out = await fn(c);
    await c.query('commit');
    return out;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}
