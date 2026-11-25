import { createHash } from 'node:crypto';
import { type OsApiCharacteristic, type OsApiItem, type OsApiUnit, osApiRef } from './onec-osapi.client.js';

/**
 * Перевод значений ОС_API в формат модели (ADR-126): деньги — строка с двумя знаками, количества — с тремя, даты 1С
 * без зоны — локальное время Бишкека `+06:00` (как `odataDate`, ONEC-103). Округления нет: число с большим
 * числом знаков передаётся как есть, и применение отклоняет позицию ошибкой (`VALIDATION`, видно в `sync_errors`),
 * а не меняет сумму молча.
 */

/** JSON-число/строка → десятичная строка без экспоненты; не число → `null`. */
function decimalText(v: unknown): string | null {
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) return null;
    const s = String(v);
    return /e/i.test(s) ? v.toFixed(6).replace(/\.?0+$/, '') : s;
  }
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim())) return v.trim();
  return null;
}

function fixed(v: unknown, places: number): string | null {
  const s = decimalText(v);
  if (s === null) return null;
  const m = /^(-?\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) return s;
  const frac = (m[2] ?? '').replace(/0+$/, '');
  if (frac.length > places) return s;
  return `${m[1]}.${frac.padEnd(places, '0')}`;
}

/** Деньги ОС_API (JSON-число) → `^-?\d+\.\d{2}$`; больше двух знаков — исходная строка (отказ при применении). */
export function osApiMoney(v: unknown): string {
  return fixed(v, 2) ?? '';
}

/** Количество ОС_API → `^-?\d+\.\d{3}$`; больше трёх знаков — исходная строка (отказ при применении). */
export function osApiQty(v: unknown): string {
  return fixed(v, 3) ?? '';
}

/** Дата 1С ISO без зоны (Module.bsl:2852-2853, локальная дата) → ISO с `+06:00`; пустая дата 1С → `null`. */
export function osApiDate(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  if (s === '' || s.startsWith('0001-01-01')) return null;
  return /([+-]\d{2}:\d{2}|Z)$/.test(s) ? s : `${s}+06:00`;
}

/** Пространство имён производных ссылок POS (UUID v5): характеристика/упаковка категории × товар. */
const DERIVED_NAMESPACE = Buffer.from('6f2b9d0e7c4a4e1b9a3d5c8e1f0a2b4c', 'hex');

/**
 * Производная ссылка (UUID v5, детерминированная) для характеристики или упаковки, владелец которой — КАТЕГОРИЯ
 * номенклатуры УНФ (`ownerType = category`): в 1С один элемент действует для всех товаров категории, а в модели
 * вариант/упаковка принадлежит одному товару (общие характеристики не поддержаны, Q-021). Поэтому на каждую пару
 * «элемент категории × товар» заводится своя ссылка; цены, остатки и штрихкоды с этим элементом переводятся на неё.
 * Обратный перевод (для записи в 1С) — по той же паре; запись через ОС_API в этом режиме выключена (ADR-126).
 */
