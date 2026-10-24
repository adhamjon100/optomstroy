import request from 'supertest';
import { CATALOG_SYNC_LOAD_ORDER } from '../../src/catalog/sync/catalog-sync.types.js';
import { type Actor, CatalogApiTestApp } from './support/catalog-api-app.js';

/**
 * Замер первичной выгрузки офлайн-кэша на 50 000 синтетических SKU (RM-E-015; NFR-PERF-006, DATA-257: «≤ 3 мин по
 * Wi-Fi» — целевой показатель клиента RM-E-009; здесь — только серверная часть in-process, без сети и gzip).
 * Запуск вручную: `CATALOG_SYNC_BENCH=1 npm run test:catalog-sync -- catalog-sync.bench` (по умолчанию пропускается:
 * загрузка каталога ~80 с). **Синтетические данные**, не реальная 1С.
 */
const SKU = Number(process.env.CATALOG_SYNC_BENCH_SKU ?? 50_000);

describe.skipIf(!process.env.CATALOG_SYNC_BENCH)(`RM-E-015 бенчмарк: выгрузка ${SKU} SKU страницами по 200`, () => {
  const t = new CatalogApiTestApp();
  let seller: Actor;

  beforeAll(async () => {
    await t.start('pos_catalog_bench', { skuCount: SKU, includeFixtures: false });
    seller = await t.actor('seller');
  }, 900_000);

  afterAll(async () => {
    await t.stop();
  });

  // 12 T-CAT-025 (серверная часть первичной загрузки; замер на устройстве — нет)
  it('все 12 сущностей без since до hasMore=false: время, страницы, строки, байты', async () => {
    const http = request(t.app.getHttpServer());
    const out: Record<
      string,
      { rows: number; deleted: number; pages: number; ms: number; maxPageMs: number; kb: number }
    > = {};
    const t0 = performance.now();
    for (const entity of CATALOG_SYNC_LOAD_ORDER) {
      let since: string | undefined;
      const s = { rows: 0, deleted: 0, pages: 0, ms: 0, maxPageMs: 0, kb: 0 };
      const e0 = performance.now();
      for (;;) {
        const p0 = performance.now();
        const r = await http
          .get(`/api/v1/catalog/sync/${entity}?limit=200${since ? `&since=${encodeURIComponent(since)}` : ''}`)
          .set('Authorization', `Bearer ${seller.token}`)
          .set('X-Device-Id', seller.deviceKey);
        expect(r.status).toBe(200);
        s.maxPageMs = Math.max(s.maxPageMs, Math.round(performance.now() - p0));
        s.pages += 1;
        s.rows += (r.body.items as unknown[]).length;
        s.deleted += (r.body.deleted as unknown[]).length;
        s.kb += Math.round(Buffer.byteLength(r.text) / 1024);
        since = r.body.nextCursor as string;
        if (!r.body.hasMore) break;
      }
      s.ms = Math.round(performance.now() - e0);
      out[entity] = s;
    }
    const totalMs = Math.round(performance.now() - t0);
    process.stdout.write(`\ncatalog-sync bench ${SKU} SKU (seller, limit=200): ${JSON.stringify({ totalMs, out })}\n`);
    expect(out.products.rows).toBeGreaterThan(SKU * 0.95);
    // Серверная часть первичной загрузки укладывается с запасом в бюджет 3 мин NFR-PERF-006.
    expect(totalMs).toBeLessThan(180_000);
  }, 900_000);
});
