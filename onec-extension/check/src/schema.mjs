// Валидатор подмножества OpenAPI 3.0.3, которое использует контракт 1.2.0:
// $ref, allOf, oneOf (+discriminator), anyOf, type, nullable, required, properties, items, enum, pattern,
// format, minimum/maximum, minItems/maxItems, minLength/maxLength; расширения правил приёма POS
// (x-pos-accepted-values, x-pos-required, x-pos-accepted-pattern). Тексты — по-русски, с путём поля.
//
// Каждая находка: { path, rule, severity, code, text, hint, proposed }.
// rule: E4 (GUID), E5 (форматы), E6 (обязательность и null) — сквозные правила;
//       SCHEMA — прочие нарушения схемы; POS — правила приёма POS (ЗАМЕЧАНИЕ);
//       UNKNOWN_TYPE — неизвестный тип элемента /changes; FIELD — неизвестное поле.
import { levenshtein, truncate } from './util.mjs';
import { maskPhone } from './mask.mjs';

const PROPOSED_NOTE = ' (элемент контракта — предложение; если не согласны, напишите нам)';

export const HINTS = {
  guid: 'В 1С: НРег(Строка(Ссылка.УникальныйИдентификатор())) — 36 символов без фигурных скобок.',
  money: 'В 1С: Формат(Сумма, "ЧДЦ=2; ЧРД=.; ЧГ=0; ЧН=0.00") — строка с точкой и двумя знаками.',
  quantity: 'В 1С: Формат(Количество, "ЧДЦ=3; ЧРД=.; ЧГ=0; ЧН=0.000") — строка с точкой и тремя знаками.',
  percent: 'В 1С: Формат(Процент, "ЧДЦ=2; ЧРД=.; ЧГ=0; ЧН=0.00").',
  datetime: 'В 1С: Формат(Дата, "ДФ=yyyy-MM-ddTHH:mm:ss") + "+06:00" (или ЗаписатьДатуJSON с часовым поясом) — без долей секунды и без Z.',
  phone: 'Телефон — +996 и 9 цифр без пробелов, например +996700123456.',
  currency: 'Валюта — три заглавные латинские буквы, для POS — KGS.',
  required: 'Обязательный ключ передаётся всегда; если значения нет — null (там, где контракт разрешает), для списка — [].',
  nullList: 'Пустой список — [], не null.',
  emptyDate: 'Пустую дату 1С (ЗначениеЗаполнено(Дата) = Ложь, Дата(1, 1, 1)) не форматируйте: передайте null (где контракт разрешает null), иначе — настоящую дату.',
};

const KNOWN_FORMAT_SCHEMAS = {
  Uuid: 'guid', OnecRef: 'guid', ExternalId: 'guid', Money: 'money', Quantity: 'quantity', Percent: 'percent',
  DateTime: 'datetime', Currency: 'currency', PhoneE164: 'phone', OnecObjectType: 'onecType', PosUserCode: 'posUserCode',
};

function typeOfRu(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'список';
  if (typeof v === 'number') return Number.isInteger(v) ? 'целое число' : 'дробное число';
  if (typeof v === 'string') return 'строка';
  if (typeof v === 'boolean') return 'true/false';
  if (typeof v === 'object') return 'объект';
  return typeof v;
}

const TYPE_RU = {
  object: 'объект', array: 'список', string: 'строка', integer: 'целое число', number: 'число', boolean: 'true или false',
};

function showVal(v, fmt) {
  if (fmt === 'phone' && typeof v === 'string') return `«${maskPhone(v)}»`;
  if (typeof v === 'string') return `«${truncate(v, 60)}»`;
  return truncate(JSON.stringify(v), 60);
}

export const NIL_GUID = '00000000-0000-0000-0000-000000000000';

