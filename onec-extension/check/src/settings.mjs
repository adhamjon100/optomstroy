// Настройки nastrojki.json: чтение и проверка, мастер первого запуска, сохранение по белому списку
// (секретов в нём нет по построению).
import fs from 'node:fs';
import path from 'node:path';
import { SettingsError } from './secrets.mjs';
import { levenshtein, GUID_RE, decodeTextFile, jsonErrorWhere, stripQuotes } from './util.mjs';
import { parseBaseUrl } from './http.mjs';

export const DEFAULT_LIMITS = { pageLimit: 1000, maxPages: 500, externalIdsMaxPages: 100 };
export const REF_KEYS = ['productRef', 'warehouseRef', 'priceListRef', 'customerRef', 'imageRef'];
const PATH_KEYS = ['passwordFile', 'tokenFile', 'clientKeyFile', 'caFile', 'outDir'];
const TOP_KEYS = ['settingsVersion', 'baseUrl', 'user', 'auth', 'passwordFile', 'tokenFile', 'clientKeyFile', 'caFile',
  'outDir', 'refs', 'phone', 'limits'];
const SECRET_LIKE = /^(password|pass|parol|пароль|token|jwt|clientKey|key|secret|ключ)$/i;

export function defaultSettings() {
  return {
    settingsVersion: 1, baseUrl: '', user: 'pos_hs', auth: 'basic', passwordFile: '', tokenFile: '', clientKeyFile: '',
    caFile: '', outDir: 'protokoly', refs: Object.fromEntries(REF_KEYS.map((k) => [k, ''])), phone: '', limits: { ...DEFAULT_LIMITS },
  };
}

function similar(k, list) {
  return list.find((n) => n.toLowerCase() === k.toLowerCase() || levenshtein(n.toLowerCase(), k.toLowerCase()) <= 2);
}

/** Одиночная обратная черта, за которой не escape JSON (типичная ошибка: "C:\certs\ca.pem"). */
function hasBadEscape(raw) {
  for (const m of raw.matchAll(/\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})?/g)) if (m[0] === '\\') return true;
  return false;
}

