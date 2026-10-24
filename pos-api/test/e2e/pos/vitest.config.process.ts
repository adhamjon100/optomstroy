import { defineConfig } from 'vitest/config';

/**
 * Этап F на настоящих процессах (`npm run test:e2e:pos`: сначала `npm run build`): только `pos-process.e2e-spec.ts`
 * с `E2E_REAL_PROCESS=1` (local-stack pos-smoke: dist/main.js, dist/worker.js, управляемый фейк HTTP-сервиса 1С
 * `scripts/pos_fake_onec.ts`). В обычном `test:e2e` этот набор пропускается.
 */
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['test/e2e/pos/pos-process.e2e-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 900_000,
    hookTimeout: 180_000,
    env: { E2E_REAL_PROCESS: '1' },
  },
});
