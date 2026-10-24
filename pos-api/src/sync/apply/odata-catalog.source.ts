import type {
  OnecAttributeValue,
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPackagingItem,
  OnecPriceListItem,
  OnecPriceRow,
  OnecStockRow,
  OnecUnitItem,
  OnecVariantItem,
  OnecWarehouseItem,
} from '../../integrations/onec/onec-catalog.types.js';
import {
  ODATA_EMPTY_REF,
  odataGuid,
  type OnecODataClient,
  OnecODataError,
  type ODataRow,
} from '../../integrations/onec/onec-odata.client.js';
import type { CatalogFullSource, CatalogReadKind, OnecVersionKey } from './catalog-source.js';

/**
 * Источник фазы 0 (`ONEC_MODE=odata_only`; 05 §4, §5, §7.1–§7.2) — стандартный OData по allow-list
 * (`contracts/onec/odata-allowlist.yaml`). Строки OData переводятся в формат элементов `/changes`, чтобы
 * конвейер применения был один для фаз 0 и 1. Имена объектов и полей — `[ТИПОВО: УТ 11]` (Q-010): после получения
 * `$metadata` меняются allow-list и таблица `READS` ниже, а не маппинг.
 * Поля `[НЕ ПОДТВЕРЖДЕНО]` (ONEC-106) запрашиваются, а при отказе 1С (400 — нет поля) — повтор без них.
 */
interface ReadSpec {
  readonly collection: string;
  readonly select: readonly string[];
  /** Минимальный набор, если полный отвергнут (неподтверждённые поля отсутствуют, ONEC-106). */
  readonly minimal?: readonly string[];
  readonly filter?: string;
  readonly map: (row: ODataRow) => OnecCatalogItem | undefined;
}

const NOMENCLATURE_FIELDS = [
  'Ref_Key',
  'DataVersion',
  'DeletionMark',
  'IsFolder',
  'Code',
  'Description',
  'НаименованиеПолное',
  'Артикул',
  'Parent_Key',
  'ЕдиницаИзмерения_Key',
  'ВидНоменклатуры_Key',
  'Описание',
  'ФайлКартинки_Key',
  'Весовой',
] as const;

function str(v: unknown): string | null {
  if (typeof v === 'string') return v.trim() === '' ? null : v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return null;
}

function ref(v: unknown): string | null {
  const s = str(v)?.toLowerCase() ?? null;
  return s === null || s === ODATA_EMPTY_REF ? null : s;
}

function bool(v: unknown): boolean | null {
  return typeof v === 'boolean' ? v : null;
}

/** `StandardODATA.Catalog_Номенклатура` → `Catalog_Номенклатура`. */
function typeName(v: unknown): string | null {
  const s = str(v);
  return s ? s.replace(/^StandardODATA\./, '') : null;
}

/** Число OData (JSON number/строка) → строка десятичного числа без экспоненты. */
export function odataDecimal(v: unknown): string {
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new Error('не число');
    const s = String(v);
    return /e/i.test(s) ? v.toFixed(6) : s;
  }
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim())) return v.trim();
  return '0';
}

/** `Edm.DateTime` без зоны — локальное время Бишкека (ONEC-103) → ISO с `+06:00`. */
export function odataDate(v: unknown): string | null {
  const s = str(v);
  if (!s) return null;
  return /([+-]\d{2}:\d{2}|Z)$/.test(s) ? s : `${s}+06:00`;
}

/** `Edm.DateTime` для параметров виртуальных таблиц (без зоны, локальное время Бишкека). */
export function odataDateTimeLiteral(d: Date): string {
  const local = new Date(d.getTime() + 6 * 3600_000).toISOString().slice(0, 19);
  return `datetime'${local}'`;
}

