import { newId } from '../../common/ids/uuid.js';
import type {
  OnecAttributeValue,
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecObjectDeletionItem,
  OnecPackagingItem,
  OnecPriceListItem,
  OnecUnitItem,
  OnecVariantItem,
  OnecWarehouseItem,
} from '../../integrations/onec/onec-catalog.types.js';
import { ONEC_CHANGE_TYPES } from '../../integrations/onec/onec-catalog.types.js';
import { ProductImageRepository } from '../images/product-image.repository.js';
import type { ApplyScope, CatalogTable } from './apply.types.js';
import { TABLE_ENTITY } from './apply.types.js';
import {
  attributeCode,
  attributeValueType,
  BARCODE_VALUE_RE,
  barcodeType,
  bool,
  milliToNumeric,
  onecRef,
  OnecValueError,
  qtyToMilli,
  requiredRef,
  requiredText,
  sourceHash,
  text,
  unitPrecision,
} from './onec-values.js';
import {
  bump,
  type Column,
  dbMessage,
  existingByKey,
  flushErrors,
  idsByRef,
  inSavepoint,
  itemError,
  type ReplicaRow,
  type ReplicaSpec,
  upsertReplica,
  upsertVersions,
} from './replica-writer.js';

/** Состояние применения одного сообщения / прогона: отложенные позиции, перечитка цен, «грязные» производные. */
export interface ApplyState {
  /** Позиции с неразрешёнными ссылками (родитель/единица/товар ещё не пришли) — повтор в конце сообщения. */
  readonly deferred: OnecCatalogItem[];
  /** Виды цен, срез которых перечитать (`Document_УстановкаЦенНоменклатуры`, 05 §6.2, SYNC-015). */
  readonly priceListsToRefresh: Set<string>;
  /** Элементы не каталога (клиенты, документы, файлы картинок, QR) — для обработчиков других модулей. */
  readonly foreign: Readonly<Record<string, unknown>>[];
  readonly dirty: { categories: boolean; products: Set<string>; variantOwners: Set<string>; counters: boolean };
  /**
   * Штрихкоды прогона (05 ONEC-017 п. 2): значение → привязка `barcodes` до прогона и все привязки, пришедшие
   * в прогоне (страницы полной перечитки / страницы сообщения `/changes`) — выбор не зависит от порядка пакетов.
   */
  readonly barcodes: Map<string, BarcodeRunEntry>;
}

/** Привязка штрихкода из регистра 1С (кандидат правила ONEC-017). */
interface BarcodeCandidate {
  readonly item: OnecBarcodeItem;
  readonly value: string;
  readonly productRef: string;
  readonly variantRef: string | null;
  readonly packRef: string | null;
  readonly type: string;
  /** Ключ сравнения «наименьший ключ»: `Номенклатура_Key|Характеристика_Key|Упаковка_Key`. */
  readonly bkey: string;
}

export interface BarcodeRunEntry {
  /** Действующая привязка `barcodes` (локальные id) на момент первой встречи значения в прогоне; `null` — нет. */
  readonly current: { productId: string; variantId: string; packagingId: string | null } | null;
  readonly candidates: Map<string, BarcodeCandidate>;
}

function bindingKey(productRef: string, variantRef: string | null, packRef: string | null): string {
  return `${productRef}|${variantRef ?? ''}|${packRef ?? ''}`;
}

function refsOf(c: BarcodeCandidate): Record<string, string | null> {
  return { productRef: c.productRef, variantRef: c.variantRef, packagingRef: c.packRef };
}

export function newApplyState(): ApplyState {
  return {
    deferred: [],
    priceListsToRefresh: new Set(),
    foreign: [],
    dirty: { categories: false, products: new Set(), variantOwners: new Set(), counters: false },
    barcodes: new Map(),
  };
}

const STD: readonly Column[] = [
  ['onec_ref', 'uuid'],
  ['onec_code', 'text'],
  ['onec_data_version', 'text'],
  ['deletion_mark', 'boolean'],
  ['synced_at', 'timestamptz'],
  ['source_hash', 'text'],
];

const SPEC = {
  units: {
    table: 'units',
    conflict: 'onec_ref',
    columns: [...STD, ['code', 'text'], ['name', 'text']],
    insertOnly: [['qty_precision', 'smallint']],
  },
  warehouses: { table: 'warehouses', conflict: 'onec_ref', columns: [...STD, ['name', 'text']] },
  price_lists: {
    table: 'price_lists',
    conflict: 'onec_ref',
    columns: [...STD, ['name', 'text'], ['price_includes_vat', 'boolean'], ['is_used_for_sales', 'boolean']],
    insertOnly: [['currency', 'char(3)']],
  },
  categories: {
    table: 'categories',
    conflict: 'onec_ref',
    columns: [...STD, ['parent_id', 'uuid'], ['name', 'text']],
    insertOnly: [
      ['path', 'text'],
      ['depth', 'smallint'],
    ],
  },
  products: {
    table: 'products',
    conflict: 'onec_ref',
    columns: [
      ...STD,
      ['sku', 'text'],
      ['name', 'text'],
      ['full_name', 'text'],
      ['description', 'text'],
      ['category_id', 'uuid'],
      ['base_unit_id', 'uuid'],
      ['is_weighted', 'boolean'],
      ['attributes', 'jsonb'],
      ['brand', 'text'],
      ['onec_image_file_ref', 'uuid'],
    ],
  },
  product_attributes: {
    table: 'product_attributes',
    conflict: 'onec_ref',
    columns: [...STD, ['name', 'text'], ['value_type', 'attribute_value_type']],
    insertOnly: [['code', 'text']],
  },
  product_variants: {
    table: 'product_variants',
    conflict: 'onec_ref',
    columns: [...STD, ['product_id', 'uuid'], ['name', 'text'], ['sku', 'text'], ['attributes', 'jsonb']],
    insertOnly: [['is_default', 'boolean']],
  },
  packagings: {
    table: 'packagings',
    conflict: 'onec_ref',
    columns: [
      ...STD,
      ['product_id', 'uuid'],
      ['packaging_set_ref', 'uuid'],
      ['unit_id', 'uuid'],
      ['name', 'text'],
      ['factor', 'numeric(14,3)'],
    ],
  },
  barcodes: {
    table: 'barcodes',
    conflict: 'value',
    columns: [
      ...STD,
      ['value', 'text'],
      ['product_id', 'uuid'],
      ['variant_id', 'uuid'],
      ['packaging_id', 'uuid'],
      ['type', 'barcode_type'],
    ],
  },
} as const satisfies Record<string, ReplicaSpec>;

/** Объект 1С удаления → таблицы (05 §6.2 п. 1: `ObjectDeletion`; ONEC-102 — только `deletion_mark`). */
const DELETION_TABLES: Readonly<Record<string, readonly CatalogTable[]>> = {
  Catalog_Номенклатура: ['products', 'categories'],
  Catalog_ХарактеристикиНоменклатуры: ['product_variants'],
  Catalog_УпаковкиЕдиницыИзмерения: ['packagings'],
  Catalog_КлассификаторЕдиницИзмерения: ['units'],
  Catalog_Склады: ['warehouses'],
  Catalog_ВидыЦен: ['price_lists'],
  InformationRegister_ШтрихкодыНоменклатуры: ['barcodes'],
};

