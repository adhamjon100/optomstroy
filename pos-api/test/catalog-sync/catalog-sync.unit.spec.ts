import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import { parseSyncLimit } from '../../src/catalog/sync/catalog-sync.controller.js';
import { CatalogSyncCursorCodec } from '../../src/catalog/sync/catalog-sync.cursor.js';
import { CATALOG_SYNC_ENTITIES, CATALOG_SYNC_LOAD_ORDER } from '../../src/catalog/sync/catalog-sync.types.js';
import { contract } from '../settings/support/openapi-check.js';

/** Unit: курсор выгрузки, `limit`, перечень сущностей против контракта (RM-E-015; 08 §4.24). */
describe('RM-E-015 unit: курсор, limit, перечень сущностей', () => {
  const secret = 'x'.repeat(48);
  const codec = (s = secret, version = 1) =>
    new CatalogSyncCursorCodec(parseSecretRing('OTP_HMAC_SECRET', s, version, 'staging'));
  const pos = { ts: '2026-10-22T09:00:00.123456Z', key: ['0192d1c3-0000-7000-8000-000000000001'] };

  it('перечень сущностей = OpenAPI CatalogSyncEntity (ядро §22.7), порядок загрузки — те же 12', () => {
    const schema = contract().components.schemas.CatalogSyncEntity as unknown as { enum: string[] };
    expect([...CATALOG_SYNC_ENTITIES]).toEqual(schema.enum);
    expect([...CATALOG_SYNC_LOAD_ORDER].sort()).toEqual([...CATALOG_SYNC_ENTITIES].sort());
  });

  it('курсор: round-trip сохраняет микросекунды и ключ; чужая сущность, другой секрет, неверная длина ключа → rule cursor', () => {
    const c = codec();
    const s = c.encode('products', pos, 1_700_000_000_000);
    expect(s).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(c.decode(s, 'products', 1)).toEqual({ position: pos, issuedAt: 1_700_000_000_000 });
    const rule = (f: () => unknown) => {
      try {
        f();
      } catch (e) {
        return (e as { extensions: { errors: { rule: string }[] } }).extensions.errors[0].rule;
      }
      return 'ok';
    };
    expect(rule(() => c.decode(s, 'variants', 1))).toBe('cursor');
    expect(rule(() => c.decode(s, 'stock', 2))).toBe('cursor');
    expect(rule(() => codec('y'.repeat(48)).decode(s, 'products', 1))).toBe('cursor');
    expect(rule(() => c.decode('', 'products', 1))).toBe('cursor');
    expect(rule(() => c.decode(`${s}x`, 'products', 1))).toBe('cursor');
    const stock = c.encode('stock', { ts: pos.ts, key: [pos.key[0], '0192d1c3-0000-7000-8000-000000000002'] }, 1);
    expect(c.decode(stock, 'stock', 2).position.key).toHaveLength(2);
  });

  it('limit: по умолчанию 200; 1…200; 0, 201, дробное, текст → VALIDATION_FAILED rule limit', () => {
    expect(parseSyncLimit(undefined)).toBe(200);
    expect(parseSyncLimit('')).toBe(200);
    expect(parseSyncLimit('1')).toBe(1);
    expect(parseSyncLimit('200')).toBe(200);
    for (const v of ['0', '201', '1.5', 'abc', '-1']) {
      expect(() => parseSyncLimit(v), v).toThrowError(expect.objectContaining({ code: 'VALIDATION_FAILED' }) as Error);
    }
  });
});
