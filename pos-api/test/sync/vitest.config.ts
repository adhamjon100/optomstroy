import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-002 (+ RM-E-014 sync): планировщик, singleton, ручной запуск по ролям, повтор outbox, алерты, сверка $count —
// на embedded PostgreSQL 17 (все миграции), pg-boss в той же БД, FakeOnecGateway с синтетическим каталогом
// («на фикстурах, не реальная интеграция»). Запуск из pos-api/: `npm run test:sync`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/sync/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 300_000,
  },
});
