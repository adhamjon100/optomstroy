import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { customerModeOrDeny, SUBJECT_KINDS } from './subject-kind.js';

/**
 * Сканер двоичных проверок вида субъекта (06 ARCH-065, AC-ARCH-065 (2); 08 §4.25 «Классификация субъекта»; 11 SEC-137
 * (6); P-002 §8.3, задача TAB-1-03 «список всех двоичных проверок `kind` в `pos-api/src` и решение по каждой»; риск
 * RR-T11 «пропущена одна из двоичных проверок — планшет получает данные или действия сотрудника»).
 *
 * Сканируются `pos-api/src/**\/*.ts` без `*.spec.ts` и без строк комментариев. Место проверки — строка с одним из
 * признаков `PATTERNS`: сравнение вида с `'staff'`/`'customer'` (`===`, `!==`, SQL `=`/`<>`), пересборка вида тернарником
 * (`? 'customer' : 'staff'`), роль `customer` (`roles.includes('customer')`, `role === 'customer'`), значение
 * `isCustomer:` в литерале объекта (кроме типа `boolean` и передачи `….isCustomer` как есть), `viewers.isCustomer(…)`.
 * Каждое место стоит в `SITES` (файл + строка без отступов + число совпадений) с решением для `kind=kiosk`:
 * - `buyer` — ветка покупателя без подтверждённой привязки (каталог, цена, наличие, корзина);
 * - `deny` — `403` (модули вне закрытого списка планшета: отказ по умолчанию, ветка сотрудника не достаётся);
 * - `keep` — планшет сюда не доходит (закрытый список маршрутов, права роли, нет телефона/PIN): прежняя ветка;
 * - `staff-only` — ветка сотрудника после отсечения покупателя и планшета выше по коду;
 * - `pending` — решение за пакетом-владельцем (`owner`), до него `kind=kiosk` таких записей не создаёт;
 * - `not-subject` — не вид субъекта (вид получателя, ветка регистрации, канал заказа).
 * Новая проверка без решения или устаревшая строка `SITES` — тест красный: при правке такой строки решение для
 * `kind=kiosk` пересматривается и записывается здесь же. `TAB_1_03` — номера исходного перечня мест (51 строка и «+»):
 * каждое либо в `SITES`, либо в `RESOLVED` (место заменено исчерпывающим разбором или вне признаков сканера).
 */

type Decision = 'buyer' | 'deny' | 'keep' | 'staff-only' | 'pending' | 'not-subject';

interface Site {
  readonly file: string;
  /** Строка исходника без отступов (как после prettier). */
  readonly code: string;
  /** Число совпадений признаков в строке (по умолчанию 1). */
  readonly count?: number;
  readonly decision: Decision;
  /** Решение для `kind=kiosk` (и почему). */
  readonly why: string;
  /** Номер места исходного перечня TAB-1-03 (`№15`, `+adapter`); нет — место не из перечня. */
  readonly tab?: string;
  /** Пакет, за которым решение `pending`. */
  readonly owner?: string;
}

const PATTERNS: readonly (readonly [string, RegExp])[] = [
  ['kind-compare', /\bkind\s*(?:={1,3}|!={1,2}|<>)\s*'(?:staff|customer)'/g],
  ['kind-compare-reversed', /'(?:staff|customer)'\s*(?:={2,3}|!={1,2})\s*[\w.?]*\bkind\b/g],
  ['kind-ternary', /\?\s*'(?:customer|staff)'\s*:\s*'(?:staff|customer)'/g],
  ['role-customer', /\broles\??\.includes\(\s*'customer'\s*\)|\brole\s*(?:={2,3}|!={1,2})\s*'customer'/g],
  ['is-customer-literal', /\bisCustomer\??\s*:(?!\s*boolean\b)(?!\s*[\w.?]*\bisCustomer\s*(?:[,})]|$))/g],
  ['viewer-is-customer', /\bviewers?\.isCustomer\(/g],
];

