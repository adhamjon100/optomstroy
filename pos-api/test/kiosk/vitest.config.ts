import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Планшет магазина (P-002, ADR-115; 12 §2.15, этап K): серверные тесты режима `kind=kiosk` — закрытый список
// маршрутов, `KIOSK_MODE`, `GET /me` планшета, далее жизненный цикл, код, заявка, сброс. Стенд —
// `test/kiosk/support/kiosk-fixture.ts` (embedded PostgreSQL 17 со всеми миграциями — тестовые данные).
// Запуск из pos-api/: `npm run test:kiosk` (входит в `npm run test:all` и в CI — проект `kiosk` vitest.config.cov-all.ts).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/kiosk/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
