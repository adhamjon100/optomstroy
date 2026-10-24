import type { CreditReason } from '../../common/enums.js';
import { MoneyMath } from '../../common/money/money-math.js';
import { Money } from '../../common/money/money.js';
import { RECEIVABLES_CLOCK_SKEW_MS } from '../../common/ports/receivables-snapshot.port.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Решение о продаже в долг — строго по порядку 10 PAY-031 (ядро §22.4 в редакции §23 п. 5; первая сработавшая
 * проверка завершает обработку). Для долга `503 ONEC_UNAVAILABLE` **не возвращается**.
 *
 * 1. Право роли и клиент: нет `credit.sale.create` → `403 FORBIDDEN` (`forbidden_role`); клиент не выбран,
 *    «Розничный покупатель» или без `onec_ref` → `422 CUSTOMER_NOT_IDENTIFIED` (без `creditReason`);
 *    `credit_allowed=false` → `422 CREDIT_BLOCKED` (`credit_not_allowed`).
 * 2. Известная блокировка в имеющемся снимке (любого возраста, без 1С): `overdue_amount > 0` → `CREDIT_BLOCKED`
 *    (`overdue`); `total > credit_limit − balance − open_orders` или лимит не задан → `CREDIT_LIMIT_EXCEEDED`
 *    (`limit_exceeded`). `creditOverride` (PAY-032) снимает **только** блокировки шага 2.
 * 3. Снимка нет, он неполон (`overdue_amount IS NULL`) или старше `RECEIVABLES_MAX_AGE_MIN` → синхронное обновление
 *    из 1С (таймаут 6000 мс) и повтор шага 2; 1С недоступна, режим C-2 или обновлённый снимок неполон →
 *    `422 RECEIVABLES_STALE` (`stale_snapshot`).
 * 4. Свежий полный снимок без блокировок → долг разрешён без обращения к 1С.
 *
 * Функция чистая: обновление снимка выполняет вызывающий. Если нужен шаг 3, возвращается `refresh_required`;
 * вызывающий пытается обновить и вызывает функцию снова с `refresh` (исход попытки).
 */
export interface ReceivablesSnapshot {
  readonly balance: Money;
  /** `null` — просрочка неизвестна (снимок неполон). */
  readonly overdueAmount: Money | null;
  /** `receivables.onec_snapshot_at`. */
  readonly snapshotAt: Date;
}

export interface CreditCustomer {
  /** Системный «Розничный покупатель» (`customers.is_retail_default`). */
  readonly isRetailDefault: boolean;
  /** Карточка идентифицирована в 1С (`onec_ref IS NOT NULL`). */
  readonly hasOnecRef: boolean;
  readonly creditAllowed: boolean;
  /** `customers.credit_limit`; `null` — лимит в 1С не задан (DEBT-012, до Q-017 — `limit_exceeded`). */
  readonly creditLimit: Money | null;
}

export interface CreditDecisionInput {
  /** Право `credit.sale.create` (и не режим клиента). */
  readonly canSellOnCredit: boolean;
  /** `null` — клиент не выбран. */
  readonly customer: CreditCustomer | null;
  readonly snapshot: ReceivablesSnapshot | null;
  /** Сумма открытых заказов клиента в долг, ещё не отражённых в снимке 1С (MV-21, MV-22). */
  readonly openOrdersAmount: Money;
  /** Итог заказа. */
  readonly total: Money;
  readonly now: Date;
  /** `RECEIVABLES_MAX_AGE_MIN` (ключ `receivables.max_age_minutes`). */
  readonly maxAgeMinutes: number;
  /** Подтверждение `senior_seller` в собственной сессии со step-up и причиной (PAY-032) — проверено сервисом. */
  readonly override: boolean;
  /**
   * Исход попытки синхронного обновления (шаг 3): `undefined` — ещё не пытались; `unavailable` — таймаут, сеть, 5xx
   * или режим C-2 (`ONEC_INBOUND_ENABLED=true`); `refreshed` — `snapshot` уже обновлённый.
   */
  readonly refresh?: 'refreshed' | 'unavailable';
}

export type CreditDecision =
  | {
      readonly kind: 'allowed';
      /** `credit_limit − balance − open_orders − total` не считается: `limitRemaining` — до заказа. */
      readonly limitRemaining: Money | null;
      readonly receivablesAsOf: Date;
      /** Разрешено благодаря `creditOverride` (аудит, `transactions.kind=credit_sale_approved`). */
      readonly overrideUsed: boolean;
    }
  | { readonly kind: 'refresh_required' }
  | {
      readonly kind: 'refused';
      readonly code:
        'FORBIDDEN' | 'CUSTOMER_NOT_IDENTIFIED' | 'CREDIT_BLOCKED' | 'CREDIT_LIMIT_EXCEEDED' | 'RECEIVABLES_STALE';
      readonly creditReason: CreditReason | null;
      readonly step: 1 | 2 | 3;
      readonly detail: string;
      readonly limitRemaining?: Money | null;
      readonly overdueAmount?: Money;
      readonly receivablesAsOf?: Date | null;
    };

