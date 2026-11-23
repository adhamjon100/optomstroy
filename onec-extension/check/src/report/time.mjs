// Время Бишкека (+06:00) независимо от часового пояса компьютера.
const OFFSET_MIN = 6 * 60;

function parts(date) {
  const d = new Date(date.getTime() + OFFSET_MIN * 60000);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return {
    y: d.getUTCFullYear(), mo: p(d.getUTCMonth() + 1), da: p(d.getUTCDate()),
    h: p(d.getUTCHours()), mi: p(d.getUTCMinutes()), s: p(d.getUTCSeconds()),
  };
}

/** «2026-11-20T14:05:00+06:00» */
export function isoBishkek(date = new Date()) {
  const t = parts(date);
  return `${t.y}-${t.mo}-${t.da}T${t.h}:${t.mi}:${t.s}+06:00`;
}

/** «20.11.2026 14:05:00 (+06:00)» */
export function humanBishkek(date = new Date()) {
  const t = parts(date);
  return `${t.da}.${t.mo}.${t.y} ${t.h}:${t.mi}:${t.s} (Бишкек, +06:00)`;
}

/** «2026-11-20_14-05» для имён файлов */
export function fileStamp(date = new Date()) {
  const t = parts(date);
  return `${t.y}-${t.mo}-${t.da}_${t.h}-${t.mi}`;
}

/** «ЧЧММСС» для синтетических имён */
export function hhmmss(date = new Date()) {
  const t = parts(date);
  return `${t.h}${t.mi}${t.s}`;
}

export function yearBishkek(date = new Date()) {
  return parts(date).y;
}

export function localOffsetIsBishkek() {
  return -new Date().getTimezoneOffset() === OFFSET_MIN;
}

/** Разбор даты контракта; null при неверном формате. */
export function parseIso(s) {
  if (typeof s !== 'string') return null;
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t) : null;
}
