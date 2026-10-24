import { sql } from 'drizzle-orm';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { maskPhone } from '../../common/logging/redaction.js';
import type { PosDatabase } from '../../db/database.js';
import { normalizeKgPhone } from '../../auth/common/phone.js';

/**
 * Первичный администратор на пустой БД staging/prod (D_spec_questions INT-02, DQ-27; 16 — первичная настройка;
 * 11 SEC-136 — приглашает только `admin`, поэтому первый `admin` появляется операторской процедурой, а не через API).
 *
 * Процедура создаёт **приглашение** с ролью `admin` для номера оператора — не пользователя с паролем и не токен:
 * учётная запись появляется при первом входе по OTP (ветка «приглашение», 09 §4.3, RM-D-017), сразу со шагом
 * `set_pin` (PIN обязателен для staff, D-48). Условия:
 * - выполняется, только если в системе **нет активного** пользователя с ролью `admin` (иначе — ничего не делает);
 * - идемпотентна: повторный запуск для того же номера при действующем приглашении ничего не меняет;
 * - номер уже принадлежит учётной записи или есть действующее приглашение `admin` на другой номер — отказ;
 * - всё — одной транзакцией под advisory-lock; аудит `user.invited` (и `user.created` технической записи автора).
 *
 * `user_invitations.invited_by_user_id NOT NULL` (07 §5.3), а пользователей на пустой БД нет: автор приглашения —
 * техническая запись «Первичная настройка» (`phone_e164 = NULL`, `status = deleted`, без ролей — войти ей нельзя,
 * в списках администрирования не видна; повторно используется). Вопрос владельцу 07 — E_spec_questions EQ-AUTH-*.
 */
export interface BootstrapAdminInput {
  /** Номер оператора (любая запись, нормализуется к `+996XXXXXXXXX`, только мобильные КР — 09 §3.4). */
  readonly phone: string;
  /** ФИО администратора (2…150 символов, 07 §5.3). */
  readonly fullName: string;
  /** Срок действия приглашения, суток (по умолчанию `INVITATION_TTL_DAYS`). */
  readonly ttlDays: number;
  /** Сквозной идентификатор запуска (аудит `request_id`). */
  readonly requestId: string;
  readonly now?: Date;
}

export type BootstrapAdminResult =
  | { readonly kind: 'created'; readonly invitationId: string; readonly phoneMasked: string; readonly expiresAt: Date }
  | {
      readonly kind: 'already_pending';
      readonly invitationId: string;
      readonly phoneMasked: string;
      readonly expiresAt: Date;
    }
  | { readonly kind: 'admin_exists' }
  | { readonly kind: 'invalid'; readonly field: 'phone' | 'fullName' | 'ttlDays'; readonly message: string }
  | { readonly kind: 'phone_taken'; readonly phoneMasked: string }
  | { readonly kind: 'other_pending'; readonly phoneMasked: string; readonly expiresAt: Date };

/** Имя технической записи-автора приглашения (user_profiles.full_name). */
export const BOOTSTRAP_INVITER_NAME = 'Первичная настройка (оператор)';
const LOCK_KEY = 'optomstroy:bootstrap-first-admin';
const MAX_TTL_DAYS = 30;

interface Row {
  [k: string]: unknown;
}

