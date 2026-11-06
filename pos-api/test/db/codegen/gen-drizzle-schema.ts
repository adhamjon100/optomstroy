import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { DEV_MIGRATIONS_SCHEMA, migrate } from '../../../src/db/migrator.js';
import { EmbeddedPg } from '../../support/embedded-pg.js';
import { readEnums, readTables } from '../support/catalog.js';
import { generateSchema } from './drizzle-codegen.js';
import { expectedTables, MIGRATIONS_DIR, SCHEMA_DIR } from '../support/paths.js';

/**
 * Перегенерация src/db/schema/*.ts (RM-C-006): одноразовый PostgreSQL 17 → migrations/*.sql и db/migrations-dev/*.sql
 * (app.env=dev, как `migrate` при APP_ENV=dev — все таблицы scripts/check_tables.sql, включая dev_outbox) → каталог →
 * Drizzle. Запуск из pos-api: `npx tsx test/db/codegen/gen-drizzle-schema.ts`, затем `npx prettier --write src/db/schema`.
 */
const DEV_MIGRATIONS_DIR = fileURLToPath(new URL('../../../db/migrations-dev/', import.meta.url));
const silent = { info: () => undefined, warn: () => undefined };

const db = new EmbeddedPg();
await db.start();
try {
  await db.createDatabase('pos_codegen');
  const client = new pg.Client({ connectionString: db.url('pos_codegen') });
  await client.connect();
  try {
    await migrate(client, { dir: MIGRATIONS_DIR, appEnv: 'dev', logger: silent });
    await migrate(client, {
      dir: DEV_MIGRATIONS_DIR,
      appEnv: 'dev',
      logger: silent,
      journalSchema: DEV_MIGRATIONS_SCHEMA,
    });
    const files = generateSchema(await readTables(client), await readEnums(client), expectedTables());
    for (const f of files) {
      writeFileSync(join(SCHEMA_DIR, f.file), f.content, 'utf8');
      process.stdout.write(`written src/db/schema/${f.file}\n`);
    }
  } finally {
    await client.end();
  }
} finally {
  await db.stop();
}
