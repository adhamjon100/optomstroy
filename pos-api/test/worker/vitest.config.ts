import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты worker/планировщика (RM-C-007): unit + интеграция на embedded PostgreSQL 17.
// Запуск: `npx vitest run --config test/worker/vitest.config.ts` (скрипт npm — у владельца package.json).
export default defineConfig({
  root: fileURLToPath(new URL('../..', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/worker/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 180_000,
  },
});
