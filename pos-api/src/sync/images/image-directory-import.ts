import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncTrigger } from '../../common/enums.js';
import type { ApplyRunTracker } from '../apply/apply.types.js';
import { ImageDecodeError, processImage, sha256Hex } from './image-processor.js';
import { isImageExtension } from './image-sources.js';
import { ImageStore } from './image-store.js';
import { emptyImageCounts, type ImageItemError, type ImageRunCounts, normRef } from './image.types.js';
import { ProductImageRepository, type ReadyImageMeta } from './product-image.repository.js';

/**
 * Раскладка каталога разовой выгрузки (05 SYNC-036, ONEC-006 «резерв — CML»; D-30):
 * - `commerceml` — выгрузка CommerceML 2.x: `import*.xml` (`Каталог/Товары/Товар`: `Ид` = Ref_Key номенклатуры,
 *   `Ид` вида `<товар>#<характеристика>` — фото характеристики; `Картинка` — путь от каталога XML, обычно `import_files/…`);
 * - `by-name` — выгрузка томов/папки скриптом: `<onec_ref>.<ext>`, `<onec_ref>_<N>.<ext>` или `<onec_ref>/<файл>`.
 * `auto` — `commerceml`, если найден `import*.xml`, иначе `by-name`.
 */
export type DirectoryLayout = 'auto' | 'commerceml' | 'by-name';

export interface DirectoryImportRequest {
  readonly dir: string;
  readonly layout?: DirectoryLayout;
  readonly trigger?: SyncTrigger;
  readonly runId?: string;
  readonly signal?: AbortSignal;
}

export interface DirectoryImportCounts extends ImageRunCounts {
  /** Найдено ссылок «товар → файл». */
  files: number;
  /** Тот же файл (sha256) уже импортирован для этой привязки — без обработки. */
  unchanged: number;
}

export interface DirectoryImportResult {
  readonly runId: string;
  readonly status: 'success' | 'partial';
  readonly layout: Exclude<DirectoryLayout, 'auto'>;
  readonly counts: DirectoryImportCounts;
}

/** Ссылка «владелец → файл» из выгрузки. */
export interface DirectoryImageRef {
  /** Ссылка 1С товара или характеристики (uuid) — или исходная строка `Ид`, если это не uuid (ошибка). */
  readonly ownerRef: string;
  /** Путь файла относительно корня выгрузки (прямые слэши). */
  readonly relPath: string;
  readonly sortOrder: number;
}

const MAX_SOURCE_BYTES = 64 * 1024 * 1024;
const MAX_DEPTH = 6;

/**
 * Разовый импорт фото из каталога файлов (выгрузка CommerceML или томов; фаза 0 без HS, SYNC-036; RM-E-003).
 * Привязка — только по `onec_ref` из выгрузки (владелец не найден → `NOT_FOUND_LOCAL`, строки нет); битый файл →
 * строки нет (у прежней — `failed`, заглушка) + `sync_errors`; одинаковый файл (sha256) хранится один раз;
 * повторный импорт того же файла не обрабатывает его заново (`source_version = sha256:<hex>`).
 * `source_ref` = `import:<ownerRef>/<путь>` — не пересекается с `Ref_Key` HS и не попадает в очередь HS.
 */
export class ImageDirectoryImporter {
  private readonly repo = new ProductImageRepository();

  constructor(
    private readonly pool: pg.Pool,
    private readonly store: ImageStore,
    private readonly runs: ApplyRunTracker,
    private readonly log: Logger,
    private readonly options: { readonly limitInputPixels?: number } = {},
  ) {}

