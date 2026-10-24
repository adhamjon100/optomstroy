import { Inject, Injectable } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { UsersRepository } from '../../users/users.repository.js';
import {
  CUSTOMER_MATCHING,
  type CustomerMatching,
  type CustomerMatchResult,
  KG_E164,
} from '../matching/customer-matching.port.js';
import {
  cardPhones,
  type CustomerLinkDto,
  customerDisplayName,
  isPhoneVerified,
  maskCustomerName,
  toCustomerLinkDto,
  type UserBrief,
  userBrief,
} from './customer-link.presenter.js';
import {
  type CustomerCardRow,
  type CustomerLinkRow,
  CustomerLinksRepository,
  type LinkUserInfo,
} from './customer-links.repository.js';
import { LinkConflictNotifier } from './link-conflict.notifier.js';
import { CUSTOMER_SELF_SERVICE_FLAG, type SelfServiceFlag } from './self-service.flag.js';
import type { VerifiedStepUp } from './step-up.verifier.js';

export type MatchStatus = 'none' | 'proposed' | 'confirmed' | 'rejected' | 'conflict';
export type MatchNextStep = 'confirm_or_reject' | 'wait_admin' | 'confirmed' | 'none';

/** `customerMatch` ответа `POST /registration/complete` (08 §4.2.1, `RegistrationCustomerMatchSummary`). */
export interface CustomerMatchSummary {
  readonly status: 'none' | 'proposed' | 'confirmed' | 'conflict';
  readonly linkId: string | null;
  readonly nextStep: MatchNextStep;
}

/** `RegistrationCustomerMatch` (08 §4.2.2, §4.2.4): до `confirmed` — только маскированное имя, без финансов. */
export interface RegistrationCustomerMatchDto {
  readonly status: MatchStatus;
  readonly linkId: string | null;
  readonly customer: { displayNameMasked: string } | { id: string; displayName: string } | null;
  readonly nextStep: MatchNextStep;
}

export interface CustomerLinkWithUserDto extends CustomerLinkDto {
  readonly user: UserBrief;
}

/** Причины, по которым клиент не может решить привязку сам (11 SEC-130) — значение `reason` в 409. */
export type SelfResolveBlocker =
  | 'conflict'
  | 'phone_changed'
  | 'card_missing'
  | 'legal_entity'
  | 'secondary_contact'
  | 'phone_not_verified'
  | 'already_linked'
  | 'other_link_confirmed';

export const LINK_RESOLVE_OPERATION = 'customer.link.resolve';
export const QUEUE_DEFAULT_LIMIT = 50;
export const QUEUE_MAX_LIMIT = 200;
/** Минимальная длина причины решения при `conflict` (11 §7.2 «обязательная причина — да (при conflict)», SEC-076). */
export const CONFLICT_REASON_MIN = 5;

export interface AdminResolveBody {
  readonly comment?: string;
  readonly force?: boolean;
}

/**
 * Привязка аккаунта клиента к карточке 1С (RM-D-005; 09 §7.8–§7.9; 08 §4.2.2, §4.2.4, §4.11.1, §4.11.7;
 * 11 коды 32, 61, 67, 73, 75, SEC-030, SEC-130; ядро §22.12, §24.2).
 *
 * Автомат: `[*] → proposed` (1 карточка) | `conflict` (≥ 2) → `confirmed` | `rejected`. Самоподтверждение — только
 * своя `proposed`-привязка при выполнении SEC-130 и `CUSTOMER_SELF_SERVICE=true`; остальное решает `admin` со
 * step-up. Каждое решение — одна транзакция READ COMMITTED: `applyAuditGucs` первым, аудит последним (07 §9.3).
 */
@Injectable()
export class CustomerLinksService {
  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly links: CustomerLinksRepository,
    private readonly users: UsersRepository,
    private readonly audit: AuditService,
    private readonly notifier: LinkConflictNotifier,
    private readonly catalog: PermissionCatalog,
    @Inject(CUSTOMER_MATCHING) private readonly matching: CustomerMatching,
    @Inject(CUSTOMER_SELF_SERVICE_FLAG) private readonly selfService: SelfServiceFlag,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  // ---------------------------------------------------------------------------------------------------------
  // Предложение привязки (регистрация клиента, REG-039; повторный поиск по новому подтверждённому номеру)
  // ---------------------------------------------------------------------------------------------------------

