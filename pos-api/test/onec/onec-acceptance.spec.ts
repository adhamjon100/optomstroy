import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { main } from '../../scripts/onec_acceptance.js';

/**
 * RM-E-016: репетиция приёмки API 1С на моке HS (фикстуры contracts/onec/fixtures) — тот же раннер, который после
 * получения API запускается против тестовой копии (`npm run onec:acceptance -- --steps …`). Не реальная интеграция.
 */
describe('scripts/onec_acceptance.ts — автоматическая часть контрольного примера 18 §7.2 (мок, тестовые данные)', () => {
  it('--mock: КП-1, КП-2, КП-5, КП-18, КП-19 → PASS, протокол с ручными шагами, код 0', async () => {
    const dir = mkdtempSync(join(process.env['TEMP'] ?? tmpdir(), 'pos-kp-'));
    try {
      const file = join(dir, 'protocol.md');
      const code = await main(['--mock', '--allow-write', '--out', file]);
      expect(code).toBe(0);
      const rows = readFileSync(file, 'utf8').split(/\r?\n/);
      for (const id of ['КП-1', 'КП-2', 'КП-5', 'КП-18', 'КП-19']) {
        const row = rows.find((l) => l.startsWith(`| ${id} |`));
        expect(row?.endsWith('| PASS |'), id).toBe(true);
      }
      expect(rows.find((l) => l.startsWith('| КП-8 |'))?.endsWith('| MANUAL |')).toBe(true);
      expect(rows.join('\n')).not.toMatch(/test-only-(password|client-key)/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('неизвестный шаг → код 2; без конфигурации ONEC_MODE=extension (не мок) → код 2', async () => {
    expect(await main(['--steps', 'kp99'])).toBe(2);
    expect(await main(['--steps', 'kp1'])).toBe(2);
  });
});
