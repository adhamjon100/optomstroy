/**
 * Элементы каталога в формате контракта `contracts/onec/onec-http-service.v1.yaml` (`ChangeItem` элементов
 * `/changes`, `CatalogCard`) — общий «канонический» вид данных 1С для адаптеров (HS расширения, OData фазы 0,
 * фикстуры и синтетический генератор) и конвейера применения `sync/apply` (RM-E-001).
 *
 * Только поля, на которые опирается маппинг; прочие (ONEC-058: неизвестные поля) просто игнорируются.
 * Срезы цен и остатков (`OnecPriceRow`, `OnecStockRow`) в `/changes` не передаются (05 §6.2: регистры остатков не
 * входят в план обмена, цены — перечитка среза по `Document_УстановкаЦенНоменклатуры`); их форма — `CatalogPrice`/
 * `CatalogStock` карточки плюс `productRef` (у карточки он задан контекстом).
 */

export const ONEC_TYPE = {
  nomenclature: 'Catalog_Номенклатура',
  variant: 'Catalog_ХарактеристикиНоменклатуры',
  packaging: 'Catalog_УпаковкиЕдиницыИзмерения',
  unit: 'Catalog_КлассификаторЕдиницИзмерения',
  warehouse: 'Catalog_Склады',
  priceList: 'Catalog_ВидыЦен',
  barcode: 'InformationRegister_ШтрихкодыНоменклатуры',
  imageFile: 'Catalog_НоменклатураПрисоединенныеФайлы',
  priceSetting: 'Document_УстановкаЦенНоменклатуры',
  deletion: 'ObjectDeletion',
} as const;

/** Все типы элементов `ChangeItem` контракта (discriminator `type`). Иной тип — ошибка данных (NOTES §3 п. 11). */
export const ONEC_CHANGE_TYPES = [
  'Catalog_Номенклатура',
  'Catalog_ХарактеристикиНоменклатуры',
  'Catalog_УпаковкиЕдиницыИзмерения',
  'Catalog_КлассификаторЕдиницИзмерения',
  'Catalog_Склады',
  'Catalog_ВидыЦен',
  'Catalog_Партнеры',
  'Catalog_Контрагенты',
  'Catalog_СоглашенияСКлиентами',
  'Catalog_СкидкиНаценки',
  'Catalog_НоменклатураПрисоединенныеФайлы',
  'InformationRegister_ШтрихкодыНоменклатуры',
  'Document_УстановкаЦенНоменклатуры',
  'Document_ЗаказКлиента',
  'Document_РеализацияТоваровУслуг',
  'Document_ПриходныйКассовыйОрдер',
  'Document_ПоступлениеБезналичныхДенежныхСредств',
  'Document_ВозвратТоваровОтКлиента',
  'QrPaymentStatus',
  'ObjectDeletion',
] as const;
export type OnecChangeType = (typeof ONEC_CHANGE_TYPES)[number];

export interface OnecAttributeValue {
  readonly propertyRef: string;
  readonly name: string;
  readonly valueType?: string | null;
  readonly valueRef?: string | null;
  readonly valueText?: string | null;
}

interface Versioned {
  readonly ref: string;
  readonly dataVersion: string;
  readonly deletionMark: boolean;
}

export interface OnecNomenclatureItem extends Versioned {
  readonly type: 'Catalog_Номенклатура';
  readonly isFolder: boolean;
  readonly code?: string | null;
  readonly description: string;
  readonly fullName?: string | null;
  readonly sku?: string | null;
  readonly parentRef?: string | null;
  readonly baseUnitRef?: string | null;
  readonly kindRef?: string | null;
  readonly descriptionText?: string | null;
  readonly imageFileRef?: string | null;
  /** Предложение (ТЗ для 1С 5.4, вопрос 31; контракт `NomenclatureChange.brand`, `x-status: proposed`): бренд. */
  readonly brand?: string | null;
  readonly isWeighted?: boolean | null;
  readonly attributes?: readonly OnecAttributeValue[];
}

