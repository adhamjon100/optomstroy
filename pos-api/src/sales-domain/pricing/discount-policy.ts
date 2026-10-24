import { SalesDomainError } from '../domain-error.js';
import { hundredthsToPercent, percentToHundredths } from './percent.js';

/**
 * Политика ручной скидки документа (10 DISC-001…DISC-012, CUST-021; 07 §5.34 `role_discount_limits`; ядро §22.10 —
 * лимиты только по ролям). Одна скидка в % на документ; сверх лимита инициатора — только `senior_seller`/`admin` в
 * **собственной сессии** со step-up и причиной (`discountOverride{reason}`, право `discount.approve.over_limit`,
 * CASH-007) в пределах своего лимита подтверждения.
 */
export interface RoleDiscountLimit {
  /** `role_discount_limits.max_percent` (строка `NUMERIC(5,2)`). */
  readonly maxPercent: string;
  readonly canApproveOverLimit: boolean;
  /** `approve_max_percent`; `null` — равен `maxPercent` (07 §5.34: не задан ТЗ). */
  readonly approveMaxPercent: string | null;
}

export interface ManualDiscountInput {
  /** Запрошенный процент (`manualDiscountPercent`). */
  readonly requestedPercent: string;
  /** Режим клиента (`customer`): ручная скидка → `403 FORBIDDEN` (CUST-021, API-179). */
  readonly isCustomer: boolean;
  /** Лимит роли инициатора (владельца корзины); `null` — строки нет → лимит 0 (fail-closed). */
  readonly initiatorLimit: RoleDiscountLimit | null;
  /**
   * Подтверждение сверх лимита: лимит подтверждающего (текущий пользователь с `discount.approve.over_limit`,
   * step-up уже проверен сервисом) и причина. Без подтверждения — `undefined`.
   */
  readonly override?: { readonly approverLimit: RoleDiscountLimit; readonly reason: string };
}

export interface ManualDiscountDecision {
  /** Применённый процент (канонический `"7.00"`). */
  readonly appliedPercent: string;
  /** Лимит роли инициатора (`Cart.discountLimitPercent`, `CheckoutPreview.permissions.discountLimitPercent`). */
  readonly limitPercent: string;
  /** Скидка сверх лимита подтверждена (`approved_by_user_id`, аудит, `transactions.kind=discount_override`). */
  readonly overrideApplied: boolean;
}

export const MIN_OVERRIDE_REASON_LENGTH = 3;

export function checkManualDiscount(i: ManualDiscountInput): ManualDiscountDecision {
  const requested = percentToHundredths(i.requestedPercent, 'manualDiscountPercent');
  const limit = i.initiatorLimit ? percentToHundredths(i.initiatorLimit.maxPercent) : 0n;
  const limitPercent = hundredthsToPercent(limit);
  if (i.isCustomer) {
    if (requested > 0n || i.override) {
      throw new SalesDomainError('FORBIDDEN', 'Ручная скидка в режиме клиента недоступна.', {
        reason: 'customer_manual_discount',
      });
    }
    return { appliedPercent: '0.00', limitPercent: '0.00', overrideApplied: false };
  }
  if (requested <= limit) {
    return { appliedPercent: hundredthsToPercent(requested), limitPercent, overrideApplied: false };
  }
  const o = i.override;
  if (o) {
    if (!o.approverLimit.canApproveOverLimit) {
      throw new SalesDomainError('FORBIDDEN', 'Нет права подтверждать скидку сверх лимита.', {
        reason: 'override_not_allowed',
      });
    }
    if (o.reason.trim().length < MIN_OVERRIDE_REASON_LENGTH) {
      throw new SalesDomainError(
        'VALIDATION_FAILED',
        'Укажите причину скидки сверх лимита.',
        {
          errors: [
            { field: 'discountOverride.reason', rule: 'required', message: 'Укажите причину скидки сверх лимита.' },
          ],
        },
        422,
      );
    }
    const approveMax = percentToHundredths(o.approverLimit.approveMaxPercent ?? o.approverLimit.maxPercent);
    if (requested <= approveMax) {
      return { appliedPercent: hundredthsToPercent(requested), limitPercent, overrideApplied: true };
    }
    throw new SalesDomainError('DISCOUNT_LIMIT_EXCEEDED', 'Скидка превышает лимит подтверждения.', {
      limitPercent: hundredthsToPercent(approveMax),
    });
  }
  throw new SalesDomainError('DISCOUNT_LIMIT_EXCEEDED', `Скидка больше лимита роли (${limitPercent} %).`, {
    limitPercent,
  });
}
