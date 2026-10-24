import { sql } from 'drizzle-orm';
import { newId } from '../common/ids/uuid.js';
import type {
  CreditCheckInput,
  CreditCheckResult,
  CreditDecisionService,
  MoneyString,
  NotificationsPort,
  SalesTx,
} from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';

type Refused = Extract<CreditCheckResult, { allowed: false }>;

/**
 * Повторная проверка продажи в долг **в транзакции создания заказа** (08 API-071 «повторяет все проверки §API-070
 * внутри транзакции создания»; 07 §5.31 `open_orders_amount` — в транзакции `POST /orders`; 10 PAY-031 шаг 2,
 * DEBT-011; ревью G-credit-3). Заказы в долг одного клиента сериализуются транзакционной advisory-блокировкой
 * `credit:<customerId>`: второй параллельный заказ видит первый в `openOrdersAmount` после его COMMIT. 1С здесь не
 * вызывается (`allowRefresh=false`): внешних вызовов в транзакции нет (ядро §22.3), снимок обновлён проверкой корзины.
 */
export async function recheckCreditInTx(
  tx: SalesTx,
  credit: CreditDecisionService,
  input: Omit<CreditCheckInput, 'allowRefresh'> & { readonly customerId: string },
): Promise<CreditCheckResult> {
  await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${`credit:${input.customerId}`}))`);
  return credit.check(tx, { ...input, allowRefresh: false });
}

/** Отказ повторной проверки → поля аудита `credit.sale_blocked` и ответ 422/403 (как у отказа до транзакции). */
export function creditRecheckRefusal(
  d: Refused,
  customerId: string,
  total: MoneyString,
): {
  readonly audit: {
    readonly customerId: string;
    readonly total: MoneyString;
    readonly code: string;
    readonly creditReason: string | null;
    readonly limitRemaining: string | null;
    readonly receivablesAsOf: string | null;
  };
  readonly problem: ProblemException;
} {
  return {
    audit: {
      customerId,
      total,
      code: d.code,
      creditReason: d.creditReason,
      limitRemaining: d.limitRemaining ?? null,
      receivablesAsOf: d.receivablesAsOf ? d.receivablesAsOf.toISOString() : null,
    },
    problem: new ProblemException(d.code, {
      detail: d.detail,
      ...(d.creditReason ? { creditReason: d.creditReason } : {}),
    }),
  };
}

/** Причина блокировки для уведомления — без сумм (10 DEBT-013: «с причиной, без сумм для продавца»). */
const CREDIT_BLOCKED_TEXT: Readonly<Record<string, string>> = {
  overdue: 'У клиента есть просроченная задолженность.',
  limit_exceeded: 'Превышен лимит задолженности клиента.',
  credit_not_allowed: 'Соглашение клиента не допускает отсрочку.',
  stale_snapshot: 'Данные о долге устарели, 1С недоступна.',
};

/**
 * In-app уведомление `credit_blocked` инициатору заказа при блокировке продажи в долг (10 DEBT-013, AC-DEBT-013;
 * 12 T-DEBT-011; ревью G-credit-7, G-trace-13): причина без сумм; сбой или непривязанный порт уведомлений ответ
 * 422 не подменяет (уведомление — should, как аудит отказа).
 */
export async function notifyCreditBlocked(
  notifications: NotificationsPort | undefined,
  log: { warn(o: object, m?: string): void },
  d: {
    readonly userId: string | null | undefined;
    readonly customerId: string | null;
    readonly code: string;
    readonly creditReason?: string | null;
    readonly requestId?: string | null;
  },
): Promise<void> {
  if (!notifications || !d.userId) return;
  const reason = d.creditReason ?? '';
  try {
    await notifications.notify(null, {
      userId: d.userId,
      kind: 'credit_blocked',
      severity: 'warning',
      title: 'Продажа в долг заблокирована',
      body: CREDIT_BLOCKED_TEXT[reason] ?? 'Продажа в долг недоступна для этого клиента.',
      payload: { customerId: d.customerId, creditReason: d.creditReason ?? null, code: d.code },
      dedupeKey: `credit_blocked:${d.requestId ?? newId()}`,
    });
  } catch (err) {
    log.warn({ err, customerId: d.customerId }, 'orders.credit_blocked.notify_failed');
  }
}
