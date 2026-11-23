// Маскирование персональных данных (§3.4) и вычистка секретов (§2.5).
// Один модуль для консоли и всех трёх файлов протокола. Порядок везде один: сначала вычистка секретов, потом маска ПДн
// (маска не должна переписать середину пароля или ключа так, что вычистка его потом не узнает).

// ---------------------------------------------------------------- секреты

export class Redactor {
  constructor() {
    this.secrets = new Set();
  }

  /** Регистрирует секрет и его производные формы (URL-кодирование, base64). */
  add(secret) {
    if (typeof secret !== 'string' || secret.length < 3) return;
    const forms = new Set([secret]);
    try { forms.add(encodeURIComponent(secret)); } catch { /* неверная суррогатная пара */ }
    forms.add(Buffer.from(secret, 'utf8').toString('base64'));
    forms.add(Buffer.from(secret, 'utf8').toString('base64').replace(/=+$/, ''));
    for (const f of forms) if (f.length >= 3) this.secrets.add(f);
  }

  /** base64(user:password) — то, что уходит в заголовке Basic. */
  addBasic(user, password) {
    if (typeof password !== 'string' || !password) return;
    const b = Buffer.from(`${user}:${password}`, 'utf8').toString('base64');
    this.secrets.add(b);
    this.secrets.add(b.replace(/=+$/, ''));
    this.add(`${user}:${password}`);
  }

