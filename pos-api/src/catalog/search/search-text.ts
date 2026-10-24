/**
 * Разбор строки поиска для алгоритма D-31 (07 §10.3; 08 §4.5.1). Чистые функции без БД.
 *
 * Нормализация, по которой ищет БД, — SQL-функции `norm_search` / `norm_sku` (0001_init.sql, 07 §10.1); здесь только
 * классификация запроса (штрихкод / артикул / текст) и разбиение на слова для tsquery. Повтор `norm_sku` в TS нужен,
 * чтобы шаблон префикса LIKE был константой плана (индекс `text_pattern_ops`); тест сверяет его с SQL-функцией.
 */

/** Ступень алгоритма D-31 = значение `matchType` (OpenAPI `ProductSummary.matchType`). */
export type SearchStage = 'barcode' | 'sku' | 'fts' | 'trgm';
export const SEARCH_STAGES: readonly SearchStage[] = ['barcode', 'sku', 'fts', 'trgm'];

/** Минимальная длина запроса (D-31: 2 символа; для цифр/артикула — любая, т. е. 1). */
export const MIN_TEXT_QUERY_LENGTH = 2;
/** Предел длины `q` (OpenAPI `maxLength: 200`). */
export const MAX_QUERY_LENGTH = 200;
/** Не больше слов в tsquery: защита от «запроса-простыни» (каждое слово — до 4 вариантов). */
export const MAX_QUERY_WORDS = 8;
/** Триграммы — только с этой длины нормализованного запроса: короче — шум и полный перебор GIN. */
export const MIN_TRIGRAM_LENGTH = 3;

/** Штрихкод в строке поиска: только цифры, 4–14 знаков (07 §10.3, ветка B). */
const BARCODE_QUERY_RE = /^\d{4,14}$/;
/** «Похоже на артикул»: буквы, цифры, дефис, точка, слеш, 2–32 знака, без пробелов (07 §10.3, ветка SKQ). */
const SKU_QUERY_RE = /^[\p{L}\p{N}][\p{L}\p{N}\-./]{0,31}$/u;
const DIGITS_RE = /^\d+$/;

export interface ClassifiedQuery {
  /** `q` после trim (как в ответе `query`). */
  readonly raw: string;
  /** Только цифры (для них допустима длина 1 — OpenAPI `q`: «для цифровых строк ≥ 1»). */
  readonly digits: boolean;
  /** Ветка B: цифры 4–14 — сначала точный штрихкод. */
  readonly barcodeCandidate: boolean;
  /** Ветка SKQ: проба префикса артикула (и `onec_code`). */
  readonly skuCandidate: boolean;
  /** `norm_sku(q)` (верхний регистр без пробелов и `-_./`). */
  readonly skuNorm: string;
  /** Слова для FTS (буквы/цифры, нижний регистр, ё→е), не больше MAX_QUERY_WORDS. */
  readonly words: readonly string[];
}

export class QueryTooShortError extends Error {
  constructor(readonly min: number) {
    super(`q короче ${min} символов`);
  }
}

/** Управляющие символы (C0, DEL) → пробел: PostgreSQL не принимает `\u0000` в text (иначе 500). */
export function stripControls(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\u0000-\u001f\u007f]/gu, ' ');
}

/** TS-повтор SQL `norm_sku` (07 §10.1): `upper(regexp_replace(s, '[[:space:]\-_./]+', '', 'g'))`. */
export function normSku(s: string): string {
  return s.replace(/[\s\-_./]+/gu, '').toUpperCase();
}

/** Слова запроса: lower, ё→е, только буквы и цифры (знаки операторов tsquery до SQL не доходят). */
export function queryWords(s: string): string[] {
  const lowered = s.toLowerCase().replace(/ё/gu, 'е');
  const out: string[] = [];
  for (const m of lowered.matchAll(/[\p{L}\p{N}]+/gu)) {
    if (!out.includes(m[0])) out.push(m[0]);
    if (out.length >= MAX_QUERY_WORDS) break;
  }
  return out;
}

/**
 * Классификация `q` по 07 §10.3. Пустой или короткий нетекстовый запрос → `QueryTooShortError` (контроллер отвечает
 * `422 VALIDATION_FAILED rule q_too_short`, OpenAPI `q`). Минимум 2 символа, цифровая строка — от 1.
 */
export function classifyQuery(q: string): ClassifiedQuery {
  const raw = stripControls(q).trim().replace(/\s+/gu, ' ');
  const digits = DIGITS_RE.test(raw);
  const words = queryWords(raw);
  if (raw.length === 0 || (!digits && [...raw].length < MIN_TEXT_QUERY_LENGTH)) {
    throw new QueryTooShortError(digits ? 1 : MIN_TEXT_QUERY_LENGTH);
  }
  const skuNorm = normSku(raw);
  return {
    raw,
    digits,
    barcodeCandidate: BARCODE_QUERY_RE.test(raw),
    skuCandidate: skuNorm.length > 0 && SKU_QUERY_RE.test(raw),
    skuNorm,
    words,
  };
}

