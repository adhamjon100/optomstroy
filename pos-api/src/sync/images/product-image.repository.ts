import type pg from 'pg';
import { writeSyncError } from '../../jobs/sync-errors.writer.js';
import type { ImageSizesMeta } from './image-sizes.js';
import { type ImageFileEntry, type ImageItemError, normRef, type RegisterResult } from './image.types.js';

type Db = Pick<pg.ClientBase, 'query'> | Pick<pg.Pool, 'query'>;

const BATCH = 1000;
/** Файл — `imageFileRef` (`ФайлКартинки`) своего товара (`products.onec_image_file_ref`, миграция 0019). */
const MAIN_BY_REF_SQL = `(p.onec_image_file_ref IS NOT NULL AND pi.source_ref = p.onec_image_file_ref::text)`;
/** Нулевая ссылка 1С — «владельца нет». */
const EMPTY_REF = '00000000-0000-0000-0000-000000000000';
/** source_ref, который можно запросить у HS `GET /pos/v1/images/{ref}` (только UUID присоединённого файла). */
export const HS_SOURCE_REF_SQL = `source_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'`;

/** Строка очереди скачивания. */
export interface ClaimedImage {
  readonly id: string;
  readonly sourceRef: string;
  readonly sourceVersion: string | null;
  /** Хэш уже обработанного содержимого (hex) — для `If-None-Match`. */
  readonly checksum: string | null;
  readonly storageKey: string | null;
  readonly attempts: number;
  readonly productId: string | null;
}

export interface ReadyImageMeta {
  readonly sha256: string;
  readonly storageKey: string;
  readonly originalMime: string;
  readonly originalBytes: number;
  readonly width: number;
  readonly height: number;
  readonly sizes: ImageSizesMeta;
}

/**
 * Доступ к `product_images` (07 §5.23, DATA-122) для пайплайна фото. Привязка — **только** по `onec_ref`
 * владельца (`products.onec_ref` / `product_variants.onec_ref`), никогда по имени/артикулу/позиции (D-30, SRC-D-107).
 */
export class ProductImageRepository {
  /**
   * Регистрация списка файлов источника: новые → `pending`; смена версии → `pending` (повторное скачивание);
   * смена владельца → перепривязка к товару с этим `onec_ref`; пометка удаления → `deleted_at`.
   * Владелец не найден → строки нет (у прежней строки — `deleted_at`, чтобы фото не осталось на другом товаре)
   * и ошибка `NOT_FOUND_LOCAL`.
   */
  async register(db: Db, entries: readonly ImageFileEntry[]): Promise<RegisterResult> {
    const res: RegisterResult = {
      received: entries.length,
      inserted: 0,
      updated: 0,
      unchanged: 0,
      markedDeleted: 0,
      ownerNotFound: 0,
      invalid: 0,
      affectedProducts: new Set<string>(),
      errors: [],
    };
    // Последняя запись по source_ref побеждает (в одном сообщении объект встречается один раз, но список OData/CML — нет).
    const bySource = new Map<string, ImageFileEntry>();
    for (const e of entries) {
      const key = typeof e.sourceRef === 'string' ? e.sourceRef.trim() : '';
      if (!key || key.length > 600) {
        res.invalid += 1;
        res.errors.push({
          errorCode: 'VALIDATION',
          severity: 'warning',
          message: 'файл фото без ключа источника пропущен',
        });
        continue;
      }
      bySource.set(key, { ...e, sourceRef: key });
    }
    const all = [...bySource.values()];
    for (let i = 0; i < all.length; i += BATCH) await this.registerBatch(db, all.slice(i, i + BATCH), res);
    return res;
  }

