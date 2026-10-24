import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * RM-E-012 (backend): сквозной сценарий этапа E на **настоящих процессах** — `node scripts/local-stack.mjs
 * catalog-smoke`: embedded PostgreSQL 17 → `node dist/migrate.js --seed` → отдельный процесс синхронизации каталога
 * через FakeOnecGateway (`scripts/load_catalog_fixtures.ts`) → `node dist/main.js` → мини-прокси фото → HTTP-сценарий
 * (каталог, поиск, остатки, избранное, офлайн-API, фото, статус синхронизации; сессии — OTP тестового режима).
 * Требует свежий `dist/` — запуск: `npm run test:e2e:catalog` (сборка + этот набор). В обычном `npm run test:e2e`
 * пропускается (нет `E2E_REAL_PROCESS=1`). **На фикстурах, не реальная интеграция.**
 */
const API_DIR = fileURLToPath(new URL('../../../', import.meta.url));
const enabled = process.env['E2E_REAL_PROCESS'] === '1';

describe.runIf(enabled)('Этап E на настоящих процессах: local-stack catalog-smoke', () => {
  it('catalog-smoke: все проверки PASS, код 0, процессы и кластер остановлены', async () => {
    expect(existsSync(`${API_DIR}dist/main.js`)).toBe(true);
    const { code, out } = await new Promise<{ code: number | null; out: string }>((resolve) => {
      const p = spawn(process.execPath, ['scripts/local-stack.mjs', 'catalog-smoke', '--catalog-fixtures=300'], {
        cwd: API_DIR,
        env: { ...process.env },
        stdio: 'pipe',
      });
      let buf = '';
      p.stdout.on('data', (d: Buffer) => (buf += d.toString()));
      p.stderr.on('data', (d: Buffer) => (buf += d.toString()));
      p.on('exit', (c) => resolve({ code: c, out: buf }));
    });
    const lines = out.split('\n').filter((l) => /\b(PASS|FAIL)\b/.test(l));
    console.error(lines.join('\n'));
    expect(lines.filter((l) => l.includes('FAIL'))).toEqual([]);
    expect(lines.length).toBeGreaterThanOrEqual(20);
    expect(out).toMatch(/catalog-smoke итог: (\d+)\/\1 PASS/);
    expect(code).toBe(0);
  }, 600_000);
});
