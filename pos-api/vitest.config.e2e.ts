import { defineConfig } from 'vitest/config';

// e2e/интеграционные тесты: test/e2e/**/*.e2e-spec.ts (embedded PostgreSQL 17 или testcontainers в CI).
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['test/e2e/**/*.e2e-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 180_000,
  },
});
