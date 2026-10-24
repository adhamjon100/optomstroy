import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты изолированного тестового режима RM-C-008: test/integrations/**/*.spec.ts (часть — на embedded PostgreSQL 17).
// Запуск из pos-api/: `npx vitest run --config test/integrations/vitest.config.ts`.
// Владелец vitest.config.ts (RM-C-005) может добавить шаблон в общий include; до этого — отдельная конфигурация.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/integrations/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 180_000,
  },
});