const KNOWN_TYPES = new Set<string>(ONEC_CHANGE_TYPES);

interface Prepared<T> {
  readonly item: T;
  readonly key: string;
  readonly hash: string;
  readonly values: Record<string, unknown>;
  readonly onecCode: string | null;
}

/**
 * Применение элементов каталога 1С к репликам (RM-E-001; 05 §5.3 словарь полей; 07 §5.B):
 * `units, warehouses, price_lists, categories, products (+packagings), product_attributes, product_variants,
 * variant_attribute_values, barcodes` со стандартным набором `onec_ref, onec_code, onec_data_version,
 * deletion_mark, synced_at, source_hash`. Неизменённое (тот же `source_hash`) не перезаписывается (SYNC-013);
 * удаление — только `deletion_mark` (ONEC-102); ошибка позиции → `sync_errors`, остальные применяются.
 *
 * Транзакцией управляет вызывающий (`ApplyScope.client` уже в `BEGIN`).
 */
export class CatalogApplier {
  private readonly images = new ProductImageRepository();

  /**
   * Применить элементы (страницу `/changes` или страницу полной загрузки) в порядке зависимостей.
   * `final=false` — позиции с неразрешёнными ссылками откладываются в `state.deferred` (повтор в конце сообщения);
   * `final=true` — неразрешённое пишется с NULL (необязательная ссылка) или уходит в `sync_errors`.
   */
  async applyItems(scope: ApplyScope, state: ApplyState, items: readonly unknown[], final = false): Promise<void> {
    const by = groupByType(scope, state, items);
    await this.units(scope, by.units);
    await this.warehouses(scope, by.warehouses);
    await this.priceLists(scope, by.priceLists);
    await this.categories(scope, state, by.folders, final);
    const attrIds = await this.attributes(scope, [...by.products, ...by.variants]);
    await this.products(scope, state, by.products, attrIds, final);
    await this.variants(scope, state, by.variants, attrIds, final);
    await this.packagings(scope, state, by.packagings, final);
    await this.barcodes(scope, state, by.barcodes, final);
    for (const ps of by.priceSettings) {
      for (const r of ps.priceListRefs ?? []) {
        const ref = onecRefSafe(r);
        if (ref) state.priceListsToRefresh.add(ref);
      }
    }
    await this.deletions(scope, state, by.deletions);
    await flushErrors(scope);
  }

  /** Повторить отложенные позиции последним проходом (конец сообщения). */
  async flushDeferred(scope: ApplyScope, state: ApplyState): Promise<void> {
    if (state.deferred.length === 0) return;
    const items = state.deferred.splice(0);
    await this.applyItems(scope, state, items, true);
  }

  // ------------------------------------------------------------------ справочники без ссылок

  private async units(scope: ApplyScope, items: readonly OnecUnitItem[]): Promise<void> {
    const prepared = this.prepare(scope, 'units', items, (it) => {
      const name = requiredText(it.description, 'description');
      const code1c = text(it.code);
      return {
        values: { code: code1c ?? name, name, qty_precision: unitPrecision(code1c, name) },
        hashOf: { code: code1c, name, deletionMark: it.deletionMark },
        onecCode: code1c,
      };
    });
    // UNIQUE units.code: код ОКЕИ уникален в 1С, но защищаемся от дублей (другой Ref_Key с тем же кодом).
    const codes = prepared.map((p) => String(p.values.code));
    const taken = await scope.client.query<{ code: string; ref: string | null }>(
      `SELECT code, onec_ref::text AS ref FROM units WHERE code = ANY($1::text[])`,
      [codes],
    );
    const owner = new Map(taken.rows.map((r) => [r.code, r.ref]));
    for (const p of prepared) {
      const code = String(p.values.code);
      const o = owner.get(code);
      if (o !== undefined && o !== p.key) p.values.code = `${code}~${p.key.slice(0, 8)}`;
      owner.set(String(p.values.code), p.key);
    }
    await this.write(scope, SPEC.units, prepared);
  }

  private async warehouses(scope: ApplyScope, items: readonly OnecWarehouseItem[]): Promise<void> {
    const real = items.filter((it) => it.isFolder !== true);
    bump(scope, 'warehouses', 'skipped', items.length - real.length);
    const prepared = this.prepare(scope, 'warehouses', real, (it) => {
      const name = requiredText(it.description, 'description');
      return {
        values: { name },
        hashOf: { name, code: text(it.code), deletionMark: it.deletionMark },
        onecCode: text(it.code),
      };
    });
    await this.write(scope, SPEC.warehouses, prepared);
  }

  private async priceLists(scope: ApplyScope, items: readonly OnecPriceListItem[]): Promise<void> {
    const prepared = this.prepare(scope, 'price_lists', items, (it) => {
      const name = requiredText(it.description, 'description');
      const currency = text(it.currency) ?? 'KGS';
      // 05 §5.3: цены в валюте ≠ KGS не загружаются; вид цены — тоже (CHECK currency = 'KGS').
      if (currency !== 'KGS') throw new OnecValueError(`валюта вида цены ${currency} ≠ KGS (05 §5.3)`);
      const vat = typeof it.priceIncludesVat === 'boolean' ? it.priceIncludesVat : null;
      const sales = bool(it.usedForSales, true);
      return {
        values: { name, price_includes_vat: vat, is_used_for_sales: sales, currency: 'KGS' },
        hashOf: { name, code: text(it.code), vat, sales, deletionMark: it.deletionMark },
        onecCode: text(it.code),
      };
    });
    await this.linkSeedPriceList(scope, prepared);
    await this.write(scope, SPEC.price_lists, prepared);
  }

  /**
   * Связывание вида цены по умолчанию из seed (`seeds/0001_defaults.sql`: «Розничная», `onec_ref IS NULL`,
   * `source_hash = 'seed:typical'`, `is_default`) с видом цены 1С **того же имени** (без учёта регистра) — до upsert
   * по `onec_ref`: строка seed получает `onec_ref` и обновляется данными 1С, сохраняя `is_default`, `visible_to_roles`
   * и ссылки (клиент «Розничный покупатель»). Без связывания вид цены по умолчанию остался бы пустым дублем без цен,
   * и цены в каталоге не видел бы никто (интеграция этапа E, EQ-INT-03; seed: «связывание по имени — задача RM-E»).
   */
  private async linkSeedPriceList(scope: ApplyScope, prepared: readonly Prepared<OnecPriceListItem>[]): Promise<void> {
    const live = prepared.filter((p) => !p.item.deletionMark);
    if (live.length === 0) return;
    await scope.client.query(
      `UPDATE price_lists p SET onec_ref = x.ref::uuid
         FROM (SELECT DISTINCT ON (lower(n.name)) n.ref, n.name
                 FROM unnest($1::text[], $2::text[]) AS n(ref, name)
                WHERE NOT EXISTS (SELECT 1 FROM price_lists q WHERE q.onec_ref = n.ref::uuid)
                ORDER BY lower(n.name), n.ref) x
        WHERE p.onec_ref IS NULL AND p.source_hash = 'seed:typical' AND NOT p.deletion_mark
          AND lower(p.name) = lower(x.name)`,
      [live.map((p) => p.key), live.map((p) => String(p.values['name']))],
    );
  }

