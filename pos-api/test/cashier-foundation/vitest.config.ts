import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Этап G, основа backend (агент G-be-foundation): порты G (`common/ports`), журнал `transactions`
// (`common/journal`), фейк 1С в режиме кассира (`SyntheticCashier` — тестовые данные), хелпер
// `test/support/cashier-fixture.ts` (embedded PostgreSQL 17). Запуск из pos-api/: `npm run test:cashier-foundation`.
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/cashier-foundation/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 120_000,
    hookTimeout: 600_000,
  },
});
