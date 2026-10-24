// ESLint 10 (flat config) + typescript-eslint 8 (type-aware). Правила границ модулей — 06 §7.4 (MOD-022):
// common/** не импортирует модули D-06; циклы — `npm run madge` (RM-B-010).
import js from '@eslint/js';
import prettier from 'eslint-config-prettier';
import globals from 'globals';
import tseslint from 'typescript-eslint';

const MODULES = [
  'auth',
  'registration',
  'profile',
  'catalog',
  'cart',
  'orders',
  'payments',
  'customers',
  'transactions',
  'returns',
  'sync',
  'admin',
  'notifications',
  'health',
];

export default tseslint.config(
  { ignores: ['dist/**', 'node_modules/**', 'coverage/**', 'src/common/enums.ts', 'src/common/rbac/permissions.generated.ts'] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      globals: { ...globals.node },
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      '@typescript-eslint/consistent-type-imports': ['error', { fixStyle: 'inline-type-imports', disallowTypeAnnotations: false }],
      'no-console': ['error', { allow: ['error'] }],
      eqeqeq: ['error', 'always'],
    },
  },
  {
    // Nest DI: типы параметров конструктора должны оставаться значениями (emitDecoratorMetadata).
    files: ['src/**/*.ts'],
    rules: { '@typescript-eslint/consistent-type-imports': 'off' },
  },
  {
    files: ['src/common/**/*.ts'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          patterns: MODULES.map((m) => ({
            group: [`../${m}/*`, `../../${m}/*`, `../../../${m}/*`],
            message: `common/** не импортирует модули D-06 (06 §7.4, MOD-022): ${m}`,
          })),
        },
      ],
    },
  },
  {
    files: ['**/*.spec.ts', 'test/**/*.ts'],
    rules: {
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-unsafe-argument': 'off',
      '@typescript-eslint/unbound-method': 'off',
      '@typescript-eslint/consistent-type-imports': 'off',
    },
  },
  {
    files: ['scripts/**/*.mjs'],
    ...tseslint.configs.disableTypeChecked,
    languageOptions: { globals: { ...globals.node }, parserOptions: { projectService: false, project: false } },
    rules: { ...tseslint.configs.disableTypeChecked.rules, 'no-console': 'off' },
  },
  prettier,
);