  // ------------------------------------------------------------------ категории (группы номенклатуры)

  private async categories(
    scope: ApplyScope,
    state: ApplyState,
    folders: readonly OnecNomenclatureItem[],
    final: boolean,
  ): Promise<void> {
    if (folders.length === 0) return;
    const prepared = this.prepare(scope, 'categories', folders, (it) => {
      const name = requiredText(it.description, 'description');
      const parentRef = onecRef(it.parentRef, 'parentRef');
      return {
        values: { name, parentRef },
        hashOf: { name, parentRef, code: text(it.code), deletionMark: it.deletionMark },
        onecCode: text(it.code),
      };
    });
    const batch = new Map(prepared.map((p) => [p.key, p]));
    const parentRefs = prepared.map((p) => p.values.parentRef).filter((r): r is string => typeof r === 'string');
    const known = await idsByRef(scope.client, 'categories', [...batch.keys(), ...parentRefs]);
    const existing = await existingByKey(scope.client, 'categories', 'onec_ref', [...batch.keys()]);
    // id новых строк заранее — дети пакета ссылаются на родителя из того же пакета (FK проверяется в конце команды).
    const ids = new Map<string, string>();
    for (const p of prepared) ids.set(p.key, existing.get(p.key)?.id ?? newId());
    const ready: Prepared<OnecNomenclatureItem>[] = [];
    // Родитель: в БД, в пакете (и сам готов), иначе — отложить (не последний проход) или NULL + предупреждение.
    const resolved = new Map<string, 'ok' | 'defer'>();
    const visit = (p: Prepared<OnecNomenclatureItem>, stack: Set<string>): 'ok' | 'defer' => {
      const done = resolved.get(p.key);
      if (done) return done;
      const parentRef = p.values.parentRef as string | null;
      let res: 'ok' | 'defer' = 'ok';
      if (parentRef !== null) {
        const inBatch = batch.get(parentRef);
        if (stack.has(p.key)) {
          res = 'ok';
          p.values.parentRef = null;
          itemError(scope, 'categories', {
            errorCode: 'VALIDATION',
            severity: 'error',
            message: 'цикл в дереве групп номенклатуры — родитель сброшен',
            onecRef: p.key,
            onecCode: p.onecCode,
          });
        } else if (inBatch) {
          stack.add(p.key);
          res = visit(inBatch, stack);
          stack.delete(p.key);
        } else if (!known.has(parentRef)) {
          res = final ? 'ok' : 'defer';
          if (final) {
            p.values.parentRef = null;
            p.values.unresolved = true;
            itemError(scope, 'categories', {
              errorCode: 'NOT_FOUND_LOCAL',
              severity: 'warning',
              message: 'родительская группа не найдена — категория в корне до повторной загрузки (05 §5.3)',
              onecRef: p.key,
              onecCode: p.onecCode,
            });
          }
        }
      }
      resolved.set(p.key, res);
      return res;
    };
    for (const p of prepared) {
      if (visit(p, new Set()) === 'defer') state.deferred.push(p.item);
      else ready.push(p);
    }
    const rows: ReplicaRow[] = ready.map((p) => {
      const id = ids.get(p.key)!;
      const parentRef = p.values.parentRef as string | null;
      const parentId = parentRef === null ? null : (ids.get(parentRef) ?? known.get(parentRef) ?? null);
      const hash = p.values.unresolved ? `unresolved:${p.hash}` : p.hash;
      return this.row(scope, p, existing, id, hash, {
        parent_id: parentId,
        name: p.values.name,
        path: `/${id}`,
        depth: 0,
      });
    });
    const written = await this.writeRows(scope, SPEC.categories, rows, existing);
    if (written > 0) state.dirty.categories = true;
  }

  // ------------------------------------------------------------------ свойства (ДополнительныеРеквизиты)

  /** Справочник свойств по парам «свойство — значение» товаров и характеристик → `propertyRef` → {id, code, type}. */
  private async attributes(
    scope: ApplyScope,
    owners: readonly (OnecNomenclatureItem | OnecVariantItem)[],
  ): Promise<Map<string, { id: string; code: string; type: string }>> {
    const defs = new Map<string, { name: string; valueType: string }>();
    for (const o of owners) {
      for (const a of o.attributes ?? []) {
        const ref = onecRefSafe(a.propertyRef);
        const name = text(a.name);
        if (!ref || !name || defs.has(ref)) continue;
        defs.set(ref, { name, valueType: attributeValueType(a.valueType) });
      }
    }
    if (defs.size === 0) return new Map();
    const existing = await existingByKey(scope.client, 'product_attributes', 'onec_ref', [...defs.keys()]);
    const candidates = [...defs.entries()]
      .filter(([ref]) => !existing.has(ref))
      .map(([ref, d]) => ({ ref, code: attributeCode(d.name) }));
    const taken = await scope.client.query<{ code: string }>(
      `SELECT code FROM product_attributes WHERE code = ANY($1::text[])`,
      [candidates.map((c) => c.code)],
    );
    const used = new Set(taken.rows.map((r) => r.code));
    const codeFor = new Map<string, string>();
    for (const c of candidates) {
      let code = c.code;
      if (used.has(code)) code = `${code}_${c.ref.slice(0, 8)}`;
      used.add(code);
      codeFor.set(c.ref, code);
    }
    const rows: ReplicaRow[] = [];
    for (const [ref, d] of defs) {
      const hash = sourceHash({ name: d.name, valueType: d.valueType });
      const ex = existing.get(ref);
      bump(scope, 'product_attributes', 'fetched');
      if (ex && ex.hash === hash && !ex.deletionMark) {
        bump(scope, 'product_attributes', 'skipped');
        continue;
      }
      rows.push({
        key: ref,
        id: ex?.id ?? newId(),
        isNew: !ex,
        hash,
        dataVersion: null,
        onecRef: ref,
        onecCode: null,
        values: {
          onec_ref: ref,
          onec_code: null,
          onec_data_version: null,
          deletion_mark: false,
          synced_at: scope.syncedAt.toISOString(),
          source_hash: hash,
          name: d.name,
          value_type: d.valueType,
          code: codeFor.get(ref) ?? attributeCode(d.name),
        },
      });
    }
    const { ok, failed } = await upsertReplica(scope.client, SPEC.product_attributes, rows);
    this.countWritten(scope, 'product_attributes', ok);
    for (const f of failed)
      itemError(scope, 'product_attributes', {
        errorCode: 'VALIDATION',
        severity: 'error',
        message: f.message,
        onecRef: f.row.key,
      });
    const r = await scope.client.query<{ id: string; ref: string; code: string; value_type: string }>(
      `SELECT id, onec_ref::text AS ref, code, value_type::text FROM product_attributes WHERE onec_ref = ANY($1::uuid[])`,
      [[...defs.keys()]],
    );
    return new Map(r.rows.map((x) => [x.ref, { id: x.id, code: x.code, type: x.value_type }]));
  }

  // ------------------------------------------------------------------ товары

