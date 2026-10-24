import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import type { ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { dec, isoOf, latest, qtyOf } from '../common/catalog-format.js';
import { isUuidString, validationFailed } from '../common/catalog-query.js';
import type { CatalogSnapshot } from '../common/catalog-snapshot.js';
import type { CatalogViewer } from '../common/catalog-viewer.js';
import { projectStock, type StockBalanceDto, type StockLevel, stockLevelOf } from '../common/stock-projection.js';

export const INVENTORY_MAX_ITEMS = 200;

export interface InventoryCheckLine {
  readonly variantId: string;
  readonly value: string;
  readonly unitId: string;
  readonly packagingId: string | null;
}

export interface InventoryCheckInput {
  readonly warehouseId: string;
  readonly items: readonly InventoryCheckLine[];
}

export interface InventoryShortageDto {
  readonly variantId: string;
  readonly requestedBase?: string;
  readonly available?: string;
  readonly unitId?: string;
  readonly stockLevel: StockLevel;
}

export interface InventoryCheckResult {
  readonly ok: boolean;
  readonly shortages: InventoryShortageDto[];
  readonly unavailable: string[];
  readonly asOf?: string;
}

const QTY_RE = /^\d{1,11}(\.\d{1,3})?$/;

/** Разбор тела `POST /inventory/check` (OpenAPI `InventoryCheckRequest`, `additionalProperties: false`). */
export function parseInventoryCheck(body: unknown): InventoryCheckInput {
  const errors: ProblemFieldError[] = [];
  const err = (field: string, rule: string, message: string) => errors.push({ field, rule, message });
  const obj = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
  if (!obj(body)) validationFailed([{ field: '$', rule: 'type', message: 'Тело запроса — объект JSON.' }]);
  for (const k of Object.keys(body)) {
    if (k !== 'warehouseId' && k !== 'items') err(k, 'additional_properties', `Поле ${k} не допускается.`);
  }
  if (!isUuidString(body.warehouseId)) err('warehouseId', 'format', 'warehouseId — UUID склада.');
  const items: InventoryCheckLine[] = [];
  if (!Array.isArray(body.items)) err('items', 'type', 'items — массив строк.');
  else {
    if (body.items.length < 1) err('items', 'min_items', 'Нужна хотя бы одна строка.');
    if (body.items.length > INVENTORY_MAX_ITEMS) {
      err('items', 'max_items', `Не более ${INVENTORY_MAX_ITEMS} строк (максимум строк корзины).`);
    }
    body.items.slice(0, INVENTORY_MAX_ITEMS).forEach((it, i) => {
      const f = `items[${i}]`;
      if (!obj(it)) return err(f, 'type', 'Строка — объект.');
      for (const k of Object.keys(it)) {
        if (k !== 'variantId' && k !== 'quantity')
          err(`${f}.${k}`, 'additional_properties', `Поле ${k} не допускается.`);
      }
      if (!isUuidString(it.variantId)) err(`${f}.variantId`, 'format', 'variantId — UUID варианта.');
      const qn = it.quantity;
      if (!obj(qn)) return err(`${f}.quantity`, 'type', 'quantity — объект Quantity.');
      for (const k of Object.keys(qn)) {
        if (!['value', 'unitId', 'packagingId', 'baseValue'].includes(k)) {
          err(`${f}.quantity.${k}`, 'additional_properties', `Поле ${k} не допускается.`);
        }
      }
      if (typeof qn.value !== 'string' || !QTY_RE.test(qn.value)) {
        err(`${f}.quantity.value`, 'quantity_format', 'Количество строкой, не более 3 знаков после точки.');
      }
      if (!isUuidString(qn.unitId)) err(`${f}.quantity.unitId`, 'format', 'unitId — UUID единицы.');
      if (qn.packagingId !== undefined && qn.packagingId !== null && !isUuidString(qn.packagingId)) {
        err(`${f}.quantity.packagingId`, 'format', 'packagingId — UUID упаковки или null.');
      }
      if (typeof it.variantId === 'string' && typeof qn.value === 'string' && typeof qn.unitId === 'string') {
        items.push({
          variantId: it.variantId.toLowerCase(),
          value: qn.value,
          unitId: qn.unitId.toLowerCase(),
          packagingId: typeof qn.packagingId === 'string' ? qn.packagingId.toLowerCase() : null,
        });
      }
    });
  }
  if (errors.length > 0) validationFailed(errors);
  return { warehouseId: (body.warehouseId as string).toLowerCase(), items };
}

interface VariantInfo {
  id: string;
  product_id: string;
  sellable: boolean;
  deleted: boolean;
  base_unit_id: string;
  qty_precision: number; // money-double: allow — число знаков после запятой (0…3), не количество
  has_price: boolean;
}

/**
 * Остатки и проверка доступности (08 §4.6; D-22, 10 INV-020…INV-028, INV-052, CUST-022): `available` считает
 * сервер (`stock_balances.available` — значение 1С или `quantity − reserved`), клиент — никогда. Проверка корзины
 * ничего не резервирует и не пишет (SRC-C-076). Нет снимка остатка → `stockLevel: unknown`, такая строка — нехватка
 * («Остаток неизвестен», добавление запрещено — INV-052).
 */
@Injectable()
export class InventoryService {
  constructor(@Inject(PG_POOL) private readonly pool: pg.Pool) {}

  /** `GET /inventory/balances`: строка на пару (вариант, склад); вариант без снимка на складе → `unknown`. */
  async balances(
    viewer: CatalogViewer,
    variantIds: readonly string[],
    warehouseId: string | undefined,
    snap: CatalogSnapshot,
  ): Promise<{ items: StockBalanceDto[]; asOf?: string; source: 'snapshot' }> {
    const [variants, warehouses] = await Promise.all([
      this.pool.query<{ id: string; unit_id: string }>(
        `SELECT v.id, p.base_unit_id AS unit_id FROM product_variants v JOIN products p ON p.id = v.product_id
          WHERE v.id = ANY($1::uuid[]) ${viewer.isCustomer ? 'AND NOT v.deletion_mark AND NOT p.deletion_mark' : ''}`,
        [variantIds],
      ),
      this.pool.query<{ id: string; name: string }>(
        warehouseId
          ? `SELECT id, name FROM warehouses WHERE id = $1::uuid AND NOT deletion_mark`
          : `SELECT id, name FROM warehouses WHERE is_active AND NOT deletion_mark ORDER BY sort_order, name, id`,
        warehouseId ? [warehouseId] : [],
      ),
    ]);
    if (warehouseId && warehouses.rows.length === 0) {
      validationFailed([{ field: 'warehouseId', rule: 'unknown_reference', message: 'Склад не найден.' }]);
    }
    const unitOf = new Map(variants.rows.map((v) => [v.id, v.unit_id]));
    const ordered = variantIds.filter((id) => unitOf.has(id));
    const stock = await this.pool.query<{
      variant_id: string;
      warehouse_id: string;
      q: string;
      r: string;
      a: string;
      at: Date;
    }>(
      `SELECT variant_id, warehouse_id, quantity::text AS q, reserved::text AS r, available::text AS a,
              onec_snapshot_at AS at
         FROM stock_balances WHERE variant_id = ANY($1::uuid[]) AND warehouse_id = ANY($2::uuid[])`,
      [ordered, warehouses.rows.map((w) => w.id)],
    );
    const byKey = new Map(stock.rows.map((s) => [`${s.variant_id}|${s.warehouse_id}`, s]));
    const items: StockBalanceDto[] = [];
    for (const variantId of ordered) {
      for (const w of warehouses.rows) {
        const s = byKey.get(`${variantId}|${w.id}`);
        items.push(
          projectStock(
            viewer,
            { variantId, warehouseId: w.id, warehouseName: w.name, unitId: unitOf.get(variantId) },
            s ? { quantity: s.q, reserved: s.r, available: s.a, asOf: latest(s.at, snap.stockAsOf) } : null,
          ),
        );
      }
    }
    const asOf = isoOf(snap.stockAsOf);
    return { items, ...(asOf ? { asOf } : {}), source: 'snapshot' };
  }

  /** `POST /inventory/check`: нехватки по складу корзины; недоступные варианты — `unavailable[]` (без побочных эффектов). */
  async check(viewer: CatalogViewer, input: InventoryCheckInput, snap: CatalogSnapshot): Promise<InventoryCheckResult> {
    const wh = await this.pool.query<{ id: string }>(
      `SELECT id FROM warehouses WHERE id = $1::uuid AND NOT deletion_mark AND is_active`,
      [input.warehouseId],
    );
    if (wh.rows.length === 0) {
      validationFailed([{ field: 'warehouseId', rule: 'unknown_reference', message: 'Склад не найден.' }]);
    }
    const variantIds = [...new Set(input.items.map((i) => i.variantId))];
    const packagingIds = [...new Set(input.items.map((i) => i.packagingId).filter((p): p is string => p !== null))];
    const [variants, packagings, stock] = await Promise.all([
      this.pool.query<VariantInfo>(
        `SELECT v.id, v.product_id, (v.is_default = NOT p.has_variants) AS sellable,
                (v.deletion_mark OR p.deletion_mark OR NOT p.is_sellable) AS deleted,
                p.base_unit_id, u.qty_precision,
                EXISTS (SELECT 1 FROM prices x WHERE x.variant_id = v.id AND x.price_list_id = $2::uuid
                           AND x.packaging_id IS NULL) AS has_price
           FROM product_variants v JOIN products p ON p.id = v.product_id JOIN units u ON u.id = p.base_unit_id
          WHERE v.id = ANY($1::uuid[])`,
        [variantIds, viewer.priceList?.id ?? null],
      ),
      this.pool.query<{
        id: string;
        product_id: string | null;
        unit_id: string;
        factor: string;
        allow_fraction: boolean;
        deletion_mark: boolean;
      }>(
        `SELECT id, product_id, unit_id, factor::text AS factor, allow_fraction, deletion_mark
           FROM packagings WHERE id = ANY($1::uuid[])`,
        [packagingIds],
      ),
      this.pool.query<{ variant_id: string; a: string; at: Date }>(
        `SELECT variant_id, available::text AS a, onec_snapshot_at AS at
           FROM stock_balances WHERE warehouse_id = $1::uuid AND variant_id = ANY($2::uuid[])`,
        [input.warehouseId, variantIds],
      ),
    ]);
    const vmap = new Map(variants.rows.map((v) => [v.id, v]));
    const pmap = new Map(packagings.rows.map((p) => [p.id, p]));
    const smap = new Map(stock.rows.map((s) => [s.variant_id, s]));
    const errors: ProblemFieldError[] = [];
    const unavailable = new Set<string>();
    const requested = new Map<string, ReturnType<typeof dec>>();
    input.items.forEach((line, i) => {
      const v = vmap.get(line.variantId);
      // Нет варианта, снят с продажи, служебный вариант товара с характеристиками, нет цены — недоступен (08 §4.6.2).
      if (!v || v.deleted || !v.sellable || (viewer.canReadPrice && !v.has_price)) {
        unavailable.add(line.variantId);
        return;
      }
      const f = `items[${i}].quantity`;
      let base = dec(line.value);
      if (line.packagingId !== null) {
        const pk = pmap.get(line.packagingId);
        if (!pk || pk.deletion_mark || pk.product_id !== v.product_id) {
          errors.push({
            field: `${f}.packagingId`,
            rule: 'packaging_mismatch',
            message: 'Упаковка не относится к товару.',
          });
          return;
        }
        if (line.unitId !== pk.unit_id && line.unitId !== v.base_unit_id) {
          errors.push({ field: `${f}.unitId`, rule: 'unit_mismatch', message: 'Единица не совпадает с упаковкой.' });
          return;
        }
        if (!pk.allow_fraction && !base.isInteger()) {
          errors.push({ field: `${f}.value`, rule: 'qty_precision', message: 'Количество упаковок — целое число.' });
          return;
        }
        base = base.times(dec(pk.factor)).toDecimalPlaces(3);
      } else {
        if (line.unitId !== v.base_unit_id) {
          errors.push({
            field: `${f}.unitId`,
            rule: 'unit_mismatch',
            message: 'Единица не совпадает с базовой единицей товара.',
          });
          return;
        }
        if (base.decimalPlaces() > v.qty_precision) {
          errors.push({
            field: `${f}.value`,
            rule: 'qty_precision',
            message: `Для единицы допустимо не более ${v.qty_precision} знаков после запятой.`,
          });
          return;
        }
      }
      requested.set(line.variantId, (requested.get(line.variantId) ?? dec(0)).plus(base));
    });
    if (errors.length > 0) validationFailed(errors);
    const shortages: InventoryShortageDto[] = [];
    for (const [variantId, need] of requested) {
      if (unavailable.has(variantId)) continue;
      const s = smap.get(variantId);
      const level = stockLevelOf(s?.a, viewer.lowStockThreshold);
      if (s && dec(s.a).gte(need)) continue;
      const unitId = vmap.get(variantId)?.base_unit_id;
      shortages.push(this.shortageFor(viewer, variantId, need.toFixed(3), s ? qtyOf(s.a) : undefined, unitId, level));
    }
    const asOf = isoOf(latest(snap.stockAsOf, ...stock.rows.map((s) => s.at)));
    return {
      ok: shortages.length === 0 && unavailable.size === 0,
      shortages,
      unavailable: [...unavailable],
      ...(asOf ? { asOf } : {}),
    };
  }

  /** `InventoryShortage` по роли: customer при `status` — только `variantId` и `stockLevel` (08 §4.6.2, §3.6). */
  private shortageFor(
    viewer: CatalogViewer,
    variantId: string,
    requestedBase: string,
    available: string | undefined,
    unitId: string | undefined,
    stockLevel: StockLevel,
  ): InventoryShortageDto {
    if (viewer.stockDisplay === 'status') return { variantId, stockLevel };
    return {
      variantId,
      requestedBase,
      ...(available !== undefined ? { available } : {}),
      ...(unitId && viewer.stockDisplay === 'full' ? { unitId } : {}),
      stockLevel,
    };
  }
}
