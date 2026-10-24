import { createHmac } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { OTP_HMAC_SECRET_RING } from '../../common/crypto/crypto.module.js';
import type { SecretRing } from '../../common/crypto/secret-ring.js';
import { fieldError } from './catalog-query.js';
import { openCursor, sealCursor } from './cursor-seal.js';

/**
 * Непрозрачный курсор keyset-пагинации (08 §2.5): JSON `{ "o": <sort>, "s": <ключ>, "id": <uuid> }`, зашифрованный
 * AES-256-GCM (целостность — тег GCM; содержимое — значение ключа сортировки — клиенту не раскрывается, ревью E-api-1).
 * Ключ шифрования выводится из серверного секрета `OTP_HMAC_SECRET` (текущая версия) с
 * отдельной меткой назначения — курсор не раскрывает секрет и не пересекается с HMAC OTP; версия ключа — в курсоре,
 * поэтому ротация секрета не ломает курсоры, выданные до неё (пока версия есть в наборе).
 * Подделанный курсор → `VALIDATION_FAILED` (rule `cursor`); курсор другой сортировки → rule `cursor_sort_mismatch`.
 */
export interface CursorPayload {
  /** Код сортировки, для которой выдан курсор. */
  readonly o: string;
  /** Значение ключа сортировки последней строки (null — строка из «хвоста» без значения, NULLS LAST). */
  readonly s: string | null;
  /** id последней строки (последний ключ сортировки всегда id). */
  readonly id: string;
}

const PURPOSE = 'pos-api:catalog-cursor:v2';
const AAD = 'catalog-cursor';

@Injectable()
export class CatalogCursorCodec {
  private readonly keys = new Map<number, Buffer>();

  constructor(@Inject(OTP_HMAC_SECRET_RING) private readonly ring: SecretRing) {}

  /** `<AES-GCM(JSON), base64url>.<версия ключа>` — содержимое (ключ сортировки) зашифровано (ревью E-api-1). */
  encode(payload: CursorPayload): string {
    const v = this.ring.currentVersion;
    const key = this.key(v);
    if (!key) throw new Error('catalog cursor: нет текущей версии секрета');
    return `${sealCursor(key, AAD, JSON.stringify({ o: payload.o, s: payload.s, id: payload.id }))}.${v}`;
  }

  /** Разбор и проверка; `sort` — текущая сортировка запроса. */
  decode(cursor: string, sort: string): CursorPayload {
    const bad = (): never => fieldError('cursor', 'cursor', 'Курсор недействителен.');
    if (cursor.length > 2048) bad();
    const dot = cursor.lastIndexOf('.');
    if (dot <= 0) bad();
    const version = cursor.slice(dot + 1);
    if (!/^\d{1,6}$/.test(version)) bad();
    const key = this.key(Number(version));
    if (!key) return bad();
    const plain = openCursor(key, AAD, cursor.slice(0, dot));
    if (plain === undefined) return bad();
    let parsed: unknown;
    try {
      parsed = JSON.parse(plain);
    } catch {
      bad();
    }
    if (parsed === null || typeof parsed !== 'object') bad();
    const { o, s, id } = parsed as Record<string, unknown>;
    if (typeof o !== 'string' || typeof id !== 'string' || !(s === null || typeof s === 'string')) return bad();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) return bad();
    if (o !== sort) fieldError('cursor', 'cursor_sort_mismatch', 'Курсор выдан для другой сортировки.');
    return { o, s, id };
  }

  /** Ключ AES-256 версии секрета: HMAC-SHA256(secret, метка назначения). */
  private key(version: number): Buffer | undefined {
    let key = this.keys.get(version);
    if (!key) {
      const secret = this.ring.get(version);
      if (!secret) return undefined;
      key = createHmac('sha256', secret).update(PURPOSE).digest();
      this.keys.set(version, key);
    }
    return key;
  }
}
