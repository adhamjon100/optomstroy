import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { ExecutionContext } from '@nestjs/common';
import type { Reflector } from '@nestjs/core';
import type { PgBoss } from 'pg-boss';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { AppVersionPolicy } from '../../src/common/app-version/app-version.policy.js';
import { AuditService } from '../../src/common/audit/audit.service.js';
import { FixedClock } from '../../src/common/auth/clock.js';
import { HTTP_RATE_LIMITS } from '../../src/common/rate-limit/http-rate-limit.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import {
  KIOSK_ACCESS_GUARD,
  KioskAccessGuard,
  kioskSignalOf,
  parseKioskAllowedCidrs,
} from '../../src/kiosk/common/kiosk-access.guard.js';
import type { KioskTabletContext, KioskTabletReader } from '../../src/kiosk/common/kiosk-tablet.reader.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import {
  KIOSK_ALERTS_CRON,
  type KioskAlertCode,
  type KioskAlertFiring,
  KioskAlertsService,
  KioskPresenceService,
  type KioskSignal,
  workingIntervalStart,
} from '../../src/kiosk/ops/kiosk-alerts.service.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { parseKioskWorkingHours } from '../../src/settings/public-settings.map.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Сеть магазина, отметка связи и алерты планшета магазина (08 §2.3 `X-Kiosk-Lock`, §2.4 `KIOSK_NETWORK_DENIED`,
 * §3.17 `StoreTablet`, §4.25 «Порядок проверок»; 07 §5.65; 10 KIOSK-024, KIOSK-026, KIOSK-033; 11 SEC-143, §6.2
 * «Алерты планшета магазина», §7.2.1; 16 §9; ADR-115 п. 21, п. 26) — **тестовые данные** стенда `kiosk-fixture`
 * (embedded PostgreSQL 17; сеть магазина — документационные сети `198.51.100.0/24` и `2001:db8:5::/48`, «снаружи» —
 * `203.0.113.9` и `2001:db8:9::9` (RFC 5737, RFC 3849); номера покупателей — вымышленные `+996 555 003 xxx`):
 * - T-KIOSK-048: `KIOSK_ALLOWED_CIDRS` — из сети магазина как обычно, снаружи `403 KIOSK_NETWORK_DENIED` + аудит
 *   `kiosk.network_denied` (актор — система, адрес — только `audit_logs.ip`) + алерт без IP, сессия не отозвана;
 *   пустая переменная — проверки нет; порядок `KIOSK_DISABLED` → `KIOSK_NETWORK_DENIED` → закрытый список;
 * - T-KIOSK-048 / T-SEC-005: общий лимит SEC-015 (значение RL-READ, ключ — `userId` планшета) — шаг 0 guard-а: поток
 *   отказов вне сети магазина ограничен, сверх лимита `429 RATE_LIMITED` без чтения `store_tablets`, аудита и алерта;
 * - T-KIOSK-068 (сервер): `X-Kiosk-Lock` `off`/`on`/нет → `lock_task_enabled` `false`/`true`/без изменений (`NULL` после
 *   подключения) тем же ограниченным обновлением, что `last_seen_at`, — и `lockTaskEnabled` в `GET /admin/store-tablets`;
 *   после подключения заново (`NULL`) первый сигнал пишется сразу, хотя прежняя сессия отметилась меньше 60 с назад;
 * - T-KIOSK-050 (сервер): `X-App-Version` → `last_app_version` и `StoreTablet.appVersion` в `GET /admin/store-tablets`,
 *   неразборчивая — без изменений;
 * - T-KIOSK-064: `last_seen_at` не чаще раза в 60 с, `GET /settings/public` — отметка простаивающего планшета; алерт «не
 *   на связи» > 15 мин только в часы `kiosk_working_hours`, пустая настройка — алерта нет;
 * - T-KIOSK-063: ≥ 10 кодов с планшета за 10 мин — алерт без телефонов и IP, коды выдаются дальше;
 * - T-KIOSK-017: исчерпан суточный лимит кодов планшета — алерт задачи `kiosk.alerts`;
 * - T-KIOSK-065: до конца подключения 29 дней — алерт; версия ниже рекомендуемой — алерт.
 * Время стенда — `FixedClock` в 12:00 Asia/Bishkek (ближайший к реальному полдень): часы работы задаются явно.
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const MIN_MS = 60_000;
const DAY_MS = 86_400_000;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;