  async run(req: DirectoryImportRequest): Promise<DirectoryImportResult> {
    const root = path.resolve(req.dir);
    const st = await stat(root);
    if (!st.isDirectory()) throw new Error(`импорт фото: ${root} — не каталог`);
    const ownRun = !req.runId;
    const runId =
      req.runId ?? (await this.runs.start({ entity: 'images', mode: 'full', trigger: req.trigger ?? 'manual' }));
    const counts: DirectoryImportCounts = { ...emptyImageCounts(), files: 0, unchanged: 0 };
    const errors: ImageItemError[] = [];
    try {
      const xmls = await findFiles(root, (rel) => /(^|\/)import[^/]*\.xml$/i.test(rel));
      const layout: Exclude<DirectoryLayout, 'auto'> =
        req.layout && req.layout !== 'auto' ? req.layout : xmls.length > 0 ? 'commerceml' : 'by-name';
      const refs =
        layout === 'commerceml' ? await collectCommerceMl(root, xmls, errors) : await collectByName(root, errors);
      counts.files = refs.length;
      const affected = new Set<string>();
      await this.importRefs(root, refs, counts, errors, affected, req.signal);
      await this.repo.refreshPrimary(this.pool, affected);
      counts.errors += await this.repo.writeErrors(this.pool, errors, runId, 1000);
      const status = counts.errors > 0 ? 'partial' : 'success';
      if (ownRun) await this.runs.finish({ runId, entity: 'images', status, counts: { ...counts, layout } });
      this.log.info({ runId, layout, counts }, 'images.import.finished');
      return { runId, status, layout, counts };
    } catch (e) {
      if (ownRun) {
        await this.runs
          .finish({
            runId,
            entity: 'images',
            status: 'failed',
            counts: { ...counts },
            errorSummary: e instanceof Error ? e.message : String(e),
          })
          .catch(() => undefined);
      }
      throw e;
    }
  }

  private async importRefs(
    root: string,
    refs: readonly DirectoryImageRef[],
    counts: DirectoryImportCounts,
    errors: ImageItemError[],
    affected: Set<string>,
    signal?: AbortSignal,
  ): Promise<void> {
    // Владельцы — одним запросом; неизвестные не обрабатываются (фото чужого товара невозможно, D-30).
    const known = await this.knownOwners(refs.map((r) => r.ownerRef));
    for (const r of refs) {
      if (signal?.aborted) return;
      const owner = normRef(r.ownerRef);
      if (!owner || !known.has(owner)) {
        counts.ownerNotFound += 1;
        errors.push({
          errorCode: owner ? 'NOT_FOUND_LOCAL' : 'VALIDATION',
          severity: 'warning',
          message: owner
            ? 'товар/характеристика выгрузки не найдены по onec_ref — фото не привязано'
            : 'Ид товара выгрузки — не ссылка 1С (uuid) — фото не привязано',
          onecRef: owner,
          payload: { file: r.relPath.slice(0, 200) },
        });
        continue;
      }
      const abs = safeJoin(root, r.relPath);
      if (!abs) {
        errors.push({
          errorCode: 'VALIDATION',
          severity: 'error',
          message: 'путь файла фото вне каталога выгрузки — пропущен',
          onecRef: owner,
          payload: { file: r.relPath.slice(0, 200) },
        });
        counts.failed += 1;
        continue;
      }
      const sourceRef = `import:${owner}/${r.relPath}`;
      let data: Buffer;
      try {
        const fst = await stat(abs);
        if (!fst.isFile()) throw new Error('не файл');
        if (fst.size > MAX_SOURCE_BYTES) throw new Error(`больше ${MAX_SOURCE_BYTES} байт`);
        data = await readFile(abs);
      } catch (e) {
        errors.push({
          errorCode: 'IMAGE_DOWNLOAD',
          severity: 'error',
          message: `файл фото выгрузки не прочитан: ${e instanceof Error ? e.message.split('\n')[0].slice(0, 120) : 'ошибка'}`,
          onecRef: owner,
          payload: { file: r.relPath.slice(0, 200), reason: 'read' },
        });
        counts.failed += 1;
        continue;
      }
      const sha = sha256Hex(data);
      const version = `sha256:${sha}`;
      const existing = await this.repo.bySourceRef(this.pool, sourceRef);
      if (
        existing &&
        existing.sourceVersion === version &&
        existing.status === 'ready' &&
        (await this.store.has(sha))
      ) {
        counts.unchanged += 1;
        continue;
      }
      let meta: ReadyImageMeta | null = (await this.store.has(sha))
        ? await this.repo.readyMetaBySha(this.pool, sha)
        : null;
      if (meta) counts.deduplicated += 1;
      else {
        try {
          const img = await processImage(data, {
            ...(this.options.limitInputPixels ? { limitInputPixels: this.options.limitInputPixels } : {}),
          });
          if (!(await this.store.has(sha))) await this.store.write(sha, img.renders);
          meta = {
            sha256: sha,
            storageKey: ImageStore.storageKey(sha),
            originalMime: img.originalMime,
            originalBytes: img.originalBytes,
            width: img.width,
            height: img.height,
            sizes: img.sizes,
          };
          counts.processed += 1;
        } catch (e) {
          if (!(e instanceof ImageDecodeError)) throw e;
          counts.failed += 1;
          errors.push({
            errorCode: 'IMAGE_DOWNLOAD',
            severity: 'error',
            message: `файл фото выгрузки не читается как изображение (${e.reason}) — показывается заглушка`,
            onecRef: owner,
            ...(existing ? { localId: existing.id } : {}),
            payload: { file: r.relPath.slice(0, 200), reason: e.reason },
          });
          // Новой записи нет; прежняя (другое содержимое по тому же пути) → failed, чтобы не показывать устаревшее.
          if (existing) {
            await this.repo.markFailed(this.pool, existing.id, {
              error: `decode: ${e.reason}`,
              attempts: 1,
              retryAt: null,
              checksum: sha,
            });
            if (existing.productId) affected.add(existing.productId);
          }
          continue;
        }
      }
      const reg = await this.repo.register(this.pool, [
        { sourceRef, ownerRef: owner, sourceVersion: version, sortOrder: r.sortOrder },
      ]);
      errors.push(...reg.errors);
      for (const p of reg.affectedProducts) affected.add(p);
      const row = await this.repo.bySourceRef(this.pool, sourceRef);
      if (!row) continue;
      await this.repo.markReady(this.pool, row.id, meta);
      counts.registered += reg.inserted + reg.updated;
      counts.ready += 1;
    }
  }

