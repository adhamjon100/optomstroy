import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { applyAuditGucs, auditContextFromRequest } from '../../../common/audit/audit-context.js';
import { AuditService } from '../../../common/audit/audit.service.js';
import type { DbExecutor } from '../../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../../common/auth/clock.js';
import { OtpHmacService } from '../../../common/crypto/otp-hmac.service.js';
import { generateOtpCode } from '../../../common/crypto/random.js';
import { DRIZZLE } from '../../../common/db/database.module.js';
import type { RequestWithContext } from '../../../common/http/request-context.js';
import { newId } from '../../../common/ids/uuid.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';
import { principalOf } from '../shared/principal.js';
import { AdminUsersRepository } from '../admin-users.repository.js';
import { policyTarget } from '../admin-users.service.js';
import { AdminAuthzService } from '../shared/admin-authz.service.js';
import { maskPhone } from '../shared/phone.js';
import { verifiedStepUp } from '../shared/step-up.guard.js';
import { canIssueEmergencyCode } from '../shared/target-policy.js';
import type { EmergencyLoginCodeDto, EmergencyLoginCodeRequestDto } from './emergency-code.dto.js';
import { EmergencyCodeRepository } from './emergency-code.repository.js';

/** TTL аварийного кода — 10 мин (08 §4.18.10; 09 §6.13; 11 SEC-131). */
export const EMERGENCY_CODE_TTL_MS = 10 * 60_000;
/** Не более 3 кодов на пользователя и 20 на администратора за сутки (09 §6.13; 08 §4.18.10). */
export const EMERGENCY_CODES_PER_TARGET_PER_DAY = 3;
export const EMERGENCY_CODES_PER_ADMIN_PER_DAY = 20;

const REASON_TEXT: Readonly<Record<string, string>> = {
  sms_unavailable: 'sms_unavailable: SMS недоступны',
  sim_lost: 'sim_lost: утеряна SIM-карта',
};

type Req = RequestWithContext & { ip?: string };

/** UUID → 16 байт (`otp_challenges.salt`: соль = `challenge_id`, 09 §5.2; D_spec_questions F-03). */
function uuidBytes(id: string): Buffer {
  return Buffer.from(id.replace(/-/g, ''), 'hex');
}

/**
 * Аварийный одноразовый код входа сотрудника при недоступности SMS (RM-D-016; 08 §4.18.10; 09 §6.13, SMS-035;
 * 11 №76, SEC-043, SEC-131; ядро §22.13 п. 2, §23 п. 8). Выдача — `admin` со step-up по PIN; цель — активный
 * сотрудник, не себе, не `admin`/`owner`. Создаётся `otp_challenges` (`purpose=login_or_register`, без
 * `sms_outbox`): 6 цифр CSPRNG, только HMAC (`OtpHmacService`, соль — `challenge_id`), TTL 10 мин, попытки —
 * `OTP_MAX_VERIFY_ATTEMPTS` (проверяет `/auth/otp/verify`), прежний живой челлендж номера → `superseded`.
 * Код возвращается один раз и не попадает в логи, аудит, уведомления и `idempotency_keys`.
 *
 * Вход по коду (`/auth/otp/request` → `/auth/otp/verify`, `amr=admin_code`, аудит `auth.emergency_code.used`) —
 * модуль auth: `src/auth/login/emergency-login.service.ts` (признак выдачи — запись аудита `issued` этой транзакции).
 */
