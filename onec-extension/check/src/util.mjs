// Общие мелочи: время, GUID, проценти, расстояние между строками.
import crypto from 'node:crypto';

export const TOOL_NAME = 'Proverka_API_1C';
export const TOOL_VERSION = '1.1.0';
export const CHECKS_CATALOG = '2026-11-20.2';
export const USER_AGENT = `Optomstroy-Proverka-API-1C/${TOOL_VERSION}`;

export const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const GUID_ANY_RE = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, Math.max(0, ms)));
}

export function randomGuid() {
  return crypto.randomUUID();
}

/** externalId объектов программы: первая группа 5e1f7e57 («selftest»), остальное случайно (§1.6). */
export function selftestGuid() {
  const u = crypto.randomUUID();
  return '5e1f7e57' + u.slice(8);
}

export function sha256hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

export function percentile(values, p) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const idx = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1));
  return s[idx];
}

export function levenshtein(a, b) {
  if (a === b) return 0;
  const m = a.length, n = b.length;
  if (!m) return n;
  if (!n) return m;
  let prev = new Array(n + 1);
  for (let j = 0; j <= n; j++) prev[j] = j;
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[n];
}

export function hasCyrillic(s) {
  return /[А-Яа-яЁё]/.test(String(s));
}

export function truncate(s, n) {
  s = String(s ?? '');
  return s.length > n ? s.slice(0, n) + '…' : s;
}

/** Простой мьютекс-очередь. */
export function createLimiter(n) {
  let active = 0;
  const q = [];
  const next = () => {
    if (active >= n || !q.length) return;
    active++;
    const { fn, res, rej } = q.shift();
    Promise.resolve().then(fn).then(res, rej).finally(() => { active--; next(); });
  };
  return (fn) => new Promise((res, rej) => { q.push({ fn, res, rej }); next(); });
}

/**
 * Где JSON неверный: позиция первой ошибки, строка и столбец (с 1). Текст V8 (по-английски и с куском тела, где могут
 * быть ПДн или секрет) не используется. Для верного JSON — null.
 */
export function jsonErrorWhere(text) {
  const s = String(text ?? '');
  const n = s.length;
  let i = 0;
  const fail = () => { throw new JsonPos(i); };
  const ws = () => { while (i < n && (s[i] === ' ' || s[i] === '\t' || s[i] === '\n' || s[i] === '\r')) i++; };
  const str = () => {
    i++;
    while (i < n) {
      const c = s.charCodeAt(i);
      if (c === 0x22) { i++; return; }
      if (c === 0x5c) {
        const e = s[i + 1];
        if (e !== undefined && '"\\/bfnrt'.includes(e)) { i += 2; continue; }
        if (e === 'u' && /^[0-9a-fA-F]{4}$/.test(s.slice(i + 2, i + 6))) { i += 6; continue; }
        fail();
      }
      if (c < 0x20) fail();
      i++;
    }
    fail();
  };
  const num = () => {
    const m = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(s.slice(i, i + 512));
    if (!m) fail();
    i += m[0].length;
  };
  const value = (depth) => {
    if (depth > 512) fail();
    ws();
    const c = s[i];
    if (c === '{') {
      i++; ws();
      if (s[i] === '}') { i++; return; }
      for (;;) {
        ws();
        if (s[i] !== '"') fail();
        str(); ws();
        if (s[i] !== ':') fail();
        i++;
        value(depth + 1); ws();
        if (s[i] === ',') { i++; continue; }
        if (s[i] === '}') { i++; return; }
        fail();
      }
    }
    if (c === '[') {
      i++; ws();
      if (s[i] === ']') { i++; return; }
      for (;;) {
        value(depth + 1); ws();
        if (s[i] === ',') { i++; continue; }
        if (s[i] === ']') { i++; return; }
        fail();
      }
    }
    if (c === '"') { str(); return; }
    if (c === '-' || (c >= '0' && c <= '9')) { num(); return; }
    for (const w of ['true', 'false', 'null']) if (s.startsWith(w, i)) { i += w.length; return; }
    fail();
  };
  try {
    value(0); ws();
    if (i < n) fail();
    return null;
  } catch (e) {
    if (!(e instanceof JsonPos)) throw e;
    return lineCol(s, Math.min(e.pos, n));
  }
}

class JsonPos {
  constructor(pos) { this.pos = pos; }
}

/** Позиция → строка и столбец (с 1). */
export function lineCol(text, pos) {
  let line = 1, last = -1;
  for (let k = 0; k < pos; k++) if (text.charCodeAt(k) === 10) { line++; last = k; }
  return { pos, line, col: pos - last };
}

/** Текст файла: BOM UTF-8, UTF-16LE/BE (Блокнот «Юникод»), UTF-16 без BOM (нули через байт); иначе UTF-8. */
export function decodeTextFile(buf) {
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) return buf.subarray(2).toString('utf16le');
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const sw = Buffer.from(buf.subarray(2));
    sw.swap16();
    return sw.toString('utf16le');
  }
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) return buf.subarray(3).toString('utf8');
  if (buf.length >= 4 && buf.length % 2 === 0) {
    let oddZero = 0, evenZero = 0;
    const m = Math.min(buf.length, 400);
    for (let k = 0; k < m; k++) if (buf[k] === 0) { if (k % 2) oddZero++; else evenZero++; }
    if (oddZero > m / 4 && evenZero === 0) return buf.toString('utf16le');
    if (evenZero > m / 4 && oddZero === 0) { const sw = Buffer.from(buf); sw.swap16(); return sw.toString('utf16le'); }
  }
  return buf.toString('utf8');
}

/** Путь, вставленный «Копировать как путь» Проводника, — в кавычках: кавычки снимаются. */
export function stripQuotes(s) {
  const t = String(s ?? '').trim();
  const m = /^"(.*)"$/.exec(t) || /^'(.*)'$/.exec(t) || /^«(.*)»$/.exec(t);
  return m ? m[1].trim() : t;
}

export function plural(n, one, few, many) {
  const n10 = n % 10, n100 = n % 100;
  if (n10 === 1 && n100 !== 11) return one;
  if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few;
  return many;
}