  private async knownOwners(refs: readonly string[]): Promise<Set<string>> {
    const uuids = [...new Set(refs.map((r) => normRef(r)).filter((r): r is string => !!r))];
    if (uuids.length === 0) return new Set();
    const r = await this.pool.query<{ ref: string }>(
      `SELECT onec_ref::text AS ref FROM products WHERE onec_ref = ANY($1::uuid[])
       UNION SELECT onec_ref::text FROM product_variants WHERE onec_ref = ANY($1::uuid[]) AND NOT is_default`,
      [uuids],
    );
    return new Set(r.rows.map((x) => x.ref));
  }
}

// ------------------------------------------------------------------ разбор выгрузки

/** Путь внутри корня (защита от `../` и абсолютных путей в `Картинка`). */
export function safeJoin(root: string, rel: string): string | null {
  if (!rel || rel.includes('\0') || path.isAbsolute(rel) || /^[a-zA-Z]:/.test(rel)) return null;
  const abs = path.resolve(root, rel);
  const back = path.relative(root, abs);
  if (!back || back.startsWith('..') || path.isAbsolute(back)) return null;
  return abs;
}

async function findFiles(root: string, match: (rel: string) => boolean): Promise<string[]> {
  const out: string[] = [];
  const walk = async (dir: string, depth: number): Promise<void> => {
    if (depth > MAX_DEPTH) return;
    const entries = await readdir(dir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const e of entries) {
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) await walk(abs, depth + 1);
      else if (e.isFile()) {
        const rel = path.relative(root, abs).split(path.sep).join('/');
        if (match(rel)) out.push(rel);
      }
    }
  };
  await walk(root, 0);
  return out;
}

const XML_ENTITIES: Readonly<Record<string, string>> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function xmlText(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (_m, ent: string) => {
      if (ent.startsWith('#x')) return String.fromCodePoint(Number.parseInt(ent.slice(2), 16));
      if (ent.startsWith('#')) return String.fromCodePoint(Number.parseInt(ent.slice(1), 10));
      return XML_ENTITIES[ent] ?? '';
    })
    .trim();
}

