import type pg from 'pg';
import pino from 'pino';
import type { OnecBarcodeItem, OnecCatalogItem } from '../../src/integrations/onec/onec-catalog.types.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '../../src/sync/apply/catalog-full-load.service.js';
import {
  type CatalogFullSource,
  type CatalogReadKind,
  type CatalogReadPage,
  SyntheticCatalogSource,
} from '../../src/sync/apply/catalog-source.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';

/**
 * Полная загрузка каталога (05 §7.1) на embedded PostgreSQL 17 и синтетике (тестовые данные):
 * - 12 T-SYNC-F03 (05 SYNC-002, AC-SYNC-002, SYNC-006, AC-SYNC-006; 04 FLOW-033.A2): обрыв на середине → прогон
 *   `failed` с `cursor_to`, загруженное сохранено, `deletion_mark` не ставится; повтор продолжает с `cursor_to`
 *   (загруженные страницы не перечитываются, дублей нет); после `partial` — полная перезагрузка с начала;
 * - 12 T-SYNC-009 (05 SYNC-004; E-KI-04): два товара с одним `onec_code` → отчёт `DUPLICATE_SUSPECTED` без
 *   автоисправления, оба товара загружены;
 * - 12 T-SYNC-F09 (05 F9, ONEC-017, SYNC-020) на пути полной перечитки регистра штрихкодов: один штрихкод у двух
 *   товаров → `BARCODE_CONFLICT` в `sync_errors` прогона, сканер находит один товар.
 */
const silent = pino({ level: 'silent' });
let server: EmbeddedPg;
let dbNo = 0;
const open: CatalogFixture[] = [];

async function fresh(): Promise<CatalogFixture> {
  const f = await startCatalogFixture({ pg: server, database: `resume_${++dbNo}`, skuCount: 60 });
  open.push(f);
  return f;
}

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
});

afterAll(async () => {
  for (const f of open) await f.stop();
  await server?.stop();
});

interface Plan {
  /** Обрыв: страница `page` (с 1) набора `kind` бросает ошибку (1С недоступна посреди загрузки). */
  fail?: { kind: CatalogReadKind; page: number };
  /** Замена/фильтр элементов набора. */
  map?: (kind: CatalogReadKind, items: readonly OnecCatalogItem[]) => readonly OnecCatalogItem[];
  /** Поправка `$count` набора. */
  countDelta?: Partial<Record<CatalogReadKind, number>>;
  /** Дописать элементы в конец набора (последней страницей). */
  extra?: Partial<Record<CatalogReadKind, readonly OnecCatalogItem[]>>;
}

/**
 * Источник поверх синтетики: журнал чтений `{kind, skip}` (`readPages(kind, startSkip)`; `read(kind)` — с начала,
 * `skip: 0`) и управляемый обрыв. Непродолжаемые сущности (штрихкоды) читаются через `read`.
 */
function source(base: SyntheticCatalogSource, plan: Plan, calls: { kind: CatalogReadKind; skip: number }[]) {
  const src: CatalogFullSource = {
    name: 'flaky',
    read: async function* (kind: CatalogReadKind) {
      for await (const page of pages(kind, 0)) yield page.items;
    },
    readPages: (kind: CatalogReadKind, startSkip: number) => pages(kind, startSkip),
    count: async (k) => (await base.count(k)) + (plan.countDelta?.[k] ?? 0),
    priceSlice: (refs) => base.priceSlice(refs),
    stockSlice: (w) => base.stockSlice(w),
  };
  async function* pages(kind: CatalogReadKind, startSkip: number): AsyncIterable<CatalogReadPage> {
    calls.push({ kind, skip: startSkip });
    let n = 0;
    let last = startSkip;
    for await (const page of base.readPages(kind, startSkip)) {
      n += 1;
      if (plan.fail && plan.fail.kind === kind && plan.fail.page === n) {
        throw new Error(`обрыв связи с 1С на странице ${n} набора ${kind} (тест)`);
      }
      last = page.nextSkip;
      yield { items: plan.map ? plan.map(kind, page.items) : page.items, nextSkip: page.nextSkip };
    }
    const extra = plan.extra?.[kind];
    if (extra && extra.length > 0) yield { items: extra, nextSkip: last + extra.length };
  }
  return src;
}

async function q<T extends pg.QueryResultRow>(pool: pg.Pool, sql: string, params: unknown[] = []): Promise<T[]> {
  return (await pool.query<T>(sql, params)).rows;
}

