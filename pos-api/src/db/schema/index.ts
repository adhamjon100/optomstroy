// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

/** Drizzle-схема «Оптомстрой POS»: все таблицы и enum-ы БД (RM-C-006). */
export * from './enums.js';
export * from './auth.js';
export * from './catalog.js';
export * from './customers.js';
export * from './sales.js';
export * from './sync.js';
