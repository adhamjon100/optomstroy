import { Inject, Injectable, Logger } from '@nestjs/common';
import { type OtpChallengeRow, OtpChallengesRepository } from '../../auth/otp/otp-challenges.repository.js';
import { type OtpCheck, OtpService } from '../../auth/otp/otp.service.js';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { isUuid } from '../../common/ids/uuid.js';
import {
  CART_READER,
  type CartReader,
  KIOSK_ORDER_PORT,
  type KioskOrderPort,
  type SalesTx,
} from '../../common/ports/index.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { KioskCustomerMatcher } from '../../customers/matching/kiosk-customer-match.js';
import { CLIENT_FORBIDDEN_MONEY_FIELDS } from '../../sales-domain/pricing/client-money-fields.js';
import type { KioskTabletContext } from '../common/kiosk-tablet.reader.js';
import { kioskNoticeSha256 } from '../otp/notice-catalog.js';
import { sanitizeKioskProblem } from '../common/kiosk-problem.sanitizer.js';

/** Тело `POST /kiosk/orders` после проверки (OpenAPI `KioskOrdersCreateRequest`; 08 §4.25.2). */
export interface KioskOrdersBody {
  readonly challengeId: string;
  readonly code: string;
  readonly cartId: string;
  readonly cartRowVersion: number;
  readonly previewToken: string;
}

/** Ответ планшету (`KioskOrderAccepted`, 08 §3.17): только номер — без статуса, сумм, клиента и ПДн. */
export interface KioskOrderAccepted {
  readonly publicNumber: string;
}

const BODY_FIELDS: readonly string[] = ['challengeId', 'code', 'cartId', 'cartRowVersion', 'previewToken'];
const PREVIEW_TOKEN_MAX = 512;
/** Один нейтральный текст для шагов (2)–(4): планшету не сообщается, какая из проверок не прошла. */
const NOT_FOUND_DETAIL = 'Код не найден. Запросите новый.';

function invalid(errors: readonly ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status: 400, detail: 'Запрос не прошёл проверку.', errors });
}

/** Денежные поля тела (D-23; 08 §4.25.2 «цены — и аудит `price.override_attempt`»). */
export function kioskForbiddenMoneyFields(raw: unknown): string[] {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return [];
  const b = raw as Record<string, unknown>;
  return CLIENT_FORBIDDEN_MONEY_FIELDS.filter((f) => f in b);
}

/**
 * Разбор тела `POST /kiosk/orders` (08 §4.25.2; `additionalProperties: false`): только идентификаторы и код. Иные
 * поля — клиент, получатель, оплата, доставка, скидка, цены, итоги, `noticeVersion` → `400 VALIDATION_FAILED` rule
 * `forbidden_field` (как `POST /kiosk/order-otp`); `challengeId`, `cartId` — UUID (rule `uuid`); `code` — ровно
 * 6 цифр (rule `otp_format`); `cartRowVersion` — целое ≥ 0 (rule `type`); `previewToken` — строка 1…512.
 */
export function parseKioskOrdersBody(raw: unknown): KioskOrdersBody {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw invalid([{ field: 'body', rule: 'type', message: 'Ожидается объект JSON' }]);
  }
  const b = raw as Record<string, unknown>;
  const errors: ProblemFieldError[] = [];
  for (const k of Object.keys(b)) {
    if (!BODY_FIELDS.includes(k)) errors.push({ field: k, rule: 'forbidden_field', message: 'Поле не принимается' });
  }
  const uuid = (field: 'challengeId' | 'cartId'): string | undefined => {
    const v = b[field];
    if (v === undefined) errors.push({ field, rule: 'required', message: 'Поле обязательно' });
    else if (!isUuid(v)) errors.push({ field, rule: 'uuid', message: 'Ожидается UUID' });
    return isUuid(v) ? v.toLowerCase() : undefined;
  };
  const challengeId = uuid('challengeId');
  const cartId = uuid('cartId');
  const code = b.code;
  if (code === undefined) errors.push({ field: 'code', rule: 'required', message: 'Поле обязательно' });
  else if (typeof code !== 'string' || !/^\d{6}$/.test(code)) {
    errors.push({ field: 'code', rule: 'otp_format', message: 'Код — ровно 6 цифр' });
  }
  const rv = b.cartRowVersion;
  if (rv === undefined) errors.push({ field: 'cartRowVersion', rule: 'required', message: 'Поле обязательно' });
  else if (typeof rv !== 'number' || !Number.isSafeInteger(rv) || rv < 0) {
    errors.push({ field: 'cartRowVersion', rule: 'type', message: 'Ожидается целое число ≥ 0' });
  }
  const token = b.previewToken;
  if (token === undefined) errors.push({ field: 'previewToken', rule: 'required', message: 'Поле обязательно' });
  else if (typeof token !== 'string' || token.length === 0 || token.length > PREVIEW_TOKEN_MAX) {
    errors.push({ field: 'previewToken', rule: 'max_length', message: `Строка 1…${PREVIEW_TOKEN_MAX} символов` });
  }
  if (errors.length > 0) throw invalid(errors);
  return {
    challengeId: challengeId as string,
    code: code as string,
    cartId: cartId as string,
    cartRowVersion: rv as number,
    previewToken: token as string,
  };
}

