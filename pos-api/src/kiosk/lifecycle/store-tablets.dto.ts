import { IsIn, IsOptional } from 'class-validator';
import { isUuid } from '../../common/ids/uuid.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';

/**
 * DTO управления планшетами магазина `/admin/store-tablets*` (08 §3.17, §4.18.11–§4.18.15; OpenAPI 1.3.0
 * `StoreTablet`, `KioskTokens`, `KioskTabletsListResponse`, `KioskTabletsEnrollRequest`, `KioskTabletsUpdateRequest`,
 * `KioskTabletsRevokeRequest`, `KioskTabletsReconnectRequest`; ADR-115). `StoreTablet` — строгий (`additionalProperties: false`): без ПДн покупателей,
 * хэша и счётчиков аварийного кода и `device_key` (11 SEC-141); все поля присутствуют всегда, nullable — как `null`.
 */

/** CHECK `store_tablets_status_chk` (07 §6.1.1; OpenAPI `StoreTabletStatus`). */
export const STORE_TABLET_STATUSES = ['active', 'revoked'] as const;
export type StoreTabletStatus = (typeof STORE_TABLET_STATUSES)[number];

/** `StoreTablet` (08 §3.17): имя и склад — `user_profiles` технического пользователя (07 §5.65). */
export interface StoreTabletDto {
  readonly id: string;
  readonly name: string;
  readonly warehouseId: string;
  readonly status: StoreTabletStatus;
  readonly enrolledAt: string;
  readonly reconnectedAt: string | null;
  readonly revokedAt: string | null;
  /** `store_tablets.last_seen_at` — отметка связи (не чаще раза в 60 с, `KioskPresenceService`). */
  readonly lastSeenAt: string | null;
  /** `X-Kiosk-Lock`: `true` — on, `false` — off, `null` — сигнала ещё не было (после подключения). */
  readonly lockTaskEnabled: boolean | null;
  /** `X-App-Version` (`store_tablets.last_app_version`). */
  readonly appVersion: string | null;
  /** Абсолютный срок действующей сессии планшета (`max(sessions.expires_at)`); `null` — сессии нет. */
  readonly expiresAt: string | null;
}

/** `KioskTabletsListResponse` (08 §4.18.12): без пагинации, порядок — по имени. */
export interface StoreTabletsListDto {
  readonly items: readonly StoreTabletDto[];
}

/**
 * `KioskTokens` (08 §3.17; ответ 201 подключения и 200 подключения заново): токены планшета и аварийный код выхода —
 * показывается один раз; не пишется в логи, аудит, уведомления и хранилище идемпотентности (11 SEC-140, SEC-141).
 */
export interface KioskTokensDto {
  readonly tablet: StoreTabletDto;
  readonly accessToken: string;
  readonly accessExpiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: string;
  readonly sid: string;
  readonly exitCode: string;
}

/** Строка проекции планшета (`store_tablets` + `user_profiles` + срок сессии) — данные без правил видимости. */
export interface StoreTabletView {
  readonly id: string;
  readonly userId: string;
  readonly name: string | null;
  readonly warehouseId: string | null;
  readonly status: StoreTabletStatus;
  readonly enrolledAt: Date;
  readonly reconnectedAt: Date | null;
  readonly revokedAt: Date | null;
  readonly lastSeenAt: Date | null;
  readonly lockTaskEnabled: boolean | null;
  readonly appVersion: string | null;
  readonly expiresAt: Date | null;
}

const iso = (d: Date | null): string | null => (d === null ? null : d.toISOString());

export function toStoreTabletDto(v: StoreTabletView): StoreTabletDto {
  return {
    id: v.id,
    // Имя и склад задаёт только подключение и PATCH (обязательны); пустые значения — лишь у строк, созданных вне API.
    name: v.name ?? '',
    warehouseId: v.warehouseId ?? '',
    status: v.status,
    enrolledAt: v.enrolledAt.toISOString(),
    reconnectedAt: iso(v.reconnectedAt),
    revokedAt: iso(v.revokedAt),
    lastSeenAt: iso(v.lastSeenAt),
    lockTaskEnabled: v.lockTaskEnabled,
    appVersion: v.appVersion,
    expiresAt: iso(v.expiresAt),
  };
}

/** Query `GET /admin/store-tablets` (08 §4.18.12): `status` ∈ `active | revoked`; иные параметры → 400. */
export class StoreTabletsListQuery {
  @IsOptional()
  @IsIn(STORE_TABLET_STATUSES)
  status?: StoreTabletStatus;
}

/** Тело `POST /admin/store-tablets` после проверки (`KioskTabletsEnrollRequest`). */
export interface StoreTabletEnrollBody {
  /** Имя планшета без пробелов по краям, 2…150 символов. */
  readonly name: string;
  readonly warehouseId: string;
}

/** Тело `PATCH /admin/store-tablets/{id}` после проверки (`KioskTabletsUpdateRequest`): хотя бы одно поле. */
export interface StoreTabletUpdateBody {
  readonly name?: string;
  readonly warehouseId?: string;
}

/** Тело `POST /admin/store-tablets/{id}/revoke` после проверки (`KioskTabletsRevokeRequest`; тело необязательно). */
export interface StoreTabletRevokeBody {
  /** Причина — только в аудит `kiosk.revoked` (не в `store_tablets`); пустая строка → `null`. */
  readonly reason: string | null;
}

export const TABLET_NAME_MIN = 2;
export const TABLET_NAME_MAX = 150;
export const REVOKE_REASON_MAX = 200;

