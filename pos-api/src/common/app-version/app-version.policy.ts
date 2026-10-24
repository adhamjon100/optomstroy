import { Inject, Injectable, Logger } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { SettingsReader } from '../settings/settings-reader.js';
import {
  CLIENT_PLATFORMS,
  type ClientPlatform,
  parsePlatformVersions,
  parseSemVer,
  type PlatformVersions,
  VersionListFormatError,
} from './version-policy.js';

export const MIN_APP_VERSION_SETTING = 'min_app_version';
export const RECOMMENDED_APP_VERSION_SETTING = 'recommended_app_version';
/**
 * Ссылка на обновление по платформам для поля `storeUrl` тела 426 (08 §2.4; ревью C-MJ-08):
 * `{ "android": "https://play.google.com/…", "windows": "https://…" }`. Ключ `app_settings` `[НОВОЕ ИМЯ —
 * предложение, Q-153 (канал раздачи сборок Windows)]`: по умолчанию не создаётся (seed — ровно ключи R0 §17.7), правит
 * `admin`; пока ключа нет, `storeUrl` в 426 не передаётся, клиент SCR-90 показывает инструкцию без кнопки-ссылки.
 */
export const APP_STORE_URL_SETTING = 'app_store_url';

export interface VersionPolicySnapshot {
  readonly min: PlatformVersions;
  readonly recommended: PlatformVersions;
  readonly storeUrls: Partial<Record<ClientPlatform, string>>;
}

/**
 * Источник версий (08 §2.11; ядро §18.2 п. 12): `app_settings.min_app_version` / `recommended_app_version`,
 * если заданы и валидны, иначе env `MIN_APP_VERSION` / `RECOMMENDED_APP_VERSION`. Чтение настроек —
 * через SettingsReader (кэш TTL), поэтому изменение действует без перезапуска API.
 * Формат значения настройки: строка `platform=semver,…` или объект `{ "android": "1.2.0", … }`.
 */
@Injectable()
export class AppVersionPolicy {
  private readonly logger = new Logger('AppVersionPolicy');
  private readonly envMin: PlatformVersions;
  private readonly envRecommended: PlatformVersions;
  private readonly warned = new Set<string>();

  constructor(
    @Inject(APP_CONFIG) config: Pick<AppConfig, 'MIN_APP_VERSION' | 'RECOMMENDED_APP_VERSION'>,
    private readonly settings: SettingsReader,
  ) {
    this.envMin = parsePlatformVersions(config.MIN_APP_VERSION);
    this.envRecommended = parsePlatformVersions(config.RECOMMENDED_APP_VERSION ?? '');
  }

  /** Неблокирующий снимок (значения из кэша; устаревший кэш обновляется в фоне). */
  snapshot(): VersionPolicySnapshot {
    return {
      min: this.coerce(MIN_APP_VERSION_SETTING, this.settings.peek(MIN_APP_VERSION_SETTING)) ?? this.envMin,
      recommended:
        this.coerce(RECOMMENDED_APP_VERSION_SETTING, this.settings.peek(RECOMMENDED_APP_VERSION_SETTING)) ??
        this.envRecommended,
      storeUrls: this.coerceStoreUrls(this.settings.peek(APP_STORE_URL_SETTING)),
    };
  }

  /** Только https-ссылки известных платформ; неверное значение игнорируется с предупреждением. */
  private coerceStoreUrls(raw: unknown): Partial<Record<ClientPlatform, string>> {
    if (raw === undefined || raw === null || raw === '') return {};
    const out: Partial<Record<ClientPlatform, string>> = {};
    if (typeof raw === 'object' && !Array.isArray(raw)) {
      for (const p of CLIENT_PLATFORMS) {
        const v = (raw as Record<string, unknown>)[p];
        if (typeof v === 'string' && /^https:\/\/\S+$/.test(v)) out[p] = v;
      }
      return out;
    }
    if (!this.warned.has(APP_STORE_URL_SETTING)) {
      this.warned.add(APP_STORE_URL_SETTING);
      this.logger.warn({ key: APP_STORE_URL_SETTING }, 'invalid app_settings value, storeUrl omitted');
    }
    return out;
  }

  /** Принудительная загрузка настроек (тесты, прогрев при старте). */
  async refresh(): Promise<VersionPolicySnapshot> {
    await Promise.all([
      this.settings.get(MIN_APP_VERSION_SETTING),
      this.settings.get(RECOMMENDED_APP_VERSION_SETTING),
      this.settings.get(APP_STORE_URL_SETTING),
    ]);
    return this.snapshot();
  }

  private coerce(key: string, raw: unknown): PlatformVersions | undefined {
    if (raw === undefined || raw === null || raw === '') return undefined;
    try {
      if (typeof raw === 'string') return parsePlatformVersions(raw);
      if (typeof raw === 'object' && !Array.isArray(raw)) {
        const out: Partial<Record<ClientPlatform, string>> = {};
        for (const p of CLIENT_PLATFORMS) {
          const v = (raw as Record<string, unknown>)[p];
          if (v === undefined) continue;
          if (typeof v !== 'string' || parseSemVer(v) === null) throw new VersionListFormatError(`${p}: не semver`);
          out[p] = v;
        }
        return out;
      }
      throw new VersionListFormatError('ожидается строка platform=semver или объект');
    } catch (e) {
      if (!this.warned.has(key)) {
        this.warned.add(key);
        this.logger.warn(
          { key, reason: e instanceof Error ? e.message : 'invalid' },
          'invalid app_settings value, env fallback',
        );
      }
      return undefined;
    }
  }
}