  private async products(
    scope: ApplyScope,
    state: ApplyState,
    items: readonly OnecNomenclatureItem[],
    attrIds: Map<string, { id: string; code: string; type: string }>,
    final: boolean,
  ): Promise<void> {
    if (items.length === 0) return;
    // Источник без бренда (OData, `brandUnknown`): текущий `products.brand` сохраняется — и в строке, и в хэше
    // (иначе срез OData стёр бы бренд, пришедший через `/changes`; ТЗ для 1С 5.4, разбор расхождений п. 15).
    const unknownBrandRefs = items
      .filter((it) => it.brandUnknown === true)
      .map((it) => onecRefSafe(it.ref))
      .filter((r): r is string => r !== null);
    const keptBrand = new Map<string, string | null>();
    if (unknownBrandRefs.length > 0) {
      const r = await scope.client.query<{ ref: string; brand: string | null }>(
        `SELECT onec_ref::text AS ref, brand FROM products WHERE onec_ref = ANY($1::uuid[])`,
        [unknownBrandRefs],
      );
      for (const row of r.rows) keptBrand.set(row.ref, row.brand);
    }
    const prepared = this.prepare(scope, 'products', items, (it) => {
      const name = requiredText(it.description, 'description');
      const attrs = normAttributes(it.attributes);
      const fields = {
        code: text(it.code),
        name,
        fullName: text(it.fullName),
        sku: text(it.sku),
        description: text(it.descriptionText),
        categoryRef: onecRef(it.parentRef, 'parentRef'),
        unitRef: onecRef(it.baseUnitRef, 'baseUnitRef'),
        isWeighted: bool(it.isWeighted, false),
        attributes: attrs,
        deletionMark: it.deletionMark,
      };
      // Предложение `brand` (ТЗ для 1С 5.4, вопрос 31) и главная картинка `imageFileRef` (разбор пп. 14–15):
      // в хэш — только непустые, чтобы товары без них не перезаписывались после обновления (SYNC-013).
      const brand = it.brandUnknown === true ? (keptBrand.get(onecRefSafe(it.ref) ?? '') ?? null) : text(it.brand);
      const imageFileRef = onecRefSafe(it.imageFileRef);
      const hashOf = {
        ...fields,
        ...(brand !== null ? { brand } : {}),
        ...(imageFileRef !== null ? { imageFileRef } : {}),
      };
      return { values: { ...fields, brand, imageFileRef }, hashOf, onecCode: fields.code };
    });
    const units = await idsByRef(
      scope.client,
      'units',
      prepared.map((p) => p.values.unitRef as string).filter(Boolean),
    );
    const cats = await idsByRef(
      scope.client,
      'categories',
      prepared.map((p) => p.values.categoryRef as string).filter(Boolean),
    );
    const existing = await existingByKey(
      scope.client,
      'products',
      'onec_ref',
      prepared.map((p) => p.key),
    );
    const ready: {
      p: Prepared<OnecNomenclatureItem>;
      unitId: string;
      categoryId: string | null;
      unresolved: boolean;
    }[] = [];
    for (const p of prepared) {
      const unitRef = p.values.unitRef as string | null;
      const unitId = unitRef ? units.get(unitRef) : undefined;
      const catRef = p.values.categoryRef as string | null;
      const categoryId = catRef ? (cats.get(catRef) ?? null) : null;
      const catMissing = catRef !== null && categoryId === null;
      if ((!unitId || catMissing) && !final) {
        state.deferred.push(p.item);
        continue;
      }
      if (!unitId) {
        itemError(scope, 'products', {
          errorCode: unitRef ? 'NOT_FOUND_LOCAL' : 'VALIDATION',
          severity: 'error',
          message: unitRef
            ? 'единица измерения товара не найдена в реплике units'
            : 'у товара нет базовой единицы (ЕдиницаИзмерения)',
          onecRef: p.key,
          onecCode: p.onecCode,
        });
        continue;
      }
      if (catMissing) {
        itemError(scope, 'products', {
          errorCode: 'NOT_FOUND_LOCAL',
          severity: 'warning',
          message: 'группа товара не найдена — category_id = NULL (05 §5.3)',
          onecRef: p.key,
          onecCode: p.onecCode,
        });
      }
      ready.push({ p, unitId, categoryId, unresolved: catMissing });
    }
    const attrsOf = new Map<string, NormAttr[]>();
    const rows = ready.map(({ p, unitId, categoryId, unresolved }) => {
      const v = p.values;
      const id = existing.get(p.key)?.id ?? newId();
      attrsOf.set(id, v.attributes as NormAttr[]);
      return this.row(scope, p, existing, id, unresolved ? `unresolved:${p.hash}` : p.hash, {
        sku: v.sku,
        name: v.name,
        full_name: v.fullName,
        description: v.description,
        category_id: categoryId,
        base_unit_id: unitId,
        is_weighted: v.isWeighted,
        attributes: productAttributesJson(v.attributes as NormAttr[], attrIds),
        brand: v.brand,
        onec_image_file_ref: v.imageFileRef,
      });
    });
    const writtenRows: ReplicaRow[] = [];
    await this.writeRows(scope, SPEC.products, rows, existing, writtenRows);
    if (writtenRows.length === 0) return;
    const ids = writtenRows.map((r) => r.id);
    // `imageFileRef` мог смениться — главное фото пересчитывается сразу (файлы этого же сообщения — в обработчике).
    await this.images.refreshPrimary(scope.client, ids);
    for (const id of ids) state.dirty.products.add(id);
    // Служебный вариант is_default создаётся вместе с товаром и живёт, пока жив товар (07 §5.17, DATA-116).
    await scope.client.query(
      `INSERT INTO product_variants (product_id, is_default, name, deletion_mark, synced_at, source_hash)
       SELECT p.id, true, '', p.deletion_mark, $2, 'default' FROM products p WHERE p.id = ANY($1::uuid[])
       ON CONFLICT (product_id) WHERE is_default DO NOTHING`,
      [ids, scope.syncedAt.toISOString()],
    );
    await scope.client.query(
      `UPDATE product_variants v SET deletion_mark = p.deletion_mark, synced_at = $2
         FROM products p WHERE v.product_id = p.id AND v.is_default AND p.id = ANY($1::uuid[])
          AND v.deletion_mark IS DISTINCT FROM p.deletion_mark`,
      [ids, scope.syncedAt.toISOString()],
    );
    // Свойства товара → значения служебного варианта (07 §5.19: «для свойств товара — default-вариант»).
    const defaults = await scope.client.query<{ product_id: string; id: string }>(
      `SELECT product_id, id FROM product_variants WHERE is_default AND product_id = ANY($1::uuid[])`,
      [ids],
    );
    const defaultOf = new Map(defaults.rows.map((r) => [r.product_id, r.id]));
    await this.replaceAttributeValues(
      scope,
      writtenRows
        .filter((r) => defaultOf.has(r.id))
        .map((r) => ({ variantId: defaultOf.get(r.id)!, attrs: attrsOf.get(r.id) ?? [] })),
      attrIds,
    );
  }

  // ------------------------------------------------------------------ характеристики

