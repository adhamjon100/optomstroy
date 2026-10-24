import { newId } from '../../common/ids/uuid.js';
import type { OnecPriceRow, OnecStockRow } from '../../integrations/onec/onec-catalog.types.js';
import type { ApplyScope } from './apply.types.js';
import {
  milliToNumeric,
  moneyToTyiyn,
  onecRef,
  OnecValueError,
  qtyToMilli,
  requiredRef,
  sourceHash,
  tyiynToNumeric,
} from './onec-values.js';
import { BATCH, bump, dbMessage, flushErrors, idsByRef, inSavepoint, itemError } from './replica-writer.js';

/**
 * Отслеживание полного среза (05 SYNC-014, SYNC-015; 07 §5.25, §5.27): какие строки «увидены» за прогон.
 * После всех страниц `finish*Slice` удаляет цены, исчезнувшие из среза (физически — производная таблица), и
 * обнуляет остатки строк, которых нет в срезе (строки не удаляются).
 */
export interface SliceTracker {
  /** id видов цен / складов, срез которых полный. */
  readonly scopeIds: Set<string>;
  /** id строк `prices` либо ключи `variant|warehouse` `stock_balances`. */
  readonly seen: Set<string>;
  /** Ошибка чтения среза → удаление/обнуление не выполняется (защита от массовой «потери» данных). */
  incomplete: boolean;
}

export function newSliceTracker(): SliceTracker {
  return { scopeIds: new Set(), seen: new Set(), incomplete: false };
}

/** Варианты по ссылкам 1С: характеристика или служебный вариант товара (`variantRef = null`, 07 §5.27). */
async function resolveVariants(
  scope: ApplyScope,
  rows: readonly { productRef: string; variantRef: string | null }[],
): Promise<{ byVariant: Map<string, string>; byProduct: Map<string, string> }> {
  const byVariant = await idsByRef(
    scope.client,
    'product_variants',
    rows.map((r) => r.variantRef).filter((x): x is string => !!x),
  );
  const products = [...new Set(rows.filter((r) => !r.variantRef).map((r) => r.productRef))];
  const byProduct = new Map<string, string>();
  for (let i = 0; i < products.length; i += 5000) {
    const r = await scope.client.query<{ ref: string; id: string }>(
      `SELECT p.onec_ref::text AS ref, v.id FROM products p
         JOIN product_variants v ON v.product_id = p.id AND v.is_default
        WHERE p.onec_ref = ANY($1::uuid[])`,
      [products.slice(i, i + 5000)],
    );
    for (const x of r.rows) byProduct.set(x.ref, x.id);
  }
  return { byVariant, byProduct };
}

/**
 * Строки среза цен (`SliceLast` по виду цены / `CatalogPrice`) → `prices` (ключ `variant_id, price_list_id,
 * packaging_id`, NULLS NOT DISTINCT). Деньги — decimal.js → тыйыны → `NUMERIC(14,2)`; цена < 0 и не-KGS вид цены —
 * ошибка позиции. Неизменённая строка (`source_hash`) не перезаписывается (SYNC-013).
 */
