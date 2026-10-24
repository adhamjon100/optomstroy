import type { PaymentMethod } from '../../common/enums.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Допустимые способы оплаты при оформлении (`CheckoutPreview.permissions.allowedPaymentMethods`; 08 API-179,
 * 10 CUST-024, PAY-030/PAY-031 шаг 1(а); ядро §24.2, §24.4).
 * - `customer`: `cash` («оплата при получении») и `qr_bakai` только при `QR_PROVIDER≠none`; `credit` — никогда;
 * - `staff`: `cash`, `qr_bakai` (при `none` — статический QR и ручное подтверждение), `credit` — при
 *   `credit.sale.create` (итоговое решение — порядок PAY-031, `decideCredit`).
 */
export interface PaymentMethodsContext {
  readonly isCustomerMode: boolean;
  readonly qrProvider: 'onec' | 'none' | 'bakai';
  /** Право `credit.sale.create`. */
  readonly canSellOnCredit: boolean;
}

export function allowedPaymentMethods(ctx: PaymentMethodsContext): PaymentMethod[] {
  if (ctx.isCustomerMode) return ctx.qrProvider === 'none' ? ['cash'] : ['cash', 'qr_bakai'];
  return ctx.canSellOnCredit ? ['cash', 'qr_bakai', 'credit'] : ['cash', 'qr_bakai'];
}

/**
 * Проверка выбранного способа: `customer` + `credit` → `403 FORBIDDEN` (`creditReason: forbidden_role`);
 * `customer` + QR при `QR_PROVIDER=none` → `422 VALIDATION_FAILED` (`rule: payment_method_unavailable`).
 * `staff` без `credit.sale.create` + `credit` → `403 FORBIDDEN` (`forbidden_role`) — шаг 1(а) PAY-031.
 */
export function assertPaymentMethodAllowed(method: PaymentMethod, ctx: PaymentMethodsContext): void {
  if (method === 'credit' && (ctx.isCustomerMode || !ctx.canSellOnCredit)) {
    throw new SalesDomainError('FORBIDDEN', 'Продажа в долг недоступна для вашей роли.', {
      creditReason: 'forbidden_role',
    });
  }
  if (method === 'qr_bakai' && ctx.isCustomerMode && ctx.qrProvider === 'none') {
    throw new SalesDomainError(
      'VALIDATION_FAILED',
      'Оплата QR сейчас недоступна.',
      {
        errors: [
          { field: 'paymentMethod', rule: 'payment_method_unavailable', message: 'Оплата QR сейчас недоступна.' },
        ],
      },
      422,
    );
  }
}
