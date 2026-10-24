import { randomUUID } from 'node:crypto';
import { mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import pino from 'pino';
import sharp from 'sharp';
import type { OnecChangesPage, OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import {
  GatewayImageSource,
  type ImageFileEntry,
  ImageDirectoryImporter,
  ImageStore,
  ImageSyncService,
  ODataImageListSource,
  ProductImageFilesHandler,
  ProductImageRepository,
  parseCommerceMlImages,
  safeJoin,
} from '../../src/sync/images/index.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import {
  garbageBytes,
  sha256,
  syntheticJpeg,
  syntheticPng,
  TestImageGateway,
  tempMediaDir,
} from './support/image-fixtures.js';

/**
 * RM-E-003 — фото товаров. **Тестовые данные**: синтетический каталог (конвейер RM-E-001), синтетические
 * изображения (sharp), тестовый шлюз `getImage` по контракту HS 05 §6.3 — не реальная интеграция с 1С.
 */

const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const cleanups: (() => Promise<void> | void)[] = [];

interface Ctx {
  f: CatalogFixture;
  media: string;
  store: ImageStore;
  gw: TestImageGateway;
  repo: ProductImageRepository;
  svc: (opts?: ConstructorParameters<typeof ImageSyncService>[5]) => ImageSyncService;
  productId: (sku: string) => Promise<string>;
  anchor: (sku: string) => string;
}

async function setup(): Promise<Ctx> {
  const f = await startCatalogFixture({ pg: server, database: `img_${++dbNo}`, skuCount: 30, includeFixtures: false });
  const m = tempMediaDir();
  cleanups.push(() => f.stop(), m.cleanup);
  const store = new ImageStore(m.dir);
  const gw = new TestImageGateway();
  const runs = createRunTracker(f.pool);
  return {
    f,
    media: m.dir,
    store,
    gw,
    repo: new ProductImageRepository(),
    svc: (opts = {}) => new ImageSyncService(f.pool, new GatewayImageSource(gw), store, runs, silent, opts),
    productId: async (sku) => {
      const r = await f.pool.query<{ id: string }>(`SELECT id::text FROM products WHERE onec_ref = $1`, [
        f.refs.anchors[sku],
      ]);
      return r.rows[0].id;
    },
    anchor: (sku) => {
      const ref = f.refs.anchors[sku];
      if (!ref) throw new Error(`нет якоря ${sku}`);
      return ref;
    },
  };
}

function entry(
  sourceRef: string,
  ownerRef: string | null,
  version = '2026-10-01T10:00:00Z|0',
  sortOrder = 0,
): ImageFileEntry {
  return { sourceRef, ownerRef, sourceVersion: version, sortOrder };
}

/** Версия 1С с фактическим размером файла (проверка «частично скачанного»). */
function ver(data: Buffer, modified = '2026-10-01T10:00:00Z'): string {
  return `${modified}|${data.byteLength}`;
}

async function rowsOf(ctx: Ctx, where = 'TRUE', params: unknown[] = []) {
  const r = await ctx.f.pool.query<{
    id: string;
    source_ref: string;
    product_id: string | null;
    variant_id: string | null;
    status: string;
    sha: string | null;
    storage_key: string | null;
    sizes: Record<string, { w: number; h: number; bytes: number }> | null;
    is_primary: boolean;
    deleted: boolean;
    attempts: number | null;
    next_attempt_at: Date | null;
  }>(
    `SELECT id::text, source_ref, product_id::text, variant_id::text, status::text, encode(checksum_sha256,'hex') AS sha,
            storage_key, sizes, is_primary, deleted_at IS NOT NULL AS deleted, attempts, next_attempt_at
       FROM product_images WHERE ${where} ORDER BY created_at, id`,
    params,
  );
  return r.rows;
}

async function syncErrors(ctx: Ctx) {
  const r = await ctx.f.pool.query<{
    entity: string;
    error_code: string;
    onec_ref: string | null;
    severity: string;
    message: string;
    sync_run_id: string | null;
  }>(
    `SELECT entity::text, error_code, onec_ref::text, severity, message, sync_run_id::text FROM sync_errors ORDER BY created_at`,
  );
  return r.rows;
}

function storedDirs(media: string): string[] {
  try {
    return readdirSync(path.join(media, 'images')).filter((n) => !n.startsWith('.'));
  } catch {
    return [];
  }
}

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const c of cleanups.reverse()) await c();
  await server?.stop();
});

