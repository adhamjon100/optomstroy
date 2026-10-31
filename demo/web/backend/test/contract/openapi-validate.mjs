// Проверка ответов демо-бэкенда по контракту contracts/openapi/pos-api.v1.yaml (WP-T1; plan §4 WP-T1, §5 п. 4).
// Порт семантики pos-api/test/settings/support/openapi-check.ts ($ref, allOf, type, required, properties, items,
// enum, pattern, format uuid/date-time, nullable, minimum; строгий режим — поля вне схемы считаются ошибкой) и
// дополнения: oneOf, anyOf, discriminator, additionalProperties, minLength/maxLength, minItems/maxItems,
// maximum/exclusive*, multipleOf, format date/uri/int32/email, uniqueItems.
//
// Запрос сопоставляется с операцией по шаблону пути (литеральные сегменты важнее параметров). Ответ:
//   2xx — схема ответа операции (JSON), для application/pdf — Content-Type и сигнатура %PDF, для text/csv — тип;
//   4xx/5xx — всегда application/problem+json по схеме Problem; code ∈ ProblemCode, HTTP-статус ∈ допустимых
//   статусов кода по contracts/enums.json (problemCodes[].http), поле status = HTTP-статус;
//   204/304 — пустое тело.
// Статус, которого нет в responses операции (кроме покрытого `default`), — предупреждение, не ошибка.
//
// Без зависимостей, кроме pos-api/node_modules/yaml (уже установлен).
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = resolve(HERE, '../../../../..').replace(/\\/g, '/');
export const OPENAPI_FILE = `${ROOT}/contracts/openapi/pos-api.v1.yaml`;
export const ENUMS_FILE = `${ROOT}/contracts/enums.json`;
const API_PREFIX = '/api/v1';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_TIME = /^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const EMAIL = /^[^\s@]+@[^\s@]+$/;

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const jsonType = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);

export class Contract {
  /** @param {{ doc?: object, enums?: object, strict?: boolean }} o */
  constructor({ doc, enums, strict = true } = {}) {
    if (!doc) {
      const YAML = createRequire(`${ROOT}/pos-api/package.json`)('yaml');
      doc = YAML.parse(readFileSync(OPENAPI_FILE, 'utf8'));
    }
    if (enums === undefined) enums = JSON.parse(readFileSync(ENUMS_FILE, 'utf8'));
    this.doc = doc;
    this.enums = enums;
    this.strict = strict;
    this.problemHttp = new Map((enums?.problemCodes ?? []).map((p) => [p.code, p.http]));
    this.ops = [];
    for (const [template, item] of Object.entries(doc.paths ?? {})) {
      for (const [m, op] of Object.entries(item)) {
        if (!['get', 'post', 'put', 'patch', 'delete', 'head', 'options'].includes(m)) continue;
        const segs = template.split('/').filter(Boolean);
        const literal = segs.filter((s) => !s.includes('{')).length;
        const segRe = (s) =>
          s
            .split(/(\{[^}]+\})/)
            .map((part) => (/^\{[^}]+\}$/.test(part) ? '[^/]+' : part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
            .join('');
        const re = new RegExp('^/' + segs.map(segRe).join('/') + '/?$');
        this.ops.push({ method: m.toUpperCase(), template, operationId: op.operationId, op, re, literal, segs: segs.length });
      }
    }
    // литеральные сегменты важнее: /catalog/products/recent раньше /catalog/products/{id}
    this.ops.sort((a, b) => b.literal - a.literal || b.segs - a.segs);
  }

  schemaByName(name) {
    const s = this.doc.components?.schemas?.[name];
    if (!s) throw new Error(`openapi: нет схемы ${name}`);
    return s;
  }

  /** Разыменовать $ref (#/components/<kind>/<name>), сохранив соседние ключи (nullable и т. п.). */
  deref(s) {
    let cur = s;
    for (let i = 0; i < 32 && cur && typeof cur.$ref === 'string'; i++) {
      const m = /^#\/components\/([^/]+)\/(.+)$/.exec(cur.$ref);
      if (!m) throw new Error(`openapi: неподдерживаемый $ref ${cur.$ref}`);
      const target = this.doc.components?.[m[1]]?.[decodeURIComponent(m[2])];
      if (!target) throw new Error(`openapi: нет ${cur.$ref}`);
      const rest = Object.fromEntries(Object.entries(cur).filter(([k]) => k !== '$ref'));
      cur = { ...target, ...rest };
    }
    return cur;
  }