/** Чтение файла настроек. @returns {{exists:boolean, settings:object, warnings:string[]}} */
export function loadSettings(file) {
  const warnings = [];
  if (!fs.existsSync(file)) return { exists: false, settings: defaultSettings(), warnings };
  let raw;
  // UTF-8 (с BOM и без) или UTF-16 — Блокнот сохраняет «Юникод» как UTF-16.
  try { raw = decodeTextFile(fs.readFileSync(file)); } catch (e) {
    throw new SettingsError(`не удалось прочитать файл настроек ${path.basename(file)}: ${e.code || 'ошибка чтения'}`);
  }
  let j;
  try { j = JSON.parse(raw); } catch {
    // Текст V8 не показывается: он по-английски и цитирует кусок файла (там может оказаться пароль).
    const w = jsonErrorWhere(raw);
    const at = w ? ` в строке ${w.line}, столбце ${w.col}` : '';
    const slash = hasBadEscape(raw)
      ? '; в пути пишите две обратные черты или прямую: "C:\\\\certs\\\\ca.pem" или "C:/certs/ca.pem"' : '';
    throw new SettingsError(`файл настроек ${path.basename(file)} — ошибка JSON${at}${slash} (значения — в кавычках, после последнего значения запятой нет)`);
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new SettingsError('файл настроек должен содержать объект JSON { … }');
  const s = defaultSettings();
  for (const [k, v] of Object.entries(j)) {
    if (k.startsWith('_')) continue;
    if (SECRET_LIKE.test(k)) {
      throw new SettingsError(`в файле настроек есть ключ «${k}»: пароль, токен и ключ в настройки не пишутся — только файл (passwordFile, tokenFile, clientKeyFile) или скрытый ввод`);
    }
    if (!TOP_KEYS.includes(k)) {
      const sim = similar(k, TOP_KEYS);
      warnings.push(`неизвестный ключ настроек «${k}»${sim ? ` — возможно, опечатка: «${sim}»` : ''}; он не читается`);
      continue;
    }
    if (k === 'refs') {
      if (v && typeof v === 'object') {
        for (const [rk, rv] of Object.entries(v)) {
          if (rk.startsWith('_')) continue;
          if (!REF_KEYS.includes(rk)) {
            const sim = similar(rk, REF_KEYS);
            warnings.push(`неизвестный ключ refs.«${rk}»${sim ? ` — возможно, опечатка: «${sim}»` : ''}`);
            continue;
          }
          const val = String(rv ?? '').trim();
          if (val && !GUID_RE.test(val)) warnings.push(`refs.${rk}: «${val}» — не GUID из 36 символов в нижнем регистре; значение не используется`);
          else s.refs[rk] = val;
        }
      }
      continue;
    }
    if (k === 'limits') {
      if (v && typeof v === 'object') {
        for (const [lk, lv] of Object.entries(v)) {
          if (lk.startsWith('_')) continue;
          if (!(lk in DEFAULT_LIMITS)) { warnings.push(`неизвестный ключ limits.«${lk}»`); continue; }
          if (!Number.isInteger(lv) || lv < 1) { warnings.push(`limits.${lk}: нужно целое число ≥ 1`); continue; }
          s.limits[lk] = lv;
        }
      }
      continue;
    }
    if (k === 'settingsVersion') { s.settingsVersion = v; continue; }
    s[k] = typeof v === 'string' ? (PATH_KEYS.includes(k) ? stripQuotes(v) : v.trim()) : v;
  }
  if (s.auth !== 'basic' && s.auth !== 'bearer') throw new SettingsError(`auth: «${s.auth}» — допустимо basic или bearer`);
  if (s.limits.pageLimit > 5000) { warnings.push('limits.pageLimit больше 5000 — используется 5000'); s.limits.pageLimit = 5000; }
  return { exists: true, settings: s, warnings };
}

/** Сохранение только ключей белого списка. */
export function saveSettings(file, s) {
  const out = {
    _пояснение: 'Настройки программы проверки API 1С. Пароль и ключ сюда НЕ пишутся: их спросят при запуске или прочитают из файлов, пути к которым ниже.',
    settingsVersion: 1,
    baseUrl: s.baseUrl || '',
    user: s.user || 'pos_hs',
    auth: s.auth === 'bearer' ? 'bearer' : 'basic',
    passwordFile: s.passwordFile || '',
    tokenFile: s.tokenFile || '',
    clientKeyFile: s.clientKeyFile || '',
    caFile: s.caFile || '',
    outDir: s.outDir || 'protokoly',
    refs: {
      _пояснение: 'Необязательно. Ссылки (GUID) объектов тестовой копии; пусто — программа возьмёт из /changes.',
      ...Object.fromEntries(REF_KEYS.map((k) => [k, (s.refs && GUID_RE.test(s.refs[k] || '')) ? s.refs[k] : ''])),
    },
    phone: s.phone || '',
    limits: { ...DEFAULT_LIMITS, ...(s.limits || {}) },
  };
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + '\n', 'utf8');
}

/** Мастер первого запуска (§2.3). Секреты здесь не спрашиваются — их спрашивает obtainSecrets (после мастера). */
export async function wizard(prompter, say, base = defaultSettings()) {
  const s = structuredClone(base);
  say('Файл настроек не найден. Ответьте на вопросы (Enter — значение в скобках).');
  for (let i = 0; i < 3; i++) {
    const a = await prompter.line('1) Адрес публикации до /hs, например https://srv-1c/ut_test/hs: ');
    if (a === null) throw new SettingsError('адрес публикации не введён (нет ввода)');
    try {
      const b = parseBaseUrl(a);
      s.baseUrl = b.href;
      for (const n of b.notes) say(`   ${n}: ${b.href}`);
      break;
    } catch (e) { say(`   Не подходит: ${e.message}`); }
  }
  if (!s.baseUrl) throw new SettingsError('адрес публикации не задан');
  const u = await prompter.line(`2) Пользователь [${s.user}]: `);
  if (u && u.trim()) s.user = u.trim();
  const m = await prompter.line('3) Вход: 1 — пароль (Basic), 2 — JWT [1]: ');
  s.auth = (m && m.trim() === '2') ? 'bearer' : 'basic';
  // Сертификат спрашивается здесь, до пароля: он нужен уже этому запуску.
  if (/^https:/i.test(s.baseUrl)) {
    const ca = await prompter.line('4) Файл корневого сертификата (.pem), если сертификат выдан внутренним центром; Enter — не нужен: ');
    if (ca && ca.trim()) s.caFile = stripQuotes(ca);
  }
  return s;
}
