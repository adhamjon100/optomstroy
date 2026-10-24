import type { DiscountKind, DiscountSource, RoleCode } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `DiscountPolicyPort` (этап G, RM-G-003; 06 §7.4 `DiscountService.limitFor(role)`) — лимиты ручной скидки по
 * ролям (`role_discount_limits`, ядро §22.10 — только по ролям; значения seed `seller 5 / cashier 5 / senior 10 /
 * admin 15 / owner 0` [НЕ ПОДТВЕРЖДЕНО: Q-015]) и правила скидок клиента из 1С (`discount_rules`,
 * `customers.discount_percent`, вид цены; DISC-007, DISC-013). Автоматические скидки 1С backend не воспроизводит —
 * итог 1С истина (DISC-006, DISC-015).
 *
 * Реализация — агент G-be-credit (`pos-api/src/customers/discounts/**`, `bindSalesPort`). Потребители: `cart`
 * (лимит роли — сейчас читает `role_discount_limits` напрямую, `cart-actor.ts`; переход на порт — по желанию
 * владельца cart без изменения поведения), `/customers/{id}/discounts`, `/discounts/rules`, дашборд кассира
 * (блок «Скидки и условия»), SCR-46. Заглушка — `test/support/cashier-ports.fakes.ts` (`StubDiscountPolicy`).
 */
export const DISCOUNT_POLICY_PORT = 'sales.DiscountPolicyPort' as const;

/** Строка `role_discount_limits` (07 §5.34). Проценты — строки `"5.00"`. */
export interface RoleDiscountLimitView {
  readonly role: RoleCode;
  readonly maxPercent: string;
  readonly canApproveOverLimit: boolean;
  /** Потолок подтверждения сверх лимита; `null` — не задан (до 100 %). */
  readonly approveMaxPercent: string | null;
  /** Порог, сверх которого обязательна причина; `null` — не задан. */
  readonly requiresReasonOverPercent: string | null;
  readonly rowVersion: number;
}

/** Правило скидки (08 `DiscountRule`). */
export interface DiscountRuleView {
  readonly id: string;
  readonly source: DiscountSource;
  readonly name: string;
  readonly kind: DiscountKind;
  /** Процент `"5.00"` или сумма `NUMERIC(14,2)`; для `price_list` — `"0.00"`. */
  readonly value: string;
  readonly appliesAutomatically: boolean;
  readonly isActive: boolean;
  /** `YYYY-MM-DD` или `null`. */
  readonly validFrom: string | null;
  readonly validTo: string | null;
  readonly conditions: {
    readonly minTotal?: MoneyString;
    readonly categoryIds?: readonly string[];
    readonly customerIds?: readonly string[];
  };
  readonly description: string | null;
}

/** Скидки и условия клиента (SCR-35, `GET /customers/{id}/discounts`; 08 `CustomersDiscountsResponse`). */
export interface CustomerDiscountTerms {
  readonly customerId: string;
  readonly priceListId: string | null;
  /** Скидка клиента 1С; `null` — данных нет (DISC-007: в предрасчёте не применяется). */
  readonly customerDiscountPercent: string | null;
  /** Действующие на дату правила, относящиеся к клиенту (без условий клиента или с ним в `customerIds`). */
  readonly rules: readonly DiscountRuleView[];
  readonly creditAllowed: boolean;
  readonly paymentTermDays: number | null;
  readonly creditLimit: MoneyString | null;
  readonly asOf: Date;
}

export interface DiscountPolicyPort {
  /** Все строки `role_discount_limits` (SCR-46, `/admin/discount-limits`). */
  limits(tx: SalesTx | null): Promise<readonly RoleDiscountLimitView[]>;

  /**
   * Лимит ручной скидки субъекта — максимум по его ролям (`"0.00"` для `customer`, ядро §24.2; неизвестная роль →
   * `"0.00"`, fail-closed).
   */
  limitFor(tx: SalesTx | null, actor: SalesActor): Promise<string>;

  /** Может ли субъект подтвердить скидку `percent` сверх своего лимита (DISC-010; `discount.approve.over_limit`). */
  canApproveOverLimit(tx: SalesTx | null, actor: SalesActor, percent: string): Promise<boolean>;

  /** Действующие правила (`/discounts/rules`): `is_active`, период по `on` (по умолчанию — сегодня Asia/Bishkek). */
  activeRules(tx: SalesTx | null, on?: Date): Promise<readonly DiscountRuleView[]>;

  /** Скидки и условия клиента; `null` — клиента нет. */
  customerTerms(tx: SalesTx | null, customerId: string, on?: Date): Promise<CustomerDiscountTerms | null>;
}
