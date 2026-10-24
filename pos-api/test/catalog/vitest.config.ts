import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-004, RM-E-014 (catalog), RM-E-017 (проекция customer): Catalog API и /inventory/* на embedded PostgreSQL 17
// (все миграции + синтетический каталог, загруженный конвейером 1С из FakeOnecGateway — тестовые данные).
// Запуск из pos-api/: `npm run test:catalog`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/catalog/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
