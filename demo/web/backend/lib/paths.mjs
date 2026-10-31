// Пути сборки браузерного бэкенда веб-демо (WP-B1). Всё вычисляется от расположения этого файла, поэтому дерево
// demo/web можно перенести вместе с репозиторием. PGlite берётся из PGLITE_DIR (по умолчанию — копия в глобальном
// netlify-cli; версия и sha256 файлов сверяются с backend/pglite.lock.json).
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const norm = (p) => p.replace(/\\/g, '/');
const here = norm(dirname(fileURLToPath(import.meta.url)));

/** demo/web/backend */
export const BACKEND = norm(resolve(here, '..'));
/** demo/web */
export const WEB = norm(resolve(BACKEND, '..'));
/** корень репозитория */
export const ROOT = norm(resolve(WEB, '../..'));
export const API = `${ROOT}/pos-api`;
export const NM = `${API}/node_modules`;
export const BUILD = `${WEB}/.build`;
/** вывод `tsc -p pos-api/tsconfig.build.json` (не pos-api/dist: там работают тесты и local-stack) */
export const DIST = `${BUILD}/pos-api-dist`;
export const SCRIPTS = `${API}/scripts`;
export const SITE = `${WEB}/site`;
export const OUT = `${SITE}/backend`;
export const SHIMS = `${BACKEND}/shims`;
export const ALIAS = `${BACKEND}/alias`;
/** сгенерированные при сборке модули (vfs-data.cjs и т. п.) */
export const GEN = `${BUILD}/gen`;
export const PGLITE_DIR = norm(
  process.env.PGLITE_DIR || 'C:/Users/Farruh/AppData/Roaming/npm/node_modules/netlify-cli/node_modules/@electric-sql/pglite',
);
export { norm };
