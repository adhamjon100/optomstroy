import { createHmac, timingSafeEqual } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { OTP_HMAC_SECRET_RING } from '../../common/crypto/crypto.module.js';
import type { SecretRing } from '../../common/crypto/secret-ring.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/**
 * Позиция выгрузки в порядке `(updated_at, <ключ>)` по возрастанию (08 §4.24 «Семантика курсора»).
 * `ts` — метка PostgreSQL с микросекундами в UTC (`2026-10-22T09:00:00.123456Z`): точность JS `Date` (мс)
 * недостаточна — строки одной транзакции различаются только микросекундами или совпадают полностью.
 * `key` — значения ключа строки после `updated_at` (`[id]`; у `stock` — `[variant_id, warehouse_id]`).
 */
export interface SyncPosition {
  readonly ts: string;
  readonly key: readonly string[];
}

export interface DecodedSyncCursor {
  readonly position: SyncPosition;
  /** Момент выдачи курсора (мс эпохи): основание проверки срока хранения удалений (409 `cursor_expired`). */
  readonly issuedAt: number;
  /** Отпечаток области видимости зрителя на момент выдачи (`undefined` — курсор выдан до введения отпечатка). */
  readonly scope?: string;
}

const PURPOSE = 'pos-api:catalog-sync-cursor:v1';
const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const MAX_CURSOR_LENGTH = 2048;

/**
 * Непрозрачный курсор `GET /catalog/sync/{entity}` (08 §4.24, §2.5): `base64url(JSON) "." HMAC-SHA256`, где JSON —
 * `{ v: <версия ключа>, e: <entity>, s: [<updated_at>, ...<ключ>], t: <выдан, мс> }`. Ключ подписи выводится из
 * `OTP_HMAC_SECRET` (текущая версия) с отдельной меткой назначения — курсор не раскрывает секрет и не совместим
 * с курсорами экранных списков. Подделка, чужая сущность или неверный формат → `400 VALIDATION_FAILED`, rule `cursor`.
 */
@Injectable()
export class CatalogSyncCursorCodec {
  private readonly keys = new Map<number, Buffer>();

  constructor(@Inject(OTP_HMAC_SECRET_RING) private readonly ring: SecretRing) {}

  /**
   * `scope` — отпечаток области видимости зрителя (роль, видимые виды цен, режим и порог остатков, склад): инкремент
   * отдаёт только строки, изменённые после `since`, поэтому курсор, выданный для другой области, не может продолжать
   * выгрузку (ревью E-api-3) — сервис отвечает `409 cursor_expired`, клиент загружает сущность заново.
   */
  encode(entity: string, position: SyncPosition, issuedAt: number, scope?: string): string {
    const v = this.ring.currentVersion;
    const body = Buffer.from(
      JSON.stringify({
        v,
        e: entity,
        s: [position.ts, ...position.key],
        t: issuedAt,
        ...(scope !== undefined ? { c: scope } : {}),
      }),
      'utf8',
    ).toString('base64url');
    return `${body}.${this.sign(v, body)}`;
  }

  decode(cursor: string, entity: string, keyLength: number): DecodedSyncCursor {
    if (cursor.length === 0 || cursor.length > MAX_CURSOR_LENGTH) throw invalidCursor();
    const dot = cursor.indexOf('.');
    if (dot <= 0 || cursor.indexOf('.', dot + 1) !== -1) throw invalidCursor();
    const body = cursor.slice(0, dot);
    const sig = cursor.slice(dot + 1);
    let parsed: unknown;
    try {
      parsed = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    } catch {
      throw invalidCursor();
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw invalidCursor();
    const p = parsed as Record<string, unknown>;
    if (typeof p.v !== 'number' || !Number.isInteger(p.v)) throw invalidCursor();
    const expected = this.sign(p.v, body);
    const a = Buffer.from(sig, 'utf8');
    const b = Buffer.from(expected, 'utf8');
    if (expected === '' || a.length !== b.length || !timingSafeEqual(a, b)) throw invalidCursor();
    if (p.e !== entity) throw invalidCursor('Курсор выдан для другой сущности.');
    const s = p.s;
    if (!Array.isArray(s) || s.length !== keyLength + 1 || !s.every((x) => typeof x === 'string')) {
      throw invalidCursor();
    }
    const [ts, ...key]: string[] = s;
    if (!TS_RE.test(ts) || Number.isNaN(Date.parse(ts)) || !key.every((k) => UUID_RE.test(k))) throw invalidCursor();
    if (typeof p.t !== 'number' || !Number.isSafeInteger(p.t) || p.t <= 0) throw invalidCursor();
    if (p.c !== undefined && (typeof p.c !== 'string' || p.c.length > 64)) throw invalidCursor();
    return { position: { ts, key }, issuedAt: p.t, ...(typeof p.c === 'string' ? { scope: p.c } : {}) };
  }

  private sign(version: number, body: string): string {
    let key = this.keys.get(version);
    if (!key) {
      const secret = this.ring.get(version);
      if (!secret) return '';
      key = createHmac('sha256', secret).update(PURPOSE).digest();
      this.keys.set(version, key);
    }
    return createHmac('sha256', key).update(body).digest('base64url');
  }
}

export function invalidCursor(
  message = 'Курсор недействителен — начните загрузку сущности без since.',
): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Курсор недействителен.',
    errors: [{ field: 'since', rule: 'cursor', message }],
  });
}