  private async variants(
    scope: ApplyScope,
    state: ApplyState,
    items: readonly OnecVariantItem[],
    attrIds: Map<string, { id: string; code: string; type: string }>,
    final: boolean,
  ): Promise<void> {
    if (items.length === 0) return;
    const prepared = this.prepare(scope, 'product_variants', items, (it) => {
      const fields = {
        code: text(it.code),
        name: requiredText(it.description, 'description'),
        ownerRef: requiredRef(it.ownerRef, 'ownerRef'),
        ownerType: text(it.ownerType),
        sku: text(it.sku),
        attributes: normAttributes(it.attributes),
        deletionMark: it.deletionMark,
      };
      return { values: fields, hashOf: fields, onecCode: fields.code };
    });
    const owners = await idsByRef(
      scope.client,
      'products',
      prepared.map((p) => p.values.ownerRef as string),
    );
    const existing = await existingByKey(
      scope.client,
      'product_variants',
      'onec_ref',
      prepared.map((p) => p.key),
    );
    const rows: ReplicaRow[] = [];
    const attrsOf = new Map<string, NormAttr[]>();
    for (const p of prepared) {
      const productId = owners.get(p.values.ownerRef as string);
      if (!productId) {
        const sharedKind = p.values.ownerType !== null && p.values.ownerType !== 'Catalog_Номенклатура';
        if (!final && !sharedKind) {
          state.deferred.push(p.item);
          continue;
        }
        itemError(scope, 'product_variants', {
          errorCode: sharedKind ? 'VALIDATION' : 'NOT_FOUND_LOCAL',
          severity: 'error',
          message: sharedKind
            ? 'характеристика вида номенклатуры (общие характеристики) — в R1 не поддержана (Q-021)'
            : 'товар-владелец характеристики не найден в реплике products',
          onecRef: p.key,
          onecCode: p.onecCode,
        });
        continue;
      }
      const attrs = p.values.attributes as NormAttr[];
      const row = this.row(scope, p, existing, existing.get(p.key)?.id ?? newId(), p.hash, {
        product_id: productId,
        name: p.values.name,
        sku: p.values.sku,
        attributes: variantAttributesJson(attrs, attrIds),
        is_default: false,
      });
      attrsOf.set(row.id, attrs);
      rows.push(row);
    }
    const writtenRows: ReplicaRow[] = [];
    await this.writeRows(scope, SPEC.product_variants, rows, existing, writtenRows);
    for (const r of writtenRows) state.dirty.variantOwners.add(String(r.values.product_id));
    await this.replaceAttributeValues(
      scope,
      writtenRows.map((r) => ({ variantId: r.id, attrs: attrsOf.get(r.id) ?? [] })),
      attrIds,
    );
  }

  /** Полная замена набора значений свойств варианта (07 §5.19: производная таблица, физическое удаление). */
  private async replaceAttributeValues(
    scope: ApplyScope,
    sets: readonly { variantId: string; attrs: readonly NormAttr[] }[],
    attrIds: Map<string, { id: string; code: string; type: string }>,
  ): Promise<void> {
    if (sets.length === 0) return;
    const rows: Record<string, unknown>[] = [];
    for (const s of sets) {
      for (const a of s.attrs) {
        const def = attrIds.get(a.propertyRef);
        if (!def) continue;
        const v = attributeValue(def.type, a);
        if (!v) continue;
        rows.push({ variant_id: s.variantId, attribute_id: def.id, ...v, onec_value_ref: a.valueRef });
      }
    }
    const variantIds = sets.map((s) => s.variantId);
    const del = await scope.client.query(
      `DELETE FROM variant_attribute_values t WHERE t.variant_id = ANY($1::uuid[])
          AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($2::jsonb) AS x(variant_id uuid, attribute_id uuid)
                           WHERE x.variant_id = t.variant_id AND x.attribute_id = t.attribute_id)`,
      [variantIds, JSON.stringify(rows.map((r) => ({ variant_id: r.variant_id, attribute_id: r.attribute_id })))],
    );
    bump(scope, 'variant_attribute_values', 'markedDeleted', del.rowCount ?? 0);
    for (let i = 0; i < rows.length; i += 1000) {
      const r = await scope.client.query<{ inserted: boolean }>(
        `INSERT INTO variant_attribute_values AS t (variant_id, attribute_id, value_text, value_number, value_bool, onec_value_ref, synced_at)
         SELECT x.variant_id, x.attribute_id, x.value_text, x.value_number, x.value_bool, x.onec_value_ref, $2
           FROM jsonb_to_recordset($1::jsonb) AS x(variant_id uuid, attribute_id uuid, value_text text,
                value_number numeric(18,6), value_bool boolean, onec_value_ref uuid)
         ON CONFLICT (variant_id, attribute_id) DO UPDATE SET value_text = EXCLUDED.value_text,
                value_number = EXCLUDED.value_number, value_bool = EXCLUDED.value_bool,
                onec_value_ref = EXCLUDED.onec_value_ref, synced_at = EXCLUDED.synced_at
          WHERE (t.value_text, t.value_number, t.value_bool, t.onec_value_ref)
                IS DISTINCT FROM (EXCLUDED.value_text, EXCLUDED.value_number, EXCLUDED.value_bool, EXCLUDED.onec_value_ref)
         RETURNING (xmax = 0) AS inserted`,
        [JSON.stringify(rows.slice(i, i + 1000)), scope.syncedAt.toISOString()],
      );
      const ins = r.rows.filter((x) => x.inserted).length;
      bump(scope, 'variant_attribute_values', 'inserted', ins);
      bump(scope, 'variant_attribute_values', 'updated', r.rows.length - ins);
    }
  }

  // ------------------------------------------------------------------ упаковки

  private async packagings(
    scope: ApplyScope,
    state: ApplyState,
    items: readonly OnecPackagingItem[],
    final: boolean,
  ): Promise<void> {
    if (items.length === 0) return;
    const prepared = this.prepare(scope, 'packagings', items, (it) => {
      const factor = qtyToMilli(it.factor, 'factor');
      if (factor <= 0n) throw new OnecValueError('factor: коэффициент упаковки должен быть > 0');
      const fields = {
        name: requiredText(it.description, 'description'),
        ownerRef: requiredRef(it.ownerRef, 'ownerRef'),
        ownerType: text(it.ownerType),
        unitRef: onecRef(it.unitRef, 'unitRef'),
        factor: milliToNumeric(factor),
        deletionMark: it.deletionMark,
      };
      return { values: fields, hashOf: fields, onecCode: null };
    });
    const owners = await idsByRef(
      scope.client,
      'products',
      prepared.map((p) => p.values.ownerRef as string),
    );
    const units = await idsByRef(
      scope.client,
      'units',
      prepared.map((p) => p.values.unitRef as string).filter(Boolean),
    );
    const existing = await existingByKey(
      scope.client,
      'packagings',
      'onec_ref',
      prepared.map((p) => p.key),
    );
    const rows: ReplicaRow[] = [];
    for (const p of prepared) {
      const v = p.values;
      const ofKind = v.ownerType !== null && v.ownerType !== 'Catalog_Номенклатура';
      const productId = ofKind ? null : owners.get(v.ownerRef as string);
      const unitId = v.unitRef ? units.get(v.unitRef as string) : undefined;
      const missingOwner = !ofKind && !productId;
      if (missingOwner || !unitId) {
        // Владелец или единица могут прийти позже в том же сообщении; упаковка без единицы — ошибка данных.
        if (!final && (missingOwner || v.unitRef !== null)) {
          state.deferred.push(p.item);
          continue;
        }
        itemError(scope, 'packagings', {
          errorCode: v.unitRef || (!ofKind && !productId) ? 'NOT_FOUND_LOCAL' : 'VALIDATION',
          severity: 'error',
          message: !unitId
            ? v.unitRef
              ? 'единица упаковки не найдена в реплике units'
              : 'у упаковки нет единицы измерения'
            : 'товар-владелец упаковки не найден в реплике products',
          onecRef: p.key,
        });
        continue;
      }
      rows.push(
        this.row(scope, p, existing, existing.get(p.key)?.id ?? newId(), p.hash, {
          product_id: productId ?? null,
          packaging_set_ref: ofKind ? v.ownerRef : null,
          unit_id: unitId,
          name: v.name,
          factor: v.factor,
        }),
      );
    }
    await this.writeRows(scope, SPEC.packagings, rows, existing);
  }

