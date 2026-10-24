import { defineConfig } from 'vitest/config';

/**
 * Покрытие модулей этапа F (13 RM-F-009: `cart/orders/payments` ≥ 80 % строк; интеграция backend этапа F — вместе с
 * документами, уведомлениями и доменом продаж): `src/cart/**`, `src/orders/**` (в т. ч. `src/orders/documents/**` и
 * обработчики `src/orders/worker/**`), `src/payments/**`, `src/notifications/**`, `src/sales-domain/**`. Модули
 * проверяются в основном наборами на embedded PostgreSQL 17 — покрытие собирается по проектам Vitest: unit (src),
 * e2e (test/e2e, в т. ч. test/e2e/pos), sales-domain, cart, orders, payments, documents, notifications, sms
 * (`src/notifications/sms` — этап D), worker. Порог — по сумме каталогов (≥ 80 % строк) и по каждому каталогу
 * отдельно (≥ 80 % строк, чтобы слабый модуль не прятался за сильными).
 *
 *   npm run test:cov:f        # отчёт text-summary + json-summary + text в coverage/stage-f
 */
const STAGE_F_DIRS = {
  cart: 'src/cart/**/*.ts',
  orders: 'src/orders/**/*.ts',
  documents: 'src/orders/documents/**/*.ts',
  payments: 'src/payments/**/*.ts',
  notifications: 'src/notifications/**/*.ts',
  salesDomain: 'src/sales-domain/**/*.ts',
} as const;

/**
 * Ветви критичных сценариев (13 RM-F-009: «создание заказа, платёж, идемпотентность — 100 % веток»; 12 C-10,
 * T-NFR-004; ревью F-trace-2, FIX-F-23). Закрытие этапа F (2026-10-23): достижимые ветви покрыты тестами (наборы
 * *-branches.spec на фейках портов и сквозные e2e/int на embedded PostgreSQL 17) — 100 % для создания заказа
 * (OrderCreateService, CheckoutPolicy), PaymentsPort, автоматов D-20/D-21/корзины/outbox и механизма
 * Idempotency-Key. Защитные ветви перечня `docs/stages/F_branch_exceptions.md` (E-1 — PaymentsService, E-2/E-3 —
 * обработчик результатов 1С; перечень **не утверждён владельцем 13**) покрыты тестами (ревью F, RC-7/RR-4):
 * `payments-service-branches.spec` (E-1), `order-onec-results.int.spec` (E-2, E-3) — пороги 100 % для всех
 * критичных файлов, любая новая непокрытая ветвь даёт красный прогон.
 */
const CRITICAL_BRANCHES: Record<string, { branches: number; lines?: number }> = {
  'src/sales-domain/idempotency/sales-idempotency.ts': { branches: 100 },
  'src/sales-domain/payment/payment-status.ts': { branches: 100 },
  'src/sales-domain/order/order-status.ts': { branches: 100 },
  'src/sales-domain/cart/cart-status.ts': { branches: 100 },
  // Лимит ручной скидки и подтверждение сверх лимита применяет корзина через `checkManualDiscount` (13 RM-G-009 п. 3
  // «скидка сверх лимита — 100 % веток»; ревью G-credit-6): `DiscountPolicyService` (cov-g) лимит только отображает.
  'src/sales-domain/pricing/discount-policy.ts': { branches: 100, lines: 100 },
  'src/sales-domain/outbox/outbox-status.ts': { branches: 100 },
  'src/orders/order-create.service.ts': { branches: 100, lines: 100 },
  'src/cart/checkout.service.ts': { branches: 100, lines: 100 },
  'src/payments/app/payments-port.service.ts': { branches: 100, lines: 100 },
  'src/payments/app/payments.service.ts': { branches: 100, lines: 100 },
  'src/orders/worker/order-onec-results.handler.ts': { branches: 100, lines: 100 },
  'src/common/idempotency/fingerprint.ts': { branches: 100, lines: 100 },
  'src/common/idempotency/idempotency.context.ts': { branches: 100, lines: 100 },
  'src/common/idempotency/idempotency.interceptor.ts': { branches: 100, lines: 100 },
  'src/common/idempotency/idempotency.repository.ts': { branches: 100, lines: 100 },
  'src/common/idempotency/idempotency.service.ts': { branches: 100, lines: 100 },
};

/** Механизм `Idempotency-Key` (этап C/D, общий для денежных маршрутов этапа F) — в отчёте ради порогов ветвей. */
const CRITICAL_EXTRA = ['src/common/idempotency/*.ts'];

export default defineConfig({
  test: {
    projects: [
      { extends: './vitest.config.ts', test: { name: 'unit' } },
      { extends: './vitest.config.e2e.ts', test: { name: 'e2e' } },
      { extends: './test/sales-domain/vitest.config.ts', test: { name: 'sales-domain' } },
      { extends: './test/cart/vitest.config.ts', test: { name: 'cart' } },
      { extends: './test/orders/vitest.config.ts', test: { name: 'orders' } },
      { extends: './test/payments/vitest.config.ts', test: { name: 'payments' } },
      { extends: './test/documents/vitest.config.ts', test: { name: 'documents' } },
      { extends: './test/notifications/vitest.config.ts', test: { name: 'notifications' } },
      { extends: './test/sms/vitest.config.ts', test: { name: 'sms' } },
      { extends: './test/worker/vitest.config.ts', test: { name: 'worker' } },
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/stage-f',
      reporter: ['text-summary', 'json-summary', 'text'],
      include: [...Object.values(STAGE_F_DIRS), ...CRITICAL_EXTRA],
      exclude: ['**/*.spec.ts', '**/index.ts'],
      thresholds: {
        lines: 80,
        ...Object.fromEntries(Object.values(STAGE_F_DIRS).map((g) => [g, { lines: 80 }])),
        ...CRITICAL_BRANCHES,
      },
    },
  },
});
