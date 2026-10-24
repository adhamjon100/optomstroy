import type { OnecCatalogItem, OnecObjectDeletionItem } from './onec-catalog.types.js';
import { OnecError } from './onec-error.js';
import type { OnecChangeItem, OnecChangesAck, OnecChangesPage, OnecChangesQuery } from './onec-gateway.js';
import { itemKey, type SyntheticCatalog } from './synthetic-catalog.js';

/**
 * Порядок типов в сообщении (тип объекта, затем ссылка — 05 §6.2 п. 1) — рекомендуемый порядок ТЗ для 1С 5.3 п. 6:
 * … скидки → заказы → реализации → платёжные документы → возвраты → события QR.
 */
export const TYPE_RANK: Readonly<Record<string, number>> = {
  Catalog_КлассификаторЕдиницИзмерения: 1,
  Catalog_Склады: 2,
  Catalog_ВидыЦен: 3,
  Catalog_Номенклатура: 4,
  Catalog_ХарактеристикиНоменклатуры: 5,
  Catalog_УпаковкиЕдиницыИзмерения: 6,
  InformationRegister_ШтрихкодыНоменклатуры: 7,
  Catalog_НоменклатураПрисоединенныеФайлы: 8,
  Document_УстановкаЦенНоменклатуры: 9,
  ObjectDeletion: 10,
  // Кассир (этап G): клиенты, затем скидки, затем документы, ссылающиеся на клиентов и товары.
  Catalog_Партнеры: 11,
  Catalog_Контрагенты: 12,
  Catalog_СоглашенияСКлиентами: 13,
  Catalog_СкидкиНаценки: 14,
  Document_ЗаказКлиента: 15,
  Document_РеализацияТоваровУслуг: 20,
  Document_ПриходныйКассовыйОрдер: 21,
  Document_ПоступлениеБезналичныхДенежныхСредств: 22,
  Document_ВозвратТоваровОтКлиента: 23,
  QrPaymentStatus: 30,
};

/** Дополнительный источник элементов плана обмена (например, синтетика кассира `SyntheticCashier`, этап G). */
export interface FakeExchangeSource {
  allItems(): readonly Readonly<Record<string, unknown>>[];
  itemByKey(key: string): object | undefined;
}

const DEFAULT_LIMIT = 1000;
const MAX_LIMIT = 5000;

interface IssuedMessage {
  readonly number: number;
  readonly keys: readonly string[];
}

/**
 * Модель плана обмена «POS» для `FakeOnecGateway` в режиме синтетического каталога (05 §6.2, ядро §22.8):
 * регистрации узла (номер 0 — не пронумерована), `ВыбратьИзменения(N+1)` нумерует все непронумерованные,
 * страницы — в устойчивом порядке, ack снимает регистрации с номером ≤ N+1, повторная регистрация после
 * нумерации сбрасывает номер (объект уходит в следующее сообщение), ack номера больше выданного — 409.
 */
export class FakeExchangePlan {
  /** key `type:ref` → номер сообщения (0 — не пронумерована). */
  private readonly registrations = new Map<string, number>();
  private readonly deletions = new Map<string, OnecObjectDeletionItem>();
  private current: IssuedMessage | undefined;
  private lastIssued = 0;
  lastAck = 0;
  /** Ошибки, которые вернуть на N-й (с 1) вызов `getChanges` (тест «сбой на странице»). */
  private readonly injected = new Map<number, OnecError>();
  private getCalls = 0;

  private readonly sources: FakeExchangeSource[] = [];

  /** `catalog = null` — план без каталога (только дополнительные источники, напр. кассир). */
  constructor(private readonly catalog: SyntheticCatalog | null) {}

  /** Подключить дополнительный источник элементов (кассир); его элементы участвуют в `registerAll`. */
  addSource(source: FakeExchangeSource): this {
    this.sources.push(source);
    return this;
  }

  /** Зарегистрировать весь состав (как `POST /changes/reregister`). */
  registerAll(): void {
    if (this.catalog) {
      for (const it of this.catalog.allItems()) this.registrations.set(itemKey(it), 0);
      for (const ps of this.catalog.priceSettings) this.registrations.set(itemKey(ps), 0);
    }
    for (const src of this.sources) {
      for (const it of src.allItems()) this.registrations.set(`${String(it.type)}:${String(it.ref)}`, 0);
    }
  }

