import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, основа backend: домен продаж (автоматы заказа D-20, payment_status 07 §6.4, onec_outbox 07 §6.5,
// cart_status; цены/скидки/долг; идемпотентность), порты `common/ports` и стенд `test/support/pos-fixture.ts`
// (embedded PostgreSQL 17 + синтетический каталог — тестовые данные). Запуск из pos-api/: `npm run test:sales-domain`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/sales-domain/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
