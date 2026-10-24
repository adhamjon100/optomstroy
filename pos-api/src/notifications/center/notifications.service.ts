import { Injectable } from '@nestjs/common';
import { CatalogCursorCodec } from '../../catalog/common/catalog-cursor.js';
import type { NotificationKind } from '../../common/enums.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { type NotificationRow, NotificationsRepository } from './notifications.repository.js';

/**
 * Центр уведомлений in-app (RM-F-008; D-41; 08 §4.16): список своих уведомлений с курсором (keyset по
 * `created_at DESC, id DESC`), фильтры `unread`, `kind`, `since`, счётчик непрочитанных для бейджа колокольчика;
 * отметка одного и всех прочитанными — идемпотентно (повтор → тот же ответ с текущим `unreadCount`).
 */
export const NOTIFICATIONS_LIMIT_DEFAULT = 50;
export const NOTIFICATIONS_LIMIT_MAX = 100;
/** Код «сортировки» курсора списка уведомлений (курсор другого списка → `cursor_sort_mismatch`). */
const CURSOR_SORT = 'notifications_created_desc';

export interface NotificationDto {
  readonly id: string;
  readonly kind: NotificationKind;
  readonly title: string;
  readonly body: string;
  readonly payload: Record<string, unknown>;
  readonly createdAt: string;
  readonly readAt: string | null;
  readonly severity: 'info' | 'warning' | 'error';
}

export interface NotificationsPage {
  readonly items: NotificationDto[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly unreadCount: number; // money-double: allow — счётчик уведомлений, не деньги
}

export interface ListQuery {
  readonly unreadOnly: boolean;
  readonly kinds: readonly NotificationKind[];
  readonly since?: string;
  readonly limit: number; // money-double: allow — размер страницы, не деньги
  readonly cursor?: string;
}

function iso(ts: string): string {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts : d.toISOString();
}

function toDto(r: NotificationRow): NotificationDto {
  return {
    id: r.id,
    kind: r.kind,
    title: r.title,
    body: r.body,
    payload: r.payload,
    createdAt: iso(r.createdAt),
    readAt: r.readAt === null ? null : iso(r.readAt),
    severity: r.severity,
  };
}

@Injectable()
export class NotificationsService {
  constructor(
    private readonly repo: NotificationsRepository,
    private readonly cursors: CatalogCursorCodec,
  ) {}

  async list(userId: string, q: ListQuery): Promise<NotificationsPage> {
    const after = q.cursor !== undefined ? this.cursors.decode(q.cursor, CURSOR_SORT) : undefined;
    const rows = await this.repo.list(userId, {
      unreadOnly: q.unreadOnly,
      kinds: q.kinds,
      limit: q.limit,
      ...(q.since !== undefined ? { since: q.since } : {}),
      ...(after && after.s !== null ? { after: { createdAt: after.s, id: after.id } } : {}),
    });
    const hasMore = rows.length > q.limit;
    const page = rows.slice(0, q.limit);
    const last = page[page.length - 1];
    return {
      items: page.map(toDto),
      nextCursor: hasMore && last ? this.cursors.encode({ o: CURSOR_SORT, s: last.createdAt, id: last.id }) : null,
      hasMore,
      unreadCount: await this.repo.unreadCount(userId),
    };
  }

  async read(userId: string, id: string): Promise<{ unreadCount: number }> {
    const found = await this.repo.markRead(userId, id);
    if (!found) throw new ProblemException('NOT_FOUND', { detail: 'Уведомление не найдено.' });
    return { unreadCount: await this.repo.unreadCount(userId) };
  }

  /** `before` — ISO-момент: отмечаются только уведомления с `created_at <= before` (08 §4.16.2, OpenAPI 1.2.0). */
  async readAll(userId: string, before?: string): Promise<{ unreadCount: number }> {
    await this.repo.markAllRead(userId, before);
    return { unreadCount: await this.repo.unreadCount(userId) };
  }
}
