import { timingSafeEqual } from 'node:crypto';
import { isSyncEntity, type SyncEntity } from '../../common/enums.js';
import type { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/** DI-токен отправителя job pg-boss из процесса API (`POST /sync/runs`): `{ send(name, data, {singletonKey}) }`. */
export const SYNC_JOB_SENDER = 'SyncJobSender' as const;
/** DI-токен параметров API синхронизации (`SyncApiOptions`). */
export const SYNC_API_OPTIONS = 'SyncApiOptions' as const;

export interface SyncApiOptions {
  /** RL-ADMIN для `POST /sync/runs`: ручных запусков на сущность в окне (08 §4.17.2: 10 / 10 мин). */
  readonly manualRunsPerWindow: number;
  readonly manualRunsWindowSec: number;
  /** Порог `consecutiveErrors` для `overall=failed` (05 §7.6.1: ≥ 3). */
  readonly consecutiveErrorsThreshold: number;
  /** Прогон без обновления дольше порога считается потерянным (как у worker). */
  readonly staleRunSeconds: number;
}

export const DEFAULT_SYNC_API_OPTIONS: SyncApiOptions = {
  manualRunsPerWindow: 10,
  manualRunsWindowSec: 600,
  consecutiveErrorsThreshold: 3,
  staleRunSeconds: 3600,
};

/** Лимит страницы (08 §2.5; ядро §19.2): 1…200, по умолчанию 50. */
export const PAGE_DEFAULT_LIMIT = 50;
export const PAGE_MAX_LIMIT = 200;
/** Период `from…to` ≤ 366 дней (rule `date_range`, 08 §2.14). */
const MAX_RANGE_MS = 366 * 86_400_000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function validation(field: string, rule: string, message: string, status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

export function parseUuid(value: string | undefined, field: string): string {
  if (typeof value !== 'string' || !UUID_RE.test(value)) throw validation(field, 'uuid', 'Ожидается UUID.');
  return value.toLowerCase();
}

/** Путь `/{id}`: неверный формат — 404 (ресурса с таким id быть не может), как в других модулях — 400. */
export function parsePathId(value: string): string {
  return parseUuid(value, 'id');
}

export function parseLimit(raw: unknown): number {
  if (raw === undefined || raw === '') return PAGE_DEFAULT_LIMIT;
  const n = typeof raw === 'string' ? Number(raw) : NaN;
  if (!Number.isInteger(n) || n < 1 || n > PAGE_MAX_LIMIT) {
    throw validation('limit', 'range', `Целое 1…${PAGE_MAX_LIMIT}.`);
  }
  return n;
}

export function parseEntity(raw: unknown, field = 'entity'): SyncEntity | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (!isSyncEntity(raw)) throw validation(field, 'enum', 'Значение вне перечня sync_entity.');
  return raw;
}

export function parseDateRange(fromRaw: unknown, toRaw: unknown): { from?: Date; to?: Date } {
  const parse = (v: unknown, field: string): Date | undefined => {
    if (v === undefined || v === '') return undefined;
    const d = typeof v === 'string' ? new Date(v) : new Date(NaN);
    if (Number.isNaN(d.getTime())) throw validation(field, 'date_time', 'Ожидается дата-время ISO-8601.');
    return d;
  };
  const from = parse(fromRaw, 'from');
  const to = parse(toRaw, 'to');
  if (from && to && (from > to || to.getTime() - from.getTime() > MAX_RANGE_MS)) {
    throw validation('from', 'date_range', 'Период: from ≤ to, не более 366 дней.');
  }
  return { ...(from ? { from } : {}), ...(to ? { to } : {}) };
}

/** Позиция keyset-пагинации `(created_at, id)`. */
export interface KeysetPosition {
  readonly createdAt: string;
  readonly id: string;
}

const MAC_LENGTH = 32;

/**
 * Непрозрачный курсор (08 §2.5): `base64url(JSON).mac`, mac — HMAC-псевдоним `OtpHmacService` (домен
 * `cursor:<list>`). Подделанный курсор → 400 `VALIDATION_FAILED` rule `cursor`.
 */
export class SyncCursorCodec {
  constructor(
    private readonly hmac: OtpHmacService,
    private readonly list: string,
  ) {}

  encode(pos: KeysetPosition): string {
    const body = Buffer.from(JSON.stringify([pos.createdAt, pos.id]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  decode(cursor: unknown): KeysetPosition | undefined {
    if (cursor === undefined || cursor === '') return undefined;
    if (typeof cursor !== 'string') throw invalidCursor();
    const [body, mac, ...rest] = cursor.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== MAC_LENGTH) throw invalidCursor();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw invalidCursor();
    try {
      const v: unknown = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      if (
        Array.isArray(v) &&
        v.length === 2 &&
        typeof v[0] === 'string' &&
        typeof v[1] === 'string' &&
        !Number.isNaN(Date.parse(v[0])) &&
        UUID_RE.test(v[1])
      ) {
        return { createdAt: v[0], id: v[1] };
      }
    } catch {
      // общий ответ ниже
    }
    throw invalidCursor();
  }

  private mac(body: string): string {
    return this.hmac.pseudonym(`cursor:${this.list}`, body).slice(0, MAC_LENGTH);
  }
}

function invalidCursor(): ProblemException {
  return validation('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
}

export interface Page<T> {
  readonly items: T[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
}

/**
 * SQL-выражение позиции курсора: `created_at` с микросекундами в ISO-8601 UTC (точность keyset без потерь JS Date).
 */
export const CURSOR_TS_SQL = (col: string): string =>
  `to_char(${col} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

/** Страница из `limit + 1` строк: лишняя строка — признак `hasMore`. */
export function toPage<R extends { cursor_ts: string; id: string }, T>(
  rows: readonly R[],
  limit: number,
  codec: SyncCursorCodec,
  map: (r: R) => T,
): Page<T> {
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return {
    items: page.map(map),
    nextCursor: hasMore && last ? codec.encode({ createdAt: last.cursor_ts, id: last.id }) : null,
    hasMore,
  };
}

export function iso(d: Date | null | undefined): string | null {
  return d ? d.toISOString() : null;
}
