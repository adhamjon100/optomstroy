// Проверка после `tsc -p tsconfig.build.json` (часть `npm run build`, в т.ч. в Dockerfile): точки входа, которые
// запускаются в образе pos-api командой `node dist/…` (16 §4.4, §14.1; docs/ops), есть в dist/. Каталога scripts/ и
// tsx в образе нет — CLI вне src/ в образ не попадает (RV-1: onec_reregister). Код выхода 1 — сборка не годна.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST_ENTRYPOINTS = Object.freeze([
  'main.js', // api
  'worker.js', // worker
  'migrate.js', // migrate (+ --seed)
  'admin/bootstrap/first-admin.cli.js', // первичный администратор (docs/ops/first_admin.md)
  'cli/onec_reregister.js', // перерегистрация плана обмена 1С (16 §14.1 шаг 8; 05 §6.2 п. 4)
]);

const distDir = fileURLToPath(new URL('../dist/', import.meta.url));
const missing = DIST_ENTRYPOINTS.filter((rel) => !existsSync(join(distDir, rel)));
if (missing.length > 0) {
  process.stderr.write(`[check-dist] нет точек входа в dist/: ${missing.join(', ')}\n`);
  process.exit(1);
}
process.stdout.write(`[check-dist] точки входа dist/ на месте: ${DIST_ENTRYPOINTS.length}\n`);
