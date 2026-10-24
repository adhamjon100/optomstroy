import { Inject, Injectable, Logger, type OnApplicationBootstrap } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import type { Principal } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import {
  CatalogProductsService,
  type PackagingDto,
  type ProductSummaryDto,
  type VariantDto,
} from '../api/catalog-products.service.js';
import { isoOf, qtyOf } from '../common/catalog-format.js';
import { type CatalogSnapshot, CatalogSnapshotService } from '../common/catalog-snapshot.js';
import { type CatalogViewer, CatalogViewerService } from '../common/catalog-viewer.js';
import { cursorFingerprint, SearchCursorCodec } from './search-cursor.js';
import { parseBarcodeRequest, qTooShort, type SearchProductsParams, type SuggestParams } from './search-params.js';
import {
  correctWords,
  findBarcode,
  runStageQuery,
  runSuggest,
  SEARCH_TX_BEGIN,
  sortKeys,
  type StagePage,
  type StageQueryInput,
} from './search.repository.js';
import {
  type ClassifiedQuery,
  classifyQuery,
  MIN_TRIGRAM_LENGTH,
  QueryTooShortError,
  SEARCH_STAGES,
  type SearchStage,
} from './search-text.js';
import type { KeyKind } from './sql-params.js';

/** Кэш контекста зрителя и среза (см. SearchService.viewerFor / snapshot). */
export const VIEWER_CACHE_MS = 3000;
export const VIEWER_CACHE_MAX = 1000;
export const SNAPSHOT_CACHE_MS = 2000;
/** Проверка актуальности словаря search_words — не чаще раза в минуту. */
export const WORDS_CHECK_MS = 60_000;

/** DI-токен кодека курсора поиска (подпись — `OtpHmacService`, см. SearchModule). */
export const SEARCH_CURSOR_CODEC = 'SearchCursorCodec';

export type SearchProductItem = ProductSummaryDto & { readonly matchType: SearchStage | null };

/** Ответ `GET /search/products` (OpenAPI: `Page<ProductSummary>` + `query`, `matchTypes`, `suggestedQuery`). */
export interface SearchProductsResponse {
  readonly items: SearchProductItem[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly totalEstimate: number | null; // money-double: allow — число строк (count), не деньги
  readonly isEstimate: boolean;
  readonly asOf: string | null;
  readonly query: string;
  readonly matchTypes: Record<SearchStage, number>;
  readonly suggestedQuery: string | null;
}

export interface SearchSuggestResponse {
  readonly items: { text: string; kind: 'product' | 'category' | 'sku'; id: string | null; count?: number }[];
}

/** Ответ `GET /search/barcode/{value}` (OpenAPI `SearchBarcodeResult`, 08 §4.5.2). */
export interface SearchBarcodeResponse {
  readonly product: SearchProductItem;
  readonly variant: VariantDto;
  readonly packaging: PackagingDto | null;
  readonly barcodeType: string;
  readonly suggestedQuantity: { value: string; unitId: string; packagingId: string | null; baseValue: string };
}

const KEY_FORMAT: Readonly<Record<KeyKind, RegExp>> = {
  int: /^-?\d{1,9}$/,
  numeric: /^-?\d{1,20}(\.\d{1,6})?$/,
  float4: /^-?(\d+(\.\d*)?|\.\d+)(e[-+]?\d+)?$/i,
  text: /^[\s\S]{0,1000}$/,
  uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
};

function badCursor(): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field: 'cursor', rule: 'cursor', message: 'Курсор недействителен — запросите список заново.' }],
  });
}

/** Ступени D-31 по порядку для запроса (07 §10.3): штрихкод → артикул → FTS → триграммы. */
export function stagePlan(q: ClassifiedQuery): SearchStage[] {
  const out: SearchStage[] = [];
  if (q.barcodeCandidate) out.push('barcode');
  if (q.skuCandidate) out.push('sku');
  if (q.words.length > 0) out.push('fts');
  if (q.words.join(' ').length >= MIN_TRIGRAM_LENGTH || q.skuNorm.length >= MIN_TRIGRAM_LENGTH) out.push('trgm');
  return out;
}

/**
 * Поиск товаров (RM-E-005, RM-E-014; D-31; 07 §10.3; 08 §4.5). Цены, остатки и поля карточки — через сервис
 * Catalog API (`CatalogViewerService`, `CatalogProductsService.summaries`): правила ролей те же, что у
 * `/catalog/products`, фильтры — общие (`productFilterSql`).
 */
