import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, агент G-be-txn-returns (RM-G-004, RM-G-005, RM-G-011, RM-G-013): журнал операций, дашборд кассира, guard оплаты долга —
// embedded PostgreSQL 17, фейк 1С в режиме кассира (тестовые данные). Запуск из pos-api/: `npm run test:transactions`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/transactions/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
