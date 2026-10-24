import { defineConfig } from 'vitest/config';

/**
 * Покрытие модулей этапа G «Кассир» (13 RM-G-009 п. 2–3; интеграция backend этапа G): клиенты (поиск, карточка,
 * история, создание, долги, скидки, избранное, чтение карточки для портов, результаты 1С), журнал транзакций и
 * дашборд кассира, возвраты, аудит и отчёты администратора, лимиты скидок, синхронизация клиентов/долгов/скидок
 * (обработчики плана обмена), решение о продаже в долг и общий писатель журнала `transactions`. Модули проверяются в
 * основном наборами на embedded PostgreSQL 17 — покрытие собирается по проектам Vitest. Порог — по сумме каталогов
 * (≥ 80 % строк) и по каждому каталогу отдельно (≥ 80 % строк, чтобы слабый модуль не прятался за сильными).
 *
 *   npm run test:cov:g        # отчёт text-summary + json-summary + text в coverage/stage-g
 *   node scripts/coverage-by-dir.mjs coverage/stage-g src/customers src/returns src/transactions src/admin
 */
const STAGE_G_DIRS = {
  customersSearch: 'src/customers/search/**/*.ts',
  customersHistory: 'src/customers/history/**/*.ts',
  customersDirectory: 'src/customers/directory/**/*.ts',
  customersCommon: 'src/customers/common/**/*.ts',
  customersReader: 'src/customers/reader/**/*.ts',
  customersJobs: 'src/customers/jobs/**/*.ts',
  receivables: 'src/customers/receivables/**/*.ts',
  discounts: 'src/customers/discounts/**/*.ts',
  favorites: 'src/customers/favorites/favorites-customers.*.ts',
  transactions: 'src/transactions/**/*.ts',
  dashboard: 'src/payments/dashboard/**/*.ts',
  returns: 'src/returns/**/*.ts',
  // Подкаталог проекции 1С и моста pg-boss — отдельным порогом, чтобы не прятался за src/returns (ревью G-fresh-run-3).
  returnsOnec: 'src/returns/onec/**/*.ts',
  adminAudit: 'src/admin/audit/**/*.ts',
  adminReports: 'src/admin/reports/**/*.ts',
  adminDiscountLimits: 'src/admin/discount-limits/**/*.ts',
  syncCustomers: 'src/sync/customers/**/*.ts',
  syncReceivables: 'src/sync/receivables/**/*.ts',
  syncDiscounts: 'src/sync/discounts/**/*.ts',
  journal: 'src/common/journal/**/*.ts',
  credit: 'src/sales-domain/credit/**/*.ts',
} as const;

/**
 * Критичные решения этапа G (13 RM-G-009 п. 3: «долг, скидка сверх лимита, аудит — 100 % веток»): решение о продаже в
 * долг (чистая `decideCredit` и сервис порта по снимку), политика скидок (лимит роли, потолок одобрения — скидка сверх
 * лимита) и проверка цепочки аудита (`verifyAuditChain` / CLI `scripts/verify_audit_chain.ts`).
 */
const CRITICAL_BRANCHES: Record<string, { branches: number; lines: number }> = {
  'src/sales-domain/credit/credit-decision.ts': { branches: 100, lines: 100 },
  'src/sales-domain/adapters/snapshot-credit-decision.service.ts': { branches: 100, lines: 100 },
  // `DiscountPolicyService` — порт `DiscountPolicyPort` (отображение лимита роли, условия клиента); лимит и подтверждение
  // сверх лимита в корзине применяет `src/sales-domain/pricing/discount-policy.ts` — 100 % ветвей в vitest.config.cov-f.ts
  // (ревью G-credit-6).
  'src/customers/discounts/discount-policy.service.ts': { branches: 100, lines: 100 },
  'src/admin/audit/audit-chain.verifier.ts': { branches: 100, lines: 100 },
};

export default defineConfig({
  test: {
    projects: [
      { extends: './vitest.config.ts', test: { name: 'unit' } },
      { extends: './vitest.config.e2e.ts', test: { name: 'e2e' } },
      { extends: './test/customers/vitest.config.ts', test: { name: 'customers' } },
      { extends: './test/receivables/vitest.config.ts', test: { name: 'receivables' } },
      { extends: './test/discounts/vitest.config.ts', test: { name: 'discounts' } },
      { extends: './test/transactions/vitest.config.ts', test: { name: 'transactions' } },
      { extends: './test/returns/vitest.config.ts', test: { name: 'returns' } },
      { extends: './test/reports/vitest.config.ts', test: { name: 'reports' } },
      { extends: './test/customer-mode/vitest.config.ts', test: { name: 'customer-mode' } },
      { extends: './test/cashier-foundation/vitest.config.ts', test: { name: 'cashier-foundation' } },
      { extends: './test/admin/vitest.config.ts', test: { name: 'admin' } },
      { extends: './test/worker/vitest.config.ts', test: { name: 'worker' } },
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/stage-g',
      reporter: ['text-summary', 'json-summary', 'text'],
      include: [...Object.values(STAGE_G_DIRS), 'src/sales-domain/adapters/snapshot-credit-decision.service.ts'],
      exclude: ['**/*.spec.ts', '**/index.ts'],
      thresholds: {
        lines: 80,
        ...Object.fromEntries(Object.values(STAGE_G_DIRS).map((g) => [g, { lines: 80 }])),
        ...CRITICAL_BRANCHES,
      },
    },
  },
});
