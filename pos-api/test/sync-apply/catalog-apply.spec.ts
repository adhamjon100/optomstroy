import type pg from 'pg';
import pino from 'pino';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import type { OnecCatalogItem, OnecPriceRow, OnecStockRow } from '../../src/integrations/onec/onec-catalog.types.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecChangesPage, OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import type { ChangeItemHandler } from '../../src/sync/apply/apply.types.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '../../src/sync/apply/catalog-full-load.service.js';
import {
  type CatalogFullSource,
  type CatalogReadKind,
  SyntheticCatalogSource,
} from '../../src/sync/apply/catalog-source.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { loadSyntheticCatalog } from '../../src/sync/apply/synthetic-load.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];

async function fresh(opts: Parameters<typeof startCatalogFixture>[0] = {}): Promise<CatalogFixture> {
  const f = await startCatalogFixture({ pg: server, database: `apply_${++dbNo}`, skuCount: 120, ...opts });
  open.push(f);
  return f;
}

function changes(
  f: { pool: pg.Pool; gateway: OnecGateway },
  opts: { pageSize?: number; handlers?: ChangeItemHandler[]; slices?: boolean; health?: boolean } = {},
): OnecChangesService {
  const gw = f.gateway;
  return new OnecChangesService(f.pool, gw, new CatalogApplier(), createRunTracker(f.pool), silent, {
    pageSize: opts.pageSize ?? 1000,
    reconcileWithHealth: opts.health ?? true,
    ...(opts.handlers ? { handlers: opts.handlers } : {}),
    ...(opts.slices !== false && gw instanceof FakeOnecGateway && gw.catalog
      ? { slices: new SyntheticCatalogSource(gw) }
      : {}),
  });
}

/** Снимок таблицы: id → `updated_at|source_hash|deletion_mark`. */
async function snap(pool: pg.Pool, table: string, key = 'id'): Promise<Map<string, string>> {
  const extra = table === 'variant_attribute_values' ? `''` : `source_hash`;
  const del = ['prices', 'stock_balances', 'variant_attribute_values'].includes(table) ? `''` : 'deletion_mark::text';
  const r = await pool.query<{ k: string; v: string }>(
    `SELECT ${key}::text AS k, updated_at::text || '|' || ${extra} || '|' || ${del} AS v FROM ${table}`,
  );
  return new Map(r.rows.map((x) => [x.k, x.v]));
}

function changed(a: Map<string, string>, b: Map<string, string>): string[] {
  const out: string[] = [];
  for (const [k, v] of b) if (a.get(k) !== v) out.push(k);
  for (const k of a.keys()) if (!b.has(k)) out.push(k);
  return out;
}

async function one<T extends pg.QueryResultRow>(pool: pg.Pool, sql: string, params: unknown[] = []): Promise<T> {
  const r = await pool.query<T>(sql, params);
  if (!r.rows[0]) throw new Error(`нет строки: ${sql}`);
  return r.rows[0];
}

const REPLICAS = [
  'units',
  'warehouses',
  'price_lists',
  'categories',
  'products',
  'product_attributes',
  'product_variants',
  'packagings',
  'barcodes',
  'prices',
  'stock_balances',
];

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const f of open) await f.stop();
  await server?.stop();
});

