import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, агент G-be-credit (RM-G-002, RM-G-011 refresh): долги клиентов, решение о продаже в долг (10 PAY-031),
// `/customers/{id}/receivables`, `/receivables/overdue`, синхронизация снимков. Unit-наборы — без БД; e2e — стенд
// `test/support/cashier-fixture.ts` (embedded PostgreSQL 17, фейк 1С в режиме кассира — тестовые данные).
// Запуск из pos-api/: `npm run test:receivables`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/receivables/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
