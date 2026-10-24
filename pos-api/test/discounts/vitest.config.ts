import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, агент G-be-credit (RM-G-003): лимиты ручной скидки по ролям, скидки клиента 1С,
// `/customers/{id}/discounts`, `/discounts/rules`, `/admin/discount-limits`, синхронизация `discount_rules`. Unit-наборы — без БД; e2e — стенд
// `test/support/cashier-fixture.ts` (embedded PostgreSQL 17, фейк 1С в режиме кассира — тестовые данные).
// Запуск из pos-api/: `npm run test:discounts`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/discounts/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
