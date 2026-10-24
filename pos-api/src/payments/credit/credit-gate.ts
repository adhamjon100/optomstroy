import { Inject, Injectable, Logger } from '@nestjs/common';
import { Money } from '../../common/money/money.js';
import {
  CREDIT_DECISION_SERVICE,
  type CreditCheckInput,
  type CreditCheckResult,
  type CreditDecisionService,
  type SalesTx,
} from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

export interface CreditApproval {
  readonly overrideUsed: boolean;
  readonly limitRemaining: string | null;
  readonly receivablesAsOf: Date;
}

/**
 * Решение о продаже в долг для модулей F (RM-F-003; 10 PAY-031; ядро §22.4 в редакции §23 п. 5) поверх порта
 * `CreditDecisionService` (до этапа G — fail-closed `CREDIT_BLOCKED`, RM-G-002 привязывает реализацию по снимку):
 * - отказ → Problem с кодом и `creditReason` 08 §2.4: `FORBIDDEN`/`forbidden_role` (403), `CUSTOMER_NOT_IDENTIFIED`
 *   (без `creditReason`), `CREDIT_BLOCKED` (`credit_not_allowed`, `overdue`), `CREDIT_LIMIT_EXCEEDED`
 *   (`limit_exceeded`, `limitRemaining`), `RECEIVABLES_STALE` (`stale_snapshot`, `receivablesAsOf`);
 * - **503 для долга не возвращается** (ядро §22.4): исключение/таймаут реализации порта (1С недоступна при
 *   обновлении снимка) — `422 RECEIVABLES_STALE` (`stale_snapshot`).
 */
@Injectable()
export class CreditGate {
  private readonly logger = new Logger('payments.credit');

  constructor(@Inject(CREDIT_DECISION_SERVICE) private readonly service: CreditDecisionService) {}

  async require(tx: SalesTx | null, input: CreditCheckInput): Promise<CreditApproval> {
    let r: CreditCheckResult;
    try {
      r = await this.service.check(tx, input);
    } catch (err) {
      if (err instanceof ProblemException && err.code !== 'ONEC_UNAVAILABLE') throw err;
      this.logger.warn({ err }, 'credit.decision_failed: RECEIVABLES_STALE (fail-closed, без 503)');
      throw new ProblemException('RECEIVABLES_STALE', {
        detail: 'Данные о долге устарели, 1С недоступна: продажа в долг невозможна, выберите наличные или QR.',
        creditReason: 'stale_snapshot',
      });
    }
    if (r.allowed) {
      return { overrideUsed: r.overrideUsed, limitRemaining: r.limitRemaining, receivablesAsOf: r.receivablesAsOf };
    }
    throw creditProblem(r);
  }
}

export function creditProblem(r: Extract<CreditCheckResult, { allowed: false }>): ProblemException {
  return new ProblemException(r.code, {
    detail: r.detail,
    ...(r.creditReason ? { creditReason: r.creditReason } : {}),
    ...(r.limitRemaining !== undefined && r.limitRemaining !== null
      ? { limitRemaining: { amount: Money.of(r.limitRemaining).toString(), currency: 'KGS' } }
      : {}),
    ...(r.receivablesAsOf ? { receivablesAsOf: r.receivablesAsOf.toISOString() } : {}),
  });
}
