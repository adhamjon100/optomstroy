import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AUDIT_ACTIONS, RESERVED_AUDIT_ACTIONS } from '../../src/common/audit/audit-actions.js';

/**
 * Полнота событий аудита D-36 (RM-G-006; 11 §7.2, §7.2.1): у каждого события словаря есть писатель — вызов
 * `AuditService.write` с литералом имени в `src/**` или триггер в `migrations/*.sql`. Исключения — с причиной:
 * события вне R1 / вне приложения (EXEMPT) и события других агентов этапа G (PENDING_G — пока не написаны; после
 * их реализации тест остаётся зелёным). Словарь кода (`audit-actions.ts`) сверяется со словарём 11 §7.2/§7.2.1.
 */
const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const SPEC_11 = fileURLToPath(new URL('../../../docs/specification/11_SECURITY_PRIVACY.md', import.meta.url));

/** Не пишутся приложением в R1 — причина у каждого. */
const EXEMPT: Readonly<Record<string, string>> = {
  'price.changed': 'зарезервировано: цены меняются только в 1С (D-23, 11 §7.2)',
  'stock.adjusted': 'зарезервировано: остатки меняются только в 1С (D-22, 11 §7.2)',
  'payment.webhook_received': 'вебхук банка — только QR_PROVIDER=bakai, R2 (RM-F-014, ядро §24.4)',
  'payment.webhook_rejected': 'вебхук банка — только QR_PROVIDER=bakai, R2 (RM-F-014, ядро §24.4)',
  'audit.exported': 'экспорт аудита — R2 (reports.export, Q-217)',
  'export.created': 'экспорт отчётов CSV — R2 (reports.export, Q-217, ядро §19.2)',
  'backup.completed': 'резервное копирование — процедура эксплуатации (16), не код pos-api',
  'backup.restore_drill': 'учение восстановления — процедура эксплуатации (16), не код pos-api',
  'privacy.subject_request': 'обработка запросов субъекта ПДн — процедура PRIV-010…012, вне этапа G',
  'privacy.user_anonymized': 'анонимизация — PRIV-011/PRIV-031, вне этапа G',
  'integration.token_issued': 'выпуск токена integration — bin/issue_integration_token (эксплуатация, ядро §18.2)',
  'integration.token_rotated': 'ротация токена integration — эксплуатация (ядро §18.2)',
  'integration.token_revoked': 'отзыв токена integration — эксплуатация (ядро §18.2)',
  'integration.auth_failed': 'входящие /integrations/onec/* — не маршрут этапа G',
  'audit.restore_verified': 'проверка цепочки после восстановления — процедура 11 §11.2 (verify_audit_chain)',
  'audit.partition_dropped': 'удаление партиции аудита — SEC-084, после срока хранения Q-028',
  'retention.executed': 'исполнение сроков хранения — 11 §10.5, вне этапа G',
  'incident.containment': 'сдерживание инцидента — SEC-119, процедура эксплуатации',
};

/** События других агентов этапа G (карта маршрутов основы G): пишут их модули-владельцы. */
const PENDING_G: Readonly<Record<string, string>> = {
  'customer.finance.view': 'G-be-credit: GET /customers/{id}/receivables?include=documents (step-up)',
  'receivables.overdue_viewed': 'G-be-credit: GET /receivables/overdue, блок overdue[] дашборда',
  'discount.over_limit_rejected': 'G-be-credit: отклонение скидки сверх лимита (в R1 операции нет — CASH-007, R2)',
  'customer.phone_lookup': 'G-be-customers: сигнал поиска клиентов по телефону (GET /search/customers)',
  'return.requested': 'G-be-txn-returns: POST /returns',
  'return.submitted': 'G-be-txn-returns: POST /returns/{id}/submit',
  'return.updated': 'G-be-txn-returns: PATCH /returns/{id}',
  'transaction.viewed_all': 'G-be-txn-returns: GET /transactions с чужими данными',
};

/** События агента G-be-admin-reports (RM-G-006): обязаны быть покрыты. */
const MINE = [
  'audit.viewed',
  'report.viewed',
  'settings.changed',
  'sync.prices.applied',
  'sync.stock.applied',
  'sync.run.finished',
  'sync.run.failed',
  'sync.manual_started',
  'outbox.retried',
  'outbox.dead',
  'outbox.confirmed',
  'outbox.rejected',
  'outbox.cancelled',
  'discount.limits_changed',
  'order.cancelled',
  'order.cancel_requested',
  'payment.manual_qr_confirmed',
  'customer.debt_viewed',
  'credit.sale_approved',
  'discount.over_limit_approved',
  'return.status_changed',
];

