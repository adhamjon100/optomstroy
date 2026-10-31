'use strict';
// Шим `querystring` (семантика Node: повторяющийся ключ → массив, '+' → пробел).
function unescape(s) {
  try {
    return decodeURIComponent(String(s).replace(/\+/g, ' '));
  } catch {
    return String(s).replace(/\+/g, ' ');
  }
}
function escape(s) {
  return encodeURIComponent(String(s));
}
function parse(str, sep = '&', eq = '=', options = {}) {
  const out = Object.create(null);
  if (typeof str !== 'string' || str.length === 0) return out;
  const max = options.maxKeys ?? 1000;
  const decode = options.decodeURIComponent ?? unescape;
  let parts = str.split(sep);
  if (max > 0 && parts.length > max) parts = parts.slice(0, max);
  for (const part of parts) {
    if (part === '') continue;
    const i = part.indexOf(eq);
    const k = decode(i >= 0 ? part.slice(0, i) : part);
    const v = i >= 0 ? decode(part.slice(i + eq.length)) : '';
    if (Object.prototype.hasOwnProperty.call(out, k)) {
      const cur = out[k];
      if (Array.isArray(cur)) cur.push(v);
      else out[k] = [cur, v];
    } else out[k] = v;
  }
  return out;
}
function stringifyPrimitive(v) {
  if (typeof v === 'string') return v;
  if (typeof v === 'number' && isFinite(v)) return String(v);
  if (typeof v === 'bigint') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return '';
}
function stringify(obj, sep = '&', eq = '=', options = {}) {
  const enc = options.encodeURIComponent ?? escape;
  if (obj === null || typeof obj !== 'object') return '';
  const parts = [];
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    const ks = enc(stringifyPrimitive(k)) + eq;
    if (Array.isArray(v)) for (const x of v) parts.push(ks + enc(stringifyPrimitive(x)));
    else parts.push(ks + enc(stringifyPrimitive(v)));
  }
  return parts.join(sep);
}
module.exports = { parse, stringify, decode: parse, encode: stringify, escape, unescape, unescapeBuffer: (s) => Buffer.from(unescape(s)) };
