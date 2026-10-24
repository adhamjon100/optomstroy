import { customType } from 'drizzle-orm/pg-core';

/**
 * Типы PostgreSQL без встроенного построителя в drizzle-orm 0.45 (RM-C-006).
 * Используются сгенерированной схемой src/db/schema/*.ts (test/db/codegen/drizzle-codegen.ts).
 */

/** bytea ↔ Buffer (node-postgres возвращает Buffer). */
export const bytea = customType<{ data: Buffer; driverData: Buffer }>({
  dataType: () => 'bytea',
});

/**
 * tsvector — generated-столбцы поиска (07 §10); значение вычисляет БД, приложение его не пишет и читает
 * как текст.
 */
export const tsvector = customType<{ data: string; driverData: string }>({
  dataType: () => 'tsvector',
});
