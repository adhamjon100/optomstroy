import { Injectable, Logger, type NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { API_PREFIX } from '../http/route-template.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { AppVersionPolicy } from './app-version.policy.js';
import {
  type ClientPlatform,
  formatVersionHeader,
  isBelowMinimum,
  isClientPlatform,
  parseSemVer,
} from './version-policy.js';

export const APP_VERSION_HEADER = 'X-App-Version';
export const PLATFORM_HEADER = 'X-Platform';
export const MIN_APP_VERSION_HEADER = 'X-Min-App-Version';
export const RECOMMENDED_APP_VERSION_HEADER = 'X-Recommended-App-Version';

/** Пути без проверки версии (RM-C-015; 08 §2.3, §2.11): `/health*`, `/openapi.json`, вебхук банка, входящий обмен 1С. */
export function isVersionCheckExempt(path: string): boolean {
  return (
    path === '/health' ||
    path.startsWith('/health/') ||
    path === '/openapi.json' ||
    path === `${API_PREFIX}/openapi.json` ||
    path === `${API_PREFIX}/payments/qr/webhook` ||
    path.startsWith(`${API_PREFIX}/integrations/`)
  );
}

/**
 * Контроль версии клиента (RM-C-015, D-46): заголовки `X-Min-App-Version` / `X-Recommended-App-Version`
 * добавляются к каждому ответу (для платформы из `X-Platform`, без неё — все платформы); версия ниже минимальной →
 * `426 APP_UPDATE_REQUIRED` до аутентификации (приоритет 426 над 401, 08 §2.4). В R1 — мягкий режим:
 * без заголовков запрос принимается с предупреждением в логе (Q-153).
 */
@Injectable()
export class AppVersionMiddleware implements NestMiddleware {
  private readonly logger = new Logger('app-version');

  constructor(private readonly policy: AppVersionPolicy) {}

  use(req: Request & { id?: string }, res: Response, next: NextFunction): void {
    const path = (req.originalUrl ?? req.url).split('?')[0] ?? '/';
    const platformRaw = req.header(PLATFORM_HEADER)?.trim().toLowerCase();
    const platform: ClientPlatform | undefined = isClientPlatform(platformRaw) ? platformRaw : undefined;
    const snap = this.policy.snapshot();

    const minHeader = formatVersionHeader(snap.min, platform);
    if (minHeader !== undefined) res.setHeader(MIN_APP_VERSION_HEADER, minHeader);
    const recHeader = formatVersionHeader(snap.recommended, platform);
    if (recHeader !== undefined) res.setHeader(RECOMMENDED_APP_VERSION_HEADER, recHeader);

    if (isVersionCheckExempt(path)) return next();

    if (platformRaw !== undefined && platformRaw !== '' && platform === undefined) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Неизвестная платформа клиента.',
        errors: [{ field: PLATFORM_HEADER, message: 'Допустимо: android, windows, ios', rule: 'platform' }],
      });
    }
    const versionRaw = req.header(APP_VERSION_HEADER)?.trim();
    if (!versionRaw || platform === undefined) {
      this.logger.warn({ event: 'app_version.missing', requestId: req.id, path }, 'app_version.missing');
      return next();
    }
    const version = parseSemVer(versionRaw);
    if (version === null) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Некорректная версия приложения.',
        errors: [
          { field: APP_VERSION_HEADER, message: 'Ожидается семантическая версия, например 1.4.2+87', rule: 'semver' },
        ],
      });
    }
    if (isBelowMinimum(snap.min, platform, version)) {
      const minVersion = snap.min[platform] ?? '';
      const storeUrl = snap.storeUrls[platform];
      throw new ProblemException('APP_UPDATE_REQUIRED', {
        detail: 'Версия приложения устарела. Обновите приложение, чтобы продолжить работу.',
        minVersion,
        ...(storeUrl !== undefined ? { storeUrl } : {}),
        headers: { [MIN_APP_VERSION_HEADER]: `${platform}=${minVersion}` },
      });
    }
    next();
  }
}
