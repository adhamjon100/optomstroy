import { SetMetadata } from '@nestjs/common';
import type { PermissionCode } from './permissions.generated.js';

export const PUBLIC_ROUTE = 'optomstroy:public';
export const REQUIRED_PERMISSIONS = 'optomstroy:required-permissions';

export interface PermissionRequirement {
  readonly mode: 'all' | 'any';
  readonly codes: readonly PermissionCode[];
}

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