// --------------------------------------------------------------------------------------------------------------
// Варианты слова для FTS: транслитерация и раскладка клавиатуры («смеситель фрап» → Frap; «cvtcbntkm» → смеситель).
// D-31 их не требует явно; это расширение ступени FTS (EQ-SRCH-03), без него «смеситель фрап» не находит
// латинский бренд Frap ни одной ступенью: FTS — другая письменность, триграммы — сходство ниже порога.
// --------------------------------------------------------------------------------------------------------------

const CYR_TO_LAT: Readonly<Record<string, string>> = {
  а: 'a',
  б: 'b',
  в: 'v',
  г: 'g',
  д: 'd',
  е: 'e',
  ж: 'zh',
  з: 'z',
  и: 'i',
  й: 'y',
  к: 'k',
  л: 'l',
  м: 'm',
  н: 'n',
  о: 'o',
  п: 'p',
  р: 'r',
  с: 's',
  т: 't',
  у: 'u',
  ф: 'f',
  х: 'h',
  ц: 'ts',
  ч: 'ch',
  ш: 'sh',
  щ: 'sch',
  ъ: '',
  ы: 'y',
  ь: '',
  э: 'e',
  ю: 'yu',
  я: 'ya',
  ң: 'n',
  ө: 'o',
  ү: 'u',
};

const LAT_DIGRAPHS: readonly (readonly [string, string])[] = [
  ['sch', 'щ'],
  ['sh', 'ш'],
  ['ch', 'ч'],
  ['zh', 'ж'],
  ['ts', 'ц'],
  ['kh', 'х'],
  ['ya', 'я'],
  ['yu', 'ю'],
  ['yo', 'е'],
];
const LAT_TO_CYR: Readonly<Record<string, string>> = {
  a: 'а',
  b: 'б',
  c: 'к',
  d: 'д',
  e: 'е',
  f: 'ф',
  g: 'г',
  h: 'х',
  i: 'и',
  j: 'дж',
  k: 'к',
  l: 'л',
  m: 'м',
  n: 'н',
  o: 'о',
  p: 'п',
  q: 'к',
  r: 'р',
  s: 'с',
  t: 'т',
  u: 'у',
  v: 'в',
  w: 'в',
  x: 'кс',
  y: 'й',
  z: 'з',
};

/** Раскладка ЙЦУКЕН ↔ QWERTY (только буквенные клавиши; знаки `[];',.` в словах не встречаются после разбора). */
const LAYOUT_EN = 'qwertyuiopasdfghjklzxcvbnm';
const LAYOUT_RU = 'йцукенгшщзфывапролдячсмить';
const EN_TO_RU = new Map([...LAYOUT_EN].map((c, i) => [c, LAYOUT_RU[i]]));
const RU_TO_EN = new Map([...LAYOUT_RU].map((c, i) => [c, LAYOUT_EN[i]]));
/** Буквы русской раскладки на клавишах знаков препинания QWERTY: х [, ъ ], ж ;, э ', б ,, ю . */
const RU_PUNCT_KEYS: Readonly<Record<string, string>> = { х: '[', ъ: ']', ж: ';', э: "'", б: ',', ю: '.' };

const CYR_RE = /^[а-яёңөү\d]+$/u;
const LAT_RE = /^[a-z\d]+$/u;

export function translitCyrToLat(w: string): string {
  return [...w].map((c) => CYR_TO_LAT[c] ?? c).join('');
}

export function translitLatToCyr(w: string): string {
  let out = '';
  let i = 0;
  outer: while (i < w.length) {
    for (const [lat, cyr] of LAT_DIGRAPHS) {
      if (w.startsWith(lat, i)) {
        out += cyr;
        i += lat.length;
        continue outer;
      }
    }
    out += LAT_TO_CYR[w[i]] ?? w[i];
    i += 1;
  }
  return out;
}

/** Слово, набранное не в той раскладке; `null` — если перевод невозможен (знак без буквы-пары). */
export function switchLayout(w: string): string | null {
  if (LAT_RE.test(w) && /[a-z]/u.test(w)) return [...w].map((c) => EN_TO_RU.get(c) ?? c).join('');
  if (CYR_RE.test(w) && /[а-я]/u.test(w)) {
    let out = '';
    for (const c of w) {
      if (RU_PUNCT_KEYS[c] !== undefined) return null;
      out += RU_TO_EN.get(c) ?? c;
    }
    return out;
  }
  return null;
}

/**
 * Варианты слова для ступени FTS: само слово (всегда первым), транслитерация в другую письменность, раскладка.
 * Цифры и смешанные слова (`f4252`) — без вариантов. Не больше 4 вариантов.
 */
export function wordVariants(w: string): string[] {
  const out = [w];
  const add = (v: string | null) => {
    if (v && v.length > 0 && !out.includes(v) && /^[\p{L}\p{N}]+$/u.test(v)) out.push(v);
  };
  if (/^\d+$/u.test(w)) return out;
  if (CYR_RE.test(w)) {
    add(translitCyrToLat(w));
    add(switchLayout(w));
  } else if (LAT_RE.test(w)) {
    if (/\d/u.test(w)) return out;
    add(translitLatToCyr(w));
    add(switchLayout(w));
  }
  return out.slice(0, 4);
}

/** Экранирование спецсимволов LIKE (`\`, `%`, `_`) — для префикса артикула. */
export function escapeLike(s: string): string {
  return s.replace(/[\\%_]/gu, (c) => `\\${c}`);
}
