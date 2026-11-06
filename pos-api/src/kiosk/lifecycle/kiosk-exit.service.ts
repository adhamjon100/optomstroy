import { Inject, Injectable, Logger } from '@nestjs/common';
import { principalOf } from '../../admin/users/shared/principal.js';
import { requestIdOf, type AuthHttpRequest } from '../../auth/common/request.js';
import { OtpChallengesRepository } from '../../auth/otp/otp-challenges.repository.js';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache, KIOSK_REVOKED_REASON } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { EXIT_CODE_FORMAT, ExitCodeHasher } from '../../common/crypto/exit-code-hasher.service.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import type { KioskTabletContext } from '../common/kiosk-tablet.reader.js';
import { StoreTabletsRepository } from './store-tablets.repository.js';

/** Неверных аварийных кодов подряд до паузы (07 §5.65; 08 §2.9 RL-PIN; 11 SEC-140). */
export const KIOSK_EXIT_MAX_ATTEMPTS = 5;
/** Пауза аварийного выхода после 5 неверных кодов — 15 мин (`store_tablets.exit_locked_until`). */
export const KIOSK_EXIT_LOCK_MS = 15 * 60_000;

/** Тело `POST /kiosk/exit` после проверки (OpenAPI `KioskExitRequest`). */
export interface KioskExitBody {
  /** Аварийный код — ровно 8 цифр; в логи, аудит и ответы не попадает (11 SEC-140 п. 6). */
  readonly code: string;
}

const BODY_FIELDS: ReadonlySet<string> = new Set(['code']);

function invalid(errors: readonly ProblemFieldError[]): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status: 400, detail: 'Запрос не прошёл проверку.', errors });
}

/**
 * Разбор тела `POST /kiosk/exit` (08 §4.25.5): `{ "code": "12345678" }` — ровно 8 цифр (иное → `400 VALIDATION_FAILED`
 * rule `exit_code_format`); иные поля → `forbidden_field`; не объект → `body:type`. Значение кода в ошибку не
 * копируется.
 */
export function parseKioskExitBody(raw: unknown): KioskExitBody {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw invalid([{ field: 'body', rule: 'type', message: 'Ожидается объект JSON' }]);
  }
  const body = raw as Record<string, unknown>;
  const errors: ProblemFieldError[] = [];
  for (const k of Object.keys(body)) {
    if (!BODY_FIELDS.has(k)) errors.push({ field: k, rule: 'forbidden_field', message: 'Поле не принимается' });
  }
  const code = body.code;
  if (typeof code !== 'string' || !EXIT_CODE_FORMAT.test(code)) {
    errors.push({ field: 'code', rule: 'exit_code_format', message: 'Аварийный код — 8 цифр' });
  }
  if (errors.length > 0) throw invalid(errors);
  return { code: code as string };
}

/** Итог транзакции выхода; ошибки бросаются после COMMIT — счётчик попыток и пауза сохраняются (как PIN, 09 §9.6). */
type ExitOutcome =
  | { readonly kind: 'ok'; readonly userId: string; readonly revokedSessions: readonly string[] }
  | { readonly kind: 'invalid'; readonly attemptsLeft: number }
  | { readonly kind: 'locked'; readonly until: Date; readonly now: boolean }
  | { readonly kind: 'revoked'; readonly kiosk: boolean };

/**
 * Аварийный выход планшета магазина со связью — `POST /kiosk/exit {code}` (08 §4.25.5; 09 §8.9 п. 4–5; 07 §5.65;
 * 10 KIOSK-004; 11 SEC-139, SEC-140; ADR-115 п. 28; P-002 §8.9 п. 2). Одна транзакция на попытку под блокировкой строки
 * `store_tablets` (параллельные попытки одного планшета идут по очереди — счётчик не обойти):
 * 1. пауза действует (`exit_locked_until > now`) → `423 KIOSK_EXIT_LOCKED {retryAfter}` — и с верным кодом;
 * 2. код сверяется с `exit_code_hash` (`Argon2id(pepper ‖ код ‖ tablet_id)`, `ExitCodeHasher`); уже использованный
 *    (`exit_code_used_at`) или прежний (заменён подключением заново) код — неверный;
 * 3. неверный → `exit_failed_attempts + 1` (после истёкшей паузы счёт идёт заново): 1-я…4-я —
 *    `422 KIOSK_EXIT_CODE_INVALID {attemptsLeft}`, 5-я — пауза 15 мин и `423 KIOSK_EXIT_LOCKED`;
 * 4. верный → код погашен (`exit_code_used_at`), попытки сброшены, строка → `revoked` (`revoked_by_user_id = NULL`,
 *    `revoke_reason='kiosk.exit_code_used'`), все сессии технического пользователя → `kiosk_revoked`, коды
 *    `kiosk_order` планшета гасятся, аудит `kiosk.exit_code_used`; после COMMIT — сброс кэша AuthGuard. Свой access
 *    `jti` в denylist не заносится: повтор после потерянного `200` получает `401 KIOSK_REVOKED` из снимка сессии,
 *    а не `SESSION_REVOKED` из denylist (08 §4.25.5 «Идемпотентность»).
 * `KIOSK_MODE=false` и адрес вне `KIOSK_ALLOWED_CIDRS` отклоняет раньше `KioskAccessGuard` (403 — приложение тогда
 * проверяет код на устройстве). Код не пишется в логи, аудит и ответы; неверные попытки — только счётчик строки.
 */