export async function applyPriceRows(
  scope: ApplyScope,
  rows: readonly OnecPriceRow[],
  tracker?: SliceTracker,
): Promise<void> {
  if (rows.length === 0) return;
  bump(scope, 'prices', 'fetched', rows.length);
  const parsed: {
    priceListRef: string;
    productRef: string;
    variantRef: string | null;
    packRef: string | null;
    price: string;
    validFrom: string | null;
    doc: string | null;
  }[] = [];
  for (const r of rows) {
    try {
      const t = moneyToTyiyn(r.price, 'price');
      if (t < 0n) throw new OnecValueError('price: цена < 0');
      parsed.push({
        priceListRef: requiredRef(r.priceListRef, 'priceListRef'),
        productRef: requiredRef(r.productRef, 'productRef'),
        variantRef: onecRef(r.variantRef, 'variantRef'),
        packRef: onecRef(r.packagingRef, 'packagingRef'),
        price: tyiynToNumeric(t),
        validFrom: typeof r.period === 'string' && r.period ? r.period : null,
        doc: onecRef(r.documentRef ?? null, 'documentRef'),
      });
    } catch (e) {
      itemError(scope, 'prices', {
        errorCode: 'VALIDATION',
        severity: 'error',
        message: msg(e),
        onecRef: safeRef(r.productRef),
      });
    }
  }
  const lists = await scope.client.query<{ ref: string; id: string; currency: string }>(
    `SELECT onec_ref::text AS ref, id, currency FROM price_lists WHERE onec_ref = ANY($1::uuid[])`,
    [[...new Set(parsed.map((p) => p.priceListRef))]],
  );
  const listId = new Map(lists.rows.map((r) => [r.ref, r.id]));
  const { byVariant, byProduct } = await resolveVariants(scope, parsed);
  const packs = await idsByRef(
    scope.client,
    'packagings',
    parsed.map((p) => p.packRef).filter((x): x is string => !!x),
  );
  const keyed = new Map<string, Record<string, unknown> & { hash: string }>();
  const missingLists = new Set<string>();
  for (const p of parsed) {
    const pl = listId.get(p.priceListRef);
    const variantId = p.variantRef ? byVariant.get(p.variantRef) : byProduct.get(p.productRef);
    const packId = p.packRef ? packs.get(p.packRef) : null;
    if (!pl) {
      if (!missingLists.has(p.priceListRef)) {
        missingLists.add(p.priceListRef);
        itemError(scope, 'prices', {
          errorCode: 'NOT_FOUND_LOCAL',
          severity: 'error',
          message: 'вид цены не найден в реплике price_lists (или не KGS)',
          onecRef: p.priceListRef,
        });
      }
      continue;
    }
    if (!variantId || packId === undefined) {
      itemError(scope, 'prices', {
        errorCode: 'NOT_FOUND_LOCAL',
        severity: 'error',
        message: !variantId ? 'вариант цены не найден в реплике' : 'упаковка цены не найдена в реплике',
        onecRef: p.variantRef ?? p.productRef,
      });
      continue;
    }
    const hash = sourceHash({ price: p.price, validFrom: p.validFrom, doc: p.doc });
    keyed.set(`${variantId}|${pl}|${packId ?? ''}`, {
      variant_id: variantId,
      price_list_id: pl,
      packaging_id: packId,
      price: p.price,
      valid_from: p.validFrom,
      onec_document_ref: p.doc,
      synced_at: scope.syncedAt.toISOString(),
      source_hash: hash,
      hash,
    });
    tracker?.scopeIds.add(pl);
  }
  const items = [...keyed.entries()];
  const existing = new Map<string, { id: string; hash: string }>();
  for (let i = 0; i < items.length; i += 5000) {
    const chunk = items.slice(i, i + 5000).map(([, v]) => v);
    const r = await scope.client.query<{ id: string; k: string; source_hash: string }>(
      `SELECT p.id, p.variant_id::text || '|' || p.price_list_id::text || '|' || coalesce(p.packaging_id::text, '') AS k, p.source_hash
         FROM prices p JOIN jsonb_to_recordset($1::jsonb) AS x(variant_id uuid, price_list_id uuid, packaging_id uuid)
           ON p.variant_id = x.variant_id AND p.price_list_id = x.price_list_id AND p.packaging_id IS NOT DISTINCT FROM x.packaging_id`,
      [
        JSON.stringify(
          chunk.map((c) => ({
            variant_id: c.variant_id,
            price_list_id: c.price_list_id,
            packaging_id: c.packaging_id,
          })),
        ),
      ],
    );
    for (const x of r.rows) existing.set(x.k, { id: x.id, hash: x.source_hash });
  }
  const write: (Record<string, unknown> & { id: string; isNew: boolean })[] = [];
  for (const [k, v] of items) {
    const ex = existing.get(k);
    if (ex) tracker?.seen.add(ex.id);
    if (ex && ex.hash === v.hash) {
      bump(scope, 'prices', 'skipped');
      continue;
    }
    const { hash: _h, ...values } = v;
    const id = ex?.id ?? newId();
    tracker?.seen.add(id);
    write.push({ id, isNew: !ex, ...values });
  }
  const sql = `INSERT INTO prices AS t (id, variant_id, price_list_id, packaging_id, price, valid_from, onec_document_ref, synced_at, source_hash)
    SELECT x.id, x.variant_id, x.price_list_id, x.packaging_id, x.price, x.valid_from, x.onec_document_ref, x.synced_at, x.source_hash
      FROM jsonb_to_recordset($1::jsonb) AS x(id uuid, variant_id uuid, price_list_id uuid, packaging_id uuid, price numeric(14,2),
           valid_from timestamptz, onec_document_ref uuid, synced_at timestamptz, source_hash text)
    ON CONFLICT (variant_id, price_list_id, packaging_id) DO UPDATE SET price = EXCLUDED.price,
           valid_from = EXCLUDED.valid_from, onec_document_ref = EXCLUDED.onec_document_ref,
           synced_at = EXCLUDED.synced_at, source_hash = EXCLUDED.source_hash
     WHERE t.source_hash IS DISTINCT FROM EXCLUDED.source_hash`;
  await writeBatches(scope, 'prices', sql, write);
  for (const w of write) scope.catalogChanges?.prices.add(String(w.variant_id));
}