async function lastRun(pool: pg.Pool, entity: string) {
  const [r] = await q<{ id: string; status: string; cursor_from: string | null; cursor_to: string | null }>(
    pool,
    `SELECT id, status::text AS status, cursor_from, cursor_to FROM sync_runs
      WHERE entity = $1 ORDER BY created_at DESC, id DESC LIMIT 1`,
    [entity],
  );
  return r;
}

const liveProducts = (f: CatalogFixture) => f.catalog.productItems().filter((p) => !p.deletionMark);

describe('T-SYNC-F03: обрыв полной загрузки и продолжение с cursor_to (05 SYNC-002, SYNC-006)', () => {
  it('обрыв на 4-й странице товаров → failed с cursor_to, пометок нет; повтор продолжает с cursor_to: 3 страницы не перечитаны, дублей нет, удалённый в 1С помечен', async () => {
    const f = await fresh();
    const pool = f.pool;
    const svc = new CatalogFullLoadService(pool, new CatalogApplier(), createRunTracker(pool), silent);
    const base = new SyntheticCatalogSource(f.gateway, 10);
    const all = f.catalog.productItems();
    expect(all.length).toBeGreaterThan(40);
    // Товар из последних страниц исчез из 1С: после полного прохода он должен получить deletion_mark (SYNC-006).
    const gone = [...all].reverse().find((p) => !p.deletionMark)!;
    const plan: Plan = {
      map: (k, items) => (k === 'products' ? items.filter((i) => i.ref !== gone.ref) : items),
      countDelta: { products: -1 },
    };
    const rowsBefore = await q<{ n: string; dm: string }>(
      pool,
      `SELECT count(*)::text AS n, count(*) FILTER (WHERE deletion_mark)::text AS dm FROM products`,
    );

    const calls1: { kind: CatalogReadKind; skip: number }[] = [];
    await expect(
      svc.run({
        entity: 'products',
        mode: 'full',
        source: source(base, { ...plan, fail: { kind: 'products', page: 4 } }, calls1),
      }),
    ).rejects.toThrow(/обрыв связи/);
    const failed = await lastRun(pool, 'products');
    expect(failed).toMatchObject({ status: 'failed', cursor_to: 'skip:products:30' });
    // Загруженное сохранено, пометки удаления не ставились (AC-SYNC-006): исчезнувший товар — живой.
    const seen1 = await q<{ n: string }>(
      pool,
      `SELECT count(*)::text AS n FROM sync_entity_versions WHERE entity = 'products' AND seen_in_run_id = $1`,
      [failed.id],
    );
    expect(Number(seen1[0].n)).toBeGreaterThanOrEqual(30);
    const goneRow = async () =>
      (await q<{ dm: boolean }>(pool, `SELECT deletion_mark AS dm FROM products WHERE onec_ref = $1`, [gone.ref]))[0]
        .dm;
    expect(await goneRow()).toBe(false);
    expect(
      await q<{ n: string; dm: string }>(
        pool,
        `SELECT count(*)::text AS n, count(*) FILTER (WHERE deletion_mark)::text AS dm FROM products`,
      ),
    ).toEqual(rowsBefore);

    // Повтор: продолжение с $skip=30 — первые три страницы не читаются; сверка учитывает объекты оборванного прогона.
    const calls2: { kind: CatalogReadKind; skip: number }[] = [];
    const res = await svc.run({ entity: 'products', mode: 'full', source: source(base, plan, calls2) });
    expect(calls2[0]).toEqual({ kind: 'products', skip: 30 });
    expect(calls2.find((c) => c.kind === 'packagings')).toEqual({ kind: 'packagings', skip: 0 });
    expect(res.status).toBe('success');
    expect(res.counts?.tables.products?.fetched).toBe(all.length - 30 - 1);
    // Не встреченный (исчезнувший) — ровно один; товары оборванного прогона не помечены (перенос seen_in_run_id).
    expect(res.counts?.tables.products?.markedDeleted).toBe(1);
    expect(await goneRow()).toBe(true);
    const run2 = await lastRun(pool, 'products');
    expect(run2).toMatchObject({ id: res.runId, status: 'success', cursor_from: 'skip:products:30' });
    const dup = await q<{ n: string }>(
      pool,
      `SELECT count(*)::text AS n FROM (SELECT onec_ref FROM products WHERE onec_ref IS NOT NULL
         GROUP BY onec_ref HAVING count(*) > 1) d`,
    );
    expect(dup[0].n).toBe('0');
    expect((await q<{ n: string }>(pool, `SELECT count(*)::text AS n FROM products`))[0].n).toBe(rowsBefore[0].n);
  });

  it('повтор job (прогон создан обработчиком): обрыв в упаковках → повтор не читает товары и продолжает упаковки с cursor_to', async () => {
    const f = await fresh();
    const pool = f.pool;
    const tracker = createRunTracker(pool);
    const svc = new CatalogFullLoadService(pool, new CatalogApplier(), tracker, silent);
    const packs = f.catalog.packagings().length;
    expect(packs).toBeGreaterThanOrEqual(6);
    const size = Math.max(2, Math.floor(packs / 3));
    const base = new SyntheticCatalogSource(f.gateway, size);
    const calls1: { kind: CatalogReadKind; skip: number }[] = [];
    // Как SyncJobProcessor: строка прогона создана заранее, при ошибке её завершает процессор.
    const run1 = await tracker.start({ entity: 'products', mode: 'full', trigger: 'schedule' });
    await expect(
      svc.run({
        entity: 'products',
        mode: 'full',
        runId: run1,
        source: source(base, { fail: { kind: 'packagings', page: 2 } }, calls1),
      }),
    ).rejects.toThrow(/обрыв связи/);
    await tracker.finish({ runId: run1, entity: 'products', status: 'failed', counts: {}, errorSummary: 'обрыв' });
    expect(await lastRun(pool, 'products')).toMatchObject({ status: 'failed', cursor_to: `skip:packagings:${size}` });
    const marked = await q<{ n: string }>(pool, `SELECT count(*)::text AS n FROM packagings WHERE deletion_mark`);

    const run2 = await tracker.start({ entity: 'products', mode: 'full', trigger: 'retry' });
    const calls2: { kind: CatalogReadKind; skip: number }[] = [];
    const res = await svc.run({ entity: 'products', mode: 'full', runId: run2, source: source(base, {}, calls2) });
    expect(calls2).toEqual([{ kind: 'packagings', skip: size }]);
    expect(res.status).toBe('success');
    expect(res.counts?.tables.packagings?.fetched).toBe(packs - size);
    expect(res.counts?.tables.packagings?.markedDeleted ?? 0).toBe(0);
    expect(await q<{ n: string }>(pool, `SELECT count(*)::text AS n FROM packagings WHERE deletion_mark`)).toEqual(
      marked,
    );
  });

  it('после partial (расхождение сверки) и после промежуточного прогона — полная перезагрузка с начала; штрихкоды после обрыва — с начала', async () => {
    const f = await fresh();
    const pool = f.pool;
    const svc = new CatalogFullLoadService(pool, new CatalogApplier(), createRunTracker(pool), silent);
    const base = new SyntheticCatalogSource(f.gateway, 10);

    const partial = await svc.run({
      entity: 'products',
      mode: 'full',
      source: source(base, { countDelta: { products: +1 } }, []),
    });
    expect(partial.status).toBe('partial');
    const calls: { kind: CatalogReadKind; skip: number }[] = [];
    await svc.run({ entity: 'products', mode: 'full', source: source(base, {}, calls) });
    expect(calls[0]).toEqual({ kind: 'products', skip: 0 });

    // Обрыв, затем другой прогон сущности (инкремент/сверка) — курсор оборванного прогона не используется.
    await expect(
      svc.run({ entity: 'products', mode: 'full', source: source(base, { fail: { kind: 'products', page: 2 } }, []) }),
    ).rejects.toThrow();
    await svc.run({ entity: 'products', mode: 'reconcile', source: source(base, {}, []) });
    const calls3: { kind: CatalogReadKind; skip: number }[] = [];
    await svc.run({ entity: 'products', mode: 'full', source: source(base, {}, calls3) });
    expect(calls3[0]).toEqual({ kind: 'products', skip: 0 });

    // Обрыв в другом режиме (reconcile) не продолжается полной загрузкой.
    await expect(
      svc.run({
        entity: 'products',
        mode: 'reconcile',
        source: source(base, { fail: { kind: 'products', page: 2 } }, []),
      }),
    ).rejects.toThrow();
    const calls4: { kind: CatalogReadKind; skip: number }[] = [];
    await svc.run({ entity: 'products', mode: 'full', source: source(base, {}, calls4) });
    expect(calls4[0]).toEqual({ kind: 'products', skip: 0 });

    // barcodes: правило ONEC-017 по всем страницам прогона — после обрыва курсор не пишется, чтение с начала.
    await expect(
      svc.run({ entity: 'barcodes', mode: 'full', source: source(base, { fail: { kind: 'barcodes', page: 2 } }, []) }),
    ).rejects.toThrow();
    expect((await lastRun(pool, 'barcodes')).cursor_to).toBeNull();
    const calls5: { kind: CatalogReadKind; skip: number }[] = [];
    await svc.run({ entity: 'barcodes', mode: 'full', source: source(base, {}, calls5) });
    expect(calls5).toEqual([{ kind: 'barcodes', skip: 0 }]);
  });
});

