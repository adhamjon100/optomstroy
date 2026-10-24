import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-005 / RM-E-014 (поиск): unit + e2e на embedded PostgreSQL 17 (UTF-8 LC_CTYPE, все миграции) и синтетическом
// каталоге через конвейер применения 1С (тестовые данные, не реальная интеграция).
// Запуск из pos-api/: `npm run test:search`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/search/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
