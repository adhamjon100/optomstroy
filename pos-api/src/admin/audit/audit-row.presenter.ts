import type { AuditRowView } from '../../common/ports/index.js';

/**
 * `AuditRow` (08 §4.18.7; OpenAPI `AuditRow`): `actor` — `UserRef` без телефона (08 §3.5) или `null` (система);
 * необязательные поля без значения (`requestId`, `actorRole`) не выводятся — в схеме они не `nullable`.
 */
export function presentAuditRow(r: AuditRowView): Record<string, unknown> {
  return {
    id: r.id,
    occurredAt: r.occurredAt.toISOString(),
    ...(r.requestId !== null ? { requestId: r.requestId } : {}),
    actor:
      r.actorUserId === null
        ? null
        : {
            id: r.actorUserId,
            displayName: r.actorName ?? 'Пользователь',
            ...(r.actorRole !== null ? { role: r.actorRole } : {}),
          },
    ...(r.actorRole !== null ? { actorRole: r.actorRole } : {}),
    sessionId: r.sessionId,
    deviceId: r.deviceId,
    ip: r.ip,
    appVersion: r.appVersion,
    action: r.action,
    entityType: r.entityType,
    entityId: r.entityId,
    onecRef: r.onecRef,
    before: r.before,
    after: r.after,
    result: r.result,
    stepUpMethod: r.stepUpMethod,
    reason: r.reason,
    rowHash: r.rowHash,
    chainOk: r.chainOk,
  };
}