  /** Операция по методу и URL запроса (с /api/v1 или без; /health — без префикса). */
  matchOperation(method, url) {
    let p = String(url).split('?')[0].split('#')[0];
    if (p.startsWith(API_PREFIX + '/')) p = p.slice(API_PREFIX.length);
    const M = String(method).toUpperCase();
    for (const o of this.ops) if (o.method === M && o.re.test(p)) return o;
    return null;
  }

  // ------------------------------------------------------------------ схема
  /** Свойства объекта с учётом allOf (для строгой проверки «лишних» полей). */
  collectProps(s, out = new Map(), seen = new Set()) {
    const d = this.deref(s);
    if (seen.has(d)) return out;
    seen.add(d);
    for (const part of d.allOf ?? []) this.collectProps(part, out, seen);
    for (const [k, v] of Object.entries(d.properties ?? {})) if (!out.has(k)) out.set(k, v);
    return out;
  }
  collectRequired(s, out = new Set()) {
    const d = this.deref(s);
    for (const r of d.required ?? []) out.add(r);
    for (const part of d.allOf ?? []) this.collectRequired(part, out);
    return out;
  }
  /** additionalProperties: undefined | boolean | schema (первое заданное в s и его allOf). */
  additionalOf(s) {
    const d = this.deref(s);
    if (d.additionalProperties !== undefined) return d.additionalProperties;
    for (const part of d.allOf ?? []) {
      const a = this.additionalOf(part);
      if (a !== undefined) return a;
    }
    return undefined;
  }
  /** Имена свойств, объявленные ветвями oneOf/anyOf (во вложенных allOf тоже) — их не считать «лишними» снаружи. */
  branchProps(s, out = new Set()) {
    const d = this.deref(s);
    for (const b of [...(d.oneOf ?? []), ...(d.anyOf ?? [])]) for (const k of this.collectProps(b).keys()) out.add(k);
    for (const part of d.allOf ?? []) this.branchProps(part, out);
    return out;
  }
  isNullable(s) {
    const d = this.deref(s);
    if (d.nullable === true) return true;
    if (Array.isArray(d.enum) && d.enum.includes(null)) return true;
    if ((d.allOf ?? []).some((p) => this.isNullable(p))) return true;
    if ((d.oneOf ?? []).some((p) => this.isNullable(p)) || (d.anyOf ?? []).some((p) => this.isNullable(p))) return true;
    return false;
  }
  typeOf(s) {
    const d = this.deref(s);
    if (typeof d.type === 'string') return d.type;
    for (const p of d.allOf ?? []) {
      const t = this.typeOf(p);
      if (t) return t;
    }
    if (d.properties || d.additionalProperties !== undefined) return 'object';
    if (d.items) return 'array';
    return undefined;
  }
  /** Схема и её allOf-части плоским списком (ограничения применяются все). */
  constraintsOf(s, out = []) {
    const d = this.deref(s);
    out.push(d);
    for (const p of d.allOf ?? []) this.constraintsOf(p, out);
    return out;
  }