  private async registerBatch(db: Db, batch: readonly ImageFileEntry[], res: RegisterResult): Promise<void> {
    const deletions: string[] = [];
    const live: ImageFileEntry[] = [];
    for (const e of batch) {
      if (e.deletionMark) deletions.push(e.sourceRef);
      else live.push(e);
    }

    // Прежние владельцы затронутых строк (смена/снятие привязки меняет главное фото прежнего товара).
    const refs = batch.map((e) => e.sourceRef);
    const prev = await db.query<{ source_ref: string; product_id: string | null }>(
      `SELECT source_ref, product_id FROM product_images WHERE source_ref = ANY($1::text[]) AND deleted_at IS NULL`,
      [refs],
    );
    for (const r of prev.rows) if (r.product_id) res.affectedProducts.add(r.product_id);

    // Владельцы по onec_ref: товар (приоритет) или характеристика (тогда product_id = товар характеристики).
    const ownerRefs = [
      ...new Set(live.map((e) => normRef(e.ownerRef)).filter((r): r is string => !!r && r !== EMPTY_REF)),
    ];
    const owners = new Map<string, { productId: string; variantId: string | null }>();
    if (ownerRefs.length > 0) {
      const o = await db.query<{ ref: string; product_id: string; variant_id: string | null; prio: number }>(
        `SELECT p.onec_ref::text AS ref, p.id::text AS product_id, NULL::text AS variant_id, 0 AS prio
           FROM products p WHERE p.onec_ref = ANY($1::uuid[])
         UNION ALL
         SELECT v.onec_ref::text, v.product_id::text, v.id::text, 1
           FROM product_variants v WHERE v.onec_ref = ANY($1::uuid[]) AND NOT v.is_default
         ORDER BY prio`,
        [ownerRefs],
      );
      for (const r of o.rows)
        if (!owners.has(r.ref)) owners.set(r.ref, { productId: r.product_id, variantId: r.variant_id });
    }

    const rows: Record<string, unknown>[] = [];
    for (const e of live) {
      const ref = normRef(e.ownerRef);
      const owner = ref && ref !== EMPTY_REF ? owners.get(ref) : undefined;
      if (!owner) {
        res.ownerNotFound += 1;
        deletions.push(e.sourceRef);
        res.errors.push({
          errorCode: 'NOT_FOUND_LOCAL',
          severity: 'warning',
          message: ref
            ? 'владелец файла фото не найден среди товаров и характеристик — фото не привязано'
            : 'у файла фото нет владельца (ВладелецФайла) — фото не привязано',
          onecRef: ref && ref !== EMPTY_REF ? ref : null,
          payload: { sourceRef: e.sourceRef.slice(0, 200) },
        });
        continue;
      }
      res.affectedProducts.add(owner.productId);
      rows.push({
        source_ref: e.sourceRef,
        product_id: owner.productId,
        variant_id: owner.variantId,
        source_version: e.sourceVersion ?? null,
        sort_order: Number.isInteger(e.sortOrder) ? e.sortOrder : 0,
        onec_is_main: typeof e.isMain === 'boolean' ? e.isMain : null,
      });
    }

    if (deletions.length > 0) {
      const d = await db.query<{ product_id: string | null }>(
        `UPDATE product_images SET deleted_at = now(), is_primary = false
          WHERE source_ref = ANY($1::text[]) AND deleted_at IS NULL
          RETURNING product_id::text`,
        [deletions],
      );
      res.markedDeleted += d.rowCount ?? 0;
      for (const r of d.rows) if (r.product_id) res.affectedProducts.add(r.product_id);
    }
    if (rows.length === 0) return;

    // Upsert по source_ref. Версия сменилась → pending (повторное скачивание с If-None-Match по прежнему хэшу).
    const up = await db.query<{ inserted: boolean }>(
      `INSERT INTO product_images (product_id, variant_id, source_ref, source_version, sort_order, onec_is_main, status)
       SELECT x.product_id, x.variant_id, x.source_ref, x.source_version, x.sort_order, x.onec_is_main, 'pending'
         FROM jsonb_to_recordset($1::jsonb) AS x(source_ref text, product_id uuid, variant_id uuid,
              source_version text, sort_order integer, onec_is_main boolean)
       ON CONFLICT (source_ref) WHERE deleted_at IS NULL DO UPDATE SET
         product_id = EXCLUDED.product_id,
         variant_id = EXCLUDED.variant_id,
         sort_order = EXCLUDED.sort_order,
         -- Признак главного файла 1С (isMain): источник без признака (OData-список) его не сбрасывает.
         onec_is_main = COALESCE(EXCLUDED.onec_is_main, product_images.onec_is_main),
         is_primary = CASE WHEN product_images.product_id IS DISTINCT FROM EXCLUDED.product_id
                             OR product_images.variant_id IS DISTINCT FROM EXCLUDED.variant_id
                           THEN false ELSE product_images.is_primary END,
         source_version = EXCLUDED.source_version,
         status = CASE WHEN product_images.source_version IS DISTINCT FROM EXCLUDED.source_version
                       THEN 'pending'::image_status ELSE product_images.status END,
         attempts = CASE WHEN product_images.source_version IS DISTINCT FROM EXCLUDED.source_version
                         THEN 0 ELSE product_images.attempts END,
         next_attempt_at = CASE WHEN product_images.source_version IS DISTINCT FROM EXCLUDED.source_version
                                THEN NULL ELSE product_images.next_attempt_at END,
         error = CASE WHEN product_images.source_version IS DISTINCT FROM EXCLUDED.source_version
                      THEN NULL ELSE product_images.error END
       WHERE product_images.product_id IS DISTINCT FROM EXCLUDED.product_id
          OR product_images.variant_id IS DISTINCT FROM EXCLUDED.variant_id
          OR product_images.sort_order IS DISTINCT FROM EXCLUDED.sort_order
          OR product_images.source_version IS DISTINCT FROM EXCLUDED.source_version
          OR (EXCLUDED.onec_is_main IS NOT NULL AND product_images.onec_is_main IS DISTINCT FROM EXCLUDED.onec_is_main)
       RETURNING (xmax = 0) AS inserted`,
      [JSON.stringify(rows)],
    );
    for (const r of up.rows) {
      if (r.inserted) res.inserted += 1;
      else res.updated += 1;
    }
    res.unchanged += rows.length - up.rows.length;
  }

