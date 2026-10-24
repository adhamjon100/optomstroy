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
}

/**
 * Исход отправки в 1С (ядро §22.1; 07 §6.5, §8.2):
 * - `sent` — 1С вернула Ref_Key (200/201 или `POS_E_DUPLICATE`);
 * - `transient` — таймаут, сеть, 5xx, результат неизвестен → `pending` с backoff (никогда не `sent`);
 * - `rejected` — ошибка данных / бизнес-отказ 1С (`POS_E_VALIDATION|STOCK|PRICE|CREDIT|STATE`) → `failed`;
 * - `fatal` — 401/403 или ошибка конфигурации → `dead` сразу.
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
  | { readonly kind: 'fatal'; readonly message: string };

/**
 * Порт доставки элемента outbox в 1С. Реализация — `OnecGateway` (RM-E-001/RM-F-*, 05 §6, §8);
 * исключение из `deliver` трактуется как временная ошибка.
 */
export interface OutboxDeliveryPort {
  /** `false` — канал записи не подключён: диспетчер не захватывает строки (попытки не тратятся). */
  readonly configured: boolean;
  deliver(row: OutboxRow): Promise<OutboxDeliveryResult>;
}

/** Заглушка этапа C: канала записи в 1С ещё нет (OnecGateway — этап E/F). */
export class NotConfiguredOutboxDelivery implements OutboxDeliveryPort {
  readonly configured = false;

  deliver(): Promise<OutboxDeliveryResult> {
    return Promise.resolve({ kind: 'transient', message: 'канал записи в 1С не подключён (этап E/F)' });
  }
}
