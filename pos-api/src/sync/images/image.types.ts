import type { SyncErrorCode } from '../../jobs/sync-errors.writer.js';

/**
 * Запись списка файлов-фото источника (05 ONEC-006, SYNC-035): присоединённый файл номенклатуры 1С
 * (`Catalog_НоменклатураПрисоединенныеФайлы`: элемент `/changes`, строка OData) или файл разовой выгрузки
 * (CommerceML `import_files`, каталог томов).
 */
export interface ImageFileEntry {
  /**
   * Ключ в источнике → `product_images.source_ref`: `Ref_Key` присоединённого файла (uuid) или
   * `import:<ownerRef>/<относительный путь>` для разовой выгрузки (07 §5.23: «Ref_Key … или путь»).
   */
  readonly sourceRef: string;
  /** `onec_ref` владельца — товара (`Catalog_Номенклатура`) или характеристики. Привязка — только по нему (D-30). */
  readonly ownerRef: string | null;
  /** Версия источника (`ДатаМодификацииУниверсальная|Размер` или `sha256:<hex>`); смена → повторное скачивание. */
  readonly sourceVersion: string | null;
  /** Порядок в галерее; главное фото — наименьший `sort_order` среди готовых (0 — главное по данным источника). */
  readonly sortOrder?: number;
  /** Пометка удаления / исчезновение в источнике → `deleted_at` (файл остаётся до регламентной очистки). */
  readonly deletionMark?: boolean;
  /**
   * Признак главного файла от 1С (`ImageFileChange.isMain`, предложение; `product_images.onec_is_main`).
   * `undefined`/`null` — источник признак не передаёт: прежнее значение строки сохраняется.
   */
  readonly isMain?: boolean | null;
}

/** Ошибка позиции фото → `sync_errors` (entity `images`; без ПДн — только ссылки 1С и коды). */
export interface ImageItemError {
  readonly errorCode: SyncErrorCode;
  readonly severity: 'warning' | 'error';
  readonly message: string;
  readonly onecRef?: string | null;
  readonly localId?: string | null;
  readonly payload?: Readonly<Record<string, unknown>>;
}

/** Итог регистрации списка файлов. */
export interface RegisterResult {
  received: number;
  inserted: number;
  updated: number;
  unchanged: number;
  markedDeleted: number;
  /** Владелец не найден среди товаров/характеристик → строка не создаётся (NOT_FOUND_LOCAL). */
  ownerNotFound: number;
  invalid: number;
  /** Товары, у которых могло смениться главное фото. */
  readonly affectedProducts: Set<string>;
  readonly errors: ImageItemError[];
}

/** Счётчики прогона фото (`sync_runs.counts`, 05 SYNC-037). */
export interface ImageRunCounts {
  listed: number;
  registered: number;
  markedDeleted: number;
  ownerNotFound: number;
  /** Скачано тело (200). */
  downloaded: number;
  /** `If-None-Match` → 304: файл не перекачивался и не обрабатывался (SYNC-035). */
  notModified: number;
  /** Тот же sha256 уже в хранилище: файлы не пересоздавались, только ссылка (D-30). */
  deduplicated: number;
  /** Сгенерированы размеры WebP (sharp). */
  processed: number;
  /** Готово к показу (`status = ready`). */
  ready: number;
  /** Ошибки: битый файл, ошибка скачивания, несовпадение хэша. */
  failed: number;
  /** 404 в источнике → `missing_source` (заглушка на клиенте). */
  missing: number;
  /** Не обработано: источник байтов недоступен в этом режиме (`odata_only` без выгрузки). */
  skipped: number;
  errors: number;
}

export function emptyImageCounts(): ImageRunCounts {
  return {
    listed: 0,
    registered: 0,
    markedDeleted: 0,
    ownerNotFound: 0,
    downloaded: 0,
    notModified: 0,
    deduplicated: 0,
    processed: 0,
    ready: 0,
    failed: 0,
    missing: 0,
    skipped: 0,
    errors: 0,
  };
}

/** Канонический UUID (ссылка 1С). */
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function normRef(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim().toLowerCase();
  return UUID_RE.test(s) ? s : null;
}
