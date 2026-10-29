import pino from 'pino';
import type { OnecChangesPage, OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * 05 ONEC-017 п. 2 / AC-ONEC-017, SYNC-020, SYNC-033 (д), F9; 12 T-SYNC-005 (б), T-SYNC-F09 — правило привязки штрихкода
 * (E-KI-03 / R2-N-02): одно значение `Штрихкод` с двумя привязками в прогоне → сохраняется текущая привязка
 * `barcodes`, если она среди пришедших, иначе — наименьший ключ (`Номенклатура_Key`, `Характеристика_Key`,
 * `Упаковка_Key`); одна запись `BARCODE_CONFLICT` со ссылками обеих привязок; порядок позиций и страниц прогона
 * на результат не влияет. Новый прогон с одной привязкой — перепривязка (п. 1). Тестовые данные (синтетика).
 */
const silent = pino({ level: 'silent' });
const BARCODE = 'InformationRegister_ШтрихкодыНоменклатуры';
let server: EmbeddedPg;
let f: CatalogFixture;
let msgNo = 100;

interface Bind {
  productRef: string;
  variantRef?: string | null;
}

function item(value: string, b: Bind): Record<string, unknown> {
  return { type: BARCODE, ref: value, barcode: value, productRef: b.productRef, variantRef: b.variantRef ?? null };
}

/** Одно сообщение `/changes` (= один прогон `barcodes`), разбитое на страницы. */
async function pull(pages: Record<string, unknown>[][]): Promise<void> {
  const n = ++msgNo;
  const stub = {
    mode: 'fixtures',
    getHealth: () => Promise.reject(new Error('нет health')),
    getChanges: (q: { cursor?: string }): Promise<{ status: number; body: OnecChangesPage }> => {
      const i = q.cursor ? Number(q.cursor) : 0;
      return Promise.resolve({
        status: 200,
        body: {
          messageNumber: n,
          hasMore: i < pages.length - 1,
          cursor: i < pages.length - 1 ? String(i + 1) : null,
          generatedAt: '2026-10-22T10:00:00+06:00',
          items: pages[i] as never,
        },
      });
    },
    ackChanges: (m: number) => Promise.resolve({ status: 200, body: { messageNumber: m } }),
  } as unknown as OnecGateway;
  const svc = new OnecChangesService(f.pool, stub, new CatalogApplier(), createRunTracker(f.pool), silent, {
    pageSize: 1000,
    reconcileWithHealth: false,
  });
  const r = await svc.pullOnce();
  expect(r.status).toBe('applied');
}

async function bound(value: string): Promise<{ product: string; variant: string | null; isDefault: boolean }> {
  const r = await f.pool.query<{ product: string; variant: string | null; is_default: boolean }>(
    `SELECT p.onec_ref::text AS product, v.onec_ref::text AS variant, v.is_default
       FROM barcodes b JOIN products p ON p.id = b.product_id JOIN product_variants v ON v.id = b.variant_id
      WHERE b.value = $1 AND NOT b.deletion_mark`,
    [value],
  );
  expect(r.rows, `штрихкод ${value}`).toHaveLength(1);
  return { product: r.rows[0].product, variant: r.rows[0].variant, isDefault: r.rows[0].is_default };
}

async function conflicts(value: string): Promise<{ payload: Record<string, unknown>; severity: string }[]> {
  const r = await f.pool.query<{ payload: Record<string, unknown>; severity: string }>(
    `SELECT payload, severity FROM sync_errors WHERE error_code = 'BARCODE_CONFLICT' AND onec_code = $1`,
    [value],
  );
  return r.rows;
}

const sortRefs = (a: string, b: string): [string, string] => (a < b ? [a, b] : [b, a]);

let lo: string; // товар с меньшим Ref_Key
let hi: string;
let owner: string; // товар с двумя характеристиками
let vLo: string;
let vHi: string;

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
  f = await startCatalogFixture({ pg: server, database: 'barcode_conflict', skuCount: 60 });
  const live = f.catalog.productItems().filter((p) => !p.deletionMark);
  [lo, hi] = sortRefs(live[3].ref, live[7].ref);
  const byOwner = new Map<string, string[]>();
  for (const v of f.catalog.variants().filter((x) => !x.deletionMark)) {
    const list = byOwner.get(v.ownerRef) ?? [];
    list.push(v.ref);
    byOwner.set(v.ownerRef, list);
  }
  const pair = [...byOwner].find(([o, vs]) => vs.length >= 2 && live.some((p) => p.ref === o));
  if (!pair) throw new Error('в синтетике нет товара с двумя характеристиками');
  owner = pair[0];
  [vLo, vHi] = sortRefs(pair[1][0], pair[1][1]);
});

afterAll(async () => {
  await f?.stop();
  await server?.stop();
});

