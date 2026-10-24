/**
 * Разовая перерегистрация состава плана обмена «POS» в 1С — `POST /pos/v1/changes/reregister` (05 §6.2 п. 4 и
 * уточнение п. 3; ТЗ для 1С 5.2 п. 7, 5.3 п. 11, 6.4; 16 §10 «переход в рабочий режим»; разбор расхождений п. 31).
 *
 * Когда запускать (администратор POS, лучше в ночное окно — разовая нагрузка на 1С):
 * - при переводе POS в рабочий режим (`ONEC_MODE=extension` на проде) — регистрации, снятые ack до подключения
 *   обработчиков всех типов, приходят снова;
 * - после подключения обработки нового типа элементов (ПКО и поступления — после ответа по Q-012);
 * - для полной перезагрузки данных из 1С.
 *
 *   cd pos-api && npm run onec:reregister -- --confirm --reason "переход в рабочий режим"
 *   # журнал (JSON-строки, без секретов): по умолчанию ./onec_reregister.journal.jsonl, иначе --journal <путь>
 *
 * Конфигурация — как у pos-worker (`ONEC_MODE=extension`, `ONEC_BASE_URL`, `ONEC_HS_PATH`, секреты — *_FILE; 16 §4.3).
 * В `odata_only` метода нет (фаза 0) — отказ. Без `--confirm` — только проверка `/health` и подсказка.
 * После 202 расширение перерегистрирует состав в фоне; изменения придут очередными циклами `onec.changes`
 * (состав — `GET /pos/v1/health.registrationBacklog`). Код выхода: 0 — принято (или проверка без `--confirm`);
 * 1 — 1С отклонила или недоступна (текст ошибки — в stderr и журнале); 2 — параметры/конфигурация.
 */
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { type AppConfig, loadAppConfig } from '../src/common/config/app-config.js';
import { onecAdapters } from '../src/integrations/onec/onec-adapters.js';
import { isOnecError } from '../src/integrations/onec/onec-error.js';
import { createOnecGateway } from '../src/integrations/onec/onec-gateway.factory.js';
import type { OnecGateway } from '../src/integrations/onec/onec-gateway.js';

export const DEFAULT_JOURNAL = 'onec_reregister.journal.jsonl';

/** Запись журнала перерегистрации (без секретов и ПДн). */
export interface ReregisterJournalEntry {
  readonly at: string;
  readonly requestId: string;
  readonly onecMode: string;
  readonly reason: string | null;
  readonly action: 'check' | 'reregister';
  readonly result: 'accepted' | 'checked' | 'failed' | 'refused';
  readonly httpStatus?: number;
  readonly errorCode?: string;
  readonly error?: string;
  readonly backlogBefore?: number | null;
  readonly lastAckMessageNumber?: number | null;
}

export interface ReregisterDeps {
  readonly config: Pick<AppConfig, 'ONEC_MODE'>;
  readonly gateway: () => OnecGateway;
  readonly journal: (entry: ReregisterJournalEntry) => void;
  readonly out: (line: string) => void;
  readonly err: (line: string) => void;
  readonly now?: () => Date;
}

/** Шаги CLI без процесса (тестируется на `FakeOnecGateway`). Возвращает код выхода. */
export async function runReregister(argv: readonly string[], deps: ReregisterDeps): Promise<number> {
  const { values } = parseArgs({
    args: [...argv],
    options: {
      confirm: { type: 'boolean' },
      reason: { type: 'string' },
      journal: { type: 'string' },
    },
    allowPositionals: false,
  });
  const now = deps.now ?? (() => new Date());
  const requestId = randomUUID();
  const reason = values.reason?.slice(0, 200) ?? null;
  const base = { requestId, onecMode: deps.config.ONEC_MODE, reason };
  const action = values.confirm === true ? 'reregister' : 'check';
  if (deps.config.ONEC_MODE === 'odata_only') {
    const msg = 'ONEC_MODE=odata_only: метода /changes/reregister нет (фаза 0) — перерегистрация не выполняется';
    deps.journal({ ...base, at: now().toISOString(), action, result: 'refused', error: msg });
    deps.err(`[onec-reregister] ОТКАЗ: ${msg}`);
    return 2;
  }
  const gw = deps.gateway();
  let backlogBefore: number | null = null;
  let lastAck: number | null = null;
  try {
    const h = await gw.getHealth({ requestId });
    backlogBefore = typeof h.body.registrationBacklog === 'number' ? h.body.registrationBacklog : null;
    lastAck = typeof h.body.lastAckMessageNumber === 'number' ? h.body.lastAckMessageNumber : null;
    deps.out(
      `[onec-reregister] /health: регистраций в очереди ${backlogBefore ?? '—'}, последний ack ${lastAck ?? '—'}`,
    );
    if (action === 'check') {
      deps.journal({
        ...base,
        at: now().toISOString(),
        action,
        result: 'checked',
        backlogBefore,
        lastAckMessageNumber: lastAck,
      });
      deps.out('[onec-reregister] проверка выполнена; для перерегистрации добавьте --confirm (разовая нагрузка на 1С)');
      return 0;
    }
    const r = await gw.reregisterChanges({ requestId });
    deps.journal({
      ...base,
      at: now().toISOString(),
      action,
      result: 'accepted',
      httpStatus: r.status,
      backlogBefore,
      lastAckMessageNumber: lastAck,
    });
    deps.out(
      `[onec-reregister] ПРИНЯТО (${r.status}): 1С перерегистрирует состав плана обмена в фоне; изменения придут ` +
        'циклами onec.changes, ход — /health.registrationBacklog (requestId ' +
        requestId +
        ')',
    );
    return 0;
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    deps.journal({
      ...base,
      at: now().toISOString(),
      action,
      result: 'failed',
      ...(isOnecError(e) ? { httpStatus: e.status, errorCode: e.code } : {}),
      error: message.slice(0, 500),
      backlogBefore,
      lastAckMessageNumber: lastAck,
    });
    deps.err(`[onec-reregister] ОШИБКА: ${message}`);
    return 1;
  }
}

async function main(): Promise<number> {
  const argv = process.argv.slice(2);
  const journalPath = parseArgs({
    args: argv,
    options: { journal: { type: 'string' }, confirm: { type: 'boolean' }, reason: { type: 'string' } },
  }).values.journal;
  const config = loadAppConfig(process.env);
  return runReregister(argv, {
    config,
    gateway: () => createOnecGateway(config, onecAdapters(config)),
    journal: (entry) => appendFileSync(journalPath ?? DEFAULT_JOURNAL, `${JSON.stringify(entry)}\n`, 'utf8'),
    out: (line) => process.stdout.write(`${line}\n`),
    err: (line) => process.stderr.write(`${line}\n`),
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`[onec-reregister] ОШИБКА КОНФИГУРАЦИИ: ${e instanceof Error ? e.message : String(e)}\n`);
      process.exit(2);
    },
  );
}
