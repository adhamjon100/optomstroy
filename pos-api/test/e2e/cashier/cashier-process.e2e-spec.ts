import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Интеграция backend этапа G (13 RM-G-009) на **настоящих процессах** — `node scripts/local-stack.mjs cashier-smoke`:
 * embedded PostgreSQL 17 → `dist/migrate.js --seed` → каталог через FakeOnecGateway → управляемый фейк HTTP-сервиса
 * 1С в режиме кассира (`scripts/pos_fake_onec.ts --cashier`) → `dist/main.js` и `dist/worker.js`
 * (`ONEC_MODE=extension`). Мир кассира загружается синхронизацией pos-worker (план обмена: клиенты, соглашения,
 * скидки, реализации; снимки долга). Сценарии: поиск и долг клиента; продажа в долг клиенту с просрочкой →
 * `CREDIT_BLOCKED` → разрешение старшего (step-up) → оплата → транзакции → аудит и проверка цепочки; клиент → outbox
 * → 1С; возврат draft → submit → accept / reject; отчёты сходятся с журналом и снимками; режим клиента.
 * Требует свежий `dist/` — запуск: `npm run test:e2e:cashier`. В обычном `npm run test:e2e` пропускается.
 * **На фикстурах, не реальная интеграция.**
 */
const API_DIR = fileURLToPath(new URL('../../../', import.meta.url));
const enabled = process.env['E2E_REAL_PROCESS'] === '1';

describe.runIf(enabled)('Этап G на настоящих процессах: local-stack cashier-smoke', () => {
  it('cashier-smoke: все проверки PASS, код 0, процессы и кластер остановлены', async () => {
    expect(existsSync(`${API_DIR}dist/main.js`)).toBe(true);
    expect(existsSync(`${API_DIR}dist/worker.js`)).toBe(true);
    const { code, out } = await new Promise<{ code: number | null; out: string }>((resolve) => {
      const p = spawn(process.execPath, ['scripts/local-stack.mjs', 'cashier-smoke', '--catalog-fixtures=200'], {
        cwd: API_DIR,
        env: { ...process.env },
        stdio: 'pipe',
      });
      let buf = '';
      p.stdout.on('data', (d: Buffer) => (buf += d.toString()));
      p.stderr.on('data', (d: Buffer) => (buf += d.toString()));
      p.on('exit', (c) => resolve({ code: c, out: buf }));
    });
    const lines = out.split('\n').filter((l) => /\[local-stack\] (PASS|FAIL) /.test(l));
    console.error(lines.join('\n'));
    expect(lines.filter((l) => l.includes('[local-stack] FAIL '))).toEqual([]);
    expect(lines.length).toBeGreaterThanOrEqual(20);
    expect(out).toMatch(/cashier-smoke итог: (\d+)\/\1 PASS/);
    expect(code).toBe(0);
  }, 1_200_000);
});
