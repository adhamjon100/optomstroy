import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-006 (избранное и недавние): e2e на одноразовом PostgreSQL 17 (embedded) с синтетическим каталогом
// (startCatalogFixture — конвейер 1С на FakeOnecGateway; тестовые данные, не реальная интеграция).
// Запуск из pos-api/: `npm run test:favorites`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/favorites/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
