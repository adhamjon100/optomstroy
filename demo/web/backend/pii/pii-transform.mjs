// Замена правдоподобных ФИО, телефонов и ИНН в синтетике кассира (WP-B1, критик [10]). Работает в onLoad плагина
// esbuild над .build/pos-api-dist/integrations/onec/synthetic-cashier.js по таблице backend/pii-map.json:
//  1) таблицы NAMES_INDIVIDUAL, NAMES_LEGAL, SCENARIO_NAMES, CASHIER_SCENARIO_PHONES заменяются целиком; перед
//     заменой содержимое сверяется с `from` — если pos-api поменял таблицу, сборка останавливается;
//  2) шаблоны имён, телефонов и ИНН обычных клиентов — точная замена выражения (ровно одно вхождение);
//  3) `literals` — во всех файлах pos-api-dist (остатки в комментариях);
//  4) в итоговом модуле не должно остаться ни одной строки из `forbidden`.
// Исходники pos-api не меняются.
import { readFileSync } from 'node:fs';
import { BACKEND } from '../lib/paths.mjs';

export function loadPiiMap(file = `${BACKEND}/pii-map.json`) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function block(src, declaration, open, close) {
  const at = src.indexOf(declaration);
  if (at < 0) return null;
  if (src.indexOf(declaration, at + 1) >= 0) throw new Error(`pii: объявление «${declaration.trim()}» встречается дважды`);
  const start = src.indexOf(open, at + declaration.length - 1);
  const end = src.indexOf(close, start);
  if (start < 0 || end < 0) return null;
  return { start, end: end + 1, body: src.slice(start + 1, end) };
}
const unq = (s) => s.replace(/\\(.)/g, '$1');

function replaceTable(src, name, spec, out) {
  const isArr = spec.kind === 'array';
  const b = block(src, spec.declaration, isArr ? '[' : '{', isArr ? ']' : '}');
  if (!b) throw new Error(`pii-map устарел: в synthetic-cashier.js нет таблицы ${name}`);
  if (isArr) {
    const got = [...b.body.matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => unq(m[1]));
    const want = spec.entries.map((e) => e.from);
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      throw new Error(`pii-map устарел: ${name} в pos-api = ${JSON.stringify(got)}, в pii-map = ${JSON.stringify(want)}`);
    }
    out.push({ table: name, entries: got.length });
    return src.slice(0, b.start) + JSON.stringify(spec.entries.map((e) => e.to)) + src.slice(b.end);
  }
  const got = Object.fromEntries([...b.body.matchAll(/([A-Za-z_$][\w$]*)\s*:\s*'((?:[^'\\]|\\.)*)'/g)].map((m) => [m[1], unq(m[2])]));
  const want = Object.fromEntries(Object.entries(spec.entries).map(([k, v]) => [k, v.from]));
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`pii-map устарел: ${name} в pos-api = ${JSON.stringify(got)}, в pii-map = ${JSON.stringify(want)}`);
  }
  out.push({ table: name, entries: Object.keys(got).length });
  const repl = Object.fromEntries(Object.entries(spec.entries).map(([k, v]) => [k, v.to]));
  return src.slice(0, b.start) + JSON.stringify(repl) + src.slice(b.end);
}

/** Остатки-литералы (комментарии, строки) в любом файле pos-api. */
export function applyPiiLiterals(src, map) {
  let s = src;
  let n = 0;
  for (const [from, to] of Object.entries(map.literals ?? {})) {
    if (from.startsWith('$')) continue;
    const parts = s.split(from);
    if (parts.length > 1) {
      n += parts.length - 1;
      s = parts.join(to);
    }
  }
  return { code: s, replaced: n };
}

/** Полная замена для synthetic-cashier.js. Бросает ошибку, если таблица не совпала или что-то осталось. */
export function applyPiiToSyntheticCashier(src, map) {
  const report = { tables: [], templates: [], literals: 0 };
  let s = src;
  for (const [name, spec] of Object.entries(map.tables)) s = replaceTable(s, name, spec, report.tables);
  for (const t of map.templates) {
    const n = s.split(t.from).length - 1;
    if (n !== 1) throw new Error(`pii-map устарел: шаблон «${t.what}» найден ${n} раз (нужно 1): ${t.from}`);
    s = s.replace(t.from, () => t.to);
    report.templates.push(t.what);
  }
  const lit = applyPiiLiterals(s, map);
  s = lit.code;
  report.literals = lit.replaced;
  const left = map.forbidden.filter((x) => s.includes(x));
  if (left.length) throw new Error(`pii: после замены в synthetic-cashier.js остались запрещённые строки: ${left.join(', ')}`);
  return { code: s, report };
}