export async function bootstrapFirstAdmin(db: PosDatabase, input: BootstrapAdminInput): Promise<BootstrapAdminResult> {
  const phone = normalizeKgPhone(input.phone);
  if (phone === null) {
    return { kind: 'invalid', field: 'phone', message: 'номер — мобильный номер КР (+996XXXXXXXXX)' };
  }
  const fullName = input.fullName.trim().replace(/\s+/g, ' ');
  if (fullName.length < 2 || fullName.length > 150) {
    return { kind: 'invalid', field: 'fullName', message: 'ФИО — от 2 до 150 символов' };
  }
  if (!Number.isInteger(input.ttlDays) || input.ttlDays < 1 || input.ttlDays > MAX_TTL_DAYS) {
    return { kind: 'invalid', field: 'ttlDays', message: `срок приглашения — целое 1…${MAX_TTL_DAYS} суток` };
  }
  const now = input.now ?? new Date();
  const audit = new AuditService(db);
  const ctx: AuditContext = { requestId: input.requestId, system: 'bootstrap' };

  return db.transaction(async (tx): Promise<BootstrapAdminResult> => {
    await applyAuditGucs(tx, ctx);
    await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtextextended(${LOCK_KEY}, 0))`);

    const admins = await tx.execute<Row>(sql`
      SELECT 1 FROM users u
        JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
        JOIN roles r ON r.id = ur.role_id AND r.code = 'admin'
       WHERE u.status = 'active' AND u.deleted_at IS NULL
       LIMIT 1`);
    if (admins.rows.length > 0) return { kind: 'admin_exists' };

    const pending = await tx.execute<{ id: string; phone_e164: string; expires_at: Date | string }>(sql`
      SELECT id, phone_e164, expires_at FROM user_invitations
       WHERE role = 'admin' AND status = 'pending' AND revoked_at IS NULL
         AND expires_at > ${now.toISOString()}::timestamptz
       ORDER BY created_at DESC`);
    const same = pending.rows.find((r) => r.phone_e164 === phone);
    if (same) {
      return {
        kind: 'already_pending',
        invitationId: same.id,
        phoneMasked: maskPhone(phone),
        expiresAt: new Date(same.expires_at),
      };
    }
    const other = pending.rows[0];
    if (other) {
      return { kind: 'other_pending', phoneMasked: maskPhone(other.phone_e164), expiresAt: new Date(other.expires_at) };
    }

    const owner = await tx.execute<Row>(sql`
      SELECT 1 FROM users WHERE phone_e164 = ${phone} AND deleted_at IS NULL LIMIT 1`);
    if (owner.rows.length > 0) return { kind: 'phone_taken', phoneMasked: maskPhone(phone) };

    // Просроченное, но не закрытое приглашение номера мешает частичному UNIQUE (phone) WHERE status = 'pending'.
    await tx.execute(sql`
      UPDATE user_invitations SET status = 'expired', updated_at = now()
       WHERE phone_e164 = ${phone} AND status = 'pending' AND expires_at <= ${now.toISOString()}::timestamptz`);

    const inviterId = await bootstrapInviter(tx, audit, ctx);
    const expiresAt = new Date(now.getTime() + input.ttlDays * 86_400_000);
    const inv = await tx.execute<{ id: string }>(sql`
      INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, status, expires_at, note)
      VALUES (${phone}, 'admin', ${fullName}, ${inviterId}::uuid, 'pending', ${expiresAt.toISOString()}::timestamptz,
              'Первичный администратор (scripts/bootstrap-admin.ts)')
      RETURNING id`);
    const invitationId = inv.rows[0]?.id;
    if (!invitationId) throw new Error('bootstrap-admin: INSERT user_invitations не вернул строку');
    await audit.write(
      ctx,
      {
        action: 'user.invited',
        entityType: 'user_invitation',
        entityId: invitationId,
        severity: 'warning',
        reason: 'first_admin_bootstrap',
        after: { phone, role: 'admin', expiresAt: expiresAt.toISOString(), fullName, source: 'bootstrap_cli' },
      },
      tx,
    );
    return { kind: 'created', invitationId, phoneMasked: maskPhone(phone), expiresAt };
  });
}

/** Техническая запись-автор (одна на систему): создаётся при первом запуске, затем переиспользуется. */
async function bootstrapInviter(tx: DbExecutor, audit: AuditService, ctx: AuditContext): Promise<string> {
  const found = await tx.execute<{ id: string }>(sql`
    SELECT u.id FROM users u JOIN user_profiles p ON p.user_id = u.id
     WHERE u.phone_e164 IS NULL AND u.kind = 'staff' AND u.status = 'deleted' AND p.full_name = ${BOOTSTRAP_INVITER_NAME}
     ORDER BY u.created_at LIMIT 1`);
  const existing = found.rows[0]?.id;
  if (existing) return existing;
  const ins = await tx.execute<{ id: string }>(sql`
    INSERT INTO users (phone_e164, kind, status, deleted_at, block_reason)
    VALUES (NULL, 'staff', 'deleted', now(), 'технический автор первичного приглашения; вход невозможен')
    RETURNING id`);
  const id = ins.rows[0]?.id;
  if (!id) throw new Error('bootstrap-admin: INSERT users не вернул строку');
  await tx.execute(sql`INSERT INTO user_profiles (user_id, full_name) VALUES (${id}::uuid, ${BOOTSTRAP_INVITER_NAME})`);
  await audit.write(
    ctx,
    {
      action: 'user.created',
      entityType: 'users',
      entityId: id,
      after: { kind: 'staff', status: 'deleted', purpose: 'bootstrap_inviter' },
    },
    tx,
  );
  return id;
}
