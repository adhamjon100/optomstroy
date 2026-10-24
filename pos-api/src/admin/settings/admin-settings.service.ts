import { Inject, Injectable, Logger } from '@nestjs/common';
import { formatVersionHeader, parsePlatformVersions } from '../../common/app-version/version-policy.js';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { principalOf } from '../users/shared/principal.js';
import { verifiedStepUp } from '../users/shared/step-up.guard.js';
import {
  ADMIN_SETTING_BY_FIELD,
  ADMIN_SETTING_KEYS,
  ADMIN_SETTINGS_ENV_FIELDS,
  type AdminSettingKey,
  checkSettingValue,
} from './admin-settings.map.js';
import type { AdminSettingsUpdateDto } from './admin-settings.dto.js';
import { type AppSettingRow, AdminSettingsRepository } from './admin-settings.repository.js';

/** `AdminSettingsResponse` (08 §4.18.6). */
export interface AdminSettingsResponse {
  readonly settings: Record<string, unknown>;
  readonly env: Record<string, unknown>;
  readonly rowVersion: number;
}

type EnvConfig = Pick<
  AppConfig,
  | 'CUSTOMER_SELF_SERVICE'
  | 'DEBT_PAYMENTS_FROM_POS'
  | 'QR_PROVIDER'
  | 'QR_TTL_MINUTES'
  | 'QR_ONEC_POLL_SECONDS'
  | 'RECEIVABLES_MAX_AGE_MIN'
  | 'MIN_APP_VERSION'
  | 'RECOMMENDED_APP_VERSION'
  | 'OTP_TTL_SECONDS'
  | 'OTP_RESEND_COOLDOWN_SECONDS'
  | 'OTP_MAX_VERIFY_ATTEMPTS'
  | 'OTP_GLOBAL_PER_MIN'
  | 'OTP_LOCK_AFTER_LOCKED_CODES'
  | 'OTP_PHONE_PAUSE_MINUTES'
  | 'SESSION_IDLE_LOCK_MINUTES'
  | 'AUTH_BACKGROUND_LOCK_MINUTES'
  | 'SMSPRO_SENDER'
>;

interface Change {
  readonly def: AdminSettingKey;
  readonly value: unknown;
}

type FieldError = ProblemFieldError & { readonly status: 400 | 422 };

const ALL_KEYS = ADMIN_SETTING_KEYS.map((k) => k.key);
const ENV_FIELDS: ReadonlySet<string> = new Set(ADMIN_SETTINGS_ENV_FIELDS);

/** Канонический JSON (ключи объектов по алфавиту): сравнение значения jsonb с телом запроса. */
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v !== null && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(v ?? null);
}

function versions(raw: string | undefined): string | null {
  if (raw === undefined || raw.trim() === '') return null;
  return formatVersionHeader(parsePlatformVersions(raw), undefined) ?? null;
}

function rowVersionOf(rows: readonly AppSettingRow[]): number {
  return rows.reduce((s, r) => s + r.rowVersion, 0);
}

/**
 * Настройки системы `GET/PUT /admin/settings` (08 §4.18.6, API-117, API-164; ядро §19.2; RM-D-015 п. 2).
 *
 * - `settings` — ключи `app_settings` по таблице соответствия (admin-settings.map.ts); в ответе — ключи, у которых
 *   задано значение (JSON `null` у ненулевого по схеме поля = «не задано, действует env» — поле не выводится).
 * - `env` — значения переменных окружения только для чтения; секреты не отдаются.
 * - `rowVersion` — сумма `app_settings.row_version` ключей таблицы: каждое изменение строки (+1) и новая строка
 *   (+1) её увеличивают, поэтому устаревшая версия всегда обнаруживается (409 VERSION_CONFLICT).
 * - PUT: схема (400 `type`/`unknown_setting`/`read_only_setting`) → диапазоны и перечни (422) → транзакция с
 *   advisory-lock: тело без изменений → 200 без проверки версии (повтор), иначе сверка `rowVersion`, запись строк,
 *   аудит `settings.changed` по ключам (before/after, метод step-up), после COMMIT — сброс кэша SettingsReader
 *   (изменение действует без перезапуска: `/settings/public`, заголовки версий).
 */