  /**
   * Проверить значение по схеме. → массив строк ошибок.
   * ctx.strict — поля вне схемы считаются ошибкой (если у объекта есть объявленные свойства и additionalProperties
   * не задан); ctx.allowExtra — имена, разрешённые внешней схемой (ветви oneOf внутри allOf).
   */
  validate(schema, value, { strict = this.strict, path = '$', allowExtra = null } = {}) {
    const s = typeof schema === 'string' ? this.schemaByName(schema) : schema;
    const errors = [];
    if (value === undefined) return errors;
    if (value === null) {
      if (!this.isNullable(s)) errors.push(`${path}: null не разрешён`);
      return errors;
    }
    const t = this.typeOf(s);
    for (const c of this.constraintsOf(s)) {
      if (Array.isArray(c.enum) && !c.enum.includes(value)) errors.push(`${path}: ${JSON.stringify(value).slice(0, 80)} вне enum [${c.enum.slice(0, 12).join(', ')}${c.enum.length > 12 ? ', …' : ''}]`);
      if (typeof value === 'string') {
        if (typeof c.pattern === 'string' && !new RegExp(c.pattern, 'u').test(value)) errors.push(`${path}: ${JSON.stringify(value).slice(0, 60)} не соответствует pattern ${c.pattern}`);
        if (typeof c.minLength === 'number' && [...value].length < c.minLength) errors.push(`${path}: длина ${[...value].length} < minLength ${c.minLength}`);
        if (typeof c.maxLength === 'number' && [...value].length > c.maxLength) errors.push(`${path}: длина ${[...value].length} > maxLength ${c.maxLength}`);
        if (c.format === 'uuid' && !UUID.test(value)) errors.push(`${path}: ${JSON.stringify(value).slice(0, 60)} не uuid`);
        if (c.format === 'date-time' && (!DATE_TIME.test(value) || Number.isNaN(Date.parse(value)))) errors.push(`${path}: ${JSON.stringify(value).slice(0, 60)} не date-time (RFC 3339)`);
        if (c.format === 'date' && (!DATE.test(value) || Number.isNaN(Date.parse(value)))) errors.push(`${path}: ${JSON.stringify(value).slice(0, 60)} не date`);
        if (c.format === 'email' && !EMAIL.test(value)) errors.push(`${path}: не email`);
        if (c.format === 'uri') {
          try {
            new URL(value);
          } catch {
            errors.push(`${path}: ${JSON.stringify(value).slice(0, 60)} не uri`);
          }
        }
      }
      if (typeof value === 'number') {
        if (typeof c.minimum === 'number' && (c.exclusiveMinimum === true ? value <= c.minimum : value < c.minimum)) errors.push(`${path}: ${value} < minimum ${c.minimum}`);
        if (typeof c.maximum === 'number' && (c.exclusiveMaximum === true ? value >= c.maximum : value > c.maximum)) errors.push(`${path}: ${value} > maximum ${c.maximum}`);
        if (typeof c.exclusiveMinimum === 'number' && value <= c.exclusiveMinimum) errors.push(`${path}: ${value} ≤ exclusiveMinimum ${c.exclusiveMinimum}`);
        if (typeof c.exclusiveMaximum === 'number' && value >= c.exclusiveMaximum) errors.push(`${path}: ${value} ≥ exclusiveMaximum ${c.exclusiveMaximum}`);
        if (typeof c.multipleOf === 'number' && Math.abs(value / c.multipleOf - Math.round(value / c.multipleOf)) > 1e-9) errors.push(`${path}: ${value} не кратно ${c.multipleOf}`);
        if (c.format === 'int32' && (value < -2147483648 || value > 2147483647)) errors.push(`${path}: ${value} вне int32`);
      }
      if (Array.isArray(value)) {
        if (typeof c.minItems === 'number' && value.length < c.minItems) errors.push(`${path}: ${value.length} элементов < minItems ${c.minItems}`);
        if (typeof c.maxItems === 'number' && value.length > c.maxItems) errors.push(`${path}: ${value.length} элементов > maxItems ${c.maxItems}`);
        if (c.uniqueItems === true && new Set(value.map((x) => JSON.stringify(x))).size !== value.length) errors.push(`${path}: элементы не уникальны`);
      }
    }

    // oneOf / anyOf (на любом уровне allOf)
    const extraFromBranches = this.branchProps(s);
    const allowForBranches = new Set([...(allowExtra ?? []), ...this.collectProps(s).keys()]);
    for (const c of this.constraintsOf(s)) {
      if (c.oneOf) errors.push(...this.checkOneOf(c, value, { strict, path, allowExtra: allowForBranches }));
      if (c.anyOf) {
        const results = c.anyOf.map((b) => this.validate(b, value, { strict, path, allowExtra: allowForBranches }));
        if (!results.some((r) => r.length === 0)) errors.push(`${path}: не подходит ни одна ветвь anyOf (${results.map((r) => r[0] ?? '').join(' | ').slice(0, 400)})`);
      }
    }

    switch (t) {
      case 'object': {
        if (!isObj(value)) return [...errors, `${path}: ожидается объект, а не ${jsonType(value)}`];
        const props = this.collectProps(s);
        for (const r of this.collectRequired(s)) if (!(r in value)) errors.push(`${path}.${r}: обязательное поле отсутствует`);
        const ap = this.additionalOf(s);
        const d = this.deref(s);
        if (typeof d.minProperties === 'number' && Object.keys(value).length < d.minProperties) errors.push(`${path}: свойств меньше minProperties ${d.minProperties}`);
        if (typeof d.maxProperties === 'number' && Object.keys(value).length > d.maxProperties) errors.push(`${path}: свойств больше maxProperties ${d.maxProperties}`);
        for (const [k, v] of Object.entries(value)) {
          const ps = props.get(k);
          if (ps) {
            errors.push(...this.validate(ps, v, { strict, path: `${path}.${k}` }));
            continue;
          }
          if (extraFromBranches.has(k) || allowExtra?.has(k)) continue; // проверит ветвь oneOf/anyOf или внешняя схема
          if (ap === false) errors.push(`${path}.${k}: поле вне схемы (additionalProperties: false)`);
          else if (isObj(ap)) errors.push(...this.validate(ap, v, { strict, path: `${path}.${k}` }));
          else if (ap === undefined && strict && props.size > 0) errors.push(`${path}.${k}: поле вне схемы`);
        }
        break;
      }
      case 'array': {
        if (!Array.isArray(value)) return [...errors, `${path}: ожидается массив, а не ${jsonType(value)}`];
        const items = this.constraintsOf(s).find((c) => c.items)?.items;
        if (items) value.forEach((v, i) => errors.push(...this.validate(items, v, { strict, path: `${path}[${i}]` })));
        break;
      }
      case 'string':
        if (typeof value !== 'string') errors.push(`${path}: ожидается строка, а не ${jsonType(value)}`);
        break;
      case 'integer':
        if (!Number.isInteger(value)) errors.push(`${path}: ожидается integer, а не ${jsonType(value)} ${JSON.stringify(value).slice(0, 40)}`);
        break;
      case 'number':
        if (typeof value !== 'number' || !Number.isFinite(value)) errors.push(`${path}: ожидается number, а не ${jsonType(value)}`);
        break;
      case 'boolean':
        if (typeof value !== 'boolean') errors.push(`${path}: ожидается boolean, а не ${jsonType(value)}`);
        break;
      default:
        break;
    }
    return errors;
  }

