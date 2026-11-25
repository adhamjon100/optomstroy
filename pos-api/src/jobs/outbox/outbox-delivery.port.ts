import type { OutboxAggregate } from '../../common/enums.js';

/** Строка `onec_outbox`, захваченная воркером (07 §5.55, §8.2). */
export interface OutboxRow {
  readonly id: string;
  readonly aggregateType: OutboxAggregate;
  readonly aggregateId: string;
  readonly externalId: string;
  readonly operation: 'create' | 'cancel';
  readonly payload: unknown;
  readonly attempts: number;
  readonly createdAt: Date;
  /**
   * Ссылки 1С клиента-зависимости (`depends_on_outbox_id` → строка `customer/create`, `sent|confirmed`): заказ нового
   * POS-клиента ставится в очередь до его подтверждения 1С с `customer.ref = null` и уходит в 1С только после
   * карточки клиента (05 SYNC-042, SYNC-049; ревью G-customers-1c-1). Ссылка — `customers.onec_ref` (после
   * `customers.onec-confirmed`) или Ref из ответа 1С строки клиента (`onec_outbox.onec_ref`); `undefined` — нет.
   */
  readonly dependencyCustomer?: {
    readonly ref: string | null;
    readonly contractorRef: string | null;
    readonly agreementRef: string | null;
  } | null;
  /**
   * Ссылки 1С заказа-основания (`depends_on_outbox_id` → строка `order/create`, `sent|confirmed`): документ оплаты QR
   * банка ставится в очередь в момент оплаты, когда заказа в 1С может ещё не быть (ADR-123) — пустые `orderRef` и
   * `customerRef` тела `POST /pos/v1/payments` дополняются при доставке. Ссылка заказа — `orders.onec_ref` или Ref
   * ответа 1С строки заказа; `undefined` — зависимости нет.
   */
  readonly dependencyOrder?: {
    readonly ref: string | null;
    readonly customerRef: string | null;
  } | null;
  /**
   * Телефон клиента заказа (основной контакт `customer_contacts`) — только строкам `order/*` и только каналу с
   * `needsOrderCustomerPhone` (ОС_API: поиск покупателя 1С `GET /customers?phone=`); иначе не читается.
   */
  readonly customerPhone?: string | null;
  /**
   * Дата доставки заказа (`orders.delivery_date`, `YYYY-MM-DD`) — тому же каналу, что и `customerPhone` (ОС_API:
   * `shipmentDate` черновика, если интервал доставки не задан; в теле `/pos/v1` её без времени нет).
   */
  readonly deliveryDate?: string | null;
  /**
   * Код последней ошибки строки до захвата (`last_error_code`): `NO_WRITE_CHANNEL` — строка была запаркована;
   * `null` — ошибок не было. Читает канал ОС_API (хвост заказов, накопленный до включения записи).
   */
  readonly lastErrorCode?: string | null;
  /**
   * Возраст строки, мс: от создания, после ручного повтора — от момента повтора (тот же отсчёт, что у
   * `OUTBOX_MAX_AGE_HOURS` в диспетчере).
   */
  readonly ageMs?: number;
}

/** Маршрут outbox `aggregate_type/operation` (`order/create`, `payment/create`…). */
export type OutboxRoute = `${OutboxAggregate}/${'create' | 'cancel'}`;

/**
 * Исход отправки в 1С (ядро §22.1; 07 §6.5, §8.2):
 * - `sent` — 1С вернула Ref_Key (200/201 или `POS_E_DUPLICATE`);
 * - `transient` — таймаут, сеть, 5xx, результат неизвестен → `pending` с backoff (никогда не `sent`);
 * - `rejected` — ошибка данных / бизнес-отказ 1С (`POS_E_VALIDATION|STOCK|PRICE|CREDIT|STATE`) → `failed`;
 * - `fatal` — 401/403 или ошибка конфигурации → `dead` сразу;
 * - `parked` — в 1С не отправлено и без изменения данных/настроек отправлено не будет (ОС_API: нечем заполнить
 *   обязательное поле заказа, маршрут не пишется в 1С, заказ из хвоста до включения записи) → `pending`,
 *   `NO_WRITE_CHANNEL` («ждёт оформления в 1С», 05 SYNC-066), попытка не засчитывается. `recheckAfterMs` задан —
 *   `next_attempt_at = now() + recheckAfterMs` (причина могла быть устранена: задан `ONEC_OSAPI_DEFAULT_CUSTOMER`,
 *   склад привязан, товар появился в выгрузке 1С — строка уйдёт сама; при неизменной причине снова паркуется без
 *   новой записи `sync_errors`); не задан — `next_attempt_at = NULL`. Выход в любой момент — ручной повтор
 *   `POST /sync/outbox/{id}/retry` (допускается для `pending` с `NO_WRITE_CHANNEL`) или привязка документа 1С.
 */
export type OutboxDeliveryResult =
  | {
      readonly kind: 'sent';
      readonly onecRef: string;
      readonly onecNumber?: string | null;
      readonly onecStatus?: string | null;
      readonly response?: unknown;
    }
  | { readonly kind: 'transient'; readonly message: string }
  | { readonly kind: 'rejected'; readonly message: string; readonly response?: unknown }
  | { readonly kind: 'fatal'; readonly message: string }
  | { readonly kind: 'parked'; readonly message: string; readonly recheckAfterMs?: number };

/**
 * Порт доставки элемента outbox в 1С. Реализация — `OnecGateway` (RM-E-001/RM-F-*, 05 §6, §8);
 * исключение из `deliver` трактуется как временная ошибка.
 */
export interface OutboxDeliveryPort {
  /** `false` — канал записи не подключён: диспетчер не захватывает строки (попытки не тратятся). */
  readonly configured: boolean;
  /**
   * Маршруты, которые канал доставляет; `undefined` — все. Строки других маршрутов диспетчер не захватывает (остаются
   * `pending`, попытки не тратятся), и зависимость от такой строки отправку не держит — канал её не доставит никогда
   * (ОС_API: `customer/create` не пишется, заказ нового клиента уходит с покупателем по телефону/по умолчанию).
   */
  readonly routes?: readonly OutboxRoute[];
  /** Канал читает телефон клиента заказа (`OutboxRow.customerPhone`). */
  readonly needsOrderCustomerPhone?: boolean;
  deliver(row: OutboxRow): Promise<OutboxDeliveryResult>;
}

/** Заглушка этапа C: канала записи в 1С ещё нет (OnecGateway — этап E/F). */
export class NotConfiguredOutboxDelivery implements OutboxDeliveryPort {
  readonly configured = false;

  deliver(): Promise<OutboxDeliveryResult> {
    return Promise.resolve({ kind: 'transient', message: 'канал записи в 1С не подключён (этап E/F)' });
  }
}
