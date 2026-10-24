import type { CreditCheckInput, CreditCheckResult, CreditDecisionService } from '../../common/ports/index.js';

/**
 * Реализация `CreditDecisionService` по умолчанию до этапа G (13 RM-F-003 п. 3: «`credit` до этапа G →
 * `CREDIT_BLOCKED`, тест фиксирует fail-closed по умолчанию»). Шаг 1 PAY-031 (право роли) соблюдается: без права —
 * `FORBIDDEN`/`forbidden_role`; иначе — всегда `422 CREDIT_BLOCKED`. Реализация со снимком долга (`decideCredit`) —
 * RM-G-002.
 */
export class FailClosedCreditDecisionService implements CreditDecisionService {
  check(_tx: unknown, input: CreditCheckInput): Promise<CreditCheckResult> {
    if (input.actor.isCustomer) {
      return Promise.resolve({
        allowed: false,
        code: 'FORBIDDEN',
        creditReason: 'forbidden_role',
        detail: 'Продажа в долг недоступна для вашей роли.',
      });
    }
    return Promise.resolve({
      allowed: false,
      code: 'CREDIT_BLOCKED',
      creditReason: null,
      detail: 'Продажа в долг временно недоступна (решение о долге — этап G).',
    });
  }
}
