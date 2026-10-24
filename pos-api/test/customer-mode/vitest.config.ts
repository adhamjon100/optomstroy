import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, агент G-be-admin-reports: серверная часть режима клиента (RM-G-014; 10 CUST-024, CUST-025; 11 SEC-030).
// Стенд — `test/support/cashier-fixture.ts` (embedded PostgreSQL 17, фейк 1С в режиме кассира — тестовые данные).
// Запуск из pos-api/: `npm run test:customer-mode`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/customer-mode/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
