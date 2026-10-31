// pdf.js на сайте веб-демо (fix:pdfcsp, 2026-10-30) — ОДИН источник для tools/assemble-site.mjs и tools/check-site.mjs.
//
// Зачем: пакет printing 5.14.3 приложения (PdfPreview, Printing.raster) на вебе берёт pdf.js с CDN
// (https://unpkg.com/pdfjs-dist@3.2.146/build/pdf.min.js + pdf.worker.min.js), если на странице нет готового глобального
// `pdfjsLib` с непустым `GlobalWorkerOptions.workerSrc`; адрес CDN заменяется глобальной `dartPdfJsBaseUrl` (база, к
// которой пакет дописывает `pdf.min.js`). Сайт демо отдаёт pdf.js сам: CSP без чужих хостов, предпросмотр работает без
// unpkg.com (и без интернета после загрузки страницы).
//
// Что публикуется (pdfjs/):
//   - pdf.min.mjs, pdf.worker.min.mjs — pdfjs-dist 5.4.296 (Mozilla, Apache-2.0) без изменений: единственная копия
//     pdf.js на машине сборки — pos-api/node_modules/pdfjs-dist (зависимость разработки pdf-parse, версия закреплена
//     package-lock.json pos-api); 3.2.146 нигде нет, а скачивать нельзя. pdf.js 5 — только ES-модули, поэтому пакет
//     printing получает его через загрузчик;
//   - pdf.min.js — загрузчик демо (site-src/pdfjs/pdf.min.js, собственный код): классический скрипт, который пакет
//     вставляет сам (`dartPdfJsBaseUrl = 'pdfjs/'` задаёт demo-boot.js до запуска Flutter); сразу задаёт `pdfjsLib`
//     (getDocument + GlobalWorkerOptions) и подгружает pdf.min.mjs через import() при первом документе;
//   - LICENSE — лицензия пакета pdfjs-dist (раздел 7 THIRD_PARTY_NOTICES.txt — тот же текст).
// Используемый пакетом API (getDocument({data}).promise/destroy, numPages, getPage, getViewport({scale}),
// render({canvasContext, viewport}).promise, cleanup) в pdf.js 5 тот же; проверено tools/pdf-smoke.mjs.
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');

export const PDFJS = {
  package: 'pdfjs-dist',
  version: '5.4.296',
  build: 'f56dc8601',
  spdx: 'Apache-2.0',
  repository: 'https://github.com/mozilla/pdf.js',
  /** Каталог пакета на машине сборки (PDFJS_DIST — другой каталог с тем же пакетом той же версии). */
  source: (process.env.PDFJS_DIST || `${ROOT}/pos-api/node_modules/pdfjs-dist`).replace(/\\/g, '/'),
  /** Файлы пакета → пути сайта; sha256 и размер сверяются при сборке и в check-site. */
  files: [
    { from: 'build/pdf.min.mjs', to: 'pdfjs/pdf.min.mjs', bytes: 418792, sha256: '343b4166b06716a55a8f87175b83223cb1a9ab701eb8a96b2577509d47fbaf4a' },
    { from: 'build/pdf.worker.min.mjs', to: 'pdfjs/pdf.worker.min.mjs', bytes: 1046214, sha256: 'dbcae78a691b3c501508f74b774c6066a57a14a76cefdc9e25ad86b651bb75d5' },
    { from: 'LICENSE', to: 'pdfjs/LICENSE', bytes: 10174, sha256: '0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594' },
  ],
  /** Загрузчик демо: исходник (от demo/web) → путь сайта (имя задаёт пакет printing: `${dartPdfJsBaseUrl}pdf.min.js`). */
  loader: { from: 'site-src/pdfjs/pdf.min.js', to: 'pdfjs/pdf.min.js' },
  /** Значение `window.dartPdfJsBaseUrl` (задаёт site-src/demo-boot.js). */
  baseUrl: 'pdfjs/',
};

export const PDFJS_SITE_FILES = [...PDFJS.files.map((f) => f.to), PDFJS.loader.to];