  /** Прерванный прогон оставил `downloading` — вернуть в очередь (прогон фото — singleton, SYNC-023). */
  async resetStuck(db: Db): Promise<number> {
    const r = await db.query(
      `UPDATE product_images SET status = 'pending' WHERE status = 'downloading' AND deleted_at IS NULL`,
    );
    return r.rowCount ?? 0;
  }

  /** Захват пачки очереди скачивания (`pending`, `failed` с наступившим `next_attempt_at`) → `downloading`. */
  async claim(db: Db, limit: number, now: Date, exclude: readonly string[] = []): Promise<ClaimedImage[]> {
    const r = await db.query<{
      id: string;
      source_ref: string;
      source_version: string | null;
      checksum: string | null;
      storage_key: string | null;
      attempts: number | null;
      product_id: string | null;
    }>(
      `UPDATE product_images pi SET status = 'downloading'
         FROM (SELECT id FROM product_images
                WHERE deleted_at IS NULL AND ${HS_SOURCE_REF_SQL}
                  AND (status = 'pending' OR (status = 'failed' AND next_attempt_at <= $2))
                  AND NOT (id = ANY($3::uuid[]))
                ORDER BY next_attempt_at NULLS FIRST, id
                LIMIT $1 FOR UPDATE SKIP LOCKED) q
        WHERE pi.id = q.id
        RETURNING pi.id::text, pi.source_ref, pi.source_version, encode(pi.checksum_sha256, 'hex') AS checksum,
                  pi.storage_key, pi.attempts, pi.product_id::text`,
      [limit, now, exclude],
    );
    return r.rows.map((x) => ({
      id: x.id,
      sourceRef: x.source_ref,
      sourceVersion: x.source_version,
      checksum: x.checksum,
      storageKey: x.storage_key,
      attempts: x.attempts ?? 0,
      productId: x.product_id,
    }));
  }

  /** Готовые метаданные по sha256 (дедупликация: тот же файл уже обработан для другой строки/товара). */
  async readyMetaBySha(db: Db, sha: string): Promise<ReadyImageMeta | null> {
    const r = await db.query<{
      storage_key: string;
      original_mime: string | null;
      original_bytes: number | null;
      width: number | null;
      height: number | null;
      sizes: ImageSizesMeta | null;
    }>(
      `SELECT storage_key, original_mime, original_bytes, width, height, sizes FROM product_images
        WHERE checksum_sha256 = decode($1, 'hex') AND status = 'ready' AND storage_key IS NOT NULL AND sizes IS NOT NULL
        ORDER BY updated_at DESC LIMIT 1`,
      [sha],
    );
    const x = r.rows[0];
    if (!x?.sizes || x.width === null || x.height === null) return null;
    return {
      sha256: sha,
      storageKey: x.storage_key,
      originalMime: x.original_mime ?? 'application/octet-stream',
      originalBytes: x.original_bytes ?? 0,
      width: x.width,
      height: x.height,
      sizes: x.sizes,
    };
  }

