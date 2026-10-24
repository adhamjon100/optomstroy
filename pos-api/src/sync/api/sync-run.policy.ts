import type { SyncEntity } from '../../common/enums.js';
import type { PermissionCode } from '../../common/rbac/permissions.generated.js';

/** Режимы, принимаемые в теле `POST /sync/runs` (`manual` присваивает сервер, 08 §4.17.2). */
export const MANUAL_RUN_MODES = ['incremental', 'full', 'reconcile'] as const;
export type ManualRunMode = (typeof MANUAL_RUN_MODES)[number];

/** Сущности «быстрого» инкремента без step-up (R0 §17.2 «SCR-43 / синхронизация»; 11 №42). */
export const LIMITED_RUN_ENTITIES: readonly SyncEntity[] = ['stock', 'prices', 'order_status'];

export interface ManualRunRule {
  /** Право 11 §4.3, которое требуется для запуска. */
  readonly permission: Extract<PermissionCode, 'sync.run.incremental.limited' | 'sync.run.full'>;
  /** Нужен `X-Step-Up-Token` операции `sync.run.full` (11 №42a). */
  readonly stepUp: boolean;
}

/**
 * Правило ручного запуска (R0 §17.2; 08 §4.17.2; 05 SYNC-025; 11 №42, №42a): `incremental` для `stock`, `prices`,
 * `order_status` — `sync.run.incremental.limited` (`senior_seller`, `admin`, `owner`) без step-up; **любой иной**
 * запуск (`full`, `reconcile`, либо сущность вне трёх, в т. ч. `incremental` для `customers`) — `sync.run.full`
 * (`admin`, `owner`) со step-up.
 */
export function manualRunRule(entity: SyncEntity, mode: ManualRunMode): ManualRunRule {
  if (mode === 'incremental' && LIMITED_RUN_ENTITIES.includes(entity)) {
    return { permission: 'sync.run.incremental.limited', stepUp: false };
  }
  return { permission: 'sync.run.full', stepUp: true };
}