@Injectable()
export class SearchService implements OnApplicationBootstrap {
  private readonly log = new Logger('search');
  private readonly viewerCache = new Map<string, { value: CatalogViewer; until: number }>();
  private snapshotCache: { value: Promise<CatalogSnapshot>; until: number } | undefined;
  private wordsCheckedAt = 0;
  private wordsMarker: string | undefined;
  private wordsRefreshing: Promise<void> | undefined;

  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly viewers: CatalogViewerService,
    private readonly products: CatalogProductsService,
    private readonly snapshots: CatalogSnapshotService,
    @Inject(SEARCH_CURSOR_CODEC) private readonly cursors: SearchCursorCodec,
  ) {}

  /**
   * Самопроверка БД: при LC_CTYPE=C PostgreSQL не считает кириллицу буквами — pg_trgm и FTS по-русски не работают
   * (EQ-SRCH-01). Ошибка не останавливает API (поиск по штрихкоду и артикулу работает), но пишется в журнал.
   */
  async onApplicationBootstrap(): Promise<void> {
    try {
      const r = await this.pool.query<{ n: number; v: string }>(
        `SELECT cardinality(show_trgm('смеситель')) AS n, to_tsvector('public.ru_unaccent', 'Смесители')::text AS v`,
      );
      const row = r.rows[0];
      if (!row || row.n === 0 || !row.v.includes('смесител')) {
        this.log.error(
          { event: 'search.locale_unsupported' },
          'search: LC_CTYPE базы не классифицирует кириллицу — FTS и триграммы по-русски не работают (нужна UTF-8 локаль)',
        );
      }
    } catch (e) {
      this.log.warn(
        { event: 'search.selfcheck_failed', err: e instanceof Error ? e.message : String(e) },
        'search self-check failed',
      );
    }
    // Словарь исправления опечаток — до первого запроса (на 50 000 SKU — доли секунды).
    await this.refreshWordsIfStale(true);
  }

  classify(q: string): ClassifiedQuery {
    try {
      return classifyQuery(q);
    } catch (e) {
      if (e instanceof QueryTooShortError) throw qTooShort(e.min);
      throw e;
    }
  }

  async searchProducts(
    principal: Principal | undefined,
    params: SearchProductsParams,
  ): Promise<SearchProductsResponse> {
    const query = this.classify(params.q);
    const viewer = await this.viewerFor(principal, params.scope);
    const fingerprint = cursorFingerprint({ q: query.raw, f: params.filters, s: params.scope });
    const cursor = params.cursor ? this.cursors.decode(params.cursor, { sort: params.sort, fingerprint }) : undefined;
    let after: string[] | undefined;
    if (cursor) {
      const keys = sortKeys(cursor.stage, params.sort);
      if (cursor.keys.length !== keys.length) throw badCursor();
      after = cursor.keys.map((v, i) => {
        const s = String(v);
        if (!KEY_FORMAT[keys[i].kind].test(s)) throw badCursor();
        return s;
      });
    }
    const stages = cursor ? [cursor.stage] : stagePlan(query);
    void this.refreshWordsIfStale();
    // Срез «данные на …» читается параллельно с поиском (отдельное соединение пула).
    const [{ chosen, page, suggestedQuery, corrected }, snapshot] = await Promise.all([
      this.runStages(
        stages,
        {
          query,
          filters: params.filters,
          viewer,
          sort: params.sort,
          limit: params.limit,
          ...(after ? { after } : {}),
        },
        cursor ? { corrected: cursor.corrected ?? null } : undefined,
      ),
      this.snapshot(),
    ]);
    const summaries = await this.products.summaries(viewer, page.ids, { snapshot });
    const items: SearchProductItem[] = [];
    for (const id of page.ids) {
      const s = summaries.get(id);
      if (s) items.push({ ...s, matchType: chosen });
    }
    const matchTypes = Object.fromEntries(SEARCH_STAGES.map((s) => [s, 0])) as Record<SearchStage, number>;
    if (chosen) matchTypes[chosen] = page.total;
    const nextCursor =
      page.hasMore && chosen && page.lastKeys
        ? this.cursors.encode({
            stage: chosen,
            sort: params.sort,
            fingerprint,
            keys: page.lastKeys,
            ...(chosen === 'trgm' ? { corrected } : {}),
          })
        : null;
    return {
      items,
      nextCursor,
      hasMore: page.hasMore,
      totalEstimate: cursor && page.ids.length === 0 ? null : page.total,
      isEstimate: false,
      asOf: isoOf(snapshot.dataAsOf) ?? null,
      query: query.raw,
      matchTypes,
      suggestedQuery,
    };
  }

  /**
   * Ступени D-31 по порядку: первая ступень с совпадениями определяет `matchType`; при продолжении по курсору —
   * ступень и вариант `trgm` (исправленные слова или исходный запрос) из курсора, без повторного исправления
   * (ревью E-api-2: иначе на странице 2+ исправление давало другой вариант и строки терялись).
   */
  private async runStages(
    stages: readonly SearchStage[],
    input: Omit<StageQueryInput, 'stage'>,
    continuation: { readonly corrected: readonly string[] | null } | undefined,
  ): Promise<{
    chosen: SearchStage | null;
    page: StagePage;
    suggestedQuery: string | null;
    corrected: readonly string[] | null;
  }> {
    let page: StagePage = { ids: [], total: 0, hasMore: false, lastKeys: null };
    let client: pg.PoolClient | undefined;
    const fromCursor = continuation !== undefined;
    const found = () => page.total > 0 || page.ids.length > 0 || fromCursor;
    try {
      for (const stage of stages) {
        // Штрихкод и артикул — точечные запросы по B-tree, им транзакция не нужна. FTS и триграммы — в транзакции
        // READ ONLY с параметрами pg_trgm и без параллельных планов/JIT (SEARCH_TX_BEGIN, один round-trip).
        let db: Pick<pg.ClientBase, 'query'> = this.pool;
        if (stage === 'fts' || stage === 'trgm') {
          if (!client) {
            client = await this.pool.connect();
            await client.query(SEARCH_TX_BEGIN);
          }
          db = client;
        }
        if (stage === 'trgm') {
          // Сначала исправление слов по словарю названий (дёшево, даёт suggestedQuery), затем — сравнение запроса
          // с каждым названием и артикулом (дорого на частых словах; EQ-SRCH-10).
          const corrected = continuation ? continuation.corrected : await correctWords(db, input.query.words);
          if (corrected) {
            page = await runStageQuery(db, { ...input, stage, correctedWords: corrected });
            if (found()) {
              await client?.query('COMMIT');
              return { chosen: stage, page, suggestedQuery: corrected.join(' '), corrected };
            }
          }
        }
        page = await runStageQuery(db, { ...input, stage });
        if (found()) {
          await client?.query('COMMIT');
          return { chosen: stage, page, suggestedQuery: null, corrected: null };
        }
      }
      await client?.query('COMMIT');
      return { chosen: null, page, suggestedQuery: null, corrected: null };
    } catch (e) {
      if (client) await client.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      client?.release();
    }
  }

  /**
   * Словарь `search_words` (0005_search.sql) обновляется, если с прошлой проверки изменились `products` (max
   * updated_at и число строк): не чаще раза в WORDS_CHECK_MS, в фоне, `refresh_search_words()` — REFRESH CONCURRENTLY
   * под advisory-lock (несколько реплик API не обновляют одновременно). [ИНТЕГРАТОРУ] Точнее — вызывать
   * `SELECT refresh_search_words()` после фиксации прогона каталога в sync/apply.
   */
  refreshWordsIfStale(force = false): Promise<void> {
    const now = Date.now();
    if (this.wordsRefreshing) return this.wordsRefreshing;
    if (!force && now - this.wordsCheckedAt < WORDS_CHECK_MS) return Promise.resolve();
    this.wordsCheckedAt = now;
    this.wordsRefreshing = (async () => {
      const m = await this.pool.query<{ m: string }>(
        `SELECT coalesce(max(updated_at)::text, '') || '/' || count(*) AS m FROM products`,
      );
      const marker = m.rows[0]?.m;
      if (marker === this.wordsMarker) return;
      const r = await this.pool.query<{ ok: boolean }>('SELECT refresh_search_words() AS ok');
      if (r.rows[0]?.ok) this.wordsMarker = marker;
    })()
      .catch((e: unknown) => {
        this.log.warn(
          { event: 'search.words_refresh_failed', err: e instanceof Error ? e.message : String(e) },
          'search words refresh failed',
        );
      })
      .finally(() => {
        this.wordsRefreshing = undefined;
      });
    return this.wordsRefreshing;
  }

  /**
   * Контекст зрителя (вид цены, склад, режим остатков — CatalogViewerService) кэшируется на VIEWER_CACHE_MS по
   * субъекту и области запроса: поиск вызывается на каждый ввод (debounce 300 мс), а ответ клиент и так кэширует
   * на 30 с (`private, max-age=30`). Ошибки (403/400) не кэшируются.
   */
  private async viewerFor(
    principal: Principal | undefined,
    scope: SearchProductsParams['scope'],
  ): Promise<CatalogViewer> {
    if (!principal) return this.viewers.resolve(principal, scope);
    const key = JSON.stringify([principal.userId, principal.kind, principal.roles, principal.status, scope]);
    const hit = this.viewerCache.get(key);
    const now = Date.now();
    if (hit && hit.until > now) return hit.value;
    const value = await this.viewers.resolve(principal, scope);
    if (this.viewerCache.size >= VIEWER_CACHE_MAX) this.viewerCache.delete(this.viewerCache.keys().next().value!);
    this.viewerCache.set(key, { value, until: now + VIEWER_CACHE_MS });
    return value;
  }

  /** Момент среза каталога (`asOf`) — кэш SNAPSHOT_CACHE_MS: значение меняется только с синхронизацией. */
  private snapshot(): Promise<CatalogSnapshot> {
    const now = Date.now();
    if (this.snapshotCache && this.snapshotCache.until > now) return this.snapshotCache.value;
    const value = this.snapshots.read();
    this.snapshotCache = { value, until: now + SNAPSHOT_CACHE_MS };
    value.catch(() => {
      this.snapshotCache = undefined;
    });
    return value;
  }

  async suggest(principal: Principal | undefined, params: SuggestParams): Promise<SearchSuggestResponse> {
    this.viewers.assertAllowed(principal);
    const query = this.classify(params.q);
    if ([...query.raw].length < 2) throw qTooShort(2);
    const rows = await runSuggest(this.pool, query, params.limit);
    return {
      items: rows.map((r) => ({
        text: r.text,
        kind: r.kind,
        id: r.id,
        ...(r.count !== null ? { count: r.count } : {}),
      })),
    };
  }

  async barcode(
    principal: Principal | undefined,
    value: string,
    raw: Readonly<Record<string, unknown>>,
  ): Promise<SearchBarcodeResponse> {
    const req = parseBarcodeRequest(value, raw);
    const viewer = await this.viewerFor(principal, req.warehouseId ? { warehouseId: req.warehouseId } : {});
    const row = await findBarcode(this.pool, req.value);
    const notFound = () => new ProblemException('NOT_FOUND', { detail: 'Товар со штрихкодом не найден.' });
    if (!row) throw notFound();
    const snapshot = await this.snapshot();
    const [summaries, variants] = await Promise.all([
      this.products.summaries(viewer, [row.product_id], { snapshot }),
      this.products.variants(viewer, row.product_id, false, snapshot),
    ]);
    const summary = summaries.get(row.product_id);
    const variant = variants.items.find((v) => v.id === row.variant_id);
    if (!summary || !variant) throw notFound();
    const packaging: PackagingDto | null =
      row.packaging_id && row.pk_unit_id && row.pk_name !== null && row.pk_factor !== null
        ? {
            id: row.packaging_id,
            unitId: row.pk_unit_id,
            name: row.pk_name,
            factor: qtyOf(row.pk_factor),
            isDefault: row.pk_is_default === true,
            allowFraction: row.pk_allow_fraction === true,
            barcode: row.value,
          }
        : null;
    // Предлагаемое количество: 1 упаковка; без упаковки — кратность продажи или 1 базовая единица (08 §4.5.2).
    const value1 = packaging ? qtyOf('1') : qtyOf(row.multiplicity ?? '1');
    return {
      product: { ...summary, matchType: 'barcode' },
      variant,
      packaging,
      barcodeType: row.type,
      suggestedQuantity: {
        value: value1,
        unitId: packaging ? packaging.unitId : row.base_unit_id,
        packagingId: packaging ? packaging.id : null,
        baseValue: packaging ? packaging.factor : value1,
      },
    };
  }
}
