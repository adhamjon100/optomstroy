import type { AuditContext } from '../audit/audit-context.js';
// Путь через `../../common/` — правило no-restricted-imports (eslint.config.mjs) по шаблону `../auth/*`.
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { KioskCustomerMatch } from '../enums.js';
import type { SalesTx } from './sales-context.js';

/**
 * `KioskOrderPort` — заявка с планшета магазина (08 §4.25.2, §4.25.3; 10 KIOSK-013…KIOSK-017; P-002 §8.5; ADR-115;
 * 06 MOD-030 «заявку создаёт модуль `orders` через порт `common/ports`, второй реализации создания заказа нет»).
 * Реализация — `OrderCreateService` модуля `orders` (`bindSalesPort`); потребитель — `kiosk/orders`
 * (`KioskOrderService`): шаги (1)–(5) и поиск карточки делает он, а проверки корзины, синхронный `/check` 1С и
 * короткая транзакция создания — `createForKiosk` поверх того же `createUnsafe`, что и `POST /orders`.
 */
export const KIOSK_ORDER_PORT = 'sales.KioskOrderPort' as const;

/** Итог поиска карточки по номеру кода (WP-S4A, `KioskCustomerMatcher`): клиент заявки и значение для заказа. */
export interface KioskOrderCustomer {
  /** Карточка при `match = single`; иначе `null` — «Розничный покупатель» (10 KIOSK-014, ORD-004). */
  readonly customerId: string | null;
  /** `orders.kiosk_customer_match` (07 §6.1.1) и `after.customerMatch` аудита `order.created`. */
  readonly match: KioskCustomerMatch;
}

export interface KioskOrderCommand {
  /** Субъект запроса — технический пользователь планшета (`kind=kiosk`); иной вид — ошибка вызывающего кода. */
  readonly principal: AuthenticatedPrincipal;
  readonly requestId: string | null;
  readonly audit: AuditContext;
  /**
   * Запрос `POST /kiosk/orders` (состояние `Idempotency-Key`): итог `{publicNumber}` пишется в транзакции создания
   * (`IdempotencyService.recordInTransaction`) и после COMMIT не перезаписывается (08 §2.7 «`POST /kiosk/orders`»).
   */
  readonly req: object;
  readonly idempotencyKey: string;
  readonly cartId: string;
  readonly cartRowVersion: number;
  /** Имя планшета (`user_profiles.full_name`) — комментарий 1С «Заявка с планшета «{имя}»» (05 ONEC-109, Q-344). */
  readonly tabletName: string;
  /** Номер кода `kiosk_order` (E.164) — получатель заявки (`receiver_phone_e164`, 1С `delivery.receiverPhone`). */
  readonly receiverPhoneE164: string;
  readonly customer: KioskOrderCustomer;
  /** Версия текста информирования кода (`otp_challenges.notice_version`) и SHA-256 её текста (11 PRIV-032). */
  readonly notice: { readonly version: string; readonly sha256: string };
  /**
   * Погашение кода в транзакции создания — первым действием после `applyAuditGucs` (P-002 §8.5 п. 3.3, п. 9):
   * повторная проверка с `allowReplay` под `FOR UPDATE` строки кода и `replayed_at`. Код уже погашен или окно
   * повтора прошло → исключение (`422 OTP_EXPIRED`), транзакция откатывается: один верный код — ровно одна заявка.
   */
  readonly consumeCode: (tx: SalesTx) => Promise<void>;
}

export interface KioskOrderResult {
  /** `201` — синхронная проверка 1С выполнена; `202` — нет (заявка `submitting`, outbox повторяет). */
  readonly httpStatus: 201 | 202;
  readonly orderId: string;
  readonly publicNumber: string;
}

export interface KioskOrderPort {
  /**
   * Заявка из корзины планшета (08 §4.25.2, шаги после проверки кода): `validateForCheckout` с `channel: 'kiosk'` и
   * `customerOverride` найденной карточки (Р-05 (а)) вне транзакции; затем короткая транзакция — погашение кода,
   * `created_via='kiosk'`, наличные, самовывоз со склада планшета, получатель — номер кода без имени,
   * `kiosk_customer_match`, `pd_notice_*`, outbox `order/create`, уведомление `kiosk_order` ролям `cashier` и
   * `senior_seller`, итог `Idempotency-Key` — только `{publicNumber}`. ORD-022 не выполняется. Ошибки — Problem
   * `POST /orders`; очищает их для планшета вызывающий (`kiosk/common/kiosk-problem.sanitizer.ts`).
   */
  createForKiosk(cmd: KioskOrderCommand): Promise<KioskOrderResult>;
  /**
   * `GET /kiosk/orders?idempotencyKey=` (08 §4.25.3): заявка этого технического пользователя (`created_by_user_id`),
   * `created_via='kiosk'`, с этим ключом, созданная не раньше чем 15 мин назад; иначе `null` (`404`).
   */
  findByIdempotencyKey(input: {
    readonly ownerUserId: string;
    readonly idempotencyKey: string;
  }): Promise<{ readonly publicNumber: string } | null>;
}
