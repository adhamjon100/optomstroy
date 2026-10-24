import { Inject, Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { ConsentKind } from '../../common/enums.js';
import { consentEntry, consentTextHash, mandatoryConsentKinds } from './consent-catalog.js';
import { type ConsentRow, ConsentsRepository } from './consents.repository.js';

/** DTO `Consent` (08 §3.14; contracts/openapi `Consent`). */
export interface ConsentDto {
  readonly kind: ConsentKind;
  readonly version: string;
  readonly granted: boolean;
  readonly grantedAt: string | null;
  readonly revokedAt: string | null;
}

/** DTO `MeConsentRequirement`. */
export interface ConsentRequirementDto {
  readonly kind: ConsentKind;
  readonly currentVersion: string;
}

export interface GrantConsentInput {
  readonly userId: string;
  readonly kind: ConsentKind;
  readonly version: string;
  /** `devices.id` — для вида с `perDevice` (biometrics_device); для остальных игнорируется. */
  readonly deviceRowId?: string | null;
  readonly ip?: string | null;
  readonly appVersion?: string | null;
  readonly otpChallengeId?: string | null;
}

export interface ConsentChange {
  readonly row: ConsentRow;
  /** true — создана новая запись (аудит `consent.granted`) / запись отозвана этим вызовом (`consent.revoked`). */
  readonly changed: boolean;
  /** Отозванная этим вызовом запись прежней версии (смена версии при повторном согласии). */
  readonly superseded?: ConsentRow;
}

export function consentToDto(row: ConsentRow): ConsentDto {
  return {
    kind: row.kind,
    version: row.version,
    granted: row.revokedAt === null,
    grantedAt: row.grantedAt.toISOString(),
    revokedAt: row.revokedAt ? row.revokedAt.toISOString() : null,
  };
}

/**
 * Согласия пользователя (07 §5.14; 08 §4.2.1, §4.3.7; 11 §10.3, PRIV-006): выдача с версией и хэшем текста
 * (`consent-catalog.ts`), отзыв, представление для `/me` и `/me/consents`. Аудит (`consent.granted`/`consent.revoked`)
 * пишет вызывающий — последним оператором своей транзакции (07 §9.3).
 */
@Injectable()
export class ConsentsService {
  constructor(
    private readonly repo: ConsentsRepository,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  /** Устройство записи: только для видов «на устройство» (biometrics_device), иначе NULL. */
  private deviceFor(kind: ConsentKind, deviceRowId: string | null | undefined): string | null {
    return consentEntry(kind)?.perDevice ? (deviceRowId ?? null) : null;
  }

  /**
   * Выдать согласие (идемпотентно): активная запись той же версии → без изменений; иной версии → прежняя
   * отзывается, создаётся новая. Неизвестный вид/версия — ошибка программиста (проверяет вызывающий).
   */
  async grant(input: GrantConsentInput, ex: DbExecutor): Promise<ConsentChange> {
    const hash = consentTextHash(input.kind, input.version);
    if (!hash) throw new Error(`consents.grant: нет текста ${input.kind}@${input.version}`);
    const deviceRowId = this.deviceFor(input.kind, input.deviceRowId);
    const active = await this.repo.findActive(input.userId, input.kind, deviceRowId, ex, true);
    if (active && active.version === input.version) return { row: active, changed: false };
    const now = this.clock.now();
    const superseded = active ? await this.repo.revoke(active.id, now, ex) : undefined;
    const row = await this.repo.insert(
      {
        userId: input.userId,
        kind: input.kind,
        version: input.version,
        textSha256: hash,
        grantedAt: now,
        deviceRowId,
        ip: input.ip ?? null,
        appVersion: input.appVersion ?? null,
        otpChallengeId: input.otpChallengeId ?? null,
      },
      ex,
    );
    return { row, changed: true, ...(superseded ? { superseded } : {}) };
  }

  /** Отозвать активное согласие вида (на устройстве — для biometrics_device). `undefined` — активного не было. */
  async revoke(
    userId: string,
    kind: ConsentKind,
    deviceRowId: string | null | undefined,
    ex: DbExecutor,
  ): Promise<ConsentRow | undefined> {
    const active = await this.repo.findActive(userId, kind, this.deviceFor(kind, deviceRowId), ex, true);
    if (!active) return undefined;
    return this.repo.revoke(active.id, this.clock.now(), ex);
  }

  async isActive(
    userId: string,
    kind: ConsentKind,
    deviceRowId: string | null | undefined,
    ex?: DbExecutor,
  ): Promise<boolean> {
    return (await this.repo.findActive(userId, kind, this.deviceFor(kind, deviceRowId), ex)) !== undefined;
  }

  async findActive(
    userId: string,
    kind: ConsentKind,
    deviceRowId: string | null | undefined,
    ex?: DbExecutor,
  ): Promise<ConsentRow | undefined> {
    return this.repo.findActive(userId, kind, this.deviceFor(kind, deviceRowId), ex);
  }

  /**
   * Последняя запись каждого вида (для `biometrics_device` — только текущего устройства): `Me.consents`,
   * `GET /me/consents.items`.
   */
  async latestView(userId: string, deviceRowId: string | null | undefined, ex?: DbExecutor): Promise<ConsentDto[]> {
    const rows = await this.repo.listForUser(userId, ex);
    const seen = new Set<string>();
    const out: ConsentDto[] = [];
    for (const r of rows) {
      if (consentEntry(r.kind)?.perDevice && r.deviceId !== (deviceRowId ?? null)) continue;
      if (seen.has(r.kind)) continue;
      // Активная запись важнее более поздней отозванной (смена версии: отзыв + новая запись в одну миллисекунду).
      const active = rows.find((x) => x.kind === r.kind && x.revokedAt === null && x.deviceId === r.deviceId);
      seen.add(r.kind);
      out.push(consentToDto(active ?? r));
    }
    return out;
  }

  requirements(): ConsentRequirementDto[] {
    return mandatoryConsentKinds().map((e) => ({ kind: e.kind, currentVersion: e.current }));
  }
}
