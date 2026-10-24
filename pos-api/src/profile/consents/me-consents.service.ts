import { Inject, Injectable } from '@nestjs/common';
import { applyAuditGucs, type AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { ConsentKind } from '../../common/enums.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import type { PosDatabase } from '../../db/database.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { MeConsentUpdateRequest } from '../profile.dto.js';
import { SecurityService } from '../security.service.js';
import type { StepUpOutcome } from '../step-up/step-up.guard.js';
import { consentEntry, isCurrentConsentVersion } from './consent-catalog.js';
import { ConsentRevocationNotifier } from './consent-revocation.notifier.js';
import type { ConsentRow } from './consents.repository.js';
import { type ConsentDto, type ConsentRequirementDto, ConsentsService, consentToDto } from './consents.service.js';

export interface MeConsentList {
  readonly items: ConsentDto[];
  readonly required: ConsentRequirementDto[];
}

function invalid(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, message, rule }],
  });
}

/**
 * `GET/POST /me/consents` (08 §4.3.7, API-050; 11 §10.3, PRIV-006): выдача и отзыв не сложнее друг друга (ст. 79).
 * Отзыв `biometrics_device` выключает биометрию устройства (отзыв биометрической семьи); отзыв `activity_sphere`
 * обнуляет `user_profiles.activity_sphere` (07 §5.2); отзыв `personal_data` (со step-up) блокирует учётную запись,
 * отзывает все её сессии и уведомляет активных администраторов (in-app, без ПДн; D PR-06). Повтор с тем же
 * `{kind, version, granted}` → 200 без новой записи.
 */
@Injectable()
export class MeConsentsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    private readonly consents: ConsentsService,
    private readonly users: UsersRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly security: SecurityService,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
    private readonly revocationNotifier: ConsentRevocationNotifier,
  ) {}

  async list(p: AuthenticatedPrincipal): Promise<MeConsentList> {
    const device = await this.devices.findByKey(p.userId, p.deviceId);
    return {
      items: await this.consents.latestView(p.userId, device?.id ?? null),
      required: this.consents.requirements(),
    };
  }

  async update(
    p: AuthenticatedPrincipal,
    body: MeConsentUpdateRequest,
    stepUp: StepUpOutcome,
    ctx: AuditContext,
  ): Promise<ConsentDto> {
    const entry = consentEntry(body.kind);
    if (!entry) throw invalid('kind', 'consent_kind', 'Вид согласия недоступен в R1');
    if (!entry.versions.some((v) => v.version === body.version)) {
      throw invalid('version', 'consent_version', 'Неизвестная версия текста согласия');
    }
    const device = await this.devices.findByKey(p.userId, p.deviceId);
    const deviceRowId = entry.perDevice ? (device?.id ?? null) : null;
    if (entry.perDevice && !device) throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия завершена.' });

    if (body.granted) {
      if (!isCurrentConsentVersion(body.kind, body.version)) {
        throw invalid('version', 'consent_version', 'Принимается только действующая версия текста');
      }
      return this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, ctx);
        const r = await this.consents.grant(
          {
            userId: p.userId,
            kind: body.kind,
            version: body.version,
            deviceRowId,
            ip: ctx.ip ?? null,
            appVersion: ctx.appVersion ?? null,
          },
          tx,
        );
        if (r.superseded) await this.auditConsent(ctx, 'consent.revoked', r.superseded, tx);
        if (r.changed) await this.auditConsent(ctx, 'consent.granted', r.row, tx);
        return consentToDto(r.row);
      });
    }

    const revokedSessions: string[] = [];
    let blocked = false;
    const result = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const revoked = await this.consents.revoke(p.userId, body.kind, deviceRowId, tx);
      if (!revoked) return this.latestOrNone(p.userId, body.kind, body.version, deviceRowId, tx);
      if (body.kind === 'biometrics_device' && device && device.biometricEnrolledAt !== null) {
        revokedSessions.push(...(await this.security.disableOnDevice(p.userId, device, ctx, tx, stepUp, false)));
      }
      if (body.kind === 'activity_sphere') {
        const profile = await this.profiles.findByUserId(p.userId, tx);
        if (profile && profile.activitySphere !== null) {
          await this.profiles.update(p.userId, { activitySphere: null }, undefined, tx);
        }
      }
      if (body.kind === 'personal_data') {
        // 08 §4.3.7: отзыв personal_data переводит аккаунт в blocked (аудит БД user.blocked — trg_users_audit).
        await this.users.setStatus(
          p.userId,
          'blocked',
          { blockedByUserId: p.userId, blockReason: 'consent_personal_data_revoked' },
          tx,
        );
        await this.users.bumpPermissionsVersion(p.userId, tx);
        revokedSessions.push(...(await this.sessions.revokeAllForUser(p.userId, 'blocked', {}, tx)));
        // «…с уведомлением администратора» (08 §4.3.7; D PR-06): in-app уведомление активным admin без ПДн.
        await this.revocationNotifier.personalDataRevoked(p.userId, revoked.id, tx);
        blocked = true;
      }
      await this.audit.write(
        ctx,
        {
          action: 'consent.revoked',
          entityType: 'consents',
          entityId: revoked.id,
          after: { kind: revoked.kind, version: revoked.version, deviceId: revoked.deviceId },
          stepUpMethod: stepUp.proof?.method ?? null,
        },
        tx,
      );
      return consentToDto(revoked);
    });
    for (const sid of revokedSessions) this.cache.invalidateSession(sid);
    if (blocked) this.cache.invalidateUser(p.userId);
    return result;
  }

  private async latestOrNone(
    userId: string,
    kind: ConsentKind,
    version: string,
    deviceRowId: string | null,
    ex: DbExecutor,
  ): Promise<ConsentDto> {
    const view = await this.consents.latestView(userId, deviceRowId, ex);
    return view.find((c) => c.kind === kind) ?? { kind, version, granted: false, grantedAt: null, revokedAt: null };
  }

  private async auditConsent(
    ctx: AuditContext,
    action: 'consent.granted' | 'consent.revoked',
    row: ConsentRow,
    tx: DbExecutor,
  ): Promise<void> {
    await this.audit.write(
      ctx,
      {
        action,
        entityType: 'consents',
        entityId: row.id,
        after: { kind: row.kind, version: row.version, deviceId: row.deviceId },
      },
      tx,
    );
  }
}
