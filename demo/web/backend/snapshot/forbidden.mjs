// Полный список запрещённых строк ПДн веб-демо (WP-B4; critic [10]): что не должно встречаться ни в снимке, ни в
// backend.js, ни в ответах бэкенда, ни в файлах сайта. Источник — backend/pii-map.json (тот же файл, по которому
// сборка бандла заменяет таблицы synthetic-cashier.js, поэтому overlay, бандл и снимок согласованы) плюс то, что
// выводится из его таблиц: полные прежние имена, фамилии и имена по отдельности, названия ОсОО без кавычек,
// прежние телефоны в E.164 и национальной записи, префиксы прежних шаблонов телефонов и ИНН для seed синтетики
// кассира. Фикстуры contracts/onec/fixtures проверены отдельно (deriveFromFixtures): там только явно тестовые
// «Клиент Пример», «ООО Пример» и +996700000001 — запрещать нечего.
import { readdirSync, readFileSync } from 'node:fs';

/** Слова, которые встречаются и в новых тестовых именах или в обычном тексте, — не ПДн сами по себе. */
const GENERIC = new Set(['ОсОО', 'ИП', 'Покупатель', 'Наличный', 'Без', 'Лимита', 'Неполные', 'Данные', 'Устаревший', 'Снимок', 'Тестов', 'Клиент', 'Чистый', 'Дом', 'Аванс', 'Плюс', 'Бишкек', 'Ремонт', 'Сервис', 'Строй', 'Лимит']);

const fromValues = (tables) => {
  const out = [];
  for (const spec of Object.values(tables)) {
    const entries = Array.isArray(spec.entries) ? spec.entries : Object.values(spec.entries);
    for (const e of entries) out.push(e.from);
  }
  return out;
};

/**
 * → { strings: string[] (отсортировано, без повторов), sources: {pii, derived, added} }.
 * cashierSeed, extraCustomers — DEMO_DATA.cashier: от них зависят прежние шаблоны телефонов и ИНН обычных клиентов.
 */
export function forbiddenStrings(piiMap, { cashierSeed = 7, extraCustomers = 20 } = {}) {
  const derived = new Set();
  for (const v of fromValues(piiMap.tables)) {
    if (/^\+996\d{9}$/.test(v)) {
      derived.add(v);
      derived.add(`0${v.slice(4)}`);
      derived.add(`${v.slice(4, 7)} ${v.slice(7, 10)} ${v.slice(10)}`);
      continue;
    }
    derived.add(v);
    const inner = /«([^»]+)»/.exec(v);
    if (inner) derived.add(inner[1]);
    for (const w of v.replace(/[«»"]/g, ' ').split(/\s+/)) if (w.length >= 4 && !GENERIC.has(w) && !w.includes('-')) derived.add(w);
  }
  // Прежние шаблоны обычных клиентов (seed): телефон +99670 + (seed·10000 + N) и ИНН 10000000000000 + seed·100000 + N
  // (N = 1…extraCustomers). Префиксы — по десяткам N: короче нельзя, иначе ложные совпадения со штрихкодами.
  const phoneBase = `+99670${String(cashierSeed * 10000).padStart(7, '0')}`; // +996700070000
  derived.add(phoneBase.slice(0, 11)); // +9967000700 — N < 100
  for (let d = 0; d <= Math.floor(extraCustomers / 10); d++) derived.add(String(10000000000000 + cashierSeed * 100000 + d * 10).slice(0, 13));
  derived.add('0110202000000'); // ИНН сценарных юрлиц 0110 202000000N
  const pii = new Set(piiMap.forbidden ?? []);
  const all = new Set([...pii, ...derived]);
  // Строки, которые законно есть в новых тестовых именах, исключаются (страховка от ложных срабатываний).
  const newNames = fromValues(piiMap.tables).length ? Object.values(piiMap.tables).flatMap((s) => (Array.isArray(s.entries) ? s.entries : Object.values(s.entries)).map((e) => e.to)) : [];
  const clash = [...all].filter((f) => newNames.some((n) => n.includes(f)));
  for (const c of clash) all.delete(c);
  return {
    strings: [...all].sort(),
    sources: { pii: [...pii].sort(), derived: [...derived].filter((x) => !pii.has(x)).sort(), droppedAsClash: clash },
  };
}

/** Число вхождений каждой запрещённой строки в тексте. → [{ string, count }] только найденные. */
export function scanText(text, strings) {
  const out = [];
  for (const s of strings) {
    let n = 0;
    for (let i = text.indexOf(s); i >= 0; i = text.indexOf(s, i + s.length)) n++;
    if (n) out.push({ string: s, count: n });
  }
  return out;
}

/** Имена, телефоны и ИНН в фикстурах 1С (contracts/onec/fixtures): что там есть (для отчёта). */
export function deriveFromFixtures(dir) {
  const names = new Set();
  const phones = new Set();
  const taxIds = new Set();
  const walk = (v, k) => {
    if (typeof v === 'string') {
      if (/^(name|fullName|partnerName|counterpartyName|contactName|customerName)$/.test(k) && /[А-Яа-яЁё]/.test(v)) names.add(v);
      for (const m of v.matchAll(/\+996\d{9}/g)) phones.add(m[0]);
      if (/^(taxId|inn)$/i.test(k)) taxIds.add(v);
    } else if (Array.isArray(v)) v.forEach((x) => walk(x, k));
    else if (v && typeof v === 'object') for (const [kk, vv] of Object.entries(v)) walk(vv, kk);
  };
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) walk(JSON.parse(readFileSync(`${dir}/${f}`, 'utf8')), '');
  return { names: [...names].sort(), phones: [...phones].sort(), taxIds: [...taxIds].sort() };
}
