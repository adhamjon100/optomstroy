// Сверка с настоящим PostgreSQL (review fixes, critic [18]): «PGlite» для demo-init эталона на PostgreSQL —
// фасад над ОДНИМ соединением node-postgres к настоящему серверу (параметры — PGHOST/PGPORT/PGUSER/PGPASSWORD/
// PGDATABASE окружения). Им пользуется только сам demo-init (demo_meta, восстановление снимка, восстановление после
// падения); pos-api, pos-worker и pg-boss ходят через настоящие пулы (test/realpg/pg-real.mjs).
// COPY … FROM '/dev/blob' (восстановление снимка WP-B4) — через временный файл, который читает сервер (суперпользователь).
import { createRequire } from 'node:module';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';

const require = createRequire(process.env.POS_REALPG_NM_ANCHOR || import.meta.url);
const pg = require('pg');
const COPY_DIR = (process.env.POS_REALPG_COPY_DIR || '.').replace(/\\/g, '/');
let seq = 0;

const out = (r) => ({ rows: r.rows ?? [], fields: (r.fields ?? []).map((f) => ({ name: f.name, dataTypeID: f.dataTypeID })), affectedRows: r.rowCount ?? 0 });

export class PGlite {
  static async create(_dataDir, _opts = {}) {
    const db = new PGlite();
    await db.init();
    return db;
  }

  async init() {
    this.client = new pg.Client({ application_name: 'realpg-demo-init' });
    await this.client.connect();
    this.closed = false;
    this.parsers = {};
    this.Module = { HEAPU8: { byteLength: 0 } };
    this.fs = { syncToFs: async () => undefined };
    this.realPostgres = true;
  }

  async query(text, params = [], opts = {}) {
    let sql = text;
    let tmp = null;
    if (opts.blob) {
      mkdirSync(COPY_DIR, { recursive: true });
      tmp = `${COPY_DIR}/copy-${process.pid}-${++seq}.txt`;
      writeFileSync(tmp, Buffer.from(await opts.blob.arrayBuffer()));
      sql = text.replace(/'\/dev\/blob'/, `'${tmp.replace(/'/g, "''")}'`);
    }
    try {
      const r = await this.client.query({ text: sql, values: params && params.length ? params : undefined, rowMode: opts.rowMode === 'array' ? 'array' : undefined });
      return out(r);
    } finally {
      if (tmp) rmSync(tmp, { force: true });
    }
  }

  async exec(text) {
    const r = await this.client.query(text);
    return (Array.isArray(r) ? r : [r]).map(out);
  }

  async transaction(fn) {
    await this.client.query('BEGIN');
    try {
      const r = await fn(this);
      await this.client.query('COMMIT');
      return r;
    } catch (e) {
      await this.client.query('ROLLBACK').catch(() => undefined);
      throw e;
    }
  }

  async refreshArrayTypes() {}

  async dumpDataDir() {
    throw new Error('эталон на PostgreSQL: dumpDataDir недоступен');
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    await this.client.end().catch(() => undefined);
  }
}
export default PGlite;
