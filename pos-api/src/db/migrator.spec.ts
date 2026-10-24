import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MigratorConfigError, loadMigratorEnv, migratorConnection } from './migrator-config.js';
import { checksumOf, MigrationError, readSqlDir, stripTransactionWrapper } from './migrator.js';

describe('migrator (RM-C-006): разбор файлов без БД', () => {
  it('контрольная сумма не зависит от CRLF/LF', () => {
    expect(checksumOf('SELECT 1;\r\nSELECT 2;\r\n')).toBe(checksumOf('SELECT 1;\nSELECT 2;\n'));
    expect(checksumOf('SELECT 1;\n')).not.toBe(checksumOf('SELECT 2;\n'));
  });

  it('снимает только внешнюю обёртку BEGIN; … COMMIT; (PL/pgSQL BEGIN … END не трогает)', () => {
    const sql = '-- header\n\nBEGIN;\nDO $$\nBEGIN\n  PERFORM 1;\nEND $$;\nCOMMIT;\n-- tail\n';
    const out = stripTransactionWrapper(sql);
    expect(out).not.toMatch(/^\s*(--[^\n]*\n|\s)*BEGIN\s*;/);
    expect(out).not.toMatch(/COMMIT\s*;/);
    expect(out).toContain('DO $$\nBEGIN\n  PERFORM 1;\nEND $$;');
    expect(stripTransactionWrapper('INSERT INTO t VALUES (1);\n')).toBe('INSERT INTO t VALUES (1);\n');
  });

  it('0001_init.sql: обёртка снимается, транзакцией управляет мигратор', () => {
    const dir = fileURLToPath(new URL('../../migrations/', import.meta.url));
    const out = stripTransactionWrapper(readFileSync(join(dir, '0001_init.sql'), 'utf8'));
    expect(out).not.toMatch(/^COMMIT;/m);
    expect(out).not.toMatch(/^BEGIN;/m);
    const files = readSqlDir(dir);
    // Последующие миграции (0003+) добавляются этапами; здесь — порядок и первые две.
    const names = files.map((f) => f.name);
    expect(names.slice(0, 2)).toEqual(['0001_init.sql', '0002_rbac_seed.sql']);
    expect([...names].sort()).toEqual(names);
    expect(files.every((f) => f.transactional)).toBe(true);
  });

  it('имя файла вне NNNN_snake_case.sql — ошибка; директива no-transaction распознаётся', () => {
    const dir = mkdtempSync(join(tmpdir(), 'migrator-spec-'));
    try {
      writeFileSync(
        join(dir, '0001_ok.sql'),
        '-- pos-migrate: no-transaction\nCREATE INDEX CONCURRENTLY x ON t (a);\n',
      );
      expect(readSqlDir(dir)[0]?.transactional).toBe(false);
      writeFileSync(join(dir, 'Bad-Name.sql'), 'SELECT 1;');
      expect(() => readSqlDir(dir)).toThrow(MigrationError);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('подключение: логин pos_migrate + пароль из *_FILE; без пароля — только APP_ENV=dev', () => {
    const files: Record<string, string> = {
      '/run/secrets/db_migrator_password': 'p@ss:w/rd\n', // check-secrets: allow — фиктивный пароль теста загрузчика *_FILE
      '/run/secrets/database_url': 'postgres://pos_app:app@db:5432/pos?sslmode=disable\n', // check-secrets: allow — фиктивная строка теста
      '/run/secrets/database_url_short': 'postgres://pos_app:app@db/pos', // check-secrets: allow — фиктивная строка теста
    };
    const env = loadMigratorEnv(
      {
        APP_ENV: 'prod',
        DATABASE_URL_FILE: '/run/secrets/database_url',
        DB_MIGRATOR_PASSWORD_FILE: '/run/secrets/db_migrator_password',
      },
      (p) => files[p] ?? '',
    );
    const url = new URL(migratorConnection(env).connectionString);
    expect(url.username).toBe('pos_migrate');
    expect(decodeURIComponent(url.password)).toBe('p@ss:w/rd');
    expect(url.host).toBe('db:5432');
    expect(url.pathname).toBe('/pos');
    expect(url.searchParams.get('sslmode')).toBe('disable');

    const prod = loadMigratorEnv(
      { APP_ENV: 'prod', DATABASE_URL_FILE: '/run/secrets/database_url_short' },
      (p) => files[p] ?? '',
    );
    expect(() => migratorConnection(prod)).toThrow(MigratorConfigError);
    // 16 §4.3 п. (3): вне dev секреты — только через *_FILE (ревью C-MJ-01)
    expect(() => loadMigratorEnv({ APP_ENV: 'prod', DATABASE_URL: 'postgres://pos_app:app@db/pos' })).toThrow(
      /DATABASE_URL_FILE/,
    );
    const dev = migratorConnection(loadMigratorEnv({ DATABASE_URL: 'postgres://postgres:x@127.0.0.1/pos' }));
    expect(dev).toMatchObject({ user: 'postgres', fallbackToDatabaseUrlUser: true });
    expect(() => loadMigratorEnv({})).toThrow(/DATABASE_URL/);
  });
});
