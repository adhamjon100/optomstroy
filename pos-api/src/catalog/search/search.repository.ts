import type pg from 'pg';
import { PRODUCT_AVAILABLE_SUM, productFilterSql } from '../api/catalog-products.service.js';
import type { ProductFilters } from '../api/product-filters.js';
import type { CatalogViewer } from '../common/catalog-viewer.js';
import type { SearchSort } from './search-params.js';
import { type ClassifiedQuery, escapeLike, type SearchStage, wordVariants } from './search-text.js';
import { keysetAfter, orderBy, type SortKey, SqlParams } from './sql-params.js';

/**
 * SQL ступеней алгоритма D-31 (07 §10.3) над репликой каталога. Каждая ступень — один запрос: кандидаты ступени →
 * фильтры каталога (общие с `/catalog/products`) → ключи сортировки → keyset-страница + общее число совпадений.
 * Все значения пользователя — параметры `$n`; в текст SQL попадают только имена столбцов и операторы, выбранные кодом.
 */

/** Порог `similarity` для артикула (07 §10.3: `pg_trgm.similarity_threshold = 0.3`). */
export const TRGM_SIMILARITY_THRESHOLD = 0.3;
/**
 * Порог `word_similarity` для названия (оператор `<%`). 07 §10.3 задаёт `name_norm % q` (similarity ≥ 0,3), но
 * similarity короткого запроса с длинным названием мала: «смиситель» × «смеситель для кухни frap f4252 хром» = 0,15 →
 * опечатка не находится. Сходство с лучшим фрагментом названия (`word_similarity`) для той же пары — 0,54
 * (EQ-SRCH-02); 0,5 — порог, при котором находятся одиночные опечатки в словах от 6 букв.
 */
export const TRGM_WORD_SIMILARITY_THRESHOLD = 0.5;
/** Таймаут одного поиска в БД (защита пула от патологического запроса; NFR p95 — 300 мс). */
export const SEARCH_STATEMENT_TIMEOUT_MS = 5000;

/** Продаваемые варианты товара — как в CatalogProductsService (EQ-ONEC-07): характеристики, иначе служебный. */
const SELLABLE = (v: string, p: string) => `NOT ${v}.deletion_mark AND ${v}.is_default = NOT ${p}.has_variants`;

export interface StageQueryInput {
  readonly stage: SearchStage;
  readonly query: ClassifiedQuery;
  readonly filters: ProductFilters;
  readonly viewer: CatalogViewer;
  readonly sort: SearchSort;
  readonly limit: number;
  /** Значения ключей последней строки предыдущей страницы (из курсора). */
  readonly after?: readonly string[];
  /**
   * Ступень «триграммы» после исправления слов по словарю `search_words` (correctWords): поиск исправленных слов по
   * `search_vector`, как ступень FTS, но с `matchType = trgm`.
   */
  readonly correctedWords?: readonly string[];
}

export interface BuiltQuery {
  readonly text: string;
  readonly values: unknown[];
  readonly keys: readonly SortKey[];
}

export interface StagePage {
  readonly ids: string[];
  readonly total: number; // money-double: allow — счётчик строк/событий (count), не деньги
  readonly hasMore: boolean;
  /** Значения ключей последней строки страницы (для курсора) — строками. */
  readonly lastKeys: string[] | null;
}