  checkOneOf(c, value, ctx) {
    const branches = c.oneOf;
    const disc = c.discriminator;
    if (disc?.propertyName) {
      if (!isObj(value)) return [`${ctx.path}: oneOf с discriminator ожидает объект`];
      const tag = value[disc.propertyName];
      if (tag === undefined) return [`${ctx.path}.${disc.propertyName}: нет поля discriminator`];
      let target = disc.mapping?.[tag];
      if (!target) {
        // без mapping — имя схемы ветви = значение
        const b = branches.find((x) => typeof x.$ref === 'string' && x.$ref.endsWith(`/${tag}`));
        target = b?.$ref;
      }
      if (!target) {
        // ветвь, где свойство discriminator — enum с этим значением
        const b = branches.find((x) => {
          const p = this.collectProps(x).get(disc.propertyName);
          const d = p ? this.deref(p) : null;
          return d?.enum?.includes(tag);
        });
        if (b) return this.validate(b, value, ctx);
        return [`${ctx.path}.${disc.propertyName}: значение ${JSON.stringify(tag)} не сопоставлено ни одной ветви discriminator`];
      }
      return this.validate({ $ref: target }, value, ctx);
    }
    const results = branches.map((b) => this.validate(b, value, ctx));
    const ok = results.filter((r) => r.length === 0).length;
    if (ok === 1) return [];
    if (ok === 0) {
      const best = results.reduce((a, b) => (b.length < a.length ? b : a));
      return [`${ctx.path}: не подходит ни одна ветвь oneOf (ближайшая: ${best.slice(0, 3).join('; ').slice(0, 400)})`];
    }
    return [`${ctx.path}: подходит ${ok} ветвей oneOf (нужна ровно одна)`];
  }

