import { Controller, Get, HttpCode, Inject, Logger, Post } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';

/**
 * Оплата долга без заказа — **условный** элемент R1 (13 RM-G-013; Q-152 по умолчанию «нет»; ядро §20.2 п. 5; 08 §4.9.1,
 * §4.9.6, API-087): в R1 есть только место в контракте (`x-feature-flag: DEBT_PAYMENTS_FROM_POS`) и guard.
 * - `POST /payments` — после RBAC (`payment.debt.receive`: cashier, senior_seller; иным — 403 по праву) →
 *   `403 FORBIDDEN` (`reason: debt_payments_disabled`) при `DEBT_PAYMENTS_FROM_POS=false` (по умолчанию). При `true`
 *   функция в R1 не реализована (решение по Q-152 не принято) — тот же отказ с `reason: debt_payments_not_implemented`
 *   (GQ-TXR-10); `Idempotency-Key` не захватывается (guard-отказ до интерсептора не нужен — тело не читается).
 * - `GET /payments/{id}/documents/receipt.pdf` — квитанция об оплате долга не выдаётся: `404 NOT_FOUND`
 *   (13 RM-G-011 п. 3) — после RBAC (`payment.read.all`: cashier, senior_seller, owner; seller/admin/customer — 403).
 * `features.debtPaymentsFromPos` (`GET /settings/public`) отражает env — клиент режим «по долгу» не показывает.
 */
@Controller('payments')
export class DebtPaymentsController {
  private readonly logger = new Logger('payments.debt');

  constructor(@Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'DEBT_PAYMENTS_FROM_POS'>) {}

  @Post()
  @HttpCode(201)
  @RequirePermission('payment.debt.receive')
  create(): never {
    if (!this.config.DEBT_PAYMENTS_FROM_POS) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Приём оплаты долга без заказа в приложении отключён: платёж принимается по заказу.',
        reason: 'debt_payments_disabled',
      });
    }
    this.logger.warn(
      { event: 'payments.debt.not_implemented' },
      'DEBT_PAYMENTS_FROM_POS=true, но RM-G-013 не выполнена',
    );
    throw new ProblemException('FORBIDDEN', {
      detail: 'Приём оплаты долга без заказа не реализован в этой версии (решение Q-152 не принято).',
      reason: 'debt_payments_not_implemented',
    });
  }

  @Get(':id/documents/receipt.pdf')
  @RequirePermission('payment.read.all')
  receipt(): never {
    throw new ProblemException('NOT_FOUND', { detail: 'Квитанция об оплате долга недоступна.' });
  }
}
