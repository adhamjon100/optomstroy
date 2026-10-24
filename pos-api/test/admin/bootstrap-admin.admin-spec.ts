import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { BOOTSTRAP_INVITER_NAME, bootstrapFirstAdmin } from '../../src/admin/bootstrap/first-admin.js';
import { runBootstrapAdminCli } from '../../src/admin/bootstrap/first-admin.cli.js';
import { AdminTestApp } from './support/admin-app.js';

/**
 * INT-02 / DQ-27: первичный администратор на пустой БД — приглашение `admin` операторской командой
 * (src/admin/bootstrap, scripts/bootstrap-admin.ts; docs/ops/first_admin.md). Синтетические номера +99677…
 */
describe('bootstrap-admin: первичный администратор (INT-02)', () => {
  const t = new AdminTestApp();
  const PHONE = '+996770000901';
  const OTHER = '+996770000902';
  let base: Record<string, string>;
  const run = async (argv: string[]) => {
    const out: string[] = [];
    const err: string[] = [];
    const code = await runBootstrapAdminCli(argv, base, { out: (l) => out.push(l), err: (l) => err.push(l) });
    return { code, out: out.join('\n'), err: err.join('\n') };
  };

  beforeAll(async () => {
    await t.start('admin_bootstrap');
    base = { APP_ENV: 'dev', MIN_APP_VERSION: 'android=1.0.0', DATABASE_URL: t.fdb.url, LOG_LEVEL: 'error' };
  });
  afterAll(async () => {
    await t.stop();
  });

  it('аргументы: без --phone/--name, неизвестный флаг, стационарный номер, короткое ФИО, срок вне 1…30 → код 2', async () => {
    expect((await run(['--name', 'Тестов Админ'])).code).toBe(2);
    expect((await run(['--phone', PHONE, '--name', 'Тестов Админ', '--bogus'])).code).toBe(2);
    expect((await run(['--phone', '+996312000000', '--name', 'Тестов Админ'])).code).toBe(2);
    expect((await run(['--phone', PHONE, '--name', 'Т'])).code).toBe(2);
    expect((await run(['--phone', PHONE, '--name', 'Тестов Админ', '--days', '45'])).code).toBe(2);
    expect((await run(['--help'])).code).toBe(0);
    expect(
      await runBootstrapAdminCli(
        ['--phone', PHONE, '--name', 'Тестов Админ'],
        {},
        { out: () => undefined, err: () => undefined },
      ),
    ).toBe(2);
    const rows = await t.q('SELECT 1 FROM user_invitations');
    expect(rows).toHaveLength(0);
  });

  it('пустая БД: создаёт приглашение admin + техническую запись-автора; аудит user.invited; вывод без ПДн; повтор — без изменений', async () => {
    const first = await run(['--phone', '0770 000 901', '--name', 'Тестов  Админ Первый', '--days', '3']);
    expect(first.code).toBe(0);
    expect(first.out).toContain('создано приглашение admin');
    expect(first.out).not.toContain('770000901');
    expect(first.out).not.toContain('Тестов');
    const inv = await t.q<{ id: string; role: string; status: string; full_name: string; invited_by_user_id: string }>(
      `SELECT id, role, status, full_name, invited_by_user_id FROM user_invitations WHERE phone_e164 = $1`,
      [PHONE],
    );
    expect(inv).toHaveLength(1);
    expect(inv[0]).toMatchObject({ role: 'admin', status: 'pending', full_name: 'Тестов Админ Первый' });
    const inviter = await t.q<{ phone_e164: string | null; status: string; full_name: string; roles: number }>(
      `SELECT u.phone_e164, u.status, p.full_name,
              (SELECT count(*)::int FROM user_roles ur WHERE ur.user_id = u.id) AS roles
         FROM users u JOIN user_profiles p ON p.user_id = u.id WHERE u.id = $1`,
      [inv[0].invited_by_user_id],
    );
    expect(inviter[0]).toEqual({ phone_e164: null, status: 'deleted', full_name: BOOTSTRAP_INVITER_NAME, roles: 0 });
    const audit = await t.auditRows('user.invited', inv[0].id);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ result: 'ok', actor_user_id: null, reason: 'first_admin_bootstrap' });
    expect(audit[0].after).toMatchObject({ role: 'admin', source: 'bootstrap_cli' });

    const again = await run(['--phone', PHONE, '--name', 'Тестов Админ Первый']);
    expect(again.code).toBe(0);
    expect(again.out).toContain('уже действует');
    expect(await t.q('SELECT 1 FROM user_invitations')).toHaveLength(1);
    expect(await t.auditRows('user.invited')).toHaveLength(1);
  });

  it('действующее приглашение admin на другой номер → код 3; номер занят учётной записью → код 3', async () => {
    const other = await run(['--phone', OTHER, '--name', 'Тестов Админ Второй']);
    expect(other.code).toBe(3);
    expect(other.err).toContain('другой номер');
    const seller = await t.actor('seller');
    const taken = await bootstrapFirstAdmin(t.fdb.db, {
      phone: seller.phone,
      fullName: 'Тестов Продавец',
      ttlDays: 7,
      requestId: 'r-1',
      now: new Date(Date.now() + 4 * 86_400_000), // приглашение PHONE истекло
    });
    expect(taken).toMatchObject({ kind: 'phone_taken' });
  });

  it('после истечения срока — новое приглашение (прежнее закрыто expired), автор переиспользуется; при активном admin — ничего', async () => {
    const later = new Date(Date.now() + 4 * 86_400_000);
    const r = await bootstrapFirstAdmin(t.fdb.db, {
      phone: PHONE,
      fullName: 'Тестов Админ Первый',
      ttlDays: 7,
      requestId: 'r-2',
      now: later,
    });
    expect(r.kind).toBe('created');
    const inv = await t.q<{ status: string; invited_by_user_id: string }>(
      `SELECT status, invited_by_user_id FROM user_invitations WHERE phone_e164 = $1 ORDER BY created_at`,
      [PHONE],
    );
    expect(inv.map((x) => x.status)).toEqual(['expired', 'pending']);
    expect(inv[0].invited_by_user_id).toBe(inv[1].invited_by_user_id);
    expect(await t.q(`SELECT 1 FROM users WHERE phone_e164 IS NULL AND status = 'deleted'`)).toHaveLength(1);
    // техническая запись не видна в администрировании пользователей
    const admin = await t.actor('admin');
    const list = await t.req('get', '/admin/users?limit=100', admin);
    expect(list.status).toBe(200);
    expect(JSON.stringify(list.body)).not.toContain(BOOTSTRAP_INVITER_NAME);
    // активный admin есть → ничего не делает
    const noop = await run(['--phone', OTHER, '--name', 'Тестов Админ Второй']);
    expect(noop.code).toBe(0);
    expect(noop.out).toContain('активный администратор уже есть');
    expect(await t.q('SELECT 1 FROM user_invitations WHERE phone_e164 = $1', [OTHER])).toHaveLength(0);
  });
});
