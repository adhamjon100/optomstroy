import type { DbExecutor } from '../audit/db-executor.js';

/**
 * Общие типы портов межмодульных вызовов этапа F (06 §7.4: `common/ports` — интерфейсы без реализаций; модули
 * `cart`, `orders`, `payments`, `notifications` и документы не импортируют друг друга, а получают реализацию по
 * DI-токену из `SalesPortRegistry`). Здесь нет импортов модулей D-06 (правило lint `common/**`).
 */

/** Транзакция бизнес-операции (Drizzle: `db.transaction(async (tx) => …)`) или клиент вне транзакции. */
export type SalesTx = DbExecutor;

/** Кто выполняет операцию (для прав, аудита, `*_by_user_id`). `userId = null` — система (job, автовоид). */
export interface SalesActor {
  readonly userId: string | null;
  readonly roles: readonly string[];
  /** Режим клиента-покупателя (`kind=customer`). */
  readonly isCustomer: boolean;
  /**
   * Вид субъекта `SubjectKind` (common/auth/subject-kind.ts; 06 ARCH-065, ADR-115) рядом с `isCustomer`: без него
   * адаптеры теряют третий вид (`isCustomer` не отличает планшет от покупателя режима клиента). `kiosk` — планшет
   * магазина: покупатель без привязки (`isCustomer = true`), но флаг `CUSTOMER_SELF_SERVICE` к нему не относится
   * (06 ARCH-067). Актор планшета задаёт `'kiosk'` всегда; не задан — актор сотрудника или покупателя из построителей
   * до ADR-115 либо системный. Литерал, а не импорт: правило lint `common/**` запрещает путь `../auth/*`; совпадение
   * с `SubjectKind` сверяет subject-kind.spec.ts.
   */
  readonly subjectKind?: 'staff' | 'customer' | 'kiosk';
  readonly sessionId?: string | null;
  readonly deviceId?: string | null;
  readonly requestId?: string | null;
}

export const SYSTEM_ACTOR: SalesActor = Object.freeze({ userId: null, roles: [], isCustomer: false });

/** Деньги на границе портов — строка `NUMERIC(14,2)` (`"16007.50"`, D-19); количества — строка до 3 знаков. */
export type MoneyString = string;
export type QuantityString = string;
