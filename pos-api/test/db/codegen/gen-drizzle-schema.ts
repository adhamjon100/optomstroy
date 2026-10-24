import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';
import { migrate } from '../../../src/db/migrator.js';
import { EmbeddedPg } from '../../support/embedded-pg.js';
import { readEnums, readTables } from '../support/catalog.js';
import { generateSchema } from './drizzle-codegen.js';
import { expectedTables, MIGRATIONS_DIR, SCHEMA_DIR } from '../support/paths.js';

/**
 * Перегенерация src/db/schema/*.ts (RM-C-006): одноразовый PostgreSQL 17 → migrations/*.sql (app.env=dev,
 * все 64 таблицы) → каталог → Drizzle. Запуск из pos-api: `npx tsx test/db/codegen/gen-drizzle-schema.ts`,
 * затем `npx prettier --write src/db/schema`.
 */
const silent = { info: () => undefined, warn: () => undefined };

const db = new EmbeddedPg();
await db.start();
try {
  await db.createDatabase('pos_codegen');
  const client = new pg.Client({ connectionString: db.url('pos_codegen') });
  await client.connect();
  try {
    await migrate(client, { dir: MIGRATIONS_DIR, appEnv: 'dev', logger: silent });
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