/** Строка похожа на JSON-объект или список (для находки «JSON закодирован дважды»). */
function looksJsonText(s) {
  if (!/^\s*[[{]/.test(s)) return false;
  try { const x = JSON.parse(s); return !!x && typeof x === 'object'; } catch { return false; }
}

const DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
const RFC3339 = /^(\d{4})-(\d{2})-(\d{2})(?:[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:[Zz]|([+-])(\d{2}):(\d{2})))?$/;

/**
 * Проверка даты по календарю и RFC 3339 (date-time; для format: date — только дата). null — дата верна,
 * иначе — причина по-русски. Вид строки (смещение +06:00, без долей секунды) проверяет шаблон контракта отдельно.
 */
export function calendarError(value, only = null) {
  const m = RFC3339.exec(String(value));
  if (!m) return 'дата не по RFC 3339 (ГГГГ-ММ-ДДTчч:мм:сс+06:00)';
  if (only === 'date' && m[4] !== undefined) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (mo < 1 || mo > 12) return `месяца ${m[2]} нет — такой даты нет в календаре`;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const max = mo === 2 && leap ? 29 : DAYS[mo - 1];
  if (d < 1 || d > max) return `${m[3]}.${m[2]}.${m[1]} — такой даты нет в календаре (в этом месяце ${max} дн.)`;
  if (m[4] === undefined) return null;
  if (Number(m[4]) > 23) return `час ${m[4]} — часов в сутках от 00 до 23`;
  if (Number(m[5]) > 59) return `минута ${m[5]} — минут от 00 до 59`;
  if (Number(m[6]) > 60) return `секунда ${m[6]} — секунд от 00 до 59`;
  if (m[8] !== undefined && (Number(m[8]) > 23 || Number(m[9]) > 59)) return `смещение ${m[7]}${m[8]}:${m[9]} — не часовой пояс`;
  return null;
}

/** Пути полей вне контракта из находок валидатора («поле … нет в контракте», «возможно, опечатка»). */
export function foreignPathsOf(errors) {
  const out = new Set();
  for (const e of errors) if (e.rule === 'FIELD' && (e.code === 'unknown-field' || e.code === 'typo')) out.add(e.path);
  return out;
}

export class Validator {
  /**
   * @param {import('./contract.mjs').Contract} contract
   * @param {{maxErrors?: number}} opts
   */
  constructor(contract, opts = {}) {
    this.c = contract;
    this.maxErrors = opts.maxErrors ?? 2000;
    this.patternFmt = new Map();
    for (const [name, fmt] of Object.entries(KNOWN_FORMAT_SCHEMAS)) {
      const s = contract.schema(name);
      if (s?.pattern && !this.patternFmt.has(s.pattern)) this.patternFmt.set(s.pattern, fmt);
    }
    // Шаблоны «дата или дата-время» (DiscountChange.validFrom/validTo) и денег без минуса.
    this.patternFmt.set('^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}:\\d{2}\\+06:00)?$', 'dateOrDatetime');
    this.patternFmt.set('^\\d+\\.\\d{2}$', 'money');
    this.extraRules = {
      Totals: (v, path, st) => {
        if (v && typeof v === 'object' && typeof v.currency === 'string' && v.currency !== 'KGS') {
          this.#err(st, path ? `${path}.currency` : 'currency', 'E5', 'FAIL', 'currency-not-kgs',
            `валюта не KGS: ${showVal(v.currency)} — в итогах POS принимает только KGS`, HINTS.currency);
        }
      },
      ImageFileChange: (v, path, st) => {
        if (!v || typeof v !== 'object') return;
        const exts = this.c.imageExtensions();
        if (typeof v.extension === 'string' && !exts.includes(v.extension.toLowerCase().replace(/^\./, ''))) {
          this.#err(st, `${path}.extension`, 'POS', 'WARN', 'image-ext',
            `POS не возьмёт файл как фото: расширение ${showVal(v.extension)} не из списка x-pos-image-extensions`, null);
        }
        if (Number.isInteger(v.size) && v.size > this.c.imageMaxBytes()) {
          this.#err(st, `${path}.size`, 'POS', 'WARN', 'image-size',
            `POS не обработает файл больше 10 МБ (size = ${v.size})`, null);
        }
      },
    };
  }

  /**
   * @param value значение (разобранный JSON)
   * @param schema схема или {$ref}
   * @returns {{errors: object[], truncated: number}}
   */
  validate(value, schema, { path = '', maxErrors = this.maxErrors } = {}) {
    const st = { errors: [], truncated: 0, proposed: false, schemaName: null, max: maxErrors };
    this.#v(value, schema, path, st, { proposed: false, schemaName: null, fmt: null, key: null, quiet: false });
    return { errors: st.errors, truncated: st.truncated };
  }

  /**
   * Пути полей, которых нет в схеме (неизвестные и опечатки), без предела числа находок: для маски протокола —
   * значения таких полей POS не читает, в протокол они идут скрытыми.
   */
  foreignPaths(value, schema) {
    const { errors } = this.validate(value, schema, { maxErrors: Infinity });
    return foreignPathsOf(errors);
  }

  /** Проверка без записи находок: подходит ли значение под схему. */
  matches(value, schema) {
    const { errors } = this.validate(value, schema);
    return !errors.some((e) => e.severity === 'FAIL');
  }

  #err(st, path, rule, severity, code, text, hint, proposed = false) {
    if (st.errors.length >= (st.max ?? this.maxErrors)) { st.truncated++; return; }
    st.errors.push({
      path: path || '(корень)', rule, severity, code,
      text: (path ? `${path}: ` : '') + text + (proposed && severity === 'FAIL' ? PROPOSED_NOTE : ''),
      hint: hint || null, proposed: !!proposed,
    });
  }

  #deref(schema) {
    let s = schema, name = null, proposed = false;
    let guard = 0;
    while (s && s.$ref && guard++ < 20) {
      name = s.$ref.split('/').pop();
      s = this.c.resolve(s.$ref);
      if (s['x-status'] === 'proposed') proposed = true;
    }
    return { s, name, proposed };
  }

  /** Эффективный тип схемы (через $ref и allOf). */
  #effType(schema) {
    const { s } = this.#deref(schema);
    if (!s) return null;
    if (s.type) return s.type;
    for (const sub of s.allOf || []) { const t = this.#effType(sub); if (t) return t; }
    return null;
  }

  #fmtOf(schema, ctxFmt, key) {
    if (ctxFmt) return ctxFmt;
    if (schema.pattern) {
      const f = this.patternFmt.get(schema.pattern);
      if (f === 'money' && key && /percent/i.test(key)) return 'percent';
      if (f) return f;
    }
    return ctxFmt;
  }

  #v(value, schema0, path, st, c) {
    if (!schema0) return;
    let schema = schema0;
    let ctx = c;
    if (schema.$ref) {
      const d = this.#deref(schema);
      schema = d.s;
      const fmt = KNOWN_FORMAT_SCHEMAS[d.name] || ctx.fmt;
      ctx = { ...ctx, schemaName: d.name, proposed: ctx.proposed || d.proposed, fmt: (d.name === 'Percent') ? 'percent' : fmt };
      this.#v1(value, schema, path, st, ctx);
      const hook = this.extraRules[d.name];
      if (hook && !ctx.quiet) hook(value, path, st);
      return;
    }
    this.#v1(value, schema, path, st, ctx);
  }

  #v1(value, schema, path, st, c) {
    const proposed = c.proposed || schema['x-status'] === 'proposed';
    const ctx = { ...c, proposed };

    // ---- null
    if (value === null) {
      if (schema.nullable === true) { if (!ctx.quiet) this.#posRules(value, schema, path, st, ctx); return; }
      if (Array.isArray(schema.enum) && schema.enum.includes(null)) return;
      if (schema.oneOf && schema.oneOf.some((b) => { const { s } = this.#deref(b); return s && (s.nullable || (s.enum || []).includes(null)); })) return;
      const t = this.#effType(schema);
      if (t === 'array') {
        this.#err(st, path, 'E6', 'FAIL', 'null-list', 'пустой список — [], не null', HINTS.nullList, proposed);
      } else if (schema.allOf || schema.type || schema.oneOf || schema.enum) {
        this.#err(st, path, 'E6', 'FAIL', 'null-not-allowed', 'значение null недопустимо — по контракту здесь обязательно значение', HINTS.required, proposed);
      }
      return;
    }

    // ---- allOf
    if (Array.isArray(schema.allOf)) {
      for (const sub of schema.allOf) this.#v(value, sub, path, st, schema.nullable === true ? { ...ctx, nullable: true } : ctx);
    }

    // ---- oneOf / anyOf
    const alts = schema.oneOf || schema.anyOf;
    if (Array.isArray(alts)) {
      if (schema.discriminator && value && typeof value === 'object' && !Array.isArray(value)) {
        const prop = schema.discriminator.propertyName;
        const tv = value[prop];
        const mapRef = schema.discriminator.mapping?.[tv];
        if (!mapRef) {
          if (tv === undefined) {
            this.#err(st, path, 'E6', 'FAIL', 'required', `нет обязательного поля ${prop}`, HINTS.required, proposed);
          } else {
            this.#err(st, `${path}.${prop}`, 'UNKNOWN_TYPE', 'WARN', 'unknown-type',
              `неизвестный тип элемента ${showVal(tv)}: POS пропустит элемент; если это ваш объект вместо типового — сообщите имя`, null);
          }
        } else {
          this.#v(value, { $ref: mapRef }, path, st, ctx);
        }
      } else {
        // Без дискриминатора: подходит хотя бы одна ветка.
        let best = null;
        const isNullOnly = (b) => { const { s } = this.#deref(b); return !!s && Array.isArray(s.enum) && s.enum.length === 1 && s.enum[0] === null; };
        const branches = value === null ? alts : alts.filter((b) => !isNullOnly(b));
        for (const b of branches) {
          const sub = { errors: [], truncated: 0 };
          this.#v(value, b, path, sub, { ...ctx, quiet: true });
          const hard = sub.errors.filter((e) => e.severity === 'FAIL').length;
          if (hard === 0) { best = { hard, b }; break; }
          if (!best || hard < best.hard) best = { hard, b };
        }
        if (best) this.#v(value, best.b, path, st, ctx);
      }
    }

    const type = schema.type;
    const fmt = this.#fmtOf(schema, ctx.fmt, ctx.key);

    // ---- enum
    if (Array.isArray(schema.enum) && schema.enum.length === 1 && schema.enum[0] === null) {
      this.#err(st, path, 'SCHEMA', 'FAIL', 'enum-null', `ожидается null, пришло: ${typeOfRu(value)}`, null, proposed);
      return;
    }
    if (Array.isArray(schema.enum)) {
      if (!schema.enum.includes(value)) {
        this.#err(st, path, 'SCHEMA', 'FAIL', 'enum',
          `значение ${showVal(value, fmt)} не из перечня контракта: ${schema.enum.filter((x) => x !== null).join(', ')}`, null, proposed);
        return;
      }
    }

    if (!type) {
      this.#posRules(value, schema, path, st, ctx);
      return;
    }

    // ---- типы
    switch (type) {
      case 'object': {
        if (typeof value !== 'object' || Array.isArray(value)) {
          const twice = typeof value === 'string' && looksJsonText(value);
          this.#err(st, path, 'SCHEMA', 'FAIL', twice ? 'double-json' : 'type', twice
            ? `ожидается ${TYPE_RU.object}, пришла строка с JSON внутри — JSON закодирован дважды (ЗаписатьJSON от готовой строки JSON)`
            : `ожидается ${TYPE_RU.object}, пришло: ${typeOfRu(value)}`, null, proposed);
          return;
        }
        const props = schema.properties || {};
        for (const r of schema.required || []) {
          if (!(r in value)) {
            const p = props[r];
            const nullable = p && (p.nullable || this.#deref(p).s?.nullable);
            this.#err(st, path ? `${path}.${r}` : r, 'E6', 'FAIL', 'required',
              `нет обязательного поля ${r}` + (nullable ? ' (если значения нет — передайте null)' : ''), HINTS.required, proposed);
          }
        }
        for (const [k, sub] of Object.entries(props)) {
          if (k in value) this.#v(value[k], sub, path ? `${path}.${k}` : k, st, { ...ctx, key: k, fmt: null, nullable: false });
        }
        if (schema.properties && !ctx.quiet) {
          const known = Object.keys(props);
          for (const k of Object.keys(value)) {
            if (k in props) continue;
            const similar = known.find((n) => n.toLowerCase() === k.toLowerCase() || (k.length > 3 && levenshtein(n, k) <= 2));
            const p = path ? `${path}.${k}` : k;
            if (similar) {
              this.#err(st, p, 'FIELD', 'WARN', 'typo', `поле «${k}» — возможно, опечатка: в контракте «${similar}»`, null);
            } else {
              this.#err(st, p, 'FIELD', 'INFO', 'unknown-field', `поле «${k}» нет в контракте 1.2.0 — POS его не читает`, null);
            }
          }
        }
        break;
      }
      case 'array': {
        if (!Array.isArray(value)) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'type', `ожидается ${TYPE_RU.array}, пришло: ${typeOfRu(value)}`, null, proposed);
          return;
        }
        if (Number.isInteger(schema.minItems) && value.length < schema.minItems) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'minItems', `элементов ${value.length} — меньше ${schema.minItems}`, null, proposed);
        }
        if (Number.isInteger(schema.maxItems) && value.length > schema.maxItems) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'maxItems', `элементов ${value.length} — больше предела ${schema.maxItems}`, null, proposed);
        }
        if (schema.items) {
          for (let i = 0; i < value.length; i++) {
            if (st.errors.length >= (st.max ?? this.maxErrors)) { st.truncated++; break; }
            this.#v(value[i], schema.items, `${path}[${i}]`, st, { ...ctx, key: ctx.key, fmt: null, nullable: false });
          }
        }
        break;
      }
      case 'string': {
        if (typeof value !== 'string') {
          if (typeof value === 'number' && (fmt === 'money' || fmt === 'percent')) {
            this.#err(st, path, 'E5', 'FAIL', 'money-number',
              `${fmt === 'percent' ? 'процент передан числом' : 'деньги переданы числом'} (${value}) — нужна строка вида "${Number(value).toFixed(2)}"`, HINTS[fmt]);
          } else if (typeof value === 'number' && fmt === 'quantity') {
            this.#err(st, path, 'E5', 'FAIL', 'qty-number',
              `количество передано числом (${value}) — нужна строка вида "${Number(value).toFixed(3)}"`, HINTS.quantity);
          } else if (fmt === 'guid') {
            this.#err(st, path, 'E4', 'FAIL', 'guid-type', `ссылка не GUID из 36 символов: пришло ${typeOfRu(value)} ${showVal(value)}`, HINTS.guid);
          } else if (fmt === 'datetime') {
            this.#err(st, path, 'E5', 'FAIL', 'date-type', `дата должна быть строкой ГГГГ-ММ-ДДTчч:мм:сс+06:00, пришло: ${typeOfRu(value)}`, HINTS.datetime);
          } else {
            this.#err(st, path, 'SCHEMA', 'FAIL', 'type', `ожидается ${TYPE_RU.string}, пришло: ${typeOfRu(value)} ${showVal(value)}`, null, proposed);
          }
          return;
        }
        if (schema.pattern && !safeTest(schema.pattern, value)) {
          this.#patternError(value, fmt, path, st, proposed);
        } else if (fmt === 'phone' && /^\+996/.test(value) && !/^\+996\d{9}$/.test(value)) {
          // Требования §4.3: телефон в E.164; номер Кыргызстана в E.164 — +996 и 9 цифр (пример +996700000001). POS берёт только /^\+996\d{9}$/: «+9960700000001»
          // (к +996 приписан местный номер с 0) по шаблону E.164 проходит, но в POS отбрасывается — ни поиска, ни SMS.
          const extra = value.length - 4;
          this.#err(st, path, 'E5', 'FAIL', 'phone-kg-digits',
            `телефон ${showVal(value, 'phone')}: после +996 должно быть 9 цифр, пришло ${extra}${/^\+9960/.test(value) && extra === 10 ? '; похоже, к +996 приписан номер с ведущим 0' : ''} (E.164 для Кыргызстана — +996 и 9 цифр, Требования §4.3; такой номер POS отбросит)`,
            HINTS.phone);
        } else if (fmt === 'phone' && !/^\+996\d{9}$/.test(value)) {
          this.#err(st, path, 'E5', 'WARN', 'phone-not-kg', `телефон ${showVal(value, 'phone')} в формате E.164, но не +996 и 9 цифр — проверьте`, HINTS.phone);
        } else if (fmt === 'datetime' || fmt === 'dateOrDatetime' || schema.format === 'date-time' || schema.format === 'date') {
          // Шаблон контракта проверяет только вид (цифры на местах); дата должна существовать в календаре (RFC 3339,
          // format: date-time): 30 февраля, 31 ноября, 24:00, 61 минута — не даты, POS такую строку отвергнет.
          const why = calendarError(value, schema.format === 'date' ? 'date' : null);
          if (why) this.#err(st, path, 'E5', 'FAIL', 'date-calendar', `${why}: ${showVal(value)}`, HINTS.datetime);
          else if (Number(value.slice(0, 4)) < 1900) {
            // Пустая дата 1С (Дата(1, 1, 1) → «0001-01-01T00:00:00+06:00») — не значение: POS прочтёт её как настоящую дату
            // (срок оплаты наступил, момент зачисления есть). Нет значения — null, где контракт разрешает (Требования §4.3).
            const nullable = schema.nullable === true || ctx.nullable === true;
            this.#err(st, path, 'E5', 'FAIL', 'date-empty', nullable
              ? `пустая дата 1С ${showVal(value)} вместо null — если даты нет, передайте null (Требования §4.3 «Обязательность и null»: «да, допускается null»)`
              : `пустая дата 1С ${showVal(value)} — поле обязательно и null не допускает: нужна настоящая дата (Требования §4.3)`, HINTS.emptyDate);
          }
        } else if (fmt === 'guid' && value === NIL_GUID) {
          // Пустая ссылка 1С (ПустаяСсылка().УникальныйИдентификатор()) — не ссылка объекта: у объектов с ней POS не отличит
          // один объект от другого. Ссылка самого объекта (ref) — ОШИБКА, прочие …Ref — «нет значения — null» (Требования §4.3).
          if (ctx.key === 'ref') this.#err(st, path, 'E4', 'FAIL', 'guid-nil', 'пустая ссылка 00000000-0000-0000-0000-000000000000 вместо ссылки объекта — у каждого объекта 1С своя ссылка (Требования §4.3: ref — УникальныйИдентификатор() ссылки)', HINTS.guid);
          else this.#err(st, path, 'E4', 'WARN', 'guid-nil-ref', 'пустая ссылка 00000000-0000-0000-0000-000000000000 — если значения нет, передайте null (Требования §4.3 «Обязательность и null»)', HINTS.required);
        }
        if (Number.isInteger(schema.minLength) && value.length < schema.minLength) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'minLength', schema.minLength === 1 ? 'пустая строка недопустима' : `строка короче ${schema.minLength} символов`, null, proposed);
        }
        if (Number.isInteger(schema.maxLength) && value.length > schema.maxLength) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'maxLength', `строка длиннее ${schema.maxLength} символов (${value.length})`, null, proposed);
        }
        break;
      }
      case 'integer':
      case 'number': {
        if (typeof value !== 'number' || !Number.isFinite(value) || (type === 'integer' && !Number.isInteger(value))) {
          const asStr = typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value);
          this.#err(st, path, 'SCHEMA', 'FAIL', 'type',
            `ожидается ${TYPE_RU[type]}, пришло: ${typeOfRu(value)} ${showVal(value)}` + (asStr ? ' — число передано строкой' : ''), null, proposed);
          return;
        }
        if (typeof schema.minimum === 'number' && value < schema.minimum) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'minimum', `значение ${value} меньше ${schema.minimum}`, null, proposed);
        }
        if (typeof schema.maximum === 'number' && value > schema.maximum) {
          this.#err(st, path, 'SCHEMA', 'FAIL', 'maximum', `значение ${value} больше ${schema.maximum}`, null, proposed);
        }
        break;
      }
      case 'boolean': {
        if (typeof value !== 'boolean') {
          const hint = (value === 'true' || value === 'false' || value === 'Да' || value === 'Нет') ? ' — логическое значение передано строкой' : '';
          this.#err(st, path, 'SCHEMA', 'FAIL', 'type', `ожидается true или false, пришло: ${typeOfRu(value)} ${showVal(value)}${hint}`, null, proposed);
          return;
        }
        break;
      }
      default:
        break;
    }
    this.#posRules(value, schema, path, st, ctx);
  }

  #posRules(value, schema, path, st) {
    const acc = schema['x-pos-accepted-values'];
    if (Array.isArray(acc) && value !== null && value !== undefined && !acc.includes(value)) {
      this.#err(st, path, 'POS', 'WARN', 'pos-accepted',
        `POS не применит элемент: значение ${showVal(value)}, POS принимает только ${acc.join(', ')}`, null);
    }
    if (schema['x-pos-required'] === true && (value === null || value === '' || value === undefined)) {
      this.#err(st, path, 'POS', 'WARN', 'pos-required', 'POS не применит элемент: значение пустое, а POS без него элемент не загрузит', null);
    }
    const ap = schema['x-pos-accepted-pattern'];
    if (ap && typeof value === 'string' && !safeTest(ap, value)) {
      const isInn = ap === '^\\d{14}$';
      this.#err(st, path, 'POS', 'WARN', 'pos-pattern',
        isInn ? 'POS не применит ИНН: нужно ровно 14 цифр' : 'POS не применит значение: не подходит под правило приёма POS', null);
    }
  }

  #patternError(value, fmt, path, st, proposed) {
    switch (fmt) {
      case 'guid': {
        if (/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value)) {
          this.#err(st, path, 'E4', 'FAIL', 'guid-upper', `ссылка в верхнем регистре: ${showVal(value)} — нужен GUID в нижнем регистре`, HINTS.guid);
        } else if (/^\{.*\}$/.test(value)) {
          this.#err(st, path, 'E4', 'FAIL', 'guid-braces', `ссылка не GUID из 36 символов: ${showVal(value)} — без фигурных скобок`, HINTS.guid);
        } else {
          this.#err(st, path, 'E4', 'FAIL', 'guid-format', `ссылка не GUID из 36 символов: ${showVal(value)} — похоже на код или представление, нужен УникальныйИдентификатор()`, HINTS.guid);
        }
        return;
      }
      case 'money':
      case 'percent': {
        const what = fmt === 'percent' ? 'процент' : 'деньги';
        let why = `${what} не в формате "1234.50" (строка, точка, два знака)`;
        if (/,/.test(value)) why += ' — запятая вместо точки';
        else if (/\s| /.test(value)) why += ' — пробелы между разрядами';
        else if (/^-?\d+$/.test(value)) why += ' — нет копеек';
        else if (/^-?\d+\.\d$/.test(value)) why += ' — один знак после точки';
        this.#err(st, path, 'E5', 'FAIL', 'money-format', `${why}: ${showVal(value)}`, HINTS[fmt]);
        return;
      }
      case 'quantity':
        this.#err(st, path, 'E5', 'FAIL', 'qty-format', `количество — три знака после точки, например "2.000": пришло ${showVal(value)}`, HINTS.quantity);
        return;
      case 'datetime':
      case 'dateOrDatetime': {
        let why;
        if (/T\d{2}:\d{2}:\d{2}\.\d+/.test(value)) why = 'дата с долями секунды — нужно без долей секунды';
        else if (/Z$/i.test(value)) why = 'дата в UTC (с Z) — нужно время Бишкека со смещением +06:00';
        else if (/T\d{2}:\d{2}:\d{2}$/.test(value)) why = 'дата без смещения +06:00';
        else if (/T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/.test(value)) why = `дата со смещением ${value.slice(-6)} — нужно +06:00 (Бишкек)`;
        else if (/^\d{2}\.\d{2}\.\d{4}/.test(value)) why = 'дата в виде ДД.ММ.ГГГГ — нужно ГГГГ-ММ-ДДTчч:мм:сс+06:00';
        else why = 'дата не в формате ГГГГ-ММ-ДДTчч:мм:сс+06:00';
        this.#err(st, path, 'E5', 'FAIL', 'date-format', `${why}: ${showVal(value)}`, HINTS.datetime);
        return;
      }
      case 'phone':
        this.#err(st, path, 'E5', 'FAIL', 'phone-format', `телефон не в формате +996XXXXXXXXX: ${showVal(value, 'phone')}`, HINTS.phone);
        return;
      case 'currency':
        this.#err(st, path, 'E5', 'FAIL', 'currency-format', `валюта — три заглавные латинские буквы (KGS): ${showVal(value)}`, HINTS.currency);
        return;
      case 'onecType':
        this.#err(st, path, 'SCHEMA', 'FAIL', 'onec-type', `тип объекта 1С должен быть вида Document_Имя или Catalog_Имя: ${showVal(value)}`, null, proposed);
        return;
      case 'posUserCode':
        this.#err(st, path, 'SCHEMA', 'FAIL', 'pos-user', `код пользователя POS — system или GUID: ${showVal(value)}`, null, proposed);
        return;
      default:
        this.#err(st, path, 'SCHEMA', 'FAIL', 'pattern', `значение ${showVal(value)} не подходит под шаблон контракта`, null, proposed);
    }
  }
}

const reCache = new Map();
function safeTest(pattern, value) {
  let re = reCache.get(pattern);
  if (!re) {
    try { re = new RegExp(pattern, 'u'); } catch { re = new RegExp(pattern); }
    reCache.set(pattern, re);
  }
  return re.test(value);
}
