import { Inject, Injectable } from '@nestjs/common';
import { and, eq, gt, isNotNull, isNull, lt, ne, sql, type SQL } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import type { HelloKeyRevokeReason, HelloKeySource } from '../common/enums.js';
import { devices, helloKeys, sessions } from '../db/schema/index.js';

export type HelloKeyRow = typeof helloKeys.$inferSelect;

/** Отозванный ключ — для аудита (`auth.biometrics.disabled`) и снятия `devices.biometric_enrolled_at`. */
export interface RevokedHelloKey {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly source: string;
}

export interface CreateHelloKeyInput {
  readonly userId: string;
  /** `devices.id` (не `device_key`). */
  readonly deviceId: string;
  /** `X509SubjectPublicKeyInfo` (DER) — проверен `parseHelloPublicKey`. */
  readonly publicKey: Buffer;
  readonly algorithm: 'RS256';
  readonly source: HelloKeySource;
}

/**
 * Какие живые ключи отзывать (`revoked_at IS NULL`): пересечение заданных условий; хотя бы одно из `userId`,
 * `deviceId`, `deviceKey` обязательно (отзыв «всех ключей системы» запросом не выражается).
 */
export interface HelloKeyFilter {
  readonly userId?: string;
  /** `devices.id`. */
  readonly deviceId?: string;
  /** `devices.device_key` установки — ключи всех пользователей с этой установкой (правило `personal`, планшет). */
  readonly deviceKey?: string;
  /** Кроме ключей этого пользователя (правило `personal`: вход другого пользователя). */
  readonly exceptUserId?: string;
}

/**
 * `hello_keys` (07 §5.66, DATA-172; миграция 0024): открытые ключи входа через Windows Hello без PIN приложения (W2) и
 * текущий challenge разблокировки — только доступ к данным. Правила (`AUTH_WINDOWS_HELLO_KEY`, правило `personal`,
 * причины отзыва, аудит) — `HelloKeyService` модуля auth. Ни ключ, ни challenge наружу и в журналы не выводятся
 * (11 SEC-146): вызывающий пишет в аудит только `id` строки и `source`.
 */
