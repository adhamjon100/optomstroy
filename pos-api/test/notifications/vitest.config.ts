import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, RM-F-008 (D-41): центр уведомлений in-app — GET /notifications, POST /notifications/{id}/read,
// POST /notifications/read-all и NotificationsPort; e2e на стенде test/support/pos-fixture.ts (embedded
// PostgreSQL 17 — тестовые данные). Запуск из pos-api/: `npm run test:notifications`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/notifications/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