  register(keys: readonly string[]): void {
    for (const k of keys) this.registrations.set(k, 0);
  }

  /** Физическое удаление объекта в 1С → элемент `ObjectDeletion` (05 §6.2 п. 1). */
  registerDeletion(objectType: string, ref: string): void {
    const item: OnecObjectDeletionItem = { type: 'ObjectDeletion', objectType, ref };
    const key = `ObjectDeletion:${objectType}:${ref}`;
    this.deletions.set(key, item);
    this.registrations.set(key, 0);
  }

  get backlog(): number {
    return this.registrations.size;
  }

  /** Ошибка на `call`-й (с 1, считая от текущего момента) вызов `getChanges`. */
  injectError(call: number, error: OnecError): void {
    this.injected.set(this.getCalls + call, error);
  }

  getChanges(query: OnecChangesQuery): OnecChangesPage {
    this.getCalls += 1;
    const err = this.injected.get(this.getCalls);
    if (err) {
      this.injected.delete(this.getCalls);
      throw err;
    }
    const limit = Math.min(Math.max(1, query.limit ?? DEFAULT_LIMIT), MAX_LIMIT);
    const number = query.since + 1;
    let offset = 0;
    if (query.cursor === undefined) {
      for (const [k, n] of this.registrations) if (n === 0) this.registrations.set(k, number);
      const keys = [...this.registrations.entries()]
        .filter(([, n]) => n > 0 && n <= number)
        .map(([k]) => k)
        .sort(compareKeys);
      this.current = { number, keys };
      this.lastIssued = Math.max(this.lastIssued, number);
    } else {
      const m = /^off:(\d+):(\d+)$/.exec(Buffer.from(query.cursor, 'base64').toString('utf8'));
      if (!m || !this.current || Number(m[1]) !== this.current.number || Number(m[1]) !== number) {
        throw new OnecError('getChanges', 400, 'POS_E_BAD_REQUEST', 'неизвестный cursor');
      }
      offset = Number(m[2]);
    }
    const msg = this.current;
    const slice = msg.keys.slice(offset, offset + limit);
    const items: OnecChangeItem[] = [];
    for (const k of slice) {
      // Объект, перерегистрированный после нумерации, выпадает из ещё не выданных страниц (05 §6.2 п. 1).
      if ((this.registrations.get(k) ?? 0) === 0) continue;
      const it = this.render(k);
      if (it) items.push(it as unknown as OnecChangeItem);
    }
    const next = offset + limit;
    const hasMore = next < msg.keys.length;
    return {
      messageNumber: msg.number,
      hasMore,
      cursor: hasMore ? Buffer.from(`off:${msg.number}:${next}`, 'utf8').toString('base64') : null,
      generatedAt: '2026-10-21T14:05:01+06:00',
      items,
    };
  }

  ack(messageNumber: number): OnecChangesAck {
    if (messageNumber > this.lastIssued) {
      throw new OnecError('ackChanges', 409, 'POS_E_ACK_OUT_OF_ORDER', `Номер сообщения ${messageNumber} не выдавался`);
    }
    let removed = 0;
    for (const [k, n] of [...this.registrations]) {
      if (n > 0 && n <= messageNumber) {
        this.registrations.delete(k);
        this.deletions.delete(k);
        removed += 1;
      }
    }
    this.lastAck = Math.max(this.lastAck, messageNumber);
    return { messageNumber, removedRegistrations: removed };
  }

  private render(key: string): OnecCatalogItem | object | undefined {
    const own = this.deletions.get(key) ?? this.catalog?.itemByKey(key);
    if (own) return own;
    for (const src of this.sources) {
      const it = src.itemByKey(key);
      if (it) return it;
    }
    return undefined;
  }
}

function compareKeys(a: string, b: string): number {
  const ta = a.slice(0, a.indexOf(':'));
  const tb = b.slice(0, b.indexOf(':'));
  const ra = TYPE_RANK[ta] ?? 50;
  const rb = TYPE_RANK[tb] ?? 50;
  if (ra !== rb) return ra - rb;
  return a < b ? -1 : a > b ? 1 : 0;
}