@Injectable()
export class HelloKeysRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Живой ключ строки `devices` (`hello_keys_device_live_uq`); `forUpdate` — блокировка строки в транзакции. */
  async findLiveByDevice(
    deviceId: string,
    ex: DbExecutor = this.db,
    forUpdate = false,
  ): Promise<HelloKeyRow | undefined> {
    const q = ex
      .select()
      .from(helloKeys)
      .where(and(eq(helloKeys.deviceId, deviceId), isNull(helloKeys.revokedAt)))
      .limit(1);
    const rows = forUpdate ? await q.for('update') : await q;
    return rows[0];
  }

  /** Живые ключи пользователя на всех устройствах (`hello_keys_user_live_idx`). */
  async listLiveByUser(userId: string, ex: DbExecutor = this.db): Promise<HelloKeyRow[]> {
    return ex
      .select()
      .from(helloKeys)
      .where(and(eq(helloKeys.userId, userId), isNull(helloKeys.revokedAt)));
  }

  async insert(input: CreateHelloKeyInput, ex: DbExecutor = this.db): Promise<HelloKeyRow> {
    const rows = await ex
      .insert(helloKeys)
      .values({
        userId: input.userId,
        deviceId: input.deviceId,
        publicKey: input.publicKey,
        algorithm: input.algorithm,
        source: input.source,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('hello_keys.insert: INSERT не вернул строку');
    return row;
  }

  /**
   * Отзыв живых ключей по фильтру с причиной (07 §5.66 `revoke_reason`): challenge гасится тем же оператором (CHECK
   * `hello_keys_challenge_chk` — у отозванного ключа challenge нет). Возвращает отозванные строки.
   */
  async revokeLive(
    filter: HelloKeyFilter,
    reason: HelloKeyRevokeReason,
    ex: DbExecutor = this.db,
  ): Promise<RevokedHelloKey[]> {
    const conds: SQL[] = [isNull(helloKeys.revokedAt)];
    if (filter.userId) conds.push(eq(helloKeys.userId, filter.userId));
    if (filter.deviceId) conds.push(eq(helloKeys.deviceId, filter.deviceId));
    if (filter.deviceKey) {
      conds.push(
        sql`${helloKeys.deviceId} IN (SELECT ${devices.id} FROM ${devices} WHERE ${devices.deviceKey} = ${filter.deviceKey.toLowerCase()})`,
      );
    }
    if (conds.length === 1) throw new Error('hello_keys.revokeLive: нужен userId, deviceId или deviceKey');
    if (filter.exceptUserId) conds.push(ne(helloKeys.userId, filter.exceptUserId));
    return ex
      .update(helloKeys)
      .set({
        revokedAt: sql`now()`,
        revokeReason: reason,
        challenge: null,
        challengeSessionId: null,
        challengeExpiresAt: null,
        updatedAt: sql`now()`,
      })
      .where(and(...conds))
      .returning({
        id: helloKeys.id,
        userId: helloKeys.userId,
        deviceId: helloKeys.deviceId,
        source: helloKeys.source,
      });
  }

  /** Новый challenge ключа (08 §4.1.10): заменяет прежний — не больше одного на ключ. */
  async setChallenge(
    id: string,
    challenge: Buffer,
    sessionId: string,
    expiresAt: Date,
    ex: DbExecutor = this.db,
  ): Promise<boolean> {
    const rows = await ex
      .update(helloKeys)
      .set({ challenge, challengeSessionId: sessionId, challengeExpiresAt: expiresAt, updatedAt: sql`now()` })
      .where(and(eq(helloKeys.id, id), isNull(helloKeys.revokedAt)))
      .returning({ id: helloKeys.id });
    return rows.length === 1;
  }

  /** Погасить challenge ключа (08 §4.1.8: при любом исходе проверки `method: hello_key`). */
  async clearChallenge(id: string, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(helloKeys)
      .set({ challenge: null, challengeSessionId: null, challengeExpiresAt: null, updatedAt: sql`now()` })
      .where(and(eq(helloKeys.id, id), isNotNull(helloKeys.challenge)));
  }

  /** Успешная разблокировка ключом: `last_used_at` (07 §5.66). */
  async markUsed(id: string, at: Date, ex: DbExecutor = this.db): Promise<void> {
    await ex
      .update(helloKeys)
      .set({ lastUsedAt: at, updatedAt: sql`now()` })
      .where(eq(helloKeys.id, id));
  }

  /**
   * Правило `personal` (07 §5.66; 08 §4.1.10): есть ли строка `sessions` другого пользователя, выданная после `since` на
   * строку `devices` с тем же `device_key` (поиск — `devices_device_key_idx`). Отдельного состояния правило не хранит.
   */
  async otherUserSessionSince(
    deviceKey: string,
    userId: string,
    since: Date,
    ex: DbExecutor = this.db,
  ): Promise<boolean> {
    const rows = await ex
      .select({ id: sessions.id })
      .from(sessions)
      .innerJoin(devices, eq(devices.id, sessions.deviceId))
      .where(
        and(eq(devices.deviceKey, deviceKey.toLowerCase()), ne(sessions.userId, userId), gt(sessions.issuedAt, since)),
      )
      .limit(1);
    return rows.length > 0;
  }

  /**
   * Срок хранения (07 §13.3 «`hello_keys`»; задание `retention.daily`): истёкший challenge — три поля в NULL (до
   * удаления `sessions`: FK `challenge_session_id`, `ON DELETE RESTRICT`); отозванные ключи — DELETE через
   * `revokedDays` дней после `revoked_at`. Время — БД (`now()`), как у прочих задач ретенции.
   */
  async purge(revokedDays = 90, ex: DbExecutor = this.db): Promise<{ challenges: number; keys: number }> {
    const cleared = await ex
      .update(helloKeys)
      .set({ challenge: null, challengeSessionId: null, challengeExpiresAt: null, updatedAt: sql`now()` })
      .where(and(isNotNull(helloKeys.challenge), lt(helloKeys.challengeExpiresAt, sql`now()`)))
      .returning({ id: helloKeys.id });
    const deleted = await ex
      .delete(helloKeys)
      .where(
        and(
          isNotNull(helloKeys.revokedAt),
          lt(helloKeys.revokedAt, sql`now() - make_interval(days => ${revokedDays}::int)`),
        ),
      )
      .returning({ id: helloKeys.id });
    return { challenges: cleared.length, keys: deleted.length };
  }
}
