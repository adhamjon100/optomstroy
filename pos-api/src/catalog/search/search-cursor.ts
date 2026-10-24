import { createHash } from 'node:crypto';
import { openCursor, sealCursor } from '../common/cursor-seal.js';
import { validationFailed } from './search-params.js';
import type { SearchStage } from './search-text.js';

/**
 * Курсор keyset-пагинации поиска (08 §2.5, OpenAPI `Cursor`): JSON, зашифрованный AES-256-GCM (`cursor-seal.ts`);
 * ключ выводится из HMAC (`OtpHmacService.pseudonym`, домен `cursor:search.products`). Шифрование, а не только
 * подпись: в ключах сортировки `available:desc` лежит остаток, который `customer` при `customer_stock_display=status`
 * получать не должен (ревью E-api-1).
 *
 * В курсоре: ступень D-31, выбранная на первой странице (следующие страницы не меняют `matchType` при изменении
 * данных между запросами), вариант ступени `trgm`, сортировка (смена → `cursor_sort_mismatch`), отпечаток `q` +
 * фильтров (другой запрос → rule `cursor`), значения ключей сортировки последней строки (последний — `id`).
 */
export interface SearchCursor {
  readonly stage: SearchStage;
  readonly sort: string;
  readonly fingerprint: string;
  readonly keys: readonly (string | number)[];
  /**
   * Вариант ступени `trgm`, выбранный на первой странице: исправленные слова (FTS по исправленному запросу) или
   * `null` — сравнение триграммами по исходному запросу. Продолжение идёт ровно этим вариантом, без повторного
   * исправления (иначе страницы 2+ теряли строки, ревью E-api-2). Для прочих ступеней — `undefined`.
   */
  readonly corrected?: readonly string[] | null;
}

export type CursorSigner = (body: string) => string;

const KEY_LABEL = 'pos-api:search-cursor:key:v2';
const AAD = 'search-cursor';
const STAGES: readonly string[] = ['barcode', 'sku', 'fts', 'trgm'];

export function cursorFingerprint(parts: unknown): string {
  return createHash('sha256').update(JSON.stringify(parts)).digest('base64url').slice(0, 16);
}

function invalid(): Error {
  return validationFailed([
    { field: 'cursor', rule: 'cursor', message: 'Курсор недействителен — запросите список заново.' },
  ]);
}

function validCorrected(cw: unknown): boolean {
  return (
    cw === undefined ||
    cw === null ||
    (Array.isArray(cw) && cw.length <= 32 && cw.every((w) => typeof w === 'string' && w.length <= 200))
  );
}

export class SearchCursorCodec {
  private key: Buffer | undefined;

  constructor(private readonly sign: CursorSigner) {}

  encode(c: SearchCursor): string {
    return sealCursor(
      this.cipherKey(),
      AAD,
      JSON.stringify({
        v: 2,
        st: c.stage,
        so: c.sort,
        f: c.fingerprint,
        k: c.keys,
        ...(c.corrected !== undefined ? { cw: c.corrected } : {}),
      }),
    );
  }

  /** Проверка целостности и соответствия запросу; ошибки — `400 VALIDATION_FAILED` (`cursor`, `cursor_sort_mismatch`). */
  decode(cursor: string, expected: { sort: string; fingerprint: string; keyCount?: number }): SearchCursor {
    if (cursor.length === 0 || cursor.length > 4096) throw invalid();
    const plain = openCursor(this.cipherKey(), AAD, cursor);
    if (plain === undefined) throw invalid();
    let parsed: unknown;
    try {
      parsed = JSON.parse(plain);
    } catch {
      throw invalid();
    }
    if (parsed === null || typeof parsed !== 'object') throw invalid();
    const o = parsed as Record<string, unknown>;
    if (
      o.v !== 2 ||
      typeof o.st !== 'string' ||
      !STAGES.includes(o.st) ||
      typeof o.so !== 'string' ||
      typeof o.f !== 'string' ||
      !Array.isArray(o.k) ||
      o.k.length === 0 ||
      o.k.length > 8 ||
      !o.k.every((x) => typeof x === 'string' || (typeof x === 'number' && Number.isFinite(x))) ||
      !validCorrected(o.cw)
    ) {
      throw invalid();
    }
    if (o.so !== expected.sort) {
      throw validationFailed([
        { field: 'cursor', rule: 'cursor_sort_mismatch', message: 'Сортировка изменилась — запросите список заново.' },
      ]);
    }
    if (o.f !== expected.fingerprint) throw invalid();
    if (expected.keyCount !== undefined && o.k.length !== expected.keyCount) throw invalid();
    return {
      stage: o.st as SearchStage,
      sort: o.so,
      fingerprint: o.f,
      keys: o.k as (string | number)[],
      ...(o.cw !== undefined ? { corrected: o.cw as string[] | null } : {}),
    };
  }

  /** AES-256: SHA-256 от HMAC-псевдонима метки назначения (секрет `OTP_HMAC_SECRET` в курсор не попадает). */
  private cipherKey(): Buffer {
    this.key ??= createHash('sha256').update(this.sign(KEY_LABEL)).digest();
    return this.key;
  }
}
