import { Injectable } from '@nestjs/common';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';

/** Порог сигнала скрейпинга (08 §4.5.4): поиск по телефону продавцом > 50 запросов в час. */
export const PHONE_LOOKUP_THRESHOLD = 50;
const WINDOW_MS = 3_600_000;

/**
 * Сигнал `customer.phone_lookup` (08 §4.5.4; 11 §7.2): продавец (`seller`, поиск без права на суммы) выполнил
 * более 50 поисков клиента по телефону за скользящий час — одна запись аудита `severity=warning` при пересечении
 * порога (повторно — не раньше, чем через час). Счётчик — в памяти процесса pos-api (сигнал, а не ограничение:
 * ограничение частоты — RL-SEARCH); телефон в аудит не пишется (11 SEC-062). G_spec_questions GQ-CUS-05.
 */
@Injectable()
export class PhoneLookupSignal {
  private readonly hits = new Map<string, number[]>();
  private readonly signalled = new Map<string, number>();

  constructor(private readonly audit: AuditService) {}

  async record(ctx: AuditContext, userId: string, now = Date.now()): Promise<boolean> {
    const from = now - WINDOW_MS;
    const list = (this.hits.get(userId) ?? []).filter((t) => t > from);
    list.push(now);
    this.hits.set(userId, list);
    if (this.hits.size > 10_000) this.prune(from);
    if (list.length <= PHONE_LOOKUP_THRESHOLD) return false;
    const last = this.signalled.get(userId);
    if (last !== undefined && last > from) return false;
    this.signalled.set(userId, now);
    await this.audit.write(ctx, {
      action: 'customer.phone_lookup',
      entityType: 'user',
      entityId: userId,
      after: { lookupsLastHour: list.length, threshold: PHONE_LOOKUP_THRESHOLD },
      severity: 'warning',
    });
    return true;
  }

  private prune(from: number): void {
    for (const [k, v] of this.hits) if (!v.some((t) => t > from)) this.hits.delete(k);
    for (const [k, t] of this.signalled) if (t <= from) this.signalled.delete(k);
  }
}
