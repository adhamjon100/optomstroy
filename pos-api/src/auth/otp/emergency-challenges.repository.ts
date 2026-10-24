import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';

/** Живой аварийный челлендж номера (09 §6.13 п. 3): выдан администратором, без `sms_outbox`. */
export interface EmergencyChallenge {
  readonly challengeId: string;
  readonly userId: string;
  readonly expiresAt: Date;
  /** `X-Device-Id` первого `/auth/otp/request` (NULL — ещё не привязан). */
  readonly deviceKey: string | null;
  readonly issuedByUserId: string | null;
}

interface RawChallenge {
  id: string;
  user_id: string;
  expires_at: Date | string;
  device_key: string | null;
  issued_by_user_id: string | null;
  [k: string]: unknown;
}

/** Действие аудита выдачи (11 §7.2.1). */
export const EMERGENCY_ISSUED_ACTION = 'auth.emergency_code.issued';

/**
 * Сторона входа аварийного кода (RM-D-016; 09 §6.13 п. 3, SMS-035; AC-AUTH-086). Выдача — модуль admin
 * (`EmergencyLoginCodeService`): `otp_challenges` (`purpose=login_or_register`, `status=sent`, `sms_outbox_id IS
 * NULL`, `device_key IS NULL`, `issued_by_user_id` = администратор) + аудит `auth.emergency_code.issued` в одной
 * транзакции. Признак «выдан администратором» — столбец `issued_by_user_id` (миграция 0003; DQ-03, adm A-08; до 0003
 * — запись аудита, заполнено миграцией). Тестовый режим OTP (тоже без `sms_outbox`) отметки не имеет.
 */
@Injectable()
export class EmergencyChallengesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Живой (`sent`, не истёкший на `now`) аварийный челлендж номера; строка блокируется `FOR UPDATE OF c`. */
  async findLiveForPhone(
    phoneE164: string,
    now: Date,
    ex: DbExecutor = this.db,
  ): Promise<EmergencyChallenge | undefined> {
    const res = await ex.execute<RawChallenge>(sql`
      SELECT c.id, c.user_id, c.expires_at, c.device_key, c.issued_by_user_id
        FROM otp_challenges c
       WHERE c.phone_e164 = ${phoneE164} AND c.purpose = 'login_or_register' AND c.status = 'sent'
         AND c.issued_by_user_id IS NOT NULL AND c.sms_outbox_id IS NULL AND c.user_id IS NOT NULL
         AND c.expires_at > ${now.toISOString()}::timestamptz
       ORDER BY c.created_at DESC
       LIMIT 1
         FOR UPDATE OF c`);
    const r = res.rows[0];
    return r ? toChallenge(r) : undefined;
  }

  /** Челлендж выдан администратором (для `/auth/otp/verify` и ротации: `amr=admin_code`, аудит `used`). */
  async findIssued(challengeId: string, ex: DbExecutor = this.db): Promise<EmergencyChallenge | undefined> {
    const res = await ex.execute<RawChallenge>(sql`
      SELECT c.id, c.user_id, c.expires_at, c.device_key, c.issued_by_user_id
        FROM otp_challenges c
       WHERE c.id = ${challengeId}::uuid AND c.issued_by_user_id IS NOT NULL AND c.sms_outbox_id IS NULL
         AND c.purpose = 'login_or_register'
       LIMIT 1`);
    const r = res.rows[0];
    return r ? toChallenge(r) : undefined;
  }

  /**
   * Привязка к `X-Device-Id` первого `/auth/otp/request` (09 §6.13, SEC-131): только пока не привязан или тот же
   * `device_key`. false — уже привязан к другому устройству.
   */
  async bindDevice(challengeId: string, deviceKey: string, ex: DbExecutor = this.db): Promise<boolean> {
    const res = await ex.execute<{ id: string }>(sql`
      UPDATE otp_challenges SET device_key = ${deviceKey}, updated_at = now()
       WHERE id = ${challengeId}::uuid AND status = 'sent' AND sms_outbox_id IS NULL
         AND (device_key IS NULL OR device_key = ${deviceKey})
      RETURNING id`);
    return res.rows.length === 1;
  }
}

function toChallenge(r: RawChallenge): EmergencyChallenge {
  return {
    challengeId: r.id,
    userId: r.user_id,
    expiresAt: r.expires_at instanceof Date ? r.expires_at : new Date(r.expires_at),
    deviceKey: r.device_key,
    issuedByUserId: r.issued_by_user_id,
  };
}
