#!/usr/bin/env node
/**
 * Покрытие строк по каталогам верхнего уровня из `coverage/<stage>/coverage-summary.json` (json-summary Vitest):
 *   node scripts/coverage-by-dir.mjs coverage/stage-f [src/orders/documents ...]
 * Дополнительные аргументы — подкаталоги, которые считаются отдельно (например, документы внутри orders).
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const [dir = 'coverage/stage-f', ...extra] = process.argv.slice(2);
const summary = JSON.parse(readFileSync(join(dir, 'coverage-summary.json'), 'utf8'));
const groups = new Map();
const add = (key, v) => {
  const g = groups.get(key) ?? { covered: 0, total: 0 };
  g.covered += v.lines.covered;
  g.total += v.lines.total;
  groups.set(key, g);
};
for (const [file, v] of Object.entries(summary)) {
  if (file === 'total') continue;
  const f = file.replace(/\\/g, '/');
  const m = /\/(src\/[^/]+)\//.exec(f);
  if (m) add(m[1], v);
  for (const e of extra) if (f.includes(`/${e}/`)) add(e, v);
}
for (const [k, v] of [...groups].sort()) {
  process.stdout.write(
    `${k.padEnd(24)} ${((100 * v.covered) / v.total).toFixed(2).padStart(6)} %  ${v.covered}/${v.total}\n`,
  );
}
process.stdout.write(`${'всего'.padEnd(24)} ${summary.total.lines.pct.toFixed(2).padStart(6)} %\n`);
