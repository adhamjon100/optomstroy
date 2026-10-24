import type { SalesActor } from '../../common/ports/index.js';

/** Значение финансового поля, скрытое от зрителя без права полного просмотра (08 `AuditRow`, 02 UI-47-013). */
export const AUDIT_MASK = '***';

/**
 * Финансовые события (11 SEC-083: «`admin` — без финансовых `before/after` для событий `payment.*`, `credit.*`,
 * `customer.debt_viewed`, `customer.finance.view` — только факт и сущность»; D-36 «работа с финансовыми данными»):
 * все значения `before/after` маскируются. `receivables.overdue_viewed` (11 §7.2.1: «финансовое, D-36») — по тому
 * же правилу (GQ-ADM-02).
 */
const FINANCIAL_ACTION_PREFIXES: readonly string[] = ['payment.', 'credit.'];
const FINANCIAL_ACTIONS: ReadonlySet<string> = new Set([
  'customer.debt_viewed',
  'customer.finance.view',
  'receivables.overdue_viewed',
]);

/**
 * Денежные ключи в событиях вне перечня (например, `order.created` с итогом, `order.cancelled` с `paidAmount`):
 * у `admin` значение маскируется, ключ остаётся (08 §4.18.7: «без финансовых before/after значений»).
 */
const MONEY_KEY = /(amount|total|balance|overdue|credit_?limit|paid|price|debt|sum|cost)/i;

export function isFinancialAuditAction(action: string): boolean {
  return FINANCIAL_ACTIONS.has(action) || FINANCIAL_ACTION_PREFIXES.some((p) => action.startsWith(p));
}

/**
 * Полный просмотр `before/after` — только `owner` (08 §4.18.7, 11 SEC-083, матрица 11 §4.4). Прочим держателям
 * `audit.read` (`admin`) и любым другим зрителям порта (`GET /transactions/{id}`) — маска (безопасное значение по
 * умолчанию).
 */
export function seesFullAudit(viewer: Pick<SalesActor, 'roles' | 'isCustomer'>): boolean {
  return !viewer.isCustomer && viewer.roles.includes('owner');
}

function maskAll(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(() => AUDIT_MASK);
  if (v !== null && typeof v === 'object') {
    return Object.fromEntries(Object.keys(v as Record<string, unknown>).map((k) => [k, AUDIT_MASK]));
  }
  return AUDIT_MASK;
}

function maskMoneyKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(maskMoneyKeys);
  if (v !== null && typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = MONEY_KEY.test(k) ? maskAll(val) : maskMoneyKeys(val);
    }
    return out;
  }
  return v;
}

/**
 * Маскирование `before/after` строки аудита для зрителя: `owner` — без изменений; иначе у финансовых событий все
 * значения → `"***"` (ключи сохраняются — видно, что изменилось), у прочих — значения денежных ключей.
 */
export function maskAuditPayload(
  viewer: Pick<SalesActor, 'roles' | 'isCustomer'>,
  action: string,
  payload: Readonly<Record<string, unknown>> | null,
): Readonly<Record<string, unknown>> | null {
  if (payload === null || seesFullAudit(viewer)) return payload;
  if (isFinancialAuditAction(action)) return maskAll(payload) as Record<string, unknown>;
  return maskMoneyKeys(payload) as Record<string, unknown>;
}