/**
 * Строки среза остатков (`Balance` / `CatalogStock`) → `stock_balances` (PK `variant_id, warehouse_id`):
 * `quantity`, `reserved`, `available_onec` (NULL — 1С не отдаёт, `available = quantity − reserved` вычисляет БД,
 * D-22), `onec_snapshot_at`. Неизменённая строка не перезаписывается (SYNC-014).
 */
export async function applyStockRows(
  scope: ApplyScope,
  rows: readonly OnecStockRow[],
  tracker?: SliceTracker,
): Promise<void> {
  if (rows.length === 0) return;
  bump(scope, 'stock_balances', 'fetched', rows.length);
  const parsed: {
    warehouseRef: string;
    productRef: string;
    variantRef: string | null;
    q: string;
    r: string;
    a: string | null;
  }[] = [];
  for (const row of rows) {
    try {
      parsed.push({
        warehouseRef: requiredRef(row.warehouseRef, 'warehouseRef'),
        productRef: requiredRef(row.productRef, 'productRef'),
        variantRef: onecRef(row.variantRef, 'variantRef'),
        q: milliToNumeric(qtyToMilli(row.onHand, 'onHand')),
        r: milliToNumeric(qtyToMilli(row.reserved ?? '0', 'reserved')),
        a:
          row.available === null || row.available === undefined
            ? null
            : milliToNumeric(qtyToMilli(row.available, 'available')),
      });
    } catch (e) {
      itemError(scope, 'stock_balances', {
        errorCode: 'VALIDATION',
        severity: 'error',
        message: msg(e),
        onecRef: safeRef(row.productRef),
      });
    }
  }
  const whs = await idsByRef(
    scope.client,
    'warehouses',
    parsed.map((p) => p.warehouseRef),
  );
  const { byVariant, byProduct } = await resolveVariants(scope, parsed);
  const snapshot = (scope.snapshotAt ?? scope.syncedAt).toISOString();
  const keyed = new Map<string, Record<string, unknown> & { hash: string }>();
  const missingWh = new Set<string>();
  for (const p of parsed) {
    const wh = whs.get(p.warehouseRef);
    const variantId = p.variantRef ? byVariant.get(p.variantRef) : byProduct.get(p.productRef);
    if (!wh) {
      if (!missingWh.has(p.warehouseRef)) {
        missingWh.add(p.warehouseRef);
        itemError(scope, 'stock_balances', {
          errorCode: 'NOT_FOUND_LOCAL',
          severity: 'error',
          message: 'склад не найден в реплике warehouses',
          onecRef: p.warehouseRef,
        });
      }
      continue;
    }
    if (!variantId) {
      itemError(scope, 'stock_balances', {
        errorCode: 'NOT_FOUND_LOCAL',
        severity: 'error',
        message: 'вариант остатка не найден в реплике',
        onecRef: p.variantRef ?? p.productRef,
      });
      continue;
    }
    const hash = stockHash(p.q, p.r, p.a);
    keyed.set(`${variantId}|${wh}`, {
      variant_id: variantId,
      warehouse_id: wh,
      quantity: p.q,
      reserved: p.r,
      available_onec: p.a,
      onec_snapshot_at: snapshot,
      synced_at: scope.syncedAt.toISOString(),
      source_hash: hash,
      hash,
    });
    tracker?.scopeIds.add(wh);
  }
  const items = [...keyed.entries()];
  const existing = new Map<string, string>();
  for (let i = 0; i < items.length; i += 5000) {
    const chunk = items.slice(i, i + 5000).map(([, v]) => ({ variant_id: v.variant_id, warehouse_id: v.warehouse_id }));
    const r = await scope.client.query<{ k: string; source_hash: string }>(
      `SELECT s.variant_id::text || '|' || s.warehouse_id::text AS k, s.source_hash
         FROM stock_balances s JOIN jsonb_to_recordset($1::jsonb) AS x(variant_id uuid, warehouse_id uuid)
           ON s.variant_id = x.variant_id AND s.warehouse_id = x.warehouse_id`,
      [JSON.stringify(chunk)],
    );
    for (const x of r.rows) existing.set(x.k, x.source_hash);
  }
  const write: (Record<string, unknown> & { id: string; isNew: boolean })[] = [];
  for (const [k, v] of items) {
    tracker?.seen.add(k);
    const ex = existing.get(k);
    if (ex === v.hash) {
      bump(scope, 'stock_balances', 'skipped');
      continue;
    }
    const { hash: _h, ...values } = v;
    write.push({ id: k, isNew: ex === undefined, ...values });
  }
  const sql = `INSERT INTO stock_balances AS t (variant_id, warehouse_id, quantity, reserved, available_onec, onec_snapshot_at, synced_at, source_hash)
    SELECT x.variant_id, x.warehouse_id, x.quantity, x.reserved, x.available_onec, x.onec_snapshot_at, x.synced_at, x.source_hash
      FROM jsonb_to_recordset($1::jsonb) AS x(variant_id uuid, warehouse_id uuid, quantity numeric(14,3), reserved numeric(14,3),
           available_onec numeric(14,3), onec_snapshot_at timestamptz, synced_at timestamptz, source_hash text)
    ON CONFLICT (variant_id, warehouse_id) DO UPDATE SET quantity = EXCLUDED.quantity, reserved = EXCLUDED.reserved,
           available_onec = EXCLUDED.available_onec, onec_snapshot_at = EXCLUDED.onec_snapshot_at,
           synced_at = EXCLUDED.synced_at, source_hash = EXCLUDED.source_hash
     WHERE t.source_hash IS DISTINCT FROM EXCLUDED.source_hash`;
  await writeBatches(scope, 'stock_balances', sql, write);
  for (const w of write) scope.catalogChanges?.stock.add(String(w.variant_id));
}

