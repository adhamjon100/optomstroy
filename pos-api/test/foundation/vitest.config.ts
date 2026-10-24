import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты общего фундамента авторизации этапа D (common/auth, common/crypto, common/audit, common/rate-limit,
// src/users) — часть на одноразовом PostgreSQL 17 (embedded-postgres, без Docker).
// Запуск из pos-api/: `npx vitest run --config test/foundation/vitest.config.ts`.
// Отдельный конфиг — vitest.config*.ts и package.json принадлежат владельцу каркаса (RM-C-005).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/foundation/**/*.foundation-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
