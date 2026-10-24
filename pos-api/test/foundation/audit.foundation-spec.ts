import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sql } from 'drizzle-orm';
import { AuditAnchorService } from '../../src/common/audit/audit-anchor.service.js';
import { applyAuditGucs, type AuditContext } from '../../src/common/audit/audit-context.js';
import { AuditEntryError, AuditService } from '../../src/common/audit/audit.service.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import { FoundationDb, seedSubject, testPhone } from './support/foundation-db.js';

describe('common/audit: AuditService + хэш-цепочка + якоря (D-36; 07 §9; 11 SEC-073…SEC-081) — embedded PostgreSQL 17', () => {
  const fdb = new FoundationDb();
  let audit: AuditService;
  let anchors: AuditAnchorService;
  let actor: AuditContext;

  beforeAll(async () => {
    await fdb.start('foundation_audit');
    audit = new AuditService(fdb.db);
    anchors = new AuditAnchorService(fdb.db);
    const s = await seedSubject(fdb.db);
    actor = {
      requestId: 'req-audit-1',
      actorUserId: s.userId,
      actorRole: 'seller',
      sessionId: s.session.id,
      deviceId: s.deviceKey,
      ip: '::ffff:10.0.0.7',
      appVersion: '1.2.0',
      clientPlatform: 'android',
    };
  });

  afterAll(async () => {
    await fdb.stop();
  });

  async function chainOk() {
    return anchors.verifyChain();
  }

  it('запись уровня app: поля контекста, chain_seq/prev_hash/row_hash ставит триггер; цепочка цела', async () => {
    const w1 = await audit.write(actor, {
      action: 'auth.login',
      entityType: 'sessions',
      entityId: actor.sessionId,
      after: { sid: actor.sessionId, amr: ['sms'] },
    });
    const w2 = await audit.write(actor, { action: 'auth.step_up.ok', stepUpMethod: 'pin', after: { operation: 'x' } });
    expect(w2.chainSeq).toBeGreaterThan(w1.chainSeq);
    expect(w1.rowHash).toHaveLength(32);
    const row = (
      await fdb.pool.query(
        `SELECT level, actor_user_id, actor_role, session_id, device_id, host(ip) AS ip, app_version, client_platform,
                request_id, action, result, severity, prev_hash FROM audit_logs WHERE id = $1`,
        [w2.id],
      )
    ).rows[0];
    expect(row).toMatchObject({
      level: 'app',
      actor_user_id: actor.actorUserId,
      actor_role: 'seller',
      session_id: actor.sessionId,
      device_id: actor.deviceId,
      ip: '10.0.0.7',
      app_version: '1.2.0',
      client_platform: 'android',
      request_id: 'req-audit-1',
      action: 'auth.step_up.ok',
      result: 'ok',
      severity: 'info',
    });
    expect((row.prev_hash as Buffer).equals(w1.rowHash)).toBe(true);
    expect(await chainOk()).toMatchObject({ ok: true, brokenAtChainSeq: null });
  });

  it('20 параллельных транзакций с записью аудита последним оператором → цепочка не рвётся', async () => {
    await Promise.all(
      Array.from({ length: 20 }, (_, i) =>
        fdb.db.transaction(async (tx) => {
          await tx.execute(sql`SELECT pg_sleep(${(i % 5) * 0.01})`);
          await audit.write(actor, { action: 'cart.cleared', after: { items: i } }, tx);
        }),
      ),
    );
    const v = await chainOk();
    expect(v.ok).toBe(true);
    const n = await fdb.pool.query(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'cart.cleared'`);
    expect(n.rows[0].n).toBe(20);
  });

  it('откат бизнес-транзакции после записи аудита → строки нет, цепочка ok, пропуск chain_seq учтён (gaps)', async () => {
    const before = await chainOk();
    await expect(
      fdb.db.transaction(async (tx) => {
        await audit.write(actor, { action: 'cart.parked' }, tx);
        throw new Error('rollback');
      }),
    ).rejects.toThrow('rollback');
    await audit.write(actor, { action: 'cart.resumed' });
    const after = await chainOk();
    expect(after.ok).toBe(true);
    expect(after.gaps).toBe(before.gaps + 1);
  });

  it('T-SEC-030: UPDATE/DELETE audit_logs запрещены: суперпользователь — триггер append-only; pos_app — нет прав (и TRUNCATE)', async () => {
    const c = await fdb.client();
    try {
      await expect(c.query(`UPDATE audit_logs SET reason = 'x' WHERE action = 'auth.login'`)).rejects.toThrow(
        /append-only/,
      );
      await expect(c.query(`DELETE FROM audit_logs WHERE action = 'auth.login'`)).rejects.toThrow(/append-only/);
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE pos_app');
      await expect(c.query(`UPDATE audit_logs SET reason = 'x'`)).rejects.toThrow(/permission denied/);
      await c.query('ROLLBACK');
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE pos_app');
      await expect(c.query(`DELETE FROM audit_logs`)).rejects.toThrow(/permission denied/);
      await c.query('ROLLBACK');
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE pos_app');
      await expect(c.query(`TRUNCATE audit_logs`)).rejects.toThrow(/permission denied/);
      await c.query('ROLLBACK');
      // pos_app может вставлять (INSERT) — запись аудита от роли приложения работает
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE pos_app');
      await c.query(
        `INSERT INTO audit_logs (level, action, result, severity) VALUES ('app', 'auth.otp.sent', 'ok', 'info')`,
      );
      await c.query('ROLLBACK');
    } finally {
      await c.end();
    }
    expect((await chainOk()).ok).toBe(true);
  });

  it('словарь 11 §7.2: действие вне словаря и зарезервированное → AuditEntryError; причина ≥ 5 символов для user.blocked', async () => {
    await expect(audit.write(actor, { action: 'auth.hacked' as never })).rejects.toThrow(AuditEntryError);
    await expect(audit.write(actor, { action: 'price.changed' })).rejects.toThrow(/зарезервировано/);
    await expect(audit.write(actor, { action: 'user.blocked', reason: 'abc' })).rejects.toThrow(/SEC-076/);
    await expect(audit.write(actor, { action: 'user.blocked', reason: 'Нарушение правил' })).resolves.toBeDefined();
    // системный актор (без actorUserId) — причина не требуется (например, отмена по проекции 1С)
    await expect(audit.write({ requestId: 'sys' }, { action: 'order.cancelled' })).resolves.toBeDefined();
    await expect(audit.write({ ...actor, sessionId: 'not-uuid' }, { action: 'auth.logout' })).rejects.toThrow(/UUID/);
  });

  it('T-SEC-008, T-SEC-029: SEC-078: OTP/PIN/токены/хэши не пишутся, телефоны — маска «+996 *** ** NN», ФИО — инициалы', async () => {
    const jwtLike = 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl';
    const w = await audit.write(actor, {
      action: 'auth.otp.failed',
      before: { attempts: 1 },
      after: {
        code: '004512',
        otp: '004512',
        pin: '123456',
        newPin: '654321',
        refreshToken: 'r'.repeat(43),
        accessToken: jwtLike,
        comment: jwtLike,
        codeHmac: 'deadbeef',
        pinHash: '$argon2id$...',
        phone: '+996700123456',
        phoneMasked: '+996 *** ** 56',
        fullName: 'Иванов Иван Иванович',
        note: `звонил с +996555987654, токен ${jwtLike}`,
        nested: { password: 'p', items: [{ secret: 's', ok: 1 }] },
        tokenId: '0199f1c2-0000-7000-8000-000000000001', // check-secrets: allow — тестовое значение
        challengeId: '0199f1c2-0000-7000-8000-000000000002',
      },
    });
    const r = (await fdb.pool.query(`SELECT before, after FROM audit_logs WHERE id = $1`, [w.id])).rows[0];
    expect(r.before).toEqual({ attempts: 1 });
    expect(r.after).toEqual({
      phone: '+996 *** ** 56',
      phoneMasked: '+996 *** ** 56',
      fullName: 'И. И. И.',
      comment: '[REDACTED]',
      note: 'звонил с +996 *** ** 54, токен [REDACTED]',
      nested: { items: [{ ok: 1 }] },
      tokenId: '0199f1c2-0000-7000-8000-000000000001', // check-secrets: allow — тестовое значение
      challengeId: '0199f1c2-0000-7000-8000-000000000002',
    });
    const dump = JSON.stringify(r);
    expect(dump).not.toContain('eyJ');
    for (const secret of ['004512', '123456', '654321', 'rrrrrrrr', 'deadbeef', 'argon2id', '700123456', '555987654']) {
      expect(dump).not.toContain(secret);
    }
  });

  it('applyAuditGucs: триггер уровня БД (users.status → blocked) пишет актора, сессию, requestId из SET LOCAL', async () => {
    const users = new UsersRepository(fdb.db);
    const target = await users.create({ phoneE164: testPhone(), kind: 'staff', status: 'active' });
    await fdb.db.transaction(async (tx) => {
      await applyAuditGucs(tx, { ...actor, requestId: 'req-db-trigger' });
      await users.setStatus(target.id, 'blocked', { blockedByUserId: actor.actorUserId, blockReason: 'тест' }, tx);
    });
    const r = (
      await fdb.pool.query(
        `SELECT level, action, actor_user_id, actor_role, session_id, request_id, severity, before, after
           FROM audit_logs WHERE entity_id = $1 AND action = 'user.blocked'`,
        [target.id],
      )
    ).rows[0];
    expect(r).toMatchObject({
      level: 'db',
      actor_user_id: actor.actorUserId,
      actor_role: 'seller',
      session_id: actor.sessionId,
      request_id: 'req-db-trigger',
      severity: 'info',
    });
    expect(r.before.status).toBe('active');
    expect(r.after.status).toBe('blocked');
    expect((await chainOk()).ok).toBe(true);
  });

  it('якорь суток: строка audit_anchors, файл экспорта, идемпотентность, сверка ok', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pos-audit-anchor-'));
    try {
      const today = (await fdb.pool.query(`SELECT to_char(now() AT TIME ZONE 'Asia/Bishkek', 'YYYY-MM-DD') AS d`))
        .rows[0].d as string;
      const a = await anchors.writeDailyAnchor(today, { exportDir: dir });
      expect(a).not.toBeNull();
      expect(a!.created).toBe(true);
      const last = (await fdb.pool.query(`SELECT chain_seq, row_hash FROM audit_logs ORDER BY chain_seq DESC LIMIT 1`))
        .rows[0];
      expect(a!.lastChainSeq).toBe(Number(last.chain_seq));
      expect(a!.lastRowHash.equals(last.row_hash)).toBe(true);
      expect(a!.rowsCount).toBeGreaterThan(20);
      expect(readFileSync(join(dir, `${today}.txt`), 'utf8')).toBe(
        `${today};${last.chain_seq};${(last.row_hash as Buffer).toString('hex')}\n`,
      );
      const again = await anchors.writeDailyAnchor(today);
      expect(again).toMatchObject({ created: false, lastChainSeq: a!.lastChainSeq });
      expect(await anchors.verifyAnchors()).toEqual([{ anchorDate: today, ok: true }]);
      const stored = (await fdb.pool.query(`SELECT verify_result, export_location, exported_at FROM audit_anchors`))
        .rows[0];
      expect(stored.verify_result).toBe('ok');
      expect(stored.export_location).toBe(join(dir, `${today}.txt`));
      expect(stored.exported_at).not.toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('подмена строки суперпользователем (триггер отключён) → audit_verify_chain: broken_at_chain_seq; якорь — hash_mismatch', async () => {
    const target = (
      await fdb.pool.query(
        `SELECT chain_seq FROM audit_logs WHERE action = 'auth.step_up.ok' ORDER BY chain_seq LIMIT 1`,
      )
    ).rows[0].chain_seq as string;
    const lastSeq = (await fdb.pool.query(`SELECT max(chain_seq) AS m FROM audit_logs`)).rows[0].m as string;
    const c = await fdb.client();
    try {
      await c.query('ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_immutable');
      await c.query(`UPDATE audit_logs SET result = 'denied' WHERE chain_seq = $1`, [target]);
      await c.query(`UPDATE audit_logs SET row_hash = decode(repeat('ab', 32), 'hex') WHERE chain_seq = $1`, [lastSeq]);
      await c.query('ALTER TABLE audit_logs ENABLE TRIGGER trg_audit_logs_immutable');
    } finally {
      await c.end();
    }
    const v = await chainOk();
    expect(v.ok).toBe(false);
    expect(v.brokenAtChainSeq).toBe(Number(target));
    const av = await anchors.verifyAnchors();
    expect(av[0]).toMatchObject({ ok: false, reason: 'hash_mismatch' });
  });
});