const READS: Readonly<Record<CatalogReadKind, ReadSpec>> = {
  units: {
    collection: 'Catalog_КлассификаторЕдиницИзмерения',
    select: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description'],
    map: (r): OnecUnitItem => ({
      type: 'Catalog_КлассификаторЕдиницИзмерения',
      ref: ref(r.Ref_Key) ?? '',
      dataVersion: str(r.DataVersion) ?? '',
      deletionMark: r.DeletionMark === true,
      code: str(r.Code),
      description: str(r.Description) ?? '',
    }),
  },
  warehouses: {
    collection: 'Catalog_Склады',
    select: ['Ref_Key', 'DataVersion', 'DeletionMark', 'IsFolder', 'Code', 'Description'],
    filter: 'IsFolder eq false',
    map: (r): OnecWarehouseItem => ({
      type: 'Catalog_Склады',
      ref: ref(r.Ref_Key) ?? '',
      dataVersion: str(r.DataVersion) ?? '',
      deletionMark: r.DeletionMark === true,
      isFolder: r.IsFolder === true,
      code: str(r.Code),
      description: str(r.Description) ?? '',
    }),
  },
  price_lists: {
    collection: 'Catalog_ВидыЦен',
    select: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Code',
      'Description',
      'ИспользоватьПриПродаже',
      'ЦенаВключаетНДС',
    ],
    minimal: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description'],
    // ВалютаЦены_Key — ссылка на справочник валют, код валюты по ней OData без доп. коллекции не даёт:
    // вид цены считается KGS (05 §5.3 «ВалютаЦены_Key [НЕ ПОДТВЕРЖДЕНО] → 'KGS'»).
    map: (r): OnecPriceListItem => ({
      type: 'Catalog_ВидыЦен',
      ref: ref(r.Ref_Key) ?? '',
      dataVersion: str(r.DataVersion) ?? '',
      deletionMark: r.DeletionMark === true,
      code: str(r.Code),
      description: str(r.Description) ?? '',
      currency: null,
      usedForSales: bool(r['ИспользоватьПриПродаже']),
      priceIncludesVat: bool(r['ЦенаВключаетНДС']),
    }),
  },
  categories: {
    collection: 'Catalog_Номенклатура',
    select: ['Ref_Key', 'DataVersion', 'DeletionMark', 'IsFolder', 'Code', 'Description', 'Parent_Key'],
    filter: 'IsFolder eq true',
    map: (r) => nomenclature(r),
  },
  products: {
    collection: 'Catalog_Номенклатура',
    select: NOMENCLATURE_FIELDS,
    minimal: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'IsFolder',
      'Code',
      'Description',
      'Parent_Key',
      'ЕдиницаИзмерения_Key',
    ],
    filter: 'IsFolder eq false',
    map: (r) => nomenclature(r),
  },
  packagings: {
    collection: 'Catalog_УпаковкиЕдиницыИзмерения',
    select: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Description',
      'Owner_Key',
      'Owner_Type',
      'Коэффициент',
      'ЕдиницаИзмерения_Key',
    ],
    map: (r): OnecPackagingItem => ({
      type: 'Catalog_УпаковкиЕдиницыИзмерения',
      ref: ref(r.Ref_Key) ?? '',
      dataVersion: str(r.DataVersion) ?? '',
      deletionMark: r.DeletionMark === true,
      description: str(r.Description) ?? '',
      ownerRef: ref(r.Owner_Key) ?? '',
      ownerType: typeName(r.Owner_Type),
      unitRef: ref(r['ЕдиницаИзмерения_Key']),
      factor: odataDecimal(r['Коэффициент']),
    }),
  },
  variants: {
    collection: 'Catalog_ХарактеристикиНоменклатуры',
    select: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description', 'Owner_Key', 'Owner_Type'],
    map: (r): OnecVariantItem => ({
      type: 'Catalog_ХарактеристикиНоменклатуры',
      ref: ref(r.Ref_Key) ?? '',
      dataVersion: str(r.DataVersion) ?? '',
      deletionMark: r.DeletionMark === true,
      code: str(r.Code),
      description: str(r.Description) ?? '',
      ownerRef: ref(r.Owner_Key) ?? '',
      ownerType: typeName(r.Owner_Type),
      sku: null,
      attributes: [],
    }),
  },
  barcodes: {
    collection: 'InformationRegister_ШтрихкодыНоменклатуры',
    select: ['Штрихкод', 'Номенклатура_Key', 'Характеристика_Key', 'Упаковка_Key', 'ТипШтрихкода'],
    minimal: ['Штрихкод', 'Номенклатура_Key', 'Характеристика_Key', 'Упаковка_Key'],
    map: (r): OnecBarcodeItem | undefined => {
      const value = str(r['Штрихкод'])?.trim();
      if (!value) return undefined;
      return {
        type: 'InformationRegister_ШтрихкодыНоменклатуры',
        ref: value,
        barcode: value,
        productRef: ref(r['Номенклатура_Key']) ?? '',
        variantRef: ref(r['Характеристика_Key']),
        packagingRef: ref(r['Упаковка_Key']),
        barcodeType: str(r['ТипШтрихкода']),
      };
    },
  },
};

