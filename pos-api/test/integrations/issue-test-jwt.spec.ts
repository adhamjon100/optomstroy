import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Controller, Get, Post } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { decodeJwt, decodeProtectedHeader } from 'jose';
import request from 'supertest';
import { issueTestJwt, main, TestJwtError } from '../../scripts/issue_test_jwt.js';
import { RequirePermission } from '../../src/common/rbac/rbac.decorators.js';
import { createTestApp, LogCapture } from '../support/test-app.js';
import { jwtAuthModule, TempJwtKeys } from './support/jwt-test-auth.js';

const POS_API_DIR = fileURLToPath(new URL('../../', import.meta.url));
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

@Controller()
class RbacProbeController {
  /** `order.create` есть у seller (permissions.yaml). */
  @RequirePermission('order.create')
  @Post('orders')
  create() {
    return { ok: true };
  }

  /** `users.manage` у seller нет, у admin есть. */
  @RequirePermission('users.manage')
  @Get('admin/users')
  users() {
    return { ok: true };
  }
}

/** Запуск CLI так же, как его запускает разработчик: `node --import tsx scripts/issue_test_jwt.ts …`. */
function runCli(args: string[], env: Record<string, string | undefined>) {
  const res = spawnSync(process.execPath, ['--import', 'tsx', 'scripts/issue_test_jwt.ts', ...args], {
    cwd: POS_API_DIR,
    env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, ...env },
    encoding: 'utf8',
    timeout: 60_000,
  });
  return { status: res.status, stdout: res.stdout, stderr: res.stderr };
}

describe('scripts/issue_test_jwt.ts (RM-C-008)', () => {
  const keys = new TempJwtKeys();
  const env = { APP_ENV: 'dev', JWT_PRIVATE_KEY_FILE: keys.privateKeyFile, JWT_KEY_ID: 'dev-test-1' };
  let app: NestExpressApplication;

  beforeAll(async () => {
    app = await createTestApp({
      controllers: [RbacProbeController],
      imports: [jwtAuthModule(keys.publicKey)],
      logStream: new LogCapture(),
    });
  });

  afterAll(async () => {
    await app?.close();
    keys.dispose();
  });

  it('claims по 09 §8.1: sub, kind, roles[], permissionsVersion, deviceId, sid, jti (+ iss, aud, iat, exp, amr); без ПДн', async () => {
    const token = await issueTestJwt({ role: 'seller', permissionsVersion: 3 }, env);
    const header = decodeProtectedHeader(token);
    expect(header).toMatchObject({ alg: 'EdDSA', typ: 'JWT', kid: 'dev-test-1' });
    const c = decodeJwt(token);
    expect(c.iss).toBe('optomstroy-pos');
    expect(c.aud).toBe('optomstroy-api');
    expect(c.sub).toMatch(UUID_RE);
    expect(c.kind).toBe('staff');
    expect(c.roles).toEqual(['seller']);
    expect(c.permissionsVersion).toBe(3);
    expect(c.deviceId).toMatch(UUID_RE);
    expect(c.sid).toMatch(UUID_RE);
    expect(c.jti).toMatch(UUID_RE);
    expect(c.amr).toEqual(['sms']);
    expect((c.exp ?? 0) - (c.iat ?? 0)).toBe(900);
    expect(Object.keys(c).sort()).toEqual(
      [
        'amr',
        'aud',
        'deviceId',
        'exp',
        'iat',
        'iss',
        'jti',
        'kind',
        'permissionsVersion',
        'roles',
        'sid',
        'sub',
      ].sort(),
    );
    const other = decodeJwt(await issueTestJwt({ role: 'seller' }, env));
    expect(other.jti).not.toBe(c.jti);
  });

  it('seller: разрешённое право (order.create) → 201; запрещённое (users.manage) → 403 FORBIDDEN', async () => {
    const token = await issueTestJwt({ role: 'seller' }, env);
    const http = request(app.getHttpServer());
    const ok = await http.post('/api/v1/orders').set('Authorization', `Bearer ${token}`).send({});
    expect(ok.status).toBe(201);
    const denied = await http.get('/api/v1/admin/users').set('Authorization', `Bearer ${token}`);
    expect(denied.status).toBe(403);
    expect(denied.body.code).toBe('FORBIDDEN');
  });

  it('admin: users.manage → 200; без токена → 401; подделанная подпись → 401', async () => {
    const http = request(app.getHttpServer());
    const admin = await issueTestJwt({ role: 'admin' }, env);
    expect((await http.get('/api/v1/admin/users').set('Authorization', `Bearer ${admin}`)).status).toBe(200);
    const anon = await http.get('/api/v1/admin/users');
    expect(anon.status).toBe(401);
    expect(anon.body.code).toBe('UNAUTHENTICATED');

    const other = new TempJwtKeys();
    try {
      const forged = await issueTestJwt({ role: 'admin' }, { ...env, JWT_PRIVATE_KEY_FILE: other.privateKeyFile });
      expect((await http.get('/api/v1/admin/users').set('Authorization', `Bearer ${forged}`)).status).toBe(401);
    } finally {
      other.dispose();
    }
  });

  it('ES256 (P-256) тоже поддерживается; неизвестная роль и ttl вне границ отвергаются', async () => {
    const p256 = new TempJwtKeys('p256');
    try {
      const t = await issueTestJwt(
        { role: 'cashier' },
        { APP_ENV: 'staging', JWT_PRIVATE_KEY_FILE: p256.privateKeyFile },
      );
      expect(decodeProtectedHeader(t).alg).toBe('ES256');
    } finally {
      p256.dispose();
    }
    await expect(issueTestJwt({ role: 'superuser' as never }, env)).rejects.toThrow(TestJwtError);
    await expect(issueTestJwt({ role: 'seller', ttlSeconds: 86_401 }, env)).rejects.toThrow(/--ttl/);
  });

  it('только APP_ENV=dev|staging: prod, production и незаданный APP_ENV → ошибка, токен не выпускается', async () => {
    for (const appEnv of ['prod', 'production', undefined]) {
      await expect(issueTestJwt({ role: 'seller' }, { ...env, APP_ENV: appEnv })).rejects.toThrow(
        /допустимо только dev \| staging/,
      );
    }
    const out: string[] = [];
    const spy = vi.spyOn(process.stdout, 'write').mockImplementation((s) => {
      out.push(String(s));
      return true;
    });
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      expect(await main(['--role', 'seller'], { ...env, APP_ENV: 'prod' })).toBe(2);
    } finally {
      spy.mockRestore();
      errSpy.mockRestore();
    }
    expect(out).toEqual([]);
  });

  it('CLI: dev → код 0 и один токен в stdout; prod → код 2, stderr с причиной, stdout пуст', () => {
    const ok = runCli(['--role', 'seller'], env);
    expect(ok.stderr).toBe('');
    expect(ok.status).toBe(0);
    const lines = ok.stdout.trim().split('\n');
    expect(lines).toHaveLength(1);
    expect(decodeJwt(lines[0] ?? '').roles).toEqual(['seller']);

    const prod = runCli(['--role', 'seller'], { ...env, APP_ENV: 'prod' });
    expect(prod.status).toBe(2);
    expect(prod.stdout).toBe('');
    expect(prod.stderr).toContain('запрещено при APP_ENV=prod');

    const noKey = runCli(['--role', 'seller'], { APP_ENV: 'dev' });
    expect(noKey.status).toBe(2);
    expect(noKey.stderr).toContain('JWT_PRIVATE_KEY_FILE');
  });
});