const SITES: readonly Site[] = [
  // ------------------------------------------------------------------------------------------------ auth, сессии
  {
    file: 'src/auth/sessions/refresh.service.ts',
    code: "const windowsStaff = user.kind === 'staff' && device.platform === 'windows';",
    decision: 'keep',
    tab: '№3',
    why: 'блокировка простоя Windows-сотрудника при refresh; у планшета PIN нет — не применяется',
  },
  {
    file: 'src/auth/sessions/session-activity.guard.ts',
    code: "if (p.kind === 'staff' && !isAllowedWithoutPin(req) && !(await this.hasPin(p.userId, now))) {",
    decision: 'keep',
    tab: '№4',
    why: 'правило D-48 «сотрудник без PIN» к kiosk не относится (08 §4.25 «Порядок проверок»); у планшета свой закрытый список',
  },
  {
    file: 'src/auth/login/login.service.ts',
    code: "if (!user || user.id !== emergency.userId || user.kind !== 'staff' || user.status !== 'active') {",
    decision: 'keep',
    tab: '№5',
    why: 'вход по аварийному коду — только сотрудник; у планшета нет телефона (users_kiosk_phone_chk) — отказ',
  },
  {
    file: 'src/auth/login/login.service.ts',
    code: "const pinMissingStaff = user.kind === 'staff' && !me.security.pinSet;",
    decision: 'keep',
    tab: '№6',
    why: 'ответ входа по SMS; планшет по SMS не входит (нет телефона)',
  },
  {
    file: 'src/registration/registration.service.ts',
    code: "if (kind === 'staff') {",
    decision: 'keep',
    tab: '№7',
    why: 'PIN обязателен сотруднику при регистрации; планшет не регистрируется (подключение — POST /admin/store-tablets)',
  },
  {
    file: 'src/registration/registration.service.ts',
    code: "} else if (branch.kind === 'customer') {",
    decision: 'not-subject',
    why: 'ветка регистрации (приглашение сотрудника или покупатель), а не вид субъекта запроса; планшет не регистрируется',
  },
  {
    file: 'src/registration/registration.service.ts',
    code: "this.cryptoBiometrics(body.device) && (branch.kind === 'customer' || pinHash !== undefined),",
    decision: 'not-subject',
    why: 'ветка регистрации (биометрия без PIN — только покупателю); планшет не регистрируется',
  },
  // ----------------------------------------------------------------------------------------------------- admin
  {
    file: 'src/admin/users/admin-users.service.ts',
    code: "if (record.role === role && record.kind === 'staff') return toAdminUserDto(record, isAdminActor(actor));",
    decision: 'staff-only',
    tab: '№8',
    why: 'цель kind=kiosk отклонена раньше — canAssignRole первой проверкой 403 kiosk_target (11 SEC-142, T-2); здесь staff и customer',
  },
  {
    file: 'src/admin/users/shared/target-policy.ts',
    code: "if (target.kind === 'customer') return forbid('customer_target');",
    decision: 'staff-only',
    tab: '№10',
    why: 'сброс PIN: цель kind=kiosk отклонена первой проверкой canResetPin (403 kiosk_target, 11 SEC-142); здесь staff и customer',
  },
  {
    file: 'src/admin/users/shared/target-policy.ts',
    code: "if (target.kind !== 'staff' || target.status !== 'active') {",
    decision: 'staff-only',
    tab: '№11',
    why: 'аварийный код входа: цель kind=kiosk — 403 kiosk_target первой проверкой (11 SEC-043, SEC-142), а не 422',
  },
  {
    file: 'src/admin/users/emergency-code/emergency-code.service.ts',
    code: "if (!user || user.kind !== 'staff' || user.status !== 'active' || user.phoneE164 !== phone) {",
    decision: 'keep',
    tab: '№12',
    why: 'та же проверка в транзакции выдачи кода: не сотрудник — отказ',
  },
  {
    file: 'src/admin/invitations/admin-invitations.service.ts',
    code: "existing.kind === 'customer'",
    decision: 'keep',
    tab: '№13',
    why: 'текст ошибки «номер занят»; у планшета нет телефона — совпадения по номеру не бывает',
  },
  {
    file: 'src/admin/invitations/admin-invitations.service.ts',
    code: "reason: existing.kind === 'customer' ? 'customer_account' : 'staff_account',",
    decision: 'keep',
    tab: '№14',
    why: 'причина «номер занят»; у планшета нет телефона',
  },
  {
    file: 'src/admin/reports/admin-reports.controller.ts',
    code: "if (principalOf(req).kind !== 'staff') {",
    decision: 'deny',
    tab: '№15',
    why: 'отчёты — только сотрудникам: customer, kiosk и любой иной вид — 403',
  },
  {
    file: 'src/admin/audit/admin-audit.controller.ts',
    code: "if (p.kind !== 'staff') throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });",
    decision: 'deny',
    tab: '№16',
    why: 'журнал аудита — только сотрудникам: customer, kiosk и любой иной вид — 403',
  },
  {
    file: 'src/admin/audit/admin-audit.controller.ts',
    code: 'isCustomer: false,',
    decision: 'staff-only',
    tab: '№16',
    why: 'актор журнала аудита строится после проверки «только staff» строкой выше',
  },
  {
    file: 'src/admin/bootstrap/first-admin.ts',
    code: "WHERE u.phone_e164 IS NULL AND u.kind = 'staff' AND u.status = 'deleted' AND p.full_name = ${BOOTSTRAP_INVITER_NAME}",
    decision: 'keep',
    tab: '+first-admin',
    why: 'поиск служебного «пригласившего» первичной настройки (SQL); технический пользователь планшета — kind=kiosk, не совпадает',
  },
  // --------------------------------------------------------------------------------------------------- profile
  {
    file: 'src/profile/me/me.service.ts',
    code: "!pending && kind === 'customer' ? this.links.meLink(userId, ex) : Promise.resolve(undefined),",
    decision: 'keep',
    tab: '№17',
    why: 'GET /me планшета — своя форма {kind, tablet} (MeService.buildKiosk), сюда не доходит',
  },
  {
    file: 'src/profile/me/me.service.ts',
    code: "!pending && kind === 'staff' ? this.discountLimit(roles, ex) : Promise.resolve(undefined),",
    decision: 'keep',
    tab: '№18',
    why: 'GET /me планшета — своя форма, лимита скидки нет',
  },
  {
    file: 'src/profile/me/settings.projection.ts',
    code: "const idleDefault = ctx.kind === 'staff' ? ctx.staffIdleMinutes : ctx.customerIdleMinutes;",
    decision: 'keep',
    tab: '№19',
    why: 'settingsFromProfile (тип вида расширен WP-F1A-TS): не staff — значение покупателя; kiosk не доходит — /me/settings вне закрытого списка, /me — форма планшета',
  },
  {
    file: 'src/profile/profile.service.ts',
    code: "p.kind === 'staff' ? this.me.settingsContext('staff', p.roles).staffIdleMinutes : IDLE_LOCK_MAX_CUSTOMER;",
    decision: 'keep',
    tab: '№20',
    why: 'PUT /me/settings: у роли kiosk нет profile.manage.own, маршрут вне закрытого списка',
  },
  {
    file: 'src/profile/me-security.controller.ts',
    code: "@RequireStepUp({ operation: PROFILE_STEP_UP.pinSet, when: (req) => req.principal?.kind === 'customer' })",
    decision: 'keep',
    tab: '№21',
    why: '/me/pin — вне закрытого списка планшета (403 kiosk_closed_list)',
  },
  {
    file: 'src/profile/security.service.ts',
    code: "if (p.kind !== 'customer') {",
    decision: 'keep',
    tab: '№22',
    why: 'DELETE /me/pin — не покупатель → 403; планшету маршрут закрыт',
  },
  {
    file: 'src/profile/security.service.ts',
    code: "(kind === 'staff' ? this.config.AUTH_REFRESH_TTL_STAFF_DAYS : this.config.AUTH_REFRESH_TTL_CUSTOMER_DAYS) * DAY_MS",
    decision: 'keep',
    tab: '№23',
    why: 'biometricTtlMs (тип вида расширен WP-F1A-TS): биометрии у планшета нет, /me/biometrics закрыт',
  },
  {
    file: 'src/profile/security.service.ts',
    code: "return kind === 'staff'",
    decision: 'keep',
    tab: '№24',
    why: 'biometricIdleMs (тип вида расширен WP-F1A-TS): биометрии у планшета нет',
  },
  {
    file: 'src/profile/security.service.ts',
    code: "if (p.kind === 'customer' && (await this.pins.find(p.userId)) === undefined) {",
    decision: 'keep',
    tab: '№25',
    why: 'отключение биометрии покупателем без PIN; планшету маршрут закрыт',
  },
  {
    file: 'src/profile/domain/profile-rules.ts',
    code: "return kind === 'staff' ? Math.max(PIN_MIN_LENGTH_CUSTOMER, Math.min(6, staffMinLength)) : PIN_MIN_LENGTH_CUSTOMER;",
    decision: 'keep',
    tab: '№26',
    why: 'pinMinLength (тип вида расширен WP-F1A-TS): у планшета PIN нет (09 §8.9), /me/pin закрыт',
  },
  // ------------------------------------------------------------------------------------------- каталог, корзина
  {
    file: 'src/catalog/common/catalog-viewer.ts',
    code: "return isBuyerLike(subjectKindOf(principal)) || principal.roles.includes('customer');",
    decision: 'buyer',
    tab: '№28',
    why: 'ветка покупателя каталога: customer и kiosk (покупатель без привязки), роль customer при виде staff — как прежде',
  },
  {
    file: 'src/cart/cart-actor.ts',
    code: "const declared = actor.subjectKind ?? (actor.isCustomer ? 'customer' : 'staff');",
    decision: 'buyer',
    tab: '№32',
    why: 'вид актора порта — SalesActor.subjectKind (актор планшета задаёт kiosk всегда); построители до ADR-115 — по isCustomer',
  },
  {
    file: 'src/cart/cart-actor.ts',
    code: "staff: () => (roles.includes('customer') ? 'customer' : 'staff'),",
    count: 2,
    decision: 'buyer',
    tab: '№31',
    why: 'withCustomerRole: роль customer при виде staff — покупатель, как прежде; kiosk — свой вид (флаг KIOSK_MODE, не CUSTOMER_SELF_SERVICE)',
  },
  {
    file: 'src/cart/customer-view.ts',
    code: "if (isCustomer || role === 'customer') {",
    decision: 'buyer',
    tab: '№33',
    why: 'карточка клиента в корзине: для kiosk — null раньше этой строки (11 SEC-141), клиента в корзине планшета нет',
  },
  {
    file: 'src/cart/cart.service.ts',
    code: '(await this.pricing.resolveFor(tx, { userId: a.userId, role: a.role, isCustomer: false, customerId: null })) ??',
    decision: 'staff-only',
    why: 'DELETE /cart/customer: kiosk — 403, customer — без изменений выше по коду; дальше только сотрудник',
  },
  {
    file: 'src/cart/cart.service.ts',
    code: 'isCustomer: false,',
    decision: 'staff-only',
    why: 'POST /cart/discount: покупатель и планшет (isCustomer) отклонены 403 в начале applyDiscount',
  },
  {
    file: 'src/cart/cart-requests.ts',
    code: "if (v.kind !== 'customer' && v.kind !== 'other_person') {",
    decision: 'not-subject',
    why: 'вид получателя (receiver.kind), а не вид субъекта',
  },
  {
    file: 'src/sales-domain/adapters/catalog-inventory-check.adapter.ts',
    code: "const kind = actor.subjectKind ?? (actor.isCustomer ? 'customer' : 'staff');",
    decision: 'buyer',
    tab: '+adapter',
    why: 'проверка наличия порта: вид — SalesActor.subjectKind (kiosk не превращается в customer и не попадает под CUSTOMER_SELF_SERVICE); склад зрителя — склад планшета',
  },
  {
    file: 'src/common/ports/sales-context.ts',
    code: 'export const SYSTEM_ACTOR: SalesActor = Object.freeze({ userId: null, roles: [], isCustomer: false });',
    decision: 'not-subject',
    why: 'системный актор (job, автовоид) — без пользователя, не вид субъекта запроса',
  },
  // ------------------------------------------------------------------------------------------------- customers
  {
    file: 'src/customers/favorites/favorites-products.service.ts',
    code: 'if (!row || (row.deletion_mark && this.viewers.isCustomer(principal))) {',
    decision: 'keep',
    tab: '№34',
    why: 'избранное вне закрытого списка и прав роли kiosk; для kiosk ветка была бы покупательской (удалённые скрыты)',
  },
  {
    file: 'src/customers/common/customer-access.ts',
    code: "const isCustomer = customerModeOrDeny(principal.kind, forbidden) || principal.roles.includes('customer');",
    decision: 'deny',
    tab: '№35',
    why: 'данные клиентов (HTTP) вне закрытого списка и прав роли kiosk: kind=kiosk и вид вне перечня — 403',
  },
  {
    file: 'src/customers/common/customer-access.ts',
    code: "return policyFor(actor.roles, permissions, actor.isCustomer || actor.roles.includes('customer'));",
    decision: 'buyer',
    tab: '№36',
    why: 'политика полей актора порта: актор планшета isCustomer=true → «self» без своих прав; карточку kiosk всё равно не получает (CustomerReader → null)',
  },
  {
    file: 'src/customers/reader/pg-customer-reader.ts',
    code: "if (actor.isCustomer || actor.roles.includes('customer')) {",
    decision: 'buyer',
    tab: '№41',
    why: 'CustomerReader.getForActor: для kiosk — null раньше этой строки (покупатель без привязки); customer — только своя карточка',
  },
  {
    file: 'src/customers/links/customer-links.service.ts',
    code: "if (!user || user.kind !== 'customer') return { status: 'none', linkId: null, nextStep: 'none' };",
    decision: 'keep',
    tab: '№38',
    why: 'автопривязка при регистрации — только покупатель; kiosk — none (привязок у планшета нет)',
  },
  {
    file: 'src/customers/links/customer-links.service.ts',
    code: "if (principal.kind !== 'customer') return { status: 'none', linkId: null, customer: null, nextStep: 'none' };",
    decision: 'keep',
    tab: '№39',
    why: 'GET /me/customer-match — не покупатель → none; планшету /me/* закрыт',
  },
  {
    file: 'src/customers/links/customer-links.service.ts',
    code: "if (principal.kind !== 'customer') {",
    decision: 'keep',
    tab: '№40',
    why: 'подтверждение/отклонение привязки — не покупатель → 403',
  },
  {
    file: 'src/customers/discounts/discounts.service.ts',
    code: 'isCustomer: customerModeOrDeny(p.kind, () => {',
    decision: 'deny',
    tab: '№37',
    why: 'правила скидок вне закрытого списка и прав роли kiosk: kind=kiosk — 403',
  },
  {
    file: 'src/customers/receivables/receivables.service.ts',
    code: 'isCustomer: customerModeOf(p),',
    decision: 'deny',
    tab: '№42',
    why: 'долги вне закрытого списка и прав роли kiosk: customerModeOf — kind=kiosk → 403 (и в view №43, refresh №44)',
  },
  // ---------------------------------------------------------------------------------- orders, payments, прочее
  {
    file: 'src/orders/order-access.ts',
    code: 'isCustomer: isBuyerLike(p.kind),',
    decision: 'buyer',
    tab: '№47',
    why: 'salesActorOf: kiosk — покупатель без привязки (isCustomer=true) с subjectKind=kiosk; «Мои заказы» карточки ему не видны',
  },
  {
    file: 'src/orders/customer-mode.guard.ts',
    code: "if (isAuthenticatedPrincipal(p) && p.kind === 'customer' && !this.config.CUSTOMER_SELF_SERVICE) {",
    decision: 'keep',
    tab: '№45',
    why: 'флаг режима клиента — только customer; планшет проверяет KIOSK_MODE (guard планшета, 06 ARCH-067), /orders ему закрыт',
  },
  {
    file: 'src/orders/order-create.service.ts',
    code: "customerMode && input.receiver.kind === 'customer' && actor.userId",
    decision: 'not-subject',
    why: 'вид получателя заказа (receiver.kind), а не вид субъекта',
  },
  {
    file: 'src/orders/order-create.service.ts',
    code: "const createdVia = customerMode ? 'customer' : 'staff';",
    decision: 'not-subject',
    why: 'канал заказа orders.created_via; канал kiosk задаёт POST /kiosk/orders (WP-S4C), POST /orders планшету закрыт',
  },
  {
    file: 'src/orders/documents/documents.controller.ts',
    code: 'isCustomer: customerModeOrDeny(p.kind, () => {',
    decision: 'deny',
    tab: '№46',
    why: 'документы вне закрытого списка планшета: kind=kiosk и вид вне перечня — 403',
  },
  {
    file: 'src/payments/api/customer-mode.guard.ts',
    code: "if (isAuthenticatedPrincipal(p) && p.kind === 'customer' && !this.config.CUSTOMER_SELF_SERVICE) {",
    decision: 'keep',
    tab: '№48',
    why: 'флаг режима клиента — только customer; /payments* планшету закрыт',
  },
  {
    file: 'src/payments/api/payments.controller.ts',
    code: 'isCustomer: customerModeOrDeny(p.kind, () => {',
    decision: 'deny',
    tab: '№49',
    why: 'платежи вне закрытого списка планшета: kind=kiosk — 403',
  },
  {
    file: 'src/returns/returns.controller.ts',
    code: 'isCustomer: customerModeOrDeny(p.kind, () => {',
    decision: 'deny',
    tab: '№50',
    why: 'возвраты вне закрытого списка планшета: kind=kiosk — 403',
  },
  {
    file: 'src/transactions/transactions.controller.ts',
    code: 'isCustomer: customerModeOrDeny(p.kind, () => {',
    decision: 'deny',
    tab: '№51',
    why: 'журнал операций вне закрытого списка планшета: kind=kiosk — 403',
  },
  {
    file: 'src/sync/api/sync-outbox.service.ts',
    code: 'actor: { userId: principal.userId, roles: principal.roles, isCustomer: false },',
    decision: 'keep',
    tab: '+sync-outbox',
    why: 'управление outbox — право sync.outbox.manage (admin); /sync/* планшету закрыт (ADR-115 п. 21)',
  },
];

