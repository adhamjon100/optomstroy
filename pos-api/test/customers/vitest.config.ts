import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-D-005 (привязка к клиенту 1С): e2e на одноразовом PostgreSQL 17 (embedded-postgres) и FakeOnecGateway.
// Запуск из pos-api/: `npx vitest run --config test/customers/vitest.config.ts`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/customers/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
