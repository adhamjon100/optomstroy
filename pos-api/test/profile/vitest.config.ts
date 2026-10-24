import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты модуля profile (RM-D-004, RM-D-014; 12 T-BIO-011, T-BIO-016, T-REG-021, T-REG-022; 08 §4.3) на одноразовом PostgreSQL 17 (embedded-postgres).
// Запуск из pos-api/: `npx vitest run --config test/profile/vitest.config.ts`.
// Отдельный конфиг — vitest.config*.ts и package.json принадлежат владельцу каркаса (RM-C-005).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/profile/**/*.profile-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
