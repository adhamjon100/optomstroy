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
 * Каталог прав из contracts/rbac/permissions.yaml (через permissions.generated.ts). Deny by default:
 * неизвестная роль, зарезервированный код (R2) или код без строки в grants — права нет.
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

  /** Эффективные права субъекта: объединение grants его ролей; статус pending_activation — псевдо-набор (11 §4.2). */
  effectivePermissions(principal: Pick<Principal, 'roles' | 'status'>): ReadonlySet<PermissionCode> {
    if (principal.status === 'pending_activation') return new Set(PSEUDO_SETS.pending_activation ?? []);
    const out = new Set<PermissionCode>();
    for (const role of principal.roles) {
      const granted = this.byRole.get(role as RbacRole);
      if (granted) for (const c of granted) out.add(c);
    }
    return out;
  }

  /** Ограничители ячейки (own, maxPercentFrom) для пары роль × право; проверяет сервис-владелец (11 §4.1 п. 5). */
  constraintsFor(role: string, code: PermissionCode): Readonly<Record<string, unknown>> | undefined {
    if (!(RBAC_ROLES as readonly string[]).includes(role)) return undefined;
    return ROLE_CONSTRAINTS[role as RbacRole][code];
  }
}