  redact(text) {
    if (text == null) return text;
    let s = String(text);
    // Заголовок Authorization: значение — всегда «Basic …» или «Bearer …», поэтому свободный текст не задевается.
    s = s.replace(/(Authorization["']?\s*[:=]\s*["']?)(Basic|Bearer)\s+[A-Za-z0-9+/=._~-]+/gi, '$1$2 ***');
    // X-POS-Client-Key — только настоящие заголовки: строка «Имя: значение» с начала строки, JSON и util.inspect
    // (имя в кавычках). Подписи проверок вроде «без заголовка X-POS-Client-Key — 401» не трогаются.
    // Заглушки программы «***» и «(нет)» не трогаются.
    s = s.replace(/(^|\n)([ \t]*X-POS-Client-Key[ \t]*:[ \t]*)(?![(*])[^\s"',}]+/gi, '$1$2***');
    s = s.replace(/(["']X-POS-Client-Key["']\s*:\s*["'])(?![(*])[^"'\r\n]+/gi, '$1***');
    const list = [...this.secrets].sort((a, b) => b.length - a.length);
    for (const sec of list) {
      if (!sec) continue;
      s = s.split(sec).join('***');
    }
    return s;
  }
}

// ---------------------------------------------------------------- ПДн

const GUID_G = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;
const GUID_ONLY = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
// Только настоящие даты (19xx/20xx, месяц 01–12, день 01–31), не часть телефона вида 0555-12-34-56.
const DATE_G = /(?<!\d)(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?(?!-?\d)/g;
const DATETIME_ONLY = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;
// Границы: не приклеено к букве или цифре; не часть суммы вида 123456789.50.
const NB = '(?<![\\p{L}\\p{N}_]|\\d[.,])';
const NA = '(?![\\p{L}\\p{N}_]|[.,]\\d)';
// +996XXXXXXXXX, 996XXXXXXXXX, 00996… — с пробелами, дефисами и скобками.
const PHONE_INTL_G = new RegExp(`${NB}(?:\\+|00)?\\(?996\\)?(?:[\\s\\-()]*\\d){9}${NA}`, 'gu');
// 0XXXXXXXXX: после 0 — код оператора с цифры 2–9 (коды и номера 1С вида 00-00001234, 0000-000123 так не начинаются).
const PHONE_LOCAL0_G = new RegExp(`${NB}\\(?0\\)?[\\s\\-]*\\(?[2-9](?:[\\s\\-()]*\\d){8}${NA}`, 'gu');
// 9 цифр без 0 и 996, первая 2–9: 555 12 34 56, (555) 123-456, 700 123 456, 555123456.
const PHONE_LOCAL9_G = new RegExp(`${NB}\\(?[2-9]\\d{2}\\)?(?:[\\s\\-]*\\d){6}${NA}`, 'gu');
// Прочие номера E.164.
const PHONE_E164_G = new RegExp(`${NB}\\+[1-9](?:[\\s\\-()]*\\d){7,14}${NA}`, 'gu');
// ИНН (ПИН) Кыргызстана — 14 цифр, первая 0, 1 или 2; рядом со словом «ИНН» — любые 10–16 цифр с пробелами.
const INN_G = new RegExp(`${NB}[0-2]\\d{13}${NA}`, 'gu');
const INN_WORD_G = /((?:ИНН|INN|ПИН|PIN)\s*[:№#=]?\s*)(\d(?:[\s-]?\d){9,15})(?!\d)/giu;
const EMAIL_G = /[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.\p{L}{2,}/gu;
// Имя после слова «клиент», «покупатель», «контрагент», «ФИО», «получатель»… — одно-три слова с заглавной буквы
// или организация (ОсОО, ООО, ИП…). Так скрываются имена, которых программа ещё не видела в /changes.
// Без флага i: регистр важен для имени (с заглавной); слово-подсказка — в любом регистре ([Кк][Лл]…).
// (Модификатор (?i:…) с альтернативами в V8 13 работает не для всех вариантов — не используется.)
const ci = (w) => [...w].map((ch) => (ch.toUpperCase() === ch.toLowerCase() ? (ch === ' ' ? '\\s+' : ch) : `[${ch.toUpperCase()}${ch.toLowerCase()}]`)).join('');
const PERSON_CUE = `(?:${['клиент', 'покупател', 'партнер', 'партнёр', 'контрагент', 'получател', 'заказчик', 'плательщик', 'директор', 'менеджер', 'ответственн']
  .map((w) => `${ci(w)}\\p{L}*`).join('|')}|${ci('фио')}|${ci('контактное лицо')}|${ci('лицо')})`;
const ORG_FORM = '(?:ОсОО|ООО|ОАО|ЗАО|ОДО|ЧП|ИП|АО)';
const PERSON_NAME = '(?:[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?|[А-ЯЁ]\\.)';
const ORG_FULL = `${ORG_FORM}\\s*(?:«[^»\\n]{1,60}»|"[^"\\n]{1,60}"|${PERSON_NAME}(?:[\\s-]+${PERSON_NAME}){0,3})`;
// Регистр букв важен для имени (с заглавной), не для слова-подсказки: (?i:…) только вокруг подсказки.
const NAME_AFTER_CUE_G = new RegExp(`((?<![\\p{L}])${PERSON_CUE}[\\s:«"]*)(${ORG_FULL}|${PERSON_NAME}(?:\\s+${PERSON_NAME}|\\s*[А-ЯЁ]\\.){0,3})`, 'gu');
const ORG_NAME_G = new RegExp(`(?<![\\p{L}])${ORG_FULL}`, 'gu');

// Имя человека без слова-подсказки (Требования §4.6: message «без имён клиентов»; имена клиентов и контактных лиц скрыты).
// Надёжные формы — отчество (-ович, -евич, -ьич, -овна, -евна, -ична), «уулу»/«кызы», «Фамилия И. О.» / «И. О. Фамилия»:
// скрываются в любом тексте (консоль, протокол) и в E9 — ОШИБКА. Слабая форма «Фамилия Имя» (фамилия на -ов, -ев, -ин,
// -ский…): скрывается в тексте ошибки 1С; в E9 — ОШИБКА после слова «клиент», «партнёр»…, иначе ЗАМЕЧАНИЕ (так же
// пишутся склады и товары: «Магазин Аламедин»).
const R = String.raw;
const CAPW = R`[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?`;
const LBW = R`(?<![\p{L}\p{N}_])`;
const RBW = R`(?![\p{L}\p{N}_])`;
const PATRO = R`[А-ЯЁ][а-яё]+(?:вич|ьич|мич|кич|овна|евна|ична)`;
const CAPL = R`[A-Z][a-z]+`;
const PATRO_LAT = R`[A-Z][a-z]+(?:ovich|evich|ovna|evna|ichna)`;
const PERSON_STRONG = [
  R`${LBW}(?:${CAPW}\s+){1,2}${PATRO}(?:\s+${CAPW})?${RBW}`,
  R`${LBW}${PATRO}\s+${CAPW}${RBW}`,
  R`${LBW}(?:${CAPW}\s+){1,3}(?:[Уу]улу|[Кк]ызы)${RBW}`,
  R`${LBW}${CAPW}\s+[А-ЯЁ]\.\s?[А-ЯЁ]\.`,
  R`${LBW}[А-ЯЁ]\.\s?[А-ЯЁ]\.\s?${CAPW}${RBW}`,
  R`${LBW}(?:${CAPL}\s+){1,2}${PATRO_LAT}(?:\s+${CAPL})?${RBW}`,
  R`${LBW}(?:${CAPL}\s+){1,3}(?:uulu|kyzy)${RBW}`,
].join('|');
const PERSON_STRONG_G = new RegExp(PERSON_STRONG, 'gu');
const PERSON_STRONG_1 = new RegExp(PERSON_STRONG, 'u');
const SURN = R`[А-ЯЁ][а-яё]{2,}(?:ов|ев|ёв|ин|ын)а?|[А-ЯЁ][а-яё]+(?:ский|ская|цкий|цкая|енко)`;
const PERSON_WEAK = R`${LBW}(?:(?:${SURN})\s+${CAPW}(?:\s+${CAPW})?|${CAPW}\s+(?:${SURN}))${RBW}`;
const PERSON_WEAK_G = new RegExp(PERSON_WEAK, 'gu');
const PERSON_WEAK_1 = new RegExp(PERSON_WEAK, 'u');

// Адрес по признакам: «г. Бишкек», «ул. …», «мкр. 7», «пр-т …», «с. …», «кв. 5», «дом 12» — с признака до конца
// перечня через запятую. «2026 г.», «5 с.», «10 кв. м» адресом не считаются.
const ADDR_MARK = [
  R`(?<!\d\s?)[Гг]\.\s?(?=[А-ЯЁ])`, R`[Гг]ород\s+(?=[А-ЯЁ])`, R`[Уу]л\.\s?`, R`[Уу]лица\s+`,
  R`[Мм]кр(?:-н|\.)?\s?(?=[\dА-ЯЁ«"])`, R`[Мм]икрорайон\s+`, R`[Жж]\/м\s?`, R`[Жж]илмассив\s+`,
  R`[Пп]р-т\s?`, R`[Пп]росп\.\s?`, R`[Пп]роспект\s+`, R`[Пп]р\.\s?(?=[А-ЯЁ])`, R`[Пп]ер\.\s?(?=[А-ЯЁ\d])`, R`[Пп]ереулок\s+`,
  R`[Бб]ул\.\s?(?=[А-ЯЁ])`, R`[Бб]ульвар\s+`, R`(?<!\d\s?)[Сс]\.\s?(?=[А-ЯЁ])`, R`[Сс]ело\s+(?=[А-ЯЁ])`, R`[Пп]ос\.\s?(?=[А-ЯЁ])`,
  R`[Кк]в\.\s?(?=\d)`, R`[Дд]ом\s+(?=\d)`,
].join('|');
const ADDRESS_SRC = R`(?<![\p{L}\p{N}._\-])(?:${ADDR_MARK})[^,;"\n<>()\u0000]{1,50}(?:,\s*[^,;"\n<>()\u0000]{1,40}){0,5}`;
const ADDRESS_G = new RegExp(ADDRESS_SRC, 'gu');
const ADDRESS_1 = new RegExp(ADDRESS_SRC, 'u');

export const MASK_NAME = '[имя скрыто]';
export const MASK_ADDRESS = '[адрес скрыт]';
export const MASK_INN = '[ИНН скрыт]';
export const MASK_EMAIL = '[e-mail скрыт]';
export const MASK_TEXT = '[текст скрыт]';

export function maskPhone(raw) {
  const digits = String(raw).replace(/\D/g, '');
  const last2 = digits.slice(-2).padStart(2, '*');
  if (String(raw).trim().startsWith('+') && !digits.startsWith('996')) return `+*** *** ** ${last2}`;
  return `+996 *** ** ${last2}`;
}

const SELFTEST_PREFIX = 'ПРОВЕРКА POS';

// Предопределённые и общие «имена» партнёров 1С — не персональные данные (Требования §1.2 п. 4: customer.ref = null —
// розничный покупатель): в список имён клиентов не попадают, в тексте ошибки не считаются именем клиента.
const GENERIC_NAMES = new Set([
  'розничный покупатель', 'розничный клиент', 'розничные покупатели', 'розничные клиенты', 'розница', 'розничный',
  'покупатель', 'покупатели', 'клиент', 'клиенты', 'покупатель розничный', 'клиент розничный',
  'физическое лицо', 'физические лица', 'физлицо', 'физ. лицо', 'физ.лицо', 'частное лицо', 'частные лица',
  'не указан', 'не указано', 'не указана', 'не указаны', '<не указан>', 'неизвестный', 'неизвестный покупатель',
  'неизвестный клиент', 'неизвестно', 'прочие', 'прочие покупатели', 'прочие клиенты', 'разные', 'разовый покупатель',
  'разовый клиент', 'анонимный покупатель', 'анонимный клиент', 'население', 'без клиента', 'основной покупатель',
  'наличный расчет',
]);
/** Предопределённое или общее имя партнёра («Розничный покупатель», «Физическое лицо», «Не указан»). */
export function isGenericName(n) {
  return GENERIC_NAMES.has(String(n).toLowerCase().replace(/ё/g, 'е').replace(/[«»"']/g, '').replace(/\s+/g, ' ').trim());
}

// Наименование товара в «…» после слова «товар», «номенклатура», «картинка товара», «характеристика», «упаковка»
// (до трёх слов между ними: «товар с кодом 00-001 «…»»). Требования §4.6 наименования товаров в тексте ошибки не запрещают.
export const PRODUCT_QUOTE_G = /(?<!\p{L})(?:товар|номенклатур|характеристик|упаковк|изделие|материал)\p{L}*(?:\s+[^\s«»]+){0,3}?\s*«[^«»\n]{1,200}»/giu;

/** Текст, где наименования товаров в «…» заменены на «ъ» той же длины (индексы совпадают). */
export function blankProductNames(text) {
  return String(text ?? '').replace(PRODUCT_QUOTE_G, (m) => {
    const q = m.indexOf('«');
    return m.slice(0, q + 1) + m.slice(q + 1, -1).replace(/[^\s]/gu, 'ъ') + '»';
  });
}

const escRe = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const wordRe = (n, flags) => new RegExp(`(?<![\\p{L}\\p{N}])${escRe(n)}(?![\\p{L}\\p{N}])`, flags);

/** Вид клиента по полю kind (CustomerKind: individual, entrepreneur, legal): true — человек, false — юрлицо, null — неизвестно. */
function personOf(v) {
  const k = v && typeof v.kind === 'string' ? v.kind : null;
  if (k === 'individual' || k === 'entrepreneur') return true;
  if (k === 'legal') return false;
  return null;
}

/** Ключи, значения которых не маскируются (кроме проверки вида значения внутри свободного текста). */
const SAFE_KEYS = new Set([
  'type', 'objectType', 'documentType', 'code', 'number', 'status', 'currency', 'kind', 'sku', 'barcode',
  'barcodeType', 'dataVersion', 'onecStatus', 'reasonCode', 'paymentMethod', 'paymentTerms', 'method',
  'supplyOption', 'fulfillmentState', 'reference', 'bankReference', 'extension', 'apiVersion',
  'extensionVersion', 'platform', 'configuration', 'configurationVersion', 'exchangeNode', 'cursor',
  'valueType', 'qrPayload', 'qrImagePng', 'purpose', 'createdByUserCode', 'cashierUserCode',
]);

const PARTNER_TYPES = new Set(['Catalog_Партнеры', 'Catalog_Контрагенты']);
const AGREEMENT_TYPE = 'Catalog_СоглашенияСКлиентами';
// Слова в имени ключа, по которым значение — имя человека или организации-клиента.
const PERSON_KEY_WORDS = new Set(['customer', 'client', 'partner', 'counterparty', 'contractor', 'receiver', 'recipient', 'contact',
  'buyer', 'payer', 'courier', 'driver', 'employee', 'cashier', 'agent', 'owner', 'signer', 'accountant']);
const PERSON_KEY_LAST = new Set(['fio', 'фио', 'contact', 'contacts', 'person', 'persons', 'director', 'manager',
  'responsible', 'accountant', 'signer', 'receiver', 'recipient']);

function keyWords(key) {
  return String(key ?? '').replace(/([a-zа-яё0-9])([A-ZА-ЯЁ])/g, '$1 $2').toLowerCase().split(/[^a-zа-яё0-9]+/).filter(Boolean);
}

// Ключи 1С по-русски и транслитом (реквизиты документов «как есть»: КонтактноеЛицо, Ответственный, otvetstvennyi…):
// начало слова ключа → вид значения. Ключи контракта 1.2.0 (латиница, customerRef, partnerRef…) так не совпадают.
const ADDRESS_KEY_PREFIXES = ['addr', 'adres', 'adress', 'адрес', 'улиц', 'ulic', 'street', 'квартир', 'kvartir', 'apartment',
  'местонахожд', 'mestonahozhd', 'location', 'локаци'];
const PLACE_WORDS = ['мест', 'mesto', 'place', 'point', 'пункт', 'punkt'];
const DELIVERY_WORDS = ['доставк', 'dostavk', 'delivery', 'shipping'];
const PHONE_KEY_PREFIXES = ['телефон', 'telefon', 'мобильн', 'mobiln', 'сотов', 'sotov'];
const EMAIL_KEY_PREFIXES = ['почт', 'pocht', 'элпочт', 'elpocht', 'емейл', 'имейл', 'email', 'e-mail'];
const PERSON_KEY_PREFIXES = ['лицо', 'контакт', 'ответствен', 'менеджер', 'покупател', 'получател', 'директор', 'водител', 'курьер',
  'клиент', 'контрагент', 'партнер', 'партнёр', 'заказчик', 'плательщик', 'фио', 'фамили', 'отчеств', 'сотрудник', 'кассир', 'продав',
  'бухгалтер', 'автор', 'подписант', 'представител', 'имя', 'физлиц', 'физическ',
  'fio', 'kontakt', 'otvetstv', 'menedzh', 'menedj', 'pokupat', 'poluchat', 'direktor', 'voditel', 'kurer', 'klient', 'kontragent',
  'zakazchik', 'platelsh', 'familiy', 'familii', 'otchestv', 'sotrudnik', 'kassir', 'prodavec', 'prodavets', 'buhgalter', 'bukhgalter',
  'avtor', 'podpisant', 'predstavitel', 'imya', 'fizlic', 'author'];
// Слова, после которых значение — ссылка, код, номер, дата, сумма или признак, а не имя («КлиентСсылка», «КодКлиента»).
const NOT_NAME_PREFIXES = ['ref', 'guid', 'uuid', 'ссылк', 'ssylk', 'код', 'kod', 'code', 'номер', 'nomer', 'number', 'дат', 'date',
  'сумм', 'summ', 'amount', 'колич', 'kolich', 'count', 'qty', 'флаг', 'flag', 'признак', 'priznak', 'тип', 'type', 'kind', 'статус',
  'status', 'верси', 'version', 'валют', 'currency', 'идентификатор', 'identifikator'];
const NOT_NAME_WORDS = new Set(['id', 'uid', 'vid', 'вид', 'tip', 'sum', 'num', 'is', 'has', 'est', 'data']);

const starts = (w, list) => list.some((p) => w.startsWith(p));

/** Вид значения по имени ключа (регулярно, не по точному имени): address, phone, email, inn, name или null. */
export function kindOfKey(key) {
  if (key == null || typeof key !== 'string') return null;
  const w = keyWords(key);
  if (!w.length) return null;
  if (w.some((x) => starts(x, ADDRESS_KEY_PREFIXES)) || /адрес/i.test(key)) return 'address';
  if (w.some((x) => starts(x, DELIVERY_WORDS)) && w.some((x) => starts(x, PLACE_WORDS))) return 'address';
  if (w.some((x) => ['phone', 'phones', 'tel', 'telephone', 'mobile', 'whatsapp', 'viber', 'telegram'].includes(x) || starts(x, PHONE_KEY_PREFIXES))
    || /телефон/i.test(key)) return 'phone';
  if (w.some((x) => x === 'email' || x === 'mail' || x === 'emails' || starts(x, EMAIL_KEY_PREFIXES)) || /почта|e-mail/i.test(key)) return 'email';
  if (w.includes('inn') || w.includes('pin') || /tax_?id|инн/i.test(key)) return 'inn';
  const last = w[w.length - 1];
  if (PERSON_KEY_LAST.has(last)) return 'name';
  if ((last === 'name' || last === 'names' || last === 'title') && w.slice(0, -1).some((x) => PERSON_KEY_WORDS.has(x))) return 'name';
  if (w.some((x) => starts(x, PERSON_KEY_PREFIXES)) && !w.some((x) => NOT_NAME_WORDS.has(x) || starts(x, NOT_NAME_PREFIXES))) return 'name';
  return null;
}

/** Вид по соседнему полю kind/type (контактная информация: {kind: 'phone', value: '…'}). */
function kindOfSibling(obj) {
  for (const k of ['kind', 'type', 'contactType', 'infoType']) {
    const v = obj[k];
    if (typeof v !== 'string') continue;
    if (/phone|тел|mobile|whatsapp|viber|telegram/i.test(v)) return 'phone';
    if (/mail|почт/i.test(v)) return 'email';
    if (/addr|адрес/i.test(v)) return 'address';
  }
  return null;
}

export class Masker {
  /** @param {{redactor?: Redactor}} [o] — вычистка секретов выполняется до маски в каждом тексте. */
  constructor({ redactor = null } = {}) {
    /** Имена клиентов, увиденные в этом прогоне (только в памяти): в тексте ошибки — E9 ОШИБКА. */
    this.names = new Set();
    /**
     * Однословные имена организаций и клиентов неизвестного вида («Мастер»): так же пишутся товары и марки
     * («Клей плиточный Мастер 25 кг»), поэтому в тексте ошибки — ЗАМЕЧАНИЕ, не ОШИБКА; в протоколе скрываются.
     */
    this.weakNames = new Set();
    this.wordRes = new Map();
    this.redactor = redactor;
  }

  /**
   * Запомнить имя клиента. person: true — физическое лицо или ИП (kind individual / entrepreneur), false — юрлицо
   * (legal), null — вид неизвестен (Catalog_Партнеры без kind). Предопределённые и общие («Розничный покупатель») не
   * запоминаются. Однословное имя — в E9 ОШИБКА только у физлица и ИП, иначе ЗАМЕЧАНИЕ.
   */
  noteName(name, { person = null } = {}) {
    if (typeof name !== 'string') return;
    const n = name.trim();
    if (n.length < 3 || n.startsWith(SELFTEST_PREFIX) || !/\p{L}/u.test(n) || isGenericName(n)) return;
    if (!/\s/.test(n) && person !== true) {
      if (!this.names.has(n)) this.weakNames.add(n);
      return;
    }
    this.names.add(n);
    this.weakNames.delete(n);
  }

  /** Есть ли имя в тексте: из двух слов и больше — подстрокой (как раньше), одно слово — только целым словом. */
  #hasName(s, n) {
    if (/\s/.test(n)) return s.includes(n);
    let re = this.wordRes.get(n);
    if (!re) { re = wordRe(n, 'u'); this.wordRes.set(n, re); }
    return re.test(s);
  }

  #replaceName(s, n) {
    if (/\s/.test(n)) return s.split(n).join(MASK_NAME);
    return s.replace(wordRe(n, 'gu'), MASK_NAME);
  }

  /**
   * Маскирование по виду значения: телефоны, ИНН, e-mail, имена клиентов и людей (отчество, «уулу», инициалы), адреса
   * по признакам (г., ул., мкр., кв.). GUID и даты не трогаются. weakNames — ещё и «Фамилия Имя» (для текста ошибки 1С).
   */
  maskText(text, { weakNames = false } = {}) {
    if (text == null) return text;
    let s = String(text);
    if (this.redactor) s = this.redactor.redact(s);
    const keep = [];
    const hold = (m) => { keep.push(m); return `\u0000${keep.length - 1}\u0000`; };
    s = s.replace(GUID_G, hold).replace(DATE_G, hold);
    // «ПРОВЕРКА POS …» — синтетические данные программы, видны как есть (кроме телефонов +996000…).
    s = s.replace(EMAIL_G, MASK_EMAIL);
    s = s.replace(INN_WORD_G, (_, a) => a + MASK_INN);
    s = s.replace(PHONE_INTL_G, (m) => maskPhone(m));
    s = s.replace(PHONE_E164_G, (m) => maskPhone(m));
    s = s.replace(PHONE_LOCAL0_G, (m) => maskPhone(m));
    s = s.replace(PHONE_LOCAL9_G, (m) => maskPhone(m));
    s = s.replace(INN_G, MASK_INN);
    if (this.names.size || this.weakNames.size) {
      const list = [...this.names, ...this.weakNames].sort((a, b) => b.length - a.length);
      for (const n of list) if (this.#hasName(s, n)) s = this.#replaceName(s, n);
    }
    s = s.replace(ADDRESS_G, MASK_ADDRESS);
    s = s.replace(PERSON_STRONG_G, MASK_NAME);
    s = s.replace(NAME_AFTER_CUE_G, (m, cue, name) => (name.startsWith('ПРОВЕРКА') ? m : cue + MASK_NAME));
    s = s.replace(ORG_NAME_G, MASK_NAME);
    if (weakNames) s = s.replace(PERSON_WEAK_G, MASK_NAME);
    // eslint-disable-next-line no-control-regex
    s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[Number(i)]);
    return s;
  }

  /**
   * Есть ли в тексте ПДн (для правила E9): точно — телефон, e-mail, ИНН рядом со словом «ИНН», увиденное имя клиента,
   * ФИО с отчеством, «уулу»/«кызы», «Фамилия И. О.», «Фамилия Имя» после слова «клиент», «партнёр»…
   * Коды и номера 1С (00-00001234, 0000-000123), даты, GUID и суммы ПДн не считаются.
   */
  findPii(text) {
    const s = String(text ?? '');
    const found = [];
    const clean = s.replace(GUID_G, ' ').replace(DATE_G, ' ');
    if (clean.match(EMAIL_G)) found.push('e-mail');
    const noMail = clean.replace(EMAIL_G, ' ');
    if (noMail.match(PHONE_INTL_G) || noMail.match(PHONE_E164_G) || noMail.match(PHONE_LOCAL0_G) || noMail.match(PHONE_LOCAL9_G)) found.push('телефон');
    INN_WORD_G.lastIndex = 0;
    if (INN_WORD_G.test(noMail)) found.push('ИНН');
    INN_WORD_G.lastIndex = 0;
    // Имя клиента только внутри «…» наименования товара («картинка товара «Клей Мастер 25 кг»») — не ОШИБКА (maybePii).
    const outside = blankProductNames(s);
    if ([...this.names].some((n) => this.#hasName(outside, n)) || this.#personName(noMail)) found.push('имя клиента');
    return found;
  }

  /** ФИО человека: надёжная форма где угодно или «Фамилия Имя» после слова-подсказки. */
  #personName(clean) {
    if (PERSON_STRONG_1.test(clean)) return true;
    for (const m of clean.matchAll(NAME_AFTER_CUE_G)) {
      if (m[2].startsWith('ПРОВЕРКА')) continue;
      if (PERSON_WEAK_1.test(m[2]) || PERSON_STRONG_1.test(m[2])) return true;
    }
    return false;
  }

  /**
   * Похоже на ПДн, но не наверняка (для E9 — ЗАМЕЧАНИЕ): 14 цифр без слова «ИНН», одно слово или организация после
   * «клиент …», «Фамилия Имя» без слова-подсказки, адрес.
   */
  maybePii(text) {
    const s = String(text ?? '');
    const out = [];
    const clean = s.replace(GUID_G, ' ').replace(DATE_G, ' ').replace(INN_WORD_G, ' ');
    INN_WORD_G.lastIndex = 0;
    if (clean.match(INN_G)) out.push('возможно, ИНН (14 цифр)');
    const outside = blankProductNames(s);
    const sure = [...this.names].some((n) => this.#hasName(outside, n)) || this.#personName(clean.replace(EMAIL_G, ' '));
    let named = false;
    for (const m of clean.matchAll(NAME_AFTER_CUE_G)) if (!m[2].startsWith('ПРОВЕРКА')) named = true;
    // Однословное имя организации вне наименования товара; имя клиента только внутри «…» наименования товара.
    const weak = [...this.weakNames].some((n) => this.#hasName(outside, n))
      || [...this.names].some((n) => this.#hasName(s, n) && !this.#hasName(outside, n));
    if (!sure && (named || weak || clean.match(ORG_NAME_G) || PERSON_WEAK_1.test(clean))) out.push('возможно, имя клиента');
    if (ADDRESS_1.test(clean)) out.push('возможно, адрес');
    return out;
  }

  /** Только запомнить имена клиентов из ответа (без маски): партнёры, контрагенты, кандидаты, запрос клиента. */
  collectNames(value) {
    const stack = [value];
    while (stack.length) {
      const v = stack.pop();
      if (Array.isArray(v)) { for (const x of v) if (x && typeof x === 'object') stack.push(x); continue; }
      if (!v || typeof v !== 'object') continue;
      const o = { person: personOf(v) };
      if (PARTNER_TYPES.has(v.type)) { this.noteName(v.description, o); this.noteName(v.fullName, o); }
      if (('phone' in v && 'name' in v && 'ref' in v) || ('dedupe' in v && 'name' in v)) { this.noteName(v.name, o); this.noteName(v.fullName, o); }
      for (const x of Object.values(v)) if (x && typeof x === 'object') stack.push(x);
    }
  }

  /**
   * Структурное маскирование JSON. mode: 'known' — структуры контракта 1.2.0;
   * 'unknown' — пробы новых методов (каждая строка с буквами скрывается целиком, кроме служебных ключей, GUID и дат).
   * foreignPaths — пути полей, которых нет в контракте 1.2.0 (валидатор: «поле … нет в контракте», «возможно, опечатка»;
   * вид пути — items[3].КонтактноеЛицо): POS их не читает, для проверки они не нужны — значение скрывается целиком
   * (кроме GUID, дат, чисел и служебных ключей); вложенный объект — как ответ пробы.
   */
  maskJson(value, { mode = 'known', foreignPaths = null } = {}) {
    return this.#walk(value, mode, null, null, null, '', foreignPaths && foreignPaths.size ? foreignPaths : null);
  }

  /** Значение поля вне контракта 1.2.0. */
  #foreign(x, key) {
    const kind = SAFE_KEYS.has(key) ? null : kindOfKey(key);
    if (typeof x === 'string') {
      if (kind) return this.#maskStr(x, kind === 'name' ? 'nameKey' : kind);
      const v = this.redactor ? this.redactor.redact(x) : x;
      if (!v || v.startsWith(SELFTEST_PREFIX) || GUID_ONLY.test(v) || DATETIME_ONLY.test(v)) return v;
      if (!SAFE_KEYS.has(key) && /\p{L}/u.test(v)) return MASK_TEXT;
      return this.maskText(v);
    }
    return this.#walk(x, 'unknown', key, null, kind === 'name' ? 'nameKey' : kind, '', null);
  }

  #maskStr(v, how) {
    if (typeof v !== 'string') return v;
    if (this.redactor) v = this.redactor.redact(v);
    if (v.startsWith(SELFTEST_PREFIX)) return v;
    // Чистые GUID и дата — не ПДн (ссылка под ключом «Клиент», «Ответственный»): остаются для разбора.
    if (how !== 'errtext' && how !== 'comment' && (GUID_ONLY.test(v) || DATETIME_ONLY.test(v))) return v;
    if (how === 'name') { if (!this.names.has(v.trim())) this.noteName(v); return v ? MASK_NAME : v; }
    if (how === 'nameNoNote') return v ? MASK_NAME : v;
    // Имя по смыслу ключа (Ответственный, КонтактноеЛицо…): в список имён — только из двух слов и больше, чтобы
    // слово вроде «Администратор» не считалось потом именем клиента в текстах ошибок (E9).
    if (how === 'nameKey') { if (/\S\s+\S/.test(v.trim())) this.noteName(v); return v ? MASK_NAME : v; }
    if (how === 'errtext') return this.maskText(v, { weakNames: true });
    if (how === 'phone') return v ? maskPhone(v) : v;
    if (how === 'inn') return v ? MASK_INN : v;
    if (how === 'address') return v ? MASK_ADDRESS : v;
    if (how === 'email') return v ? MASK_EMAIL : v;
    if (how === 'text') return v ? MASK_TEXT : v;
    if (how === 'comment') {
      // «POS <uuid> · POS-2026-000123 · свободный текст» — префикс остаётся, остальное скрыто.
      const m = v.match(/^(POS [0-9a-fA-F-]{36}(?: · POS-\d{4}-\d{6})?)( · .*)?$/);
      if (m) {
        if (!m[2]) return v;
        const rest = m[2].slice(3);
        return rest.startsWith(SELFTEST_PREFIX) ? v : `${m[1]} · ${MASK_TEXT}`;
      }
      return v ? MASK_TEXT : v;
    }
    return this.maskText(v);
  }

  #walk(v, mode, key, parent, kindHint = null, path = '', foreign = null) {
    if (Array.isArray(v)) return v.map((x, i) => this.#walk(x, mode, key, v, kindHint, `${path}[${i}]`, foreign));
    if (v && typeof v === 'object') {
      const out = {};
      const t = v.type;
      const isPartner = PARTNER_TYPES.has(t);
      const isAgreement = t === AGREEMENT_TYPE;
      const isCandidate = 'phone' in v && 'name' in v && 'ref' in v;
      const isCustomerRequest = 'dedupe' in v && 'name' in v;
      const isError = typeof v.code === 'string' && /^POS_E_/.test(v.code) && 'message' in v;
      const isErrorLine = 'lineNumber' in v && typeof v.text === 'string';
      const sibling = kindOfSibling(v);
      // сначала запомнить имена, чтобы они скрывались и в свободном тексте этого же объекта
      const po = { person: personOf(v) };
      if (isPartner) { this.noteName(v.description, po); this.noteName(v.fullName, po); }
      if (isCandidate || isCustomerRequest) { this.noteName(v.name, po); this.noteName(v.fullName, po); }
      for (const [k, x] of Object.entries(v)) {
        const p = path ? `${path}.${k}` : k;
        if (foreign && foreign.has(p)) { out[k] = this.#foreign(x, k); continue; }
        let how = null;
        if ((isPartner) && (k === 'description' || k === 'fullName')) how = 'name';
        // Соглашения: наименование скрывается, но в список имён клиентов не попадает («Основное соглашение»,
        // «Розница» — не имя; иначе такие слова считались бы ПДн в текстах ошибок).
        else if (isAgreement && (k === 'description' || k === 'fullName')) how = 'nameNoNote';
        else if ((isCandidate || isCustomerRequest) && (k === 'name' || k === 'fullName')) how = 'name';
        else if ((isError && k === 'message') || (isErrorLine && k === 'text')) how = 'errtext';
        else if (k === 'courierComment' || k === 'reasonText') how = 'text';
        else if (k === 'comment' && isCustomerRequest) how = 'text';
        else if (k === 'comment') how = 'comment';
        else if (k === 'presentation') how = 'phone';
        else if (sibling && ['value', 'presentation', 'text', 'valueText', 'view'].includes(k)) how = sibling;
        else if (k === 'warnings' && Array.isArray(x)) {
          out[k] = x.map((w) => this.#maskStr(w, 'text'));
          continue;
        } else if (!SAFE_KEYS.has(k)) {
          how = kindOfKey(k);
          if (how === 'name') how = 'nameKey';
        }
        if (k === 'phones' && Array.isArray(x)) {
          out[k] = x.map((p) => (p && typeof p === 'object')
            ? Object.fromEntries(Object.entries(p).map(([pk, pv]) => [pk, typeof pv === 'string' ? maskPhone(pv) : pv]))
            : (typeof p === 'string' ? maskPhone(p) : p));
          continue;
        }
        if (how && typeof x === 'string') { out[k] = this.#maskStr(x, how); continue; }
        out[k] = this.#walk(x, mode, k, v, how, p, foreign);
      }
      return out;
    }
    if (typeof v === 'string') {
      const s = this.redactor ? this.redactor.redact(v) : v;
      if (kindHint) return this.#maskStr(s, kindHint);
      if (mode === 'unknown' && !SAFE_KEYS.has(key) && /\p{L}/u.test(s) && !s.startsWith(SELFTEST_PREFIX)
        && !GUID_ONLY.test(s) && !DATETIME_ONLY.test(s)) {
        return MASK_TEXT;
      }
      if (SAFE_KEYS.has(key) && key !== 'reference' && key !== 'bankReference') return s;
      return this.maskText(s);
    }
    return v;
  }
}

/** Маскирование телефона в строке запроса (?phone=…). */
export function maskQueryPhone(pathWithQuery) {
  return String(pathWithQuery).replace(/([?&]phone=)([^&]*)/g, (_, a, b) => {
    let raw = b;
    try { raw = decodeURIComponent(b); } catch { /* как есть */ }
    return a + `[${maskPhone(raw)}]`;
  });
}
