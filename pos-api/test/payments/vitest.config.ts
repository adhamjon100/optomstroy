import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап F, агент F-be-payments (RM-F-003, RM-F-012, RM-F-015, RM-F-016): платежи по заказу, QR через 1С
// (`ScriptedOnecGateway` — тестовые данные) и запасной `QR_PROVIDER=none`, ручное подтверждение и void со step-up,
// long-polling, опрос статуса QR, решение о долге. Стенд — test/support/pos-fixture.ts (embedded PostgreSQL 17).
// Запуск из pos-api/: `npm run test:payments`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/payments/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 300_000,
  },
});
