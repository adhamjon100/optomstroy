import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты админ-раздела пользователей этапа D (RM-D-006, RM-D-016; src/admin/users, src/admin/invitations):
// unit (политика целей) и e2e на одноразовом PostgreSQL 17 (embedded-postgres, без Docker).
// Запуск из pos-api/: `npx vitest run --config test/admin/vitest.config.ts`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/admin/**/*.admin-spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
