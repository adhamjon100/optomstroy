import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse as parseYaml } from 'yaml';

/**
 * Проверка ответа по схеме контракта contracts/openapi/pos-api.v1.yaml (замена `jest-openapi` из критерия
 * RM-D-015 п. 1 — зависимость в package.json не добавляется). Поддерживается подмножество OpenAPI 3.0, которым
 * описаны DTO: `$ref`, `allOf`, `type`, `required`, `properties`, `items`, `enum`, `pattern`, `format`
 * (uuid, date-time), `nullable`, `minimum`. Режим `strict` — свойства вне схемы считаются ошибкой
 * («поля, не разрешённые роли, отсутствуют», 08 §3.7; API-157 «ровно перечисленные поля»).
 */
type Schema = Record<string, unknown>;

let doc: { components: { schemas: Record<string, Schema> } } | undefined;

export function contract(): { components: { schemas: Record<string, Schema> } } {
  doc ??= parseYaml(
    readFileSync(fileURLToPath(new URL('../../../../contracts/openapi/pos-api.v1.yaml', import.meta.url)), 'utf8'),
  ) as { components: { schemas: Record<string, Schema> } };
  return doc;
}

export function schemaOf(name: string): Schema {
  const s = contract().components.schemas[name];
  if (!s) throw new Error(`нет схемы ${name}`);
  return s;
}

function deref(s: Schema): Schema {
  let cur = s;
  for (let i = 0; i < 20 && typeof cur.$ref === 'string'; i++) {
    const name = cur.$ref.replace('#/components/schemas/', '');
    cur = { ...schemaOf(name), ...Object.fromEntries(Object.entries(cur).filter(([k]) => k !== '$ref')) };
  }
  return cur;
}

/** Все свойства схемы с учётом `allOf` (для строгой проверки «лишних» полей). */
function collectProps(s: Schema): Map<string, Schema> {
  const d = deref(s);
  const out = new Map<string, Schema>();
  for (const part of (d.allOf as Schema[] | undefined) ?? []) for (const [k, v] of collectProps(part)) out.set(k, v);
  for (const [k, v] of Object.entries((d.properties as Record<string, Schema> | undefined) ?? {})) out.set(k, v);
  return out;
}

function collectRequired(s: Schema): Set<string> {
  const d = deref(s);
  const out = new Set<string>((d.required as string[] | undefined) ?? []);
  for (const part of (d.allOf as Schema[] | undefined) ?? []) for (const r of collectRequired(part)) out.add(r);
  return out;
}

function isNullable(s: Schema): boolean {
  const d = deref(s);
  if (d.nullable === true) return true;
  return ((d.allOf as Schema[] | undefined) ?? []).some((p) => deref(p).nullable === true);
}

function typeOf(s: Schema): string | undefined {
  const d = deref(s);
  if (typeof d.type === 'string') return d.type;
  for (const p of (d.allOf as Schema[] | undefined) ?? []) {
    const t = typeOf(p);
    if (t) return t;
  }
  if (d.properties || d.allOf) return 'object';
  return undefined;
}

function constraintsOf(s: Schema): Schema[] {
  const d = deref(s);
  return [d, ...((d.allOf as Schema[] | undefined) ?? []).flatMap((p) => constraintsOf(p))];
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function validateAgainst(schema: Schema | string, value: unknown, strict = true, path = '$'): string[] {
  const s = typeof schema === 'string' ? schemaOf(schema) : schema;
  const errors: string[] = [];
  if (value === null) {
    if (!isNullable(s)) errors.push(`${path}: null не разрешён`);
    return errors;
  }
  const t = typeOf(s);
  for (const c of constraintsOf(s)) {
    if (Array.isArray(c.enum) && !c.enum.includes(value)) errors.push(`${path}: ${JSON.stringify(value)} вне enum`);
    if (typeof c.pattern === 'string' && typeof value === 'string' && !new RegExp(c.pattern).test(value)) {
      errors.push(`${path}: не соответствует pattern ${c.pattern}`);
    }
    if (c.format === 'uuid' && typeof value === 'string' && !UUID.test(value)) errors.push(`${path}: не uuid`);
    if (c.format === 'date-time' && typeof value === 'string' && Number.isNaN(Date.parse(value))) {
      errors.push(`${path}: не date-time`);
    }
    if (typeof c.minimum === 'number' && typeof value === 'number' && value < c.minimum) {
      errors.push(`${path}: < minimum`);
    }
  }
  switch (t) {
    case 'object': {
      if (typeof value !== 'object' || Array.isArray(value)) return [...errors, `${path}: ожидается объект`];
      const props = collectProps(s);
      for (const r of collectRequired(s)) if (!(r in value)) errors.push(`${path}.${r}: обязательное поле отсутствует`);
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
        const ps = props.get(k);
        if (!ps) {
          if (strict && props.size > 0) errors.push(`${path}.${k}: поле вне схемы`);
          continue;
        }
        errors.push(...validateAgainst(ps, v, strict, `${path}.${k}`));
      }
      break;
    }
    case 'array': {
      if (!Array.isArray(value)) return [...errors, `${path}: ожидается массив`];
      const items = constraintsOf(s).find((c) => c.items)?.items as Schema | undefined;
      if (items) value.forEach((v, i) => errors.push(...validateAgainst(items, v, strict, `${path}[${i}]`)));
      break;
    }
    case 'string':
      if (typeof value !== 'string') errors.push(`${path}: ожидается строка`);
      break;
    case 'integer':
      if (!Number.isInteger(value)) errors.push(`${path}: ожидается integer`);
      break;
    case 'number':
      if (typeof value !== 'number') errors.push(`${path}: ожидается number`);
      break;
    case 'boolean':
      if (typeof value !== 'boolean') errors.push(`${path}: ожидается boolean`);
      break;
    default:
      break;
  }
  return errors;
}

/** Ключи объекта на любой глубине (для тестов «нет финансовых полей»). */
export function deepKeys(value: unknown, acc: Set<string> = new Set()): Set<string> {
  if (Array.isArray(value)) for (const v of value) deepKeys(v, acc);
  else if (value !== null && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      acc.add(k);
      deepKeys(v, acc);
    }
  }
  return acc;
}