function nomenclature(r: ODataRow): OnecNomenclatureItem {
  return {
    type: 'Catalog_Номенклатура',
    ref: ref(r.Ref_Key) ?? '',
    dataVersion: str(r.DataVersion) ?? '',
    deletionMark: r.DeletionMark === true,
    isFolder: r.IsFolder === true,
    code: str(r.Code),
    description: str(r.Description) ?? '',
    fullName: str(r['НаименованиеПолное']),
    sku: str(r['Артикул']),
    parentRef: ref(r.Parent_Key),
    baseUnitRef: ref(r['ЕдиницаИзмерения_Key']),
    kindRef: ref(r['ВидНоменклатуры_Key']),
    descriptionText: str(r['Описание']),
    imageFileRef: ref(r['ФайлКартинки_Key']),
    isWeighted: bool(r['Весовой']),
    attributes: [],
  };
}

const REFS_PER_FILTER = 25;

export class ODataCatalogSource implements CatalogFullSource {
  readonly name = 'odata';
  private propertyNames: Map<string, string> | undefined;
  private snapshot: Date | undefined;

  constructor(
    private readonly client: OnecODataClient,
    private readonly now: () => Date = () => new Date(),
  ) {}

  snapshotAt(): Date | undefined {
    return this.snapshot;
  }

  async *read(kind: CatalogReadKind): AsyncIterable<readonly OnecCatalogItem[]> {
    const spec = READS[kind];
    const select = await this.workingSelect(spec);
    for await (const page of this.client.pages(spec.collection, {
      select,
      ...(spec.filter ? { filter: spec.filter } : {}),
    })) {
      const items = page.rows.map(spec.map).filter((x): x is OnecCatalogItem => x !== undefined);
      if (kind === 'products') await this.attachAttributes(items as OnecNomenclatureItem[]);
      yield items;
    }
  }

  count(kind: CatalogReadKind): Promise<number> {
    const spec = READS[kind];
    const notDeleted = spec.select.includes('DeletionMark') ? 'DeletionMark eq false' : undefined;
    const filter = [spec.filter, notDeleted].filter(Boolean).join(' and ');
    return this.client.count(spec.collection, filter || undefined);
  }

  async *versions(kind: CatalogReadKind): AsyncIterable<readonly OnecVersionKey[]> {
    const spec = READS[kind];
    if (!spec.select.includes('DataVersion'))
      throw new Error(`${kind}: у объекта нет DataVersion — только полная перечитка`);
    for await (const page of this.client.pages(spec.collection, {
      select: ['Ref_Key', 'DataVersion', 'DeletionMark'],
      ...(spec.filter ? { filter: spec.filter } : {}),
    })) {
      yield page.rows
        .map((r) => ({
          key: ref(r.Ref_Key) ?? '',
          dataVersion: str(r.DataVersion),
          deletionMark: r.DeletionMark === true,
        }))
        .filter((v) => v.key !== '');
    }
  }

  async fetchByKeys(kind: CatalogReadKind, keys: readonly string[]): Promise<readonly OnecCatalogItem[]> {
    const spec = READS[kind];
    const select = await this.workingSelect(spec);
    const out: OnecCatalogItem[] = [];
    for (let i = 0; i < keys.length; i += REFS_PER_FILTER) {
      // Оператора `in` в OData v3 нет — цепочка `or` по 20–50 ссылок (05 SYNC-017).
      const or = keys
        .slice(i, i + REFS_PER_FILTER)
        .map((k) => `Ref_Key eq ${odataGuid(k)}`)
        .join(' or ');
      const rows = await this.client.list(spec.collection, {
        select,
        filter: spec.filter ? `(${spec.filter}) and (${or})` : or,
      });
      out.push(...rows.map(spec.map).filter((x): x is OnecCatalogItem => x !== undefined));
    }
    if (kind === 'products') await this.attachAttributes(out as OnecNomenclatureItem[]);
    return out;
  }

