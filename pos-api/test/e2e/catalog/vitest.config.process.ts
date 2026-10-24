import { defineConfig } from 'vitest/config';

/**
 * Этап E на настоящих процессах (`npm run test:e2e:catalog`: сначала `npm run build`): только
 * `catalog-process.e2e-spec.ts` с `E2E_REAL_PROCESS=1` (local-stack catalog-smoke: dist/main.js, dist/migrate.js,
 * процесс загрузки каталога через FakeOnecGateway). В обычном `test:e2e` этот набор пропускается.
 */
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['test/e2e/catalog/catalog-process.e2e-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 600_000,
    hookTimeout: 180_000,
    env: { E2E_REAL_PROCESS: '1' },
  },
});
