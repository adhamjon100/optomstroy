import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { normalizeKgPhone } from '../../auth/common/phone.js';
import { OtpService } from '../../auth/otp/otp.service.js';
import type { AuditContext } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { isUuid } from '../../common/ids/uuid.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { kioskIntegerSetting } from '../../settings/public-settings.map.js';
import type { KioskTabletContext } from '../common/kiosk-tablet.reader.js';
import { kioskNoticeVersion } from './notice-catalog.js';

/** Тело `POST /kiosk/order-otp` после проверки (OpenAPI `KioskOrderOtpRequest`; 08 §4.25.1). */
export interface KioskOrderOtpBody {
  /** Нормализованный E.164 `+996XXXXXXXXX` (09 §3.4). */
  readonly phone: string;
  readonly cartId: string;
  readonly noticeVersion: string;
}

/** Ответ `202` (OpenAPI `KioskOrderOtpResponse`): одинаков для любого номера, номер не повторяется (11 SEC-017). */
export interface KioskOrderOtpResponse {
  readonly challengeId: string;
  readonly resendAfterSec: number;
}

const BODY_FIELDS: ReadonlySet<string> = new Set(['phone', 'cartId', 'noticeVersion']);

function invalid(errors: readonly ProblemFieldError[], status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail: 'Запрос не прошёл проверку.', errors });
}

/**
 * Разбор тела `POST /kiosk/order-otp` (08 §4.25.1; `additionalProperties: false`): иные поля → `400
 * VALIDATION_FAILED` rule `forbidden_field` (контракт, а не `additional_properties` общего ValidationPipe); номер —
 * мобильный КР (rule `phone_e164`, как `POST /auth/otp/request`); `cartId` — UUID (rule `uuid`); `noticeVersion` —
 * строка 1…32 без управляющих символов (rule `max_length`). Известность версии проверяет сервис (422).
 */
export function parseKioskOrderOtpBody(raw: unknown): KioskOrderOtpBody {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw invalid([{ field: 'body', rule: 'type', message: 'Ожидается объект JSON' }]);
  }
  const body = raw as Record<string, unknown>;
  const errors: ProblemFieldError[] = [];
  for (const k of Object.keys(body)) {
    if (!BODY_FIELDS.has(k)) errors.push({ field: k, rule: 'forbidden_field', message: 'Поле не принимается' });
  }
  const phone = normalizeKgPhone(body.phone);
  if (phone === null) {
    errors.push({
      field: 'phone',
      rule: 'phone_e164',
      message: 'Ожидается мобильный номер КР в формате +996XXXXXXXXX',
    });
  }
  const cartId = typeof body.cartId === 'string' ? body.cartId.toLowerCase() : undefined;
  if (!isUuid(cartId)) errors.push({ field: 'cartId', rule: 'uuid', message: 'Ожидается UUID' });
  const nv = body.noticeVersion;
  // eslint-disable-next-line no-control-regex
  if (typeof nv !== 'string' || nv.trim().length === 0 || nv.length > 32 || /[\u0000-\u001F\u007F]/.test(nv)) {
    errors.push({ field: 'noticeVersion', rule: 'max_length', message: 'Строка 1…32 символов' });
  }
  if (errors.length > 0) throw invalid(errors);
  return { phone: phone as string, cartId: cartId as string, noticeVersion: nv as string };
}

/**
 * Код к заявке с планшета магазина (08 §4.25.1; 09 §5.3, §5.4; 10 KIOSK-011, KIOSK-012, KIOSK-022; P-002 §8.5 п. 1–2,
 * §14.2, §14.4; ADR-115). Порядок: версия текста информирования (неизвестная → `422 VALIDATION_FAILED` rule
 * `notice_version`) → корзина (`cartId` — активная непустая корзина технического пользователя планшета, иначе
 * `422 CART_EMPTY`) → `OtpService.issue` с назначением `kiosk_order` и лимитами планшета `kiosk_otp_per_hour` /
 * `kiosk_otp_per_day` из `app_settings` (значения по умолчанию — в коде, `KIOSK_INTEGER_SETTINGS`). До выпуска кода SMS
 * не отправляется. Номер покупателя ни с чем не сравнивается: ни `users`, ни карточки клиентов, ни 1С здесь не
 * читаются — ответ, его статус и путь обработки одинаковы для номера с карточкой, без карточки и номера сотрудника
 * (11 SEC-017); карточку ищет только `POST /kiosk/orders` после верного кода (09 §7.8 (в)).
 */
@Injectable()
export class KioskOtpService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    private readonly otp: OtpService,
    private readonly settings: SettingsReader,
  ) {}

  async request(input: {
    readonly tablet: KioskTabletContext;
    readonly body: KioskOrderOtpBody;
    readonly deviceKey: string;
    readonly ip: string | null;
    readonly requestId: string | null;
    readonly audit: AuditContext;
  }): Promise<KioskOrderOtpResponse> {
    const { tablet, body } = input;
    const notice = kioskNoticeVersion(body.noticeVersion);
    if (!notice) {
      throw invalid(
        [{ field: 'noticeVersion', rule: 'notice_version', message: 'Неизвестная версия текста информирования' }],
        422,
      );
    }
    if (!(await this.isActiveNonEmptyCart(tablet.userId, body.cartId))) {
      throw new ProblemException('CART_EMPTY', { detail: 'Корзина пуста.' });
    }
    const [perHour, perDay] = await Promise.all([
      this.settings.get('kiosk_otp_per_hour').then((v) => kioskIntegerSetting('kiosk_otp_per_hour', v)),
      this.settings.get('kiosk_otp_per_day').then((v) => kioskIntegerSetting('kiosk_otp_per_day', v)),
    ]);
    const issued = await this.otp.issue({
      phoneE164: body.phone,
      purpose: 'kiosk_order',
      deviceKey: input.deviceKey,
      ip: input.ip,
      requestId: input.requestId,
      userId: null,
      audit: input.audit,
      kiosk: { tabletId: tablet.tabletId, cartId: body.cartId, noticeVersion: notice.version, perHour, perDay },
    });
    return { challengeId: issued.challengeId, resendAfterSec: issued.resendAfterSec };
  }

  /**
   * `cartId` — активная корзина технического пользователя планшета (одна `active` на владельца — частичный UNIQUE
   * `carts`) с хотя бы одной строкой. Чужая, отложенная, закрытая, несуществующая или пустая корзина → `false`
   * (`422 CART_EMPTY`, 08 §4.25.1): планшету не сообщается, какая из причин.
   */
  private async isActiveNonEmptyCart(ownerUserId: string, cartId: string): Promise<boolean> {
    const res = await this.db.execute<{ ok: boolean }>(sql`
      SELECT EXISTS (
        SELECT 1 FROM carts c
         WHERE c.id = ${cartId}::uuid AND c.owner_user_id = ${ownerUserId}::uuid AND c.status = 'active'
           AND EXISTS (SELECT 1 FROM cart_items i WHERE i.cart_id = c.id)
      ) AS ok`);
    return res.rows[0]?.ok === true;
  }
}