@Injectable()
export class KioskExitService {
  private readonly logger = new Logger('kiosk');
  /**
   * Погашение кодов `kiosk_order` планшета (`gashKioskCodes`) — экземпляр внутри сервиса, не провайдер модуля: второй
   * провайдер с тем же токеном подменил бы экземпляр модуля `auth` (как в `StoreTabletsService`).
   */
  private readonly otpChallenges: OtpChallengesRepository;

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: StoreTabletsRepository,
    private readonly hasher: ExitCodeHasher,
    private readonly sessions: SessionsRepository,
    private readonly audit: AuditService,
    private readonly authState: AuthStateCache,
  ) {
    this.otpChallenges = new OtpChallengesRepository(db);
  }

  async exit(req: AuthHttpRequest, tablet: KioskTabletContext, body: KioskExitBody): Promise<void> {
    const principal = principalOf(req);
    const ctx = auditContextFromRequest(req);
    const requestId = requestIdOf(req);
    const now = this.clock.now();
    const outcome = await this.db.transaction(async (tx): Promise<ExitOutcome> => {
      await applyAuditGucs(tx, ctx);
      // Порядок блокировок — строка планшета, затем его сессии (как отключение и подключение заново).
      const row = await this.repo.lock(tablet.tabletId, tx);
      const session = await this.sessions.lockById(principal.sessionId, tx);
      if (
        !row ||
        row.userId !== principal.userId ||
        row.status !== 'active' ||
        !session ||
        session.userId !== principal.userId ||
        session.revokedAt !== null
      ) {
        // Гонка с отключением, другим выходом или подключением заново: сессия уже отозвана.
        return {
          kind: 'revoked',
          kiosk: row?.status === 'revoked' || session?.revokeReason === KIOSK_REVOKED_REASON,
        };
      }
      if (row.exitLockedUntil !== null && row.exitLockedUntil.getTime() > now.getTime()) {
        return { kind: 'locked', until: row.exitLockedUntil, now: false };
      }
      const check = await this.hasher.verify(body.code, row.id, row.exitCodeHash, row.exitCodePepperVersion);
      if (!check.ok || row.exitCodeUsedAt !== null) {
        // Пауза истекла — новая серия из 5 попыток (07 §5.65: «5 неверных подряд»).
        const before = row.exitLockedUntil !== null ? 0 : row.exitFailedAttempts;
        const attempts = before + 1;
        if (attempts >= KIOSK_EXIT_MAX_ATTEMPTS) {
          const until = new Date(now.getTime() + KIOSK_EXIT_LOCK_MS);
          await this.repo.recordExitFailure(row.id, attempts, until, now, tx);
          return { kind: 'locked', until, now: true };
        }
        await this.repo.recordExitFailure(row.id, attempts, null, now, tx);
        return { kind: 'invalid', attemptsLeft: KIOSK_EXIT_MAX_ATTEMPTS - attempts };
      }
      if (!(await this.repo.markExitUsed(row.id, now, tx))) return { kind: 'revoked', kiosk: true };
      const revokedSessions = await this.sessions.revokeAllForUser(row.userId, 'kiosk_revoked', {}, tx);
      const codes = await this.otpChallenges.gashKioskCodes(tx, row.id, now);
      await this.audit.write(
        ctx,
        {
          action: 'kiosk.exit_code_used',
          entityType: 'store_tablet',
          entityId: row.id,
          before: { status: 'active' },
          after: {
            tabletId: row.id,
            status: 'revoked',
            exitCodeUsedAt: now.toISOString(),
            revokedSessions: revokedSessions.length,
            gashedKioskCodes: codes.superseded + codes.replayed,
          },
        },
        tx,
      );
      return { kind: 'ok', userId: row.userId, revokedSessions };
    });

    switch (outcome.kind) {
      case 'ok':
        // Сессии технического пользователя недействительны в этом процессе сразу (08 §2.2; 11 SEC-139).
        this.authState.invalidateUser(outcome.userId);
        for (const sid of outcome.revokedSessions) this.authState.invalidateSession(sid);
        this.logger.log(
          {
            event: 'kiosk.exit_code_used',
            requestId,
            tabletId: tablet.tabletId,
            revokedSessions: outcome.revokedSessions.length,
          },
          'kiosk.exit_code_used',
        );
        return;
      case 'invalid':
        this.logger.warn(
          {
            event: 'kiosk.exit_code_invalid',
            requestId,
            tabletId: tablet.tabletId,
            attemptsLeft: outcome.attemptsLeft,
          },
          'kiosk.exit_code_invalid',
        );
        throw new ProblemException('KIOSK_EXIT_CODE_INVALID', {
          detail: `Неверный аварийный код. Осталось попыток: ${outcome.attemptsLeft}.`,
          attemptsLeft: outcome.attemptsLeft,
        });
      case 'locked': {
        const retryAfter = Math.max(1, Math.ceil((outcome.until.getTime() - now.getTime()) / 1000));
        if (outcome.now) {
          this.logger.warn(
            { event: 'kiosk.exit_locked', requestId, tabletId: tablet.tabletId, retryAfter },
            'kiosk.exit_locked',
          );
        }
        throw new ProblemException('KIOSK_EXIT_LOCKED', {
          detail: 'Аварийный выход временно заблокирован: 5 неверных кодов подряд. Попробуйте позже.',
          retryAfter,
        });
      }
      case 'revoked':
        throw outcome.kiosk
          ? new ProblemException('KIOSK_REVOKED', { detail: 'Планшет отключён администратором.' })
          : new ProblemException('SESSION_REVOKED', { detail: 'Сессия завершена. Войдите снова.' });
    }
  }
}