@Injectable()
export class EmergencyLoginCodeService {
  private readonly logger = new Logger('admin.emergency_code');

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: EmergencyCodeRepository,
    private readonly adminUsers: AdminUsersRepository,
    private readonly hmac: OtpHmacService,
    private readonly audit: AuditService,
    private readonly authz: AdminAuthzService,
  ) {}

  async issue(req: Req, targetUserId: string, body: EmergencyLoginCodeRequestDto): Promise<EmergencyLoginCodeDto> {
    const actor = principalOf(req);
    const record = await this.adminUsers.findRecord(targetUserId);
    if (!record) throw new ProblemException('NOT_FOUND', { detail: 'Пользователь не найден.' });
    await this.authz.enforce(
      req,
      canIssueEmergencyCode(actor, policyTarget(record)),
      'users.emergency_code.issue',
      targetUserId,
    );
    const comment = body.comment?.trim() || null;
    if (body.reason === 'other' && !comment) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Для причины «другое» нужен комментарий (5–200 символов).',
        errors: [{ field: 'comment', rule: 'comment_required', message: 'Комментарий обязателен при reason=other.' }],
      });
    }
    const phone = record.phoneE164;
    if (!phone) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 422,
        detail: 'У пользователя нет номера телефона.',
        errors: [{ field: 'id', rule: 'target_not_active_staff', message: 'У пользователя нет номера телефона.' }],
      });
    }

    const ctx = auditContextFromRequest(req);
    const now = this.clock.now();
    const expiresAt = new Date(now.getTime() + EMERGENCY_CODE_TTL_MS);
    const challengeId = newId();
    const code = generateOtpCode();
    const reasonText = body.reason === 'other' ? `other: ${comment ?? ''}` : (REASON_TEXT[body.reason] ?? body.reason);

    await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      // Сериализация выдач (лимиты считаются по аудиту — без гонки двух параллельных выдач)
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext('admin.emergency_code'))`);
      const user = await this.adminUsers.lockUser(targetUserId, tx);
      if (!user || user.kind !== 'staff' || user.status !== 'active' || user.phoneE164 !== phone) {
        throw new ProblemException('VALIDATION_FAILED', {
          status: 422,
          detail: 'Аварийный код выдаётся только активному сотруднику.',
          errors: [{ field: 'id', rule: 'target_not_active_staff', message: 'Цель — не активный сотрудник.' }],
        });
      }
      await this.enforceLimits(targetUserId, actor.userId, tx);
      await this.repo.supersedeLive(phone, tx);
      await this.repo.insert(
        {
          id: challengeId,
          userId: targetUserId,
          phoneE164: phone,
          codeHmac: this.hmac.codeHmac(challengeId, code),
          salt: uuidBytes(challengeId),
          pepperVersion: this.hmac.currentVersion,
          expiresAt,
          requestId: ctx.requestId ?? null,
          issuedByUserId: actor.userId,
        },
        tx,
      );
      const owners = await this.adminUsers.activeOwnerIds(tx);
      await this.adminUsers.notify(
        [targetUserId],
        {
          title: 'Выдан аварийный код входа',
          body: 'Администратор выдал вам одноразовый код входа. Если вы его не запрашивали — сообщите руководителю.',
          dedupeKey: `auth.emergency_code.issued:${challengeId}`,
          severity: 'warning',
          payload: { expiresAt: expiresAt.toISOString() },
        },
        tx,
      );
      await this.adminUsers.notify(
        owners,
        {
          title: 'Выдан аварийный код входа сотруднику',
          body: 'Администратор выдал сотруднику аварийный код входа (SMS недоступны). Подробности — в журнале аудита.',
          dedupeKey: `auth.emergency_code.issued:${challengeId}`,
          severity: 'warning',
          payload: { targetUserId, issuedByUserId: actor.userId, expiresAt: expiresAt.toISOString() },
        },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: 'auth.emergency_code.issued',
          entityType: 'user',
          entityId: targetUserId,
          after: {
            challengeId,
            expiresAt: expiresAt.toISOString(),
            reasonCode: body.reason,
            targetRole: record.role,
          },
          reason: reasonText,
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
          severity: 'warning',
        },
        tx,
      );
    });

    // Алерт класса SEC-069 на каждую выдачу — без кода и телефона
    this.logger.warn(
      {
        event: 'security.alert',
        alert: 'auth.emergency_code.issued',
        requestId: req.id,
        actorUserId: actor.userId,
        targetUserId,
        challengeId,
        expiresAt: expiresAt.toISOString(),
      },
      'auth.emergency_code.issued',
    );
    return { code, expiresAt: expiresAt.toISOString(), phoneMasked: maskPhone(phone) };
  }

  private async enforceLimits(targetUserId: string, actorUserId: string, tx: DbExecutor): Promise<void> {
    const byTarget = await this.repo.issuedInLastDay({ targetUserId }, tx);
    const byActor = await this.repo.issuedInLastDay({ actorUserId }, tx);
    const over = [
      byTarget.count >= EMERGENCY_CODES_PER_TARGET_PER_DAY ? byTarget.retryAfterSec : -1,
      byActor.count >= EMERGENCY_CODES_PER_ADMIN_PER_DAY ? byActor.retryAfterSec : -1,
    ].filter((v) => v >= 0);
    if (over.length > 0) {
      const retryAfter = Math.max(1, ...over);
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Лимит выдачи аварийных кодов за сутки исчерпан.',
        retryAfter,
        reason: byTarget.count >= EMERGENCY_CODES_PER_TARGET_PER_DAY ? 'per_user_daily' : 'per_admin_daily',
      });
    }
  }
}
