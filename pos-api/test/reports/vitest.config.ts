import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, агент G-be-admin-reports: отчёты руководителя /admin/reports/* (RM-G-006; 08 §4.18.8).
// Стенд — `test/support/cashier-fixture.ts` (embedded PostgreSQL 17, фейк 1С в режиме кассира — тестовые данные).
// Запуск из pos-api/: `npm run test:reports`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/reports/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