  /** Срез цен `ЦеныНоменклатуры/SliceLast` по каждому виду цены (05 SYNC-015). */
  async *priceSlice(priceListRefs: readonly string[]): AsyncIterable<readonly OnecPriceRow[]> {
    const at = this.now();
    this.snapshot = at;
    for (const pl of priceListRefs) {
      const params = `Period=${odataDateTimeLiteral(at)},Condition='ВидЦены_Key eq ${odataGuid(pl).replace(/'/g, "''")}'`;
      for await (const page of this.client.pages('InformationRegister_ЦеныНоменклатуры', {
        select: ['Period', 'ВидЦены_Key', 'Номенклатура_Key', 'Характеристика_Key', 'Упаковка_Key', 'Цена'],
        virtual: { op: 'sliceLast', params },
      })) {
        yield page.rows
          .map((r) => ({
            priceListRef: ref(r['ВидЦены_Key']) ?? pl,
            productRef: ref(r['Номенклатура_Key']) ?? '',
            variantRef: ref(r['Характеристика_Key']),
            packagingRef: ref(r['Упаковка_Key']),
            price: odataDecimal(r['Цена']),
            period: odataDate(r.Period),
          }))
          .filter((r) => r.productRef !== '');
      }
    }
  }

  /**
   * Срез остатков `СвободныеОстатки/Balance` (остаток и резервы); при отсутствии регистра (`conditional`,
   * 404) — `ТоварыНаСкладах/Balance` без резервов (05 §5.3: «без регистра резервов available = quantity»).
   */
  async *stockSlice(warehouseRefs?: readonly string[]): AsyncIterable<readonly OnecStockRow[]> {
    const at = this.now();
    this.snapshot = at;
    const targets: (string | undefined)[] =
      warehouseRefs && warehouseRefs.length > 0 ? [...warehouseRefs] : [undefined];
    for (const wh of targets) {
      const cond = wh ? `,Condition='Склад_Key eq ${odataGuid(wh).replace(/'/g, "''")}'` : '';
      const params = `Period=${odataDateTimeLiteral(at)}${cond},Dimensions='Номенклатура,Характеристика,Склад'`;
      try {
        for await (const page of this.client.pages('AccumulationRegister_СвободныеОстатки', {
          select: [
            'Номенклатура_Key',
            'Характеристика_Key',
            'Склад_Key',
            'ВНаличииBalance',
            'ВРезервеBalance',
            'ВРезервеПодЗаказBalance',
          ],
          virtual: { op: 'balance', params },
        })) {
          yield page.rows.map((r) => stockRow(r, true)).filter((r): r is OnecStockRow => r !== undefined);
        }
      } catch (e) {
        if (!(e instanceof OnecODataError && e.notFound)) throw e;
        for await (const page of this.client.pages('AccumulationRegister_ТоварыНаСкладах', {
          select: ['Номенклатура_Key', 'Характеристика_Key', 'Склад_Key', 'ВНаличииBalance'],
          virtual: { op: 'balance', params },
        })) {
          yield page.rows.map((r) => stockRow(r, false)).filter((r): r is OnecStockRow => r !== undefined);
        }
      }
    }
  }

  /** Полный `$select` или минимальный, если 1С отвергла неподтверждённые поля (400/404 на поле). */
  private readonly selects = new Map<string, readonly string[]>();
  private async workingSelect(spec: ReadSpec): Promise<readonly string[]> {
    const known = this.selects.get(spec.collection + (spec.filter ?? ''));
    if (known) return known;
    let select = spec.select;
    if (spec.minimal) {
      try {
        await this.client.list(spec.collection, {
          select: spec.select,
          top: 1,
          ...(spec.filter ? { filter: spec.filter } : {}),
        });
      } catch (e) {
        if (!(e instanceof OnecODataError) || e.retryable) throw e;
        select = spec.minimal;
      }
    }
    this.selects.set(spec.collection + (spec.filter ?? ''), select);
    return select;
  }