describe('T-SYNC-009: отчёт о дублях onec_code при первичной загрузке (05 SYNC-004; E-KI-04)', () => {
  it('два товара с одним кодом 1С → DUPLICATE_SUSPECTED (warning) со ссылками обоих; оба загружены, прогон success', async () => {
    const f = await fresh();
    const pool = f.pool;
    const svc = new CatalogFullLoadService(pool, new CatalogApplier(), createRunTracker(pool), silent);
    const base = new SyntheticCatalogSource(f.gateway, 25);
    const [a, b] = liveProducts(f);
    const code = a.code!;
    expect(code).toBeTruthy();
    const plan: Plan = {
      map: (k, items) =>
        k === 'products' ? items.map((i) => (i.ref === b.ref ? ({ ...i, code } as OnecCatalogItem) : i)) : items,
    };
    const res = await svc.run({ entity: 'products', mode: 'full', source: source(base, plan, []) });
    expect(res.status).toBe('success');
    expect(res.counts?.errors).toBe(0);
    const rows = await q<{ ref: string; dm: boolean }>(
      pool,
      `SELECT onec_ref::text AS ref, deletion_mark AS dm FROM products WHERE onec_code = $1 ORDER BY onec_ref`,
      [code],
    );
    expect(rows).toEqual([a.ref, b.ref].sort().map((ref) => ({ ref, dm: false })));
    const errs = await q<{ severity: string; onec_code: string; payload: Record<string, unknown>; run: string }>(
      pool,
      `SELECT severity, onec_code, payload, sync_run_id::text AS run FROM sync_errors
        WHERE error_code = 'DUPLICATE_SUSPECTED' AND entity = 'products'`,
    );
    expect(errs).toHaveLength(1);
    expect(errs[0]).toMatchObject({
      severity: 'warning',
      onec_code: code,
      run: res.runId,
      payload: { table: 'products', field: 'onec_code', onecCode: code, count: 2, refs: [a.ref, b.ref].sort() },
    });
    // Полная загрузка без дублей — новых записей нет (отчёт — по прогону).
    await svc.run({ entity: 'products', mode: 'full', source: source(base, {}, []) });
    expect(
      await q(pool, `SELECT 1 FROM sync_errors WHERE error_code = 'DUPLICATE_SUSPECTED' AND entity = 'products'`),
    ).toHaveLength(1);
  });
});

