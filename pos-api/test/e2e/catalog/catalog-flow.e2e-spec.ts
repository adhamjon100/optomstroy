import { randomUUID } from 'node:crypto';
import type { INestApplication } from '@nestjs/common';
import pino from 'pino';
import request from 'supertest';
import { createApp } from '../../../src/bootstrap/create-app.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { QUEUES } from '../../../src/common/jobs/contracts/queues.js';
import { PinHasher } from '../../../src/common/crypto/pin-hasher.service.js';
import { FakeOnecGateway } from '../../../src/integrations/onec/fake-onec.gateway.js';
import { SyncJobProcessor } from '../../../src/jobs/sync/sync-job.processor.js';
import { StubSyncHandler } from '../../../src/jobs/sync/sync-handler.js';
import { createSyncWorkerWiring, type SyncWorkerWiring } from '../../../src/jobs/sync/sync-worker.wiring.js';
import { CATALOG_LOAD_ORDER } from '../../../src/sync/apply/catalog-full-load.service.js';
import type { RoleCode } from '../../../src/users/users.types.js';
import { FoundationDb, seedSubject } from '../../foundation/support/foundation-db.js';
import { LogCapture, testConfig } from '../../support/test-app.js';

/**
 * RM-E-012 (backend, интеграция этапа E): сквозной сценарий приложения AppModule (все модули, глобальные guard'ы,
 * реальные access-JWT и сессии) на embedded PostgreSQL 17 со всеми миграциями:
 *
 *   синхронизация каталога через FakeOnecGateway обработчиками pos-worker (`createSyncWorkerWiring` →
 *   `SyncJobProcessor` по сущностям 05 SYNC-001) → `/sync/status` → `/catalog/products` (ETag/304, цены строкой,
 *   курсор) → карточка → «Недавние» → `/search/products` (артикул, FTS) → `/search/barcode/{value}` →
 *   `/inventory/check` (3 варианта) → избранное (двойной PUT, DELETE) → `/catalog/sync/{entity}` (выгрузка = реплика)
 *   → изменение в «1С» → цикл `onec.changes` → инкремент `/catalog/sync/products?since=` (1 изменённый, 1 удалённый).
 *
 * **На фикстурах, не реальная интеграция**: фикстуры `contracts/onec/fixtures` + синтетический каталог.
 * Настоящие процессы (dist/main.js, отдельный процесс загрузки) — `catalog-process.e2e-spec.ts` и
 * `node scripts/local-stack.mjs catalog-smoke`.
 */
const SKU = 300;
const HEAD = { 'X-App-Version': '99.0.0', 'X-Platform': 'android' };

