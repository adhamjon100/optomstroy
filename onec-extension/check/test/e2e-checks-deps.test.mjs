// --checks X для каждой проверки каталога (--demo): X не ПРОПУЩЕНО из-за нехватки данных — зависимости добавляются
// сами. Допустимые пропуски: ручные вопросы в демо, M2 (другой компьютер), M11 (программа не выполняет). Если всё
// выбранное пропущено — «ничего не проверено» и код 2, а не зелёный итог. Не больше 6 прогонов одновременно.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { CATALOG } from '../src/checks/index.mjs';
import { runMain, readProtocol, check, tmpDir, limiter } from './helpers/env.mjs';

const root = tmpDir('oc-deps-');
const limit = limiter(6);
const results = new Map(CATALOG.map((d) => [d.id, limit(async () => {
  const out = path.join(root, d.id);
  const r = await runMain(['--demo', '--no-manual', '--checks', d.id, '--out', out]);
  return { ...r, p: readProtocol(out) };
})]));
after(async () => { await Promise.allSettled(results.values()); fs.rmSync(root, { recursive: true, force: true }); });

const ALLOWED_SKIP = /ДЕМО: (ручной вопрос|сверка с 1С) не|--expect-no-access|КП-20 программа не выполняет/;

for (const d of CATALOG) {
  test(`--demo --checks ${d.id}: не пропущено из-за данных`, async () => {
    const r = await results.get(d.id);
    assert.ok(r.p, r.out.slice(-800));
    const c = check(r.p, d.id);
    assert.ok(c, `${d.id} не выполнялась`);
    if (c.verdict === 'SKIP') {
      assert.match(c.summary, ALLOWED_SKIP, `${d.id} ПРОПУЩЕНО: ${c.summary}`);
      assert.equal(r.code, 2, `всё выбранное пропущено — код 2, а не ${r.code}`);
      assert.match(r.out, /Итог: ничего не проверено/);
      assert.equal(r.p.json.nothingChecked, true);
    } else {
      assert.equal(r.code, 0, `${d.id}: ${c.verdict} — ${c.summary}\n${r.out.slice(-600)}`);
    }
  });
}