const ENROLL_FIELDS: ReadonlySet<string> = new Set(['name', 'warehouseId']);
const UPDATE_FIELDS: ReadonlySet<string> = ENROLL_FIELDS;
const REVOKE_FIELDS: ReadonlySet<string> = new Set(['reason']);
const NO_FIELDS: ReadonlySet<string> = new Set();
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001F\u007F]/;

function invalid(errors: readonly ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status: 400, detail: 'Запрос не прошёл проверку.', errors });
}

/** Объект тела; иное → 400 `body:type`. `optional` — отсутствующее тело (`undefined`, `null`) = `{}`. */
function bodyObject(raw: unknown, optional: boolean): Record<string, unknown> {
  if (optional && (raw === undefined || raw === null)) return {};
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw invalid([{ field: 'body', rule: 'type', message: 'Ожидается объект JSON' }]);
  }
  return raw as Record<string, unknown>;
}

/** Иные поля → `forbidden_field` (контракт `additionalProperties: false`, как `POST /kiosk/order-otp`). */
function forbidden(body: Record<string, unknown>, allowed: ReadonlySet<string>, errors: ProblemFieldError[]): void {
  for (const k of Object.keys(body)) {
    if (!allowed.has(k)) errors.push({ field: k, rule: 'forbidden_field', message: 'Поле не принимается' });
  }
}

function nameOf(v: unknown, errors: ProblemFieldError[]): string | undefined {
  if (typeof v !== 'string') {
    errors.push({ field: 'name', rule: 'type', message: 'Имя планшета — строка' });
    return undefined;
  }
  const name = v.trim();
  if (name.length < TABLET_NAME_MIN || name.length > TABLET_NAME_MAX) {
    errors.push({
      field: 'name',
      rule: 'length',
      message: `Имя планшета — ${TABLET_NAME_MIN}…${TABLET_NAME_MAX} символов`,
    });
    return undefined;
  }
  if (CONTROL_CHARS.test(name)) {
    errors.push({ field: 'name', rule: 'no_control_chars', message: 'Имя без управляющих символов' });
    return undefined;
  }
  return name;
}

function warehouseOf(v: unknown, errors: ProblemFieldError[]): string | undefined {
  if (typeof v !== 'string' || !isUuid(v)) {
    errors.push({ field: 'warehouseId', rule: 'uuid', message: 'Ожидается UUID склада' });
    return undefined;
  }
  return v.toLowerCase();
}

/** Разбор тела подключения (08 §4.18.11): `name` 2…150, `warehouseId` — UUID; иные поля → `forbidden_field`. */
export function parseEnrollBody(raw: unknown): StoreTabletEnrollBody {
  const body = bodyObject(raw, false);
  const errors: ProblemFieldError[] = [];
  forbidden(body, ENROLL_FIELDS, errors);
  const name = nameOf(body.name, errors);
  const warehouseId = warehouseOf(body.warehouseId, errors);
  if (errors.length > 0 || name === undefined || warehouseId === undefined) throw invalid(errors);
  return { name, warehouseId };
}

/** Разбор тела изменения (08 §4.18.13): хотя бы одно из `name`, `warehouseId`; пустое тело → 400 `min_properties`. */
export function parseUpdateBody(raw: unknown): StoreTabletUpdateBody {
  const body = bodyObject(raw, false);
  const errors: ProblemFieldError[] = [];
  forbidden(body, UPDATE_FIELDS, errors);
  const hasName = body.name !== undefined;
  const hasWarehouse = body.warehouseId !== undefined;
  if (!hasName && !hasWarehouse && errors.length === 0) {
    errors.push({ field: 'body', rule: 'min_properties', message: 'Укажите имя или склад планшета' });
  }
  const name = hasName ? nameOf(body.name, errors) : undefined;
  const warehouseId = hasWarehouse ? warehouseOf(body.warehouseId, errors) : undefined;
  if (errors.length > 0) throw invalid(errors);
  return { ...(name !== undefined ? { name } : {}), ...(warehouseId !== undefined ? { warehouseId } : {}) };
}

/**
 * Разбор тела подключения заново (08 §4.18.15; OpenAPI `KioskTabletsReconnectRequest`): пустой объект, тело
 * необязательно; любое поле → 400 `forbidden_field`, не объект → 400 `body:type`.
 */
export function parseReconnectBody(raw: unknown): void {
  const body = bodyObject(raw, true);
  const errors: ProblemFieldError[] = [];
  forbidden(body, NO_FIELDS, errors);
  if (errors.length > 0) throw invalid(errors);
}

/** Разбор тела отключения (08 §4.18.14): тело необязательно; `reason` — строка ≤ 200 или `null`. */
export function parseRevokeBody(raw: unknown): StoreTabletRevokeBody {
  const body = bodyObject(raw, true);
  const errors: ProblemFieldError[] = [];
  forbidden(body, REVOKE_FIELDS, errors);
  const r = body.reason;
  let reason: string | null = null;
  if (r !== undefined && r !== null) {
    if (typeof r !== 'string') {
      errors.push({ field: 'reason', rule: 'type', message: 'Причина — строка' });
    } else if (r.length > REVOKE_REASON_MAX) {
      errors.push({ field: 'reason', rule: 'max_length', message: `Причина — до ${REVOKE_REASON_MAX} символов` });
    } else if (CONTROL_CHARS.test(r.replace(/[\r\n\t]/g, ' '))) {
      errors.push({ field: 'reason', rule: 'no_control_chars', message: 'Причина без управляющих символов' });
    } else {
      reason = r.trim() === '' ? null : r.trim();
    }
  }
  if (errors.length > 0) throw invalid(errors);
  return { reason };
}