  async markReady(db: Db, id: string, m: ReadyImageMeta): Promise<void> {
    await db.query(
      `UPDATE product_images SET status = 'ready', checksum_sha256 = decode($2, 'hex'), storage_key = $3,
              original_mime = $4, original_bytes = $5, width = $6, height = $7, sizes = $8::jsonb,
              error = NULL, attempts = 0, next_attempt_at = NULL
        WHERE id = $1`,
      [id, m.sha256, m.storageKey, m.originalMime, m.originalBytes, m.width, m.height, JSON.stringify(m.sizes)],
    );
  }

  /** 304: содержимое не менялось — строка снова `ready` без обработки. */
  async markNotModified(db: Db, id: string): Promise<void> {
    await db.query(
      `UPDATE product_images SET status = 'ready', error = NULL, attempts = 0, next_attempt_at = NULL WHERE id = $1`,
      [id],
    );
  }

  /**
   * Ошибка: `failed` (файлы и `storage_key` сбрасываются — клиент показывает заглушку, а не старое/чужое фото).
   * `retryAt = null` — без автоматического повтора до смены версии в источнике (битый файл, исчерпаны попытки).
   */
  async markFailed(
    db: Db,
    id: string,
    f: { error: string; attempts: number; retryAt: Date | null; checksum?: string | null },
  ): Promise<void> {
    await db.query(
      `UPDATE product_images SET status = 'failed', error = $2, attempts = $3, next_attempt_at = $4,
              checksum_sha256 = CASE WHEN $5::text IS NULL THEN checksum_sha256 ELSE decode($5, 'hex') END,
              storage_key = NULL, sizes = NULL, is_primary = false
        WHERE id = $1`,
      [id, f.error.slice(0, 500), Math.min(f.attempts, 32_000), f.retryAt, f.checksum ?? null],
    );
  }

  /** 404 в источнике → `missing_source` (заглушка, D-30; SYNC-072). */
  async markMissing(db: Db, id: string): Promise<void> {
    await db.query(
      `UPDATE product_images SET status = 'missing_source', error = 'POS_E_NOT_FOUND', next_attempt_at = NULL,
              storage_key = NULL, sizes = NULL, is_primary = false
        WHERE id = $1`,
      [id],
    );
  }

  /**
   * Главное фото: у товара — готовый файл `imageFileRef` товара (`products.onec_image_file_ref`), если он
   * присоединён к этому же товару или его характеристике (контракт `NomenclatureChange.imageFileRef`; ТЗ для 1С 5.4),
   * иначе — готовое фото самого товара (сначала с признаком 1С `isMain`, затем с наименьшим `sort_order`), иначе —
   * первое готовое фото его характеристик (того же товара); у характеристики — её собственное. `is_primary` и
   * `products/product_variants.primary_image_id` меняются только при фактическом изменении (updated_at → инкремент
   * офлайн-кэша, 08 §4.24). Нет готовых фото → `NULL` (заглушка).
   */
  async refreshPrimary(db: Db, productIds: Iterable<string>): Promise<number> {
    const ids = [...new Set(productIds)];
    let changed = 0;
    for (let i = 0; i < ids.length; i += BATCH) {
      const chunk = ids.slice(i, i + BATCH);
      // Порядок выбора (разбор расхождений п. 14; ТЗ для 1С 5.4): файл `imageFileRef` товара (`ФайлКартинки`), если
      // он присоединён к этому же товару, → признак `isMain` 1С → `sort_order` → время регистрации.
      const target = `SELECT DISTINCT ON (pi.product_id, pi.variant_id) pi.id, pi.product_id, pi.variant_id
                        FROM product_images pi JOIN products p ON p.id = pi.product_id
                       WHERE pi.product_id = ANY($1::uuid[]) AND pi.deleted_at IS NULL AND pi.status = 'ready'
                       ORDER BY pi.product_id, pi.variant_id, ${MAIN_BY_REF_SQL} DESC,
                                COALESCE(pi.onec_is_main, false) DESC, pi.sort_order, pi.created_at, pi.id`;
      const cleared = await db.query(
        `UPDATE product_images SET is_primary = false
          WHERE product_id = ANY($1::uuid[]) AND is_primary
            AND id NOT IN (SELECT id FROM (${target}) t)`,
        [chunk],
      );
      const set = await db.query(
        `UPDATE product_images SET is_primary = true
          WHERE id IN (SELECT id FROM (${target}) t) AND NOT is_primary`,
        [chunk],
      );
      const prod = await db.query(
        `WITH best AS (
           SELECT DISTINCT ON (pi.product_id) pi.product_id, pi.id
             FROM product_images pi JOIN products p ON p.id = pi.product_id
            WHERE pi.product_id = ANY($1::uuid[]) AND pi.deleted_at IS NULL AND pi.status = 'ready'
            ORDER BY pi.product_id, ${MAIN_BY_REF_SQL} DESC, (pi.variant_id IS NOT NULL),
                     COALESCE(pi.onec_is_main, false) DESC, pi.sort_order, pi.created_at, pi.id)
         UPDATE products p SET primary_image_id = b.id
           FROM (SELECT x.id AS product_id, best.id FROM unnest($1::uuid[]) AS x(id)
                   LEFT JOIN best ON best.product_id = x.id) b
          WHERE p.id = b.product_id AND p.primary_image_id IS DISTINCT FROM b.id`,
        [chunk],
      );
      const vars = await db.query(
        `WITH best AS (
           SELECT DISTINCT ON (variant_id) variant_id, id FROM product_images
            WHERE product_id = ANY($1::uuid[]) AND variant_id IS NOT NULL AND deleted_at IS NULL AND status = 'ready'
            ORDER BY variant_id, COALESCE(onec_is_main, false) DESC, sort_order, created_at, id)
         UPDATE product_variants v SET primary_image_id = best.id
           FROM product_variants v2 LEFT JOIN best ON best.variant_id = v2.id
          WHERE v.id = v2.id AND v2.product_id = ANY($1::uuid[]) AND NOT v2.is_default
            AND v.primary_image_id IS DISTINCT FROM best.id`,
        [chunk],
      );
      changed += (cleared.rowCount ?? 0) + (set.rowCount ?? 0) + (prod.rowCount ?? 0) + (vars.rowCount ?? 0);
    }
    return changed;
  }