/** Места перечня TAB-1-03 без строки сканера: заменены исчерпывающим разбором или вне признаков сканера. */
const RESOLVED: readonly {
  readonly tab: string;
  readonly decision: Decision;
  readonly why: string;
  readonly owner?: string;
}[] = [
  {
    tab: '№1',
    decision: 'keep',
    why: 'session-issuer.ts sessionTerms — bySubjectKind: staff 7 дн / 24 ч, customer 30 / 14 дн, kiosk своя строка 180 / 7 дн (09 §8.9, Р-22)',
  },
  {
    tab: '№2',
    decision: 'keep',
    why: 'session-issuer.ts maxSessions — bySubjectKind: staff 3, customer 5, kiosk 1 (09 §8.9 п. 2)',
  },
  {
    tab: '№9',
    decision: 'deny',
    why: 'admin-users.service.ts setRoles — switchSubjectKind в транзакции: customer → staff, kiosk → 403 kiosk_target (11 SEC-142, T-2)',
  },
  {
    tab: '№27',
    decision: 'buyer',
    why: 'catalog-viewer.ts assertAllowed — switchSubjectKind: customer — CUSTOMER_SELF_SERVICE, kiosk — KIOSK_MODE (403 KIOSK_DISABLED)',
  },
  {
    tab: '№29',
    decision: 'buyer',
    why: 'catalog-viewer.ts resolve — bySubjectKind: kiosk — обычная цена без клиента, склад только home_warehouse_id, priceListId/warehouseId → 403',
  },
  {
    tab: '№30',
    decision: 'keep',
    why: "catalog-sync.service.ts `kind === 'integration'` → 403 (вне признаков сканера); kiosk — склад зрителя закреплён (warehouseLocked)",
  },
  {
    tab: '№43',
    decision: 'deny',
    why: 'receivables.service.ts view — customerModeOf: kind=kiosk → 403',
  },
  {
    tab: '№44',
    decision: 'deny',
    why: 'receivables.service.ts refresh — customerModeOf: kind=kiosk → 403',
  },
  {
    tab: '+admin-users-sql',
    decision: 'deny',
    why: "admin-users.repository.ts list() — всегда `u.kind <> 'kiosk'`: список SCR-45 без планшетов при любых фильтрах kind/role (11 SEC-142)",
  },
];