  /**
   * Поиск карточки по подтверждённому телефону и создание `customer_links` (09 §7.8 п. 3): 0 → ничего; 1 →
   * `proposed`; ≥ 2 → `conflict` на каждую карточку + уведомление администраторам. Для вызова внутри транзакции
   * `POST /registration/complete` передайте `executor` (поиск в 1С выполняется до записи; при длинной транзакции
   * используйте `matching.findByPhone` до неё и `applyMatch` внутри).
   */
  async proposeForUser(
    input: { readonly userId: string; readonly phoneE164: string; readonly requestId?: string },
    executor?: DbExecutor,
  ): Promise<CustomerMatchSummary> {
    const result = await this.matching.findByPhone(input.phoneE164, {
      ...(input.requestId ? { requestId: input.requestId } : {}),
      ...(executor ? { executor } : {}),
    });
    if (executor) return this.applyMatch(input.userId, input.phoneE164, result, executor);
    return this.db.transaction((tx) => this.applyMatch(input.userId, input.phoneE164, result, tx));
  }

  /** Запись результата поиска в `customer_links` (в транзакции вызывающего). */
  async applyMatch(
    userId: string,
    phoneE164: string,
    result: CustomerMatchResult,
    ex: DbExecutor,
  ): Promise<CustomerMatchSummary> {
    if (!KG_E164.test(phoneE164)) throw new RangeError('customer_links: телефон — E.164 +996XXXXXXXXX');
    const user = await this.users.findById(userId, ex);
    if (!user || user.kind !== 'customer') return { status: 'none', linkId: null, nextStep: 'none' };
    const now = this.clock.now();
    const ids = result.candidates.map((c) => c.customerId);
    const existing = await this.links.listForUser(userId, ex);
    const confirmed = existing.find((l) => l.status === 'confirmed');
    if (!confirmed) {
      if (ids.length === 1) {
        await this.links.upsertProposal(
          { userId, customerId: ids[0], status: 'proposed', matchedPhoneE164: phoneE164, conflictCandidates: null },
          now,
          ex,
        );
      } else if (ids.length >= 2) {
        const rows: CustomerLinkRow[] = [];
        for (const id of ids) {
          rows.push(
            await this.links.upsertProposal(
              {
                userId,
                customerId: id,
                status: 'conflict',
                matchedPhoneE164: phoneE164,
                conflictCandidates: ids.filter((x) => x !== id),
              },
              now,
              ex,
            ),
          );
        }
        const open = rows.filter((r) => r.status === 'conflict');
        if (open.length > 0)
          await this.notifier.notifyConflict(
            userId,
            open.map((r) => r.id),
            ex,
          );
      }
    }
    const match = await this.matchFor(userId, ex);
    return {
      status: match.status === 'rejected' ? 'none' : match.status,
      linkId: match.status === 'rejected' ? null : match.linkId,
      nextStep: match.nextStep,
    };
  }

  // ---------------------------------------------------------------------------------------------------------
  // GET /registration/customer-match (08 §4.2.2)
  // ---------------------------------------------------------------------------------------------------------

  async getMatch(principal: AuthenticatedPrincipal): Promise<RegistrationCustomerMatchDto> {
    if (principal.kind !== 'customer') return { status: 'none', linkId: null, customer: null, nextStep: 'none' };
    return this.matchFor(principal.userId, this.db);
  }

  private async matchFor(userId: string, ex: DbExecutor): Promise<RegistrationCustomerMatchDto> {
    const rows = await this.links.listForUser(userId, ex);
    const confirmed = rows.find((l) => l.status === 'confirmed');
    if (confirmed) {
      const card = await this.links.findCard(confirmed.customerId, ex);
      return {
        status: 'confirmed',
        linkId: confirmed.id,
        customer: card ? { id: card.id, displayName: customerDisplayName(card.name) } : null,
        nextStep: 'confirmed',
      };
    }
    const conflict = rows.find((l) => l.status === 'conflict');
    if (conflict) return { status: 'conflict', linkId: conflict.id, customer: null, nextStep: 'wait_admin' };
    const proposed = rows.find((l) => l.status === 'proposed');
    if (proposed) {
      const card = await this.links.findCard(proposed.customerId, ex);
      const blocker = await this.selfResolveBlocker(proposed, ex);
      return {
        status: 'proposed',
        linkId: proposed.id,
        customer: card ? { displayNameMasked: maskCustomerName(card.name) } : null,
        nextStep: this.selfService.enabled() && blocker === null ? 'confirm_or_reject' : 'wait_admin',
      };
    }
    const rejected = rows.filter((l) => l.status === 'rejected').at(-1);
    if (rejected) return { status: 'rejected', linkId: rejected.id, customer: null, nextStep: 'none' };
    return { status: 'none', linkId: null, customer: null, nextStep: 'none' };
  }

