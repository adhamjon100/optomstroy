import pino from 'pino';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import type { OnecChangesPage, OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { ProductImageFilesHandler } from '../../src/sync/images/image-files.handler.js';
import { ProductImageRepository } from '../../src/sync/images/product-image.repository.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * Главная картинка товара по `imageFileRef` и предложению `isMain`, бренд `brand` (разбор расхождений пп. 14, 15;
 * контракт `NomenclatureChange.imageFileRef|brand`, `ImageFileChange.isMain`; ТЗ для 1С 5.4). Тестовые данные.
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let f: CatalogFixture;

const U = '11111111-0000-4000-8000-000000000001';
const A = '22222222-0000-4000-8000-00000000000a';
const B = '22222222-0000-4000-8000-00000000000b';
const C = '22222222-0000-4000-8000-00000000000c';
const FA1 = '33333333-0000-4000-8000-0000000000a1';
const FA2 = '33333333-0000-4000-8000-0000000000a2';
const FB1 = '33333333-0000-4000-8000-0000000000b1';
const FB2 = '33333333-0000-4000-8000-0000000000b2';
const FC1 = '33333333-0000-4000-8000-0000000000c1';
const FC2 = '33333333-0000-4000-8000-0000000000c2';

const unit = {
  type: 'Catalog_КлассификаторЕдиницИзмерения',
  ref: U,
  dataVersion: 'u1',
  deletionMark: false,
  code: '796',
  description: 'шт',
};
function product(ref: string, extra: Record<string, unknown> = {}, version = 'p1'): Record<string, unknown> {
  return {
    type: 'Catalog_Номенклатура',
    ref,
    dataVersion: version,
    deletionMark: false,
    isFolder: false,
    code: ref.slice(-4),
    description: `Товар ${ref.slice(-1)}`,
    sku: `SKU-${ref.slice(-1)}`,
    baseUnitRef: U,
    ...extra,
  };
}
function file(ref: string, owner: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    type: 'Catalog_НоменклатураПрисоединенныеФайлы',
    ref,
    dataVersion: 'f1',
    deletionMark: false,
    ownerRef: owner,
    size: 100,
    extension: 'jpg',
    modifiedAt: '2026-10-21T10:00:00+06:00',
    ...extra,
  };
}

/** Шлюз с заданными сообщениями `/changes` (номер — since + 1), ack — фейк. */
function gateway(messages: Record<string, unknown>[][]): OnecGateway {
  const real = new FakeOnecGateway();
  let i = 0;
  return Object.assign(Object.create(real) as FakeOnecGateway, {
    getChanges: (q: { since: number }) => {
      const items = messages[Math.min(i, messages.length - 1)] ?? [];
      i += 1;
      const body: OnecChangesPage = {
        messageNumber: q.since + 1,
        hasMore: false,
        cursor: null,
        generatedAt: '2026-10-21T10:00:00+06:00',
        items: items as unknown as OnecChangesPage['items'],
      };
      return Promise.resolve({ status: 200, body });
    },
  });
}

function service(gw: OnecGateway): OnecChangesService {
  return new OnecChangesService(f.pool, gw, new CatalogApplier(), createRunTracker(f.pool), silent, {
    reconcileWithHealth: false,
    handlers: [new ProductImageFilesHandler()],
  });
}

async function primaryOf(ref: string): Promise<string | null> {
  const r = await f.pool.query<{ src: string | null }>(
    `SELECT pi.source_ref AS src FROM products p LEFT JOIN product_images pi ON pi.id = p.primary_image_id
      WHERE p.onec_ref = $1`,
    [ref],
  );
  return r.rows[0]?.src ?? null;
}

async function productIds(): Promise<string[]> {
  return (await f.pool.query<{ id: string }>(`SELECT id::text AS id FROM products`)).rows.map((r) => r.id);
}

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
  f = await startCatalogFixture({
    pg: server,
    database: 'main_image',
    skuCount: 0,
    includeFixtures: false,
    skipLoad: true,
  });
});