/** Хэш строки остатка (без момента снимка: неизменённый остаток не получает новой версии, SYNC-014). */
export function stockHash(q: string, r: string, a: string | null): string {
  return sourceHash({ q, r, a });
}

/** Конец полного среза цен: цены видов цен среза, не встреченные в нём, удаляются физически (07 §5.27). */
export async function finishPriceSlice(scope: ApplyScope, tracker: SliceTracker): Promise<number> {
  if (tracker.incomplete || tracker.scopeIds.size === 0) return 0;
  const r = await scope.client.query<{ id: string; variant_id: string }>(
    `SELECT id, variant_id FROM prices WHERE price_list_id = ANY($1::uuid[])`,
    [[...tracker.scopeIds]],
  );
  const goneRows = r.rows.filter((x) => !tracker.seen.has(x.id));
  for (const x of goneRows) scope.catalogChanges?.prices.add(x.variant_id);
  const gone = goneRows.map((x) => x.id);
  let deleted = 0;
  for (let i = 0; i < gone.length; i += 5000) {
    const d = await scope.client.query(`DELETE FROM prices WHERE id = ANY($1::uuid[])`, [gone.slice(i, i + 5000)]);
    deleted += d.rowCount ?? 0;
  }
  bump(scope, 'prices', 'markedDeleted', deleted);
  await flushErrors(scope);
  return deleted;
}

