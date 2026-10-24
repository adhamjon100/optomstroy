/**
 * Параметры SQL-запроса: значения пользователя попадают в текст запроса только как `$n` (SQL-инъекция невозможна
 * по построению — ни одно значение `q`, фильтров или курсора не конкатенируется в SQL).
 */
export class SqlParams {
  readonly values: unknown[] = [];

  /** Добавить значение и получить ссылку `$n` (с приведением типа, если задано). */
  add(value: unknown, cast?: string): string {
    this.values.push(value);
    return cast ? `$${this.values.length}::${cast}` : `$${this.values.length}`;
  }
}

/** Направление ключа сортировки. */
export type SortDir = 'asc' | 'desc';
/** Тип значения ключа в курсоре и приведение параметра в SQL. */
export type KeyKind = 'int' | 'numeric' | 'float4' | 'text' | 'uuid';

export interface SortKey {
  /** Столбец проекции (алиас во внешнем запросе). */
  readonly col: string;
  readonly dir: SortDir;
  readonly kind: KeyKind;
}

const CAST: Readonly<Record<KeyKind, string>> = {
  int: 'int',
  numeric: 'numeric',
  float4: 'float4',
  text: 'text',
  uuid: 'uuid',
};

/** `ORDER BY` по ключам (значения ключей не NULL — NULL-флаги вынесены в отдельный ключ `int`). */
export function orderBy(alias: string, keys: readonly SortKey[]): string {
  return keys.map((k) => `${alias}.${k.col} ${k.dir === 'asc' ? 'ASC' : 'DESC'}`).join(', ');
}

/**
 * Keyset-условие «строго после позиции» для набора ключей со смешанными направлениями (08 §2.5):
 * `(k1 > v1) OR (k1 = v1 AND k2 > v2) OR …`. Значения ключей не должны быть NULL (вызывающий кладёт coalesce).
 */
export function keysetAfter(
  alias: string,
  keys: readonly SortKey[],
  values: readonly (string | number)[],
  p: SqlParams,
): string {
  if (values.length !== keys.length) throw new Error('keysetAfter: число значений не совпадает с ключами');
  const refs = keys.map((k, i) => p.add(values[i], CAST[k.kind]));
  const ors: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const eqs = keys.slice(0, i).map((k, j) => `${alias}.${k.col} = ${refs[j]}`);
    const k = keys[i];
    eqs.push(`${alias}.${k.col} ${k.dir === 'asc' ? '>' : '<'} ${refs[i]}`);
    ors.push(`(${eqs.join(' AND ')})`);
  }
  return `(${ors.join(' OR ')})`;
}