describe('T-SYNC-F09: штрихкод у двух товаров при полной перечитке регистра (05 F9, ONEC-017, SYNC-020)', () => {
  it('BARCODE_CONFLICT в sync_errors прогона barcodes; привязка — наименьший ключ; сканер находит один товар', async () => {
    const f = await fresh();
    const pool = f.pool;
    const svc = new CatalogFullLoadService(pool, new CatalogApplier(), createRunTracker(pool), silent);
    const base = new SyntheticCatalogSource(f.gateway, 50);
    const [p1, p2] = liveProducts(f)
      .slice(2, 4)
      .map((p) => p.ref)
      .sort();
    const value = '2990000009901';
    const bc = (productRef: string): OnecBarcodeItem =>
      ({
        type: 'InformationRegister_ШтрихкодыНоменклатуры',
        ref: value,
        barcode: value,
        productRef,
        variantRef: null,
      }) as unknown as OnecBarcodeItem;
    // Привязка к p2 — в первой странице, к p1 — последней страницей того же прогона (порядок не влияет, ONEC-017).
    let injected = false;
    const plan: Plan = {
      map: (k, items) => {
        if (k !== 'barcodes' || injected) return items;
        injected = true;
        return [bc(p2), ...items];
      },
      extra: { barcodes: [bc(p1)] },
      countDelta: { barcodes: 1 },
    };
    const res = await svc.run({ entity: 'barcodes', mode: 'full', source: source(base, plan, []) });
    const errs = await q<{ severity: string; run: string; payload: Record<string, unknown> }>(
      pool,
      `SELECT severity, sync_run_id::text AS run, payload FROM sync_errors
        WHERE error_code = 'BARCODE_CONFLICT' AND onec_code = $1`,
      [value],
    );
    expect(errs).toHaveLength(1);
    expect(errs[0]).toMatchObject({ run: res.runId, payload: { rule: 'min_key', chosen: { productRef: p1 } } });
    const found = await q<{ ref: string }>(
      pool,
      `SELECT p.onec_ref::text AS ref FROM barcodes b JOIN products p ON p.id = b.product_id
        WHERE b.value = $1 AND NOT b.deletion_mark`,
      [value],
    );
    expect(found).toEqual([{ ref: p1 }]);
  });
});
