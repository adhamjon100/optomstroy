import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты БД RM-C-006 (миграции, seed, сверка Drizzle-схемы, выгрузка DDL) на одноразовом PostgreSQL 17
// (embedded-postgres, без Docker). Запуск из pos-api: `npx vitest run --config test/db/vitest.config.ts`.
// Отдельный конфиг — чтобы не менять vitest.config*.ts владельца каркаса (RM-C-005).
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: fileURLToPath(new URL('../..', import.meta.url)),
    include: ['test/db/**/*.db-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 240_000,
  },
});
