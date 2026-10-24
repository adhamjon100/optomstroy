import { randomUUID } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { type AppConfig, ConfigError, loadAppConfig } from '../../common/config/app-config.js';
import { createPool } from '../../common/db/database.module.js';
import { createDatabase } from '../../db/database.js';
import { type BootstrapAdminResult, bootstrapFirstAdmin } from './first-admin.js';

/**
 * CLI первичного администратора (INT-02; описание — docs/ops/first_admin.md):
 *
 *   node dist/admin/bootstrap/first-admin.cli.js --phone +996XXXXXXXXX --name "Фамилия Имя Отчество" [--days 7]
 *   npx tsx scripts/bootstrap-admin.ts --phone … --name …          # из исходников (dev, рабочее место оператора)
 *
 * Окружение — то же, что у pos-api (`loadAppConfig`: `DATABASE_URL_FILE` и прочие `*_FILE`; секретов в аргументах
 * нет). Вывод — без ПДн: номер маскирован, ФИО не печатается. Коды выхода:
 *   0 — приглашение создано, уже действует (повторный запуск) или активный admin уже есть (ничего не сделано);
 *   2 — ошибка аргументов или конфигурации; 3 — отказ (номер занят / действует приглашение admin на другой номер);
 *   1 — непредвиденная ошибка (транзакция откатывается целиком).
 */
export interface CliIo {
  readonly out: (line: string) => void;
  readonly err: (line: string) => void;
}

const USAGE =
  'usage: bootstrap-admin --phone <+996XXXXXXXXX> --name "<ФИО>" [--days <1…30>]\n' +
  '  окружение pos-api: APP_ENV, DATABASE_URL_FILE (или DATABASE_URL в dev), MIN_APP_VERSION, … (16 §4.3)';

export async function runBootstrapAdminCli(
  argv: readonly string[],
  env: NodeJS.ProcessEnv,
  io: CliIo = {
    out: (l) =>
      process.stdout.write(`${l}
`),
    err: (l) => console.error(l),
  },
): Promise<number> {
  let args: { phone?: string; name?: string; days?: string; help?: boolean };
  try {
    args = parseArgs({
      args: [...argv],
      options: {
        phone: { type: 'string' },
        name: { type: 'string' },
        days: { type: 'string' },
        help: { type: 'boolean', short: 'h' },
      },
      strict: true,
    }).values;
  } catch (e) {
    io.err(`bootstrap-admin: ${e instanceof Error ? e.message : String(e)}\n${USAGE}`);
    return 2;
  }
  if (args.help) {
    io.out(USAGE);
    return 0;
  }
  if (!args.phone || !args.name) {
    io.err(`bootstrap-admin: --phone и --name обязательны\n${USAGE}`);
    return 2;
  }
  let config: AppConfig;
  try {
    config = loadAppConfig(env);
  } catch (e) {
    io.err(`bootstrap-admin: конфигурация: ${e instanceof ConfigError ? e.message : 'ошибка чтения окружения'}`);
    return 2;
  }
  const ttlDays = args.days !== undefined ? Number(args.days) : config.INVITATION_TTL_DAYS;
  const requestId = randomUUID();
  const pool = createPool(config, 'bootstrap-admin');
  try {
    const result = await bootstrapFirstAdmin(createDatabase(pool), {
      phone: args.phone,
      fullName: args.name,
      ttlDays,
      requestId,
    });
    return report(result, requestId, io);
  } catch (e) {
    io.err(
      `bootstrap-admin: ошибка (${e instanceof Error ? e.name : 'unknown'}), изменений нет; requestId=${requestId}`,
    );
    return 1;
  } finally {
    await pool.end().catch(() => undefined);
  }
}

function report(r: BootstrapAdminResult, requestId: string, io: CliIo): number {
  switch (r.kind) {
    case 'created':
      io.out(
        `bootstrap-admin: создано приглашение admin ${r.invitationId} для ${r.phoneMasked}, действует до ` +
          `${r.expiresAt.toISOString()}; вход — по OTP с этого номера, затем установка PIN. requestId=${requestId}`,
      );
      return 0;
    case 'already_pending':
      io.out(
        `bootstrap-admin: приглашение admin ${r.invitationId} для ${r.phoneMasked} уже действует до ` +
          `${r.expiresAt.toISOString()} — изменений нет`,
      );
      return 0;
    case 'admin_exists':
      io.out('bootstrap-admin: активный администратор уже есть — изменений нет (приглашения выдаёт admin в SCR-45)');
      return 0;
    case 'invalid':
      io.err(
        `bootstrap-admin: --${r.field === 'fullName' ? 'name' : r.field === 'ttlDays' ? 'days' : 'phone'}: ${r.message}`,
      );
      return 2;
    case 'phone_taken':
      io.err(
        `bootstrap-admin: номер ${r.phoneMasked} уже принадлежит учётной записи — отказ (см. docs/ops/first_admin.md)`,
      );
      return 3;
    case 'other_pending':
      io.err(
        `bootstrap-admin: действует приглашение admin на другой номер (${r.phoneMasked}, до ` +
          `${r.expiresAt.toISOString()}) — отказ; дождитесь входа или срока`,
      );
      return 3;
  }
}

/** Запуск файлом (`node dist/admin/bootstrap/first-admin.cli.js …`). */
function isMain(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(realpathSync(entry)).href;
  } catch {
    return false;
  }
}

if (isMain()) {
  void runBootstrapAdminCli(process.argv.slice(2), process.env).then((code) => {
    process.exitCode = code;
  });
}