export interface OnecVariantItem extends Versioned {
  readonly type: 'Catalog_ХарактеристикиНоменклатуры';
  readonly code?: string | null;
  readonly description: string;
  readonly ownerRef: string;
  readonly ownerType?: string | null;
  readonly sku?: string | null;
  readonly attributes?: readonly OnecAttributeValue[];
}

export interface OnecPackagingItem extends Versioned {
  readonly type: 'Catalog_УпаковкиЕдиницыИзмерения';
  readonly description: string;
  readonly ownerRef: string;
  readonly ownerType?: string | null;
  readonly unitRef?: string | null;
  /** Количество `^\d+\.\d{3}$`. */
  readonly factor: string;
}

export interface OnecUnitItem extends Versioned {
  readonly type: 'Catalog_КлассификаторЕдиницИзмерения';
  readonly code?: string | null;
  readonly description: string;
}

export interface OnecWarehouseItem extends Versioned {
  readonly type: 'Catalog_Склады';
  readonly isFolder?: boolean | null;
  readonly code?: string | null;
  readonly description: string;
}

export interface OnecPriceListItem extends Versioned {
  readonly type: 'Catalog_ВидыЦен';
  readonly code?: string | null;
  readonly description: string;
  readonly currency?: string | null;
  readonly usedForSales?: boolean | null;
  readonly priceIncludesVat?: boolean | null;
}

export interface OnecBarcodeItem {
  readonly type: 'InformationRegister_ШтрихкодыНоменклатуры';
  /** Ключ набора — значение штрихкода. */
  readonly ref: string;
  readonly barcode: string;
  readonly productRef: string;
  readonly variantRef?: string | null;
  readonly packagingRef?: string | null;
  readonly barcodeType?: string | null;
}

export interface OnecImageFileItem extends Versioned {
  readonly type: 'Catalog_НоменклатураПрисоединенныеФайлы';
  readonly ownerRef?: string | null;
  readonly size: number;
  readonly extension: string;
  readonly modifiedAt: string;
  /** Предложение (ТЗ для 1С 5.4, вопрос 32; контракт `ImageFileChange.isMain`, `x-status: proposed`): главный файл. */
  readonly isMain?: boolean | null;
}

export interface OnecPriceSettingItem extends Versioned {
  readonly type: 'Document_УстановкаЦенНоменклатуры';
  readonly number: string;
  readonly date: string;
  readonly posted: boolean;
  readonly priceListRefs: readonly string[];
}

export interface OnecObjectDeletionItem {
  readonly type: 'ObjectDeletion';
  readonly objectType: string;
  readonly ref: string;
}

/** Элементы каталога, которые применяет `sync/apply` (остальные типы — обработчики других модулей). */
export type OnecCatalogItem =
  | OnecNomenclatureItem
  | OnecVariantItem
  | OnecPackagingItem
  | OnecUnitItem
  | OnecWarehouseItem
  | OnecPriceListItem
  | OnecBarcodeItem
  | OnecImageFileItem
  | OnecPriceSettingItem
  | OnecObjectDeletionItem;

/** Строка среза цен (`InformationRegister_ЦеныНоменклатуры/SliceLast`, `CatalogPrice` + `productRef`). */
export interface OnecPriceRow {
  readonly priceListRef: string;
  readonly productRef: string;
  /** `null` — цена товара без характеристики (служебный вариант `is_default`). */
  readonly variantRef: string | null;
  readonly packagingRef: string | null;
  /** Деньги `^\d+\.\d{2}$` (ONEC-058). */
  readonly price: string;
  readonly period?: string | null;
  readonly documentRef?: string | null;
}

/** Строка среза остатков (`ТоварыНаСкладах`/`СвободныеОстатки` `Balance`, `CatalogStock` + `productRef`). */
export interface OnecStockRow {
  readonly warehouseRef: string;
  readonly productRef: string;
  readonly variantRef: string | null;
  /** Количества `^-?\d+\.\d{3}$`. */
  readonly onHand: string;
  readonly reserved: string;
  /** Свободный остаток 1С; `null` — 1С не отдаёт (тогда `available = quantity − reserved` в БД). */
  readonly available: string | null;
}
