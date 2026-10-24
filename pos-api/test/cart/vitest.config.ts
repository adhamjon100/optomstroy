import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, агент F-be-cart (RM-F-001, RM-F-012, RM-F-015): корзина 08 §4.7, checkout-preview (CheckoutPolicy), порт
// CartReader, минимальный GET /search/customers, фоновые задачи корзины — на стенде test/support/pos-fixture.ts
// (embedded PostgreSQL 17 + синтетический каталог — тестовые данные). Запуск из pos-api/: `npm run test:cart`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/cart/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
