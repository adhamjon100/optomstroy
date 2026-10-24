import { defineConfig } from 'vitest/config';

/**
 * Объединённое покрытие pos-api для CI (job `api-integration` → `coverage-gate`; 13 §6.1 п. 3, RM-E-012 п. 3;
 * ревью E-trace-5): все наборы `npm run test:all` одним запуском — unit (src), e2e (test/e2e) и наборы на embedded
 * PostgreSQL 17 (test/<набор>/vitest.config.ts). Слой application (`*.service.ts`) проверяется в основном
 * интеграционными наборами, поэтому гейт строится по этому lcov (вместе с unit), а не по одному unit-проекту.
 *
 *   npm run test:cov:all      # lcov + text-summary в coverage/all
 */
const SUITES = [
  'integrations',
  'worker',
  'db',
  'foundation',
  'auth',
  'admin',
  'customers',
  'profile',
  'registration',
  'settings',
  'sms',
  'onec',
  'sync-apply',
  'sync',
  'catalog',
  'catalog-sync',
  'favorites',
  'search',
  'images',
];

export default defineConfig({
  test: {
    projects: [
      { extends: './vitest.config.ts', test: { name: 'unit' } },
      { extends: './vitest.config.e2e.ts', test: { name: 'e2e' } },
      ...SUITES.map((s) => ({ extends: `./test/${s}/vitest.config.ts`, test: { name: s } })),
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/all',
      reporter: ['lcov', 'text-summary'],
      include: ['src/**/*.ts'],
      exclude: ['**/*.spec.ts', '**/index.ts'],
    },
  },
});
