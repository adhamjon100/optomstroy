import { SetMetadata } from '@nestjs/common';
import type { PermissionCode } from './permissions.generated.js';

export const PUBLIC_ROUTE = 'optomstroy:public';
export const REQUIRED_PERMISSIONS = 'optomstroy:required-permissions';

/** Группа альтернатив требования «И из ИЛИ»: достаточно одного права группы; пустая группа не допускается. */
export type PermissionGroup = readonly [PermissionCode, ...PermissionCode[]];

/**
 * Требование прав маршрута (metadata `REQUIRED_PERMISSIONS`; читают RbacGuard и e2e-матрица T-SEC-018):
 * - `all` — нужны все коды; `any` — достаточно одного;
 * - `cnf` — «И из ИЛИ» (конъюнктивная нормальная форма; ADR-115, 11 §4.3.1, SEC-138): каждая группа `groups`
 *   выполнена хотя бы одним своим правом, например `POST /cart/checkout-preview` — `cart.manage.own` **и** одно из
 *   `order.create` | `kiosk.order.submit`.
 * Все коды требования (для T-SEC-018 «коды маршрута ⊆ x-permissions» и журнала отказа) — `requirementCodes`.
 */
export type PermissionRequirement =
  | { readonly mode: 'all' | 'any'; readonly codes: readonly PermissionCode[] }
  | { readonly mode: 'cnf'; readonly groups: readonly (readonly PermissionCode[])[] };

/** Публичный маршрут без Bearer (08 §2.2 «Публичные эндпоинты», 11 SEC-013). */
export const Public = (): MethodDecorator & ClassDecorator => SetMetadata(PUBLIC_ROUTE, true);

/** Требуются все перечисленные права (deny by default: маршрут без политики → 403). */
export const RequirePermission = (code: PermissionCode, ...more: PermissionCode[]): MethodDecorator & ClassDecorator =>
  SetMetadata(REQUIRED_PERMISSIONS, { mode: 'all', codes: [code, ...more] } satisfies PermissionRequirement);

/** Достаточно любого из прав (например, `order.read.own` | `order.read.all`; ограничение own проверяет сервис). */
export const RequireAnyPermission = (
  code: PermissionCode,
  ...more: PermissionCode[]
): MethodDecorator & ClassDecorator =>
  SetMetadata(REQUIRED_PERMISSIONS, { mode: 'any', codes: [code, ...more] } satisfies PermissionRequirement);

/**
 * Требование «И из ИЛИ» (ADR-115; 11 SEC-138): каждая группа — хотя бы одно её право, например
 * `@RequirePermissionGroups(['cart.manage.own'], ['order.create', 'kiosk.order.submit'])`. Требование без групп или
 * с пустой группой — ошибка при объявлении класса (маршрут не регистрируется молча без политики).
 */
export const RequirePermissionGroups = (
  group: PermissionGroup,
  ...more: PermissionGroup[]
): MethodDecorator & ClassDecorator => {
  const groups = [group, ...more].map((g) => [...g]);
  if (groups.some((g) => g.length === 0)) {
    throw new Error('RequirePermissionGroups: пустая группа прав (требование «И из ИЛИ» невыполнимо)');
  }
  return SetMetadata(REQUIRED_PERMISSIONS, { mode: 'cnf', groups } satisfies PermissionRequirement);
};

/** Все коды требования в порядке объявления, без повторов (для `cnf` — объединение групп). */
export function requirementCodes(requirement: PermissionRequirement): readonly PermissionCode[] {
  const codes = requirement.mode === 'cnf' ? requirement.groups.flat() : requirement.codes;
  return [...new Set(codes)];
}