  /**
   * Условия самоподтверждения 11 SEC-130 по **текущему** снимку карточки: своя `proposed`; телефон аккаунта, по
   * которому сделано предложение, = основной телефон карточки, отмеченный `verified`; карточка не `legal`; карточка
   * не привязана (`confirmed`) к другому пользователю; у пользователя нет другой `confirmed`-привязки.
   */
  private async selfResolveBlocker(link: CustomerLinkRow, ex: DbExecutor): Promise<SelfResolveBlocker | null> {
    if (link.status === 'conflict') return 'conflict';
    const user = await this.users.findById(link.userId, ex);
    const phone = user?.phoneE164 ?? null;
    if (!phone || link.matchedPhoneE164 !== phone) return 'phone_changed';
    const card = await this.links.findCard(link.customerId, ex);
    if (!card) return 'card_missing';
    if (card.customerType === 'legal') return 'legal_entity';
    if (card.primaryPhoneE164 !== phone) return 'secondary_contact';
    if (!isPhoneVerified(card, phone)) return 'phone_not_verified';
    if ((await this.links.confirmedByOthers(card.id, link.userId, ex)).length > 0) return 'already_linked';
    const own = (await this.links.listForUser(link.userId, ex)).filter(
      (l) => l.status === 'confirmed' && l.id !== link.id,
    );
    if (own.length > 0) return 'other_link_confirmed';
    return null;
  }

  // ---------------------------------------------------------------------------------------------------------
  // POST /registration/customer-match/confirm|reject (08 §4.2.4; 11 код 75, SEC-130)
  // ---------------------------------------------------------------------------------------------------------

