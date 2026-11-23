// Разбор флагов (node:util parseArgs), справка по-русски, отказ от флагов-секретов.
import { parseArgs } from 'node:util';
import { TOOL_VERSION } from './util.mjs';

export class CliError extends Error {
  constructor(msg) { super(msg); this.code = 'CLI'; }
}

const SECRET_FLAG = /^--?(password|pass|parol|pwd|token|jwt|key|client-?key|x-pos-client-key|secret|parol)(=|$)/i;

export function parseCli(argv) {
  for (const a of argv) {
    if (SECRET_FLAG.test(a)) {
      throw new CliError('пароль, ключ и токен в командной строке не передаются: пароль — только скрытым вводом или файлом (passwordFile, tokenFile, clientKeyFile в настройках)');
    }
  }
  let parsed;
  let options;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: false,
      strict: true,
      options: options = {
        config: { type: 'string' },
        checks: { type: 'string' },
        list: { type: 'boolean' },
        'allow-write': { type: 'boolean' },
        out: { type: 'string' },
        ca: { type: 'string' },
        insecure: { type: 'boolean' },
        'allow-http': { type: 'boolean' },
        demo: { type: 'boolean' },
        'expect-no-access': { type: 'boolean' },
        'no-manual': { type: 'boolean' },
        verbose: { type: 'boolean' },
        help: { type: 'boolean', short: 'h' },
        version: { type: 'boolean' },
        // для разработчиков (нет в --help, описаны в check/README.md)
        'demo-defect': { type: 'string' },
        'timeout-scale': { type: 'string' },
      },
    });
  } catch (e) {
    // Тексты Node (по-английски) не показываются; значение лишнего аргумента не повторяется — это может быть пароль.
    const opt = /'(--?[A-Za-z][\w-]*)/.exec(e.message || '')?.[1] || '';
    const def = options?.[opt.replace(/^--?/, '')];
    if (e.code === 'ERR_PARSE_ARGS_UNKNOWN_OPTION') throw new CliError(`неизвестный флаг ${opt} — список флагов: --help`);
    if (e.code === 'ERR_PARSE_ARGS_INVALID_OPTION_VALUE') {
      throw new CliError(def && def.type === 'boolean' ? `флаг ${opt} не принимает значение` : `у флага ${opt} нет значения — укажите его через пробел: ${opt} <значение>`);
    }
    if (e.code === 'ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL') {
      throw new CliError('лишний аргумент без флага — программа принимает только флаги вида --имя (список: --help); пароль и ключ — только скрытым вводом или файлом');
    }
    throw new CliError('ошибка в флагах — список флагов: --help');
  }
  const v = parsed.values;
  let timeoutScale = 1;
  if (v['timeout-scale'] !== undefined) {
    timeoutScale = Number(v['timeout-scale']);
    if (!(timeoutScale >= 0.001 && timeoutScale <= 1)) throw new CliError('--timeout-scale: число от 0.001 до 1');
  }
  return {
    config: v.config || null,
    checks: v.checks ? v.checks.split(/[,;\s]+/).map((x) => x.trim().toUpperCase()).filter(Boolean) : null,
    list: !!v.list,
    allowWrite: !!v['allow-write'],
    out: v.out || null,
    ca: v.ca || null,
    insecure: !!v.insecure,
    allowHttp: !!v['allow-http'],
    demo: !!v.demo,
    expectNoAccess: !!v['expect-no-access'],
    noManual: !!v['no-manual'],
    verbose: !!v.verbose,
    help: !!v.help,
    version: !!v.version,
    demoDefect: v['demo-defect'] || null,
    timeoutScale,
    noArgs: argv.length === 0,
  };
}

export function helpText() {
  return `Проверка API 1С (расширение OptomstroyPOS) ${TOOL_VERSION} — контракт 1.2.0, «Требования к API 1С» 1.2.1

Запуск: Proverka_API_1C.cmd [флаги]
   (то же: runtime\\node.exe programma\\main.mjs [флаги])

Без флагов — проверка чтения: программа спросит настройки (при первом запуске), пароль и ключ
(ввод скрыт), проверит методы и запишет протокол в папку protokoly.

Флаги:
  --config <файл>      файл настроек (по умолчанию nastrojki.json рядом с программой)
  --checks <список>    только эти проверки или группы: A1,C2 или A,C,PAY (зависимости добавятся)
  --list               показать каталог проверок и выйти
  --allow-write        разрешить запросы POST: тестовые объекты «ПРОВЕРКА POS», ack, перерегистрация
                       (только на ТЕСТОВОЙ копии; программа попросит подтверждение)
  --out <папка>        куда писать протоколы (по умолчанию protokoly рядом с программой)
  --ca <файл.pem>      корневой сертификат внутреннего центра (добавляется к доверенным)
  --insecure           не проверять сертификат (НЕ рекомендуется; пишется в протокол)
  --allow-http         разрешить адрес http:// (НЕ рекомендуется; по Требованиям — только HTTPS)
  --demo               прогон против встроенного имитатора на образцах 1.2.0 (без сети и паролей)
  --expect-no-access   проверка «нет доступа» с ДРУГОГО компьютера сети (M2): пароль не нужен
  --no-manual          не задавать ручные вопросы (они будут «пропущено»)
  --verbose            подробнее в консоль (пароли и ключ всё равно не выводятся)
  --help, --version    эта справка; версия программы и контракта

Пароль, ключ и токен в командной строке не принимаются — только скрытый ввод или файл,
путь к которому указан в настройках (passwordFile, tokenFile, clientKeyFile).

Коды выхода: 0 — ошибок нет; 1 — есть ошибки (ОШИБКА или «ВРУЧНУЮ: НЕТ»);
             2 — проверка не выполнена (настройки, связь, отмена, сбой программы).
`;
}
