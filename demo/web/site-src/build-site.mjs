// Оптомстрой POS · веб-демо · сборка страницы сайта (WP-S1).
//
//   node demo/web/site-src/build-site.mjs [--out <dir>] [--check] [--pii-map <file>] [--tokens <file>]
//
// 1. demo-tokens.css — CSS-переменные --pd-* из contracts/design-tokens/tokens.json (цвета, отступы, радиусы, текст,
//    тени, длительности, layout). meta theme-color в index.html и demo-closed.html — tokens color.primary.
// 2. demo-data.js — данные подсказки «Как войти» (plan §3.6): роли и телефоны, код 246810, пример PIN 715382, тестовые
//    клиенты (метка — слово для поиска по имени, ui:A uiA-09). Имена тестовых клиентов — из demo/web/backend/pii-map.json (WP-B4),
//    если файл есть, иначе — таблица plan §3.5 / ADR-113 п. 11 (б).
// 3. Проверка: в файлах страницы нет запрещённых строк ПДн (прежние ФИО и телефоны клиентов Windows-демо).
// 4. --out <dir>: копирует публикуемые файлы (без dev/ и этого скрипта) в каталог сайта (WP-N1: demo/web/site).
// --check: только проверить, что сгенерированные файлы актуальны (код 1 — устарели или нашлись запрещённые строки).
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
const OUT = arg('out', null);
const CHECK = arg('check', false) === true;
const TOKENS = resolve(arg('tokens', join(REPO, 'contracts', 'design-tokens', 'tokens.json')));
const PII_MAP = resolve(arg('pii-map', join(REPO, 'demo', 'web', 'backend', 'pii-map.json')));

// Публикуемые файлы страницы (порядок — для отчёта).
export const PUBLISHED = [
  'index.html',
  'demo-closed.html',
  'demo-closed.js',
  'demo-tokens.css',
  'demo-screen.css',
  'demo-panel.css',
  'demo-data.js',
  'demo-env.js',
  'demo-lock.js',
  'demo-reset.js',
  'demo-bridge.js',
  'demo-panel.js',
  'demo-boot.js',
  'api-unavailable.json',
  'robots.txt',
];

// plan WP-B4 + critic [10]: прежние ФИО и телефоны клиентов Windows-демо не должны попасть на сайт.
export const FORBIDDEN = [
  'Асанов', 'Асанова', 'Айгуль', 'Бакыт', 'Токтогулов', 'Эрлан', 'Жумабаева', 'Нургуль', 'Алыбаев', 'Нуралиева',
  'Чистый Дом', 'Лимит-Строй', '+996700123456', '+996700223344', '+99670007000', '996 700 123 456', '996 700 223 344',
];

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const kebab = (s) => String(s).replace(/([a-z0-9])([A-Z])/g, '$1-$2').replace(/_/g, '-').toLowerCase();
const hexRgb = (hex) => {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex).trim());
  if (!m) throw new Error(`не цвет: ${hex}`);
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};

function tokensCss(raw) {
  const t = JSON.parse(raw);
  const lines = [];
  const v = (name, value) => lines.push(`  --pd-${name}: ${value};`);
  for (const [k, val] of Object.entries(t.color)) {
    if (val && typeof val === 'object') {
      if (val.rgb !== undefined && val.opacity !== undefined) {
        const [r, g, b] = hexRgb(val.rgb);
        v(`color-${kebab(k)}`, `rgba(${r}, ${g}, ${b}, ${val.opacity})`);
        v(`color-${kebab(k)}-rgb`, `${r}, ${g}, ${b}`);
      }
      continue;
    }
    v(`color-${kebab(k)}`, String(val).toUpperCase());
  }
  for (const [k, val] of Object.entries(t.space || {})) v(`space-${k}`, `${val}px`);
  for (const [k, val] of Object.entries(t.radius || {})) v(`radius-${kebab(k)}`, `${val}px`);
  const fam = t.text && t.text.fontFamily ? t.text.fontFamily : 'Inter';
  v('font-family', `'${fam}', 'Segoe UI', Roboto, Arial, sans-serif`);
  for (const [name, s] of Object.entries((t.text && t.text.styles) || {})) {
    v(`text-${kebab(name)}-size`, `${s.fontSize}px`);
    v(`text-${kebab(name)}-line`, `${s.lineHeight}px`);
    v(`text-${kebab(name)}-weight`, String(s.fontWeight));
  }
  for (const [k, e] of Object.entries(t.elevation || {})) {
    const shadows = (e.shadows || []).map((s) => {
      const [r, g, b] = hexRgb(s.color.rgb);
      return `${s.x}px ${s.y}px ${s.blur}px ${s.spread}px rgba(${r}, ${g}, ${b}, ${s.color.opacity})`;
    });
    v(`shadow-${k}`, shadows.length ? shadows.join(', ') : 'none');
  }
  for (const [k, val] of Object.entries((t.motion && t.motion.duration) || {})) v(`motion-${kebab(k)}`, `${val}ms`);
  for (const [k, val] of Object.entries((t.motion && t.motion.curve) || {})) v(`curve-${kebab(k)}`, `cubic-bezier(${val.join(', ')})`);
  for (const [k, val] of Object.entries(t.layout || {})) {
    if (typeof val === 'number' && !/Columns$/.test(k)) v(`layout-${kebab(k)}`, `${val}px`);
  }
  const header = [
    '/*',
    ' * СГЕНЕРИРОВАНО demo/web/site-src/build-site.mjs — не править вручную.',
    ` * Источник: contracts/design-tokens/tokens.json ${t.meta && t.meta.version ? `v${t.meta.version}` : ''} (палитра ${t.meta ? t.meta.palette : '?'}), sha256 ${sha256(raw)}.`,
    ' */',
  ];
  return { css: `${header.join('\n')}\n:root {\n${lines.join('\n')}\n}\n`, primary: String(t.color.primary).toUpperCase(), version: t.meta && t.meta.version };
}

