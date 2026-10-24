import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * RM-F-009 (backend), RM-F-010 «на фикстурах»: сквозные сценарии этапа F на **настоящих процессах** —
 * `node scripts/local-stack.mjs pos-smoke`: embedded PostgreSQL 17 → `dist/migrate.js --seed` → каталог через
 * FakeOnecGateway → управляемый фейк HTTP-сервиса расширения 1С → `dist/main.js` и `dist/worker.js`
 * (`ONEC_MODE=extension` → фейк). Сценарии: корзина → checkout-preview → POST /orders (повтор по ключу) → outbox →
 * «Заказ клиента» (идемпотентно по externalId) → статус из 1С → оплата → товарный чек PDF; QR через 1С → опрос
 * воркера → received; 503 → submitting → восстановление; отказ 1С → submit_failed + восстановление корзины;
 * dead-letter → ручной повтор; QR_PROVIDER=none → ручное подтверждение со step-up; режим клиента.
 * Требует свежий `dist/` — запуск: `npm run test:e2e:pos`. В обычном `npm run test:e2e` пропускается.
 * **На фикстурах, не реальная интеграция.**
 */
const API_DIR = fileURLToPath(new URL('../../../', import.meta.url));
const enabled = process.env['E2E_REAL_PROCESS'] === '1';

describe.runIf(enabled)('Этап F на настоящих процессах: local-stack pos-smoke', () => {
  it('pos-smoke: все проверки PASS, код 0, процессы и кластер остановлены', async () => {
    expect(existsSync(`${API_DIR}dist/main.js`)).toBe(true);
    expect(existsSync(`${API_DIR}dist/worker.js`)).toBe(true);
    const { code, out } = await new Promise<{ code: number | null; out: string }>((resolve) => {
      const p = spawn(process.execPath, ['scripts/local-stack.mjs', 'pos-smoke', '--catalog-fixtures=200'], {
        cwd: API_DIR,
        env: { ...process.env },
        stdio: 'pipe',
      });
      let buf = '';
      p.stdout.on('data', (d: Buffer) => (buf += d.toString()));
      p.stderr.on('data', (d: Buffer) => (buf += d.toString()));
      p.on('exit', (c) => resolve({ code: c, out: buf }));
    });
    // Строки проверок: «[local-stack] PASS …» / «[local-stack] FAIL …» (в деталях встречается VALIDATION_FAILED).
    const lines = out.split('\n').filter((l) => /\[local-stack\] (PASS|FAIL) /.test(l));
    console.error(lines.join('\n'));
    expect(lines.filter((l) => l.includes('[local-stack] FAIL '))).toEqual([]);
    expect(lines.length).toBeGreaterThanOrEqual(25);
    expect(out).toMatch(/pos-smoke итог: (\d+)\/\1 PASS/);
    expect(code).toBe(0);
  }, 900_000);
});