const TAB_1_03 = [
  ...Array.from({ length: 51 }, (_, i) => `№${i + 1}`),
  '+adapter',
  '+admin-users-sql',
  '+first-admin',
  '+sync-outbox',
];

const DECISIONS: readonly Decision[] = ['buyer', 'deny', 'keep', 'staff-only', 'pending', 'not-subject'];

const SRC = fileURLToPath(new URL('../../', import.meta.url));
const ROOT = join(SRC, '..');

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) sourceFiles(p, out);
    else if (p.endsWith('.ts') && !p.endsWith('.spec.ts')) out.push(p);
  }
  return out;
}

interface Hit {
  readonly file: string;
  readonly code: string;
  readonly line: number;
  count: number;
}

/** Места с признаками двоичной проверки вида: ключ — файл и строка без отступов. */
function scan(): Map<string, Hit> {
  const hits = new Map<string, Hit>();
  for (const abs of sourceFiles(SRC)) {
    const file = relative(ROOT, abs).replaceAll('\\', '/');
    readFileSync(abs, 'utf8')
      .split('\n')
      .forEach((raw, i) => {
        const code = raw.trim();
        if (code.startsWith('*') || code.startsWith('//') || code.startsWith('/*')) return;
        let n = 0;
        for (const [, re] of PATTERNS) n += code.match(re)?.length ?? 0;
        if (n === 0) return;
        const key = `${file}|${code}`;
        const hit = hits.get(key) ?? { file, code, line: i + 1, count: 0 };
        hit.count += n;
        hits.set(key, hit);
      });
  }
  return hits;
}

