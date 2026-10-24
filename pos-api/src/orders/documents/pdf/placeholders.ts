/**
 * Подстановки шаблона печатной формы: `{{путь.к.полю}}` → строка из модели документа. Области видимости
 * просматриваются по порядку (элемент массива `each`/`table`, затем корень). Отсутствующее значение → пустая строка.
 * Логики (условий, циклов, выражений) в строках нет — только подстановка; условия — поле `when` блока.
 */
export type Scope = Readonly<Record<string, unknown>>;

const PLACEHOLDER_RE = /\{\{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\}\}/g;

function lookup(path: string, scope: Scope): { found: boolean; value: unknown } {
  let cur: unknown = scope;
  for (const part of path.split('.')) {
    if (cur === null || typeof cur !== 'object' || !(part in (cur as Record<string, unknown>))) {
      return { found: false, value: undefined };
    }
    cur = (cur as Record<string, unknown>)[part];
  }
  return { found: true, value: cur };
}

export function resolvePath(path: string, scopes: readonly Scope[]): unknown {
  for (const s of scopes) {
    const r = lookup(path, s);
    if (r.found) return r.value;
  }
  return undefined;
}

function asText(v: unknown): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'bigint') return String(v);
  return '';
}

export function fill(template: string, scopes: readonly Scope[]): string {
  return template.replace(PLACEHOLDER_RE, (_m, path: string) => asText(resolvePath(path, scopes)));
}

/** Истинность условия `when`: непустая строка, `true`, непустой массив, ненулевое число. */
export function truthy(path: string | undefined, scopes: readonly Scope[]): boolean {
  if (path === undefined) return true;
  const v = resolvePath(path, scopes);
  if (Array.isArray(v)) return v.length > 0;
  if (typeof v === 'string') return v.trim() !== '';
  if (typeof v === 'number') return v !== 0;
  return v === true;
}