  // ------------------------------------------------------------------ штрихкоды

  private async barcodes(
    scope: ApplyScope,
    state: ApplyState,
    items: readonly OnecBarcodeItem[],
    final: boolean,
  ): Promise<void> {
    if (items.length === 0) return;
    // 05 ONEC-017 п. 2 / AC-ONEC-017, SYNC-020, SYNC-033 (д): значение штрихкода — ключ набора регистра. Все
    // привязки значения, пришедшие в прогоне (во всех страницах/пакетах прогона — `state.barcodes`), — кандидаты;
    // побеждает текущая привязка `barcodes` (до прогона), если она среди кандидатов, иначе — наименьший ключ
    // (`Номенклатура_Key`, `Характеристика_Key`, `Упаковка_Key`). Две и более привязки → `BARCODE_CONFLICT`.
    // Результат не зависит от порядка позиций и пакетов; DataVersion не используется (SYNC-012).
    const parsed: BarcodeCandidate[] = [];
    const badValues = new Set<string>();
    for (const it of items) {
      bump(scope, 'barcodes', 'fetched');
      const value = (text(it.barcode) ?? text(it.ref) ?? '').trim();
      try {
        if (!BARCODE_VALUE_RE.test(value)) throw new OnecValueError('штрихкод: недопустимые символы или длина (4…64)');
        const productRef = requiredRef(it.productRef, 'productRef');
        const variantRef = onecRef(it.variantRef, 'variantRef');
        const packRef = onecRef(it.packagingRef, 'packagingRef');
        const type = barcodeType(value, it.barcodeType);
        parsed.push({
          item: it,
          value,
          productRef,
          variantRef,
          packRef,
          type,
          bkey: bindingKey(productRef, variantRef, packRef),
        });
      } catch (e) {
        const message = errMessage(e);
        if (badValues.has(`${value}\u0000${message}`)) continue;
        badValues.add(`${value}\u0000${message}`);
        itemError(scope, 'barcodes', { errorCode: 'VALIDATION', severity: 'error', message, onecCode: value });
      }
    }
    if (parsed.length === 0) return;
    // Текущая привязка фиксируется при первой встрече значения в прогоне (до записи этого прогона).
    const fresh = [...new Set(parsed.map((p) => p.value))].filter((v) => !state.barcodes.has(v));
    if (fresh.length > 0) {
      const cur = await scope.client.query<{ value: string; p: string; v: string; k: string | null }>(
        `SELECT value, product_id::text AS p, variant_id::text AS v, packaging_id::text AS k
           FROM barcodes WHERE value = ANY($1::text[]) AND NOT deletion_mark`,
        [fresh],
      );
      const byValue = new Map(cur.rows.map((r) => [r.value, r]));
      for (const v of fresh) {
        const r = byValue.get(v);
        state.barcodes.set(v, {
          current: r ? { productId: r.p, variantId: r.v, packagingId: r.k } : null,
          candidates: new Map(),
        });
      }
    }
    const sizeBefore = new Map<string, number>();
    for (const p of parsed) {
      const entry = state.barcodes.get(p.value)!;
      if (!sizeBefore.has(p.value)) sizeBefore.set(p.value, entry.candidates.size);
      const had = entry.candidates.get(p.bkey);
      // Та же привязка повторно (другая страница, повтор отложенной позиции): тип — детерминированно (наименьший).
      if (!had || p.type < had.type) entry.candidates.set(p.bkey, p);
    }
    const all = [...sizeBefore.keys()].flatMap((v) => [...state.barcodes.get(v)!.candidates.values()]);
    const products = await idsByRef(
      scope.client,
      'products',
      all.map((p) => p.productRef),
    );
    const variants = await idsByRef(
      scope.client,
      'product_variants',
      all.map((p) => p.variantRef).filter((x): x is string => !!x),
    );
    const packs = await idsByRef(
      scope.client,
      'packagings',
      all.map((p) => p.packRef).filter((x): x is string => !!x),
    );
    const defaults = await scope.client.query<{ product_id: string; id: string }>(
      `SELECT product_id, id FROM product_variants WHERE is_default AND product_id = ANY($1::uuid[])`,
      [[...products.values()]],
    );
    const defaultOf = new Map(defaults.rows.map((r) => [r.product_id, r.id]));
    const resolve = (c: BarcodeCandidate) => {
      const productId = products.get(c.productRef);
      const variantId = c.variantRef ? variants.get(c.variantRef) : productId ? defaultOf.get(productId) : undefined;
      const packId = c.packRef ? packs.get(c.packRef) : null;
      return { productId, variantId, packId };
    };
    const winners: BarcodeCandidate[] = [];
    for (const [value, before] of sizeBefore) {
      const entry = state.barcodes.get(value)!;
      const sorted = [...entry.candidates.values()].sort((a, b) => (a.bkey < b.bkey ? -1 : a.bkey > b.bkey ? 1 : 0));
      const cur = entry.current;
      const keep = cur
        ? sorted.find((c) => {
            const r = resolve(c);
            return (
              r.productId === cur.productId && r.variantId === cur.variantId && (r.packId ?? null) === cur.packagingId
            );
          })
        : undefined;
      const winner = keep ?? sorted[0];
      if (sorted.length > 1 && sorted.length > before) {
        itemError(scope, 'barcodes', {
          errorCode: 'BARCODE_CONFLICT',
          severity: 'warning',
          message: `штрихкод привязан в 1С к ${sorted.length} позициям — оставлена ${keep ? 'текущая привязка' : 'привязка с наименьшим ключом'} (05 ONEC-017)`,
          onecCode: value,
          payload: {
            rule: keep ? 'current' : 'min_key',
            chosen: refsOf(winner),
            bindings: sorted.map(refsOf),
          },
        });
      }
      winners.push(winner);
    }
    const existing = await existingByKey(
      scope.client,
      'barcodes',
      'value',
      winners.map((p) => p.value),
    );
    const rows: ReplicaRow[] = [];
    const seen: { key: string; hash: string; id: string }[] = [];
    for (const p of winners) {
      const { productId, variantId, packId } = resolve(p);
      if (!productId || !variantId || packId === undefined) {
        if (!final) {
          state.deferred.push(p.item);
          continue;
        }
        itemError(scope, 'barcodes', {
          errorCode: 'NOT_FOUND_LOCAL',
          severity: 'error',
          message: !productId
            ? 'товар штрихкода не найден'
            : !variantId
              ? 'характеристика штрихкода не найдена'
              : 'упаковка штрихкода не найдена',
          onecCode: p.value,
        });
        continue;
      }
      const hash = sourceHash({
        value: p.value,
        productRef: p.productRef,
        variantRef: p.variantRef,
        packRef: p.packRef,
        type: p.type,
      });
      const ex = existing.get(p.value);
      if (ex && ex.hash === hash && !ex.deletionMark) {
        bump(scope, 'barcodes', 'skipped');
        seen.push({ key: p.value, hash, id: ex.id });
        continue;
      }
      rows.push({
        key: p.value,
        id: ex?.id ?? newId(),
        isNew: !ex,
        hash,
        dataVersion: null,
        onecRef: null,
        onecCode: p.value,
        values: {
          onec_ref: null,
          onec_code: null,
          onec_data_version: null,
          deletion_mark: false,
          synced_at: scope.syncedAt.toISOString(),
          source_hash: hash,
          value: p.value,
          product_id: productId,
          variant_id: variantId,
          packaging_id: packId,
          type: p.type,
        },
      });
    }
    const { ok, failed } = await upsertReplica(scope.client, SPEC.barcodes, rows);
    this.countWritten(scope, 'barcodes', ok);
    for (const f of failed)
      itemError(scope, 'barcodes', {
        errorCode: 'VALIDATION',
        severity: 'error',
        message: f.message,
        onecCode: f.row.key,
      });
    seen.push(...ok.map((r) => ({ key: r.key, hash: r.hash, id: r.id })));
    await upsertVersions(
      scope.client,
      'barcodes',
      await scope.runIdFor('barcodes'),
      seen.map((r) => ({ key: r.key, onecRef: null, dataVersion: null, hash: r.hash, localId: r.id })),
      scope.syncedAt,
    );
  }

