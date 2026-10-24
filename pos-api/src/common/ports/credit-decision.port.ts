import type { CreditReason } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `CreditDecisionService` [НОВОЕ ИМЯ, 13 §13 п. 14; RM-F-003] — решение о продаже в долг. Порядок проверок — 10 PAY-031
 * (чистая функция `decideCredit`, sales-domain/credit). Реализация со снимком долга и синхронным обновлением из 1С —
 * этап G (RM-G-002); до неё по умолчанию привязана fail-closed реализация (`FailClosedCreditDecisionService`):
 * всегда `422 CREDIT_BLOCKED` (RM-F-003 критерий 3).
 */
export const CREDIT_DECISION_SERVICE = 'sales.CreditDecisionService' as const;

export interface CreditCheckInput {
  readonly actor: SalesActor;
  readonly customerId: string | null;
  readonly total: MoneyString;
  /** `creditOverride{reason}` с проверенным step-up (PAY-032). */
  readonly override: { readonly reason: string } | null;
  /**
   * `false` — без синхронного обновления снимка из 1С (шаг 3 PAY-031 → `RECEIVABLES_STALE`): повторная проверка
   * лимита в транзакции создания заказа под блокировкой клиента (08 API-071). По умолчанию — обновление разрешено.
   */
  readonly allowRefresh?: boolean;
}

export type CreditCheckResult =
  | {
      readonly allowed: true;
      readonly overrideUsed: boolean;
      readonly limitRemaining: MoneyString | null;
      readonly receivablesAsOf: Date;
    }
  | {
      readonly allowed: false;
      readonly code:
        'FORBIDDEN' | 'CUSTOMER_NOT_IDENTIFIED' | 'CREDIT_BLOCKED' | 'CREDIT_LIMIT_EXCEEDED' | 'RECEIVABLES_STALE';
      readonly creditReason: CreditReason | null;
      readonly detail: string;
      readonly limitRemaining?: MoneyString | null;
      readonly receivablesAsOf?: Date | null;
    };

export interface CreditDecisionService {
  check(tx: SalesTx | null, input: CreditCheckInput): Promise<CreditCheckResult>;
}