/** Ключи сортировки для ступени и `sort` (08 §2.5: `id` — последний ключ; NULL — в конце). */
export function sortKeys(stage: SearchStage, sort: SearchSort): SortKey[] {
  const id: SortKey = { col: 'id', dir: 'asc', kind: 'uuid' };
  switch (sort) {
    case 'relevance:desc':
      return stage === 'sku'
        ? [{ col: 'k_score', dir: 'desc', kind: 'int' }, { col: 'k_name', dir: 'asc', kind: 'text' }, id]
        : [{ col: 'k_score', dir: 'desc', kind: 'float4' }, id];
    case 'name:asc':
      return [{ col: 'k_name', dir: 'asc', kind: 'text' }, id];
    case 'sku:asc':
      return [{ col: 'k_null', dir: 'asc', kind: 'int' }, { col: 'k_sku', dir: 'asc', kind: 'text' }, id];
    case 'price:asc':
      return [{ col: 'k_null', dir: 'asc', kind: 'int' }, { col: 'k_price', dir: 'asc', kind: 'numeric' }, id];
    case 'price:desc':
      return [{ col: 'k_null', dir: 'asc', kind: 'int' }, { col: 'k_price', dir: 'desc', kind: 'numeric' }, id];
    case 'available:desc':
      return [{ col: 'k_null', dir: 'asc', kind: 'int' }, { col: 'k_avail', dir: 'desc', kind: 'numeric' }, id];
  }
}

/** tsquery ступени FTS: слова через `&&`, варианты слова (транслит, раскладка) через `||`, последнее — префикс. */
export function tsQueryExpr(words: readonly string[], p: SqlParams): string | null {
  if (words.length === 0) return null;
  const groups = words.map((w, i) => {
    const suffix = i === words.length - 1 ? ':*' : '';
    const variants = wordVariants(w).map((v) => `to_tsquery('public.ru_unaccent', ${p.add(v + suffix, 'text')})`);
    // Стоп-слово («для») даёт пустой tsquery — тогда вся группа пустая (иначе транслит «dlya» стал бы обязательным).
    return `(CASE WHEN numnode(${variants[0]}) = 0 THEN ''::tsquery ELSE (${variants.join(' || ')}) END)`;
  });
  return groups.join(' && ');
}

/** Кандидаты ступени: `cand(id, score)` (несколько строк на товар допустимы — берётся max). */
function candidates(stage: SearchStage, q: ClassifiedQuery, p: SqlParams): string {
  switch (stage) {
    case 'barcode':
      return `SELECT b.product_id AS id, 1::float8 AS score FROM barcodes b
               WHERE b.value = ${p.add(q.raw, 'text')} AND NOT b.deletion_mark`;
    case 'sku': {
      const exact = p.add(q.skuNorm, 'text');
      const prefix = p.add(`${escapeLike(q.skuNorm)}%`, 'text');
      return `SELECT id, 3::float8 AS score FROM products WHERE sku_norm = ${exact}
              UNION ALL SELECT id, 2 FROM products WHERE sku_norm LIKE ${prefix}
              UNION ALL SELECT v.product_id, 1 FROM product_variants v WHERE v.sku_norm LIKE ${prefix} AND NOT v.deletion_mark
              UNION ALL SELECT id, 3 FROM products WHERE onec_code = ${p.add(q.raw, 'text')}`;
    }
    case 'fts':
      throw new Error('fts: кандидаты строятся напрямую из products (ftsMatch)');
    case 'trgm': {
      const qn = `norm_search(${p.add(q.raw, 'text')})`;
      const parts = [
        `SELECT id, word_similarity(${qn}, name_norm)::float8 AS score FROM products WHERE ${qn} <% name_norm`,
        `SELECT v.product_id, word_similarity(${qn}, v.name_norm)::float8 FROM product_variants v
          WHERE ${qn} <% v.name_norm AND NOT v.deletion_mark AND NOT v.is_default`,
      ];
      if (q.skuNorm.length >= 3) {
        const sk = p.add(q.skuNorm, 'text');
        parts.push(
          `SELECT id, similarity(sku_norm, ${sk})::float8 FROM products WHERE sku_norm % ${sk}`,
          `SELECT v.product_id, similarity(v.sku_norm, ${sk})::float8 FROM product_variants v
            WHERE v.sku_norm % ${sk} AND NOT v.deletion_mark`,
        );
      }
      return parts.join('\n UNION ALL ');
    }
  }
}

