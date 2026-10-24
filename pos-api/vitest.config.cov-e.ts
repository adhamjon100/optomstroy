import { defineConfig } from 'vitest/config';

/**
 * Покрытие модулей этапа E (13 RM-E-012 п. 3: `sync` + `catalog` ≥ 80 % строк; интеграция этапа E — вместе с
 * адаптером 1С и избранным товаров): `src/sync/**`, `src/catalog/**`, `src/integrations/onec/**`,
 * `src/customers/favorites/**`. Модули проверяются в основном наборами на embedded PostgreSQL 17 — покрытие
 * собирается по проектам Vitest: unit (src), e2e (test/e2e, в т. ч. test/e2e/catalog), onec, sync-apply, sync,
 * catalog, catalog-sync, favorites, search, images, integrations. Порог — по сумме четырёх каталогов (≥ 80 % строк)
 * и отдельно по каждому каталогу (≥ 75 % строк, чтобы слабый модуль не прятался за сильными).
 *
 *   npm run test:cov:e        # отчёт text-summary + json-summary в coverage/stage-e
 */
const STAGE_E_DIRS = [
  'src/sync/**/*.ts',
  'src/catalog/**/*.ts',
  'src/integrations/onec/**/*.ts',
  'src/customers/favorites/**/*.ts',
];

/**
 * Обработчики синхронизации этапа G (клиенты и реализации, снимки долга, правила скидок — RM-G-001…RM-G-003) лежат в
 * `src/sync/**`, но проверяются наборами этапа G и покрытием `npm run test:cov:g` (vitest.config.cov-g.ts, порог
 * ≥ 80 % строк по каждому каталогу) — в регрессии этапа E не учитываются (интеграция backend этапа G).
 */
const STAGE_G_SYNC = ['src/sync/customers/**', 'src/sync/receivables/**', 'src/sync/discounts/**'];

export default defineConfig({
  test: {
    projects: [
      { extends: './vitest.config.ts', test: { name: 'unit' } },
      { extends: './vitest.config.e2e.ts', test: { name: 'e2e' } },
      { extends: './test/onec/vitest.config.ts', test: { name: 'onec' } },
      { extends: './test/sync-apply/vitest.config.ts', test: { name: 'sync-apply' } },
      { extends: './test/sync/vitest.config.ts', test: { name: 'sync' } },
      { extends: './test/catalog/vitest.config.ts', test: { name: 'catalog' } },
      { extends: './test/catalog-sync/vitest.config.ts', test: { name: 'catalog-sync' } },
      { extends: './test/favorites/vitest.config.ts', test: { name: 'favorites' } },
      { extends: './test/search/vitest.config.ts', test: { name: 'search' } },
      { extends: './test/images/vitest.config.ts', test: { name: 'images' } },
      { extends: './test/integrations/vitest.config.ts', test: { name: 'integrations' } },
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/stage-e',
      reporter: ['text-summary', 'json-summary', 'text'],
      include: STAGE_E_DIRS,
      exclude: ['**/*.spec.ts', '**/index.ts', ...STAGE_G_SYNC],
      thresholds: {
        lines: 80,
        'src/sync/**/*.ts': { lines: 75 },
        'src/catalog/**/*.ts': { lines: 75 },
        'src/integrations/onec/**/*.ts': { lines: 75 },
        'src/customers/favorites/**/*.ts': { lines: 75 },
      },
    },
  },
});