/** Конец полного среза остатков: строки складов среза, не встреченные в нём, обнуляются (05 §5.3: «строка → 0»). */
export async function finishStockSlice(scope: ApplyScope, tracker: SliceTracker): Promise<number> {
  if (tracker.incomplete || tracker.scopeIds.size === 0) return 0;
  const r = await scope.client.query<{ k: string; variant_id: string; warehouse_id: string }>(
    `SELECT variant_id::text || '|' || warehouse_id::text AS k, variant_id, warehouse_id FROM stock_balances
      WHERE warehouse_id = ANY($1::uuid[]) AND (quantity <> 0 OR reserved <> 0 OR available_onec IS NOT NULL)`,
    [[...tracker.scopeIds]],
  );
  const gone = r.rows.filter((x) => !tracker.seen.has(x.k));
  for (const g of gone) scope.catalogChanges?.stock.add(g.variant_id);
  let zeroed = 0;
  const zeroHash = stockHash('0.000', '0.000', null);
  for (let i = 0; i < gone.length; i += BATCH) {
    const u = await scope.client.query(
      `UPDATE stock_balances s SET quantity = 0, reserved = 0, available_onec = NULL, source_hash = $2,
              onec_snapshot_at = $3, synced_at = $4
         FROM jsonb_to_recordset($1::jsonb) AS x(variant_id uuid, warehouse_id uuid)
        WHERE s.variant_id = x.variant_id AND s.warehouse_id = x.warehouse_id`,
      [
        JSON.stringify(
          gone.slice(i, i + BATCH).map((g) => ({ variant_id: g.variant_id, warehouse_id: g.warehouse_id })),
        ),
        zeroHash,
        (scope.snapshotAt ?? scope.syncedAt).toISOString(),
        scope.syncedAt.toISOString(),
      ],
    );
    zeroed += u.rowCount ?? 0;
  }
  bump(scope, 'stock_balances', 'markedDeleted', zeroed);
  await flushErrors(scope);
  return zeroed;
}

async function writeBatches(
  scope: ApplyScope,
  table: 'prices' | 'stock_balances',
  sql: string,
  write: readonly (Record<string, unknown> & { id: string; isNew: boolean })[],
): Promise<void> {
  const body = (b: readonly Record<string, unknown>[]): string =>
    JSON.stringify(b.map(({ isNew: _n, ...rest }) => rest));
  for (let i = 0; i < write.length; i += BATCH) {
    const batch = write.slice(i, i + BATCH);
    try {
      await inSavepoint(scope.client, () => scope.client.query(sql, [body(batch)]));
      count(scope, table, batch);
    } catch {
      for (const row of batch) {
        try {
          await inSavepoint(scope.client, () => scope.client.query(sql, [body([row])]));
          count(scope, table, [row]);
        } catch (e) {
          itemError(scope, table, {
            errorCode: 'VALIDATION',
            severity: 'error',
            message: dbMessage(e),
            localId: (row.variant_id as string) ?? null,
          });
        }
      }
    }
  }
  await flushErrors(scope);
}

function count(scope: ApplyScope, table: 'prices' | 'stock_balances', rows: readonly { isNew: boolean }[]): void {
  const ins = rows.filter((r) => r.isNew).length;
  bump(scope, table, 'inserted', ins);
  bump(scope, table, 'updated', rows.length - ins);
}

function msg(e: unknown): string {
  return e instanceof OnecValueError ? e.message : dbMessage(e);
}

function safeRef(v: unknown): string | null {
  try {
    return onecRef(v);
  } catch {
    return null;
  }
}
