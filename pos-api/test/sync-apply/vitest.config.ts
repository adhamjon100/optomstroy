import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-001: конвейер применения данных 1С к репликам каталога на embedded PostgreSQL 17 (все миграции).
// Запуск из pos-api/: `npm run test:sync-apply`. Данные — фикстуры 1С и синтетика (тестовые данные).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/sync-apply/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 240_000,
  },
});