const STORE_CIDRS = '198.51.100.0/24, 2001:db8:5::/48';
const STORE_IP = '198.51.100.20';
const STORE_IP6 = '2001:db8:5::20';
const OUTSIDE_IP = '203.0.113.9';
const OUTSIDE_IP6 = '2001:db8:9::9';

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 003 xxx` (тестовые данные). */
function freshPhone(): string {
  phoneSeq += 1;
  return `+996555003${String(100 + phoneSeq)}`;
}

/** Ближайший к `nowMs` полдень Asia/Bishkek (06:00 UTC): сессии и токены стенда остаются действительными. */
function nearestBishkekNoon(nowMs: number): Date {
  const d = new Date(nowMs);
  const base = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 6, 0, 0);
  const best = [base - DAY_MS, base, base + DAY_MS].reduce((a, b) =>
    Math.abs(b - nowMs) < Math.abs(a - nowMs) ? b : a,
  );
  return new Date(best);
}

/** `ЧЧ:ММ` по Asia/Bishkek для `at - minusMinutes`. */
function bishkekHhMm(at: Date, minusMinutes = 0): string {
  const local = new Date(at.getTime() + BISHKEK_OFFSET_MS - minusMinutes * MIN_MS);
  return `${String(local.getUTCHours()).padStart(2, '0')}:${String(local.getUTCMinutes()).padStart(2, '0')}`;
}

interface CallOpts {
  readonly ip?: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: unknown;
}

type Subject = Pick<PosActor, 'token' | 'deviceKey'>;

/** Запрос стенда; адрес клиента — `X-Forwarded-For` (доверенный прокси — loopback стенда, как pos-proxy, SEC-016). */
async function call(t: KioskTestApp, method: Method, path: string, a: Subject, opts: CallOpts = {}): Promise<Res> {
  let r = t.req(method, path, a).set('X-Forwarded-For', opts.ip ?? STORE_IP);
  for (const [k, v] of Object.entries(opts.headers ?? {})) r = r.set(k, v);
  const res = await (opts.body !== undefined ? r.send(opts.body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

async function fillCart(t: KioskTestApp, a: PosActor, v: SaleableVariant): Promise<string> {
  const c0 = await call(t, 'get', '/cart', a);
  expect(c0.status, JSON.stringify(c0.body)).toBe(200);
  const put = await call(t, 'put', `/cart/items/${v.variantId}`, a, {
    body: { quantity: { value: '1', unitId: v.unitId, packagingId: null }, rowVersion: c0.body.rowVersion as number },
  });
  expect(put.status, JSON.stringify(put.body)).toBe(200);
  return c0.body.id as string;
}

/** `dev_outbox` (07 §5.63) в БД стенда — как `order-otp.spec.ts` (файл dev-миграции не меняется). */
async function createDevOutbox(t: KioskTestApp): Promise<void> {
  const c = await t.pool.connect();
  try {
    await c.query(`SELECT set_config('app.env', 'test', false)`);
    await c.query(readFileSync(DEV_OUTBOX_SQL, 'utf8'));
  } finally {
    await c.query('RESET app.env').catch(() => undefined);
    c.release();
  }
}

interface SeenRow {
  readonly last_seen_at: Date | null;
  readonly last_app_version: string | null;
  readonly lock_task_enabled: boolean | null;
}

async function seenOf(t: KioskTestApp, tab: KioskTablet): Promise<SeenRow> {
  const r = await t.q<SeenRow & Record<string, unknown>>(
    `SELECT last_seen_at, last_app_version, lock_task_enabled FROM store_tablets WHERE id = $1`,
    [tab.tabletId],
  );
  const row = r[0];
  if (!row) throw new Error('нет строки store_tablets');
  return row;
}

const ms = (d: Date | null): number | null => (d === null ? null : new Date(d).getTime());

/** Строка планшета в `GET /admin/store-tablets` (08 §4.18.12; `kiosk.read`), как её видит SCR-54. */
async function listedOf(t: KioskTestApp, viewer: Subject, tabletId: string): Promise<Record<string, unknown>> {
  const l = await call(t, 'get', '/admin/store-tablets', viewer);
  expect(l.status, JSON.stringify(l.body)).toBe(200);
  const item = (l.body.items as Record<string, unknown>[]).find((x) => x.id === tabletId);
  if (!item) throw new Error(`планшета ${tabletId} нет в GET /admin/store-tablets`);
  return item;
}

const firingOf = (all: readonly KioskAlertFiring[], alert: KioskAlertCode, tabletId: string) =>
  all.filter((f) => f.alert === alert && f.tabletId === tabletId);

describe('KioskAccessGuard: сеть магазина и сигналы планшета без HTTP (T-KIOSK-048, T-KIOSK-068 unit)', () => {
  const tablet: KioskTabletContext = {
    tabletId: randomUUID(),
    userId: randomUUID(),
    deviceId: randomUUID(),
    name: 'Планшет у входа',
    warehouseId: randomUUID(),
  };
  const reflector = { getAllAndOverride: () => undefined } as unknown as Reflector;
  const reader = { findActiveByUserId: () => Promise.resolve(tablet) } as unknown as KioskTabletReader;
  const ctx = (req: Record<string, unknown>): ExecutionContext =>
    ({
      getType: () => 'http',
      getHandler: () => undefined,
      getClass: () => undefined,
      switchToHttp: () => ({ getRequest: () => req }),
    }) as unknown as ExecutionContext;
  const req = (kind: string, path: string, ip: string, headers: Record<string, string> = {}, method = 'GET') => ({
    method,
    route: { path: `/api/v1${path}` },
    principal: { userId: tablet.userId, kind, roles: [kind === 'kiosk' ? 'kiosk' : 'seller'] },
    headers,
    ip,
  });
  const fakes = () => {
    const marks: { tabletId: string; signal: KioskSignal }[] = [];
    const denied: unknown[] = [];
    const presence = {
      mark: (tabletId: string, signal: KioskSignal) => {
        marks.push({ tabletId, signal });
        return Promise.resolve(true);
      },
    } as unknown as KioskPresenceService;
    const alerts = {
      networkDenied: (input: unknown) => {
        denied.push(input);
        return Promise.resolve();
      },
    } as unknown as KioskAlertsService;
    return { marks, denied, presence, alerts };
  };
  const guard = (cidrs: string | undefined, kioskMode = true) => {
    const f = fakes();
    const g = new KioskAccessGuard(
      reflector,
      { KIOSK_MODE: kioskMode, KIOSK_ALLOWED_CIDRS: cidrs },
      reader,
      f.presence,
      f.alerts,
    );
    return { g, ...f };
  };
  const codeOf = async (p: Promise<boolean>) =>
    p.then(
      () => 'pass',
      (e: { code?: string; extensions?: { reason?: string } }) => `${e.code ?? '?'}/${e.extensions?.reason ?? ''}`,
    );

  it('T-KIOSK-048 KIOSK_ALLOWED_CIDRS: разбор списка; пусто — проверки нет; ошибка — при старте', () => {
    for (const empty of [undefined, '', '   ', ' , ,']) expect(parseKioskAllowedCidrs(empty)).toBeNull();
    const list = parseKioskAllowedCidrs('198.51.100.0/24, 192.0.2.7 ,2001:db8:5::/48');
    expect(list?.check('198.51.100.200', 'ipv4')).toBe(true);
    expect(list?.check('192.0.2.7', 'ipv4')).toBe(true);
    expect(list?.check('192.0.2.8', 'ipv4')).toBe(false);
    expect(list?.check('2001:db8:5::1', 'ipv6')).toBe(true);
    expect(list?.check('2001:db8:6::1', 'ipv6')).toBe(false);
    for (const bad of ['abc', '198.51.100.0/33', '198.51.100.0/24/1', '2001:db8::/129', '198.51.100.0/x', '10.0.0']) {
      expect(() => parseKioskAllowedCidrs(bad), bad).toThrow(/KIOSK_ALLOWED_CIDRS/);
      expect(() => new KioskAccessGuard(reflector, { KIOSK_MODE: true, KIOSK_ALLOWED_CIDRS: bad }, reader)).toThrow();
    }
  });

  it('T-KIOSK-048 порядок: KIOSK_DISABLED → KIOSK_NETWORK_DENIED → закрытый список; staff и customer не ограничены', async () => {
    const on = guard(STORE_CIDRS);
    expect(await codeOf(on.g.canActivate(ctx(req('kiosk', '/cart', STORE_IP))))).toBe('pass');
    expect(await codeOf(on.g.canActivate(ctx(req('kiosk', '/cart', `::ffff:${STORE_IP}`))))).toBe('pass');
    expect(await codeOf(on.g.canActivate(ctx(req('kiosk', '/cart', STORE_IP6))))).toBe('pass');
    expect(await codeOf(on.g.canActivate(ctx(req('kiosk', '/cart', OUTSIDE_IP))))).toBe('KIOSK_NETWORK_DENIED/');
    expect(await codeOf(on.g.canActivate(ctx(req('kiosk', '/cart', OUTSIDE_IP6))))).toBe('KIOSK_NETWORK_DENIED/');
    // вне сети — раньше закрытого списка; в сети маршрут вне списка — kiosk_closed_list
    const orders = (ip: string) => req('kiosk', '/orders', ip, {}, 'POST');
    expect(await codeOf(on.g.canActivate(ctx(orders(OUTSIDE_IP))))).toBe('KIOSK_NETWORK_DENIED/');
    expect(await codeOf(on.g.canActivate(ctx(orders(STORE_IP))))).toBe('FORBIDDEN/kiosk_closed_list');
    expect(on.denied).toEqual([
      expect.objectContaining({ tablet: { tabletId: tablet.tabletId, name: tablet.name }, route: 'GET /cart' }),
      expect.objectContaining({ route: 'GET /cart' }),
      expect.objectContaining({ route: 'POST /orders' }),
    ]);
    expect((on.denied[0] as { ctx: { ip: string } }).ctx.ip).toBe(OUTSIDE_IP);
    // отказ сети отметку связи не ставит
    expect(on.marks).toHaveLength(3);
    // сотрудник и покупатель снаружи — без проверки сети
    for (const kind of ['staff', 'customer']) {
      expect(await codeOf(on.g.canActivate(ctx(req(kind, '/cart', OUTSIDE_IP)))), kind).toBe('pass');
    }
    // KIOSK_MODE=false: сначала KIOSK_DISABLED; на /settings/public и /me — проверка сети
    const off = guard(STORE_CIDRS, false);
    expect(await codeOf(off.g.canActivate(ctx(req('kiosk', '/cart', OUTSIDE_IP))))).toBe('KIOSK_DISABLED/');
    expect(off.denied).toEqual([]);
    expect(await codeOf(off.g.canActivate(ctx(req('kiosk', '/settings/public', OUTSIDE_IP))))).toBe(
      'KIOSK_NETWORK_DENIED/',
    );
    expect(await codeOf(off.g.canActivate(ctx(req('kiosk', '/me', STORE_IP))))).toBe('pass');
    // пустая переменная — проверки нет
    for (const cidrs of [undefined, '']) {
      const none = guard(cidrs);
      expect(await codeOf(none.g.canActivate(ctx(req('kiosk', '/cart', OUTSIDE_IP))))).toBe('pass');
      expect(none.denied).toEqual([]);
    }
  });

  it('T-KIOSK-068 X-Kiosk-Lock on|off — иное или нет заголовка → без изменений; X-App-Version — только SemVer', async () => {
    const sig = (headers: Record<string, string>) => kioskSignalOf({ headers });
    expect(sig({ 'x-kiosk-lock': 'on' }).lockTaskEnabled).toBe(true);
    expect(sig({ 'x-kiosk-lock': ' off ' }).lockTaskEnabled).toBe(false);
    for (const v of ['ON', 'yes', '1', '']) expect(sig({ 'x-kiosk-lock': v }).lockTaskEnabled, v).toBeNull();
    expect(sig({}).lockTaskEnabled).toBeNull();
    expect(sig({ 'x-app-version': '1.4.2+87' }).appVersion).toBe('1.4.2+87');
    for (const v of ['abc', '1.4', `1.4.2+${'9'.repeat(70)}`])
      expect(sig({ 'x-app-version': v }).appVersion).toBeNull();
    const g = guard(undefined);
    await g.g.canActivate(ctx(req('kiosk', '/settings/public', STORE_IP, { 'x-kiosk-lock': 'on' })));
    expect(g.marks).toEqual([{ tabletId: tablet.tabletId, signal: { lockTaskEnabled: true, appVersion: null } }]);
  });

  it('часы работы kiosk_working_hours (Asia/Bishkek): начало текущего интервала, конец не входит, иначе null', () => {
    const hours = parseKioskWorkingHours('mon-fri 09:00-18:00;sat 10:00-14:00') ?? [];
    const at = (iso: string) => new Date(iso);
    // 2026-11-07 — суббота, 2026-11-06 — пятница, 2026-11-08 — воскресенье; Бишкек = UTC+6
    expect(workingIntervalStart(hours, at('2026-11-07T05:00:00Z'))).toEqual(at('2026-11-07T04:00:00Z'));
    expect(workingIntervalStart(hours, at('2026-11-06T11:59:00Z'))).toEqual(at('2026-11-06T03:00:00Z'));
    expect(workingIntervalStart(hours, at('2026-11-06T12:00:00Z'))).toBeNull();
    expect(workingIntervalStart(hours, at('2026-11-08T06:00:00Z'))).toBeNull();
    expect(workingIntervalStart(hours, at('2026-11-06T02:59:00Z'))).toBeNull();
    expect(workingIntervalStart([], at('2026-11-06T06:00:00Z'))).toBeNull();
  });
});

describe('kiosk: сеть магазина, отметка связи и алерты (KIOSK_MODE=true, KIOSK_ALLOWED_CIDRS задана)', () => {
  const t = new KioskTestApp();
  const clock = new FixedClock(nearestBishkekNoon(Date.now()));
  let variant: SaleableVariant;
  let seller: PosActor;
  let customer: PosActor;
  let admin: PosActor;
  let alerts: KioskAlertsService;

  const setSetting = async (key: string, json: string | null): Promise<void> => {
    if (json === null) await t.q(`DELETE FROM app_settings WHERE key = $1`, [key]);
    else await t.setSetting(key, json);
    t.app.get(SettingsReader).invalidate();
  };
  const alertLogs = (alert: KioskAlertCode, tabletId: string) =>
    t.logs.json().filter((e) => e.event === 'security.alert' && e.alert === alert && e.kioskId === tabletId);
  const notes = (alert: KioskAlertCode, tabletId: string) =>
    (t.fakes?.notifications.items ?? []).filter((n) => n.dedupeKey.startsWith(`${alert}:${tabletId}:`));
  const noPii = (v: unknown) => {
    const s = JSON.stringify(v);
    for (const bad of ['+996', '996555003', OUTSIDE_IP, OUTSIDE_IP6, STORE_IP, '198.51.100']) {
      expect(s, bad).not.toContain(bad);
    }
  };
  const orderOtp = (tab: KioskTablet, cartId: string) =>
    call(t, 'post', '/kiosk/order-otp', tab, { body: { phone: freshPhone(), cartId, noticeVersion: NOTICE } });

  beforeAll(async () => {
    await t.start({
      env: {
        QR_PROVIDER: 'none',
        KIOSK_MODE: 'true',
        KIOSK_ALLOWED_CIDRS: STORE_CIDRS,
        OTP_GLOBAL_PER_MIN: '100000',
      },
      skuCount: 40,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
      clock,
    });
    await createDevOutbox(t);
    variant = (await t.saleableVariants(1))[0];
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
    admin = await t.actor({ role: 'admin' });
    t.fakes?.notifications.roleMembers.set('admin', [admin.userId]);
    alerts = t.app.get(KioskAlertsService, { strict: false });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-048 CIDR inside/outside/empty: снаружи 403 KIOSK_NETWORK_DENIED, аудит и алерт без IP, сессия не отозвана', async () => {
    const tab = await t.tablet({ name: 'Планшет у кассы' });
    const cartId = (await call(t, 'get', '/cart', tab)).body.id as string;
    expect((await call(t, 'get', '/settings/public', tab)).status).toBe(200);
    expect((await call(t, 'get', '/cart', tab, { ip: STORE_IP6 })).status).toBe(200);
    const seenBefore = ms((await seenOf(t, tab)).last_seen_at);
    expect(seenBefore).toBe(clock.now().getTime());
    clock.advance(61_000);

    const denied = [
      await call(t, 'get', '/cart', tab, { ip: OUTSIDE_IP }),
      await call(t, 'post', '/kiosk/reset', tab, { ip: OUTSIDE_IP, body: { cartId } }),
      await call(t, 'get', '/settings/public', tab, { ip: OUTSIDE_IP6 }),
      await call(t, 'post', '/orders', tab, { ip: OUTSIDE_IP, body: {} }), // вне списка — всё равно сеть раньше
    ];
    for (const r of denied) {
      expect([r.status, r.body.code, r.body.detail]).toEqual([
        403,
        'KIOSK_NETWORK_DENIED',
        'Планшет не в сети магазина. Обратитесь к продавцу.',
      ]);
    }
    // отказ сети не ставит отметку связи и не трогает корзину
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(seenBefore);
    expect((await t.q(`SELECT status::text AS s FROM carts WHERE id = $1`, [cartId]))[0]).toEqual({ s: 'active' });

    // аудит kiosk.network_denied (11 §7.2.1): актор — система, store_tablets.id, шаблон маршрута; адрес — только ip
    const audit = await t.q<{ actor_user_id: string | null; result: string; ip: string; after: unknown }>(
      `SELECT actor_user_id, result, host(ip) AS ip, after FROM audit_logs
        WHERE action = 'kiosk.network_denied' AND entity_id = $1 ORDER BY chain_seq`,
      [tab.tabletId],
    );
    expect(audit).toEqual([
      { actor_user_id: null, result: 'denied', ip: OUTSIDE_IP, after: { kioskId: tab.tabletId, route: 'GET /cart' } },
      {
        actor_user_id: null,
        result: 'denied',
        ip: OUTSIDE_IP,
        after: { kioskId: tab.tabletId, route: 'POST /kiosk/reset' },
      },
      {
        actor_user_id: null,
        result: 'denied',
        ip: OUTSIDE_IP6,
        after: { kioskId: tab.tabletId, route: 'GET /settings/public' },
      },
      {
        actor_user_id: null,
        result: 'denied',
        ip: OUTSIDE_IP,
        after: { kioskId: tab.tabletId, route: 'POST /orders' },
      },
    ]);
    noPii(audit.map((a) => a.after));

    // алерт (SEC-068 канал, SEC-132 содержимое): один на окно 10 мин; уведомление администратору с именем планшета
    expect(alertLogs('kiosk.network_denied', tab.tabletId)).toEqual([expect.objectContaining({ route: 'GET /cart' })]);
    noPii(alertLogs('kiosk.network_denied', tab.tabletId));
    const n = notes('kiosk.network_denied', tab.tabletId);
    expect(n).toEqual([
      expect.objectContaining({
        userId: admin.userId,
        kind: 'system',
        payload: { target: null, alert: 'kiosk.network_denied', kioskId: tab.tabletId },
      }),
    ]);
    expect(n[0]?.body).toContain('«Планшет у кассы»');
    noPii(n);

    // сессия не отозвана: в сети магазина работа продолжается без подключения заново
    const s = await t.q<{ revoked_at: Date | null }>(`SELECT revoked_at FROM sessions WHERE id = $1`, [tab.sessionId]);
    expect(s).toEqual([{ revoked_at: null }]);
    expect((await call(t, 'get', '/cart', tab)).status).toBe(200);

    // токены сотрудников и покупателей сетью магазина не ограничиваются
    for (const a of [seller, customer]) {
      expect((await call(t, 'get', '/cart', a, { ip: OUTSIDE_IP })).status, a.kind).toBe(200);
      expect((await call(t, 'get', '/settings/public', a, { ip: OUTSIDE_IP6 })).status, a.kind).toBe(200);
    }
  });

  it('T-KIOSK-068 X-Kiosk-Lock on/off/absent → lockTaskEnabled true/false/unchanged (NULL after enrollment) in GET /admin/store-tablets', async () => {
    const tab = await t.tablet();
    expect(await seenOf(t, tab)).toEqual({ last_seen_at: null, last_app_version: null, lock_task_enabled: null });
    expect(await listedOf(t, admin, tab.tabletId)).toMatchObject({ lockTaskEnabled: null, lastSeenAt: null });
    const lockAfter = async (headers: Record<string, string>, advanceMs = 61_000) => {
      clock.advance(advanceMs);
      expect((await call(t, 'get', '/cart', tab, { headers })).status).toBe(200);
      const column = (await seenOf(t, tab)).lock_task_enabled;
      expect((await listedOf(t, admin, tab.tabletId)).lockTaskEnabled).toBe(column);
      return column;
    };
    expect(await lockAfter({}, 0)).toBeNull(); // сигнала ещё не было — NULL, отметка связи есть
    expect((await seenOf(t, tab)).last_seen_at).not.toBeNull();
    expect(await lockAfter({ 'X-Kiosk-Lock': 'off' })).toBe(false); // веб, Windows, NoKioskLock
    expect(await lockAfter({})).toBe(false); // без заголовка — не меняется
    expect(await lockAfter({ 'X-Kiosk-Lock': 'on' })).toBe(true); // после KioskLock.enable
    const seen = ms((await seenOf(t, tab)).last_seen_at);
    expect(await lockAfter({ 'X-Kiosk-Lock': 'off' }, 10_000)).toBe(true); // раньше 60 с — то же обновление не идёт
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(seen);
    expect(await lockAfter({ 'X-Kiosk-Lock': 'yes' })).toBe(true); // иное значение — не меняется
    expect(await lockAfter({ 'X-Kiosk-Lock': 'off' })).toBe(false);
  });

  it('T-KIOSK-068 reconnect: NULL → первый X-Kiosk-Lock новой сессии пишется сразу, а не через 60 с после прежней', async () => {
    const warehouseId = await t.defaultWarehouseId();
    // подключение через API (08 §4.18.11) администратором на «устройстве планшета»
    const enroller = await t.actor({ role: 'admin' });
    const e = await t
      .req('post', '/admin/store-tablets', enroller, {
        stepUp: await t.stepUp(enroller, 'kiosk.manage'),
        idem: randomUUID(),
      })
      .send({ name: 'Планшет подключения заново', warehouseId });
    expect(e.status, JSON.stringify(e.body)).toBe(201);
    const id = String(e.body.tablet.id);
    const before: Subject = { token: String(e.body.accessToken), deviceKey: enroller.deviceKey };
    const row = async () => {
      const r = await t.q<SeenRow & Record<string, unknown>>(
        `SELECT last_seen_at, last_app_version, lock_task_enabled FROM store_tablets WHERE id = $1`,
        [id],
      );
      const found = r[0];
      if (!found) throw new Error('нет строки store_tablets');
      return found;
    };
    clock.advance(1_000);
    expect((await call(t, 'get', '/settings/public', before, { headers: { 'X-Kiosk-Lock': 'on' } })).status).toBe(200);
    const firstSeen = clock.now().getTime();
    expect(await row()).toMatchObject({ lock_task_enabled: true });

    // через 10 с — «Подключить заново этот планшет» (08 §4.18.15) администратором, вошедшим на том же устройстве
    clock.advance(10_000);
    const onDevice = await t.actor({ role: 'admin' });
    await t.q(`UPDATE devices SET device_key = $1 WHERE id = $2`, [enroller.deviceKey, onDevice.deviceId]);
    const pv = await t.q<{ v: number }>(`SELECT permissions_version AS v FROM users WHERE id = $1`, [onDevice.userId]);
    const { token } = await t.jwt.signAccess({
      sub: onDevice.userId,
      kind: 'staff',
      roles: ['admin'],
      permissionsVersion: pv[0]?.v ?? 1,
      deviceId: enroller.deviceKey,
      sid: onDevice.sessionId,
    });
    const reAdmin = { ...onDevice, deviceKey: enroller.deviceKey, token };
    const re = await t
      .req('post', `/admin/store-tablets/${id}/reconnect`, reAdmin, {
        stepUp: await t.stepUp(reAdmin, 'kiosk.manage'),
        idem: randomUUID(),
      })
      .send({});
    expect(re.status, JSON.stringify(re.body)).toBe(200);
    const after: Subject = { token: String(re.body.accessToken), deviceKey: enroller.deviceKey };
    expect(await row()).toMatchObject({ lock_task_enabled: null });
    expect(ms((await row()).last_seen_at)).toBe(firstSeen);
    expect(await listedOf(t, admin, id)).toMatchObject({ lockTaskEnabled: null });

    // 15 с после отметки прежней сессии: первый сигнал новой сессии — сразу (SCR-54 «Закрепление включено»)
    clock.advance(5_000);
    expect((await call(t, 'get', '/settings/public', after, { headers: { 'X-Kiosk-Lock': 'on' } })).status).toBe(200);
    const seen = clock.now().getTime();
    expect(ms((await row()).last_seen_at)).toBe(seen);
    expect(await listedOf(t, admin, id)).toMatchObject({ lockTaskEnabled: true });
    // дальше — прежнее ограничение 60 с: «off» через 5 с не пишется
    clock.advance(5_000);
    expect((await call(t, 'get', '/cart', after, { headers: { 'X-Kiosk-Lock': 'off' } })).status).toBe(200);
    expect(await row()).toMatchObject({ lock_task_enabled: true });
    expect(ms((await row()).last_seen_at)).toBe(seen);
    // другой процесс (своя память): без заголовка и при уже известном значении — раньше 60 с не пишет
    const twin = new KioskPresenceService(t.db, clock);
    expect(await twin.mark(id, { appVersion: null, lockTaskEnabled: null }, randomUUID())).toBe(false);
    expect(await twin.mark(id, { appVersion: null, lockTaskEnabled: false }, randomUUID())).toBe(false);
    expect(await row()).toMatchObject({ lock_task_enabled: true });
    // прежняя сессия отозвана подключением заново
    expect((await call(t, 'get', '/cart', before)).body.code).toBe('KIOSK_REVOKED');
  });

  it('T-KIOSK-050 last_app_version shown in GET list: X-App-Version → StoreTablet.appVersion', async () => {
    const tab = await t.tablet();
    const versionAfter = async (headers: Record<string, string>) => {
      clock.advance(61_000);
      expect((await call(t, 'get', '/settings/public', tab, { headers })).status).toBe(200);
      const column = (await seenOf(t, tab)).last_app_version;
      expect((await listedOf(t, admin, tab.tabletId)).appVersion).toBe(column);
      return column;
    };
    expect(await versionAfter({ 'X-App-Version': '1.4.2+87', 'X-Platform': 'android' })).toBe('1.4.2+87');
    expect(await versionAfter({})).toBe('1.4.2+87'); // без заголовка — не меняется
    expect(await versionAfter({ 'X-App-Version': 'abc' })).toBe('1.4.2+87'); // неразборчивая — не меняется
    expect(await versionAfter({ 'X-App-Version': '1.5.0', 'X-Platform': 'android' })).toBe('1.5.0');
  });

  it('T-KIOSK-064 last_seen_at throttle: не чаще раза в 60 с, GET /settings/public — отметка простаивающего планшета', async () => {
    const tab = await t.tablet();
    expect((await call(t, 'get', '/cart', tab)).status).toBe(200);
    const first = clock.now().getTime();
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(first);
    clock.advance(30_000);
    expect((await call(t, 'get', '/settings/public', tab)).status).toBe(200);
    expect((await call(t, 'get', '/catalog/categories', tab)).status).toBe(200);
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(first);
    clock.advance(30_000); // ровно 60 с — уже можно
    expect((await call(t, 'get', '/settings/public', tab)).status).toBe(200);
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(first + 60_000);
    // второй процесс pos-api (своя память) не пишет раньше 60 с — условие UPDATE
    const twin = new KioskPresenceService(t.db, clock);
    clock.advance(20_000);
    expect(await twin.mark(tab.tabletId, { appVersion: null, lockTaskEnabled: null })).toBe(false);
    expect(ms((await seenOf(t, tab)).last_seen_at)).toBe(first + 60_000);
    // сотрудник store_tablets не трогает
    const before = await t.q(`SELECT id, updated_at FROM store_tablets ORDER BY id`);
    clock.advance(61_000);
    expect((await call(t, 'get', '/settings/public', seller)).status).toBe(200);
    expect(await t.q(`SELECT id, updated_at FROM store_tablets ORDER BY id`)).toEqual(before);
  });

  it('T-KIOSK-064 offline in/out of working hours, empty hours = off: > 15 мин только в часы работы', async () => {
    const now = clock.now();
    const a = await t.tablet({ name: 'Планшет А' });
    const b = await t.tablet({ name: 'Планшет Б' });
    const c = await t.tablet({ name: 'Планшет В' });
    const at = (minAgo: number) => new Date(now.getTime() - minAgo * MIN_MS);
    await t.q(`UPDATE store_tablets SET last_seen_at = $2, enrolled_at = $3 WHERE id = $1`, [
      a.tabletId,
      at(16),
      at(60),
    ]);
    await t.q(`UPDATE store_tablets SET last_seen_at = $2, enrolled_at = $3 WHERE id = $1`, [
      b.tabletId,
      at(10),
      at(60),
    ]);
    await t.q(`UPDATE store_tablets SET last_seen_at = NULL, enrolled_at = $2 WHERE id = $1`, [c.tabletId, at(30)]);
    const offline = async () => {
      const f = await alerts.runChecks();
      return {
        a: firingOf(f, 'kiosk.offline', a.tabletId),
        b: firingOf(f, 'kiosk.offline', b.tabletId),
        c: firingOf(f, 'kiosk.offline', c.tabletId),
      };
    };

    // пустая настройка и ключа нет — алерт выключен (Q-341; ответ владельца 2026-11-04 «Пока заглушки»)
    await setSetting('kiosk_working_hours', null);
    expect(await offline()).toEqual({ a: [], b: [], c: [] });
    await setSetting('kiosk_working_hours', JSON.stringify(''));
    expect(await offline()).toEqual({ a: [], b: [], c: [] });
    await setSetting('kiosk_working_hours', JSON.stringify('всегда')); // неверный формат — тоже выключен
    expect(await offline()).toEqual({ a: [], b: [], c: [] });

    // вне часов работы — алерта нет
    await setSetting('kiosk_working_hours', JSON.stringify('mon-sun 14:00-20:00'));
    expect(await offline()).toEqual({ a: [], b: [], c: [] });
    // отсчёт — с начала часов работы: открылись 10 мин назад — ещё не 15 мин «в часы работы»
    await setSetting('kiosk_working_hours', JSON.stringify(`mon-sun ${bishkekHhMm(now, 10)}-23:00`));
    expect(await offline()).toEqual({ a: [], b: [], c: [] });

    // в часы работы: 16 мин без связи и подключён 30 мин назад без единого запроса — алерт; 10 мин — нет
    await setSetting('kiosk_working_hours', JSON.stringify('mon-sun 08:00-20:00'));
    const inHours = await offline();
    expect(inHours).toEqual({
      a: [{ alert: 'kiosk.offline', tabletId: a.tabletId, raised: true }],
      b: [],
      c: [{ alert: 'kiosk.offline', tabletId: c.tabletId, raised: true }],
    });
    expect(alertLogs('kiosk.offline', a.tabletId)).toEqual([expect.objectContaining({ minutes: 16 })]);
    expect(notes('kiosk.offline', a.tabletId)).toEqual([
      expect.objectContaining({ userId: admin.userId, kind: 'system', severity: 'warning' }),
    ]);
    expect(notes('kiosk.offline', a.tabletId)[0]?.body).toContain('«Планшет А»');
    noPii([alertLogs('kiosk.offline', a.tabletId), notes('kiosk.offline', a.tabletId)]);
    // повтор задачи через 5 мин — тот же эпизод, алерт не повторяется
    expect((await offline()).a).toEqual([{ alert: 'kiosk.offline', tabletId: a.tabletId, raised: false }]);
    expect(notes('kiosk.offline', a.tabletId)).toHaveLength(1);
    await setSetting('kiosk_working_hours', null);
  });

  it('T-KIOSK-063 ≥ 10 codes / 10 min alert without phones/IP: коды выдаются дальше в пределах лимита', async () => {
    const tab = await t.tablet({ name: 'Планшет у входа' });
    const cartId = await fillCart(t, tab, variant);
    for (let i = 0; i < 9; i += 1) expect((await orderOtp(tab, cartId)).status).toBe(202);
    expect(firingOf(await alerts.runChecks(), 'kiosk.otp_burst', tab.tabletId)).toEqual([]);
    expect((await orderOtp(tab, cartId)).status).toBe(202);
    expect(firingOf(await alerts.runChecks(), 'kiosk.otp_burst', tab.tabletId)).toEqual([
      { alert: 'kiosk.otp_burst', tabletId: tab.tabletId, raised: true },
    ]);
    // лимит часа (30) не исчерпан — коды выдаются дальше; повтор задачи в том же окне алерт не повторяет
    expect((await orderOtp(tab, cartId)).status).toBe(202);
    expect(firingOf(await alerts.runChecks(), 'kiosk.otp_burst', tab.tabletId)).toEqual([
      { alert: 'kiosk.otp_burst', tabletId: tab.tabletId, raised: false },
    ]);
    expect(alertLogs('kiosk.otp_burst', tab.tabletId)).toEqual([
      expect.objectContaining({ count: 10, threshold: 10, windowMinutes: 10 }),
    ]);
    const n = notes('kiosk.otp_burst', tab.tabletId);
    expect(n).toHaveLength(1);
    expect(n[0]?.body).toContain('«Планшет у входа»');
    noPii([alertLogs('kiosk.otp_burst', tab.tabletId), n]);
    await t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false }).drain();
  });

  it('T-KIOSK-017 daily limit alert: исчерпан суточный лимит кодов планшета — алерт задачи kiosk.alerts', async () => {
    await setSetting('kiosk_otp_per_day', '3');
    try {
      const tab = await t.tablet();
      const cartId = await fillCart(t, tab, variant);
      for (let i = 0; i < 2; i += 1) expect((await orderOtp(tab, cartId)).status).toBe(202);
      expect(firingOf(await alerts.runChecks(), 'kiosk.limit_reached', tab.tabletId)).toEqual([]);
      // третий код из трёх — лимит суток исчерпан (следующий запрос получит 429): алерт задачи
      expect((await orderOtp(tab, cartId)).status).toBe(202);
      expect(firingOf(await alerts.runChecks(), 'kiosk.limit_reached', tab.tabletId)).toEqual([
        { alert: 'kiosk.limit_reached', tabletId: tab.tabletId, raised: true },
      ]);
      const r = await orderOtp(tab, cartId);
      expect([r.status, r.body.code]).toEqual([429, 'KIOSK_RATE_LIMITED']);
      // отказ квоту не расходует — то же окно, алерт задачи не повторяется
      expect(firingOf(await alerts.runChecks(), 'kiosk.limit_reached', tab.tabletId)).toEqual([
        { alert: 'kiosk.limit_reached', tabletId: tab.tabletId, raised: false },
      ]);
      // лог: отказ 429 (WP-S3) и задача — без телефона; уведомление администратору — от задачи
      const logs = alertLogs('kiosk.limit_reached', tab.tabletId);
      expect(logs).toEqual(
        expect.arrayContaining([expect.objectContaining({ scope: 'otp_kiosk_tablet_24h', limit: 3 })]),
      );
      const n = notes('kiosk.limit_reached', tab.tabletId);
      expect(n).toHaveLength(1);
      expect(n[0]?.body).toContain('за сутки (3)');
      noPii([logs, n]);
    } finally {
      await setSetting('kiosk_otp_per_day', null);
      await t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false }).drain();
    }
  });

  it('T-KIOSK-065 29 days left, version below recommended: алерт о конце подключения и о версии', async () => {
    const soon = await t.tablet({ name: 'Планшет 29 дней' });
    const later = await t.tablet({ name: 'Планшет 31 день' });
    const now = clock.now().getTime();
    await t.q(`UPDATE sessions SET expires_at = $2 WHERE id = $1`, [soon.sessionId, new Date(now + 29 * DAY_MS)]);
    await t.q(`UPDATE sessions SET expires_at = $2 WHERE id = $1`, [later.sessionId, new Date(now + 31 * DAY_MS)]);
    await t.q(`UPDATE store_tablets SET last_app_version = '1.4.2+87' WHERE id = $1`, [soon.tabletId]);
    await t.q(`UPDATE store_tablets SET last_app_version = '1.5.0' WHERE id = $1`, [later.tabletId]);
    await setSetting('recommended_app_version', JSON.stringify('android=1.5.0,windows=1.5.0'));
    try {
      const f = await alerts.runChecks();
      expect(firingOf(f, 'kiosk.session_expiring', soon.tabletId)).toEqual([
        { alert: 'kiosk.session_expiring', tabletId: soon.tabletId, raised: true },
      ]);
      expect(firingOf(f, 'kiosk.session_expiring', later.tabletId)).toEqual([]);
      expect(alertLogs('kiosk.session_expiring', soon.tabletId)).toEqual([
        expect.objectContaining({ daysLeft: 29, thresholdDays: 30 }),
      ]);
      expect(notes('kiosk.session_expiring', soon.tabletId)[0]?.body).toContain('до конца подключения 29 дн.');

      expect(firingOf(f, 'kiosk.app_outdated', soon.tabletId)).toEqual([
        { alert: 'kiosk.app_outdated', tabletId: soon.tabletId, raised: true },
      ]);
      expect(firingOf(f, 'kiosk.app_outdated', later.tabletId)).toEqual([]);
      expect(alertLogs('kiosk.app_outdated', soon.tabletId)).toEqual([
        expect.objectContaining({ version: '1.4.2+87', recommended: '1.5.0', platform: 'android' }),
      ]);
      noPii([alertLogs('kiosk.session_expiring', soon.tabletId), notes('kiosk.app_outdated', soon.tabletId)]);

      // отключённый планшет алертов не даёт
      await t.revokeTablet(soon.tabletId);
      const g = await alerts.runChecks();
      expect(g.filter((x) => x.tabletId === soon.tabletId)).toEqual([]);
    } finally {
      await setSetting('recommended_app_version', null);
    }
  });

  it('задача kiosk.alerts: очередь, обработчик и расписание раз в 5 мин (Asia/Bishkek); при KIOSK_MODE=false — пусто', async () => {
    const calls: string[] = [];
    let handler: (() => Promise<unknown>) | undefined;
    const boss = {
      getQueue: () => Promise.resolve(null),
      createQueue: (name: string, o: { policy: string }) => {
        calls.push(`create ${name} ${o.policy}`);
        return Promise.resolve();
      },
      work: (name: string, _o: unknown, fn: () => Promise<unknown>) => {
        calls.push(`work ${name}`);
        handler = fn;
        return Promise.resolve('w');
      },
      schedule: (name: string, cron: string, _d: unknown, o: { tz: string; singletonKey: string }) => {
        calls.push(`schedule ${name} ${cron} ${o.tz} ${o.singletonKey}`);
        return Promise.resolve();
      },
    } as unknown as PgBoss;
    await alerts.register(boss);
    expect(calls).toEqual([
      'create kiosk.alerts singleton',
      'work kiosk.alerts',
      `schedule kiosk.alerts ${KIOSK_ALERTS_CRON} Asia/Bishkek kiosk.alerts`,
    ]);
    expect(KIOSK_ALERTS_CRON).toBe('*/5 * * * *');
    expect(await handler?.()).toEqual({ alerts: expect.any(Number), raised: expect.any(Number) });

    // KIOSK_MODE=false: проверки не выполняются (планшеты отвечают KIOSK_DISABLED)
    const off = new KioskAlertsService(
      t.db,
      clock,
      { KIOSK_MODE: false, WORKERS_ENABLED: false },
      t.app.get(AuditService),
      t.app.get(SettingsReader),
      t.app.get(AppVersionPolicy),
      t.fakes?.notifications as never,
    );
    expect(await off.runChecks()).toEqual([]);
  });
});

describe('kiosk: общий лимит SEC-015 раньше проверок планшета (KIOSK_ALLOWED_CIDRS задана; RL-READ стенда = 3)', () => {
  const t = new KioskTestApp();
  const clock = new FixedClock(nearestBishkekNoon(Date.now()));
  let seller: PosActor;

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true', KIOSK_ALLOWED_CIDRS: STORE_CIDRS },
      skuCount: 10,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      // Лимит понижен только для стенда (значение по умолчанию — 08 §2.9 RL-READ, 600/мин).
      providers: [{ provide: HTTP_RATE_LIMITS, useValue: { 'RL-READ': 3 } }],
      fakePorts: true,
      jobs: false,
      clock,
    });
    seller = await t.actor({ role: 'seller' });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-048 T-SEC-005 general limit before network check: 3×403 KIOSK_NETWORK_DENIED, затем 429 RATE_LIMITED без аудита; сотрудник — без лимита guard-а', async () => {
    const tab = await t.tablet({ name: 'Планшет лимита' });
    interface Reply extends Res {
      readonly headers: Readonly<Record<string, string | undefined>>;
    }
    const me = async (a: Subject, ip: string): Promise<Reply> => {
      const r = await t.req('get', '/me', a).set('X-Forwarded-For', ip);
      return { status: r.status, body: (r.body ?? {}) as Res['body'], headers: r.headers };
    };
    const deniedAudit = async () =>
      (
        await t.q<{ n: number }>(
          `SELECT count(*)::int AS n FROM audit_logs WHERE action = 'kiosk.network_denied' AND entity_id = $1`,
          [tab.tabletId],
        )
      )[0]?.n;

    const replies: Reply[] = [];
    for (let i = 0; i < 4; i += 1) replies.push(await me(tab, OUTSIDE_IP));
    expect(replies.slice(0, 3).map((r) => [r.status, r.body.code as unknown])).toEqual([
      [403, 'KIOSK_NETWORK_DENIED'],
      [403, 'KIOSK_NETWORK_DENIED'],
      [403, 'KIOSK_NETWORK_DENIED'],
    ]);
    const limited = replies[3];
    expect([limited?.status, limited?.body.code]).toEqual([429, 'RATE_LIMITED']);
    expect(Number(limited?.headers['retry-after'])).toBeGreaterThan(0);
    expect(limited?.headers['x-ratelimit-limit']).toBe('3');
    expect(limited?.headers['x-ratelimit-remaining']).toBe('0');
    // 4-й запрос отклонён до проверки сети: аудита и алерта нет (3 строки — по одной на отказ сети)
    expect(await deniedAudit()).toBe(3);
    // лимит общий для всех запросов планшета: из сети магазина в том же окне — тоже 429, отметки связи нет
    const inside = await me(tab, STORE_IP);
    expect([inside.status, inside.body.code]).toEqual([429, 'RATE_LIMITED']);
    expect((await seenOf(t, tab)).last_seen_at).toBeNull();
    expect(await deniedAudit()).toBe(3);

    // Сотрудник с тем же числом запросов guard-ом планшета не ограничивается (сеть и лимит — только kind=kiosk).
    for (let i = 0; i < 5; i += 1) {
      const r = await me(seller, OUTSIDE_IP);
      expect([r.status, r.body.code], `сотрудник, запрос ${i + 1}`).toEqual([200, undefined]);
    }

    // Следующее окно: планшет в сети магазина снова работает (сессия не отозвана).
    clock.advance(60_000);
    const next = await me(tab, STORE_IP);
    expect(next.status, JSON.stringify(next.body)).toBe(200);
    expect(next.body).toMatchObject({ kind: 'kiosk', tablet: { id: tab.tabletId } });
  });
});
