import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import pino from 'pino';
import { imagesGcJob } from '../../src/jobs/sync/sync-jobs.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import {
  GatewayImageSource,
  ImagesGcService,
  ImageStore,
  ImageSyncService,
  ProductImageRepository,
} from '../../src/sync/images/index.js';
import { queueSpecs } from '../../src/sync/scheduler/queue-specs.js';
import { IMAGES_GC_QUEUE } from '../../src/sync/scheduler/sync-queues.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { sha256, syntheticJpeg, TestImageGateway, tempMediaDir } from './support/image-fixtures.js';

/**
 * EQ-IMG-10 — job `images.gc` (07 §5.23, 13 RM-E-003): удаление осиротевших файлов фото. Двухфазно (пометка →
 * удаление в следующем цикле), безопасно к гонке с загрузкой. **Тестовые данные** (синтетика sharp, тестовый шлюз).
 */
const silent = pino({ level: 'silent' });
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
let server: EmbeddedPg;
let f: CatalogFixture;
let media: { dir: string; cleanup: () => void };
let store: ImageStore;

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
  f = await startCatalogFixture({ pg: server, database: 'img_gc', skuCount: 30, includeFixtures: false });
  media = tempMediaDir('gc');
  store = new ImageStore(media.dir);
});

afterAll(async () => {
  await f?.stop();
  media?.cleanup();
  await server?.stop();
});

function fakeSha(): string {
  return sha256(Buffer.from(randomUUID()));
}

/** Каталог хранилища «как после загрузки» с заданным возрастом файлов. */
function plantDir(sha: string, ageMs: number): void {
  const dir = path.join(store.root, sha);
  mkdirSync(dir, { recursive: true });
  const t = new Date(Date.now() - ageMs);
  for (const s of ['thumb', 'card', 'full']) {
    const p = path.join(dir, `${s}.webp`);
    writeFileSync(p, Buffer.from(`webp-${s}-${sha}`));
    utimesSync(p, t, t);
  }
}

function ageMarker(sha: string, ageMs: number): void {
  const t = new Date(Date.now() - ageMs);
  utimesSync(store.markerOf(sha), t, t);
}

const marked = (sha: string) => existsSync(store.markerOf(sha));
const present = (sha: string) => existsSync(path.join(store.root, sha));