describe('Конвейер применения 1С → реплики каталога (RM-E-001; на фикстурах и синтетике, не реальная интеграция)', () => {
  // 12 T-ONEC-019 (поля реплик), T-SYNC-001 (каталожная часть первичной загрузки)
  // 12: T-ORD-019 (резерв — по данным 1С: reserved/available из среза остатков)
  it('полная загрузка: все 12 таблиц, стандартный набор полей реплики, ровно один is_default у товара, цены/остатки фикстуры', async () => {
    const f = await fresh();
    for (const t of REPLICAS) {
      expect(Number((await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM ${t}`)).n), t).toBeGreaterThan(
        0,
      );
    }
    expect(
      Number((await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM variant_attribute_values`)).n),
    ).toBeGreaterThan(0);
    // Стандартный набор (ONEC-100): onec_ref + onec_data_version у объектов 1С, source_hash/synced_at — у всех.
    for (const t of ['units', 'warehouses', 'price_lists', 'categories', 'products', 'packagings']) {
      const bad = await one<{ n: string }>(
        f.pool,
        `SELECT count(*)::text AS n FROM ${t} WHERE onec_ref IS NULL OR onec_data_version IS NULL OR source_hash IS NULL OR synced_at IS NULL`,
      );
      expect(bad.n, t).toBe('0');
    }
    expect(
      (
        await one<{ n: string }>(
          f.pool,
          `SELECT count(*)::text AS n FROM product_variants WHERE NOT is_default AND (onec_ref IS NULL OR onec_data_version IS NULL)`,
        )
      ).n,
    ).toBe('0');
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products WHERE onec_code IS NULL`)).n,
    ).toBe('0');
    // DATA-116 / критерий 4 RM-E-001: у каждого товара ровно один служебный вариант; у товара без характеристик — только он.
    expect(
      (
        await one<{ n: string }>(
          f.pool,
          `SELECT count(*)::text AS n FROM products p WHERE (SELECT count(*) FROM product_variants v WHERE v.product_id = p.id AND v.is_default) <> 1`,
        )
      ).n,
    ).toBe('0');
    const noChars = await one<{ n: string; d: string }>(
      f.pool,
      `SELECT count(*)::text AS n, sum((SELECT count(*) FROM product_variants v WHERE v.product_id = p.id))::text AS d
         FROM products p WHERE NOT p.has_variants`,
    );
    expect(Number(noChars.n)).toBeGreaterThan(50);
    expect(noChars.d).toBe(noChars.n);
    // Товар фикстуры KX-1245 (05 §6.4): группа, характеристика, свойство, упаковка, штрихкод, цены и остатки карточки.
    const kx = await one<{
      id: string;
      name: string;
      cat: string;
      has_variants: boolean;
      unit: string;
      attrs: Record<string, unknown>;
    }>(
      f.pool,
      `SELECT p.id, p.name, c.name AS cat, p.has_variants, u.name AS unit, p.attributes AS attrs
         FROM products p JOIN categories c ON c.id = p.category_id JOIN units u ON u.id = p.base_unit_id WHERE p.sku = 'KX-1245'`,
    );
    expect(kx).toMatchObject({
      name: 'Смеситель для кухни однорычажный',
      cat: 'Смесители',
      has_variants: true,
      unit: 'шт',
    });
    expect(kx.attrs).toEqual({ tsvet: { name: 'Цвет', value: 'Хром', type: 'list' } });
    const variant = await one<{ id: string; name: string; attributes: Record<string, unknown> }>(
      f.pool,
      `SELECT id, name, attributes FROM product_variants WHERE onec_ref = 'a1b2c3d4-0000-4000-8000-000000000101'`,
    );
    expect(variant).toMatchObject({ name: 'Хром', attributes: { tsvet: 'Хром' } });
    expect(
      (
        await one<{ v: string }>(f.pool, `SELECT value_text AS v FROM variant_attribute_values WHERE variant_id = $1`, [
          variant.id,
        ])
      ).v,
    ).toBe('Хром');
    const prices = await f.pool.query<{ pl: string; pack: string | null; price: string }>(
      `SELECT pl.onec_ref::text AS pl, pk.name AS pack, pr.price::text AS price FROM prices pr
         JOIN price_lists pl ON pl.id = pr.price_list_id LEFT JOIN packagings pk ON pk.id = pr.packaging_id
        WHERE pr.variant_id = $1 ORDER BY pr.price`,
      [variant.id],
    );
    expect(prices.rows).toEqual([
      { pl: 'e5f6a7b8-0000-4000-8000-000000000002', pack: null, price: '2150.00' },
      { pl: 'e5f6a7b8-0000-4000-8000-000000000001', pack: null, price: '2350.00' },
      { pl: 'e5f6a7b8-0000-4000-8000-000000000002', pack: 'Коробка (6 шт)', price: '12600.00' },
    ]);
    const stock = await one<{ q: string; r: string; a: string }>(
      f.pool,
      `SELECT quantity::text AS q, reserved::text AS r, available::text AS a FROM stock_balances s JOIN warehouses w ON w.id = s.warehouse_id
        WHERE s.variant_id = $1 AND w.onec_ref = 'd4e5f6a7-0000-4000-8000-000000000001'`,
      [variant.id],
    );
    expect(stock).toEqual({ q: '16.000', r: '2.000', a: '14.000' });
    const bc = await one<{ type: string; variant: string }>(
      f.pool,
      `SELECT b.type::text AS type, v.onec_ref::text AS variant FROM barcodes b JOIN product_variants v ON v.id = b.variant_id WHERE b.value = '4600000000015'`,
    );
    // Фикстура 1.1.0: EAN-13 с верной контрольной цифрой (ТЗ для 1С §5.4) → тип EAN13.
    expect(bc).toEqual({ type: 'EAN13', variant: 'a1b2c3d4-0000-4000-8000-000000000101' });
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM barcodes WHERE type = 'EAN13'`)).n,
    ).not.toBe('0');
    // Дерево: путь и глубина, счётчики сайдбара = активные продаваемые товары поддерева (DATA-114).
    const root = await one<{ id: string; depth: number; cnt: number }>(
      f.pool,
      `SELECT id, depth, product_count_cache AS cnt FROM categories WHERE name = 'Смесители' AND parent_id IS NULL AND onec_ref::text NOT LIKE 'a1b2%'`,
    );
    expect(root.depth).toBe(0);
    const expected = await one<{ n: number }>(
      f.pool,
      `SELECT count(*)::int AS n FROM products p JOIN categories c ON c.id = p.category_id
        WHERE NOT p.deletion_mark AND c.path LIKE (SELECT path FROM categories WHERE id = $1) || '%'`,
      [root.id],
    );
    expect(root.cnt).toBe(expected.n);
    expect(
      (await one<{ t: string }>(f.pool, `SELECT category_path_text AS t FROM products WHERE sku = 'F4252'`)).t,
    ).toMatch(/^Смесители \/ /);
    // Прогоны full по каждой сущности, ошибок позиций нет.
    const runs = await f.pool.query<{ entity: string; status: string }>(
      `SELECT DISTINCT entity::text, status::text FROM sync_runs ORDER BY 1`,
    );
    expect(runs.rows.every((r) => r.status === 'success')).toBe(true);
    expect(
      (
        await one<{ n: string }>(
          f.pool,
          `SELECT count(*)::text AS n FROM sync_errors WHERE error_code <> 'DUPLICATE_SUSPECTED'`,
        )
      ).n,
    ).toBe('0');
    // Отчёт о дублях кода 1С (05 SYNC-004, 12 T-SYNC-009) — не ошибка позиции: фикстуры 1С и синтетика нумеруют
    // склады, виды цен, характеристики и единицы с одного кода, это настоящие дубли набора — warning по группе.
    const dups = await f.pool.query<{ severity: string; n: string }>(
      `SELECT severity, payload->>'count' AS n FROM sync_errors WHERE error_code = 'DUPLICATE_SUSPECTED'`,
    );
    expect(dups.rows.every((d) => d.severity === 'warning' && d.n === '2')).toBe(true);
    // Деньги без float: NUMERIC(14,2) равен строке среза.
    const anySlice = f.catalog
      .priceSlice()
      .find((p) => p.variantRef === null && p.packagingRef === null && p.productRef === f.refs.anchors.F4252)!;
    const db = await one<{ price: string }>(
      f.pool,
      `SELECT pr.price::text AS price FROM prices pr JOIN price_lists pl ON pl.id = pr.price_list_id
         JOIN product_variants v ON v.id = pr.variant_id AND v.is_default JOIN products p ON p.id = v.product_id
        WHERE p.onec_ref = $1 AND pl.onec_ref = $2 AND pr.packaging_id IS NULL`,
      [anySlice.productRef, anySlice.priceListRef],
    );
    expect(db.price).toBe(anySlice.price);
  });

  // 12 T-CAT-010 (повтор full без дублей и перезаписей), T-SYNC-004
  it('повторная полная загрузка: ни одной вставки/перезаписи, updated_at не меняется (SYNC-005, SYNC-009, SYNC-013)', async () => {
    const f = await fresh();
    const before = new Map<string, Map<string, string>>();
    for (const t of REPLICAS.filter((x) => !['prices', 'stock_balances'].includes(x)))
      before.set(t, await snap(f.pool, t));
    before.set('prices', await snap(f.pool, 'prices'));
    before.set('stock_balances', await snap(f.pool, 'stock_balances', `variant_id::text || warehouse_id::text`));
    const again = await loadSyntheticCatalog(f.pool, { catalog: f.catalog });
    for (const r of again.results) {
      expect(r.status, r.entity).toBe('success');
      expect(r.counts?.inserted ?? 0, r.entity).toBe(0);
      expect(r.counts?.updated ?? 0, r.entity).toBe(0);
      expect(r.counts?.markedDeleted ?? 0, r.entity).toBe(0);
    }
    expect(again.results.find((r) => r.entity === 'products')!.counts!.skipped).toBeGreaterThan(100);
    for (const [t, s] of before) {
      const now =
        t === 'stock_balances'
          ? await snap(f.pool, t, `variant_id::text || warehouse_id::text`)
          : await snap(f.pool, t);
      expect(changed(s, now), t).toEqual([]);
    }
  });

  // 12 T-SYNC-002 (инкремент, ack после COMMIT), T-CAT-010 (изменение → updated), T-ONEC-004
  it('инкремент /changes: изменён 1 товар → изменилась ровно 1 строка products; ack после COMMIT; sync_node_state и sync_runs', async () => {
    const f = await fresh();
    const before = await snap(f.pool, 'products');
    const m = f.gateway.mutateCatalog({ renameProducts: 1 });
    const svc = changes(f);
    const r = await svc.pullOnce();
    expect(r.status).toBe('applied');
    expect(r.messageNumber).toBe(1);
    const after = await snap(f.pool, 'products');
    const diff = changed(before, after);
    expect(diff).toHaveLength(1);
    const ref = m.changedKeys[0].split(':')[1];
    expect(
      (await one<{ id: string; name: string }>(f.pool, `SELECT id, name FROM products WHERE onec_ref = $1`, [ref]))
        .name,
    ).toMatch(/\(обн\. 1\)$/);
    expect(diff[0]).toBe((await one<{ id: string }>(f.pool, `SELECT id FROM products WHERE onec_ref = $1`, [ref])).id);
    const ops = f.gateway.calls.map((c) => c.operation);
    expect(ops.indexOf('ackChanges')).toBeGreaterThan(ops.lastIndexOf('getChanges'));
    expect(f.gateway.calls.filter((c) => c.operation === 'ackChanges').map((c) => c.args[0])).toEqual([1]);
    const node = await one<{ n: string; ack: Date | null; err: string | null }>(
      f.pool,
      `SELECT last_message_number::text AS n, last_ack_at AS ack, last_error_code AS err FROM sync_node_state WHERE node = 'pos'`,
    );
    expect(node.n).toBe('1');
    expect(node.ack).not.toBeNull();
    expect(node.err).toBeNull();
    const run = await one<{ mode: string; status: string; cursor_to: string; trigger: string; updated: string }>(
      f.pool,
      `SELECT mode::text, status::text, cursor_to, "trigger"::text AS trigger, counts->>'updated' AS updated FROM sync_runs
        WHERE entity = 'products' AND mode = 'incremental'`,
    );
    expect(run).toEqual({ mode: 'incremental', status: 'success', cursor_to: '1', trigger: 'schedule', updated: '1' });
    // Следующий цикл: регистраций нет — пустое сообщение, ack не отправляется.
    expect((await svc.pullOnce()).status).toBe('empty');
    expect(f.gateway.calls.filter((c) => c.operation === 'ackChanges')).toHaveLength(1);
  });

  // 12 T-SYNC-002 (неизменённые не перезаписываются — source_hash)
  it('DataVersion сменился, содержимое — нет: строка не перезаписывается, версия учтена (SYNC-013, SYNC-032 п. 3)', async () => {
    const f = await fresh();
    const before = await snap(f.pool, 'products');
    const m = f.gateway.mutateCatalog({ touchProducts: 1 });
    const r = await changes(f).pullOnce();
    expect(r.status).toBe('applied');
    expect(r.counts.products).toMatchObject({ skipped: 1, updated: 0, inserted: 0 });
    expect(changed(before, await snap(f.pool, 'products'))).toEqual([]);
    const ref = m.changedKeys[0].split(':')[1];
    const item = f.catalog.productItems().find((p) => p.ref === ref)!;
    const v = await one<{ dv: string; run: string }>(
      f.pool,
      `SELECT data_version AS dv, seen_in_run_id::text AS run FROM sync_entity_versions WHERE entity = 'products' AND onec_key = $1`,
      [ref],
    );
    expect(v.dv).toBe(item.dataVersion);
    expect(v.run).toBe(r.runIds.products);
  });

  // 12 T-SYNC-004 (тот же пакет дважды), T-ONEC-004 (повтор GET без ack)
  it('повторный пакет идемпотентен: двойное применение даёт то же состояние; без ack сообщение выдаётся заново (SYNC-031)', async () => {
    const f = await fresh();
    const m = f.gateway.mutateCatalog({ renameProducts: 2, repricePrices: 2 });
    // Первая попытка: ack «не прошёл» (сбой сети) — данные применены, номер узла не сдвинут.
    const realAck = f.gateway.ackChanges.bind(f.gateway);
    let fail = true;
    f.gateway.ackChanges = (n, o) =>
      fail ? ((fail = false), Promise.reject(new OnecError('ackChanges', 0, 'TRANSPORT', 'сеть'))) : realAck(n, o);
    const svc = changes(f);
    const r1 = await svc.pullOnce();
    expect(r1.status).toBe('applied_not_acked');
    expect((await one<{ n: string }>(f.pool, `SELECT last_message_number::text AS n FROM sync_node_state`)).n).toBe(
      '0',
    );
    const state1 = new Map([...(await snap(f.pool, 'products')), ...(await snap(f.pool, 'prices'))]);
    // Повтор: то же сообщение 1 (регистрации не сняты) — состояние БД идентично, перезаписей нет.
    const r2 = await svc.pullOnce();
    expect(r2.status).toBe('applied');
    expect(r2.messageNumber).toBe(1);
    expect(r2.counts.products).toMatchObject({ updated: 0, inserted: 0, skipped: 2 });
    const state2 = new Map([...(await snap(f.pool, 'products')), ...(await snap(f.pool, 'prices'))]);
    expect(changed(state1, state2)).toEqual([]);
    // Ещё раз тот же состав (перерегистрация) — снова без изменений.
    f.gateway.exchange!.register(m.changedKeys);
    const r3 = await svc.pullOnce();
    expect(r3.messageNumber).toBe(2);
    expect(r3.counts.products).toMatchObject({ updated: 0, skipped: 2 });
    expect(changed(state2, new Map([...(await snap(f.pool, 'products')), ...(await snap(f.pool, 'prices'))]))).toEqual(
      [],
    );
  });

  // 12 T-SYNC-002 (пометки и удаления в пакете)
  it('deletion_mark: пометка в 1С и ObjectDeletion → только пометка (строка остаётся), служебный вариант скрыт, счётчик категории уменьшен', async () => {
    const f = await fresh();
    const m = f.gateway.mutateCatalog({ deleteProducts: 1 });
    const ref = m.changedKeys[0].split(':')[1];
    const catBefore = await one<{ id: string; cnt: number }>(
      f.pool,
      `SELECT c.id, c.product_count_cache AS cnt FROM products p JOIN categories c ON c.id = p.category_id WHERE p.onec_ref = $1`,
      [ref],
    );
    await changes(f).pullOnce();
    const p = await one<{ id: string; dm: boolean }>(
      f.pool,
      `SELECT id, deletion_mark AS dm FROM products WHERE onec_ref = $1`,
      [ref],
    );
    expect(p.dm).toBe(true);
    expect(
      (
        await one<{ dm: boolean }>(
          f.pool,
          `SELECT deletion_mark AS dm FROM product_variants WHERE product_id = $1 AND is_default`,
          [p.id],
        )
      ).dm,
    ).toBe(true);
    expect(
      (
        await one<{ cnt: number }>(f.pool, `SELECT product_count_cache AS cnt FROM categories WHERE id = $1`, [
          catBefore.id,
        ])
      ).cnt,
    ).toBe(catBefore.cnt - 1);
    // Физическое удаление в 1С: ObjectDeletion характеристики и товара.
    const v = f.catalog.variants()[0];
    const other = f.catalog.productItems().find((x) => !x.deletionMark && x.ref !== ref && x.sku !== 'KX-1245')!;
    f.gateway.exchange!.registerDeletion('Catalog_ХарактеристикиНоменклатуры', v.ref);
    f.gateway.exchange!.registerDeletion('Catalog_Номенклатура', other.ref);
    f.gateway.exchange!.registerDeletion('InformationRegister_ШтрихкодыНоменклатуры', f.catalog.barcodes()[0].barcode);
    const r = await changes(f).pullOnce();
    expect(r.status).toBe('applied');
    expect(
      (
        await one<{ dm: boolean }>(f.pool, `SELECT deletion_mark AS dm FROM product_variants WHERE onec_ref = $1`, [
          v.ref,
        ])
      ).dm,
    ).toBe(true);
    expect(
      (await one<{ dm: boolean }>(f.pool, `SELECT deletion_mark AS dm FROM products WHERE onec_ref = $1`, [other.ref]))
        .dm,
    ).toBe(true);
    expect(
      (
        await one<{ dm: boolean }>(f.pool, `SELECT deletion_mark AS dm FROM barcodes WHERE value = $1`, [
          f.catalog.barcodes()[0].barcode,
        ])
      ).dm,
    ).toBe(true);
    expect((await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products`)).n).toBe(
      String(f.stats.products),
    );
  });

  // 12 T-SYNC-003 (сбой страницы; в режиме расширения — откат всего сообщения), T-SYNC-008
  it('сбой при чтении страницы → ROLLBACK, ack не отправлен, номер узла не сдвинут; следующий цикл применяет сообщение целиком', async () => {
    const f = await fresh();
    f.gateway.mutateCatalog({ renameProducts: 12 });
    f.gateway.exchange!.injectError(
      2,
      new OnecError('getChanges', 503, 'POS_E_MAINTENANCE', 'обновление конфигурации'),
    );
    const svc = changes(f, { pageSize: 5 });
    await expect(svc.pullOnce()).rejects.toMatchObject({ code: 'POS_E_MAINTENANCE' });
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(false);
    expect(
      (
        await one<{ n: string; err: string }>(
          f.pool,
          `SELECT last_message_number::text AS n, last_error_code AS err FROM sync_node_state`,
        )
      ).n,
    ).toBe('0');
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products WHERE name LIKE '%(обн. 1)'`)).n,
    ).toBe('0');
    expect(
      (
        await one<{ s: string }>(
          f.pool,
          `SELECT status::text AS s FROM sync_runs WHERE entity = 'products' AND mode = 'incremental'`,
        )
      ).s,
    ).toBe('failed');
    expect((await one<{ err: string }>(f.pool, `SELECT last_error_code AS err FROM sync_node_state`)).err).toBe(
      'ONEC_UNAVAILABLE',
    );
    const r = await svc.pullOnce();
    expect(r.status).toBe('applied');
    expect(r.pages).toBe(3);
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products WHERE name LIKE '%(обн. 1)'`)).n,
    ).toBe('12');
  });

  it('сбой применения (обработчик модуля бросает) → ROLLBACK всего сообщения, ack не отправлен', async () => {
    const f = await fresh();
    f.gateway.mutateCatalog({ renameProducts: 1 });
    f.gateway.exchange!.registerDeletion('Catalog_Партнеры', 'c3d4e5f6-0000-4000-8000-000000000001');
    const failing: ChangeItemHandler = {
      types: ['Catalog_Партнеры'],
      entityOf: () => 'customers',
      apply: () => Promise.reject(new Error('ошибка модуля клиентов')),
    };
    await expect(changes(f, { handlers: [failing] }).pullOnce()).rejects.toThrow(/ошибка модуля клиентов/);
    expect(f.gateway.calls.some((c) => c.operation === 'ackChanges')).toBe(false);
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products WHERE name LIKE '%(обн. 1)'`)).n,
    ).toBe('0');
  });

  // 12 T-SYNC-003 (невалидные объекты → sync_errors, прогон partial), T-SYNC-045 (ненайденная единица)
  it('ошибка одной позиции → sync_errors, остальные применены, ack отправлен, прогон partial', async () => {
    const f = await fresh({ skuCount: 5 });
    const unit = f.catalog.units[0].ref;
    const cat = f.catalog.categories[0].ref;
    const NEW = (n: number) => `0eeeeeee-0000-4000-8000-${String(n).padStart(12, '0')}`;
    const items: Record<string, unknown>[] = [
      {
        type: 'Catalog_Номенклатура',
        ref: NEW(1),
        dataVersion: 'v1',
        deletionMark: false,
        isFolder: false,
        code: 'OK-1',
        description: 'Годный товар',
        sku: 'OK-1',
        parentRef: cat,
        baseUnitRef: unit,
        futureField: 'игнорируется',
      },
      {
        type: 'Catalog_Номенклатура',
        ref: NEW(2),
        dataVersion: 'v1',
        deletionMark: false,
        isFolder: false,
        code: 'BAD-UNIT',
        description: 'Нет единицы',
        parentRef: cat,
        baseUnitRef: NEW(99),
      },
      {
        type: 'Catalog_Номенклатура',
        ref: 'не-guid',
        dataVersion: 'v1',
        deletionMark: false,
        isFolder: false,
        description: 'Плохая ссылка',
        baseUnitRef: unit,
      },
      {
        type: 'Catalog_ВидыЦен',
        ref: NEW(3),
        dataVersion: 'v1',
        deletionMark: false,
        description: 'Долларовый',
        currency: 'USD',
      },
      {
        type: 'Catalog_УпаковкиЕдиницыИзмерения',
        ref: NEW(4),
        dataVersion: 'v1',
        deletionMark: false,
        description: 'Пустая',
        ownerRef: NEW(1),
        unitRef: unit,
        factor: '0.000',
      },
      { type: 'InformationRegister_ШтрихкодыНоменклатуры', ref: 'bad*code', barcode: 'bad*code', productRef: NEW(1) },
      {
        type: 'InformationRegister_ШтрихкодыНоменклатуры',
        ref: '2999999999999',
        barcode: '2999999999999',
        productRef: NEW(1),
        variantRef: null,
      },
      { type: 'Catalog_Чтото', ref: NEW(5) },
    ];
    const acks: number[] = [];
    const stub = {
      mode: 'fixtures',
      getHealth: () => Promise.reject(new Error('нет health')),
      getChanges: (): Promise<{ status: number; body: OnecChangesPage }> =>
        Promise.resolve({
          status: 200,
          body: {
            messageNumber: 7,
            hasMore: false,
            cursor: null,
            generatedAt: '2026-10-21T14:05:01+06:00',
            items: items as never,
          },
        }),
      ackChanges: (n: number) => {
        acks.push(n);
        return Promise.resolve({ status: 200, body: { messageNumber: n } });
      },
    } as unknown as OnecGateway;
    const r = await changes({ pool: f.pool, gateway: stub }).pullOnce();
    expect(r.status).toBe('applied');
    expect(acks).toEqual([7]);
    expect((await one<{ name: string }>(f.pool, `SELECT name FROM products WHERE onec_ref = $1`, [NEW(1)])).name).toBe(
      'Годный товар',
    );
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM barcodes WHERE value = '2999999999999'`)).n,
    ).toBe('1');
    expect(
      (await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM products WHERE onec_ref = $1`, [NEW(2)])).n,
    ).toBe('0');
    const errs = await f.pool.query<{
      entity: string;
      code: string;
      ref: string | null;
      oc: string | null;
      sev: string;
    }>(
      `SELECT entity::text, error_code AS code, onec_ref::text AS ref, onec_code AS oc, severity AS sev FROM sync_errors ORDER BY entity, error_code`,
    );
    expect(errs.rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ entity: 'products', code: 'NOT_FOUND_LOCAL', ref: NEW(2) }),
        expect.objectContaining({ entity: 'products', code: 'VALIDATION', ref: null }),
        expect.objectContaining({ entity: 'prices', code: 'VALIDATION', ref: NEW(3) }),
        expect.objectContaining({ entity: 'products', code: 'VALIDATION', ref: NEW(4) }),
        expect.objectContaining({ entity: 'barcodes', code: 'VALIDATION', oc: 'bad*code' }),
        expect.objectContaining({ entity: 'products', code: 'VALIDATION', sev: 'warning' }),
      ]),
    );
    expect(
      (
        await one<{ s: string }>(
          f.pool,
          `SELECT status::text AS s FROM sync_runs WHERE entity = 'products' AND mode = 'incremental'`,
        )
      ).s,
    ).toBe('partial');
    expect((await one<{ n: string }>(f.pool, `SELECT last_message_number::text AS n FROM sync_node_state`)).n).toBe(
      '7',
    );
  });

  // 12 T-SYNC-014
  it('цены: документ установки цен → перечитка среза затронутых видов цен; изменились ровно изменённые строки (SYNC-015)', async () => {
    const f = await fresh();
    const before = await snap(f.pool, 'prices');
    const sliceBefore = f.catalog.priceSlice().map((x) => JSON.stringify(x));
    f.gateway.mutateCatalog({ repricePrices: 3 });
    const prev = new Set(sliceBefore);
    const repriced = f.catalog.priceSlice().filter((x) => !prev.has(JSON.stringify(x))).length;
    expect(repriced).toBeGreaterThan(0);
    const r = await changes(f).pullOnce();
    expect(r.status).toBe('applied');
    expect(Object.keys(r.runIds)).toEqual(['prices']);
    expect(changed(before, await snap(f.pool, 'prices'))).toHaveLength(repriced);
    expect(r.counts.prices?.tables.prices).toMatchObject({ updated: repriced, inserted: 0, markedDeleted: 0 });
  });

  // 12 T-SYNC-013
  it('срез остатков: пишутся только изменённые строки; строка, исчезнувшая из среза, обнуляется (не удаляется)', async () => {
    const f = await fresh();
    const before = await snap(f.pool, 'stock_balances', `variant_id::text || '|' || warehouse_id::text`);
    const prev = new Set(f.catalog.stockSlice().map((x) => JSON.stringify(x)));
    f.gateway.mutateCatalog({ restockRows: 2 });
    const all = f.catalog.stockSlice();
    const mutated = all.filter((x) => !prev.has(JSON.stringify(x)));
    expect(mutated.length).toBeGreaterThan(0);
    const dropped = all.find((r) => r.onHand !== '0.000' && !mutated.includes(r))!;
    const base = new SyntheticCatalogSource(f.gateway);
    const source: CatalogFullSource = {
      ...base,
      name: 'test',
      read: (k: CatalogReadKind) => base.read(k),
      priceSlice: (refs: readonly string[]) => base.priceSlice(refs),
      stockSlice: async function* () {
        yield await Promise.resolve(all.filter((r) => r !== dropped));
      },
    };
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    const res = await svc.run({ entity: 'stock', mode: 'full', source });
    expect(res.status).toBe('success');
    expect(res.counts).toMatchObject({ updated: mutated.length, inserted: 0, markedDeleted: 1 });
    expect(
      changed(before, await snap(f.pool, 'stock_balances', `variant_id::text || '|' || warehouse_id::text`)),
    ).toHaveLength(mutated.length + 1);
    const zero = await one<{ q: string; a: string }>(
      f.pool,
      `SELECT s.quantity::text AS q, s.available::text AS a FROM stock_balances s JOIN warehouses w ON w.id = s.warehouse_id
         JOIN product_variants v ON v.id = s.variant_id LEFT JOIN products p ON p.id = v.product_id
        WHERE w.onec_ref = $1 AND (v.onec_ref = $2 OR (v.is_default AND p.onec_ref = $3 AND $2::uuid IS NULL))`,
      [dropped.warehouseRef, dropped.variantRef, dropped.productRef],
    );
    expect(zero).toEqual({ q: '0.000', a: '0.000' });
  });

  // 12 T-SYNC-010
  it('полная загрузка: не встреченный объект → deletion_mark при совпадении $count; расхождение — partial без пометок (SYNC-003, SYNC-006)', async () => {
    const f = await fresh();
    const gone = f.catalog.productItems().find((p) => !p.deletionMark && p.sku !== 'KX-1245')!;
    const base = new SyntheticCatalogSource(f.gateway);
    const make = (countDelta: number): CatalogFullSource => ({
      name: 'test',
      read: async function* (k: CatalogReadKind) {
        for await (const page of base.read(k)) yield page.filter((i: OnecCatalogItem) => i.ref !== gone.ref);
      },
      count: async (k: CatalogReadKind) => (await base.count(k)) + (k === 'products' ? countDelta - 1 : 0),
      priceSlice: (refs: readonly string[]): AsyncIterable<readonly OnecPriceRow[]> => base.priceSlice(refs),
      stockSlice: (w?: readonly string[]): AsyncIterable<readonly OnecStockRow[]> => base.stockSlice(w),
    });
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    const mismatch = await svc.run({ entity: 'products', mode: 'full', source: make(+1) });
    expect(mismatch.status).toBe('partial');
    expect(mismatch.counts).toMatchObject({ markedDeleted: 0 });
    expect(
      (await one<{ dm: boolean }>(f.pool, `SELECT deletion_mark AS dm FROM products WHERE onec_ref = $1`, [gone.ref]))
        .dm,
    ).toBe(false);
    expect(
      (
        await one<{ n: string }>(
          f.pool,
          `SELECT count(*)::text AS n FROM sync_errors WHERE error_code = 'COUNT_MISMATCH'`,
        )
      ).n,
    ).toBe('1');
    const ok = await svc.run({ entity: 'products', mode: 'reconcile', source: make(0) });
    expect(ok.status).toBe('success');
    expect(ok.counts?.tables.products).toMatchObject({ markedDeleted: 1, updated: 0, inserted: 0 });
    expect(
      (await one<{ dm: boolean }>(f.pool, `SELECT deletion_mark AS dm FROM products WHERE onec_ref = $1`, [gone.ref]))
        .dm,
    ).toBe(true);
  });

  // 12 T-SYNC-002 (фаза 0: DataVersion + source_hash)
  it('фаза 0: инкремент по DataVersion — дочитывается ровно изменённый объект (SYNC-012)', async () => {
    const f = await fresh();
    f.catalog.mutate({ renameProducts: 1 });
    const before = await snap(f.pool, 'products');
    const base = new SyntheticCatalogSource(f.gateway);
    const fetched: string[] = [];
    const source: CatalogFullSource = {
      name: 'test',
      read: (k: CatalogReadKind) => base.read(k),
      versions: (k: CatalogReadKind) => base.versions(k),
      fetchByKeys: (k: CatalogReadKind, keys: readonly string[]) => {
        fetched.push(...keys);
        return base.fetchByKeys(k, keys);
      },
      priceSlice: (refs: readonly string[]) => base.priceSlice(refs),
      stockSlice: (w?: readonly string[]) => base.stockSlice(w),
    };
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    const r = await svc.run({ entity: 'products', mode: 'incremental', source });
    expect(fetched).toHaveLength(1);
    expect(r.counts).toMatchObject({ updated: 1, inserted: 0 });
    expect(changed(before, await snap(f.pool, 'products'))).toHaveLength(1);
  });

  it('вид цены по умолчанию из seed («Розничная», onec_ref NULL) связывается с видом цены 1С того же имени (EQ-INT-03)', async () => {
    // без фикстур 1С: в них есть свой вид цены «Розничная» (второй объект 1С с тем же именем — отдельная строка)
    const f = await fresh({ skipLoad: true, includeFixtures: false });
    const SEED_ID = '00000000-0000-7000-8000-000000000101';
    await f.pool.query(
      `INSERT INTO price_lists (id, synced_at, source_hash, name, is_default, visible_to_roles, sort_order)
       VALUES ($1, now(), 'seed:typical', 'Розничная', true, '{seller,cashier,senior_seller,admin,owner,customer}', 0)`,
      [SEED_ID],
    );
    const svc = new CatalogFullLoadService(f.pool, new CatalogApplier(), createRunTracker(f.pool), silent);
    await svc.loadAll(new SyntheticCatalogSource(f.gateway), 'full');
    const lists = await f.pool.query<{
      id: string;
      name: string;
      is_default: boolean;
      linked: boolean;
      prices: number;
    }>(
      `SELECT l.id, l.name, l.is_default, l.onec_ref IS NOT NULL AS linked,
              (SELECT count(*)::int FROM prices p WHERE p.price_list_id = l.id) AS prices
         FROM price_lists l WHERE lower(l.name) = 'розничная'`,
    );
    // одна строка: seed-строка получила onec_ref вида цены 1С, сохранила is_default и id; цены легли на неё
    expect(lists.rows).toHaveLength(1);
    expect(lists.rows[0]).toMatchObject({ id: SEED_ID, is_default: true, linked: true });
    expect(lists.rows[0]?.prices).toBeGreaterThan(0);
    // повторная загрузка — без дублей и без перезаписи (SYNC-013)
    const before = await snap(f.pool, 'price_lists');
    await svc.loadAll(new SyntheticCatalogSource(f.gateway), 'full');
    expect(changed(before, await snap(f.pool, 'price_lists'))).toEqual([]);
  });

  it('статические фикстуры /changes (без каталога): товар раньше своей группы, неизвестное удаление, клиенты/документы без обработчика', async () => {
    const f = await fresh({ skuCount: 0, includeFixtures: false, skipLoad: true });
    const gw = new FakeOnecGateway();
    const r = await changes({ pool: f.pool, gateway: gw }, { health: false }).pullOnce();
    expect(r.status).toBe('applied');
    expect(r.messageNumber).toBe(5121);
    expect(r.pages).toBe(2);
    expect(r.unhandled).toBeGreaterThan(0);
    const kx = await one<{ cat: string; unit: string; hv: boolean }>(
      f.pool,
      `SELECT c.name AS cat, u.name AS unit, p.has_variants AS hv FROM products p JOIN categories c ON c.id = p.category_id JOIN units u ON u.id = p.base_unit_id WHERE p.sku = 'KX-1245'`,
    );
    expect(kx).toEqual({ cat: 'Смесители', unit: 'шт', hv: true });
    expect((await one<{ n: string }>(f.pool, `SELECT count(*)::text AS n FROM packagings`)).n).toBe('1');
    // Документ установки цен страницы 2: перечитка среза без источника срезов — одно предупреждение (SYNC-015).
    const errs = await f.pool.query<{ e: string; code: string; sev: string }>(
      `SELECT entity::text AS e, error_code AS code, severity AS sev FROM sync_errors`,
    );
    expect(errs.rows).toEqual([{ e: 'prices', code: 'OTHER', sev: 'warning' }]);
    expect(gw.calls.filter((c) => c.operation === 'ackChanges').map((c) => c.args[0])).toEqual([5121]);
    expect((await one<{ n: string }>(f.pool, `SELECT last_message_number::text AS n FROM sync_node_state`)).n).toBe(
      '5121',
    );
  });
});
