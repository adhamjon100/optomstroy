import { Controller, Get, HttpCode, Param, Post, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import { isNotificationKind, type NotificationKind } from '../../common/enums.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import {
  NOTIFICATIONS_LIMIT_DEFAULT,
  NOTIFICATIONS_LIMIT_MAX,
  type NotificationsPage,
  NotificationsService,
} from './notifications.service.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_STORE = 'no-store';
const KIND_MAX_ITEMS = 50;

function invalid(field: string, rule: string, message: string): never {
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

function single(q: Record<string, unknown>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined || v === '') return undefined;
  if (typeof v !== 'string') invalid(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

/**
 * RFC 3339 `date-time` (OpenAPI `format: date-time`): смещение `Z` или `±hh:mm` обязательно. Без смещения `new Date`
 * трактует значение в поясе процесса (`TZ`, 16 §4.3) — граница `since`/`before` сдвигалась бы (ревью RC-7).
 */
const RFC3339_DATE_TIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/i;

/** Необязательный параметр «дата-время RFC 3339 со смещением» (`since`, `before`); иначе — 400 VALIDATION_FAILED. */
export function isoDateTime(q: Record<string, unknown>, name: string): string | undefined {
  const raw = single(q, name);
  if (raw === undefined) return undefined;
  const d = new Date(raw);
  if (!RFC3339_DATE_TIME_RE.test(raw) || Number.isNaN(d.getTime())) {
    invalid(
      name,
      'format',
      `${name} — дата-время ISO 8601 со смещением (Z или ±hh:mm), например 2026-10-23T10:00:00Z.`,
    );
  }
  return d.toISOString();
}

function subject(req: RequestWithContext): string {
  const p = req.principal;
  if (!p) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
  return p.userId;
}

/**
 * Центр уведомлений in-app (RM-F-008; D-41; 08 §4.16; SCR-44): `notifications.read.own` — все роли, только свои
 * уведомления (`integration` → 403 — права нет). `GET /notifications` — `Page<Notification>` + `unreadCount`;
 * `POST /notifications/{id}/read` и `/read-all` — `200 { unreadCount }`, повтор идемпотентен, `Idempotency-Key`
 * допускается. Чужое или несуществующее уведомление → `404 NOT_FOUND`. `Cache-Control: no-store`. Аудит не пишется.
 */
@Controller('notifications')
export class NotificationsController {
  constructor(private readonly service: NotificationsService) {}

  @Get()
  @RequirePermission('notifications.read.own')
  async list(
    @Req() req: RequestWithContext,
    @Query() q: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<NotificationsPage> {
    const unreadRaw = single(q, 'unread');
    let unreadOnly = false;
    if (unreadRaw !== undefined) {
      if (unreadRaw === 'true' || unreadRaw === '1') unreadOnly = true;
      else if (unreadRaw !== 'false' && unreadRaw !== '0') invalid('unread', 'type', 'unread — true или false.');
    }
    const kinds: NotificationKind[] = [];
    const kindRaw = single(q, 'kind');
    if (kindRaw !== undefined) {
      const parts = kindRaw.split(',').map((s) => s.trim());
      if (parts.length > KIND_MAX_ITEMS) invalid('kind', 'maxItems', `kind — не более ${KIND_MAX_ITEMS} значений.`);
      for (const k of parts) {
        if (!isNotificationKind(k)) invalid('kind', 'enum', `Неизвестный вид уведомления: ${k}.`);
        if (!kinds.includes(k)) kinds.push(k);
      }
    }
    const since = isoDateTime(q, 'since');
    const limitRaw = single(q, 'limit');
    let limit = NOTIFICATIONS_LIMIT_DEFAULT;
    if (limitRaw !== undefined) {
      if (!/^\d{1,6}$/.test(limitRaw)) invalid('limit', 'type', 'limit — целое число.');
      limit = Number(limitRaw); // money-double: allow — размер страницы, не деньги
      if (limit < 1) invalid('limit', 'minimum', 'limit — не меньше 1.');
      if (limit > NOTIFICATIONS_LIMIT_MAX) invalid('limit', 'maximum', `limit — не больше ${NOTIFICATIONS_LIMIT_MAX}.`);
    }
    const cursor = single(q, 'cursor');
    res.setHeader('Cache-Control', NO_STORE);
    return this.service.list(subject(req), {
      unreadOnly,
      kinds,
      limit,
      ...(since !== undefined ? { since } : {}),
      ...(cursor !== undefined ? { cursor } : {}),
    });
  }

  @Post('read-all')
  @HttpCode(200)
  @RequirePermission('notifications.read.own')
  @Idempotent({ required: false })
  async readAll(
    @Req() req: RequestWithContext,
    @Query() q: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ unreadCount: number }> {
    // `before` (OpenAPI 1.2.0; 08 §4.16.2 «Уточнения», FQ-NOTIF-04; 07 §11.2 notification.read): отметить только
    // уведомления, созданные не позже момента офлайн-действия. Без параметра — все непрочитанные.
    const before = isoDateTime(q, 'before');
    res.setHeader('Cache-Control', NO_STORE);
    return this.service.readAll(subject(req), before);
  }

  @Post(':id/read')
  @HttpCode(200)
  @RequirePermission('notifications.read.own')
  @Idempotent({ required: false })
  async read(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ unreadCount: number }> {
    res.setHeader('Cache-Control', NO_STORE);
    // Неверный формат id — тот же 404, что и чужое уведомление (существование не раскрывается).
    if (!UUID_RE.test(id)) throw new ProblemException('NOT_FOUND', { detail: 'Уведомление не найдено.' });
    return this.service.read(subject(req), id.toLowerCase());
  }
}
