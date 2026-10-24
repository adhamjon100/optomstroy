import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-015 (GET /catalog/sync/{entity}): e2e на одноразовом PostgreSQL 17 (embedded) с синтетическим каталогом
// (startCatalogFixture — конвейер 1С на FakeOnecGateway; тестовые данные, не реальная интеграция) + unit курсора.
// Запуск из pos-api/: `npm run test:catalog-sync`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/catalog-sync/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