  /** Доп. реквизиты номенклатуры (ТЧ `ДополнительныеРеквизиты`) → `attributes[]` (05 §5.3, ONEC-004). */
  private async attachAttributes(items: OnecNomenclatureItem[]): Promise<void> {
    if (items.length === 0) return;
    const names = await this.loadPropertyNames();
    const byRef = new Map<string, OnecAttributeValue[]>();
    const valueRefs = new Set<string>();
    const raw: { owner: string; prop: string; value: unknown; type: string | null }[] = [];
    for (let i = 0; i < items.length; i += REFS_PER_FILTER) {
      const or = items
        .slice(i, i + REFS_PER_FILTER)
        .map((it) => `Ref_Key eq ${odataGuid(it.ref)}`)
        .join(' or ');
      let rows: ODataRow[];
      try {
        rows = await this.client.list('Catalog_Номенклатура_ДополнительныеРеквизиты', {
          select: ['Ref_Key', 'Свойство_Key', 'Значение', 'Значение_Type'],
          filter: or,
        });
      } catch (e) {
        if (e instanceof OnecODataError && !e.retryable) return; // нет ТЧ — свойства не загружаются (allow-list fallback)
        throw e;
      }
      for (const r of rows) {
        const owner = ref(r.Ref_Key);
        const prop = ref(r['Свойство_Key']);
        if (!owner || !prop) continue;
        const type = typeName(r['Значение_Type']);
        if (type && /^Catalog_/.test(type)) {
          const vr = ref(r['Значение']);
          if (vr) valueRefs.add(vr);
        }
        raw.push({ owner, prop, value: r['Значение'], type });
      }
    }
    const valueNames = await this.loadValueNames([...valueRefs]);
    for (const x of raw) {
      const isRef = x.type !== null && /^Catalog_/.test(x.type);
      const valueRef = isRef ? ref(x.value) : null;
      const list = byRef.get(x.owner) ?? [];
      list.push({
        propertyRef: x.prop,
        name: names.get(x.prop) ?? x.prop,
        valueType: x.type,
        valueRef,
        valueText: valueRef ? (valueNames.get(valueRef) ?? null) : str(x.value),
      });
      byRef.set(x.owner, list);
    }
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const attrs = byRef.get(it.ref);
      if (attrs) items[i] = { ...it, attributes: attrs };
    }
  }

  private async loadPropertyNames(): Promise<Map<string, string>> {
    if (this.propertyNames) return this.propertyNames;
    const out = new Map<string, string>();
    try {
      for await (const page of this.client.pages('ChartOfCharacteristicTypes_ДополнительныеРеквизитыИСведения', {
        select: ['Ref_Key', 'Description'],
      })) {
        for (const r of page.rows) {
          const k = ref(r.Ref_Key);
          const n = str(r.Description);
          if (k && n) out.set(k, n);
        }
      }
    } catch (e) {
      if (!(e instanceof OnecODataError) || e.retryable) throw e;
    }
    this.propertyNames = out;
    return out;
  }

  private async loadValueNames(refs: readonly string[]): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    for (let i = 0; i < refs.length; i += REFS_PER_FILTER) {
      const or = refs
        .slice(i, i + REFS_PER_FILTER)
        .map((k) => `Ref_Key eq ${odataGuid(k)}`)
        .join(' or ');
      try {
        const rows = await this.client.list('Catalog_ЗначенияСвойствОбъектов', {
          select: ['Ref_Key', 'Description'],
          filter: or,
        });
        for (const r of rows) {
          const k = ref(r.Ref_Key);
          const n = str(r.Description);
          if (k && n) out.set(k, n);
        }
      } catch (e) {
        if (!(e instanceof OnecODataError) || e.retryable) throw e;
      }
    }
    return out;
  }
}

function stockRow(r: ODataRow, withReserve: boolean): OnecStockRow | undefined {
  const productRef = ref(r['Номенклатура_Key']);
  const warehouseRef = ref(r['Склад_Key']);
  if (!productRef || !warehouseRef) return undefined;
  const onHand = odataDecimal(r['ВНаличииBalance']);
  const reserved = withReserve
    ? sumDecimals(odataDecimal(r['ВРезервеBalance']), odataDecimal(r['ВРезервеПодЗаказBalance']))
    : '0';
  return { warehouseRef, productRef, variantRef: ref(r['Характеристика_Key']), onHand, reserved, available: null };
}

/** Сумма двух десятичных строк до 3 знаков (целочисленно, без float). */
function sumDecimals(a: string, b: string): string {
  const milli = (s: string): bigint => {
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(s);
    if (!m) return 0n;
    const v = BigInt(m[2]) * 1000n + BigInt((m[3] ?? '').slice(0, 3).padEnd(3, '0'));
    return m[1] ? -v : v;
  };
  const t = milli(a) + milli(b);
  const neg = t < 0n;
  const s = (neg ? -t : t).toString().padStart(4, '0');
  return `${neg ? '-' : ''}${s.slice(0, -3)}.${s.slice(-3)}`;
}