/**
 * Разбор `import*.xml` CommerceML 2.x: для каждого `<Товар>` — первый `<Ид>` (идентификатор товара; вложенные
 * `Ид` свойств/групп идут после него по схеме) и все `<Картинка>`. Без внешнего XML-парсера: структура выгрузки
 * плоская, значения — текст без вложенной разметки.
 */
export function parseCommerceMlImages(xml: string, xmlRelDir: string): DirectoryImageRef[] {
  const out: DirectoryImageRef[] = [];
  const productRe = /<Товар(?:\s[^>]*)?>([\s\S]*?)<\/Товар>/g;
  for (let m = productRe.exec(xml); m; m = productRe.exec(xml)) {
    const body = m[1];
    const id = /<Ид>([\s\S]*?)<\/Ид>/.exec(body);
    if (!id) continue;
    const rawId = xmlText(id[1]);
    // `<товар>#<характеристика>` — фото характеристики (CommerceML 2.05+).
    const [productPart, variantPart] = rawId.split('#');
    const owner = (variantPart && normRef(variantPart)) || normRef(productPart) || rawId;
    const picRe = /<Картинка>([\s\S]*?)<\/Картинка>/g;
    let n = 0;
    for (let p = picRe.exec(body); p; p = picRe.exec(body)) {
      const rel = xmlText(p[1]).replace(/\\/g, '/');
      if (!rel) continue;
      const joined = path.posix.normalize(xmlRelDir ? `${xmlRelDir}/${rel}` : rel);
      out.push({ ownerRef: owner, relPath: joined, sortOrder: n++ });
    }
  }
  return out;
}

async function collectCommerceMl(
  root: string,
  xmls: readonly string[],
  errors: ImageItemError[],
): Promise<DirectoryImageRef[]> {
  const out: DirectoryImageRef[] = [];
  for (const rel of xmls) {
    let xml: string;
    try {
      xml = (await readFile(path.join(root, rel), 'utf8')).replace(/^\uFEFF/, '');
    } catch (e) {
      errors.push({
        errorCode: 'VALIDATION',
        severity: 'error',
        message: `файл выгрузки CommerceML не прочитан: ${e instanceof Error ? e.message.split('\n')[0].slice(0, 120) : 'ошибка'}`,
        payload: { file: rel.slice(0, 200) },
      });
      continue;
    }
    const dir = path.posix.dirname(rel);
    out.push(...parseCommerceMlImages(xml, dir === '.' ? '' : dir));
  }
  return out;
}

const UUID_PART = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const NAME_RE = new RegExp(`^(${UUID_PART})(?:[_ ](\\d{1,4}))?$`);
const DIR_RE = new RegExp(`^${UUID_PART}$`);

async function collectByName(root: string, errors: ImageItemError[]): Promise<DirectoryImageRef[]> {
  const files = await findFiles(
    root,
    (rel) => isImageExtension(path.posix.extname(rel).slice(1)) && path.posix.extname(rel) !== '',
  );
  const out: DirectoryImageRef[] = [];
  const perDir = new Map<string, number>();
  for (const rel of files) {
    const base = path.posix.basename(rel, path.posix.extname(rel));
    const parent = path.posix.basename(path.posix.dirname(rel));
    const byFile = NAME_RE.exec(base);
    if (byFile) {
      out.push({ ownerRef: byFile[1].toLowerCase(), relPath: rel, sortOrder: byFile[2] ? Number(byFile[2]) : 0 });
    } else if (DIR_RE.test(parent)) {
      const n = perDir.get(parent) ?? 0;
      perDir.set(parent, n + 1);
      out.push({ ownerRef: parent.toLowerCase(), relPath: rel, sortOrder: n });
    } else {
      errors.push({
        errorCode: 'VALIDATION',
        severity: 'warning',
        message: 'имя файла фото не содержит ссылку 1С товара — пропущен',
        payload: { file: rel.slice(0, 200) },
      });
    }
  }
  return out;
}
