import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, модуль `orders` (RM-F-002, RM-F-012, RM-F-015): создание заказа, outbox → 1С (FakeOnecGateway),
// проекция статусов D-20, отмена, ручная привязка, списки и права — на embedded PostgreSQL 17 со стендом
// `test/support/pos-fixture.ts` (тестовые данные). Запуск из pos-api/: `npm run test:orders`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/orders/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