describe('images.gc — очистка осиротевших файлов фото (EQ-IMG-10)', () => {
  it('пометка → удаление в следующем цикле; живые, недавно снятые и свежие файлы не трогаются; гонка с загрузкой', async () => {
    const pool = f.pool;
    const repo = new ProductImageRepository();
    const gw = new TestImageGateway();
    const anchors = ['F4252', 'F3241', 'G1017-8'].map((s) => f.refs.anchors[s]);
    const imgs = await Promise.all([1, 2, 3].map((seed) => syntheticJpeg(800, 600, seed)));
    const refs = imgs.map(() => randomUUID());
    imgs.forEach((img, i) => gw.serve(refs[i], img));
    await repo.register(
      pool,
      imgs.map((img, i) => ({
        sourceRef: refs[i],
        ownerRef: anchors[i],
        sourceVersion: `2026-10-01T10:00:00Z|${img.byteLength}`,
        sortOrder: 0,
      })),
    );
    const sync = new ImageSyncService(pool, new GatewayImageSource(gw), store, createRunTracker(pool), silent, {});
    expect((await sync.run({ trigger: 'manual' })).counts.ready).toBe(3);
    const [A, B, C] = imgs.map(sha256); // A — живое; B — снято 40 дней назад; C — снято 5 дней назад
    await pool.query(
      `UPDATE product_images SET deleted_at = now() - make_interval(days => $2), is_primary = false
        WHERE checksum_sha256 = decode($1, 'hex')`,
      [B, 40],
    );
    await pool.query(
      `UPDATE product_images SET deleted_at = now() - make_interval(days => $2), is_primary = false
        WHERE checksum_sha256 = decode($1, 'hex')`,
      [C, 5],
    );
    // Файлы загружены давно (до снятия строк) — как в проде.
    for (const s of [A, B, C]) {
      const t = new Date(Date.now() - 41 * DAY);
      for (const n of readdirSync(path.join(store.root, s))) utimesSync(path.join(store.root, s, n), t, t);
    }
    const D = fakeSha(); // строк нет, файлы старые → позже появится живая строка (гонка через БД)
    const F = fakeSha(); // строк нет, файлы старые → удаляется
    const E = fakeSha(); // строк нет, файлы свежие (загрузка в процессе: файл записан, строки ещё нет)
    const G = fakeSha(); // строк нет, файлы старые → после пометки перезаписан загрузкой (гонка через файлы)
    plantDir(D, 3 * DAY);
    plantDir(F, 3 * DAY);
    plantDir(G, 3 * DAY);
    plantDir(E, 10 * 60_000);

    const gc = new ImagesGcService(pool, store, silent);
    // Цикл 1: только пометка.
    const r1 = await gc.run();
    expect(r1).toMatchObject({ scanned: 7, marked: 4, deleted: 0, unmarked: 0, kept: 3, errors: 0 });
    for (const s of [B, D, F, G]) expect(marked(s), s).toBe(true);
    for (const s of [A, C, E]) expect(marked(s), s).toBe(false);
    // Помеченный каталог для загрузки «отсутствует» — дедупликация на него не ссылается.
    expect(await store.has(B)).toBe(false);
    expect(await store.has(A)).toBe(true);

    // Цикл 2 сразу: пометки свежие (< 1 ч) — ничего не удаляется.
    const r2 = await gc.run();
    expect(r2).toMatchObject({ deleted: 0, marked: 0 });
    for (const s of [A, B, C, D, E, F, G]) expect(present(s), s).toBe(true);

    // Прошёл час. D снова используется (новая строка), G перезаписан загрузкой (write снимает пометку).
    for (const s of [B, D, F, G]) ageMarker(s, 2 * HOUR);
    const extra = randomUUID();
    await repo.register(pool, [
      { sourceRef: extra, ownerRef: anchors[0], sourceVersion: '2026-10-02T10:00:00Z|1', sortOrder: 5 },
    ]);
    await pool.query(
      `UPDATE product_images SET status = 'ready', checksum_sha256 = decode($2, 'hex'), storage_key = 'images/' || $2
        WHERE source_ref = $1`,
      [extra, D],
    );
    await store.write(G, [{ name: 'thumb', data: Buffer.from('fresh'), w: 1, h: 1 }]);
    expect(marked(G)).toBe(false);

    // Цикл 3: удалены B и F; D — пометка снята; G — файлы свежие → без пометки до истечения порога сироты.
    const r3 = await gc.run();
    expect(r3).toMatchObject({ scanned: 7, deleted: 2, unmarked: 1, marked: 0, errors: 0 });
    expect(present(B)).toBe(false);
    expect(present(F)).toBe(false);
    for (const s of [A, C, D, E, G]) expect(present(s), s).toBe(true);
    expect(marked(D)).toBe(false);
    expect(marked(G)).toBe(false);
    expect(readdirSync(path.join(store.root, A)).sort()).toEqual(['card.webp', 'full.webp', 'thumb.webp']);
    expect(existsSync(gc.trashDir) ? readdirSync(gc.trashDir) : []).toEqual([]);
    // Строки product_images не меняются (удаляются только файлы).
    const n = await pool.query<{ n: string }>(`SELECT count(*)::text AS n FROM product_images`);
    expect(n.rows[0].n).toBe('4');
  });

  it('нет каталога хранилища — пустой результат; job pg-boss и очередь images.gc', async () => {
    const empty = new ImagesGcService(f.pool, new ImageStore(path.join(media.dir, 'nope')), silent);
    expect(await imagesGcJob(empty)({ id: 'job-1', data: {} })).toEqual({
      scanned: 0,
      marked: 0,
      unmarked: 0,
      deleted: 0,
      kept: 0,
      errors: 0,
    });
    const spec = queueSpecs({
      sync: { retryLimit: 2, retryDelay: 60, retryBackoff: false, retryDelayMax: 120, expireInSeconds: 1800 },
    }).find((s) => s.name === IMAGES_GC_QUEUE);
    expect(spec?.options).toMatchObject({ policy: 'exclusive', retryLimit: 0 });
  });
});
