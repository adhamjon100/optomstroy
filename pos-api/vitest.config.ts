import { defineConfig } from 'vitest/config';

// Unit-тесты: src/**/*.spec.ts. Nest DI требует emitDecoratorMetadata — Vite 8 (oxc) читает его из tsconfig.json
// (тот же подход, что в шаблоне Nest 12 ts-esm).
export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['src/**/*.spec.ts'],
    environment: 'node',
    pool: 'forks',
    testTimeout: 20_000,
  },
});
