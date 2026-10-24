import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

/**
 * Покрытие агента G-be-credit (RM-G-002, RM-G-003, RM-G-011 refresh): наборы `test/receivables` и `test/discounts`
 * (unit + e2e на embedded PostgreSQL 17 — тестовые данные). Критичные по RM-G-009 решения — 100 % ветвей:
 * решение о продаже в долг (чистая `decideCredit` и `SnapshotCreditDecisionService`) и политика скидок
 * (`DiscountPolicyService`). Остальной код подмодулей — порог по строкам.
 *
 *   npm run test:cov:credit     # отчёт text-summary + text в coverage/stage-g-credit
 */
const CRITICAL: Record<string, { branches: number; lines: number }> = {
  'src/sales-domain/credit/credit-decision.ts': { branches: 100, lines: 100 },
  'src/sales-domain/adapters/snapshot-credit-decision.service.ts': { branches: 100, lines: 100 },
  // `DiscountPolicyService` — порт `DiscountPolicyPort` (отображение лимита роли, условия клиента); лимит и подтверждение
  // сверх лимита в корзине применяет `src/sales-domain/pricing/discount-policy.ts` — 100 % ветвей в vitest.config.cov-f.ts
  // (ревью G-credit-6).
  'src/customers/discounts/discount-policy.service.ts': { branches: 100, lines: 100 },
};

export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  test: {
    projects: [
      { extends: './test/receivables/vitest.config.ts', test: { name: 'receivables' } },
      { extends: './test/discounts/vitest.config.ts', test: { name: 'discounts' } },
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/stage-g-credit',
      reporter: ['text-summary', 'text'],
      include: [
        'src/sales-domain/credit/**/*.ts',
        'src/sales-domain/adapters/snapshot-credit-decision.service.ts',
        'src/customers/receivables/**/*.ts',
        'src/customers/discounts/**/*.ts',
        'src/admin/discount-limits/**/*.ts',
        'src/sync/receivables/**/*.ts',
        'src/sync/discounts/**/*.ts',
      ],
      exclude: ['**/*.spec.ts', '**/index.ts'],
      thresholds: {
        lines: 85,
        ...CRITICAL,
      },
    },
  },
});