  // ------------------------------------------------------------------ удаление (ObjectDeletion)

  private async deletions(
    scope: ApplyScope,
    state: ApplyState,
    items: readonly OnecObjectDeletionItem[],
  ): Promise<void> {
    const byTable = new Map<CatalogTable, Set<string>>();
    for (const d of items) {
      const tables = DELETION_TABLES[d.objectType];
      if (!tables) continue;
      for (const t of tables) {
        let key: string | null;
        try {
          key = t === 'barcodes' ? text(d.ref) : onecRef(d.ref, 'ref');
        } catch {
          key = null;
        }
        if (!key) continue;
        const set = byTable.get(t) ?? new Set<string>();
        set.add(key);
        byTable.set(t, set);
      }
    }
    for (const [table, keys] of byTable) {
      const col = table === 'barcodes' ? 'value' : 'onec_ref';
      const r = await scope.client.query<{ id: string; key: string }>(
        `UPDATE ${table} SET deletion_mark = true, source_hash = 'deleted:' || source_hash, synced_at = $2
          WHERE ${col} = ANY($1::${col === 'value' ? 'text' : 'uuid'}[]) AND NOT deletion_mark
          RETURNING id, ${col}::text AS key`,
        [[...keys], scope.syncedAt.toISOString()],
      );
      bump(scope, table, 'markedDeleted', r.rowCount ?? 0);
      if (table === 'categories' && (r.rowCount ?? 0) > 0) state.dirty.categories = true;
      if (table === 'products' && r.rows.length > 0) {
        const ids = r.rows.map((x) => x.id);
        for (const id of ids) state.dirty.products.add(id);
        await scope.client.query(
          `UPDATE product_variants SET deletion_mark = true, synced_at = $2 WHERE is_default AND product_id = ANY($1::uuid[]) AND NOT deletion_mark`,
          [ids, scope.syncedAt.toISOString()],
        );
      }
      if (table === 'product_variants' && r.rows.length > 0) {
        const owners = await scope.client.query<{ product_id: string }>(
          `SELECT DISTINCT product_id FROM product_variants WHERE id = ANY($1::uuid[])`,
          [r.rows.map((x) => x.id)],
        );
        for (const o of owners.rows) state.dirty.variantOwners.add(o.product_id);
      }
    }
  }

  // ------------------------------------------------------------------ общее

  private prepare<T extends { ref: string; dataVersion?: string; deletionMark?: boolean }>(
    scope: ApplyScope,
    table: CatalogTable,
    items: readonly T[],
    map: (it: T) => { values: Record<string, unknown>; hashOf: unknown; onecCode: string | null },
  ): Prepared<T>[] {
    const out = new Map<string, Prepared<T>>();
    for (const it of items) {
      bump(scope, table, 'fetched');
      try {
        const key = requiredRef(it.ref, 'ref');
        const m = map(it);
        // Повтор объекта в пакете: применяется последнее состояние (объекты передаются в текущем состоянии).
        out.set(key, { item: it, key, hash: sourceHash(m.hashOf), values: m.values, onecCode: m.onecCode });
      } catch (e) {
        itemError(scope, table, {
          errorCode: 'VALIDATION',
          severity: 'error',
          message: errMessage(e),
          onecRef: onecRefSafe(it.ref),
          payload: { type: (it as { type?: string }).type ?? null },
        });
      }
    }
    return [...out.values()];
  }

  private row(
    scope: ApplyScope,
    p: Prepared<{ ref: string; dataVersion?: string; deletionMark?: boolean }>,
    existing: Map<string, { id: string }>,
    id: string,
    hash: string,
    values: Record<string, unknown>,
  ): ReplicaRow {
    return {
      key: p.key,
      id,
      isNew: !existing.has(p.key),
      hash,
      dataVersion: typeof p.item.dataVersion === 'string' ? p.item.dataVersion : null,
      onecRef: p.key,
      onecCode: p.onecCode,
      values: {
        onec_ref: p.key,
        onec_code: p.onecCode,
        onec_data_version: typeof p.item.dataVersion === 'string' ? p.item.dataVersion : null,
        deletion_mark: p.item.deletionMark === true,
        synced_at: scope.syncedAt.toISOString(),
        source_hash: hash,
        ...values,
      },
    };
  }

  /** Записать подготовленные справочники без внешних ссылок (units, warehouses, price_lists). */
  private async write(
    scope: ApplyScope,
    spec: ReplicaSpec,
    prepared: Prepared<{ ref: string; dataVersion?: string; deletionMark?: boolean }>[],
  ): Promise<void> {
    if (prepared.length === 0) return;
    const existing = await existingByKey(
      scope.client,
      spec.table,
      'onec_ref',
      prepared.map((p) => p.key),
    );
    const rows = prepared.map((p) =>
      this.row(scope, p, existing, existing.get(p.key)?.id ?? newId(), p.hash, { ...p.values }),
    );
    await this.writeRows(scope, spec, rows, existing);
  }