@Injectable()
export class AdminSettingsService {
  private readonly logger = new Logger('AdminSettings');

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(APP_CONFIG) private readonly config: EnvConfig,
    private readonly repo: AdminSettingsRepository,
    private readonly reader: SettingsReader,
    private readonly audit: AuditService,
  ) {}

  async get(): Promise<AdminSettingsResponse> {
    return this.view(await this.repo.load(ALL_KEYS));
  }

  async update(req: RequestWithContext, body: AdminSettingsUpdateDto): Promise<AdminSettingsResponse> {
    const actor = principalOf(req);
    const changes = this.validate(body.settings);
    const ctx = auditContextFromRequest(req);
    const result = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      await this.repo.lock(tx);
      const rows = await this.repo.load(ALL_KEYS, tx);
      const byKey = new Map(rows.map((r) => [r.key, r]));
      const diff = changes.filter((c) => {
        const row = byKey.get(c.def.key);
        return row === undefined || canonical(row.value) !== canonical(c.value);
      });
      if (diff.length === 0) return { rows, changed: [] as string[] };
      const current = rowVersionOf(rows);
      if (body.rowVersion !== current) {
        throw new ProblemException('VERSION_CONFLICT', {
          detail: 'Настройки изменились. Обновите экран и повторите.',
          current: { rowVersion: current },
        });
      }
      const before: Record<string, unknown> = {};
      const after: Record<string, unknown> = {};
      for (const c of diff) {
        const row = byKey.get(c.def.key);
        before[c.def.apiField] = row?.value ?? null;
        after[c.def.apiField] = c.value;
        if (row) await this.repo.update(c.def.key, c.value, actor.userId, tx);
        else await this.repo.insert({ ...c.def, value: c.value }, actor.userId, tx);
      }
      await this.audit.write(
        ctx,
        {
          action: 'settings.changed',
          entityType: 'app_settings',
          before,
          after,
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
          // 11 SEC-076 требует причину для `settings.changed`, а `AdminSettingsUpdateRequest` поля `reason` не
          // содержит (additionalProperties: false) — причина формируется сервером из перечня ключей.
          reason: `Изменение настроек системы (SCR-46): ${diff.map((c) => c.def.apiField).join(', ')}`.slice(0, 500),
        },
        tx,
      );
      return { rows: await this.repo.load(ALL_KEYS, tx), changed: diff.map((c) => c.def.key) };
    });
    for (const key of result.changed) this.reader.invalidate(key);
    return this.view(result.rows);
  }

  /** Проверка тела по таблице соответствия: все ошибки сразу; 400 (схема) важнее 422 (значения). */
  private validate(settings: Record<string, unknown>): Change[] {
    const errors: FieldError[] = [];
    const changes: Change[] = [];
    for (const [field, value] of Object.entries(settings)) {
      const def = ADMIN_SETTING_BY_FIELD.get(field);
      const path = `settings.${field}`;
      if (!def) {
        errors.push(
          ENV_FIELDS.has(field)
            ? { status: 400, field: path, rule: 'read_only_setting', message: 'Значение задаётся только на сервере' }
            : { status: 400, field: path, rule: 'unknown_setting', message: 'Неизвестная настройка' },
        );
        continue;
      }
      const c = checkSettingValue(def.rule, value);
      if (c.ok) changes.push({ def, value: c.value });
      else errors.push({ status: c.status, field: path, rule: c.rule, message: c.message });
    }
    if (errors.length > 0) {
      const status = errors.some((e) => e.status === 400) ? 400 : 422;
      throw new ProblemException('VALIDATION_FAILED', {
        status,
        detail: 'Настройки не прошли проверку.',
        errors: errors.filter((e) => e.status === status).map(({ field, message, rule }) => ({ field, message, rule })),
      });
    }
    return changes;
  }

  private view(rows: readonly AppSettingRow[]): AdminSettingsResponse {
    const byKey = new Map(rows.map((r) => [r.key, r]));
    const settings: Record<string, unknown> = {};
    for (const def of ADMIN_SETTING_KEYS) {
      const row = byKey.get(def.key);
      if (!row) continue;
      const c = checkSettingValue(def.rule, row.value);
      if (c.ok) settings[def.apiField] = c.value;
      else if (row.value !== null) {
        this.logger.warn(
          { event: 'admin.settings.invalid_value', key: def.key, rule: c.rule },
          'invalid app_settings value',
        );
      }
    }
    return { settings, env: this.env(), rowVersion: rowVersionOf(rows) };
  }

  private env(): Record<string, unknown> {
    const c = this.config;
    return {
      customerSelfService: c.CUSTOMER_SELF_SERVICE,
      debtPaymentsFromPos: c.DEBT_PAYMENTS_FROM_POS,
      qrProvider: c.QR_PROVIDER,
      qrTtlMinutes: c.QR_TTL_MINUTES,
      qrOnecPollSeconds: c.QR_ONEC_POLL_SECONDS,
      receivablesMaxAgeMin: c.RECEIVABLES_MAX_AGE_MIN,
      minAppVersion: versions(c.MIN_APP_VERSION) ?? c.MIN_APP_VERSION,
      recommendedAppVersion: versions(c.RECOMMENDED_APP_VERSION),
      otpTtlSeconds: c.OTP_TTL_SECONDS,
      otpResendCooldownSeconds: c.OTP_RESEND_COOLDOWN_SECONDS,
      otpMaxVerifyAttempts: c.OTP_MAX_VERIFY_ATTEMPTS,
      otpGlobalPerMin: c.OTP_GLOBAL_PER_MIN,
      otpLockAfterLockedCodes: c.OTP_LOCK_AFTER_LOCKED_CODES,
      otpPhonePauseMinutes: c.OTP_PHONE_PAUSE_MINUTES,
      sessionIdleLockMinutes: c.SESSION_IDLE_LOCK_MINUTES,
      authBackgroundLockMinutes: c.AUTH_BACKGROUND_LOCK_MINUTES,
      ...(c.SMSPRO_SENDER !== undefined && c.SMSPRO_SENDER.trim() !== '' ? { smsSenderName: c.SMSPRO_SENDER } : {}),
    };
  }
}