/**
 * Ступень FTS: совпадения берутся прямо из `products` (GIN `search_vector`) без промежуточного набора и повторного
 * соединения по id — у частых слов («смеситель») это тысячи строк (EXPLAIN — docs/perf/E_search_benchmark.md).
 */
function ftsMatch(words: readonly string[], p: SqlParams): { score: string; match: string } {
  const tsq = tsQueryExpr(words, p) ?? `''::tsquery`;
  // ts_rank, а не ts_rank_cd из 07 §10.3: на запросе с вариантами слова (OR) и префиксом ts_rank_cd в 15–20 раз
  // дороже (678 совпадений «смеситель фрап»: 78 мс против 3,7 мс), а веса A/B/C/D учитывают обе функции (EQ-SRCH-02).
  return { score: `ts_rank(p.search_vector, ${tsq}, 32)::float8`, match: `p.search_vector @@ (${tsq})` };
}

/** Проекция ключей сортировки над `m` (+ LATERAL-агрегаты цены/остатка, если они нужны сортировке или фильтру). */
function projection(sort: SearchSort, stage: SearchStage): string {
  switch (sort) {
    case 'relevance:desc':
      return stage === 'sku' ? 'm.score::int AS k_score, m.name AS k_name' : 'm.score::float4 AS k_score';
    case 'name:asc':
      return 'm.name AS k_name';
    case 'sku:asc':
      return "(m.sku_norm IS NULL)::int AS k_null, coalesce(m.sku_norm, '') AS k_sku";
    case 'price:asc':
      return '(pa.pmin IS NULL)::int AS k_null, coalesce(pa.pmin, 0) AS k_price';
    case 'price:desc':
      return '(pa.pmax IS NULL)::int AS k_null, coalesce(pa.pmax, 0) AS k_price';
    case 'available:desc':
      return '(sa.avail IS NULL)::int AS k_null, coalesce(sa.avail, 0) AS k_avail';
  }
}

/**
 * Полный запрос страницы ступени. Фильтры `inStock`/`priceMin`/`priceMax` — по агрегатам продаваемых вариантов,
 * как в `CatalogProductsService.list`: остаток — Σ available на складе запроса > 0; цена — пересечение диапазона
 * `[pmin, pmax]` товара с `[priceMin, priceMax]`.
 */
