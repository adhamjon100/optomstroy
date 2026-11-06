import { BlockList, isIP } from 'node:net';
import {
  type CanActivate,
  type ExecutionContext,
  Inject,
  Injectable,
  Logger,
  Optional,
  type Provider,
} from '@nestjs/common';
import { APP_GUARD, Reflector } from '@nestjs/core';
import { parseSemVer } from '../../common/app-version/version-policy.js';
import { auditContextFromRequest, normalizeIp } from '../../common/audit/audit-context.js';
import { CLOCK, type Clock, systemClock } from '../../common/auth/clock.js';
import { isSubjectKind, switchSubjectKind } from '../../common/auth/subject-kind.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import {
  HTTP_RATE_LIMITS,
  HTTP_RATE_LIMITS_PER_MINUTE,
  type HttpRateLimitGroup,
  MemoryWindowCounter,
  rateLimitedProblem,
} from '../../common/rate-limit/http-rate-limit.js';
import { PUBLIC_ROUTE } from '../../common/rbac/rbac.decorators.js';
import { KioskAlertsService, KioskPresenceService, type KioskSignal } from '../ops/kiosk-alerts.service.js';
import { isKioskClosedListRoute, isKioskDisabledExempt, kioskRouteKeyOf } from './kiosk-routes.js';
import { type KioskRequest, KioskTabletReader } from './kiosk-tablet.reader.js';

type KioskHttpRequest = KioskRequest & { baseUrl?: string; ip?: string };

/** Конфигурация guard-а: `KIOSK_ALLOWED_CIDRS` необязательна (пусто — проверки сети нет, 16 §4.3). */
export type KioskAccessGuardConfig = Pick<AppConfig, 'KIOSK_MODE'> & Partial<Pick<AppConfig, 'KIOSK_ALLOWED_CIDRS'>>;

/** Предел длины `X-App-Version` в `store_tablets.last_app_version` (как `audit_logs.app_version`). */
const APP_VERSION_MAX_LENGTH = 64;

/**
 * Разбор `KIOSK_ALLOWED_CIDRS` (16 §4.3; 11 SEC-143): адреса и сети IPv4/IPv6 через запятую (`198.51.100.0/24`,
 * `203.0.113.7`, `2001:db8:5::/48`). Пусто или одни пробелы — `null` (проверки нет). Неверный элемент — ошибка при
 * старте (fail-closed: опечатка в списке не должна молча открыть или закрыть всем планшетам доступ).
 */
