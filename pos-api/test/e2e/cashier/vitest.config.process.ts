import { defineConfig } from 'vitest/config';

/**
 * Этап G на настоящих процессах (`npm run test:e2e:cashier`: сначала `npm run build`): только
 * `cashier-process.e2e-spec.ts` с `E2E_REAL_PROCESS=1` (local-stack cashier-smoke: dist/main.js, dist/worker.js,
 * управляемый фейк HTTP-сервиса 1С в режиме кассира). В обычном `test:e2e` этот набор пропускается.
 */
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['test/e2e/cashier/cashier-process.e2e-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 1_200_000,
    hookTimeout: 180_000,
    env: { E2E_REAL_PROCESS: '1' },
  },
});
