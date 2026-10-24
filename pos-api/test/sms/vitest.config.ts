import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Тесты SMS-адаптера SMSPro и SMS-контура notifications (RM-D-002): локальный HTTPS-стенд SMSPro (не реальный
// вендор) и одноразовый PostgreSQL 17 (embedded-postgres) для sms_outbox/pg-boss.
// Запуск из pos-api/: `npx vitest run --config test/sms/vitest.config.ts`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/sms/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 240_000,
  },
});