// Тестовые клиенты по сценариям (plan §3.5, ADR-113 п. 11 (б)) — запасная таблица, пока нет pii-map.json.
// `search` — слово для поиска по имени (кассир, старший продавец, администратор, руководитель); продавец ищет только по
// полному номеру `phone` (ядро §19.4, `customer-match.ts`). Прежние метки «0102»… вводили в заблуждение: у продавца
// поиск по 4 цифрам не работает, у остальных «0102» находит и «Клиент 20 (тест)» (ui:A uiA-09, ui:B B-04).
const FALLBACK_CUSTOMERS = [
  { search: 'Просрочка', phone: '+996700000102', name: 'Покупатель Просрочка (тест)', note: 'просрочка — продажа в долг запрещена' },
  { search: 'Долг в лимите', phone: '+996700000101', name: 'Покупатель Долг в лимите (тест)', note: 'долг в лимите — продажа в долг разрешена' },
  { search: 'Лимит превышен', phone: '+996700000104', name: 'ОсОО Лимит превышен (тест)', note: 'кредитный лимит превышен' },
  { search: 'Без долга', phone: '+996700000103', name: 'ОсОО Без долга (тест)', note: 'без долга' },
];

// Терпимый разбор pii-map.json (формат задаёт WP-B4): ищем пары «телефон → тестовое имя» в любом месте JSON —
// объекты {phone|testPhone|newPhone|to.phone…, name|testName|newName|to.name…} и словари {"+996700000101": "имя"}.
function namesFromPiiMap(json) {
  const out = {};
  // Формат WP-B4 (version 1): tables.SCENARIO_NAMES.entries[сценарий].to + tables.CASHIER_SCENARIO_PHONES.entries[сценарий].to.
  const t = json && json.tables;
  if (t && t.SCENARIO_NAMES && t.CASHIER_SCENARIO_PHONES) {
    const names = t.SCENARIO_NAMES.entries || {};
    const phones = t.CASHIER_SCENARIO_PHONES.entries || {};
    for (const [scenario, ph] of Object.entries(phones)) {
      const d = String((ph && ph.to) || '').replace(/\D/g, '');
      const n = names[scenario] && names[scenario].to;
      if (/^99670000010\d$/.test(d) && typeof n === 'string' && n.trim()) out[d.slice(-4)] = n.trim();
    }
    if (Object.keys(out).length) return out;
  }
  const phoneKeys = ['testPhone', 'newPhone', 'phoneTest', 'phone_e164', 'phoneE164', 'phone'];
  const nameKeys = ['testName', 'newName', 'nameTest', 'fullName', 'name', 'title'];
  const digits = (s) => String(s || '').replace(/\D/g, '');
  const take = (phone, name) => {
    const d = digits(phone);
    if (/^99670000010\d$/.test(d) && typeof name === 'string' && name.trim()) out[d.slice(-4)] = name.trim();
  };
  const pick = (o, keys) => {
    for (const k of keys) {
      if (o[k] !== undefined && typeof o[k] !== 'object') return o[k];
      if (o.to && typeof o.to === 'object' && o.to[k] !== undefined && typeof o.to[k] !== 'object') return o.to[k];
      if (o.new && typeof o.new === 'object' && o.new[k] !== undefined && typeof o.new[k] !== 'object') return o.new[k];
    }
    return undefined;
  };
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    take(pick(node, phoneKeys), pick(node, nameKeys));
    for (const [k, val] of Object.entries(node)) {
      if (typeof val === 'string' && /^\+?996\s?700\s?000\s?10\d$/.test(k.trim())) take(k, val);
      else walk(val);
    }
  };
  walk(json);
  return out;
}