export function osApiDerivedRef(kind: 'characteristic' | 'unit', sharedRef: string, itemRef: string): string {
  const h = createHash('sha1')
    .update(DERIVED_NAMESPACE)
    .update(`osapi:${kind}:${sharedRef}:${itemRef}`, 'utf8')
    .digest();
  const b = Buffer.from(h.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const x = b.toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/** Владелец «товар» / «категория»; прочие (`unitSet`, `other`) в модели не представимы — пропускаются. */
function ownerKind(t: unknown): 'item' | 'category' | null {
  return t === 'item' ? 'item' : t === 'category' ? 'category' : null;
}

/**
 * Строка (цена, штрихкод) на единице, которую модель не может представить: упаковка с владельцем `unitSet`/`other`
 * (`ТипВладельца`, Module.bsl:2737-2748; `ВидЕдиницы` отдаёт `package` для любого `Справочник.ЕдиницыИзмерения`,
 * Module.bsl:2751-2758), упаковка категории для товара вне категории или упаковка, которой нет в `/units`. Такой
 * упаковки в реплике нет (`OsApiCatalogSource` её не создаёт), поэтому строка пропускается намеренно — без ссылки
 * на несуществующую упаковку и без ошибки применения на каждом опросе.
 */
export const OSAPI_UNREPRESENTABLE = Symbol('osapi-unrepresentable');
export type OsApiUnrepresentable = typeof OSAPI_UNREPRESENTABLE;

/**
 * Справочный индекс выгрузок `/items`, `/characteristics`, `/units`: товары по категориям, владельцы характеристик
 * и упаковок — для разворота элементов категории по товарам и перевода ссылок строк цен/остатков/штрихкодов.
 */
export class OsApiCatalogIndex {
  readonly items = new Map<string, OsApiItem>();
  /** categoryId → товары (не группы) категории. */
  readonly byCategory = new Map<string, string[]>();
  private readonly charOwner = new Map<string, 'item' | 'category' | null>();
  private readonly unitOwner = new Map<string, { kind: 'item' | 'category' | null; ownerId: string | null }>();

  constructor(
    items: readonly OsApiItem[],
    characteristics: readonly OsApiCharacteristic[] = [],
    units: readonly OsApiUnit[] = [],
  ) {
    for (const it of items) {
      const id = osApiRef(it.id);
      if (!id) continue;
      this.items.set(id, it);
      const cat = osApiRef(it.categoryId);
      if (!it.isGroup && cat) {
        const list = this.byCategory.get(cat) ?? [];
        list.push(id);
        this.byCategory.set(cat, list);
      }
    }
    for (const c of characteristics) {
      const id = osApiRef(c.id);
      if (id) this.charOwner.set(id, ownerKind(c.ownerType));
    }
    for (const u of units) {
      const id = osApiRef(u.id);
      if (id) this.unitOwner.set(id, { kind: ownerKind(u.ownerType), ownerId: osApiRef(u.ownerId) });
    }
  }

  /** Ссылка варианта для строки «товар + характеристика»; без характеристики — `null` (служебный вариант). */
  variantRef(itemId: unknown, characteristicId: unknown): string | null {
    const ch = osApiRef(characteristicId);
    if (!ch) return null;
    const item = osApiRef(itemId);
    if (item && this.charOwner.get(ch) === 'category') return osApiDerivedRef('characteristic', ch, item);
    return ch;
  }

  /**
   * Владелец характеристики по `/characteristics`: `item`/`category`; `null` — владелец не представим
   * (`unitSet`/`other`); `undefined` — характеристики нет в выгрузке.
   */
  characteristicOwner(characteristicId: unknown): 'item' | 'category' | null | undefined {
    const ch = osApiRef(characteristicId);
    return ch ? this.charOwner.get(ch) : undefined;
  }

  /**
   * Ссылка упаковки для строки цены/штрихкода: `null` — базовая единица классификатора (строка без упаковки);
   * `OSAPI_UNREPRESENTABLE` — упаковки нет в реплике (см. выше), строка пропускается.
   *
   * `unitKind` — признак строки ОС_API (`package` у цен, Module.bsl:372); у штрихкодов его нет (Module.bsl:334), и
   * единица, которой нет в `/units`, считается базовой (так её и отдаёт 1С для единиц классификатора).
   */
  packagingRef(itemId: unknown, unitId: unknown, unitKind?: unknown): string | null | OsApiUnrepresentable {
    const u = osApiRef(unitId);
    if (!u) return null;
    const owner = this.unitOwner.get(u);
    if (!owner) return unitKind === 'package' ? OSAPI_UNREPRESENTABLE : null;
    if (owner.kind === 'item') return u;
    if (owner.kind === 'category') {
      const item = osApiRef(itemId);
      const inCategory =
        item !== null && owner.ownerId !== null && (this.byCategory.get(owner.ownerId) ?? []).includes(item);
      return inCategory ? osApiDerivedRef('unit', u, item) : OSAPI_UNREPRESENTABLE;
    }
    return OSAPI_UNREPRESENTABLE;
  }
}