function files(dir: string, ext: string, out: string[] = []): string[] {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) files(p, ext, out);
    else if (p.endsWith(ext)) out.push(p);
  }
  return out;
}

/** Писатели: литерал `'<action>'` в коде (кроме словаря, чтения аудита и тестов) или имя в триггере SQL. */
function writers(): Map<string, string[]> {
  const ts = files(join(ROOT, 'src'), '.ts')
    .filter((p) => !p.endsWith('.spec.ts'))
    .filter((p) => !/[\\/]common[\\/]audit[\\/]audit-actions\.ts$/.test(p))
    .filter((p) => !/[\\/]admin[\\/]audit[\\/]audit-(masking|query\.service)\.ts$/.test(p))
    .map((p) => [p, readFileSync(p, 'utf8')] as const);
  const sql = files(join(ROOT, 'migrations'), '.sql').map((p) => [p, readFileSync(p, 'utf8')] as const);
  const out = new Map<string, string[]>();
  for (const a of AUDIT_ACTIONS) {
    const esc = a.replace(/\./g, '\\.');
    const inSql = new RegExp(`['|]${esc}['|]`);
    const hits = [
      ...ts.filter(([, c]) => c.includes(`'${a}'`)).map(([p]) => p),
      ...sql.filter(([, c]) => inSql.test(c)).map(([p]) => p),
    ];
    out.set(a, hits);
  }
  return out;
}

/** Имена событий словаря 11 §7.2 и §7.2.1 (первая колонка таблиц «Событие (`action`)»). */
function dictionary11(): Set<string> {
  const text = readFileSync(SPEC_11, 'utf8');
  const start = text.indexOf('### 7.2. События аудита');
  const end = text.indexOf('### 7.3. Требования');
  const lines = text.slice(start, end).split('\n');
  const names = new Set<string>();
  let inTable = false;
  for (const line of lines) {
    if (line.startsWith('| Событие (`action`)')) {
      inTable = true;
      continue;
    }
    if (!line.startsWith('|')) {
      inTable = false;
      continue;
    }
    if (!inTable || line.startsWith('|---')) continue;
    const first = line.split('|')[1] ?? '';
    for (const m of first.matchAll(/`([a-z_]+(?:\.[a-z_]+)+)`/g)) names.add(m[1]);
  }
  return names;
}

describe('аудит D-36: полнота событий словаря 11 §7.2 (RM-G-006)', () => {
  const found = writers();

  it('словарь кода = словарь 11 §7.2 + §7.2.1', () => {
    const spec = dictionary11();
    expect(spec.size).toBeGreaterThan(100);
    expect([...spec].filter((a) => !(AUDIT_ACTIONS as readonly string[]).includes(a))).toEqual([]);
    expect(AUDIT_ACTIONS.filter((a) => !spec.has(a))).toEqual([]);
  });

  it('исключения и ожидающие — из словаря; зарезервированные R1 — в исключениях', () => {
    const dict = new Set<string>(AUDIT_ACTIONS);
    expect([...Object.keys(EXEMPT), ...Object.keys(PENDING_G), ...MINE].filter((a) => !dict.has(a))).toEqual([]);
    for (const a of RESERVED_AUDIT_ACTIONS) expect(EXEMPT[a], a).toBeDefined();
    expect(MINE.filter((a) => a in EXEMPT || a in PENDING_G)).toEqual([]);
  });

  it('события D-36 этапа G (скидки/права, sync.*.applied, отмены, возвраты, финансы, ручные подтверждения, ручная синхронизация, настройки) — пишутся', () => {
    const missing = MINE.filter((a) => (found.get(a) ?? []).length === 0);
    expect(missing).toEqual([]);
  });

  it('у каждого события словаря есть писатель, кроме исключений R1 и событий других агентов G', () => {
    const missing = AUDIT_ACTIONS.filter((a) => (found.get(a) ?? []).length === 0);
    const unexplained = missing.filter((a) => !(a in EXEMPT) && !(a in PENDING_G));
    expect(unexplained).toEqual([]);
    const stillPending = missing.filter((a) => a in PENDING_G);
    // Сводка для отчёта этапа: события других агентов G, которых в коде ещё нет.
    console.error(`[audit-coverage] ожидают других агентов G: ${stillPending.join(', ') || '—'}`);
  });
});
