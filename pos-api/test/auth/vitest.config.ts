import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Unit-тесты модуля auth (RM-D-001, RM-D-003): политика OTP, PIN, лимиты, step-up — без БД.
// Запуск из pos-api/: `npx vitest run --config test/auth/vitest.config.ts`.
// e2e модуля — test/e2e/auth/*.e2e-spec.ts (`npm run test:e2e`, embedded PostgreSQL 17).
// Отдельный конфиг — vitest.config*.ts и package.json принадлежат владельцу каркаса (RM-C-005).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/auth/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    testTimeout: 60_000,
  },
});