describe('Штрихкод с двумя привязками — правило 05 ONEC-017 п. 2 (E-KI-03)', () => {
  // 12 T-SYNC-F09 (BARCODE_CONFLICT в sync_errors; привязка — по ONEC-017; сканер находит один товар — `bound`)
  it('два товара, один пакет, привязки нет: наименьший Ref_Key при любом порядке; одна запись BARCODE_CONFLICT со ссылками A и B', async () => {
    await pull([[item('2990000000101', { productRef: hi }), item('2990000000101', { productRef: lo })]]);
    await pull([[item('2990000000102', { productRef: lo }), item('2990000000102', { productRef: hi })]]);
    for (const v of ['2990000000101', '2990000000102']) {
      expect((await bound(v)).product).toBe(lo);
      const c = await conflicts(v);
      expect(c).toHaveLength(1);
      expect(c[0].severity).toBe('warning');
      expect(c[0].payload).toMatchObject({
        rule: 'min_key',
        chosen: { productRef: lo },
        bindings: [
          { productRef: lo, variantRef: null, packagingRef: null },
          { productRef: hi, variantRef: null, packagingRef: null },
        ],
      });
    }
  });

  it('два товара, один пакет, текущая привязка к товару с большим ключом — сохраняется при любом порядке', async () => {
    for (const v of ['2990000000201', '2990000000202']) await pull([[item(v, { productRef: hi })]]);
    expect(await conflicts('2990000000201')).toHaveLength(0);
    await pull([[item('2990000000201', { productRef: lo }), item('2990000000201', { productRef: hi })]]);
    await pull([[item('2990000000202', { productRef: hi }), item('2990000000202', { productRef: lo })]]);
    for (const v of ['2990000000201', '2990000000202']) {
      expect((await bound(v)).product).toBe(hi);
      const c = await conflicts(v);
      expect(c).toHaveLength(1);
      expect(c[0].payload).toMatchObject({ rule: 'current', chosen: { productRef: hi } });
    }
  });

  it('два товара в разных пакетах (страницах) одного прогона: порядок страниц не влияет; одна запись конфликта', async () => {
    // Привязки нет → наименьший ключ.
    await pull([[item('2990000000301', { productRef: hi })], [item('2990000000301', { productRef: lo })]]);
    await pull([[item('2990000000302', { productRef: lo })], [item('2990000000302', { productRef: hi })]]);
    // Текущая привязка к hi → сохраняется, хотя первая страница перепривязала бы на lo.
    for (const v of ['2990000000303', '2990000000304']) await pull([[item(v, { productRef: hi })]]);
    await pull([[item('2990000000303', { productRef: lo })], [item('2990000000303', { productRef: hi })]]);
    await pull([[item('2990000000304', { productRef: hi })], [item('2990000000304', { productRef: lo })]]);
    expect((await bound('2990000000301')).product).toBe(lo);
    expect((await bound('2990000000302')).product).toBe(lo);
    expect((await bound('2990000000303')).product).toBe(hi);
    expect((await bound('2990000000304')).product).toBe(hi);
    for (const v of ['2990000000301', '2990000000302', '2990000000303', '2990000000304'])
      expect(await conflicts(v), v).toHaveLength(1);
  });

  it('два варианта одного товара: в одном пакете и в разных пакетах — наименьший Характеристика_Key или текущая', async () => {
    const a = { productRef: owner, variantRef: vLo };
    const b = { productRef: owner, variantRef: vHi };
    await pull([[item('2990000000401', b), item('2990000000401', a)]]);
    await pull([[item('2990000000402', a)], [item('2990000000402', b)]]);
    await pull([[item('2990000000403', b)], [item('2990000000403', a)]]);
    for (const v of ['2990000000401', '2990000000402', '2990000000403']) {
      const r = await bound(v);
      expect(r).toEqual({ product: owner, variant: vLo, isDefault: false });
      const c = await conflicts(v);
      expect(c).toHaveLength(1);
      expect(c[0].payload).toMatchObject({
        rule: 'min_key',
        bindings: [
          { productRef: owner, variantRef: vLo },
          { productRef: owner, variantRef: vHi },
        ],
      });
    }
    // Текущая привязка — вариант с большим ключом.
    await pull([[item('2990000000404', b)]]);
    await pull([[item('2990000000404', a), item('2990000000404', b)]]);
    await pull([[item('2990000000405', b)]]);
    await pull([[item('2990000000405', a)], [item('2990000000405', b)]]);
    for (const v of ['2990000000404', '2990000000405']) {
      expect((await bound(v)).variant).toBe(vHi);
      expect((await conflicts(v))[0]?.payload).toMatchObject({ rule: 'current' });
    }
  });

  it('новый прогон с одной привязкой — перепривязка (п. 1), без конфликта; повтор той же привязки в пакете — не конфликт', async () => {
    await pull([[item('2990000000501', { productRef: lo })]]);
    await pull([[item('2990000000501', { productRef: hi })]]);
    expect((await bound('2990000000501')).product).toBe(hi);
    await pull([[item('2990000000502', { productRef: lo }), item('2990000000502', { productRef: lo })]]);
    expect((await bound('2990000000502')).product).toBe(lo);
    expect(await conflicts('2990000000501')).toHaveLength(0);
    expect(await conflicts('2990000000502')).toHaveLength(0);
  });

  it('привязка-победитель к товару, пришедшему позже в том же сообщении, применяется (отложенный проход)', async () => {
    const pool = f.pool;
    const unit = f.catalog.units[0].ref;
    const cat = f.catalog.categories[0].ref;
    const fresh = '00000000-0000-4000-8000-00000000b0c1'; // меньше любого синтетического Ref_Key
    await pull([
      [item('2990000000601', { productRef: hi }), item('2990000000601', { productRef: fresh })],
      [
        {
          type: 'Catalog_Номенклатура',
          ref: fresh,
          dataVersion: 'v1',
          deletionMark: false,
          isFolder: false,
          code: 'BC-NEW',
          description: 'Товар для штрихкода',
          sku: 'BC-NEW',
          parentRef: cat,
          baseUnitRef: unit,
        },
      ],
    ]);
    expect((await bound('2990000000601')).product).toBe(fresh);
    expect(await conflicts('2990000000601')).toHaveLength(1);
    const n = await pool.query<{ n: string }>(`SELECT count(*)::text AS n FROM barcodes WHERE value = '2990000000601'`);
    expect(n.rows[0].n).toBe('1');
  });
});
