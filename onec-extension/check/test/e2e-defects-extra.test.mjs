// Дополнительные дефекты (test/helpers/defects-extra.mjs) через фасад 1С: для каждого — отдельный прогон программы
// отдельным процессом против фасада с известными тестовыми паролем и ключом. Проверяется: ожидаемая проверка —
// ОШИБКА (DX) или ЗАМЕЧАНИЕ (W) с русским фрагментом; код выхода; ни пароля, ни ключа, ни base64(user:password),
// ни ПДн образцов и дефекта нет в консоли, трёх файлах протокола и файле настроек. Не больше 4 прогонов сразу.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { EXTRA_DEFECTS, WARN_DEFECTS } from './helpers/defects-extra.mjs';
import {
  frontWithSecrets, makeConfig, runMain, runInteractive, readProtocol, check, checkTexts, tmpDir,
  SAMPLE_PII, secretForms, leaks, limiter,
} from './helpers/env.mjs';

const dirs = [];
// Сначала дождаться всех прогонов (при --test-name-pattern часть тестов не ждёт свои прогоны).
after(async () => { await Promise.allSettled(results.values()); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const limit = limiter(4);

async function runDefect(d) {
  const { front, password, clientKey } = await frontWithSecrets({ defect: d });
  try {
    const dir = tmpDir(`oc-dx-${d.id}-`);
    dirs.push(dir);
    const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
    const base = ['--config', cfg, '--allow-http'];
    let r;
    if (d.rereg) {
      // C6 спрашивает «Выполнить перерегистрацию?» — ответ «д» подаётся по подсказке.
      r = await runInteractive([...base, '--allow-write'], [
        [/введите имя публикации/, front.publication],
        [/Выполнить перерегистрацию/, 'д'],
      ]);
    } else {
      r = await runMain([...base, '--no-manual', ...(d.write ? ['--allow-write'] : [])], { input: d.write ? `${front.publication}\n` : '' });
    }
    const protocol = readProtocol(path.join(dir, 'protokoly'));
    return { ...r, protocol, password, clientKey, cfgText: fs.readFileSync(cfg, 'utf8'), journal: front.journal };
  } finally {
    await front.close();
  }
}

const ALL = [...EXTRA_DEFECTS, ...WARN_DEFECTS];
const results = new Map(ALL.map((d) => [d.id, limit(() => runDefect(d))]));

for (const d of ALL) {
  const kind = d.verdict === 'FAIL' ? 'ОШИБКА' : 'ЗАМЕЧАНИЕ';
  test(`${d.id} ${d.what} → ${d.check} ${kind} «${d.fragment}»`, async () => {
    const r = await results.get(d.id);
    assert.ok(r.protocol, `нет протокола; вывод: ${r.out.slice(-800)}`);
    const c = check(r.protocol, d.check);
    assert.ok(c, `в протоколе нет проверки ${d.check}`);
    assert.equal(c.verdict, d.verdict, `${d.check}: ${c.verdict} — ${c.summary}`);
    const texts = checkTexts(c);
    assert.ok(texts.includes(d.fragment), `${d.check}: нет фрагмента «${d.fragment}» в: ${texts.slice(0, 700)}`);
    assert.ok(/[А-Яа-яЁё]/.test(texts), 'текст находки по-русски');
    for (const [id, frag] of d.also || []) {
      const x = check(r.protocol, id);
      assert.ok(x, `в протоколе нет проверки ${id}`);
      assert.equal(x.verdict, 'FAIL', `${id}: ${x.verdict} — ${x.summary}`);
      assert.ok(checkTexts(x).includes(frag), `${id}: нет фрагмента «${frag}» в: ${checkTexts(x).slice(0, 700)}`);
    }
    if (d.exitCode !== null && d.exitCode !== undefined) assert.equal(r.code, d.exitCode, `код выхода ${r.code}; итог: ${r.out.slice(-600)}`);
    assert.equal(r.protocol.json.exitCode, r.code, 'код выхода в протоколе = коду процесса');
    // Приватность: секреты — нигде (и в файле настроек), ПДн образцов и дефекта — ни в консоли, ни в протоколе.
    const all = [r.out, ...r.protocol.texts];
    assert.deepEqual(leaks([...all, r.cfgText], secretForms(r.password, r.clientKey)), [], 'секрет в выводе');
    assert.deepEqual(leaks(all, [...SAMPLE_PII, ...(d.pii || [])]), [], 'ПДн в выводе');
    for (const ch of r.protocol.json.checks) {
      for (const f of ch.findings.filter((x) => x.severity === 'FAIL')) assert.ok(f.where && f.hint, `${ch.id}: нет «где» или подсказки у «${f.text}»`);
    }
    // Без --allow-write в 1С уходят только GET.
    if (!d.write) assert.deepEqual([...new Set(r.journal.map((j) => j.method))], ['GET'], 'без --allow-write — только GET');
  });
}
