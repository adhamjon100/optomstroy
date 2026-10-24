import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-D-015 (GET /settings/public): e2e на одноразовом PostgreSQL 17 + unit сервиса и скрипт сверки с 08 §4.18.6.
// Запуск из pos-api/: `npx vitest run --config test/settings/vitest.config.ts`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/settings/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
