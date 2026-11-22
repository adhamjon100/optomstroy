# Резервное копирование POS под Windows Server 2022 (`infra/windows/backup`)

Перенос резервного копирования комплекта Linux (`infra/docker/backup/backup.sh`, `infra/docker/postgres/scripts/wal-archive.sh`, `infra/scripts/restore-db.sh`; 16 §8) на Windows Server без сторонних программ. Ни `age`, ни `rclone`, ни `gzip.exe` не нужны: всё делает `pos-backup.mjs` на `node.exe` из релиза (Node 24, без пакетов npm) и программы PostgreSQL 17 (`pg_dump`, `pg_dumpall`, `pg_basebackup`, `psql`, `pg_restore`, `pg_ctl`).

Правила хранения, расписание и порядок восстановления — как в комплекте Linux (16 §8.1–§8.5, RUNBOOK §4). Отличия перечислены в разделе «Отклонения от плана».

## Состав

| Файл | Назначение | Где запускается |
|---|---|---|
| `pos-backup.mjs`, `lib/*.mjs` | инструмент: служба, дамп, WAL, вне сервера, очистка, состояние, расшифровка, распаковка | сервер (`releases\<версия>\backup\`), ПК держателя ключа |
| `backup.example.json` | пример `config\backup.json` (без секретов: только пути) | сервер |
| `OptomstroyBackup.svc.example.json` | пример описания службы для `OptomstroySvc.exe` | сервер |
| `backup.ps1` | ручные шаги: `status`, `dump-now`, `base-now`, `wal-ship`, `offsite-now`, `prune`, `verify` | сервер |
| `keygen.ps1` | пара ключей RSA-4096 | **ПК держателя ключа, не сервер** |
| `restore.ps1` | восстановление из дампа (16 §8.5) | сервер, администратор + держатель ключа |
| `restore-pitr.ps1` | восстановление на момент времени (PITR) и подмена рабочей базы (`-Apply`) | сервер, администратор + держатель ключа |
| `restore-drill.ps1` | ежемесячная проверка восстановления во временный кластер (рабочая база, службы и роли не трогаются) | сервер, администратор + держатель ключа |
| `set-backup-acl.ps1` | права NTFS: закрытые корень копий и спул WAL, доступ службы к релизу и настройкам; `-CheckOnly` — проверка | сервер, администратор |
| `BackupCommon.ps1` | общие функции скриптов | — |
| `tests/optbk.test.mjs` | модульные проверки формата и инструмента (`node --test`) | ПК разработчика |
| `tests/jobs.test.mjs` | модульные проверки заданий: замок, `wal-ship` после обрыва, `wal-unpack`, вне сервера, прогон при сбое `pg_dump`, Healthchecks, `status` | ПК разработчика |
| `tests/integration.test.mjs` | проверка на настоящем PostgreSQL 17 | ПК разработчика |
| `tests/drill.test.mjs`, `tests/fakepg.mjs` | `restore-drill.ps1` и `restore.ps1` на настоящем PostgreSQL 17; `psql`/`pg_restore` подменены (`fakepg`: SQL выполняет сервер) | ПК разработчика |
| `../tests/backup.tests.ps1` | все проверки комплекта одним запуском | ПК разработчика |

## Службы, учётные записи, порты

| Что | Кто запускает | Учётная запись | Порт |
|---|---|---|---|
| `OptomstroyBackup` — `pos-backup.mjs daemon` под `OptomstroySvc.exe` | SCM, автозапуск | `NT SERVICE\OptomstroyBackup` (виртуальная) | нет |
| `archive_command` (`pos-backup.mjs wal-archive`) | служба `OptomstroyPostgres` | `NT AUTHORITY\NetworkService` | нет |

Служба подключается только к `127.0.0.1:5433` ролью `pos_backup` (атрибут `REPLICATION`, `pg_read_all_data`). Новых портов нет.

## Раскладка на сервере

```
D:\Optomstroy\
  current\backup\pos-backup.mjs       инструмент (из релиза; current — ссылка на активный релиз)
  current\node\node.exe
  config\backup.json                  настройки (без секретов)
  config\backup-public.pem            открытый ключ держателя (только открытый!)
  config\backup.svc.json              описание службы (пишет install.ps1)
  secrets\pgpass_backup.conf          файл паролей PostgreSQL для pos_backup
  data\walspool\                      спул WAL (archive_command пишет, служба забирает за ~20 с)
  data\media\, data\audit-anchors\    источники копии фото и отметок аудита
  logs\backup\                        журнал службы (пишет OptomstroySvc.exe)
D:\OptomstroyBackups\                 корень копий (лучше отдельный том)
  dumps\<UTC>.dump.optbk              ежедневный дамп pg_dump -Fc   (+ .sha256, .json)
  dumps\globals-<UTC>.sql.optbk       роли без паролей (по воскресеньям)
  dumps\monthly\<UTC>.dump.optbk      первый дамп месяца (жёсткая ссылка на тот же файл)
  pitr\<system_identifier>\base\base-<UTC>.tar.gz.optbk   базовая копия (+ .sha256, .json со start/end WAL и временем)
  pitr\<system_identifier>\wal\<сегмент>.gz.optbk         архив WAL (+ .plain.json — SHA-256 открытого сегмента)
  media\media\..., media\audit-anchors\...                 накопительная копия (без удаления), НЕ зашифрована
  state\status.json                   время и итог последних шагов (для status и мониторинга)
  state\daily.lock, state\wal.lock    замки (служба и ручной запуск не выполняют один шаг одновременно)
```

`<UTC>` — `YYYYMMDD-HHMMSS` по UTC (однозначно при смене пояса сервера). Расписание — по `timeZone` (Asia/Bishkek).

**Что зашифровано.** Дампы, globals, базовые копии и архив WAL пишутся сразу в OPTBK1 — открытый файл на диск не попадает. Фото и отметки аудита (`media\<name>`) копируются **как есть, без шифрования** (не персональные данные; 16 §8.2 — накопительная копия фото, как `rclone copy` в Linux) и в таком же виде уходят вне сервера (`<offsite>\media\`). Если владелец решит, что отметки аудита (07 §9.3) вне сервера должны быть закрыты, — это доработка (шифровать `audit-anchors` как дампы).

## `backup.json`

| Ключ | Обязательный | По умолчанию | Смысл |
|---|---|---|---|
| `backupRoot` | да | — | корень копий |
| `pgBin` | да | — | папка `bin` PostgreSQL 17 |
| `pg.host`, `pg.port`, `pg.user`, `pg.database` | нет | `127.0.0.1`, `5433`, `pos_backup`, `optomstroy` | подключение |
| `pg.credentialFile` | да | — | файл паролей PostgreSQL в формате pgpass (`127.0.0.1:5433:*:pos_backup:<пароль>`); передаётся программам PostgreSQL через `PGPASSFILE` |
| `publicKeyFile` | да | — | открытый ключ RSA-4096 (PEM) |
| `walSpoolDir` | да | — | спул WAL (его же читает `wal-archive --config`) |
| `timeZone` | нет | `Asia/Bishkek` | пояс расписания и месячной копии |
| `dailyAt` | нет | `05:30` | время ежедневного прогона (после ночного обмена) |
| `keepDays` | нет | 30 | дампы и базовые копии |
| `monthlyExtraDays` | нет | 93 | месячная копия хранится `keepDays + monthlyExtraDays` |
| `globalsKeepDays`, `globalsWeekday` | нет | 90, 0 | globals: срок; день недели (0 — воскресенье) |
| `pitr` | нет | `true` | базовые копии и архив WAL |
| `walShipEverySeconds`, `walOffsiteEverySeconds` | нет | 20, 300 | спул → архив; архив WAL → вне сервера |
| `retryMinutes` | нет | 30 | повтор ежедневного прогона, если дамп не удался |
| `chunkSize`, `gzipLevel` | нет | 1048576, 3 | кусок OPTBK1; сжатие базовых копий и WAL |
| `mediaDirs` | нет | `[]` | `[{name, path}]` — папки для накопительной копии |
| `offsite` | нет | `null` | копия вне сервера (см. «Копия вне сервера»): `{ "path": "\\\\nas\\share" }` — копирует служба; `{ "mode": "pull" }` — хранилище само забирает файлы из корня копий (служба ничего не копирует); `null` — копии вне сервера нет, `status`: `offsite-not-configured` |
| `healthchecksUrlFile` | нет | `null` | файл секрета с адресом проверки Healthchecks (`secrets\healthchecks_url`); оповещения `/start`, `/fail`, успех |
| `alerting` | нет | `null` | `"external"` — оповещение делает внешний мониторинг, опрашивающий `status` (без Healthchecks). Без `healthchecksUrlFile` и без `"external"` — `status`: `alerting-not-configured` |
| `statusCheckEveryMinutes` | нет | 10 | самопроверка службы (правила `status`): проблемы — в журнал и `/fail` |

Ошибки схемы выводятся все сразу; служба при ошибке не запускается (код 2).

## Команды `pos-backup.mjs`

```
node pos-backup.mjs daemon      --config backup.json   служба: расписание, WAL, вне сервера; стоп — конец stdin
node pos-backup.mjs dump-now    --config backup.json [--globals]
node pos-backup.mjs dump-only   --config backup.json                 только дамп (обновление программы)
node pos-backup.mjs base-now | wal-ship | media-now | prune --config backup.json
node pos-backup.mjs offsite-now --config backup.json [--wal]
node pos-backup.mjs status      --config backup.json [--no-db]       JSON; код 0 — норма, 1 — проблемы
node pos-backup.mjs drill-record --config backup.json --result ok|fail [--dump <файл>] [--seconds N] [--detail <текст>] [--ping-url-file <файл>]
                                                                      итог restore-drill.ps1 в state\status.json
node pos-backup.mjs wal-archive --config backup.json <%p> <%f>       archive_command
node pos-backup.mjs verify-file <файл> [--key private.pem]
node pos-backup.mjs keygen      --out <папка>                         ПК держателя ключа
node pos-backup.mjs decrypt     --key private.pem [--gunzip] <вход> <выход|->
node pos-backup.mjs decrypt-pipe --key private.pem [--gunzip] <вход> -- <программа> [аргументы]
node pos-backup.mjs restore-base --key private.pem <base-….tar.gz.optbk> --to <пустая папка> [--no-space-check]
node pos-backup.mjs wal-unpack  --key private.pem --from <pitr\…\wal> --to <папка> [--start-wal <сегмент>] [--allow-gap] [--segment-mb 16] [--no-space-check]
node pos-backup.mjs key-id      --public public.pem
```

Коды выхода: 0 — успех, 1 — ошибка, 2 — неверный вызов или настройки; у `wal-unpack` 3 — архив неполный (дыра в номерах сегментов или повреждённый сегмент): распакован непрерывный отрезок до неё, строка «НЕПОЛНЫЙ АРХИВ» называет последний сегмент. `restore-base` и `wal-unpack` до расшифровки сравнивают оценку объёма (`tarBytes` из `.json` базовой копии; число сегментов × 16 МиБ) со свободным местом тома назначения плюс 1 ГиБ запаса.

`dump-only` — дамп, `.sha256`/`.json`, месячная копия; код 0 — дамп опубликован. Его вызывает обновление программы («копия перед обновлением»): недоступное хранилище вне сервера не должно останавливать обновление, и базовая копия при каждом обновлении не нужна. `dump-now` — полный ежедневный прогон. Журнал — строки JSON в stdout (`{"time","service":"pos-backup","level","msg"}`); значения секретов не печатаются. Парольная фраза закрытого ключа — `--passphrase-file`, переменная `POS_BACKUP_KEY_PASSPHRASE` или ввод с клавиатуры (скрипты `.ps1` спрашивают её через `Read-Host -AsSecureString` и передают только через окружение процесса).

### Ежедневный прогон (`daemon` в `dailyAt`, `dump-now`)

Порядок как в Linux: дамп → месячная копия → globals (в `globalsWeekday`) → базовая копия PITR → фото → вне сервера → очистка. Ошибки собираются в `state\status.json` (`lastError`), прогон завершается с ошибкой. Повтор через `retryMinutes` — только если не удался дамп. Пропущенный прогон (служба или сервер были остановлены в `dailyAt`) выполняется сразу после запуска.

- Базовая копия — **не больше одной за местный день**: повтор прогона (дамп не удался) её не повторяет. Иначе при постоянном сбое `pg_dump` (неверный pgpass, нет программы) каждые 30 минут появлялась бы новая полная копия — около 37 в сутки, и том копий и хранилище вне сервера заполнились бы.
- Сбой дампа — **очистка не выполняется** (в Linux прогон заканчивается сразу после сбоя дампа): старые дампы не удаляются, пока нет нового. Фото и копия вне сервера накопительные и выполняются.
- Оповещение (как `ping_hc` в Linux), если задан `healthchecksUrlFile`: `/start` в начале прогона, `/fail` с текстом ошибок, пустой суффикс при успехе. Адрес — секрет (`secrets\healthchecks_url`), в журнал не пишется; недоставленный ping — только предупреждение.

Дамп: `pg_dump -Fc` запускается дочерним процессом, его stdout потоком шифруется в `<файл>.partial`. Файл публикуется только если `pg_dump` вернул 0, поток завершён и данных больше нуля (оба кода выхода проверяются — проблема `cmd /c "pg_dump | age"` из черновика плана снята). Иначе `.partial` удаляется. Открытый дамп на диск не пишется.

Базовая копия: `pg_basebackup -D - -F tar -X fetch --checkpoint=fast --no-manifest` → gzip → OPTBK1; в `.json` — `startWal`/`endWal` (`pg_walfile_name` до и после), время начала и конца, `system_identifier`.

### Архив WAL

1. `archive_command` (служба PostgreSQL) — `wal-archive`: копирует сегмент во временный файл в спуле, `fsync`, сверяет SHA-256 с источником, публикует **без перезаписи** (жёсткая ссылка; ошибка, если имя уже есть), сверяет SHA-256 опубликованного файла. Код 0 — только после этого. Файл с тем же именем и тем же содержимым — 0 (повтор после сбоя), с другим — 1, ничего не перезаписывается. Сброс каталога (`fsync` папки) в Windows невозможен — метаданные NTFS журналируются.
2. Служба раз в `walShipEverySeconds` (20 с): gzip → OPTBK1 в `pitr\<system_identifier>\wal\`, `.plain.json` (SHA-256 открытого сегмента — только для сверки повторной архивации, вне сервера не уходит) **до** публикации архива (как `.sha256` в Linux: обрыв между шагами не останавливает отправку навсегда), публикация без перезаписи, удаление из спула. Брошенные `.plain.json` без архива старше суток удаляет `prune`. `system_identifier` берётся из заголовка сегмента (длинный заголовок страницы WAL), для `.history`/`.backup` — последний известный или запрос к базе. Отправка идёт по порядку имён; при ошибке следующие сегменты ждут.
3. Раз в `walOffsiteEverySeconds` (5 мин) — копия архива WAL вне сервера. Как `wal_upload` в Linux, проверяются только файлы, опубликованные с начала прошлого полностью успешного прохода (минус 15 минут, окно не меньше 2 ч; отметки нет — весь архив): общая папка не перечисляется целиком каждые 5 минут. Сбой — повтор через минуту; отметка двигается только после прохода без ошибок, поэтому после перебоя всё накопленное уходит первым успешным проходом. Ночной прогон сверяет всё.

Решение «сжимать, затем шифровать»: как в Linux (`.gz.age`) — сегменты сжимаются в разы, а сжатие до шифрования не раскрывает ничего, кроме размера (размер сегмента и так известен). Открытый сегмент лежит в спуле на томе базы не дольше ~20 с — как в Linux.

Строка для `postgresql.conf` (её пишет `infra/windows/postgres/init-postgres.ps1`):

```
archive_mode = on
archive_timeout = 60
archive_command = '"D:\\Optomstroy\\current\\node\\node.exe" "D:\\Optomstroy\\current\\backup\\pos-backup.mjs" wal-archive --config "D:\\Optomstroy\\config\\backup.json" "%p" "%f"'
```

### Копия вне сервера

`offsite.path` — папка (обычно общая папка `\\nas\share`). Копируются готовые файлы `dumps\`, `pitr\` (без `.plain.json`) — зашифрованные, `media\` — фото и отметки аудита **в открытом виде**: потоком во временное имя и переименованием. **Там ничего не удаляется и не перезаписывается**: файл уже есть с тем же размером — пропуск; с другим размером — предупреждение и признак `offsite-conflicts` в `status`. Хранение вне сервера — правилами самого хранилища (как `rclone copy --immutable` в Linux).

Копирование (и фото, и вне сервера) асинхронное и прерываемое: пока многогигабайтная базовая копия идёт на общую папку, служба отправляет WAL и штатно останавливается по концу stdin за секунды (временный файл удаляется), а не ждёт конца копии до `stopTimeoutSeconds` = 60 с, после которых `OptomstroySvc.exe` убил бы процесс.

**Открытый вопрос — решение владельца и заказчика до запуска в работу.** Виртуальная учётная запись `NT SERVICE\OptomstroyBackup` обращается к сети от имени учётной записи компьютера (`<ДОМЕН>\<СЕРВЕР>$`). VPS заказчика — отдельный сервер, скорее всего не в домене; тогда в NAS или общую папку она **не войдёт**, `offsite-now` падает с «недоступен», а `status` постоянно показывает `wal-offsite-older-30m`. Поэтому в `backup.example.json` `offsite` = `null`; общая папка `\\nas\share` подходит только серверу в домене. Варианты (выбирает заказчик вместе с владельцем):

1. **Отдельная локальная учётная запись** `svc-optomstroy-backup` (план v0.2) вместо виртуальной: служба `OptomstroyBackup` запускается под ней (`sc.exe config OptomstroyBackup obj= .\svc-optomstroy-backup password= …` — пароль вводит администратор), на NAS заводится одноимённая учётная запись с тем же паролем или явное подключение (`cmdkey` от имени этой учётной записи). Пароль надо менять и хранить.
2. **Модель «забирает хранилище»**: на сервере общая папка только для чтения на `D:\OptomstroyBackups` (доступ одной учётной записи NAS), NAS или удалённый ПК сам копирует новые файлы по расписанию (robocopy `/XO` без удаления, rsync). Сервер не хранит пароль от хранилища, а взломанный сервер не может удалить копии вне сервера. В `backup.json` — `"offsite": { "mode": "pull" }` (служба ничего не копирует, `offsite-not-configured` снимается); контроль свежести — на стороне NAS (сервер не знает, когда NAS забрал файлы).
3. **HTTPS/SFTP-хранилище** — в инструменте нет (без сторонних программ); потребует доработки.

До решения: `offsite: null` (так пишет `install.ps1`). Копии вне сервера нет — все копии пропадут вместе с сервером (16 §8.1: «Копия вне сервера — обязательна»). Это **не молчит**: `status` (и `scripts\status.ps1`) показывает `offsite-not-configured`, служба при запуске и в самопроверке пишет строку `error` в журнал. `/fail` в Healthchecks из-за этого не отправляется (иначе проверка была бы «красной» постоянно и настоящий сбой не отличался бы от ненастроенной копии). Снимается только настройкой `offsite` (копирование службой или `{ "mode": "pull" }`).

### Очистка (`prune`)

Дампы — `keepDays`, но три самых новых ежедневных дампа не удаляются никогда (отличие от Linux: если `pg_dump` падает дольше `keepDays`, без этой защиты остались бы только месячные); месячные — `keepDays + monthlyExtraDays`; globals — `globalsKeepDays`; базовые копии — `keepDays`, самая новая с `.json` не удаляется никогда; WAL — пока нужен самой старой оставшейся базовой копии (сравнение номеров сегментов без линии времени), `.history` не удаляются; у кластера без базовых копий WAL удаляется по сроку `keepDays`. Брошенные `.partial` старше суток удаляются. Вне сервера очистка не выполняется.

### Состояние (`status`) для мониторинга

JSON: последний дамп (файл, размер, возраст), последняя базовая копия, объём архива WAL и время последней отправки, спул (число файлов, возраст самого старого), `pg_stat_archiver`, время последней копии вне сервера, отметка жизни службы. Поле `problems` и код 1 при: `daemon-not-running` (служба не обновляла `daemonHeartbeatUtc` дольше 3 мин; Linux: `schedule-loop-not-running`), `dump-older-26h`, `base-older-26h`, `wal-spool-stuck-10m`, `archive-mode-off`, `wal-archive-failing` (последняя ошибка архивации новее последнего успеха), `db-unreachable`, `offsite-older-26h`, `wal-offsite-older-30m`, `offsite-conflicts`, `last-run-failed` (последний ежедневный прогон с ошибкой; снимается следующим успешным прогоном, `dump-only` его не снимает — ошибка могла быть в копии вне сервера), `restore-drill-failed` (последняя проверка `restore-drill.ps1` не пройдена).

Риски настройки и порядка работы — тоже в `problems` и код 1, сразу после установки (без отсрочки 26 ч), но служба **не** шлёт из-за них `/fail` в Healthchecks (только строка `error` в журнале при запуске и в самопроверке, не чаще раза в час при неизменном списке): `offsite-not-configured` (`offsite` = `null`), `alerting-not-configured` (нет `healthchecksUrlFile` и `alerting` ≠ `"external"`), `restore-drill-older-35d` (успешной проверки восстановления не было дольше 35 суток; отсчёт — с `monitorSinceUtc`). Поля `offsiteMode` (`push`, `pull`, `null`), `alerting` (`healthchecks`, `external`, `null`), `lastRestoreDrill`, `lastRestoreDrillOkUtc`.

Пороги те же, что у healthcheck Linux; отсчёт — с первого запуска службы (`monitorSinceUtc` в `state\status.json`, как `.pitr_since` в Linux): на свежей установке отсутствие копий — не ошибка первые 26 ч (копия WAL вне сервера — 30 мин). `backup.ps1 -Action status` дополнительно проверяет права закрытых папок (`set-backup-acl.ps1 -CheckOnly`).

**Кто замечает сбои.** Служба раз в `statusCheckEveryMinutes` (10 мин) выполняет те же проверки сама: проблемы — строка `error` в журнале службы (`logs\backup`) и, если задан `healthchecksUrlFile`, `/fail` в Healthchecks. Healthchecks сам поднимает тревогу, если успешного ping нет дольше периода проверки (служба или сервер не работают). Без `healthchecksUrlFile` сбой виден только в журнале и по `status` (и сам `status` показывает `alerting-not-configured`) — для работы в магазине оповещение обязательно (адрес проверки — от владельца; секрет `secrets\healthchecks_url`, права — `set-backup-acl.ps1`). Журнал событий Windows не используется: регистрация источника событий требует прав администратора на каждом обновлении.

## Формат OPTBK1

Гибридное шифрование: на каждый файл — случайный ключ AES-256-GCM, он зашифрован открытым ключом RSA-4096 (RSA-OAEP, SHA-256). Данные — кусками по `chunkSize` с тегом GCM у каждого. Закрытый ключ на сервере не хранится.

Заголовок (числа big-endian):

| Смещение | Байт | Поле |
|---|---|---|
| 0 | 6 | магия `OPTBK1` |
| 6 | 1 | версия = 1 |
| 7 | 1 | флаги = 0 |
| 8 | 4 | `chunkSize` (1 КиБ … 16 МиБ) |
| 12 | 32 | `keyId` = SHA-256 открытого ключа (SubjectPublicKeyInfo, DER) |
| 44 | 2 | `wrappedLen` (512 для RSA-4096) |
| 46 | `wrappedLen` | RSA-OAEP-SHA256(32 байта ключа AES) |

Затем куски до последнего: `флаг` (1 байт: 0 — не последний, 1 — последний), `N` (4 байта, длина шифртекста; у не последнего куска ровно `chunkSize`, у последнего 0…`chunkSize`), шифртекст `N` байт, тег 16 байт.

- Одноразовое число куска `i` — 4 нулевых байта и `i` (uint64). Ключ у каждого файла свой, повтор пары «ключ, число» невозможен.
- AAD куска — `SHA-256(заголовок) || i (uint64) || флаг`. Поэтому подмена заголовка, перестановка или удаление кусков, подмена флага «последний» ломают проверку тега.
- Файл без последнего куска — «обрезан» (`truncated`), байты после последнего куска — ошибка (`trailing`). Последний кусок пишется только при нормальном конце входного потока: если `pg_dump` оборвался, файл останется без него (и будет удалён).
- Расшифровка отдаёт каждый кусок только после проверки его тега; ошибка (подмена — `auth`, чужой ключ — `wrong-key`, обрезка) прерывает поток. Потребитель (`pg_restore`) получает данные потоком: при подмене в середине файла восстановление прерывается с ошибкой и база считается неполной.

`verify-file` без ключа проверяет магию, версию, структуру и длины кусков, наличие последнего куска, отсутствие хвоста, SHA-256 файла против `.sha256` и манифеста `.json` (размер, `keyId`). Подлинность кусков без закрытого ключа не проверить; `verify-file --key` расшифровывает файл целиком (и распаковывает gzip у `.gz.optbk`) без записи на диск.

## Ключи

На ПК держателя ключа (не на сервере): `.\keygen.ps1 -OutDir E:\optomstroy-key -NodeExe <node.exe>` — парольная фраза не короче 12 символов (без интерактивной консоли — `-PassphraseFile <файл>`, иначе скрипт сразу завершается с ошибкой, а не ждёт ввода). Получаются `backup-public.pem` (передаётся администратору: `config\backup-public.pem`), `backup-private.pem` (зашифрован парольной фразой; хранить офлайн, вторая копия — в другом месте) и `key-id.txt`. Сверка на сервере: `node pos-backup.mjs key-id --public config\backup-public.pem` должен совпасть с `key-id.txt`; служба печатает `keyId` при запуске.

## Команды администратора (posdeploy их выполнить не может)

**Подлинность архива держится на правах папок.** OPTBK1 шифрует открытым ключом, поэтому зашифровать «правильный» дамп или сегмент WAL может любой, кто может писать в `D:\OptomstroyBackups` или в `data\walspool`; PITR воспроизвёл бы подложенный WAL. На томе данных у «Прошедших проверку» (Authenticated Users) по умолчанию есть право изменения вложенных папок (`icacls D:\` на ПК разработчика: `NT AUTHORITY\Authenticated Users:(OI)(CI)(IO)(M)`). Поэтому корень копий и спул **закрываются** (наследование отключено, явные права только Administrators, SYSTEM и службам), и это проверяется: `set-backup-acl.ps1 -CheckOnly` и каждый `backup.ps1 -Action status`.

Порядок (PowerShell «от имени администратора», после регистрации службы `OptomstroyBackup` — SID виртуальной учётной записи появляется вместе со службой):

Службу `OptomstroyBackup` регистрирует `scripts\install.ps1` (шаг «Службы Windows и права учётных записей служб») вместе с `OptomstroyApi` и `OptomstroyWorker`; команды для ручной регистрации — `infra/windows/svchost/README.md`, «3. Регистрация служб». Описание службы — `config\backup.svc.json` (его пишет `install.ps1`; образец полей — `OptomstroyBackup.svc.example.json`). Если регистрировать вручную, параметры должны совпадать с `install.ps1`:

```powershell
$root = 'D:\Optomstroy'
# 1. Служба — те же параметры, что у install.ps1 (иначе следующий install.ps1/update.ps1 приведёт их к этим):
$bin = '\"' + "$root\current\svchost\OptomstroySvc.exe" + '\" --config \"' + "$root\config\backup.svc.json" + '\"'
sc.exe create OptomstroyBackup binPath= $bin start= delayed-auto obj= "NT SERVICE\OptomstroyBackup" DisplayName= 'Optomstroy POS backup' depend= OptomstroyPostgres
sc.exe sidtype OptomstroyBackup unrestricted
sc.exe failure OptomstroyBackup reset= 86400 actions= restart/10000/restart/10000/restart/60000
sc.exe failureflag OptomstroyBackup 1
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\OptomstroyBackup' -Name PreshutdownTimeout -Value 90000 -Type DWord
# 2. secrets\pgpass_backup.conf: одна строка 127.0.0.1:5433:*:pos_backup:<пароль из db_backup_password> (ASCII, без BOM);
#    secrets\healthchecks_url (по желанию): адрес проверки Healthchecks одной строкой.
# 3. Права (повторный запуск безопасен):
& "$root\current\backup\set-backup-acl.ps1" -InstallRoot $root -BackupRoot 'D:\OptomstroyBackups'
```

`set-backup-acl.ps1` делает то же, что следующие команды (для администратора, который выполняет их вручную; `*S-1-5-32-544` — Administrators, `*S-1-5-18` — SYSTEM, `*S-1-5-20` — NetworkService, SID указаны вместо имён, потому что на русской Windows имена групп локализованы):

```powershell
$root = 'D:\Optomstroy'; $bk = 'D:\OptomstroyBackups'; $svc = 'NT SERVICE\OptomstroyBackup'
New-Item -ItemType Directory -Force "$bk", "$root\data\walspool", "$root\logs\backup", "$root\releases" | Out-Null
# закрытые папки: наследование отключено, только администраторы, SYSTEM и службы
icacls $bk                   /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "${svc}:(OI)(CI)M"
icacls "$root\data\walspool" /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "${svc}:(OI)(CI)M" '*S-1-5-20:(OI)(CI)M'
# запуск службы из релиза: node.exe и pos-backup.mjs через junction current
icacls $root                 /grant "${svc}:(RX)"            # только сама папка
icacls "$root\releases"      /grant "${svc}:(OI)(CI)RX"
icacls "$root\data\media"         /grant "${svc}:(OI)(CI)RX"
icacls "$root\data\audit-anchors" /grant "${svc}:(OI)(CI)RX"
icacls "$root\logs\backup"        /grant "${svc}:(OI)(CI)M"
icacls "$root\config\backup.json"       /grant "${svc}:(R)"
icacls "$root\config\backup-public.pem" /grant "${svc}:(R)"
icacls "$root\secrets\pgpass_backup.conf" /inheritance:r /grant:r '*S-1-5-32-544:F' "${svc}:(R)"
```

Учётной записи службы PostgreSQL (`archive_command`) права на `releases`, `config\backup.json` и спул выдаёт `infra/windows/postgres/init-postgres.ps1` (`Grant-PgArchiveAccess`); `set-backup-acl.ps1` после этого оставляет ей `M` на спуле (параметр `-PgServiceAccount`, по умолчанию `NT AUTHORITY\NetworkService`).

После запуска: `.\backup.ps1 -Action dump-now -Globals` (первая полная копия), `.\backup.ps1 -Action status` (код 0), `pg_stat_archiver.failed_count = 0`, держатель ключа проверяет восстановление (ниже).

## Восстановление из дампа (`restore.ps1`, 16 §8.5)

Администратор в PowerShell «от имени администратора», держатель ключа приносит `backup-private.pem` на съёмном носителе:

```powershell
.\restore.ps1 -DumpFile D:\OptomstroyBackups\dumps\20261121-003000.dump.optbk -KeyFile E:\key\backup-private.pem `
              [-GlobalsFile D:\OptomstroyBackups\dumps\globals-….sql.optbk] [-SuperPassFile <pgpass postgres>]
```

0. Предварительные проверки до любых изменений (без `-SkipPasswords`): `postgres\apply-roles.ps1` релиза, файлы секретов `pg_password`, `db_migrator_password`, `db_backup_password`, `database_url`; база в `database_url` должна совпадать с `-Database` (восстановление в другую базу — `-SkipPasswords` или проверка копии — `restore-drill.ps1`); модуль `pg` в `-ApiDir` (по умолчанию `current\api`).
1. `verify-file --key` — копия **целиком** с ключом (подлинность каждого куска, расшифровка без записи на диск; то же для `-GlobalsFile`). Неверный ключ или парольная фраза, подменённый или повреждённый файл — выход до любых изменений (как «`age -d` в никуда» в Linux).
2. Подтверждение вводом имени базы (`-Force` или `-DevTest` — без ввода).
3. Остановка `OptomstroyApi`, `OptomstroyWorker`, `OptomstroyBackup`.
4. Роли из globals (по желанию; в копии нет паролей).
5. Прежняя база **переименовывается** в `<база>_before_<время>` — страховочная копия (с `-DropOld` — удаляется; возможно только после успешной проверки шага 1). Новую базу создаёт `postgres\apply-roles.ps1` — тот же, что у `install.ps1`, `update.ps1` и `rollback.ps1`: локаль эталона (UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE `-LcCtype`, по умолчанию en-US), роли по `roles.sql` (NOSUPERUSER, NOBYPASSRLS и т. д. — это же снимает лишние атрибуты, пришедшие из globals; у `pos_backup` — `REPLICATION` и `pg_read_all_data`), пароли из `secrets\` **верификаторами SCRAM-SHA-256** (открытый пароль не попадает ни в командную строку, ни в журнал PostgreSQL — кластер пишет медленные операторы, `log_min_duration_statement = 500ms`), права на базу, стоп-проверка `lower('ЁЯ') = 'ёя'`. С `-SkipPasswords` роли не трогаются (должны уже быть), база создаётся скриптом с той же локалью. В обоих случаях — своя стоп-проверка локали новой базы перед восстановлением.
6. `decrypt-pipe` → `pg_restore --exit-on-error` (без `-j`); проверяются расшифровка и код `pg_restore`; `ANALYZE`; список расширений.
7. Фото и отметки аудита — каждая папка `mediaDirs` из `backup.json` (`media\<name>` → её `path`; без `backup.json` — `media` → `data\media`, `audit-anchors` → `data\audit-anchors`), `robocopy /E /XO`, без удаления.
8–11. Подсказки: `migrate`, если программа новее копии; OPS-KI-04 (кассиры: заказы и корзины после момента копии потеряны); запуск служб; ручной обмен с 1С.

Пароль `postgres` для `psql` и `pg_restore` — `-SuperPassFile` (файл паролей) или ввод с клавиатуры; `apply-roles.ps1` берёт его из `secrets\pg_password`. `-DevTest` — без остановки и запуска служб и без ввода подтверждения (проверочный стенд); фото — только если явно задан `-BackupConfig` (папки рабочей установки не трогаются).

`restore.ps1` **не** подходит для ежемесячной проверки: без `-DevTest` он останавливает службы и меняет рабочую базу. Для проверки — `restore-drill.ps1` (ниже). Копия расшифровывается дважды (проверка и восстановление) — время восстановления больше, зато рабочая база не трогается, пока копия не проверена.

## Восстановление на момент времени (`restore-pitr.ps1`)

```powershell
.\restore-pitr.ps1 -KeyFile E:\key\backup-private.pem -TargetTime '2026-11-21 14:05:00+06:00' -DataDir D:\Optomstroy\data\pg-restore
# проверить данные на 127.0.0.1:5434, затем:
.\restore-pitr.ps1 -Apply -DataDir D:\Optomstroy\data\pg-restore
```

Рабочая база не трогается до `-Apply`. Шаги:

1. Остановка служб программы.
2. **Конец WAL в архив** (как `restore-db.sh` в Linux): `pg_switch_wal()` на рабочем кластере (суперпользователь: `-SuperPassFile` или ввод пароля), ожидание, пока `pg_stat_archiver.last_archived_wal` дойдёт до закрытого сегмента (до 5 мин; не дошёл — отказ), затем `pos-backup wal-ship` — спул в зашифрованный архив. Без этого шага «до последнего момента» потерял бы последние 1–2 минуты и всё, что лежало в спуле (служба резервного копирования уже остановлена). Рабочий кластер недоступен (авария) — предупреждение и продолжение; `-SkipWalFlush` — пропуск шага.
3. Выбор самой новой базовой копии, закончившейся раньше момента (или самой новой при `-Latest`) → `restore-base` в пустую папку (оценка места).
4. `wal-unpack` с `startWal` копии: проверка непрерывности номеров сегментов и места на диске; повреждённый сегмент останавливает распаковку на нём. Архив неполный (код 3): с `-Latest` — **отказ** (иначе восстановление молча остановилось бы на дыре и скрипт сообщил бы об успехе); с `-TargetTime` — предупреждение (момент после дыры даст «recovery ended before configured recovery target»); `-AllowWalGap` — осознанно восстановить до дыры.
5. В `postgresql.auto.conf` блок: `restore_command = 'copy "<папка WAL>\%f" "%p"'`, `recovery_target_time`, `recovery_target_action = 'promote'` (или `recovery_target_timeline = 'latest'`), `logging_collector = off` и `log_destination = 'stderr'` (кластер из `init-postgres.ps1` пишет журнал сборщиком в общую папку `logs\pg` — в тот же `postgresql-%a.log`, что рабочий; временный кластер пишет только в свой журнал `-l`, который читает скрипт), `archive_mode = 'off'`, временный порт и `127.0.0.1` → `recovery.signal`.
6. `pg_ctl start` → ожидание: `recovery.signal` удалён и в журнале «database system is ready to accept connections»; ошибки восстановления (как в Linux: «recovery ended before configured recovery target», PANIC и др.) — отказ; истекло `-TimeoutMinutes` — временный кластер останавливается (`pg_ctl stop -m immediate`), отказ.
7. Итог — строки журнала «recovery stopping before commit…», «last completed transaction…».

`-Apply`: остановка временного кластера, удаление блока восстановления из `postgresql.auto.conf` (журнал и архивирование снова как в `optomstroy.conf`), остановка служб и `OptomstroyPostgres`, `data\pg` → `data\pg-before-<время>`, восстановленная папка → `data\pg`, права как у `init-postgres.ps1` (наследование отключено; Administrators и SYSTEM — F, учётная запись службы PostgreSQL — M; владелец Administrators; проверка — нарушение останавливает до запуска службы), отправка `.history` новой линии времени в архив WAL (при `archive_mode=off` она туда не попала), запуск `OptomstroyPostgres`. Дальше — сразу новая базовая копия (`backup.ps1 -Action base-now`), `migrate` при необходимости, OPS-KI-04, запуск служб, обмен с 1С.

## Ежемесячная проверка восстановления (`restore-drill.ps1`, 16 §8.1)

Перенос `infra/scripts/backup-restore-test.sh` без Docker. Рабочая база, службы и роли рабочего кластера **не трогаются**: можно запускать при работающем магазине. Администратор с держателем ключа:

```powershell
.\restore-drill.ps1 -KeyFile E:\key\backup-private.pem [-DumpFile <копия>] [-WorkDir E:\drill] [-Port 5435] [-PingUrlFile <файл с адресом Healthchecks «restore-drill»>]
```

1. Копия — `-DumpFile` или самый новый `dumps\*.dump.optbk` (затем `dumps\monthly`).
2. `verify-file --key` — копия целиком (подлинность каждого куска, без записи на диск).
3. Временный кластер: `initdb` в `-WorkDir` (по умолчанию папка во `%TEMP%`; свободного места — с запасом, оценка 10 × размер копии) с локалью рабочего (builtin C.UTF-8, LC_COLLATE C, LC_CTYPE `-LcCtype`), случайный пароль `postgres` только на время проверки, `pg_ctl start` на `127.0.0.1:-Port` (по умолчанию 5435), `archive_mode = off` — в архив WAL рабочего ничего не пишется. PostgreSQL под администратором работает с ограниченным маркером, поэтому `-WorkDir` получает явное право текущего пользователя.
4. Роли рабочего контура без входа, база `restore_check`, стоп-проверка `lower('ЁЯ') = 'ёя'`.
5. `decrypt-pipe` → `pg_restore --exit-on-error`.
6. Проверки как в Linux: `pos_meta.schema_migrations` не пуст; расширения `pg_trgm`, `unaccent`, `pgcrypto`; ключевые таблицы `products`, `product_variants`, `customers`, `orders`, `payments`, `audit_logs` есть — число строк в вывод (сверка с контрольными значениями — запись в журнале эксплуатации); владелец `pos_migrate` и права `pos_app` — предупреждение, если их нет в копии.
7. Уборка всегда, и после ошибки: `pg_ctl stop`, удаление `-WorkDir` (`-Keep` — оставить для разбора).
8. Итог — `pos-backup.mjs drill-record` в `state\status.json`: `status` показывает `restore-drill-failed` и `restore-drill-older-35d`; `-PingUrlFile` — отдельная проверка Healthchecks (успех — ping, ошибка — `/fail`). Код выхода: 0 — копия восстанавливается, 1 — нет.

PITR проверяется отдельно: `restore-pitr.ps1 -Latest -DataDir <временная папка> -Port 5434` (рабочая база не трогается до `-Apply`); после проверки — `pg_ctl stop -D <папка>`, папки удаляются. Ключ после проверок уносится.

## Что проверено (2026-11-21, ПК разработчика, Windows 11, Node 24.11.1, PostgreSQL 17.10 из `@embedded-postgres`)

- `node --test tests/optbk.test.mjs` — 17 из 17: обход формата (0 байт … 300 КБ, мелкие порции потока), подмена байта шифртекста и заголовка, обрезка (граница куска, внутри куска, заголовок), подмена флага «последний», перестановка кусков, хвост, чужой ключ, ключ под парольной фразой, CLI `keygen`/`decrypt`/`verify-file`, `wal-archive` (запись, повтор, конфликт, неверное имя), tar (ustar, длинное имя, отказ на `..`), конвейер «программа → OPTBK1» (код 0, код 3, пустой вывод, программа не найдена, остановка), очистка по срокам, `decrypt-pipe`.
- `node --test tests/jobs.test.mjs` — 7 из 7: замок (живой владелец; переиспользованный PID со старой отметкой; мёртвый PID; чужой замок не удаляется); `wal-ship` после обрыва между отпечатком и публикацией (оба места обрыва) и удаление брошенных отпечатков; `wal-unpack` — дыра (код 3, распакован отрезок до неё; `--allow-gap`), повреждённый сегмент (код 3, распакован отрезок до него), переход номера через границу логического файла; копия WAL вне сервера только в окне с прошлого успеха, ночной проход — всё, остановка посреди копии 64 МиБ без временных файлов; `status` на свежей установке и `daemon-not-running`; три новейших дампа не удаляются; ежедневный прогон с поддельными `pg_dump.exe` (код 1), `pg_basebackup.exe`, `psql.exe` (собраны `csc.exe`): два прогона (второй — повтор через 31 мин) дают одну базовую копию, очистки нет, Healthchecks получает `/start`, `/fail`, `/start`, `/fail`.
- `node --test tests/integration.test.mjs` — 5 из 5 на настоящем PostgreSQL 17.10 (порты 55441–55443), шестая проверка (официальные программы) пропущена — их нет: кластер `builtin C.UTF-8` (`lower('ЁЯ') = 'ёя'`) с `archive_command = pos-backup wal-archive`, `failed_count = 0`, журнал **как у `init-postgres.ps1`** (`logging_collector = on`, абсолютная `log_directory`, `postgresql-%a.log`); базовая копия, зашифрованная конвейером pos-backup; `wal-ship`; служба `daemon` (прогон по расписанию: дамп падает — нет `pg_dump`, очистка пропущена, вторая базовая копия за день не делается; фото, копия вне сервера, отправка нового сегмента, штатная остановка по концу stdin с кодом 0; `status`: `last-run-failed`, `daemon-not-running`, без `dump-older-26h` на свежей установке); `restore-pitr.ps1 -DevTest` на момент между двумя вставками — есть только первая, в журнале «recovery stopping before commit», журнал восстановления — в своём файле `-l`; `-Latest` — все строки, включая вставку, сегмент которой лежал **в спуле** (не в архиве) до запуска скрипта: его отправил шаг 1а (`wal-ship`).
- 2026-11-22, `node --test tests/jobs.test.mjs` — 9 из 9: добавлены риски настройки в `status` (`offsite-not-configured`, `alerting-not-configured` на свежей установке; `{ "mode": "pull" }` и `"alerting": "external"` их снимают; ошибки схемы `offsite`/`alerting`) и проверка восстановления (`drill-record`: `restore-drill-failed`, `restore-drill-older-35d`, через 36 суток после успеха — снова).
- 2026-11-22, `node --test tests/drill.test.mjs` — 4 из 4 на настоящем PostgreSQL 17.10 (`initdb`/`pg_ctl`/`postgres` из `@embedded-postgres`, порты 55445–55446); `psql.exe` и `pg_restore.exe` — подмена `fakepg` (собрана `csc.exe`, SQL выполняет настоящий сервер через модуль `pg`; «дамп» — зашифрованный OPTBK1 SQL-текст, формат `-Fc` не воспроизводится): `restore-drill.ps1 -DevTest` — успех (число строк в выводе, временная папка удалена, порт свободен, `lastRestoreDrill = ok`), копия без журнала миграций — код 1, кластер остановлен и папка удалена и после ошибки, `restore-drill-failed`; `restore.ps1 -DevTest` на кластере без ролей программы с прежней базой — `apply-roles.ps1` создал базу (builtin C.UTF-8, C, en-US) и роли (пароли — `SCRAM-SHA-256$`, NOSUPERUSER, NOBYPASSRLS, REPLICATION только у `pos_backup`), прежняя база переименована, `pos_app` входит паролем из `database_url`, **в журнале сервера с `log_statement = all` нет ни одного открытого пароля**, фото и `audit-anchors` восстановлены из корня копий; база в `database_url` ≠ `-Database` — отказ до проверки копии. Эта проверка нашла ошибку в SQL стоп-проверки (`text || "char"` — неоднозначный оператор), исправлено.
- `set-backup-acl.ps1 -DevTest` на временных папках (текущий пользователь вместо служб): наследование отключено, `-CheckOnly` — код 0; добавленное право «Прошедших проверку» (`*S-1-5-11:M`) — нарушение, код 1.
- Все `.ps1` разобраны парсером PowerShell 5.1 без ошибок, UTF-8 с BOM.

**Не проверено на этом ПК** (в наборе `@embedded-postgres` есть только `initdb`, `pg_ctl`, `postgres`; других программ PostgreSQL на ПК нет — поиск по `Program Files`, `AppData`, `ProgramData`): вызовы `pg_dump`, `pg_dumpall`, настоящего `pg_basebackup`, `psql` из инструмента, `restore.ps1` целиком (`pg_restore`, `psql`), `status` с запросом к базе, `pg_switch_wal` и ожидание `pg_stat_archiver` в шаге 1а `restore-pitr.ps1`, `-Apply` (службы, права с учётной записью службы, `/setowner` — нужны права администратора), `set-backup-acl.ps1` с виртуальной учётной записью, регистрация службы, оповещение реального Healthchecks (проверено на локальном приёмнике). Базовая копия в интеграционной проверке сделана низкоуровневым API (`pg_backup_start`/`pg_backup_stop` + `tar.exe`) и зашифрована тем же конвейером (`encryptChildToFile`), что и `pg_basebackup`.

**Обязательно до запуска в работу (тестовый адрес с официальными программами PostgreSQL 17.10):** `powershell -File infra\windows\tests\backup.tests.ps1 -PgBin 'C:\Program Files\PostgreSQL\17\bin'` — тогда выполняется шестая интеграционная проверка: `dump-only` (настоящий `pg_dump -Fc` в stdout), `base-now` (`pg_basebackup -D - -F tar -X fetch`), `status` с запросом к базе, `restore.ps1 -DevTest` в соседнюю базу со сравнением числа строк, `restore-drill.ps1 -DevTest` с настоящим `pg_restore` во временный кластер (порт 55448; в тестовой базе нет журнала миграций — ожидается код 1 после восстановления, временная папка удалена), `restore-pitr.ps1 -DevTest -Latest` из копии `pg_basebackup` (распаковка tar, шаг 1а с настоящим `pg_switch_wal`). Затем вручную администратором: `set-backup-acl.ps1`, `restore-pitr.ps1 -Apply` на тестовом кластере.

Запуск: `powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\backup.tests.ps1` (`-SkipIntegration` — без PostgreSQL; `-PgBin` — другая папка `bin`, например полная установка PostgreSQL 17).

## Отклонения от плана (WINDOWS_NATIVE_PLAN.md v0.2, раздел 7)

- Вместо `age` — собственный формат OPTBK1 на встроенной криптографии Node (RSA-OAEP-4096 + AES-256-GCM): требование «без сторонних программ». Копии Linux (`.age`) этим инструментом не читаются, и наоборот.
- Вместо `rclone` — копирование в папку (`offsite.path`, обычно общая папка) без удаления и перезаписи. Облачные хранилища напрямую не поддерживаются.
- Вместо заданий Планировщика — служба `OptomstroyBackup` с внутренним расписанием (решение пакета); вместо отдельной локальной учётной записи `svc-optomstroy-backup` — виртуальная `NT SERVICE\OptomstroyBackup` (см. ограничение для хранилищ вне домена).
- Проверка двух кодов выхода (`pg_dump` и шифрования) выполнена в Node, а не двумя объектами `System.Diagnostics.Process`.
- `restore.ps1` не удаляет прежнюю базу, а переименовывает (страховочная копия без отдельного дампа; `-DropOld` — удалить).
- PITR восстанавливается рядом с рабочей базой, подмена — отдельным шагом `-Apply`; во время проверки `archive_mode = off`, чтобы проверочный кластер не писал в архив рабочего.
- Сверх Linux: базовая копия — не больше одной за местный день; три новейших дампа не удаляются при очистке; `wal-unpack` проверяет непрерывность архива WAL и место на диске; самопроверка службы раз в 10 минут с `/fail` в Healthchecks (в Linux — healthcheck Docker).
- Копия вне сервера для сервера не в домене не решена (см. «Копия вне сервера») — пункт владельца и заказчика. Пока не решена, `status` показывает `offsite-not-configured` (и `alerting-not-configured`, если нет Healthchecks).
- Проверка восстановления (`restore-drill.ps1`) — во временный кластер `initdb`/`pg_ctl` на `127.0.0.1` вместо временного контейнера в сети Docker `internal`; итог — в `state\status.json` (`restore-drill-older-35d` — напоминание о ежемесячной проверке). Шаг PITR Linux-проверки (`--pitr`) не перенесён: PITR проверяется `restore-pitr.ps1 -Latest` во временную папку.
- PowerShell 5.1 не передаёт двоичные данные между программами конвейером `|`, поэтому расшифровка в `pg_restore`/`psql` идёт через `pos-backup.mjs decrypt-pipe`, а распаковка базовой копии — встроенной распаковкой tar (`restore-base`), без `tar.exe`.