  async selfResolve(
    principal: AuthenticatedPrincipal,
    ctx: AuditContext,
    linkId: string,
    decision: 'confirm' | 'reject',
  ): Promise<RegistrationCustomerMatchDto> {
    if (principal.kind !== 'customer') {
      throw new ProblemException('FORBIDDEN', { detail: 'Операция доступна только клиенту.' });
    }
    if (!this.selfService.enabled()) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Самостоятельное подтверждение привязки выключено.',
        reason: 'self_service_disabled',
        nextStep: 'wait_admin',
      });
    }
    const target = decision === 'confirm' ? 'confirmed' : 'rejected';
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const link = await this.links.findOwn(linkId, principal.userId, tx, true);
      if (!link) throw notFound();
      if (link.status === target) return this.selfResponse(link, tx);
      if (link.status === 'conflict') throw linkConflict('conflict', 'wait_admin');
      // SEC-130: объект выбирается фильтром status = 'proposed'; привязка в другом статусе «не найдена».
      if (link.status !== 'proposed') throw notFound();
      if (decision === 'confirm') {
        const blocker = await this.selfResolveBlocker(link, tx);
        if (blocker) throw linkConflict(blocker, 'wait_admin');
      }
      const updated = await this.links.resolve(
        link.id,
        { status: target, resolvedByUserId: principal.userId, at: this.clock.now() },
        tx,
      );
      await this.audit.write(
        ctx,
        {
          action: target === 'confirmed' ? 'customer.link.confirmed' : 'customer.link.rejected',
          entityType: 'customer_link',
          entityId: link.id,
          before: { status: link.status },
          after: { status: target, selfResolved: true, linkId: link.id },
        },
        tx,
      );
      return this.selfResponse(updated, tx);
    });
  }

  private async selfResponse(link: CustomerLinkRow, ex: DbExecutor): Promise<RegistrationCustomerMatchDto> {
    if (link.status === 'confirmed') {
      const card = await this.links.findCard(link.customerId, ex);
      return {
        status: 'confirmed',
        linkId: link.id,
        customer: card ? { id: card.id, displayName: customerDisplayName(card.name) } : null,
        nextStep: 'confirmed',
      };
    }
    return { status: 'rejected', linkId: link.id, customer: null, nextStep: 'none' };
  }

  // ---------------------------------------------------------------------------------------------------------
  // POST /customers/{id}/links/{linkId}/confirm|reject — только admin со step-up (08 §4.11.7; 11 код 32)
  // ---------------------------------------------------------------------------------------------------------

  async adminResolve(
    principal: AuthenticatedPrincipal,
    ctx: AuditContext,
    customerId: string,
    linkId: string,
    decision: 'confirm' | 'reject',
    body: AdminResolveBody,
    stepUp: VerifiedStepUp,
  ): Promise<CustomerLinkDto> {
    const target = decision === 'confirm' ? 'confirmed' : 'rejected';
    const comment = body.comment?.trim() ? body.comment.trim() : null;
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const link = await this.links.findForCustomer(linkId, customerId, tx, true);
      if (!link) throw notFound();
      if (link.status === target) return this.linkDto(link, tx);
      if (link.status !== 'proposed' && link.status !== 'conflict') {
        throw new ProblemException('CUSTOMER_LINK_CONFLICT', {
          detail: 'Привязка уже решена; разрешаются только предложенные и конфликтные привязки.',
          currentStatus: link.status,
        });
      }
      const wasConflict = link.status === 'conflict';
      if (wasConflict && (comment === null || comment.length < CONFLICT_REASON_MIN)) {
        throw new ProblemException('VALIDATION_FAILED', {
          status: 400,
          detail: 'Для разрешения конфликта укажите причину решения.',
          errors: [
            {
              field: 'comment',
              rule: 'reason_required',
              message: `Причина обязательна (не короче ${CONFLICT_REASON_MIN} символов).`,
              params: { min: CONFLICT_REASON_MIN },
            },
          ],
        });
      }
      const now = this.clock.now();
      const superseded: string[] = [];
      const siblingsRejected: string[] = [];
      if (target === 'confirmed') {
        const otherOwn = await this.links.listForUserByStatus(link.userId, 'confirmed', link.id, tx);
        const others = await this.links.confirmedByOthers(link.customerId, link.userId, tx);
        if ((otherOwn.length > 0 || others.length > 0) && body.force !== true) {
          throw new ProblemException('CUSTOMER_LINK_CONFLICT', {
            detail: 'Существует другая подтверждённая привязка; для замены передайте force=true.',
            reason: otherOwn.length > 0 ? 'user_has_confirmed_link' : 'customer_already_linked',
          });
        }
        for (const o of otherOwn) {
          await this.links.resolve(
            o.id,
            { status: 'rejected', resolvedByUserId: principal.userId, reason: 'superseded', at: now },
            tx,
          );
          superseded.push(o.id);
        }
      }
      const updated = await this.links.resolve(
        link.id,
        { status: target, resolvedByUserId: principal.userId, reason: comment, at: now },
        tx,
      );
      if (wasConflict && target === 'confirmed') {
        for (const s of await this.links.listForUserByStatus(link.userId, 'conflict', link.id, tx)) {
          await this.links.resolve(
            s.id,
            { status: 'rejected', resolvedByUserId: principal.userId, reason: 'conflict_resolved', at: now },
            tx,
          );
          siblingsRejected.push(s.id);
        }
      }
      await this.audit.write(
        ctx,
        {
          action: wasConflict
            ? 'customer.link.conflict_resolved'
            : target === 'confirmed'
              ? 'customer.link.confirmed'
              : 'customer.link.rejected',
          entityType: 'customer_link',
          entityId: link.id,
          before: { status: link.status },
          after: {
            status: target,
            selfResolved: false,
            linkId: link.id,
            customerId: link.customerId,
            ...(body.force === true ? { force: true } : {}),
            ...(superseded.length > 0 ? { supersededLinkIds: superseded } : {}),
            ...(siblingsRejected.length > 0 ? { rejectedLinkIds: siblingsRejected } : {}),
          },
          stepUpMethod: stepUp.method,
          reason: comment,
        },
        tx,
      );
      return this.linkDto(updated, tx);
    });
  }

  private async linkDto(row: CustomerLinkRow, ex: DbExecutor): Promise<CustomerLinkDto> {
    const info = row.confirmedByUserId
      ? await this.links.userInfo([row.confirmedByUserId], ex)
      : new Map<string, LinkUserInfo>();
    return toCustomerLinkDto(row, row.confirmedByUserId ? briefOf(row.confirmedByUserId, info) : null);
  }

  // ---------------------------------------------------------------------------------------------------------
  // GET /customers/{id}/links (08 §4.11.7; 11 код 67, код 61 для customer)
  // ---------------------------------------------------------------------------------------------------------

  async listLinks(
    principal: AuthenticatedPrincipal,
    customerId: string,
  ): Promise<{ items: CustomerLinkWithUserDto[] }> {
    const card = await this.links.findCard(customerId);
    if (!card) throw notFound();
    const perms = this.catalog.effectivePermissions(principal);
    let rows: CustomerLinkRow[];
    if (perms.has('customer.link.read')) {
      rows = await this.links.listForCustomer(customerId);
    } else {
      // customer (customer.self.read): только своя привязка и только после confirmed (SEC-030 (в)) — иначе
      // существование карточки не раскрывается.
      const own = await this.links.findPair(principal.userId, customerId);
      if (!own || own.status !== 'confirmed') throw notFound();
      rows = [own];
    }
    return { items: await this.withUsers(rows) };
  }

  private async withUsers(rows: readonly CustomerLinkRow[]): Promise<CustomerLinkWithUserDto[]> {
    const ids = rows.flatMap((r) => (r.confirmedByUserId ? [r.userId, r.confirmedByUserId] : [r.userId]));
    const info = await this.links.userInfo(ids);
    return rows.map((r) => {
      const user = userBriefOf(r.userId, info);
      return {
        ...toCustomerLinkDto(r, r.confirmedByUserId ? briefOf(r.confirmedByUserId, info) : null),
        user,
      };
    });
  }

  // ---------------------------------------------------------------------------------------------------------
  // GET /customers?linkStatus=proposed,conflict (08 §4.11.1; 11 код 73 — admin)
  // ---------------------------------------------------------------------------------------------------------

  async listQueue(
    statuses: readonly ('proposed' | 'conflict')[],
    limit: number,
    cursor: string | null,
  ): Promise<{ items: Record<string, unknown>[]; nextCursor: string | null; hasMore: boolean }> {
    const after = cursor ? decodeCursor(cursor) : null;
    const ids = await this.links.queueCustomerIds(statuses, limit + 1, after);
    const page = ids.slice(0, limit);
    const cards = await this.links.findCards(page);
    const flags = await this.links.debtFlags(page);
    const linkRows = await this.links.listForCustomersByStatus(page, statuses);
    const withUsers = await this.withUsers(linkRows);
    const items = page.flatMap((id) => {
      const card = cards.get(id);
      if (!card) return [];
      return [
        {
          ...adminCustomerDto(card, flags.get(id)),
          links: withUsers.filter((l) => l.customerId === id),
        },
      ];
    });
    const hasMore = ids.length > limit;
    return { items, nextCursor: hasMore && page.length > 0 ? encodeCursor(page[page.length - 1]) : null, hasMore };
  }
}

