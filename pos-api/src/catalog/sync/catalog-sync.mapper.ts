import { imageOf, moneyOf, qtyOf } from '../common/catalog-format.js';
import type { CatalogViewer } from '../common/catalog-viewer.js';
import { projectStock } from '../common/stock-projection.js';
import type { SyncRow } from './catalog-sync.queries.js';
import type { CatalogSyncEntity } from './catalog-sync.types.js';

/**
 * Элементы `items[]` выгрузки (08 §4.24; OpenAPI `x-entity-schema` у `CatalogSyncResponse`): полная карточка объекта
 * без вычисляемых цен/остатков и полей пользователя. Необязательные поля без значения не выводятся (в контракте они
 * не `nullable`); `nullable`-поля (`parentId`, `minQuantity`, `multiplicity`, `packagingId`, `barcode`) — `null`.
 * Деньги и количества — строками из NUMERIC через decimal.js (D-19), без float.
 *
 * Дополнительно к контракту (EQ-CSYNC-02): `id` у `barcodes`, `prices`, `images` (ключ для `deleted[]`, где по
 * контракту — uuid объекта), `productId` у `packagings`/`barcodes` (EQ-FEF-02), `path`/`depth`/`isVisible`/`updatedAt`
 * у `categories` (EQ-FEF-03), `isDefaultForPos`/`shortName`/`sortOrder` у `warehouses` (EQ-FEF-12),
 * `multiplicity`/`isSellable` у `products`, `valueType`/`isVariantAxis`/`isFilterable`/`sortOrder` у `attributes`.
 */
export type SyncItem = Record<string, unknown>;

export interface MapContext {
  readonly viewer: CatalogViewer;
  /** Время среза остатков/цен (`sync_state.last_success_at`, EQ-ONEC-03) — нижняя граница `asOf`. */
  readonly stockAsOf?: Date;
  readonly pricesAsOf?: Date;
}

const str = (v: unknown): string | undefined => (typeof v === 'string' && v !== '' ? v : undefined);
const nul = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
const iso = (v: unknown): string | undefined => (v instanceof Date ? v.toISOString() : undefined);

function put(o: SyncItem, key: string, v: unknown): void {
  if (v !== undefined) o[key] = v;
}

function later(a: unknown, b: Date | undefined): string | undefined {
  const d = a instanceof Date ? a : undefined;
  if (d && b) return (d.getTime() >= b.getTime() ? d : b).toISOString();
  return (d ?? b)?.toISOString();
}

/** `products.attributes` `{code: {name, value, type}}` / `product_variants.attributes` `{code: value}` → `{code: string}`. */
function attrMap(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return out;
  for (const [code, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === 'string') out[code] = v;
    else if (typeof v === 'number' || typeof v === 'boolean') out[code] = String(v);
    else if (v !== null && typeof v === 'object' && 'value' in v) {
      const value = v.value;
      if (typeof value === 'string') out[code] = value;
      else if (typeof value === 'number' || typeof value === 'boolean') out[code] = String(value);
    }
  }
  return out;
}

