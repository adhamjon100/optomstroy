import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { classifySyncErrors, loadCatalogFixtures } from '../../scripts/load_catalog_fixtures.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';

/**
 * `scripts/load_catalog_fixtures.ts` (RM-E-011; загрузчик local-stack и демо ADR-109): отчёт о дублях `onec_code`
 * (`DUPLICATE_SUSPECTED` уровня warning, 05 SYNC-004, E-KI-04) — не ошибка маппинга и не делает итог красным.
 * Фикстуры 1С + синтетика заведомо дают такие дубли (тестовые данные).
 */
describe('scripts/load_catalog_fixtures.ts — отчёт DUPLICATE_SUSPECTED не ломает итог (E-KI-04)', () => {
  let f: CatalogFixture;
  let media: string;

  beforeAll(async () => {
    f = await startCatalogFixture({ database: 'load_cli', skipLoad: true, includeFixtures: false, skuCount: 0 });
    media = mkdtempSync(path.join(process.env['TEMP'] ?? tmpdir(), 'pos-load-cli-media-'));
  });

  afterAll(async () => {
    await f?.stop();
    if (media) rmSync(media, { recursive: true, force: true });
  });

  it('фикстуры 1С + 200 SKU: дубли кода — в syncWarnings, ошибок маппинга 0, ok=true', async () => {
    const r = await loadCatalogFixtures(f.pool, { sku: 200, images: 3, includeFixtures: true, mediaDir: media });
    const dups = await f.pool.query<{ severity: string }>(
      `SELECT severity::text AS severity FROM sync_errors WHERE error_code = 'DUPLICATE_SUSPECTED'`,
    );
    expect(dups.rows.length).toBeGreaterThan(0);
    expect(dups.rows.every((d) => d.severity === 'warning')).toBe(true);
    expect(r.syncWarnings['DUPLICATE_SUSPECTED']).toBe(dups.rows.length);
    expect(r.syncErrors['DUPLICATE_SUSPECTED']).toBe(dups.rows.length);
    expect(r.mappingErrors).toBe(0);
    expect(r.ok).toBe(true);
  });

  it('классификация: warning-дубль — отчёт; DUPLICATE_SUSPECTED уровня error и прочие коды — ошибки; фото — нет', () => {
    const c = classifySyncErrors([
      { code: 'DUPLICATE_SUSPECTED', severity: 'warning', n: 4 },
      { code: 'DUPLICATE_SUSPECTED', severity: 'error', n: 1 },
      { code: 'VALIDATION', severity: 'error', n: 2 },
      { code: 'IMAGE_DECODE_FAILED', severity: 'error', n: 5 },
      { code: 'HASH_MISMATCH', severity: 'error', n: 1 },
    ]);
    expect(c.syncErrors).toEqual({ DUPLICATE_SUSPECTED: 5, VALIDATION: 2, IMAGE_DECODE_FAILED: 5, HASH_MISMATCH: 1 });
    expect(c.syncWarnings).toEqual({ DUPLICATE_SUSPECTED: 4 });
    expect(c.mappingErrors).toBe(3);
  });
});