/** `idempotencyKey` запроса `GET /kiosk/orders` (08 §4.25.3): UUID, обязателен; иначе `400 VALIDATION_FAILED`. */
export function parseKioskOrdersQuery(q: Record<string, unknown>): string {
  const v = q.idempotencyKey;
  if (v === undefined || v === '') {
    throw invalid([{ field: 'idempotencyKey', rule: 'required', message: 'Параметр обязателен' }]);
  }
  if (!isUuid(v)) throw invalid([{ field: 'idempotencyKey', rule: 'uuid', message: 'Ожидается UUID' }]);
  return v.toLowerCase();
}

/**
 * Заявка с планшета магазина — `POST /kiosk/orders` в три шага и восстановление `GET /kiosk/orders?idempotencyKey=`
 * (08 §4.25.2, §4.25.3; 09 §5.3; 10 KIOSK-011, KIOSK-013…KIOSK-017, KIOSK-022; 11 SEC-016, SEC-141; P-002 §8.5;
 * ADR-115). Порядок проверок один (P-002 §8.5 п. 4):
 * 1. `previewToken` — подпись, срок, `cartId`, `cartRowVersion`, способ оплаты `cash`, **без итога**
 *    (`CartReader.verifyPreviewToken`) → `422 PRICE_CHANGED preview_*`;
 * 2–4. код существует и `purpose=kiosk_order`, выдан этому планшету, для этой корзины — чтение без блокировки,
 *    иначе `404 NOT_FOUND`; на шагах 1–4 код не проверяется и попытка не тратится (`OtpService.check` засчитал бы
 *    попытку при чужом устройстве);
 * 5. проверка кода — своя транзакция (`allowReplay`): неверный код фиксирует попытку всегда, ошибка — после COMMIT;
 *    повтор того же верного кода в окне 60 с — `replay` без новой попытки.
 * Затем вне транзакции — поиск карточки 1С по номеру кода (`KioskCustomerMatcher`, только после верного кода: перебор
 * номеров 1С не вызывает), и порт `KioskOrderPort.createForKiosk` модуля `orders`: проверки корзины и `/check` 1С по
 * карточке в памяти, короткая транзакция создания с погашением кода (`replayed_at`). Блокировок кода и корзины, пока
 * идёт обращение к 1С, нет. Ошибки очищаются (`kiosk/common/kiosk-problem.sanitizer.ts`) до выхода из обработчика — под ключом
 * идемпотентности хранится только `{publicNumber}` или очищенный Problem. Номер, код и ключ в журнал не пишутся.
 */