/** Строка выгрузки → элемент `items[]` (или `undefined` — строку отдать нельзя, она уходит в `deleted[]`). */
export function toSyncItem(entity: CatalogSyncEntity, r: SyncRow, ctx: MapContext): SyncItem | undefined {
  switch (entity) {
    case 'units':
      return { id: r.id, code: r.code, name: r.name, shortName: r.name, qtyPrecision: r.qty_precision };
    case 'warehouses': {
      const o: SyncItem = { id: r.id, name: r.name };
      put(o, 'code', str(r.onec_code));
      o.isActive = r.is_active;
      put(o, 'shortName', str(r.short_name));
      o.isDefaultForPos = r.is_default_for_pos;
      o.sortOrder = r.sort_order;
      return o;
    }
    case 'categories': {
      const o: SyncItem = { id: r.id, parentId: nul(r.parent_id), name: r.name };
      put(o, 'code', str(r.onec_code));
      o.productCount = r.product_count_cache;
      o.sortOrder = r.sort_order;
      put(o, 'iconKey', str(r.icon_key));
      o.imageUrl = typeof r.image_sha === 'string' ? (imageOf({ sha: r.image_sha })?.cardUrl ?? null) : null;
      o.hasChildren = r.has_children === true;
      o.deletionMark = false;
      put(o, 'onecRef', str(r.onec_ref));
      o.path = r.path;
      o.depth = r.depth;
      o.isVisible = r.is_visible;
      put(o, 'updatedAt', iso(r.updated_at));
      return o;
    }
    case 'products': {
      const o: SyncItem = { id: r.id, name: r.name };
      put(o, 'sku', str(r.sku));
      put(o, 'categoryId', str(r.category_id));
      put(o, 'brand', str(r.brand));
      o.hasVariants = r.has_variants;
      put(o, 'defaultVariantId', str(r.default_variant_id));
      o.baseUnit = {
        id: r.base_unit_id,
        code: r.unit_code,
        name: r.unit_name,
        shortName: r.unit_name,
        qtyPrecision: r.qty_precision,
      };
      put(o, 'description', str(r.description));
      o.attributes = attrMap(r.attributes);
      o.imageIds = Array.isArray(r.image_ids) ? r.image_ids : [];
      o.barcodes = Array.isArray(r.barcodes) ? r.barcodes : [];
      o.minQuantity = typeof r.min_qty === 'string' ? qtyOf(r.min_qty) : null;
      o.multiplicity = typeof r.multiplicity === 'string' ? qtyOf(r.multiplicity) : null;
      o.isSellable = r.is_sellable;
      put(o, 'onecCode', str(r.onec_code));
      o.deletionMark = false;
      put(o, 'updatedAt', iso(r.updated_at));
      return o;
    }
    case 'variants': {
      const o: SyncItem = { id: r.id, productId: r.product_id, isDefault: r.is_default };
      put(o, 'name', typeof r.name === 'string' ? r.name : undefined);
      put(o, 'sku', str(r.sku));
      o.attributes = attrMap(r.attributes);
      o.barcodes = Array.isArray(r.barcodes) ? r.barcodes : [];
      o.multiplicity = typeof r.multiplicity === 'string' ? qtyOf(r.multiplicity) : null;
      o.unitId = r.base_unit_id;
      o.sortOrder = r.sort_order;
      o.deletionMark = false;
      return o;
    }
    case 'packagings': {
      // `variantId` обязателен (OpenAPI `CatalogSyncPackaging`): упаковка 07 принадлежит товару — служебный
      // вариант товара (EQ-ONEC-07); у товара без вариантов упаковку отдать нельзя.
      if (typeof r.variant_id !== 'string') return undefined;
      return {
        id: r.id,
        unitId: r.unit_id,
        name: r.name,
        factor: qtyOf(String(r.factor)),
        isDefault: r.is_default,
        allowFraction: r.allow_fraction,
        barcode: nul(r.barcode),
        variantId: r.variant_id,
        productId: r.product_id,
        sortOrder: r.sort_order,
      };
    }
    case 'barcodes':
      return {
        id: r.id,
        barcode: r.value,
        variantId: r.variant_id,
        packagingId: nul(r.packaging_id),
        type: r.type,
        productId: r.product_id,
      };
    case 'price_lists': {
      const o: SyncItem = { id: r.id, name: r.name };
      put(o, 'code', str(r.onec_code));
      o.currency = typeof r.currency === 'string' ? r.currency.trim() : 'KGS';
      o.isDefault = r.is_default;
      o.visibleToRoles = Array.isArray(r.visible_to_roles) ? r.visible_to_roles : [];
      return o;
    }
    case 'prices': {
      const o: SyncItem = {
        id: r.id,
        priceListId: r.price_list_id,
        priceListName: r.price_list_name,
        packagingId: nul(r.packaging_id),
        price: moneyOf(String(r.price)),
      };
      put(o, 'validFrom', iso(r.valid_from));
      put(o, 'asOf', later(r.synced_at, ctx.pricesAsOf));
      o.variantId = r.variant_id;
      return o;
    }
    case 'stock':
      return {
        ...projectStock(
          ctx.viewer,
          {
            variantId: String(r.variant_id),
            warehouseId: String(r.warehouse_id),
            warehouseName: String(r.warehouse_name),
            unitId: str(r.unit_id),
          },
          {
            quantity: String(r.quantity),
            reserved: String(r.reserved),
            available: String(r.available),
            asOf: (() => {
              const a = later(r.onec_snapshot_at, ctx.stockAsOf);
              return a ? new Date(a) : undefined;
            })(),
          },
        ),
      };
    case 'attributes': {
      const o: SyncItem = {
        id: r.id,
        code: r.code,
        name: r.name,
        values: Array.isArray(r.attr_values) ? r.attr_values : [],
        valueType: r.value_type,
      };
      put(o, 'unitLabel', str(r.unit_label));
      o.isFilterable = r.is_filterable;
      o.isVariantAxis = r.is_variant_axis;
      o.sortOrder = r.sort_order;
      return o;
    }
    case 'images': {
      // URL фото — общая функция каталога (`imageOf`, RM-E-004; префикс пути — EQ-IMG-06).
      const img = typeof r.sha === 'string' ? imageOf({ sha: r.sha, is_primary: r.is_primary === true }) : undefined;
      if (!img) return undefined;
      const o: SyncItem = { id: r.id, ...img, isPrimary: r.is_primary === true };
      if (typeof r.width === 'number') o.width = r.width;
      if (typeof r.height === 'number') o.height = r.height;
      o.productId = r.product_id;
      o.variantId = nul(r.variant_id);
      o.sortOrder = r.sort_order;
      return o;
    }
  }
}