describe('RM-E-003 пайплайн фото: HS getImage → sharp → images/{sha256}/{size}.webp', () => {
  // 12 T-SYNC-043 (контрольная сумма sha256)
  it('один и тот же файл для двух товаров хранится один раз (sha256)', async () => {
    const ctx = await setup();
    const img = await syntheticJpeg(1600, 1200, 1);
    const [a, b] = [randomUUID(), randomUUID()];
    ctx.gw.serve(a, img);
    ctx.gw.serve(b, img);
    const reg = await ctx.repo.register(ctx.f.pool, [
      entry(a, ctx.anchor('F4252'), ver(img)),
      entry(b, ctx.anchor('F3241'), ver(img)),
    ]);
    expect(reg.inserted).toBe(2);

    const res = await ctx.svc({ concurrency: 2 }).run({ trigger: 'manual' });
    expect(res.status).toBe('success');
    expect(res.counts.ready).toBe(2);
    expect(res.counts.processed).toBe(1);
    expect(res.counts.deduplicated).toBe(1);

    const rows = await rowsOf(ctx);
    expect(rows).toHaveLength(2);
    const sha = sha256(img);
    for (const r of rows) {
      expect(r.status).toBe('ready');
      expect(r.sha).toBe(sha);
      expect(r.storage_key).toBe(`images/${sha}`);
    }
    // Два разных товара, одна копия файлов на диске.
    expect(new Set(rows.map((r) => r.product_id)).size).toBe(2);
    expect(storedDirs(ctx.media)).toEqual([sha]);
    expect(readdirSync(path.join(ctx.media, 'images', sha)).sort()).toEqual(['card.webp', 'full.webp', 'thumb.webp']);
    // Главное фото обоих товаров — их собственная строка.
    const p = await ctx.f.pool.query<{ id: string; primary_image_id: string }>(
      `SELECT id::text, primary_image_id::text FROM products WHERE id = ANY($1::uuid[])`,
      [rows.map((r) => r.product_id)],
    );
    for (const x of p.rows) expect(rows.find((r) => r.id === x.primary_image_id)?.product_id).toBe(x.id);
  });

  // 12 T-CAT-008 (битый файл → заглушка)
  // 12: T-SYNC-F11 (битый файл → sync_errors)
  it('битый файл → нет готовой записи (заглушка) и запись в sync_errors', async () => {
    const ctx = await setup();
    const good = await syntheticJpeg(800, 600, 2);
    const truncated = good.subarray(0, Math.floor(good.length / 2));
    const garbage = garbageBytes();
    const [g, t, ok] = [randomUUID(), randomUUID(), randomUUID()];
    ctx.gw.serve(g, garbage);
    ctx.gw.serve(t, truncated);
    ctx.gw.serve(ok, good);
    await ctx.repo.register(ctx.f.pool, [
      entry(g, ctx.anchor('G1017-8'), ver(garbage)),
      entry(t, ctx.anchor('SB-1WH'), ver(truncated)),
      entry(ok, ctx.anchor('VTP-20'), ver(good)),
    ]);
    const res = await ctx.svc().run();
    expect(res.status).toBe('partial');
    expect(res.counts.failed).toBe(2);
    expect(res.counts.ready).toBe(1);

    const bad = await rowsOf(ctx, 'source_ref = ANY($1)', [[g, t]]);
    expect(bad).toHaveLength(2);
    for (const r of bad) {
      expect(r.status).toBe('failed');
      expect(r.storage_key).toBeNull();
      expect(r.sizes).toBeNull();
      expect(r.is_primary).toBe(false);
      // Битый файл без автоповтора: повтор — только при новой версии в 1С.
      expect(r.next_attempt_at).toBeNull();
    }
    // Файлы битых исходников в хранилище не появились; товары без фото → primary_image_id NULL (заглушка).
    expect(storedDirs(ctx.media)).toEqual([sha256(good)]);
    const prim = await ctx.f.pool.query<{ onec_ref: string; primary_image_id: string | null }>(
      `SELECT onec_ref::text, primary_image_id::text FROM products WHERE onec_ref = ANY($1::uuid[])`,
      [[ctx.anchor('G1017-8'), ctx.anchor('SB-1WH')]],
    );
    for (const p of prim.rows) expect(p.primary_image_id).toBeNull();

    const errs = (await syncErrors(ctx)).filter((e) => e.entity === 'images');
    expect(errs).toHaveLength(2);
    expect(new Set(errs.map((e) => e.onec_ref))).toEqual(new Set([g, t]));
    for (const e of errs) {
      expect(e.error_code).toBe('IMAGE_DOWNLOAD');
      expect(e.severity).toBe('error');
      expect(e.sync_run_id).toBe(res.runId);
    }
    // Повторный прогон: битые файлы не перекачиваются, новых ошибок нет.
    const calls = ctx.gw.calls.length;
    await ctx.svc().run();
    expect(ctx.gw.calls.length).toBe(calls);
    expect((await syncErrors(ctx)).length).toBe(2);
  });

  // 12 T-CAT-006, T-SYNC-043 (160/400/1200 WebP)
  it('размеры thumb 160 / card 400 / full 1200, формат WebP, без увеличения', async () => {
    const ctx = await setup();
    const land = await syntheticJpeg(1600, 1200, 3);
    const port = await syntheticPng(900, 1600, 4);
    const small = await syntheticJpeg(300, 200, 5);
    const refs = [randomUUID(), randomUUID(), randomUUID()];
    ctx.gw.serve(refs[0], land);
    ctx.gw.serve(refs[1], port);
    ctx.gw.serve(refs[2], small);
    await ctx.repo.register(ctx.f.pool, [
      entry(refs[0], ctx.anchor('F4252'), ver(land)),
      entry(refs[1], ctx.anchor('F3241'), ver(port)),
      entry(refs[2], ctx.anchor('G1017-8'), ver(small)),
    ]);
    const res = await ctx.svc().run();
    expect(res.counts.ready).toBe(3);

    const expected: Record<string, Record<string, [number, number]>> = {
      [sha256(land)]: { thumb: [160, 120], card: [400, 300], full: [1200, 900] },
      [sha256(port)]: { thumb: [90, 160], card: [225, 400], full: [675, 1200] },
      [sha256(small)]: { thumb: [160, 107], card: [300, 200], full: [300, 200] },
    };
    for (const [sha, sizes] of Object.entries(expected)) {
      const [row] = await rowsOf(ctx, `checksum_sha256 = decode($1,'hex')`, [sha]);
      for (const [name, [w, h]] of Object.entries(sizes)) {
        const file = ctx.store.fileOf(sha, name as 'thumb');
        const meta = await sharp(file).metadata();
        expect(meta.format).toBe('webp');
        expect([meta.width, meta.height]).toEqual([w, h]);
        expect(row.sizes?.[name]).toEqual({ w, h, bytes: statSync(file).size });
      }
    }
    const meta = await ctx.f.pool.query<{ original_mime: string; width: number; height: number }>(
      `SELECT original_mime, width, height FROM product_images WHERE source_ref = $1`,
      [refs[1]],
    );
    expect(meta.rows[0]).toEqual({ original_mime: 'image/png', width: 900, height: 1600 });
  });

  // 12 T-CAT-008 (никогда фото другого товара)
  it('чужой onec_ref не привязывается: фото только у владельца по onec_ref', async () => {
    const ctx = await setup();
    const img = await syntheticJpeg(640, 480, 6);
    const [own, foreign, empty] = [randomUUID(), randomUUID(), randomUUID()];
    const unknownOwner = randomUUID();
    for (const r of [own, foreign, empty]) ctx.gw.serve(r, img);
    const variant = await ctx.f.pool.query<{ onec_ref: string; product_id: string; id: string }>(
      `SELECT onec_ref::text, product_id::text, id::text FROM product_variants WHERE NOT is_default ORDER BY onec_ref LIMIT 1`,
    );
    const v = variant.rows[0];
    const varRef = randomUUID();
    ctx.gw.serve(varRef, await syntheticJpeg(640, 480, 7));

    const reg = await ctx.repo.register(ctx.f.pool, [
      entry(own, ctx.anchor('F4252'), ver(img)),
      entry(foreign, unknownOwner, ver(img)),
      entry(empty, '00000000-0000-0000-0000-000000000000', ver(img)),
      entry(varRef, v.onec_ref, '2026-10-01T10:00:00Z|'),
    ]);
    expect(reg.inserted).toBe(2);
    expect(reg.ownerNotFound).toBe(2);
    await ctx.repo.writeErrors(ctx.f.pool, reg.errors);
    await ctx.svc().run();

    const rows = await rowsOf(ctx);
    expect(rows.map((r) => r.source_ref).sort()).toEqual([own, varRef].sort());
    const a = await ctx.productId('F4252');
    expect(rows.find((r) => r.source_ref === own)).toMatchObject({ product_id: a, variant_id: null, status: 'ready' });
    // Фото характеристики — у товара этой характеристики и у неё самой.
    expect(rows.find((r) => r.source_ref === varRef)).toMatchObject({ product_id: v.product_id, variant_id: v.id });
    const vp = await ctx.f.pool.query<{ primary_image_id: string | null }>(
      `SELECT primary_image_id::text FROM product_variants WHERE id = $1`,
      [v.id],
    );
    expect(vp.rows[0].primary_image_id).toBe(rows.find((r) => r.source_ref === varRef)?.id);
    // Остальные товары каталога фото не получили (ни одна строка не указывает на них).
    const others = await ctx.f.pool.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM products WHERE primary_image_id IS NOT NULL AND id <> ALL($1::uuid[])`,
      [[a, v.product_id]],
    );
    expect(others.rows[0].n).toBe('0');
    const nf = (await syncErrors(ctx)).filter((e) => e.error_code === 'NOT_FOUND_LOCAL');
    expect(nf).toHaveLength(2);
    expect(nf.map((e) => e.onec_ref)).toContain(unknownOwner);
    expect(nf.every((e) => e.entity === 'images')).toBe(true);

    // Файл «переехал» к неизвестному владельцу → снимается с прежнего товара (не остаётся на чужом).
    await ctx.repo.register(ctx.f.pool, [entry(own, unknownOwner, ver(img))]);
    await ctx.repo.refreshPrimary(ctx.f.pool, [a]);
    const after = await rowsOf(ctx, 'source_ref = $1', [own]);
    expect(after[0].deleted).toBe(true);
    const pa = await ctx.f.pool.query<{ primary_image_id: string | null }>(
      `SELECT primary_image_id::text FROM products WHERE id = $1`,
      [a],
    );
    expect(pa.rows[0].primary_image_id).toBeNull();
  });

  // 12 T-SYNC-043 (повтор не скачивает)
  it('ETag без изменений → без повторного скачивания и обработки (If-None-Match → 304)', async () => {
    const ctx = await setup();
    const img = await syntheticJpeg(1000, 800, 8);
    const ref = randomUUID();
    ctx.gw.serve(ref, img);
    await ctx.repo.register(ctx.f.pool, [entry(ref, ctx.anchor('F4252'), ver(img, '2026-10-01T10:00:00Z'))]);
    const first = await ctx.svc().run();
    expect(first.counts.processed).toBe(1);
    const sha = sha256(img);
    const mtime = statSync(ctx.store.fileOf(sha, 'full')).mtimeMs;
    expect(ctx.gw.calls).toEqual([{ ref }]);

    // Тот же список, та же версия → очередь пуста, к 1С не обращаемся.
    const same = await ctx.repo.register(ctx.f.pool, [
      entry(ref, ctx.anchor('F4252'), ver(img, '2026-10-01T10:00:00Z')),
    ]);
    expect(same.unchanged).toBe(1);
    const second = await ctx.svc().run();
    expect(second.counts).toMatchObject({ downloaded: 0, processed: 0, notModified: 0 });
    expect(ctx.gw.calls).toHaveLength(1);

    // Новая версия файла в 1С (дата модификации), содержимое то же → If-None-Match "<sha>" → 304, без обработки.
    await ctx.repo.register(ctx.f.pool, [entry(ref, ctx.anchor('F4252'), ver(img, '2026-10-02T09:00:00Z'))]);
    const third = await ctx.svc().run();
    expect(ctx.gw.calls[1]).toEqual({ ref, ifNoneMatch: `"${sha}"` });
    expect(third.counts).toMatchObject({ notModified: 1, downloaded: 0, processed: 0, ready: 1 });
    expect(statSync(ctx.store.fileOf(sha, 'full')).mtimeMs).toBe(mtime);
    expect((await rowsOf(ctx))[0].status).toBe('ready');

    // Содержимое изменилось → скачано и обработано заново, новый sha256.
    const img2 = await syntheticJpeg(1000, 800, 9);
    ctx.gw.serve(ref, img2);
    await ctx.repo.register(ctx.f.pool, [entry(ref, ctx.anchor('F4252'), ver(img2, '2026-10-03T09:00:00Z'))]);
    const fourth = await ctx.svc().run();
    expect(fourth.counts).toMatchObject({ downloaded: 1, processed: 1 });
    expect((await rowsOf(ctx))[0].sha).toBe(sha256(img2));
  });

  // 12 T-CAT-008, T-SYNC-045 (нет фото → заглушка)
  // 12: T-SYNC-F11 (ошибка скачивания фото: 404 → заглушка + sync_errors)
  it('404 в 1С → missing_source (заглушка) и предупреждение в sync_errors', async () => {
    const ctx = await setup();
    const ref = randomUUID();
    await ctx.repo.register(ctx.f.pool, [entry(ref, ctx.anchor('F4252'))]);
    const res = await ctx.svc().run();
    expect(res.counts.missing).toBe(1);
    expect((await rowsOf(ctx))[0]).toMatchObject({ status: 'missing_source', storage_key: null });
    const errs = await syncErrors(ctx);
    expect(errs).toEqual([
      expect.objectContaining({ entity: 'images', error_code: 'IMAGE_DOWNLOAD', severity: 'warning', onec_ref: ref }),
    ]);
  });

  // 12: T-SYNC-F11 (sha256/размер ≠ → повтор с backoff, после попыток — sync_errors)
  it('ETag ≠ sha256 или размер ≠ Размер 1С → HASH_MISMATCH, повтор с backoff, после попыток — sync_errors', async () => {
    const ctx = await setup();
    const img = await syntheticJpeg(500, 500, 10);
    const [wrongEtag, wrongSize] = [randomUUID(), randomUUID()];
    ctx.gw.serve(wrongEtag, img, { etag: `"${'0'.repeat(64)}"` });
    ctx.gw.serve(wrongSize, img);
    await ctx.repo.register(ctx.f.pool, [
      entry(wrongEtag, ctx.anchor('F4252'), ver(img)),
      entry(wrongSize, ctx.anchor('F3241'), `2026-10-01T10:00:00Z|${img.byteLength + 10}`),
    ]);
    const now = new Date('2026-10-22T02:30:00Z');
    const first = await ctx.svc({ maxAttempts: 2, now: () => now }).run();
    expect(first.counts.failed).toBe(2);
    expect(first.counts.errors).toBe(0);
    expect(first.status).toBe('partial');
    for (const r of await rowsOf(ctx)) {
      expect(r.status).toBe('failed');
      expect(r.attempts).toBe(1);
      expect(r.next_attempt_at?.getTime()).toBe(now.getTime() + 600_000);
    }
    expect(storedDirs(ctx.media)).toEqual([]);
    const later = new Date(now.getTime() + 3_600_000);
    const second = await ctx.svc({ maxAttempts: 2, now: () => later }).run();
    expect(second.counts.failed).toBe(2);
    const errs = await syncErrors(ctx);
    expect(errs.map((e) => e.error_code)).toEqual(['HASH_MISMATCH', 'HASH_MISMATCH']);
    for (const r of await rowsOf(ctx)) expect(r.next_attempt_at).toBeNull();
  });

  it('главное фото — наименьший sort_order среди готовых; products.primary_image_id', async () => {
    const ctx = await setup();
    const [i0, i1] = [await syntheticJpeg(400, 400, 11), await syntheticJpeg(400, 400, 12)];
    const [r0, r1] = [randomUUID(), randomUUID()];
    ctx.gw.serve(r0, i0);
    ctx.gw.serve(r1, i1);
    await ctx.repo.register(ctx.f.pool, [
      entry(r1, ctx.anchor('F4252'), ver(i1), 1),
      entry(r0, ctx.anchor('F4252'), ver(i0), 0),
    ]);
    await ctx.svc().run();
    const rows = await rowsOf(ctx);
    const primary = rows.filter((r) => r.is_primary);
    expect(primary.map((r) => r.source_ref)).toEqual([r0]);
    const p = await ctx.f.pool.query<{ primary_image_id: string }>(
      `SELECT primary_image_id::text FROM products WHERE id = $1`,
      [await ctx.productId('F4252')],
    );
    expect(p.rows[0].primary_image_id).toBe(primary[0].id);
  });
});

describe('RM-E-003 источники списка файлов', () => {
  it('/changes: Catalog_НоменклатураПрисоединенныеФайлы регистрируется в транзакции сообщения; ObjectDeletion снимает фото', async () => {
    const ctx = await setup();
    const fileRef = randomUUID();
    const pdfRef = randomUUID();
    const orphanRef = randomUUID();
    let n = 0;
    let pageItems: Record<string, unknown>[] = [];
    const gw = {
      mode: 'extension',
      getChanges: (q: { since: number }) =>
        Promise.resolve({
          status: 200,
          body: {
            messageNumber: q.since + 1,
            hasMore: false,
            cursor: null,
            generatedAt: '2026-10-22T02:00:00+06:00',
            items: pageItems,
          } as unknown as OnecChangesPage,
        }),
      ackChanges: (m: number) => {
        n = m;
        return Promise.resolve({ status: 200, body: { messageNumber: m } });
      },
    } as unknown as OnecGateway;
    const svc = new OnecChangesService(ctx.f.pool, gw, new CatalogApplier(), createRunTracker(ctx.f.pool), silent, {
      reconcileWithHealth: false,
      handlers: [new ProductImageFilesHandler()],
    });
    const file = (ref: string, owner: string, ext = 'jpg') => ({
      type: 'Catalog_НоменклатураПрисоединенныеФайлы',
      ref,
      dataVersion: 'AAAAAQAAAAA=',
      deletionMark: false,
      ownerRef: owner,
      size: 1234,
      extension: ext,
      modifiedAt: '2026-10-21T18:00:00Z',
    });
    pageItems = [
      file(fileRef, ctx.anchor('F4252')),
      file(pdfRef, ctx.anchor('F4252'), 'pdf'),
      file(orphanRef, randomUUID()),
    ];
    const r1 = await svc.pullOnce();
    expect(r1.status).toBe('applied');
    expect(r1.unhandled).toBe(0);
    expect(n).toBe(1);
    const rows = await rowsOf(ctx);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ source_ref: fileRef, status: 'pending', product_id: await ctx.productId('F4252') });
    const v = await ctx.f.pool.query<{ source_version: string }>(`SELECT source_version FROM product_images`);
    expect(v.rows[0].source_version).toBe('2026-10-21T18:00:00Z|1234');
    expect((await syncErrors(ctx)).filter((e) => e.error_code === 'NOT_FOUND_LOCAL')).toHaveLength(1);

    pageItems = [{ type: 'ObjectDeletion', objectType: 'Catalog_НоменклатураПрисоединенныеФайлы', ref: fileRef }];
    const r2 = await svc.pullOnce();
    expect(r2.status).toBe('applied');
    expect((await rowsOf(ctx))[0].deleted).toBe(true);
  });

  it('полный список OData: регистрация, сверка отсутствующих → deleted_at', async () => {
    const ctx = await setup();
    const img = await syntheticJpeg(300, 300, 13);
    const [a, b] = [randomUUID(), randomUUID()];
    ctx.gw.serve(a, img);
    ctx.gw.serve(b, img);
    const row = (ref: string, owner: string) => ({
      Ref_Key: ref,
      DataVersion: 'AAAA',
      DeletionMark: false,
      ВладелецФайла_Key: owner,
      Размер: img.byteLength,
      Расширение: 'jpg',
      ДатаМодификацииУниверсальная: '2026-10-21T10:00:00',
    });
    let pages = [[row(a, ctx.anchor('F4252')), row(b, ctx.anchor('VTP-20'))]];
    const client = {
      pages: async function* () {
        await Promise.resolve();
        for (const [i, rows] of pages.entries()) yield { skip: i * 1000, rows };
      },
    };
    const list = new ODataImageListSource(client);
    const r1 = await ctx.svc().run({ listSource: list });
    expect(r1.counts).toMatchObject({ listed: 2, registered: 2, ready: 2, deduplicated: 1, processed: 1 });
    pages = [[row(a, ctx.anchor('F4252'))]];
    const r2 = await ctx.svc().run({ listSource: list });
    expect(r2.counts.markedDeleted).toBe(1);
    expect(r2.counts.downloaded).toBe(0);
    const del = await rowsOf(ctx, 'source_ref = $1', [b]);
    expect(del[0].deleted).toBe(true);
    const p = await ctx.f.pool.query<{ primary_image_id: string | null }>(
      `SELECT primary_image_id::text FROM products WHERE id = $1`,
      [await ctx.productId('VTP-20')],
    );
    expect(p.rows[0].primary_image_id).toBeNull();
  });
});

describe('RM-E-003 разовый импорт каталога файлов (CommerceML / тома)', () => {
  // 12 T-SYNC-044
  it('CommerceML: привязка по Ид = onec_ref, один файл — одна копия, битый файл и чужой Ид → sync_errors, повтор без обработки', async () => {
    const ctx = await setup();
    const exp = tempMediaDir('cml');
    cleanups.push(exp.cleanup);
    const dir = path.join(exp.dir, 'webdata');
    mkdirSync(path.join(dir, 'import_files', 'ab'), { recursive: true });
    const shared = await syntheticJpeg(1200, 900, 14);
    const second = await syntheticPng(500, 700, 15);
    writeFileSync(path.join(dir, 'import_files', 'ab', 'shared.jpg'), shared);
    writeFileSync(path.join(dir, 'import_files', 'ab', 'second.png'), second);
    writeFileSync(path.join(dir, 'import_files', 'ab', 'broken.jpg'), garbageBytes(2048, 3));
    const unknown = randomUUID();
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<КоммерческаяИнформация ВерсияСхемы="2.05">
 <Каталог><Товары>
  <Товар><Ид>${ctx.anchor('F4252')}</Ид><Наименование>Смеситель &amp; кухня</Наименование>
   <Картинка>import_files/ab/shared.jpg</Картинка><Картинка>import_files/ab/second.png</Картинка>
   <ЗначенияСвойств><ЗначенияСвойства><Ид>${randomUUID()}</Ид><Значение>x</Значение></ЗначенияСвойства></ЗначенияСвойств>
  </Товар>
  <Товар><Ид>${ctx.anchor('VTP-20')}</Ид><Картинка>import_files/ab/shared.jpg</Картинка></Товар>
  <Товар><Ид>${ctx.anchor('SB-1WH')}</Ид><Картинка>import_files/ab/broken.jpg</Картинка></Товар>
  <Товар><Ид>${unknown}</Ид><Картинка>import_files/ab/shared.jpg</Картинка></Товар>
  <Товар><Ид>${ctx.anchor('F3241')}</Ид><Картинка>../../evil.jpg</Картинка></Товар>
 </Товары></Каталог>
</КоммерческаяИнформация>`;
    writeFileSync(path.join(dir, 'import0_1.xml'), `\uFEFF${xml}`);

    const importer = new ImageDirectoryImporter(ctx.f.pool, ctx.store, createRunTracker(ctx.f.pool), silent);
    const r = await importer.run({ dir: exp.dir });
    expect(r.layout).toBe('commerceml');
    expect(r.status).toBe('partial');
    expect(r.counts).toMatchObject({ files: 6, ready: 3, processed: 2, deduplicated: 1, ownerNotFound: 1, failed: 2 });

    const rows = await rowsOf(ctx, 'deleted_at IS NULL');
    expect(rows).toHaveLength(3);
    const f4252 = await ctx.productId('F4252');
    const vtp = await ctx.productId('VTP-20');
    expect(rows.filter((x) => x.product_id === f4252)).toHaveLength(2);
    expect(rows.filter((x) => x.product_id === vtp)).toHaveLength(1);
    expect(rows.every((x) => x.status === 'ready' && x.source_ref.startsWith('import:'))).toBe(true);
    expect(storedDirs(ctx.media).sort()).toEqual([sha256(shared), sha256(second)].sort());
    // Главное фото F4252 — первая Картинка.
    expect(rows.find((x) => x.is_primary && x.product_id === f4252)?.sha).toBe(sha256(shared));

    const errs = await syncErrors(ctx);
    expect(errs.map((e) => e.error_code).sort()).toEqual(['IMAGE_DOWNLOAD', 'NOT_FOUND_LOCAL', 'VALIDATION']);
    expect(errs.find((e) => e.error_code === 'NOT_FOUND_LOCAL')?.onec_ref).toBe(unknown);
    expect(errs.find((e) => e.error_code === 'IMAGE_DOWNLOAD')?.onec_ref).toBe(ctx.anchor('SB-1WH'));

    // Повторный импорт тех же файлов — без обработки и без новых строк.
    const again = await importer.run({ dir: exp.dir });
    expect(again.counts).toMatchObject({ unchanged: 3, processed: 0, deduplicated: 0 });
    expect(await rowsOf(ctx, 'deleted_at IS NULL')).toHaveLength(3);
  });

  it('тома: файлы <onec_ref>[_N].ext и <onec_ref>/<файл>', async () => {
    const ctx = await setup();
    const exp = tempMediaDir('vol');
    cleanups.push(exp.cleanup);
    const a = ctx.anchor('G1017-8');
    const b = ctx.anchor('SB-1WH');
    writeFileSync(path.join(exp.dir, `${a}.jpg`), await syntheticJpeg(300, 300, 16));
    writeFileSync(path.join(exp.dir, `${a}_2.jpg`), await syntheticJpeg(300, 300, 17));
    mkdirSync(path.join(exp.dir, b));
    writeFileSync(path.join(exp.dir, b, 'photo.png'), await syntheticPng(200, 200, 18));
    writeFileSync(path.join(exp.dir, 'readme.jpg'), await syntheticJpeg(10, 10, 19));
    const r = await new ImageDirectoryImporter(ctx.f.pool, ctx.store, createRunTracker(ctx.f.pool), silent).run({
      dir: exp.dir,
    });
    expect(r.layout).toBe('by-name');
    expect(r.counts).toMatchObject({ files: 3, ready: 3, processed: 3 });
    const rows = await rowsOf(ctx);
    const [pa, pb] = [await ctx.productId('G1017-8'), await ctx.productId('SB-1WH')];
    expect(rows.filter((x) => x.product_id === pa)).toHaveLength(2);
    expect(rows.filter((x) => x.product_id === pb)).toHaveLength(1);
    expect((await syncErrors(ctx)).map((e) => e.error_code)).toEqual(['VALIDATION']);
  });

  it('разбор CommerceML и защита путей', () => {
    const p = randomUUID();
    const v = randomUUID();
    const refs = parseCommerceMlImages(
      `<Товар><Ид>${p}#${v}</Ид><Картинка>import_files\\a&amp;b.jpg</Картинка></Товар><Товар><Ид>${p}</Ид></Товар>`,
      'webdata',
    );
    expect(refs).toEqual([{ ownerRef: v, relPath: 'webdata/import_files/a&b.jpg', sortOrder: 0 }]);
    const root = path.resolve('D:/x/root');
    expect(safeJoin(root, '../evil.jpg')).toBeNull();
    expect(safeJoin(root, 'C:/Windows/win.ini')).toBeNull();
    expect(safeJoin(root, '/etc/passwd')).toBeNull();
    expect(safeJoin(root, 'a/../../b.jpg')).toBeNull();
    expect(safeJoin(root, 'a/b.jpg')).toBe(path.join(root, 'a', 'b.jpg'));
  });
});