export function parseKioskAllowedCidrs(raw: string | undefined): BlockList | null {
  const items = (raw ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (items.length === 0) return null;
  const list = new BlockList();
  for (const item of items) {
    const [addr = '', prefix, ...rest] = item.split('/');
    const family = isIP(addr);
    const type = family === 6 ? 'ipv6' : 'ipv4';
    const bits = prefix === undefined ? null : /^\d{1,3}$/.test(prefix) ? Number(prefix) : Number.NaN;
    if (family === 0 || rest.length > 0 || (bits !== null && !(bits >= 0 && bits <= (family === 6 ? 128 : 32)))) {
      throw new Error(`KIOSK_ALLOWED_CIDRS: неверный адрес или сеть «${item}» (ожидается IP или IP/префикс)`);
    }
    if (bits === null) list.addAddress(addr, type);
    else list.addSubnet(addr, bits, type);
  }
  return list;
}

/** Адрес клиента (как для IP-лимитов SEC-016: `req.ip` с учётом доверенного прокси) входит в сеть магазина. */
export function isKioskNetworkAllowed(list: BlockList, ip: string | null): boolean {
  const family = ip === null ? 0 : isIP(ip);
  if (ip === null || family === 0) return false;
  return list.check(ip, family === 6 ? 'ipv6' : 'ipv4');
}

function headerOf(req: RequestWithContext, name: string): string | undefined {
  const v = req.headers[name];
  const s = Array.isArray(v) ? (v.length === 1 ? v[0] : undefined) : v;
  return typeof s === 'string' ? s.trim() : undefined;
}

/**
 * Сигналы планшета из заголовков (08 §2.3): `X-Kiosk-Lock` — ровно `on` | `off`, иное или нет заголовка — значение не
 * меняется; `X-App-Version` — SemVer до 64 символов (`1.4.2+87`), иное — не меняется.
 */
export function kioskSignalOf(req: RequestWithContext): KioskSignal {
  const lock = headerOf(req, 'x-kiosk-lock');
  const version = headerOf(req, 'x-app-version');
  return {
    lockTaskEnabled: lock === 'on' ? true : lock === 'off' ? false : null,
    appVersion:
      version !== undefined && version.length <= APP_VERSION_MAX_LENGTH && parseSemVer(version) !== null
        ? version
        : null,
  };
}

/**
 * Глобальный guard планшета магазина (06 §7.4 п. (1), ARCH-066; 08 §4.25 «Порядок проверок»; 11 SEC-137; ADR-115).
 * Порядок guard-ов приложения: ReadOnlyGuard → AuthGuard → SessionActivityGuard → **KioskAccessGuard** → RbacGuard
 * (app.module.ts `GLOBAL_PROVIDERS`; 401 по-прежнему раньше 403). Маршруты `@Public()` (11 SEC-013) guard не видит —
 * с токеном планшета они отвечают так же, как без него; нет субъекта — решает RbacGuard (401).
 *
 * Действует только для `kind=kiosk` (разбор вида — исчерпывающий, 06 ARCH-065): `staff` и `customer` проходят без
 * изменений; вид вне `staff | customer | kiosk` (в том числе служебный `integration`) — отказ по умолчанию `403`.
 * Для планшета:
 * 0. общий лимит SEC-015 (11 SEC-015; 08 §2.9 — значение RL-READ, 600/мин, ключ — `userId` технического пользователя,
 *    хранилище `memory`): считаются все запросы планшета, в том числе отклоняемые дальше; превышение →
 *    `429 RATE_LIMITED` с `Retry-After` и `X-RateLimit-*` (как `HttpRateLimitInterceptor`) раньше всех проверок —
 *    без чтения `store_tablets`, аудита и алерта. Интерцептор лимитов работает после guard-ов и отклонённых здесь
 *    запросов не видит, поэтому поток отказов сети (п. 2) иначе не ограничен ничем;
 * 1. `KIOSK_MODE=false` → `403 KIOSK_DISABLED` на любом маршруте, кроме `GET /settings/public` и `GET /me` (в том
 *    числе все `/kiosk/*`, включая `POST /kiosk/exit`; ADR-115 п. 28);
 * 2. задана `KIOSK_ALLOWED_CIDRS`, а адрес клиента (`req.ip` с учётом доверенного прокси, как SEC-016) вне неё →
 *    `403 KIOSK_NETWORK_DENIED`, аудит `kiosk.network_denied` и алерт без IP (`KioskAlertsService`); сессия не
 *    отзывается — в сети магазина планшет снова работает (11 SEC-143); пусто — проверки нет;
 * 3. маршрута нет в закрытом списке (kiosk-routes.ts) или у запроса нет шаблона маршрута → `403 FORBIDDEN`
 *    `reason: kiosk_closed_list` (fail-closed);
 * 4. действующая строка `store_tablets` → `req.kiosk` (KioskTabletContext); отключённого или неполного планшета нет
 *    → `403 FORBIDDEN` (сессию, отозванную отключением, раньше отклоняет AuthGuard — `401 KIOSK_REVOKED`);
 * 5. отметка связи `last_seen_at`, `last_app_version` (`X-App-Version`), `lock_task_enabled` (`X-Kiosk-Lock`) одним
 *    условным обновлением не чаще раза в 60 с на сессию планшета (`KioskPresenceService`; в том числе
 *    `GET /settings/public` — отметка простаивающего планшета; первый `X-Kiosk-Lock` после подключения заново — сразу).
 *    Ошибка отметки запрос не отклоняет.
 * Права маршрута проверяет следующий RbacGuard: список права не выдаёт, только сужает.
 */
@Injectable()
export class KioskAccessGuard implements CanActivate {
  private readonly logger = new Logger('kiosk');
  /** Сеть магазина (`KIOSK_ALLOWED_CIDRS`); `null` — проверки нет. */
  private readonly storeNetwork: BlockList | null;
  /** Общий лимит SEC-015 (шаг 0): счётчик окна 1 мин в памяти процесса, ключ — `userId` планшета. */
  private readonly counter = new MemoryWindowCounter();
  private readonly generalLimit: number;
  private readonly clock: Clock;

  constructor(
    private readonly reflector: Reflector,
    @Inject(APP_CONFIG) private readonly config: KioskAccessGuardConfig,
    private readonly tablets: KioskTabletReader,
    @Optional() private readonly presence?: KioskPresenceService,
    @Optional() private readonly alerts?: KioskAlertsService,
    @Optional() @Inject(CLOCK) clock?: Clock,
    @Optional() @Inject(HTTP_RATE_LIMITS) limits?: Partial<Record<HttpRateLimitGroup, number>>,
  ) {
    this.storeNetwork = parseKioskAllowedCidrs(config.KIOSK_ALLOWED_CIDRS);
    this.clock = clock ?? systemClock;
    this.generalLimit = limits?.['RL-READ'] ?? HTTP_RATE_LIMITS_PER_MINUTE['RL-READ'];
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, [context.getHandler(), context.getClass()]) === true) {
      return true;
    }
    const req = context.switchToHttp().getRequest<KioskHttpRequest>();
    const principal = req.principal;
    if (!principal) return true;
    const kind = principal.kind;
    if (!isSubjectKind(kind)) {
      // `integration` и любое значение вне перечня — не вид субъекта: отказ по умолчанию (06 ARCH-065).
      this.deny(req, 'unknown_subject_kind', null);
    }
    return switchSubjectKind(kind, {
      staff: () => Promise.resolve(true),
      customer: () => Promise.resolve(true),
      kiosk: () => this.checkKiosk(req, principal.userId),
    });
  }

  private async checkKiosk(req: KioskHttpRequest, userId: string): Promise<boolean> {
    const route = kioskRouteKeyOf(req);
    const rl = this.counter.consume(`kiosk-guard:${userId}`, this.generalLimit, this.clock.now().getTime());
    if (!rl.allowed) {
      this.logger.warn({ event: 'kiosk.rate_limited', requestId: req.id, route }, 'kiosk.rate_limited');
      throw rateLimitedProblem(this.generalLimit, rl.retryAfterSec);
    }
    if (!this.config.KIOSK_MODE && !isKioskDisabledExempt(route)) {
      this.logger.warn({ event: 'kiosk.disabled', requestId: req.id, route }, 'kiosk.disabled');
      throw new ProblemException('KIOSK_DISABLED', {
        detail: 'Сервис временно недоступен. Обратитесь к продавцу.',
      });
    }
    if (this.storeNetwork !== null && !isKioskNetworkAllowed(this.storeNetwork, normalizeIp(req.ip))) {
      await this.denyNetwork(req, userId, route);
    }
    if (!isKioskClosedListRoute(route)) {
      this.deny(req, 'kiosk_closed_list', route);
    }
    const tablet = await this.tablets.findActiveByUserId(userId);
    if (!tablet) {
      this.deny(req, 'kiosk_tablet_inactive', route);
    }
    req.kiosk = tablet;
    await this.presence?.mark(tablet.tabletId, kioskSignalOf(req), req.principal?.sessionId ?? null);
    return true;
  }

  /**
   * `403 KIOSK_NETWORK_DENIED` (08 §2.4; 11 SEC-143): аудит `kiosk.network_denied` и алерт — `KioskAlertsService`
   * (планшет — действующая строка `store_tablets`, если есть); в журнал guard-а — без адреса клиента (SEC-063).
   */
  private async denyNetwork(req: KioskHttpRequest, userId: string, route: string | null): Promise<never> {
    this.logger.warn({ event: 'kiosk.network_denied', requestId: req.id, route }, 'kiosk.network_denied');
    const tablet = await this.tablets.findActiveByUserId(userId).catch(() => null);
    await this.alerts?.networkDenied({
      ctx: auditContextFromRequest(req),
      tablet: tablet ? { tabletId: tablet.tabletId, name: tablet.name } : null,
      route,
    });
    throw new ProblemException('KIOSK_NETWORK_DENIED', {
      detail: 'Планшет не в сети магазина. Обратитесь к продавцу.',
    });
  }

  /**
   * `403 FORBIDDEN`: клиенту `reason` только для закрытого списка (08 §2.4 «Коды и отказы планшета магазина»),
   * прочие причины — в журнал (без идентификаторов субъекта; 11 SEC-062).
   */
  private deny(req: RequestWithContext, reason: string, route: string | null): never {
    this.logger.warn({ event: 'kiosk.denied', requestId: req.id, reason, route }, 'kiosk.denied');
    throw new ProblemException('FORBIDDEN', {
      detail: 'Операция недоступна на планшете магазина.',
      ...(reason === 'kiosk_closed_list' ? { reason } : {}),
    });
  }
}

/**
 * Провайдер для `GLOBAL_PROVIDERS` app.module.ts — сразу после `AUTH_SESSION_ACTIVITY_GUARD` и перед RbacGuard
 * (06 §7.4 п. (1), AC-ARCH-066 (2)). Зависимость `KioskTabletReader` экспортирует `KioskModule`.
 */
export const KIOSK_ACCESS_GUARD: Provider = { provide: APP_GUARD, useClass: KioskAccessGuard };