/** `Customer(role-DTO)` для `admin` (08 §3.7): без сумм долга — только флаги; поля без значения не выводятся. */
function adminCustomerDto(
  card: CustomerCardRow,
  flags: { hasDebt: boolean; isOverdue: boolean } | undefined,
): Record<string, unknown> {
  return {
    id: card.id,
    name: card.name,
    displayName: customerDisplayName(card.name),
    customerType: card.customerType,
    ...(card.onecCode ? { onecCode: card.onecCode } : {}),
    isRetailDefault: card.isRetailDefault,
    phones: cardPhones(card),
    ...(card.inn ? { inn: card.inn } : {}),
    creditAllowed: card.creditAllowed,
    hasDebt: flags?.hasDebt ?? false,
    isOverdue: flags?.isOverdue ?? false,
    source: card.source,
    onecStatus: card.onecStatus,
    onecRef: card.onecRef,
    syncedAt: card.syncedAt ? card.syncedAt.toISOString() : null,
  };
}

function briefOf(userId: string, info: Map<string, LinkUserInfo>): UserBrief {
  const u = info.get(userId);
  const b = userBrief(userId, u?.fullName ? { fullName: u.fullName, displayName: u.displayName } : null, null);
  return { id: b.id, displayName: b.displayName };
}

function userBriefOf(userId: string, info: Map<string, LinkUserInfo>): UserBrief {
  const u = info.get(userId);
  return userBrief(
    userId,
    u?.fullName ? { fullName: u.fullName, displayName: u.displayName } : null,
    u?.phoneE164 ?? null,
  );
}

function notFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Привязка не найдена.' });
}

function linkConflict(reason: SelfResolveBlocker, nextStep: MatchNextStep): ProblemException {
  return new ProblemException('CUSTOMER_LINK_CONFLICT', {
    detail: 'Эту привязку подтверждает администратор.',
    reason,
    nextStep,
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function encodeCursor(customerId: string): string {
  return Buffer.from(JSON.stringify({ c: customerId }), 'utf8').toString('base64url');
}

export function decodeCursor(cursor: string): string {
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as { c?: unknown };
    if (typeof parsed.c === 'string' && UUID_RE.test(parsed.c)) return parsed.c.toLowerCase();
  } catch {
    // ниже — единый ответ
  }
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Неверный курсор.',
    errors: [{ field: 'cursor', rule: 'cursor', message: 'Курсор повреждён или устарел.' }],
  });
}