const MINUTE_MS = 60_000;

/** Свежий: `0 ≤ now − snapshotAt ≤ maxAge` с допуском часов 1С; метка «из будущего» — непригодна (ревью G-credit-2). */
function isFresh(s: ReceivablesSnapshot, now: Date, maxAgeMinutes: number): boolean {
  const age = now.getTime() - s.snapshotAt.getTime();
  return age >= -RECEIVABLES_CLOCK_SKEW_MS && age <= maxAgeMinutes * MINUTE_MS;
}

function fmt(m: Money): string {
  return m.toString().replace('.', ',');
}

/** Шаг 2 по имеющемуся снимку; `null` — блокировок не найдено. */
function knownBlock(i: CreditDecisionInput, c: CreditCustomer, s: ReceivablesSnapshot): CreditDecision | null {
  if (s.overdueAmount !== null && !s.overdueAmount.isZero() && !s.overdueAmount.isNegative()) {
    return {
      kind: 'refused',
      code: 'CREDIT_BLOCKED',
      creditReason: 'overdue',
      step: 2,
      detail: `Есть просроченная задолженность ${fmt(s.overdueAmount)} сом.`,
      overdueAmount: s.overdueAmount,
      receivablesAsOf: s.snapshotAt,
    };
  }
  if (c.creditLimit === null) {
    return {
      kind: 'refused',
      code: 'CREDIT_LIMIT_EXCEEDED',
      creditReason: 'limit_exceeded',
      step: 2,
      detail: 'Лимит в 1С не задан.',
      limitRemaining: null,
      receivablesAsOf: s.snapshotAt,
    };
  }
  const remaining = MoneyMath.creditRemaining(c.creditLimit, s.balance, i.openOrdersAmount);
  if (i.total.compare(remaining) > 0) {
    return {
      kind: 'refused',
      code: 'CREDIT_LIMIT_EXCEEDED',
      creditReason: 'limit_exceeded',
      step: 2,
      detail: `Превышен лимит: доступно ${fmt(remaining.isNegative() ? Money.ZERO : remaining)} сом.`,
      limitRemaining: remaining,
      receivablesAsOf: s.snapshotAt,
    };
  }
  return null;
}

export function decideCredit(i: CreditDecisionInput): CreditDecision {
  // Шаг 1.
  if (!i.canSellOnCredit) {
    return {
      kind: 'refused',
      code: 'FORBIDDEN',
      creditReason: 'forbidden_role',
      step: 1,
      detail: 'Продажа в долг недоступна для вашей роли.',
    };
  }
  const c = i.customer;
  if (!c || c.isRetailDefault || !c.hasOnecRef) {
    return {
      kind: 'refused',
      code: 'CUSTOMER_NOT_IDENTIFIED',
      creditReason: null,
      step: 1,
      detail: 'Для продажи в долг выберите клиента из 1С.',
    };
  }
  if (!c.creditAllowed) {
    return {
      kind: 'refused',
      code: 'CREDIT_BLOCKED',
      creditReason: 'credit_not_allowed',
      step: 1,
      detail: 'Соглашение клиента не допускает отсрочку.',
    };
  }
  // Шаг 2 — по имеющемуся снимку любого возраста; override снимает только этот шаг.
  const s = i.snapshot;
  let overrideUsed = false;
  if (s) {
    const block = knownBlock(i, c, s);
    if (block) {
      if (!i.override) return block;
      overrideUsed = true;
    }
  }
  // Шаг 3.
  const usable = s !== null && s.overdueAmount !== null && isFresh(s, i.now, i.maxAgeMinutes);
  if (!usable) {
    if (i.refresh === undefined) return { kind: 'refresh_required' };
    return {
      kind: 'refused',
      code: 'RECEIVABLES_STALE',
      creditReason: 'stale_snapshot',
      step: 3,
      detail: 'Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR.',
      receivablesAsOf: s?.snapshotAt ?? null,
    };
  }
  // Шаг 4 (после обновления шаг 2 уже повторён выше по свежему снимку).
  const remaining =
    c.creditLimit === null ? null : MoneyMath.creditRemaining(c.creditLimit, s.balance, i.openOrdersAmount);
  return { kind: 'allowed', limitRemaining: remaining, receivablesAsOf: s.snapshotAt, overrideUsed };
}

/** Отказ → `SalesDomainError` (HTTP 403/422 по 08 §2.4; `creditReason` — расширение Problem). */
export function creditRefusalError(d: Extract<CreditDecision, { kind: 'refused' }>): SalesDomainError {
  return new SalesDomainError(d.code, d.detail, {
    ...(d.creditReason ? { creditReason: d.creditReason } : {}),
    ...(d.limitRemaining !== undefined && d.limitRemaining !== null
      ? { limitRemaining: d.limitRemaining.toJSON() }
      : {}),
  });
}