export function buildStageQuery(input: StageQueryInput): BuiltQuery {
  const p = new SqlParams();
  const { viewer, filters, sort, stage } = input;
  const fts =
    stage === 'fts'
      ? ftsMatch(input.query.words, p)
      : stage === 'trgm' && input.correctedWords
        ? ftsMatch(input.correctedWords, p)
        : undefined;
  const cand = fts ? '' : candidates(stage, input.query, p);
  const where = [
    'NOT p.deletion_mark',
    'p.is_sellable',
    ...(fts ? [fts.match] : []),
    ...productFilterSql(p, filters, viewer),
  ];
  const needPrice =
    sort === 'price:asc' || sort === 'price:desc' || filters.priceMin !== undefined || filters.priceMax !== undefined;
  const needStock = sort === 'available:desc' || filters.inStock === true;
  const joins: string[] = [];
  const outer: string[] = [];
  if (needPrice) {
    const pl = p.add(viewer.canReadPrice ? (viewer.priceList?.id ?? null) : null, 'uuid');
    joins.push(`LEFT JOIN LATERAL (
        SELECT min(x.price) AS pmin, max(x.price) AS pmax FROM product_variants v
          JOIN prices x ON x.variant_id = v.id AND x.price_list_id = ${pl} AND x.packaging_id IS NULL
         WHERE v.product_id = m.id AND ${SELLABLE('v', 'm')}) pa ON true`);
    if (filters.priceMin !== undefined) outer.push(`pa.pmax >= ${p.add(filters.priceMin, 'numeric')}`);
    if (filters.priceMax !== undefined) outer.push(`pa.pmin <= ${p.add(filters.priceMax, 'numeric')}`);
  }
  if (needStock) {
    const wh = p.add(viewer.warehouse?.id ?? null, 'uuid');
    joins.push(`LEFT JOIN LATERAL (
        SELECT ${PRODUCT_AVAILABLE_SUM('b', 'm')} AS avail FROM product_variants v
          JOIN stock_balances b ON b.variant_id = v.id AND b.warehouse_id = ${wh}
         WHERE v.product_id = m.id AND ${SELLABLE('v', 'm')}) sa ON true`);
    if (filters.inStock === true) outer.push('sa.avail > 0');
  }
  const keys = sortKeys(stage, sort);
  const keyset = input.after ? `WHERE ${keysetAfter('k', keys, input.after, p)}` : '';
  const limit = p.add(input.limit + 1, 'int');
  const m = fts
    ? `SELECT p.id, p.name, p.sku_norm, p.has_variants, ${fts.score} AS score
         FROM products p WHERE ${where.join(' AND ')}`
    : `SELECT p.id, p.name, p.sku_norm, p.has_variants, c.score
         FROM (SELECT id, max(score) AS score FROM (${cand}) u GROUP BY id) c JOIN products p ON p.id = c.id
        WHERE ${where.join(' AND ')}`;
  const text = `
    WITH m AS (${m}),
    k AS (
      SELECT m.id, ${projection(sort, stage)}
        FROM m ${joins.join('\n')}
       ${outer.length ? `WHERE ${outer.join(' AND ')}` : ''}
    )
    SELECT ${keys.map((key, i) => `k.${key.col}::text AS c${i}`).join(', ')}, (SELECT count(*) FROM k)::int AS total
      FROM k ${keyset}
     ORDER BY ${orderBy('k', keys)}
     LIMIT ${limit}`;
  return { text, values: p.values, keys };
}

export async function runStageQuery(db: Pick<pg.ClientBase, 'query'>, input: StageQueryInput): Promise<StagePage> {
  const q = buildStageQuery(input);
  const res = await db.query<Record<string, string | number>>(q.text, q.values);
  const hasMore = res.rows.length > input.limit;
  const rows = hasMore ? res.rows.slice(0, input.limit) : res.rows;
  const idIdx = q.keys.length - 1;
  const last = rows.at(-1);
  // total — число строк k (после фильтров); на странице после последней — 0 строк, total берём из запроса без строк
  // нельзя, поэтому при пустой странице с курсором total неизвестен (null → 0 только без курсора).
  const total = res.rows[0] !== undefined ? Number(res.rows[0].total) : 0; // money-double: allow — счётчик строк/событий (count), не деньги
  return {
    ids: rows.map((r) => String(r[`c${idIdx}`])),
    total,
    hasMore,
    lastKeys: last ? q.keys.map((_, i) => String(last[`c${i}`])) : null,
  };
}

/** Порог сходства слова запроса со словом словаря при исправлении опечатки (pg_trgm similarity). */
export const WORD_FIX_THRESHOLD = 0.4;
/** Исправляются только слова от 4 символов (короткие — префиксы при наборе, их обрабатывает FTS `:*`). */
export const WORD_FIX_MIN_LENGTH = 4;

/**
 * Исправление слов запроса по словарю названий `search_words` (0005_search.sql): для каждого слова от 4 букв —
 * ближайшее слово словаря по триграммам (сам словарь, если слово в нём есть). `null` — исправлять нечего.
 * Требует транзакции SEARCH_TX_BEGIN (порог `%` = pg_trgm.similarity_threshold).
 */
