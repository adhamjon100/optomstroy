import { Injectable, Logger } from '@nestjs/common';
import { auditContextFromRequest } from '../../../common/audit/audit-context.js';
import { AuditService } from '../../../common/audit/audit.service.js';
import type { RequestWithContext } from '../../../common/http/request-context.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';
import type { PolicyDecision } from './target-policy.js';
import { verifiedStepUp } from './step-up.guard.js';

const DENY_DETAILS: Readonly<Record<string, string>> = {
  owner_role_reserved: 'Действие над ролью или учётной записью владельца недоступно.',
  self_target: 'Это действие нельзя выполнить над своей учётной записью.',
  owner_scope_limited: 'Владелец управляет только ролями и сессиями администраторов и владельцев.',
  customer_target: 'Действие не применяется к учётной записи клиента.',
  privileged_target: 'Аварийный код не выдаётся администраторам и владельцам.',
  role_not_invitable: 'Приглашением создаются только продавец, кассир и старший продавец.',
};

/**
 * Применение решения политики целей (target-policy.ts): `403 FORBIDDEN {reason}` + аудит `authz.denied` с
 * алертом в логе (11 SEC-040, SEC-041, SEC-043, SEC-069) либо `422 VALIDATION_FAILED {errors[rule]}`.
 * Запись `authz.denied` — отдельной командой (не откатывается вместе с отклонённой операцией).
 */
@Injectable()
export class AdminAuthzService {
  private readonly logger = new Logger('authz');

  constructor(private readonly audit: AuditService) {}

  async enforce(
    req: RequestWithContext & { ip?: string },
    decision: PolicyDecision,
    operation: string,
    targetUserId: string | null,
  ): Promise<void> {
    if (decision.ok) return;
    if (decision.code === 'VALIDATION_FAILED') {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 422,
        detail: decision.message,
        errors: [{ field: decision.field, rule: decision.rule, message: decision.message }],
      });
    }
    await this.denied(req, operation, targetUserId, decision.reason);
    throw new ProblemException('FORBIDDEN', {
      detail: DENY_DETAILS[decision.reason] ?? 'Недостаточно прав для операции.',
      reason: decision.reason,
    });
  }

  /** `authz.denied` (11 §7.2): кто, над кем, какая операция и причина; алерт — структурный лог `security.alert`. */
  async denied(
    req: RequestWithContext & { ip?: string },
    operation: string,
    targetUserId: string | null,
    reason: string,
  ): Promise<void> {
    const ctx = auditContextFromRequest(req);
    try {
      await this.audit.write(ctx, {
        action: 'authz.denied',
        entityType: targetUserId ? 'user' : null,
        entityId: targetUserId,
        after: { operation, reason },
        result: 'denied',
        severity: 'warning',
        stepUpMethod: verifiedStepUp(req)?.method ?? null,
      });
    } catch (e) {
      // Отказ остаётся отказом; сбой аудита — инцидент (11 SEC-073), но не повод выполнить операцию.
      this.logger.error({ event: 'audit.write_failed', requestId: req.id, err: e }, 'authz.denied audit failed');
    }
    this.logger.warn(
      {
        event: 'security.alert',
        alert: 'authz.denied',
        requestId: req.id,
        actorUserId: ctx.actorUserId,
        targetUserId,
        operation,
        reason,
      },
      'authz.denied',
    );
  }
}
