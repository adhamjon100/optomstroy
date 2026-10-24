import { Controller, Get, Headers, Res } from '@nestjs/common';
import type { Response } from 'express';
import { RequirePermission } from '../common/rbac/rbac.decorators.js';
import { PublicSettingsService } from './public-settings.service.js';

/** `Cache-Control` ответа (08 §2.8, §4.23.1): частный кэш клиента 5 мин; переопределяет `no-store` по умолчанию. */
export const PUBLIC_SETTINGS_CACHE_CONTROL = 'private, max-age=300';

/** Совпадение `If-None-Match` (список, `*`, слабое сравнение — RFC 9110 §13.1.2). */
export function etagMatches(ifNoneMatch: string | undefined, etag: string): boolean {
  if (!ifNoneMatch) return false;
  const strip = (t: string) => t.trim().replace(/^W\//, '');
  const target = strip(etag);
  return ifNoneMatch.split(',').some((t) => t.trim() === '*' || strip(t) === target);
}

/**
 * `GET /settings/public` (RM-D-015; 08 §4.23.1, API-157): `settings.public.read` — все интерактивные роли и
 * пользователь `pending_activation` (псевдо-набор 11 §4.2); без Bearer → 401; `integration` → 403 (RbacGuard).
 * `ETag` + `Cache-Control: private, max-age=300`; `If-None-Match` → 304 без тела. Аудит не пишется.
 */
@Controller('settings')
export class PublicSettingsController {
  constructor(private readonly service: PublicSettingsService) {}

  @Get('public')
  @RequirePermission('settings.public.read')
  async get(@Headers('if-none-match') ifNoneMatch: string | undefined, @Res() res: Response): Promise<void> {
    const { body, etag } = await this.service.readWithEtag();
    res.setHeader('ETag', etag);
    res.setHeader('Cache-Control', PUBLIC_SETTINGS_CACHE_CONTROL);
    if (etagMatches(ifNoneMatch, etag)) {
      res.status(304).end();
      return;
    }
    res.status(200).json(body);
  }
}