  /**
   * Пропуск неизменённых (`source_hash` совпал, SYNC-013), upsert остальных, учёт версий (`sync_entity_versions`).
   * Возвращает число записанных строк; записанные строки — в `out` (если передан).
   */
  private async writeRows(
    scope: ApplyScope,
    spec: ReplicaSpec,
    rows: readonly ReplicaRow[],
    existing: Map<string, { id: string; hash: string; deletionMark: boolean }>,
    out?: ReplicaRow[],
  ): Promise<number> {
    const changed: ReplicaRow[] = [];
    for (const r of rows) {
      const ex = existing.get(r.key);
      if (ex && ex.hash === r.hash) bump(scope, spec.table, 'skipped');
      else changed.push(r);
    }
    const { ok, failed } = await upsertReplica(scope.client, spec, changed);
    this.countWritten(scope, spec.table, ok);
    for (const f of failed) {
      itemError(scope, spec.table, {
        errorCode: 'VALIDATION',
        severity: 'error',
        message: f.message,
        onecRef: f.row.onecRef,
        onecCode: f.row.onecCode,
      });
    }
    out?.push(...ok);
    const failedKeys = new Set(failed.map((f) => f.row.key));
    const entity = TABLE_ENTITY[spec.table];
    await upsertVersions(
      scope.client,
      entity,
      await scope.runIdFor(entity),
      rows
        .filter((r) => !failedKeys.has(r.key))
        .map((r) => ({ key: r.key, onecRef: r.onecRef, dataVersion: r.dataVersion, hash: r.hash, localId: r.id })),
      scope.syncedAt,
    );
    return ok.length;
  }

  private countWritten(scope: ApplyScope, table: CatalogTable, ok: readonly ReplicaRow[]): void {
    const inserted = ok.filter((r) => r.isNew).length;
    bump(scope, table, 'inserted', inserted);
    bump(scope, table, 'updated', ok.length - inserted);
  }
}

// ------------------------------------------------------------------ вспомогательное

interface Grouped {
  units: OnecUnitItem[];
  warehouses: OnecWarehouseItem[];
  priceLists: OnecPriceListItem[];
  folders: OnecNomenclatureItem[];
  products: OnecNomenclatureItem[];
  variants: OnecVariantItem[];
  packagings: OnecPackagingItem[];
  barcodes: OnecBarcodeItem[];
  priceSettings: { priceListRefs?: readonly string[] }[];
  deletions: OnecObjectDeletionItem[];
}

function groupByType(scope: ApplyScope, state: ApplyState, items: readonly unknown[]): Grouped {
  const g: Grouped = {
    units: [],
    warehouses: [],
    priceLists: [],
    folders: [],
    products: [],
    variants: [],
    packagings: [],
    barcodes: [],
    priceSettings: [],
    deletions: [],
  };
  for (const raw of items) {
    if (typeof raw !== 'object' || raw === null || typeof (raw as { type?: unknown }).type !== 'string') {
      scope.errors.push({
        entity: 'products',
        errorCode: 'VALIDATION',
        severity: 'error',
        message: 'элемент /changes без поля type',
      });
      continue;
    }
    const it = raw as OnecCatalogItem;
    switch (it.type) {
      case 'Catalog_КлассификаторЕдиницИзмерения':
        g.units.push(it);
        break;
      case 'Catalog_Склады':
        g.warehouses.push(it);
        break;
      case 'Catalog_ВидыЦен':
        g.priceLists.push(it);
        break;
      case 'Catalog_Номенклатура':
        if (it.isFolder === true) g.folders.push(it);
        else g.products.push(it);
        break;
      case 'Catalog_ХарактеристикиНоменклатуры':
        g.variants.push(it);
        break;
      case 'Catalog_УпаковкиЕдиницыИзмерения':
        g.packagings.push(it);
        break;
      case 'InformationRegister_ШтрихкодыНоменклатуры':
        g.barcodes.push(it);
        break;
      case 'Document_УстановкаЦенНоменклатуры':
        g.priceSettings.push(it);
        break;
      case 'ObjectDeletion':
        g.deletions.push(it);
        if (!DELETION_TABLES[it.objectType]) state.foreign.push(it as unknown as Record<string, unknown>);
        break;
      default: {
        const type = (it as { type: string }).type;
        if (KNOWN_TYPES.has(type)) {
          state.foreign.push(it as unknown as Record<string, unknown>);
        } else {
          // NOTES §3 п. 11: неизвестный тип — запись в sync_errors, применение не останавливается.
          scope.errors.push({
            entity: 'products',
            errorCode: 'VALIDATION',
            severity: 'warning',
            message: `неизвестный тип элемента /changes: ${type.slice(0, 80)}`,
            payload: { type: type.slice(0, 80) },
          });
        }
      }
    }
  }
  return g;
}

interface NormAttr {
  readonly propertyRef: string;
  readonly name: string;
  readonly valueType: string | null;
  readonly valueRef: string | null;
  readonly valueText: string | null;
}

function normAttributes(list: readonly OnecAttributeValue[] | undefined): NormAttr[] {
  const out: NormAttr[] = [];
  for (const a of list ?? []) {
    const propertyRef = onecRefSafe(a.propertyRef);
    const name = text(a.name);
    if (!propertyRef || !name) continue;
    out.push({
      propertyRef,
      name,
      valueType: text(a.valueType),
      valueRef: onecRefSafe(a.valueRef),
      valueText: typeof a.valueText === 'string' ? a.valueText.trim() : null,
    });
  }
  return out.sort((x, y) => (x.propertyRef < y.propertyRef ? -1 : x.propertyRef > y.propertyRef ? 1 : 0));
}

/** `products.attributes`: `{"<code>": {"name", "value", "type"}}` (07 §5.16). */
function productAttributesJson(
  attrs: readonly NormAttr[],
  ids: Map<string, { code: string; type: string }>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const a of attrs) {
    const def = ids.get(a.propertyRef);
    if (!def) continue;
    out[def.code] = { name: a.name, value: a.valueText, type: def.type };
  }
  return out;
}

/** `product_variants.attributes`: денормализованные `{"<code>": "<значение>"}` для `VariantSelector` (07 §5.17). */
function variantAttributesJson(
  attrs: readonly NormAttr[],
  ids: Map<string, { code: string }>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const a of attrs) {
    const def = ids.get(a.propertyRef);
    if (def) out[def.code] = a.valueText;
  }
  return out;
}

function attributeValue(
  type: string,
  a: NormAttr,
): { value_text: string | null; value_number: string | null; value_bool: boolean | null } | null {
  const t = a.valueText;
  if (type === 'number' && t !== null && /^-?\d+([.,]\d+)?$/.test(t)) {
    return { value_text: null, value_number: t.replace(',', '.'), value_bool: null };
  }
  if (type === 'boolean' && t !== null) {
    const v = /^(true|да|1)$/i.test(t) ? true : /^(false|нет|0)$/i.test(t) ? false : null;
    if (v !== null) return { value_text: null, value_number: null, value_bool: v };
  }
  if (t === null || t === '') return null;
  return { value_text: t, value_number: null, value_bool: null };
}

function onecRefSafe(v: unknown): string | null {
  try {
    return onecRef(v);
  } catch {
    return null;
  }
}

function errMessage(e: unknown): string {
  return e instanceof OnecValueError ? e.message : dbMessage(e);
}

export { inSavepoint };
