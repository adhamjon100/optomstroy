import { Inject, Injectable } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import { applyAuditGucs, type AuditContext } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import type { PosDatabase } from '../db/database.js';
import { warehouses } from '../db/schema/index.js';
import { DevicesRepository } from '../users/devices.repository.js';
import { type ProfilePatch, UserProfilesRepository } from '../users/user-profiles.repository.js';
import { UsersRepository } from '../users/users.repository.js';
import { ConsentsService } from './consents/consents.service.js';
import {
  activitySphereErrors,
  birthYearErrors,
  fullNameErrors,
  normalizeFullName,
  throwIfErrors,
} from './domain/profile-rules.js';
import { MeService, type ProfileDto, profileToDto } from './me/me.service.js';
import { type SettingsDto, settingsFromProfile, storedFromSettings } from './me/settings.projection.js';
import { IDLE_LOCK_MAX_CUSTOMER, IDLE_LOCK_MIN } from './profile.constants.js';
import type { MeProfilePatchRequest, MeSettingsPutRequest } from './profile.dto.js';

/**
 * `PATCH /me/profile` (08 §4.3.2) и `PUT /me/settings` (08 §4.3.4). Профиль — данные приложения, не карточка 1С
 * (09 §7.7): реплика `customers` не изменяется. Оптимистичная блокировка — `user_profiles.row_version` (общая для
 * профиля и настроек: триггер check_row_version 07 §8.3 требует +1 при любом UPDATE строки; D_spec_questions PR-05).
 */
@Injectable()
export class ProfileService {
  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly users: UsersRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly consents: ConsentsService,
    private readonly me: MeService,
    private readonly audit: AuditService,
  ) {}

  async patchProfile(p: AuthenticatedPrincipal, body: MeProfilePatchRequest, ctx: AuditContext): Promise<ProfileDto> {
    const errors: ProblemFieldError[] = [];
    const patch: ProfilePatch = {};
    if (body.fullName !== undefined) {
      errors.push(...fullNameErrors(body.fullName));
      patch.fullName = normalizeFullName(body.fullName);
    }
    if (body.birthYear !== undefined) {
      errors.push(...birthYearErrors(body.birthYear, this.clock.now()));
      patch.birthYear = body.birthYear;
    }
    if (body.activitySphere !== undefined) {
      errors.push(...activitySphereErrors(body.activitySphere));
      patch.activitySphere = body.activitySphere;
    }
    throwIfErrors(errors);

    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const user = await this.users.findById(p.userId, tx);
      if (!user) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
      const current = await this.profiles.findByUserId(p.userId, tx);
      if (!current) {
        // Учётная запись без профиля (сотрудник по приглашению без ФИО, 09 §7.6): первый PATCH создаёт профиль.
        if (body.rowVersion !== 0 || patch.fullName === undefined) {
          throw new ProblemException('VERSION_CONFLICT', { detail: 'Профиль ещё не создан.', current: {} });
        }
      } else if (current.rowVersion !== body.rowVersion) {
        throw this.conflict(profileToDto(current, user));
      }
      if (patch.activitySphere !== undefined && patch.activitySphere !== null) {
        if (!(await this.consents.isActive(p.userId, 'activity_sphere', null, tx))) {
          throw new ProblemException('CONSENT_REQUIRED', {
            detail: 'Сфера деятельности сохраняется только при согласии на её обработку.',
            reason: 'activity_sphere',
          });
        }
      }
      const fields = Object.keys(patch);
      let row;
      if (!current) {
        row = await this.profiles.create(
          {
            userId: p.userId,
            fullName: patch.fullName ?? '',
            birthYear: patch.birthYear ?? null,
            activitySphere: patch.activitySphere ?? null,
          },
          tx,
        );
      } else {
        row = await this.profiles.update(p.userId, patch, body.rowVersion, tx);
        if (!row) {
          const fresh = await this.profiles.findByUserId(p.userId, tx);
          throw this.conflict(profileToDto(fresh, user));
        }
      }
      if (fields.length > 0) {
        await this.audit.write(
          ctx,
          { action: 'profile.updated', entityType: 'user_profiles', entityId: p.userId, after: { fields } },
          tx,
        );
      }
      const dto = profileToDto(row, user);
      if (!dto) throw new Error('profile: строка не найдена после записи');
      return dto;
    });
  }

  private conflict(current: ProfileDto | undefined): ProblemException {
    return new ProblemException('VERSION_CONFLICT', {
      detail: 'Профиль изменён другим запросом. Обновите данные.',
      current: current ? { ...current } : {},
    });
  }

  async putSettings(p: AuthenticatedPrincipal, body: MeSettingsPutRequest): Promise<SettingsDto> {
    const maxIdle =
      p.kind === 'staff' ? this.me.settingsContext('staff', p.roles).staffIdleMinutes : IDLE_LOCK_MAX_CUSTOMER;
    const errors: ProblemFieldError[] = [];
    if (body.idleLockMinutes < IDLE_LOCK_MIN || body.idleLockMinutes > maxIdle) {
      errors.push({
        field: 'idleLockMinutes',
        message: `Допустимо от ${IDLE_LOCK_MIN} до ${maxIdle} минут`,
        rule: 'idle_lock_range',
        params: { min: IDLE_LOCK_MIN, max: maxIdle },
      });
    }
    if (body.defaultWarehouseId !== null) {
      const wh = await this.db
        .select({ id: warehouses.id })
        .from(warehouses)
        .where(eq(warehouses.id, body.defaultWarehouseId))
        .limit(1);
      if (wh.length === 0) {
        errors.push({ field: 'defaultWarehouseId', message: 'Склад не найден', rule: 'warehouse_unknown' });
      }
    }
    throwIfErrors(errors);

    const device = await this.devices.findByKey(p.userId, p.deviceId);
    const sctx = this.me.settingsContext(p.kind, p.roles, device?.platform);
    return this.db.transaction(async (tx) => {
      const profile = await this.profiles.findByUserId(p.userId, tx);
      if (!profile) throw new ProblemException('VERSION_CONFLICT', { detail: 'Профиль ещё не создан.', current: {} });
      const current = settingsFromProfile(profile, sctx);
      const conflict = (cur: SettingsDto) =>
        new ProblemException('VERSION_CONFLICT', {
          detail: 'Настройки или профиль изменены другим запросом. Обновите данные.',
          current: { ...cur },
        });
      if (current.rowVersion !== body.rowVersion) throw conflict(current);
      const next: Omit<SettingsDto, 'rowVersion'> = {
        locale: body.locale ?? current.locale,
        scanner: body.scanner ? { mode: body.scanner.mode, suffix: body.scanner.suffix } : current.scanner,
        scanAddsToCart: body.scanAddsToCart,
        printer: body.printer
          ? { defaultFormat: body.printer.defaultFormat, autoPrint: body.printer.autoPrint }
          : current.printer,
        catalogView: body.catalogView,
        defaultWarehouseId: body.defaultWarehouseId,
        idleLockMinutes: body.idleLockMinutes,
      };
      const row = await this.profiles.update(
        p.userId,
        { settings: storedFromSettings(next), locale: next.locale },
        body.rowVersion,
        tx,
      );
      if (!row) {
        const fresh = await this.profiles.findByUserId(p.userId, tx);
        throw conflict(settingsFromProfile(fresh, sctx));
      }
      return settingsFromProfile(row, sctx);
    });
  }
}