describe('Этап E: синхронизация (FakeOnecGateway) → каталог → поиск → остатки → избранное → офлайн-API', () => {
  const fdb = new FoundationDb();
  let app: INestApplication;
  let gateway: FakeOnecGateway;
  let wiring: SyncWorkerWiring;
  const actors = {} as Record<'seller' | 'admin' | 'customer', { token: string; deviceKey: string }>;
  const log = pino({ level: 'silent' });

  const call = (role: keyof typeof actors, method: 'get' | 'post' | 'put' | 'delete', path: string) => {
    const a = actors[role];
    let r = request(app.getHttpServer())
      [method](`/api/v1${path}`)
      .set(HEAD)
      .set('Authorization', `Bearer ${a.token}`)
      .set('X-Device-Id', a.deviceKey);
    if (method !== 'get') r = r.set('Idempotency-Key', randomUUID());
    return r;
  };

  beforeAll(async () => {
    await fdb.start('catalog_flow_e2e');
    const config = testConfig({ DATABASE_URL: fdb.url, LOG_LEVEL: 'silent', ONEC_MODE: 'fixtures' });
    app = await createApp(config, { logStream: new LogCapture() });
    const jwt = app.get(JwtService);
    const hasher = app.get(PinHasher);
    for (const role of ['seller', 'admin', 'customer'] as const) {
      const kind = role === 'customer' ? 'customer' : 'staff';
      const s = await seedSubject(fdb.db, { role: role as RoleCode, kind });
      const h = await hasher.hash('482913', s.userId);
      await fdb.pool.query(
        `INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, changed_at) VALUES ($1, $2, $3, $4, now())`,
        [s.userId, h.pinHash, h.pepperVersion, h.pinLength],
      );
      const token = (
        await jwt.signAccess({
          sub: s.userId,
          kind,
          roles: [role as RoleCode] as never,
          permissionsVersion: 1,
          deviceId: s.deviceKey,
          sid: s.session.id,
        })
      ).token;
      actors[role] = { token, deviceKey: s.deviceKey };
    }
    gateway = new FakeOnecGateway({
      catalog: { skuCount: SKU, seed: 7 },
      includeFixtureCatalog: true,
      registerAll: false,
    });
    wiring = createSyncWorkerWiring({ config, pool: fdb.pool, log, gateway, images: null });
  });

  afterAll(async () => {
    await app?.close();
    await fdb.stop();
  });

  // 12 T-SYNC-001 (каталожные сущности обработчиками worker), T-SYNC-007
  it('1. полная синхронизация через FakeOnecGateway обработчиками pos-worker: все прогоны success, $count сошёлся', async () => {
    const stub = new StubSyncHandler();
    const processor = new SyncJobProcessor(wiring.registry, (e) => wiring.handlers[e] ?? stub, fdb.pool, log);
    for (const entity of CATALOG_LOAD_ORDER) {
      const out = await processor.process(
        { id: randomUUID(), retryCount: 0 },
        { entity, mode: 'full', trigger: 'manual' },
      );
      expect(out, entity).toMatchObject({ status: 'completed', implemented: true });
    }
    const runs = await fdb.pool.query<{ entity: string; status: string }>(
      `SELECT entity::text AS entity, status::text AS status FROM sync_runs ORDER BY started_at`,
    );
    expect(runs.rows.length).toBeGreaterThanOrEqual(CATALOG_LOAD_ORDER.length);
    expect(runs.rows.filter((r) => r.status !== 'success')).toEqual([]);
    const report = await wiring.countCheck.run({ trigger: 'manual' });
    expect(report.mismatches).toBe(0);
    const errors = await fdb.pool.query(`SELECT error_code FROM sync_errors`);
    expect(errors.rows).toEqual([]);

    const st = await call('admin', 'get', '/sync/status');
    expect(st.status).toBe(200);
    const products = (st.body as { entities: { entity: string; lastSuccessAt?: string | null }[] }).entities.find(
      (e) => e.entity === 'products',
    );
    expect(products?.lastSuccessAt).toBeTruthy();
  });

  let page1: { id: string; hasVariants: boolean; defaultVariantId?: string; baseUnit: { id: string } }[] = [];

  // 12 T-CAT-001
  it('2. /catalog/products: страница, цены строкой + KGS, курсор без повторов, ETag → 304', async () => {
    const r = await call('seller', 'get', '/catalog/products?limit=50');
    expect(r.status).toBe(200);
    const body = r.body as {
      items: (typeof page1)[number] & { price?: { price: { amount: string; currency: string } } }[];
      nextCursor: string;
      hasMore: boolean;
    };
    page1 = body.items as unknown as typeof page1;
    expect(body.items).toHaveLength(50);
    expect(body.hasMore).toBe(true);
    const priced = (body.items as unknown as { price?: { price: { amount: string; currency: string } } }[]).filter(
      (p) => p.price,
    );
    expect(priced.length).toBeGreaterThan(0);
    for (const p of priced) {
      expect(p.price?.price.amount).toMatch(/^\d{1,13}\.\d{2}$/);
      expect(p.price?.price.currency).toBe('KGS');
    }
    const r2 = await call('seller', 'get', `/catalog/products?limit=50&cursor=${encodeURIComponent(body.nextCursor)}`);
    expect(r2.status).toBe(200);
    const ids = new Set(page1.map((p) => p.id));
    expect((r2.body as { items: { id: string }[] }).items.filter((p) => ids.has(p.id))).toEqual([]);
    const etag = r.headers['etag'];
    expect(etag).toBeTruthy();
    const r304 = await call('seller', 'get', '/catalog/products?limit=50').set('If-None-Match', etag);
    expect(r304.status).toBe(304);
  });

  it('3. карточка → «Недавние» (побочный эффект @RecordsRecentView, 08 §4.4.3)', async () => {
    const id = page1[0].id;
    const card = await call('seller', 'get', `/catalog/products/${id}`);
    expect(card.status).toBe(200);
    let found = false;
    for (let i = 0; i < 30 && !found; i++) {
      const recent = await call('seller', 'get', '/catalog/products/recent');
      found = (recent.body as { items: { id: string }[] }).items.some((x) => x.id === id);
      if (!found) await new Promise((res) => setTimeout(res, 100));
    }
    expect(found).toBe(true);
  });

  // 12 T-CAT-002
  it('4. поиск: артикул F4252 → sku; «смеситель фрап» → fts; штрихкод → товар и вариант', async () => {
    const sku = await call('seller', 'get', `/search/products?q=${encodeURIComponent('F4252')}`);
    expect(sku.status).toBe(200);
    expect((sku.body as { items: { sku: string; matchType: string }[] }).items[0]).toMatchObject({
      sku: 'F4252',
      matchType: 'sku',
    });
    const fts = await call('seller', 'get', `/search/products?q=${encodeURIComponent('смеситель фрап')}`);
    expect(fts.status).toBe(200);
    const items = (fts.body as { items: { matchType: string }[] }).items;
    expect(items.length).toBeGreaterThan(0);
    expect(['fts', 'trgm']).toContain(items[0].matchType);
    const bc = await fdb.pool.query<{ value: string; product_id: string }>(
      `SELECT b.value, b.product_id FROM barcodes b JOIN products p ON p.id = b.product_id
        WHERE NOT b.deletion_mark AND NOT p.deletion_mark AND b.packaging_id IS NULL ORDER BY b.value LIMIT 1`,
    );
    const r = await call('seller', 'get', `/search/barcode/${encodeURIComponent(bc.rows[0].value)}`);
    expect(r.status).toBe(200);
    expect((r.body as { product: { id: string } }).product.id).toBe(bc.rows[0].product_id);
  });

  it('5. /inventory/check для 3 вариантов → ok/shortages/unavailable; customer — без количеств', async () => {
    const wh = await call('seller', 'get', '/catalog/warehouses');
    const warehouseId = (wh.body as { items: { id: string }[] }).items[0].id;
    const three = page1.filter((p) => !p.hasVariants && p.defaultVariantId).slice(0, 3);
    expect(three).toHaveLength(3);
    const r = await call('seller', 'post', '/inventory/check').send({
      warehouseId,
      items: three.map((p) => ({ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id } })),
    });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ ok: expect.any(Boolean), shortages: expect.any(Array), unavailable: [] });
    const c = await call('customer', 'get', '/catalog/products?limit=20');
    expect(c.status).toBe(200);
    for (const p of (c.body as { items: { stock?: Record<string, unknown> }[] }).items) {
      expect(p.stock ?? {}).not.toHaveProperty('quantity');
      expect(p.stock ?? {}).not.toHaveProperty('reserved');
    }
  });

  it('6. избранное: двойной PUT идемпотентен, DELETE убирает', async () => {
    const id = page1[1].id;
    expect((await call('seller', 'put', `/favorites/products/${id}`)).status).toBe(204);
    expect((await call('seller', 'put', `/favorites/products/${id}`)).status).toBe(204);
    const list = await call('seller', 'get', '/favorites/products');
    expect((list.body as { items: { id: string }[] }).items.filter((x) => x.id === id)).toHaveLength(1);
    expect((await call('seller', 'delete', `/favorites/products/${id}`)).status).toBe(204);
    const after = await call('seller', 'get', '/favorites/products');
    expect((after.body as { items: { id: string }[] }).items.some((x) => x.id === id)).toBe(false);
  });

  // 12 T-SYNC-002, T-CAT-034
  it('7. /catalog/sync/products: выгрузка = реплика; изменение в 1С → onec.changes → инкремент с since', async () => {
    let since: string | undefined;
    let total = 0;
    for (let i = 0; i < 50; i++) {
      const r = await call('seller', 'get', `/catalog/sync/products?limit=200${since ? `&since=${since}` : ''}`);
      expect(r.status).toBe(200);
      const b = r.body as { items: unknown[]; nextCursor: string; hasMore: boolean; deleted: string[] };
      expect(Object.keys(b).sort()).toEqual(['deleted', 'hasMore', 'items', 'nextCursor', 'serverTime']);
      total += b.items.length;
      since = encodeURIComponent(b.nextCursor);
      if (!b.hasMore) break;
    }
    const live = await fdb.pool.query<{ n: number }>(`SELECT count(*)::int AS n FROM products WHERE NOT deletion_mark`);
    expect(total).toBe(live.rows[0].n);

    // «1С»: переименован 1 товар и помечен на удаление 1 товар → план обмена → цикл onec.changes воркера
    const m = gateway.mutateCatalog({ renameProducts: 1, deleteProducts: 1 });
    expect(m.changedKeys.length).toBeGreaterThanOrEqual(2);
    const job = wiring.jobs[QUEUES.onecChanges];
    expect(job).toBeDefined();
    const res = (await job!({ id: randomUUID(), data: {} })) as { status: string };
    expect(res.status).toBe('applied');

    const inc = await call('seller', 'get', `/catalog/sync/products?limit=200&since=${since}`);
    expect(inc.status).toBe(200);
    const b = inc.body as { items: { id: string; name: string }[]; deleted: string[] };
    expect(b.items.length + b.deleted.length).toBeGreaterThanOrEqual(2);
    expect(b.items.some((p) => /\(обн\. \d+\)$/.test(p.name))).toBe(true);
    expect(b.deleted.length).toBeGreaterThanOrEqual(1);
    const node = await fdb.pool.query<{ n: string }>(
      `SELECT last_message_number::text AS n FROM sync_node_state WHERE node = 'pos'`,
    );
    expect(Number(node.rows[0].n)).toBeGreaterThanOrEqual(1);
  });
});