describe('AC-ARCH-065 (2): двоичные проверки вида субъекта в pos-api/src — у каждой решение для kind=kiosk', () => {
  const hits = scan();
  const listed = new Map(SITES.map((s) => [`${s.file}|${s.code}`, s]));

  it('AC-ARCH-065 (2) каждая двоичная проверка вида — в перечне решений SITES (новая без решения — красный)', () => {
    const missing = [...hits.values()]
      .filter((h) => !listed.has(`${h.file}|${h.code}`))
      .map((h) => `${h.file}:${h.line} ${h.code} — добавьте в SITES решение для kind=kiosk (buyer/deny/keep/…)`);
    expect(missing).toEqual([]);
    expect(hits.size).toBeGreaterThan(40);
  });

  it('AC-ARCH-065 (2) перечень без устаревших строк: каждое решение указывает на существующую проверку', () => {
    const stale: string[] = [];
    for (const s of SITES) {
      const h = hits.get(`${s.file}|${s.code}`);
      if (!h) stale.push(`${s.file}: «${s.code}» — строки нет, пересмотрите решение и удалите/исправьте запись SITES`);
      else if (h.count !== (s.count ?? 1))
        stale.push(`${s.file}:${h.line} совпадений ${h.count}, в SITES ${s.count ?? 1}`);
    }
    expect(stale).toEqual([]);
    expect(listed.size).toBe(SITES.length);
  });

  it('AC-ARCH-065 (2) решение у каждого места: категория из перечня, причина; pending — с пакетом-владельцем', () => {
    const bad = [...SITES, ...RESOLVED].filter(
      (s) =>
        !DECISIONS.includes(s.decision) ||
        s.why.trim().length < 10 ||
        (s.decision === 'pending') !== (s.owner !== undefined && /^WP-[A-Z0-9-]+$/.test(s.owner)),
    );
    expect(bad).toEqual([]);
  });

  it('TAB-1-03: каждое место исходного перечня (51 строка и «+») имеет решение — в SITES или RESOLVED', () => {
    const covered = new Set([...SITES.map((s) => s.tab), ...RESOLVED.map((r) => r.tab)].filter((t) => t !== undefined));
    expect(TAB_1_03.filter((t) => !covered.has(t))).toEqual([]);
    expect([...covered].filter((t) => !TAB_1_03.includes(t)).sort()).toEqual([]);
  });

  it('AC-ARCH-065 customerModeOrDeny (классификатор мест deny): staff → false, customer → true, kiosk и вид вне перечня — отказ', () => {
    const deny = (): never => {
      throw new Error('403');
    };
    expect(customerModeOrDeny('staff', deny)).toBe(false);
    expect(customerModeOrDeny('customer', deny)).toBe(true);
    for (const kind of ['kiosk', 'integration', 'robot', '', null, undefined, 1]) {
      expect(() => customerModeOrDeny(kind, deny), String(kind)).toThrow('403');
    }
    expect(SUBJECT_KINDS).toEqual(['staff', 'customer', 'kiosk']);
  });
});
