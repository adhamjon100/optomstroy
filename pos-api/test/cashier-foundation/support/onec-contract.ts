import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';

/**
 * Минимальная проверка значения по схеме `contracts/onec/onec-http-service.v1.yaml` (подмножество OpenAPI 3:
 * `$ref`, `oneOf` + `discriminator.mapping`, `type`, `required`, `properties`, `items`, `enum`, `pattern`,
 * `nullable`, `minimum`, `minItems`). `additionalProperties` не проверяется: ONEC-058 — неизвестные поля
 * потребитель игнорирует (поля-предложения фейка, GQ-FND-03…05, допустимы). Только для тестов.
 */
const CONTRACT = fileURLToPath(new URL('../../../../contracts/onec/onec-http-service.v1.yaml', import.meta.url));

type Schema = Record<string, unknown>;

let cached: Record<string, Schema> | undefined;

function schemas(): Record<string, Schema> {
  if (!cached) {
    const doc = YAML.parse(readFileSync(CONTRACT, 'utf8')) as { components: { schemas: Record<string, Schema> } };
    cached = doc.components.schemas;
  }
  return cached;
}

function resolve(s: Schema): Schema {
  const ref = s.$ref;
  if (typeof ref !== 'string') return s;
  const name = ref.split('/').pop()!;
  const target = schemas()[name];
  if (!target) throw new Error(`нет схемы ${name}`);
  return resolve(target);
}

function typeOf(v: unknown): string {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v;
}

function check(value: unknown, schema: Schema, path: string, errors: string[]): void {
  const s = resolve(schema);
  if (value === null) {
    if (s.nullable !== true && !(Array.isArray(s.oneOf) && s.nullable)) errors.push(`${path}: null не допускается`);
    return;
  }
  if (Array.isArray(s.oneOf)) {
    const disc = s.discriminator as { propertyName: string; mapping?: Record<string, string> } | undefined;
    if (disc && typeof value === 'object' && value !== null) {
      const key = (value as Record<string, unknown>)[disc.propertyName];
      const target = typeof key === 'string' ? disc.mapping?.[key] : undefined;
      if (!target) {
        errors.push(`${path}.${disc.propertyName}: значение ${String(key)} не в discriminator.mapping`);
        return;
      }
      check(value, { $ref: target }, path, errors);
      return;
    }
    const ok = (s.oneOf as Schema[]).some((alt) => {
      const e: string[] = [];
      check(value, alt, path, e);
      return e.length === 0;
    });
    if (!ok) errors.push(`${path}: не подходит ни одна альтернатива oneOf`);
    return;
  }
  if (Array.isArray(s.allOf)) {
    for (const part of s.allOf as Schema[]) check(value, part, path, errors);
  }
  const t = s.type as string | undefined;
  const actual = typeOf(value);
  if (t && !(t === actual || (t === 'number' && actual === 'integer'))) {
    errors.push(`${path}: тип ${actual}, ожидался ${t}`);
    return;
  }
  if (Array.isArray(s.enum) && !(s.enum as unknown[]).includes(value)) {
    errors.push(`${path}: ${JSON.stringify(value)} не в enum`);
  }
  if (typeof s.pattern === 'string' && typeof value === 'string' && !new RegExp(s.pattern).test(value)) {
    errors.push(`${path}: "${value}" не соответствует ${s.pattern}`);
  }
  if (typeof s.minimum === 'number' && typeof value === 'number' && value < s.minimum) {
    errors.push(`${path}: ${value} < ${s.minimum}`);
  }
  if (actual === 'array') {
    const arr = value as unknown[];
    if (typeof s.minItems === 'number' && arr.length < s.minItems) errors.push(`${path}: элементов < ${s.minItems}`);
    if (s.items) arr.forEach((x, i) => check(x, s.items as Schema, `${path}[${i}]`, errors));
  }
  if (actual === 'object') {
    const obj = value as Record<string, unknown>;
    for (const r of (s.required as string[] | undefined) ?? []) {
      if (!(r in obj)) errors.push(`${path}.${r}: обязательное поле отсутствует`);
    }
    const props = (s.properties as Record<string, Schema> | undefined) ?? {};
    for (const [k, ps] of Object.entries(props)) if (k in obj) check(obj[k], ps, `${path}.${k}`, errors);
  }
}

/** Ошибки соответствия значения схеме `components.schemas.<name>` (пусто — соответствует). */
export function contractErrors(name: string, value: unknown): string[] {
  const errors: string[] = [];
  check(value, { $ref: `#/components/schemas/${name}` }, name, errors);
  return errors;
}