@Injectable()
export class KioskOrderService {
  private readonly logger = new Logger('kiosk');
  /**
   * Чтение кода на шагах (2)–(4) и `replayed_at` при погашении. Класс без состояния (только `DRIZZLE`); `AuthModule`
   * его не экспортирует, а второй провайдер с тем же токеном подменил бы экземпляр модуля `auth` для
   * `app.get(OtpChallengesRepository)` — поэтому экземпляр создаётся здесь (как в `kiosk/lifecycle`).
   */
  private readonly challenges: OtpChallengesRepository;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(CART_READER) private readonly cart: CartReader,
    @Inject(KIOSK_ORDER_PORT) private readonly orders: KioskOrderPort,
    private readonly otp: OtpService,
    private readonly matcher: KioskCustomerMatcher,
    private readonly audit: AuditService,
  ) {
    this.challenges = new OtpChallengesRepository(db);
  }

  async create(input: {
    readonly req: object;
    readonly principal: AuthenticatedPrincipal;
    readonly tablet: KioskTabletContext;
    readonly body: KioskOrdersBody;
    readonly idempotencyKey: string;
    readonly requestId: string | null;
    readonly audit: AuditContext;
  }): Promise<{ readonly httpStatus: 201 | 202; readonly publicNumber: string }> {
    try {
      return await this.createUnsafe(input);
    } catch (e) {
      throw sanitizeKioskProblem(e);
    }
  }

  /** `GET /kiosk/orders?idempotencyKey=` — номер заявки этого планшета по ключу последней попытки (≤ 15 мин). */
  async findByIdempotencyKey(tablet: KioskTabletContext, idempotencyKey: string): Promise<KioskOrderAccepted> {
    const found = await this.orders.findByIdempotencyKey({ ownerUserId: tablet.userId, idempotencyKey });
    if (!found) throw new ProblemException('NOT_FOUND', { detail: 'Заявка не найдена.' });
    return { publicNumber: found.publicNumber };
  }

  /** Аудит `price.override_attempt` (11 §7.2): цены и итоги в теле заявки планшет не передаёт (D-23). */
  async auditPriceOverride(audit: AuditContext, fields: readonly string[]): Promise<void> {
    await this.audit.write(audit, {
      action: 'price.override_attempt',
      entityType: 'order',
      result: 'denied',
      severity: 'warning',
      after: { fields, route: 'POST /kiosk/orders' },
    });
  }

  private async createUnsafe(input: {
    readonly req: object;
    readonly principal: AuthenticatedPrincipal;
    readonly tablet: KioskTabletContext;
    readonly body: KioskOrdersBody;
    readonly idempotencyKey: string;
    readonly requestId: string | null;
    readonly audit: AuditContext;
  }): Promise<{ readonly httpStatus: 201 | 202; readonly publicNumber: string }> {
    const { body, tablet, principal } = input;
    // (1) Токен предпросмотра без итога — до кода (итог заявки по карточке пересчитывает сервер, Р-05 (а)).
    this.cart.verifyPreviewToken(body.previewToken, {
      cartId: body.cartId,
      cartRowVersion: body.cartRowVersion,
      paymentMethod: 'cash',
    });
    // (2)–(4) Код этого назначения, этого планшета и этой корзины — без блокировки и без попытки.
    const found = await this.challenges.findById(body.challengeId);
    if (
      !found ||
      found.purpose !== 'kiosk_order' ||
      found.kioskTabletId !== tablet.tabletId ||
      found.cartId !== body.cartId
    ) {
      throw new ProblemException('NOT_FOUND', { detail: NOT_FOUND_DETAIL });
    }
    // (5) Проверка кода — своя транзакция; итог-ошибка бросается после COMMIT (попытка не откатывается).
    const check = await this.db.transaction(async (tx): Promise<OtpCheck> => {
      await applyAuditGucs(tx, input.audit);
      const r = await this.verifyCode(tx, body, principal);
      await this.auditCheck(tx, input.audit, tablet, found, r);
      return r;
    });
    if (check.kind === 'not_found' || check.kind === 'device_mismatch') {
      // После (2)–(4) не бывает; на всякий случай — без траты попыток чужого кода и без DEVICE_MISMATCH.
      throw new ProblemException('NOT_FOUND', { detail: NOT_FOUND_DETAIL });
    }
    if (check.kind !== 'ok' && check.kind !== 'replay') throw OtpService.toProblem(check);
    const challenge = check.challenge;
    const noticeVersion = challenge.noticeVersion;
    const noticeSha256 = noticeVersion ? kioskNoticeSha256(noticeVersion) : undefined;
    if (!noticeVersion || !noticeSha256) {
      // Код выдаётся только с известной версией текста (POST /kiosk/order-otp, 422 notice_version) — иначе сбой.
      throw new Error('kiosk: у кода kiosk_order нет известной версии текста информирования');
    }

    // Вне транзакции: карточка 1С по номеру кода (реплика + синхронный запрос в 1С; 1С не ответила — реплика).
    const match = await this.matcher.matchKioskCustomer(challenge.phoneE164, {
      ...(input.requestId ? { requestId: input.requestId } : {}),
    });
    try {
      const created = await this.orders.createForKiosk({
        principal,
        requestId: input.requestId,
        audit: input.audit,
        req: input.req,
        idempotencyKey: input.idempotencyKey,
        cartId: body.cartId,
        cartRowVersion: body.cartRowVersion,
        tabletName: tablet.name,
        receiverPhoneE164: challenge.phoneE164,
        customer: { customerId: match.customerId, match: match.match },
        notice: { version: noticeVersion, sha256: noticeSha256 },
        consumeCode: (tx) => this.consumeCode(tx, body, principal),
      });
      this.logger.log(
        {
          event: 'kiosk.order_created',
          requestId: input.requestId,
          tabletId: tablet.tabletId,
          orderId: created.orderId,
          httpStatus: created.httpStatus,
          customerMatch: match.match,
          matchReason: match.reason,
          onec: match.onec,
        },
        'kiosk.order_created',
      );
      return { httpStatus: created.httpStatus, publicNumber: created.publicNumber };
    } catch (e) {
      throw await this.preferConsumedCode(e, challenge.id);
    }
  }

  /** Проверка кода так, как её делают шаг (5) и транзакция создания: назначение `kiosk_order`, устройство планшета. */
  private verifyCode(tx: SalesTx, body: KioskOrdersBody, principal: AuthenticatedPrincipal): Promise<OtpCheck> {
    return this.otp.check(tx, {
      challengeId: body.challengeId,
      code: body.code,
      deviceKey: principal.deviceId,
      purpose: 'kiosk_order',
      allowReplay: true,
    });
  }

  /**
   * Погашение кода в транзакции создания (P-002 §8.5 п. 3.3, п. 9): строка кода `FOR UPDATE` (`OtpService.check`),
   * итог — только `replay` (код проверен на шаге (5) и ещё не погашен, окно 60 с не прошло) → `replayed_at`. Код
   * уже погашен другим запросом, сбросом, отключением или выходом, окно прошло → `422 OTP_EXPIRED`, заявки нет.
   */
  private async consumeCode(tx: SalesTx, body: KioskOrdersBody, principal: AuthenticatedPrincipal): Promise<void> {
    const r = await this.verifyCode(tx, body, principal);
    if (r.kind !== 'replay') {
      throw new ProblemException('OTP_EXPIRED', { detail: 'Код истёк. Запросите новый.' });
    }
    const now = this.clock.now();
    await this.challenges.update(r.challenge.id, { replayedAt: now }, now, tx);
  }

  /**
   * Корзина `cartId` перестала быть активной (`ORDER_STATE_INVALID`) или изменилась (`VERSION_CONFLICT`) потому, что
   * этот же код уже создал заявку (двойное нажатие, 12 T-KIOSK-047) или погашен сбросом, — ответ планшету `422
   * OTP_EXPIRED` (08 §4.25.2 «уже создал заявку»): код важнее состояния корзины. Иначе — исходная ошибка.
   */
  private async preferConsumedCode(e: unknown, challengeId: string): Promise<unknown> {
    if (!(e instanceof ProblemException) || (e.code !== 'ORDER_STATE_INVALID' && e.code !== 'VERSION_CONFLICT')) {
      return e;
    }
    const ch = await this.challenges.findById(challengeId).catch(() => undefined);
    if (ch && (ch.replayedAt !== null || ch.status !== 'verified')) {
      return new ProblemException('OTP_EXPIRED', { detail: 'Код истёк. Запросите новый.' });
    }
    return e;
  }

  /**
   * Аудит проверки кода (11 §7.2: `auth.otp.verified` / `auth.otp.failed` / `auth.otp.locked` с `after.kioskId`;
   * без кода и номера). Повтор верного кода (`replay`) и уже заблокированный код событий не добавляют (как вход,
   * login.service.ts). Пишется в транзакции проверки — вместе с попыткой.
   */
  private async auditCheck(
    tx: SalesTx,
    audit: AuditContext,
    tablet: KioskTabletContext,
    ch: OtpChallengeRow,
    r: OtpCheck,
  ): Promise<void> {
    if (r.kind === 'replay' || r.kind === 'not_found' || r.kind === 'locked') return;
    if (r.kind === 'ok') {
      await this.audit.write(
        audit,
        {
          action: 'auth.otp.verified',
          entityType: 'otp_challenge',
          entityId: ch.id,
          after: { purpose: 'kiosk_order', kioskId: tablet.tabletId, attempts: r.challenge.attempts },
        },
        tx,
      );
      return;
    }
    const locked = r.kind === 'invalid' && r.lockedNow;
    this.logger.warn(
      { event: locked ? 'otp.locked' : `otp.${r.kind}`, challengeId: ch.id, tabletId: tablet.tabletId },
      'kiosk.otp_verify_failed',
    );
    await this.audit.write(
      audit,
      {
        action: locked ? 'auth.otp.locked' : 'auth.otp.failed',
        entityType: 'otp_challenge',
        entityId: ch.id,
        result: 'denied',
        severity: locked ? 'warning' : 'info',
        after: {
          purpose: 'kiosk_order',
          kioskId: tablet.tabletId,
          reason: r.kind,
          ...(r.kind === 'invalid' ? { attemptsLeft: r.attemptsLeft } : {}),
        },
      },
      tx,
    );
  }
}