export async function correctWords(
  db: Pick<pg.ClientBase, 'query'>,
  words: readonly string[],
): Promise<string[] | null> {
  if (!words.some((w) => w.length >= WORD_FIX_MIN_LENGTH && !/^\d+$/u.test(w))) return null;
  const res = await db.query<{ input: string; fix: string | null }>(
    `SELECT w.input, fix.word AS fix
       FROM unnest($1::text[]) WITH ORDINALITY AS w(input, ord)
       LEFT JOIN LATERAL (
         SELECT sw.word FROM search_words sw
          WHERE length(w.input) >= $2 AND w.input !~ '^[0-9]+$' AND sw.word % w.input
            AND similarity(sw.word, w.input) >= $3
          ORDER BY (sw.word = w.input) DESC, similarity(sw.word, w.input) DESC, sw.freq DESC, sw.word
          LIMIT 1) fix ON true
      ORDER BY w.ord`,
    [words, WORD_FIX_MIN_LENGTH, WORD_FIX_THRESHOLD],
  );
  const fixed = res.rows.map((r) => r.fix ?? r.input);
  return fixed.some((w, i) => w !== words[i]) ? fixed : null;
}

/**
 * Начало транзакции ступеней FTS/триграммы одним round-trip (простой протокол, только константы кода): READ ONLY,
 * пороги pg_trgm (07 §10.3, EQ-SRCH-02), таймаут, отказ от параллельных планов и JIT — запрос поиска короткий, а
 * запуск параллельных воркеров и JIT-компиляция стоят больше самого запроса (первый прогон бенчмарка: Gather Merge
 * 160 мс при 25 мс работы воркеров). `SET LOCAL` действует до COMMIT/ROLLBACK.
 */
export const SEARCH_TX_BEGIN = [
  'BEGIN READ ONLY',
  `SET LOCAL pg_trgm.similarity_threshold = ${TRGM_SIMILARITY_THRESHOLD}`,
  `SET LOCAL pg_trgm.word_similarity_threshold = ${TRGM_WORD_SIMILARITY_THRESHOLD}`,
  `SET LOCAL statement_timeout = ${SEARCH_STATEMENT_TIMEOUT_MS}`,
  'SET LOCAL max_parallel_workers_per_gather = 0',
  'SET LOCAL jit = off',
].join('; ');

// ---------------------------------------------------------------------------------------------- подсказки

export interface SuggestRow {
  kind: 'product' | 'category' | 'sku';
  text: string;
  id: string;
  count: number | null;
}

/**
 * `GET /search/suggest` (08 §4.5.3; 07 §10.3: только префикс по `name_norm` и `sku_norm`, limit 10): артикулы
 * (если запрос похож на артикул) → категории (≤ 3) → названия, начинающиеся с запроса → названия со словом,
 * начинающимся с запроса. Индексы — `products_name_norm_prefix_idx` (0005), `products_sku_norm_idx`,
 * `categories_name_norm_trgm`, `products_name_norm_trgm`.
 */
export function buildSuggestQuery(q: ClassifiedQuery, limit: number): BuiltQuery {
  const p = new SqlParams();
  const lim = p.add(limit, 'int');
  const qn = `norm_search(${p.add(q.raw, 'text')})`;
  const parts: string[] = [];
  if (q.skuCandidate) {
    const prefix = p.add(`${escapeLike(q.skuNorm)}%`, 'text');
    parts.push(`(SELECT 'sku'::text AS kind, p.sku AS text, p.id, NULL::int AS cnt, 0 AS ord, p.sku_norm AS k
                  FROM products p WHERE p.sku_norm LIKE ${prefix} AND NOT p.deletion_mark AND p.is_sellable
                 ORDER BY p.sku_norm LIMIT ${lim})`);
  }
  parts.push(
    `(SELECT 'category'::text AS kind, c.name AS text, c.id, c.product_count_cache AS cnt, 1 AS ord, c.name_norm AS k
        FROM categories c
       WHERE c.name_norm LIKE ${qn} || '%' AND NOT c.deletion_mark AND c.is_visible AND c.product_count_cache > 0
       ORDER BY c.product_count_cache DESC, c.name_norm LIMIT 3)`,
    `(SELECT 'product'::text AS kind, p.name AS text, p.id, NULL::int AS cnt, 2 AS ord, p.name_norm AS k FROM products p
       WHERE p.name_norm COLLATE "C" LIKE ${qn} || '%' AND NOT p.deletion_mark AND p.is_sellable
       ORDER BY p.name_norm COLLATE "C" LIMIT ${lim})`,
    `(SELECT 'product'::text AS kind, p.name AS text, p.id, NULL::int AS cnt, 3 AS ord, p.name_norm AS k FROM products p
       WHERE p.name_norm LIKE '% ' || ${qn} || '%' AND NOT p.deletion_mark AND p.is_sellable
       ORDER BY p.name_norm COLLATE "C" LIMIT ${lim})`,
  );
  const text = `SELECT kind, text, id::text AS id, cnt FROM (${parts.join(' UNION ALL ')}) s
                 ORDER BY ord, k COLLATE "C", id LIMIT ${lim}`;
  return { text, values: p.values, keys: [] };
}