function loginData() {
  let source = 'plan §3.5 / ADR-113 п. 11 (б) (demo/web/backend/pii-map.json ещё нет)';
  let customers = FALLBACK_CUSTOMERS.map((c) => ({ ...c }));
  let forbidden = [];
  if (existsSync(PII_MAP)) {
    const raw = readFileSync(PII_MAP, 'utf8');
    const json = JSON.parse(raw);
    if (Array.isArray(json.forbidden)) forbidden = json.forbidden.filter((s) => typeof s === 'string' && s);
    const names = namesFromPiiMap(json);
    let used = 0;
    customers = customers.map((c) => {
      const n = names[c.phone.slice(-4)];
      if (n) used++;
      return n ? { ...c, name: n } : c;
    });
    source = `demo/web/backend/pii-map.json sha256 ${sha256(raw)} (${used} из ${customers.length} имён)`;
  }
  const data = {
    source,
    otpCode: '246810',
    pinExample: '715382',
    pinBad: ['111111', '123456'],
    customerPinNote: 'Покупатель при первом входе заполняет короткую анкету и задаёт PIN из 4 цифр.',
    // plan §3.6: роли и телефоны в этом порядке.
    roles: [
      { phone: '+996777000902', label: 'Продавец (по приглашению)' },
      { phone: '+996777000907', label: 'Старший продавец' },
      { phone: '+996777000906', label: 'Кассир' },
      { phone: '+996777000901', label: 'Администратор' },
      { phone: '+996777000909', label: 'Руководитель' },
      { phone: '+996777000905', label: 'Новый покупатель' },
      { phone: '+996777000903', label: 'Новый покупатель' },
      { phone: '+996700000101', label: 'Покупатель с карточкой «1С»' },
      { phone: '+996777000904', label: 'Свободный номер для приглашения' },
    ],
    customers,
    qrDefaultPolls: 5,
    // Оценка «≈ N с» в панели: один цикл опроса «1С» в браузере — около 3,6 с (QR_ONEC_POLL_SECONDS = 2 плюс опрос
    // очереди задач); 5 опросов ≈ 18 с (ui:A uiA-08: оплата пришла через 18,2 с, а панель обещала ≈ 10 с).
    qrPollSeconds: 3.6,
  };
  const js = [
    '/*',
    ' * СГЕНЕРИРОВАНО demo/web/site-src/build-site.mjs — не править вручную.',
    ` * Подсказка «Как войти» демо-панели (plan §3.6). Тестовые клиенты: ${source}.`,
    ' */',
    '(function (g) {',
    "  'use strict';",
    '  var P = g.PosDemoPage = g.PosDemoPage || {};',
    `  P.data = ${JSON.stringify(data, null, 2).replace(/\n/g, '\n  ')};`,
    '})(window);',
    '',
  ].join('\n');
  return { js, data, forbidden };
}

function setThemeColor(file, primary) {
  const p = join(HERE, file);
  const src = readFileSync(p, 'utf8');
  const next = src.replace(/(<meta name="theme-color" content=")#[0-9A-Fa-f]{6}(")/, `$1${primary}$2`);
  return { p, src, next };
}

function main() {
  const problems = [];
  const tokensRaw = readFileSync(TOKENS, 'utf8');
  const tk = tokensCss(tokensRaw);
  const ld = loginData();
  const generated = [
    { file: 'demo-tokens.css', content: tk.css },
    { file: 'demo-data.js', content: ld.js },
  ];
  for (const g of generated) {
    const p = join(HERE, g.file);
    const cur = existsSync(p) ? readFileSync(p, 'utf8') : null;
    if (cur !== g.content) {
      if (CHECK) problems.push(`${g.file} устарел — запустите build-site.mjs без --check`);
      else writeFileSync(p, g.content);
    }
  }
  for (const f of ['index.html', 'demo-closed.html']) {
    const r = setThemeColor(f, tk.primary);
    if (r.src !== r.next) {
      if (CHECK) problems.push(`${f}: theme-color ≠ tokens color.primary ${tk.primary}`);
      else writeFileSync(r.p, r.next);
    }
  }
  const report = [];
  const forbidden = [...new Set([...FORBIDDEN, ...ld.forbidden])];
  for (const f of PUBLISHED) {
    const p = join(HERE, f);
    if (!existsSync(p)) {
      problems.push(`нет файла ${f}`);
      continue;
    }
    const buf = readFileSync(p);
    const text = buf.toString('utf8');
    for (const bad of forbidden) if (text.includes(bad)) problems.push(`${f}: запрещённая строка ПДн «${bad}»`);
    for (const bad of ['D:/', 'D:\\', 'C:/Users', 'C:\\Users', 'file:///']) if (text.includes(bad)) problems.push(`${f}: путь машины разработки «${bad}»`);
    report.push({ file: f, bytes: statSync(p).size, sha256: sha256(buf) });
  }
  if (OUT && !CHECK && !problems.length) {
    mkdirSync(OUT, { recursive: true });
    for (const r of report) copyFileSync(join(HERE, r.file), join(OUT, r.file));
  }
  const total = report.reduce((s, r) => s + r.bytes, 0);
  console.log(JSON.stringify({ tokens: { version: tk.version, primary: tk.primary }, loginData: ld.data.source, files: report.length, bytes: total, out: OUT || null, check: CHECK, problems }, null, 1));
  if (problems.length) process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