  // ------------------------------------------------------------------ ответ
  responseSpec(op, status) {
    const rs = op.responses ?? {};
    const exact = rs[String(status)];
    if (exact) return { spec: this.deref(exact), key: String(status), declared: true };
    const range = rs[`${String(status)[0]}XX`];
    if (range) return { spec: this.deref(range), key: `${String(status)[0]}XX`, declared: true };
    if (rs.default) return { spec: this.deref(rs.default), key: 'default', declared: false };
    return { spec: null, key: null, declared: false };
  }

  /**
   * Проверить записанный ответ. rec: { method, url, status, headers: {k: v}, json, bytes?, magic?, size }.
   * → { operationId, template, errors: string[], warnings: string[], matched: boolean }
   */
  checkResponse(rec) {
    const out = { operationId: null, template: null, errors: [], warnings: [], matched: false };
    const o = this.matchOperation(rec.method, rec.url);
    if (!o) {
      out.errors.push(`операция не найдена в контракте: ${rec.method} ${String(rec.url).split('?')[0]}`);
      return out;
    }
    out.matched = true;
    out.operationId = o.operationId;
    out.template = o.template;
    const status = Number(rec.status);
    const ct = String(rec.headers?.['content-type'] ?? '').toLowerCase();
    const size = rec.size ?? rec.bytes?.length ?? 0;
    const { spec, key, declared } = this.responseSpec(o.op, status);
    if (!declared) out.warnings.push(`статус ${status} не объявлен в responses операции ${o.operationId}${key === 'default' ? ' (покрыт default)' : ''}`);

    if (status >= 400) {
      if (!ct.startsWith('application/problem+json')) out.errors.push(`${status}: Content-Type «${ct}» вместо application/problem+json`);
      if (!isObj(rec.json)) {
        out.errors.push(`${status}: тело не JSON-объект Problem`);
        return out;
      }
      out.errors.push(...this.validate('Problem', rec.json, { path: '$' }).map((e) => `Problem ${e}`));
      const code = rec.json.code;
      const allowed = this.problemHttp.get(code);
      if (!allowed) out.errors.push(`Problem: code ${JSON.stringify(code)} нет в contracts/enums.json problemCodes`);
      else if (!allowed.includes(status)) out.errors.push(`Problem: code ${code} с HTTP ${status}, а по contracts/enums.json — ${allowed.join('/')}`);
      if (rec.json.status !== undefined && rec.json.status !== status) out.errors.push(`Problem: поле status ${rec.json.status} ≠ HTTP ${status}`);
      return out;
    }
    if (status === 204 || status === 304) {
      if (size > 0) out.errors.push(`${status}: тело должно быть пустым (${size} байт)`);
      return out;
    }
    if (!spec) {
      out.errors.push(`${status}: нет описания ответа`);
      return out;
    }
    const content = spec.content ?? {};
    const types = Object.keys(content);
    if (!types.length) {
      if (size > 0) out.warnings.push(`${status}: тело ${size} байт, а контракт тела не описывает`);
      return out;
    }
    const mt = types.find((x) => ct.startsWith(x.toLowerCase())) ?? null;
    if (!mt) {
      out.errors.push(`${status}: Content-Type «${ct}» не из объявленных [${types.join(', ')}]`);
      return out;
    }
    if (mt === 'application/pdf') {
      if (rec.magic !== undefined && !String(rec.magic).startsWith('%PDF')) out.errors.push(`${status}: PDF без сигнатуры %PDF (${JSON.stringify(rec.magic)})`);
      if (!size) out.errors.push(`${status}: пустой PDF`);
      return out;
    }
    if (/json/.test(mt)) {
      const schema = content[mt]?.schema;
      if (rec.json === undefined) {
        out.errors.push(`${status}: тело не JSON`);
        return out;
      }
      if (schema) out.errors.push(...this.validate(schema, rec.json, { path: '$' }));
      return out;
    }
    // text/csv, image/webp и т. п. — достаточно типа и непустого тела
    if (!size) out.warnings.push(`${status}: пустое тело ${mt}`);
    return out;
  }
}

let shared;
/** Общий экземпляр (разбор YAML ~0,5 с). */
export function contract() {
  shared ??= new Contract();
  return shared;
}
