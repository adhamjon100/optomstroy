/**
 * Вид субъекта сервера (06 ARCH-065; ADR-115 п. 2; 11 SEC-137 (6)): `staff` — сотрудник, `customer` — покупатель
 * режима клиента, `kiosk` — технический пользователь планшета магазина (`users.kind='kiosk'`, без телефона и PIN).
 * Значения = `users.kind` (07 §6.1, `contracts/enums.json` `user_kind`) = claim `kind` access-JWT (08 §2.2, 09 §8.1).
 *
 * Правило (P-002 §8.3): ветки «покупатель» и «сотрудник» не выводятся двоичной проверкой `kind === 'customer'` или
 * `kind === 'staff'` — иначе новый вид молча попадает в чужую ветку. Вид разбирается исчерпывающим `switch`
 * (`switchSubjectKind`, `bySubjectKind`, ветка `default` — `assertNeverSubjectKind`) или помощниками ниже;
 * значение вне перечня — исключение `UnknownSubjectKindError`: отказ по умолчанию (fail-closed), доступа нет.
 * Файл без зависимостей: его импортируют common/auth, src/users и модули D-06.
 */
export const SUBJECT_KINDS = ['staff', 'customer', 'kiosk'] as const;
export type SubjectKind = (typeof SUBJECT_KINDS)[number];

/** Вид субъекта вне `SUBJECT_KINDS`. Сообщение — без значения произвольного формата (логи — 11 SEC-062). */
export class UnknownSubjectKindError extends Error {
  override readonly name = 'UnknownSubjectKindError';
  constructor(value: unknown) {
    super(`неизвестный вид субъекта ${describeValue(value)}: отказ по умолчанию (06 ARCH-065)`);
  }
}

function describeValue(value: unknown): string {
  if (typeof value === 'string') return /^[a-z_]{1,32}$/.test(value) ? `«${value}»` : '(строка вне формата)';
  return value === null ? '(null)' : `(${typeof value})`;
}

export function isSubjectKind(value: unknown): value is SubjectKind {
  return typeof value === 'string' && (SUBJECT_KINDS as readonly string[]).includes(value);
}

/**
 * Классификатор значения извне системы типов (строка БД, claim, заголовок): вид из перечня — как есть, иначе
 * `UnknownSubjectKindError`. `integration` (служебный `Principal.kind` обмена с 1С) видом субъекта не является.
 */
export function toSubjectKind(value: unknown): SubjectKind {
  if (!isSubjectKind(value)) throw new UnknownSubjectKindError(value);
  return value;
}

/** Ветка `default` исчерпывающего `switch` по виду: компилятор требует все случаи, во время выполнения — исключение. */
export function assertNeverSubjectKind(value: never): never {
  throw new UnknownSubjectKindError(value);
}

/** Обработчики исчерпывающего разбора: каждый вид — свой случай (без ветки «иначе»). */
export interface SubjectKindCases<T> {
  readonly staff: () => T;
  readonly customer: () => T;
  readonly kiosk: () => T;
}

/** Исчерпывающий разбор вида с ленивыми ветками (ветка может бросить отказ, например `403` для `kiosk`). */
export function switchSubjectKind<T>(kind: SubjectKind, cases: SubjectKindCases<T>): T {
  switch (kind) {
    case 'staff':
      return cases.staff();
    case 'customer':
      return cases.customer();
    case 'kiosk':
      return cases.kiosk();
    default:
      return assertNeverSubjectKind(kind);
  }
}

/** Значение по виду из полной таблицы (сроки, лимиты): таблица без одного из видов не компилируется. */
export function bySubjectKind<T>(kind: SubjectKind, table: Readonly<Record<SubjectKind, T>>): T {
  return switchSubjectKind(kind, {
    staff: () => table.staff,
    customer: () => table.customer,
    kiosk: () => table.kiosk,
  });
}

/**
 * «Покупатель или планшет» — ограничительные ветки покупателя без подтверждённой привязки (11 SEC-137 (6)): без
 * скидок и долга, без выбора вида цены и клиента, наличие по `customer_stock_display`, без отложенных корзин.
 */
export function isBuyerLike(kind: SubjectKind): boolean {
  return switchSubjectKind(kind, { staff: () => false, customer: () => true, kiosk: () => true });
}

/**
 * «Только покупатель режима клиента» (`kind=customer`): флаг `CUSTOMER_SELF_SERVICE` и права на свои объекты
 * (привязка `customer_links`, «Мои заказы», свои долги). Планшет сюда не входит — его флаг `KIOSK_MODE` (06 ARCH-067).
 */
export function isSelfServiceCustomer(kind: SubjectKind): boolean {
  return switchSubjectKind(kind, { staff: () => false, customer: () => true, kiosk: () => false });
}

/**
 * Признак режима клиента (`isCustomer`) для модулей вне закрытого списка планшета магазина (08 §4.25: документы,
 * платежи, возвраты, журнал операций, скидки, долги): `staff` → `false`, `customer` → `true`; `kiosk` и значение вне
 * перечня (в том числе служебный `integration`) → `deny()` — отказ по умолчанию (06 ARCH-065): планшет до этих модулей
 * не доходит (закрытый список и права роли), а если дошёл, ветку сотрудника не получает.
 */
export function customerModeOrDeny(kind: unknown, deny: () => never): boolean {
  if (!isSubjectKind(kind)) return deny();
  return switchSubjectKind(kind, { staff: () => false, customer: () => true, kiosk: deny });
}
