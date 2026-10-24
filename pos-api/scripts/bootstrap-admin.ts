/**
 * Первичный администратор на пустой БД (INT-02; docs/ops/first_admin.md). Обёртка над
 * `src/admin/bootstrap/first-admin.cli.ts` для запуска из исходников:
 *
 *   APP_ENV=staging DATABASE_URL_FILE=/run/secrets/database_url … \
 *     npx tsx scripts/bootstrap-admin.ts --phone +996XXXXXXXXX --name "Фамилия Имя Отчество" [--days 7]
 *
 * В образе pos-api (каталога `scripts/` там нет) — тот же код из `dist/`:
 *   node dist/admin/bootstrap/first-admin.cli.js --phone … --name …
 *
 * Создаёт приглашение с ролью `admin`, только если активного `admin` нет; повторный запуск идемпотентен; аудит
 * `user.invited`. Секреты — только через `*_FILE` окружения pos-api; в аргументах и выводе их нет.
 */
import { runBootstrapAdminCli } from '../src/admin/bootstrap/first-admin.cli.js';

process.exitCode = await runBootstrapAdminCli(process.argv.slice(2), process.env);