  /**
   * Полная сверка списка (ночной прогон по OData, SYNC-035): живые строки HS-источника (`source_ref` = uuid),
   * которых нет в полном списке, получают `deleted_at`. Строки разовой выгрузки (`import:…`) не трогаются.
   */
  async markAbsent(db: Db, seen: readonly string[]): Promise<{ count: number; products: string[] }> {
    const r = await db.query<{ product_id: string | null }>(
      `UPDATE product_images SET deleted_at = now(), is_primary = false
        WHERE deleted_at IS NULL AND ${HS_SOURCE_REF_SQL} AND NOT (source_ref = ANY($1::text[]))
        RETURNING product_id::text`,
      [seen],
    );
    return { count: r.rowCount ?? 0, products: r.rows.map((x) => x.product_id).filter((x): x is string => !!x) };
  }

  /** Существующая живая строка по ключу источника (разовый импорт: пропуск неизменённых файлов). */
  async bySourceRef(
    db: Db,
    sourceRef: string,
  ): Promise<{ id: string; sourceVersion: string | null; status: string; productId: string | null } | null> {
    const r = await db.query<{ id: string; source_version: string | null; status: string; product_id: string | null }>(
      `SELECT id::text, source_version, status::text, product_id::text FROM product_images
        WHERE source_ref = $1 AND deleted_at IS NULL`,
      [sourceRef],
    );
    const x = r.rows[0];
    return x ? { id: x.id, sourceVersion: x.source_version, status: x.status, productId: x.product_id } : null;
  }

  /** Ошибки позиций → `sync_errors` (entity `images`). Не более `max` записей; остаток — сводкой. */
  async writeErrors(db: Db, errors: readonly ImageItemError[], runId?: string | null, max = 200): Promise<number> {
    let n = 0;
    for (const e of errors.slice(0, max)) {
      await db.query(
        `INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, payload, severity)
         VALUES ($1, 'images', $2, $3, $4, $5, $6::jsonb, $7)`,
        [
          runId ?? null,
          e.onecRef ?? null,
          e.localId ?? null,
          e.errorCode,
          e.message.slice(0, 2000),
          e.payload ? JSON.stringify(e.payload) : null,
          e.severity,
        ],
      );
      n += 1;
    }
    if (errors.length > max) {
      await writeSyncError(db, {
        entity: 'images',
        errorCode: errors[max].errorCode,
        severity: 'warning',
        message: `ещё ${errors.length - max} ошибок фото (сводка)`,
        ...(runId ? { syncRunId: runId } : {}),
      });
      n += 1;
    }
    return n;
  }
}
