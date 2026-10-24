import { defineConfig } from 'vitest/config';

/**
 * Покрытие модулей этапа D (13 RM-D-011 п. 2: `auth` и `registration` ≥ 80 % строк). Модули проверяются в основном
 * e2e-наборами на embedded PostgreSQL 17, поэтому покрытие собирается по проектам Vitest: unit (src), e2e
 * (test/e2e, в т. ч. test/e2e/auth), test/auth, test/registration, test/profile, test/admin. Порог — по каждому из
 * двух каталогов отдельно (`perFile: false`, glob-пороги).
 *
 *   npm run test:cov:d        # отчёт text + json-summary в coverage/stage-d
 */
export default defineConfig({
  test: {
    projects: [
      { extends: './vitest.config.ts', test: { name: 'unit' } },
      { extends: './vitest.config.e2e.ts', test: { name: 'e2e' } },
      { extends: './test/auth/vitest.config.ts', test: { name: 'auth' } },
      { extends: './test/registration/vitest.config.ts', test: { name: 'registration' } },
      { extends: './test/profile/vitest.config.ts', test: { name: 'profile' } },
      { extends: './test/admin/vitest.config.ts', test: { name: 'admin' } },
    ],
    coverage: {
      provider: 'v8',
      reportsDirectory: './coverage/stage-d',
      reporter: ['text', 'json-summary'],
      include: ['src/auth/**/*.ts', 'src/registration/**/*.ts'],
      exclude: ['**/*.spec.ts', '**/index.ts'],
      thresholds: {
        'src/auth/**/*.ts': { lines: 80 },
        'src/registration/**/*.ts': { lines: 80 },
      },
    },
  },
});
