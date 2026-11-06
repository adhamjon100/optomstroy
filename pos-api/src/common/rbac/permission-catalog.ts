import { Injectable } from '@nestjs/common';
import type { Principal } from '../http/request-context.js';
import {
  PERMISSION_CODES,
  type PermissionCode,
  PERMISSIONS,
  type PermissionMeta,
  PSEUDO_SETS,
  RBAC_ROLES,
  type RbacRole,
  ROLE_CONSTRAINTS,
  ROLE_GRANTS,
} from './permissions.generated.js';

/**
 * Права, привязанные к виду субъекта (11 SEC-138; ADR-115): код засчитывается, только если `kind` субъекта равен
 * указанному здесь, — роль `kiosk` в токене сотрудника или покупателя этих кодов не даёт. Вид не передан (вызовы
 * `effectivePermissions({ roles })` построителей акторов, документов, платежей) — коды исключаются (отказ по
 * умолчанию). Перечень — коды №79–81 11 §4.3; `kiosk.read` и `kiosk.manage` к виду не привязаны.
 */
export const KIND_BOUND_PERMISSIONS = {
  'kiosk.order.submit': 'kiosk',
  'kiosk.self.read': 'kiosk',
  'kiosk.self.exit': 'kiosk',
} as const satisfies Partial<Record<PermissionCode, Principal['kind']>>;

const KIND_BOUND: readonly (readonly [PermissionCode, Principal['kind']])[] = Object.entries(
  KIND_BOUND_PERMISSIONS,
) as [PermissionCode, Principal['kind']][];

/** Субъект для расчёта прав: роли и статус; `kind` — для кодов, привязанных к виду (без него они не засчитываются). */
export type PermissionSubject = Pick<Principal, 'roles' | 'status'> & { readonly kind?: Principal['kind'] };

/**
 * Каталог прав из contracts/rbac/permissions.yaml (через permissions.generated.ts). Deny by default:
 * неизвестная роль, зарезервированный код (R2) или код без строки в grants — права нет; код из
 * `KIND_BOUND_PERMISSIONS` — только при своём виде субъекта.
 * Источник истины в рантайме этапа D — таблицы roles/role_permissions (seed 0002 из того же YAML);
 * этот каталог — fallback и эталон для теста сверки.
 */
@Injectable()
export class PermissionCatalog {
  private readonly meta = new Map<PermissionCode, PermissionMeta>(PERMISSIONS.map((p) => [p.code, p]));
  private readonly byRole = new Map<RbacRole, ReadonlySet<PermissionCode>>(
    RBAC_ROLES.map((r) => [r, new Set(ROLE_GRANTS[r].filter((c) => !this.meta.get(c)?.reserved))]),
  );

  isKnown(code: string): code is PermissionCode {
    return (PERMISSION_CODES as readonly string[]).includes(code);
  }

  metaOf(code: PermissionCode): PermissionMeta | undefined {
    return this.meta.get(code);
  }

  /**
   * Эффективные права субъекта: объединение grants его ролей; статус pending_activation — псевдо-набор (11 §4.2);
   * коды, привязанные к виду (`KIND_BOUND_PERMISSIONS`, SEC-138), — только при совпадающем `kind`.
   */
  effectivePermissions(principal: PermissionSubject): ReadonlySet<PermissionCode> {
    const out = new Set<PermissionCode>();
    if (principal.status === 'pending_activation') {
      for (const c of PSEUDO_SETS.pending_activation ?? []) out.add(c);
    } else {
      for (const role of principal.roles) {
        const granted = this.byRole.get(role as RbacRole);
        if (granted) for (const c of granted) out.add(c);
      }
    }
    for (const [code, kind] of KIND_BOUND) if (principal.kind !== kind) out.delete(code);
    return out;
  }

  /** Ограничители ячейки (own, maxPercentFrom) для пары роль × право; проверяет сервис-владелец (11 §4.1 п. 5). */
  constraintsFor(role: string, code: PermissionCode): Readonly<Record<string, unknown>> | undefined {
    if (!(RBAC_ROLES as readonly string[]).includes(role)) return undefined;
    return ROLE_CONSTRAINTS[role as RbacRole][code];
  }
}
