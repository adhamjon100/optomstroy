import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// RM-E-001: адаптеры 1С (HTTP-сервис расширения против локального мока на фикстурах, OData allow-list, фейк-каталог).
// Запуск из pos-api/: `npm run test:onec`. Без БД и сети (только 127.0.0.1).
export default defineConfig({
  root: fileURLToPath(new URL('../../', import.meta.url)),
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    include: ['test/onec/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    testTimeout: 60_000,
    hookTimeout: 60_000,
  },
});