export async function runSuggest(db: Pick<pg.Pool, 'query'>, q: ClassifiedQuery, limit: number): Promise<SuggestRow[]> {
  const built = buildSuggestQuery(q, limit * 2);
  const res = await db.query<{ kind: SuggestRow['kind']; text: string; id: string; cnt: number | null }>(
    built.text,
    built.values,
  );
  // Дедупликация: товар, найденный обеими ветками названия, и одинаковый текст подсказки — один раз.
  const seen = new Set<string>();
  const out: SuggestRow[] = [];
  for (const r of res.rows) {
    const key = `${r.kind === 'category' ? 'c' : 'p'}:${r.id}`;
    const textKey = `${r.kind}:${r.text.toLowerCase()}`;
    if (seen.has(key) || seen.has(textKey)) continue;
    seen.add(key);
    seen.add(textKey);
    out.push({ kind: r.kind, text: r.text, id: r.id, count: r.cnt });
    if (out.length >= limit) break;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------- штрихкод

export interface BarcodeRow {
  value: string;
  type: 'EAN13' | 'EAN8' | 'UPC' | 'CODE128' | 'CODE39' | 'QR' | 'other';
  product_id: string;
  variant_id: string;
  packaging_id: string | null;
  pk_unit_id: string | null;
  pk_name: string | null;
  pk_factor: string | null;
  pk_is_default: boolean | null;
  pk_allow_fraction: boolean | null;
  base_unit_id: string;
  multiplicity: string | null;
}

/**
 * Точное совпадение штрихкода (07 §5.22: `barcodes.value` UNIQUE — не больше одной строки; DATA-121). Товар снят
 * с продажи или помечен на удаление, вариант или упаковка помечены на удаление → совпадения нет.
 */
export async function findBarcode(db: Pick<pg.Pool, 'query'>, value: string): Promise<BarcodeRow | undefined> {
  const res = await db.query<BarcodeRow>(
    `SELECT b.value, b.type::text AS type, b.product_id::text, b.variant_id::text, b.packaging_id::text,
            k.unit_id::text AS pk_unit_id, k.name AS pk_name, k.factor::text AS pk_factor, k.is_default AS pk_is_default,
            k.allow_fraction AS pk_allow_fraction, p.base_unit_id::text, p.multiplicity::text
       FROM barcodes b
       JOIN products p ON p.id = b.product_id AND NOT p.deletion_mark AND p.is_sellable
       JOIN product_variants v ON v.id = b.variant_id AND NOT v.deletion_mark
       LEFT JOIN packagings k ON k.id = b.packaging_id
      WHERE b.value = $1::text AND NOT b.deletion_mark AND (b.packaging_id IS NULL OR NOT k.deletion_mark)`,
    [value],
  );
  return res.rows[0];
}