afterAll(async () => {
  await f?.stop();
  await server?.stop();
});

describe('главное фото: imageFileRef своего товара → isMain → порядок файлов (п. 14)', () => {
  it('imageFileRef и isMain выбирают главное фото; ссылка на файл другого товара не действует; смена imageFileRef — сразу; список без isMain признак не сбрасывает', async () => {
    const gw = gateway([
      [
        unit,
        product(A, { imageFileRef: FA2, brand: 'Grohe' }),
        product(B),
        product(C, { imageFileRef: FA1 }),
        file(FA1, A),
        file(FA2, A),
        file(FB1, B),
        file(FB2, B, { isMain: true }),
        file(FC1, C),
        file(FC2, C),
      ],
      [product(A, { imageFileRef: FA1, brand: 'Grohe' }, 'p2')],
    ]);
    expect((await service(gw).pullOnce()).status).toBe('applied');
    const main = await f.pool.query<{ src: string; main: boolean | null }>(
      `SELECT source_ref AS src, onec_is_main AS main FROM product_images ORDER BY source_ref`,
    );
    expect(main.rows.find((r) => r.src === FB2)?.main).toBe(true);
    expect(main.rows.find((r) => r.src === FB1)?.main).toBeNull();
    // Фото скачаны ночным прогоном (здесь — отметкой ready) → пересчёт главного фото.
    await f.pool.query(`UPDATE product_images SET status = 'ready'`);
    const repo = new ProductImageRepository();
    await repo.refreshPrimary(f.pool, await productIds());
    expect(await primaryOf(A)).toBe(FA2); // imageFileRef, хотя FA1 зарегистрирован раньше
    expect(await primaryOf(B)).toBe(FB2); // isMain
    const c = await primaryOf(C);
    expect([FC1, FC2]).toContain(c); // ссылка на файл товара A — не главная для C
    const ref = await f.pool.query<{ r: string | null }>(
      `SELECT onec_image_file_ref::text AS r FROM products WHERE onec_ref = $1`,
      [C],
    );
    expect(ref.rows[0]?.r).toBe(FA1);

    // Следующее сообщение: imageFileRef товара A → FA1; главное фото меняется в той же транзакции.
    expect((await service(gw).pullOnce()).status).toBe('applied');
    expect(await primaryOf(A)).toBe(FA1);

    // Полный список файлов без признака (OData) — isMain сохраняется.
    await repo.register(f.pool, [{ sourceRef: FB2, ownerRef: B, sourceVersion: 'другая версия', sortOrder: 0 }]);
    await f.pool.query(`UPDATE product_images SET status = 'ready'`);
    await repo.refreshPrimary(f.pool, await productIds());
    expect(await primaryOf(B)).toBe(FB2);
  });
});

describe('бренд товара (п. 15)', () => {
  it('brand сохраняется в products.brand; без поля — NULL, повтор без изменений не перезаписывает товар', async () => {
    const brands = await f.pool.query<{ ref: string; brand: string | null }>(
      `SELECT onec_ref::text AS ref, brand FROM products WHERE onec_ref = ANY($1::uuid[]) ORDER BY onec_ref`,
      [[A, B]],
    );
    expect(brands.rows).toEqual([
      { ref: A, brand: 'Grohe' },
      { ref: B, brand: null },
    ]);
    const before = await f.pool.query<{ u: string; h: string }>(
      `SELECT updated_at::text AS u, source_hash AS h FROM products WHERE onec_ref = $1`,
      [B],
    );
    expect((await service(gateway([[product(B, {}, 'p9')]])).pullOnce()).status).toBe('applied');
    const after = await f.pool.query<{ u: string; h: string }>(
      `SELECT updated_at::text AS u, source_hash AS h FROM products WHERE onec_ref = $1`,
      [B],
    );
    expect(after.rows[0]).toEqual(before.rows[0]);
  });
});
