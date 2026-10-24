import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты модуля registration (RM-D-004, RM-D-014; 12 T-REG-*) на одноразовом PostgreSQL 17 (embedded-postgres).
// Запуск из pos-api/: `npx vitest run --config test/registration/vitest.config.ts`.
// Отдельный конфиг — vitest.config*.ts и package.json принадлежат владельцу каркаса (RM-C-005).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/registration/**/*.registration-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
