# PostgreSQL 17.10 для Windows Server 2022 (комплект Optomstroy)

Комплект ставит отдельный экземпляр PostgreSQL для программы Optomstroy: служба `OptomstroyPostgres`, порт
`127.0.0.1:5433`, вход только по `scram-sha-256`, архивирование WAL для восстановления на момент времени (PITR).
Базу 1С и SQL Server он не трогает, порты 80/443 и Hyper-V не затрагивает.

| Файл | Назначение |
| --- | --- |
| `init-postgres.ps1` | закрытые права `data\pg`/`logs\pg`, `initdb`, `optomstroy.conf` и `pg_hba.conf`, права для `archive_command`, регистрация и запуск службы (администратор); `-Resume` — продолжить после сбоя; `-DevTest` — запуск без службы |
| `apply-roles.ps1` | база, роли и права (`roles.sql`), стоп-проверка локали, проверка архивирования WAL, `-Verify` — проверка прав входом под каждой ролью |
| `roles.sql` | роли и права — перенос `infra/docker/postgres/initdb/10-roles.sh` (повторяемый) |
| `pg-tool.mjs` | выполняет SQL через модуль `pg` релиза на `node.exe` релиза (psql не нужен) |
| `stop-postgres.ps1` | остановка; `-Unregister` — снятие службы. Данные не удаляет |
| `pg-common.ps1` | общие функции скриптов |
| `test/pg-test-helper.mjs` | только для проверочного прогона `infra/windows/tests/postgres.tests.ps1` |

Скрипты — Windows PowerShell 5.1, UTF-8 с BOM. Параметр `-InstallRoot` (по умолчанию `D:\Optomstroy`) задаёт
пути по умолчанию: `data\pg`, `logs\pg`, `secrets\`, `config\backup.json`, `current\node\node.exe`, `current\api`.

## Параметры кластера

- `initdb -E UTF8 --data-checksums --locale-provider=builtin --builtin-locale=C.UTF-8 --locale=C --lc-ctype=en-US`
  и база `CREATE DATABASE … TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8'
  LC_COLLATE 'C' LC_CTYPE 'en-US'` — как у `pos-api/scripts/local-stack.mjs` на Windows и как 16 §4.4 (а)
  («на Windows — `en-US`»). `lower()`/`upper()` — по Unicode (провайдер builtin), сортировка побайтовая,
  `LC_CTYPE en-US` нужен FTS и `pg_trgm` для кириллицы. В Linux-комплекте — libc `C.UTF-8`; на Windows такой
  libc-локали нет, поэтому провайдер builtin (результат для программы проверен прогоном миграций, см. ниже).
- `optomstroy.conf` (в каталоге данных, подключается строкой `include 'optomstroy.conf'` в конце
  `postgresql.conf`): `listen_addresses = '127.0.0.1'`, `port = 5433`, `unix_socket_directories = ''`,
  `password_encryption = scram-sha-256`, `shared_preload_libraries = pg_stat_statements`, `timezone = UTC`,
  `wal_level = replica`, `archive_mode = on`, `archive_timeout = 60`, `wal_keep_size = 256MB`, журналы — в
  `logs\pg` (`postgresql-Mon.log` … неделя по кругу), `log_min_duration_statement = 500ms`.
- Память (сервер общий с 1С и SQL Server): `shared_buffers` 1GB (`-SharedBuffers 512MB`, если на нашу часть 4 ГБ),
  `effective_cache_size` 2GB, `work_mem` 16MB, `maintenance_work_mem` 128MB, `max_connections` 100,
  `huge_pages = off`. Обязательное условие — ограниченный `max server memory` у SQL Server.
- `pg_hba.conf` целиком заменяется: `host all all 127.0.0.1/32 scram-sha-256` и
  `host replication pos_backup 127.0.0.1/32 scram-sha-256` (для `pg_basebackup`). Строк `local` нет.
- Жёсткого предела памяти и процессора, как `memory: ${PG_MEM_LIMIT:-2G}` / `cpus: 2.0` у контейнера в
  `infra/compose.prod.yml`, на Windows у комплекта нет (объект задания для службы не создаётся): расход памяти
  PostgreSQL ограничен только настройками — примерно `shared_buffers` + `work_mem` × число одновременных
  сортировок/хешей в активных соединениях (`max_connections` 100) + `maintenance_work_mem` на обслуживание.
  Если памяти мало — уменьшайте `-SharedBuffers` и `-MaxConnections`.
- Изменить параметры потом: `init-postgres.ps1 -ConfigOnly … -SharedBuffers 512MB`, затем
  `Restart-Service OptomstroyPostgres` (остановит и зависимые службы программы — запустить их снова).
  С правами администратора `-ConfigOnly` ещё и проверяет права папок данных и журналов (предупреждения).

## Права папок данных и журналов

`init-postgres.ps1` сам закрывает `data\pg` и `logs\pg` (до `initdb`): наследование от родительской папки
отключается (`icacls /inheritance:r`), явные права — только Administrators и SYSTEM (полный доступ) и учётная
запись службы PostgreSQL (изменение); владелец — Administrators. После регистрации службы скрипт проверяет, что
других записей нет, иначе останавливается. Без этого на томе данных группа «Прошедшие проверку» (Authenticated
Users) по умолчанию наследует изменение вложенных папок, и любая локальная учётная запись (службы 1С и SQL Server,
пользователи RDP) могла бы вписать `trust` в `pg_hba.conf` и получить базу. Отключение наследования на корне
`D:\Optomstroy` (план, шаг 2) по-прежнему нужно для остальных папок, но для PostgreSQL от него не зависит.

На время `initdb` запускающий администратор получает явное полное право на эти папки: `initdb` под администратором
перезапускает себя с ограниченным маркером (группа Administrators в нём только запрещающая) и иначе не смог бы
писать в папку. Пароль суперпользователя `initdb` читает из временной копии `pg_password` в `logs\pg\.tmp` (копия
удаляется при любом исходе) — по той же причине: папка `secrets` закрыта только для Administrators и SYSTEM.
После регистрации службы явное право администратора снимается.

Антивирус (Microsoft Defender и др.): исключите из проверки при доступе `D:\Optomstroy\data\pg` и
`D:\Optomstroy\data\walspool` (сканирование файлов данных и сегментов WAL замедляет PostgreSQL и может вызывать
ошибки «Permission denied» при переименовании файлов). Пример для Defender [Администратор]:
`Add-MpPreference -ExclusionPath 'D:\Optomstroy\data\pg','D:\Optomstroy\data\walspool'`.

## archive_command — контракт с пакетом резервного копирования

```
"<InstallRoot>\current\node\node.exe" "<InstallRoot>\current\backup\pos-backup.mjs" wal-archive --config "<InstallRoot>\config\backup.json" "%p" "%f"
```

- Команду выполняет `cmd.exe` от имени учётной записи службы PostgreSQL; рабочий каталог — каталог данных,
  `%p` — путь **относительно каталога данных** в виде Windows (`pg_wal\000000010000000000000001`), `%f` — имя файла.
  Проверено прогоном с настоящим `pos-backup.mjs` (через junction `current`, `backup.json` с `walSpoolDir`, пути с
  пробелами): сегмент найден по относительному `%p` и сохранён в спул.
- Код 0 — только когда файл надёжно сохранён; иначе PostgreSQL повторит архивирование и сегмент не удалит.
- Путь через `current` — после переключения релиза архивирование само берёт новую версию инструмента. На время
  переключения `current` команда может вернуть ошибку — PostgreSQL повторит.
- Права учётной записи службы PostgreSQL выдаёт `init-postgres.ps1` (после регистрации службы, для стандартной
  команды и `archive_mode = on`); `config\backup.json` с `walSpoolDir` должен существовать **до** запуска скрипта:

  ```powershell
  $acct = 'NT AUTHORITY\NetworkService'          # учётная запись службы OptomstroyPostgres
  icacls D:\Optomstroy                   /grant "${acct}:(RX)"           # только сама папка: переход к current
  icacls D:\Optomstroy\releases          /grant "${acct}:(OI)(CI)RX"     # node.exe и pos-backup.mjs любого релиза
  icacls D:\Optomstroy\config\backup.json /grant "${acct}:(R)"           # секретов не содержит
  icacls D:\Optomstroy\data\walspool     /grant "${acct}:(OI)(CI)M"      # walSpoolDir из backup.json
  ```

  Без этих прав каждый вызов `archive_command` завершается ошибкой, сегменты копятся в `pg_wal` (диск
  заполняется), а PITR молча перестаёт работать. Поэтому `apply-roles.ps1` в конце проверяет архивирование:
  запись в WAL, `pg_switch_wal()`, ожидание сегмента в `pg_stat_archiver`; рост `failed_count` — ошибка.
- Другая команда: `init-postgres.ps1 -ArchiveCommand '…'` (`%p` и `%f` обязательны; права на её файлы скрипт не
  выдаёт). `-ArchiveMode off` — без PITR (проверка архивирования пропускается).

## Учётная запись службы

По умолчанию `NT AUTHORITY\NetworkService` (как у установщика EDB): пароля нет, не администратор (`postgres.exe`
под администратором не запускается). `-ServiceAccount 'NT SERVICE\OptomstroyPostgres'` (виртуальная учётная
запись, изолированнее: NetworkService общая для нескольких служб Windows) технически передаётся в
`pg_ctl register` без изменений, а права скрипт выдаёт **после** регистрации (SID виртуальной учётной записи
появляется вместе со службой). На Windows Server этот вариант **не проверялся** — у нас нет прав администратора;
до проверки на тестовом адресе используется NetworkService. При переходе на виртуальную учётную запись тот же
параметр нужно передать и восстановлению (`infra/windows/backup/restore-pitr.ps1 -PgServiceAccount …`, там по
умолчанию тоже NetworkService).

**Остаточный риск NetworkService.** Это общая учётная запись: любой процесс, работающий под NetworkService
(другие службы Windows на этом сервере), получает те же права, что PostgreSQL, — изменение каталога данных
(`pg_hba.conf`, файлы базы) и спула WAL. Права папок закрывают доступ всем остальным, но не этим службам.
**Обязательная проверка перед установкой (шаг 1а `init-postgres.ps1`).** Скрипт сам перечисляет службы, работающие
под той же учётной записью (`Win32_Service`, сравнение по SID; своя служба не считается), и пишет результат в
`logs\pg\precheck-service-account.log` (дописывается при каждом запуске: время, режим, итог `OK`/`WARN`/`ACCEPTED`,
список служб с пометкой `[Windows]` или `[СТОРОННЯЯ]`). Компонент Windows — исполняемый файл внутри `%SystemRoot%`;
всё остальное, в том числе программы Microsoft вне папки Windows (например SQL Server, если он запущен под
NetworkService), считается сторонним. Если сторонние службы есть, а служба `OptomstroyPostgres` ещё не
зарегистрирована, скрипт **останавливается до любых изменений на диске**. Дальше — одно из двух:

1. Рекомендуется: виртуальная учётная запись `-ServiceAccount 'NT SERVICE\OptomstroyPostgres'` (её проверять не нужно —
   она принадлежит только этой службе). Сначала — на тестовом адресе: `init-postgres.ps1 … -ServiceAccount 'NT SERVICE\OptomstroyPostgres'`,
   `Get-Service OptomstroyPostgres` (Running), `apply-roles.ps1` (включая проверку архивирования WAL — она идёт от
   имени службы), `Restart-Service OptomstroyPostgres`; тот же параметр — `set-backup-acl.ps1 -PgServiceAccount` и
   `restore-pitr.ps1 -PgServiceAccount`.
2. Осознанно оставить NetworkService: `init-postgres.ps1 … -AcceptSharedServiceAccount` (итог `ACCEPTED` в журнале).

При `-Resume`/`-ConfigOnly` (учётная запись уже выбрана) и `-DevTest` проверка только предупреждает, но журнал пишется.
Посмотреть вручную то же самое:

```powershell
Get-CimInstance Win32_Service | Where-Object StartName -like '*NetworkService*' | Select-Object Name, DisplayName, State, PathName
```

Умолчание остаётся NetworkService: виртуальная учётная запись с `pg_ctl register` у нас не проверена (нет прав
администратора и доступа к тестовому адресу). После проверки на тестовом адресе её стоит сделать умолчанием.
`install.ps1` пока не передаёт `-AcceptSharedServiceAccount`/`-ServiceAccount` — при остановке на этой проверке
администратор запускает `init-postgres.ps1` сам (с выбранным вариантом), затем `install.ps1` (кластер и служба уже
есть — `initdb` не повторяется).

## Порядок установки [Администратор]

Пароли — только в файлах `secrets\` (одна строка печатных ASCII-символов без пробелов, от 16 символов, без BOM;
допускается один перевод строки в конце, вторая строка — ошибка): `pg_password` (суперпользователь `postgres`),
`db_migrator_password`, `db_backup_password`, `database_url` (`postgres://pos_app:<пароль>@127.0.0.1:5433/<база>`;
имя базы берётся отсюда). Значения не выводятся; серверу `pg-tool.mjs` передаёт не пароли, а верификаторы
SCRAM-SHA-256.

Имя секрета суперпользователя — `pg_password`, как в Linux-комплекте (`infra/compose.prod.yml`, `infra/scripts`) и
16_DEPLOYMENT_PLAN; в черновике плана для Windows он назван `pg_superuser_password` — в комплекте одно имя,
`pg_password`. В отличие от черновика плана (временный файл пароля удаляется после `initdb`), `pg_password`
**остаётся** в `secrets\`: он нужен повторным запускам `apply-roles.ps1` (смена паролей ролей), восстановлению и
ротации — как в Linux-комплекте. Права на файл — только Administrators и SYSTEM (наследуются от `secrets`);
ни одна служба программы его не читает.

Предварительно: распакован релиз (`current\node\node.exe`, `current\api`, `current\backup`), создан
`config\backup.json` с `walSpoolDir` (пакет резервного копирования), созданы файлы секретов.

```powershell
$pg = 'C:\Program Files\PostgreSQL\17\bin'     # бинарные файлы PostgreSQL 17.10 для Windows x64
$kit = 'D:\Optomstroy\current\scripts\postgres' # папка комплекта в релизе
# 0. Брандмауэр (до запуска службы) и проверка, что порт свободен
New-NetFirewallRule -DisplayName 'Optomstroy PostgreSQL 5433 block inbound' -Direction Inbound -Protocol TCP -LocalPort 5433 -Action Block
Get-NetTCPConnection -State Listen -LocalPort 5433 -ErrorAction SilentlyContinue
# 1. Кластер, закрытые права data\pg и logs\pg, права для archive_command, служба
& "$kit\init-postgres.ps1" -PgBin $pg -InstallRoot D:\Optomstroy
#    сбой после initdb (регистрация, права, sc.exe, запуск) — исправить причину и продолжить:
#    & "$kit\init-postgres.ps1" -PgBin $pg -InstallRoot D:\Optomstroy -Resume
# 2. База, роли, стоп-проверка lower('ЁЯ') = 'ёя' (провал — установка останавливается), проверка архивирования WAL
& "$kit\apply-roles.ps1" -InstallRoot D:\Optomstroy
# 3. Миграции под pos_migrate (APP_ENV: prod — рабочий адрес, staging — тестовый)
$env:APP_ENV = 'prod'
$env:DATABASE_URL_FILE = 'D:\Optomstroy\secrets\database_url'
$env:DB_MIGRATOR_PASSWORD_FILE = 'D:\Optomstroy\secrets\db_migrator_password'
Push-Location D:\Optomstroy\current\api
& D:\Optomstroy\current\node\node.exe dist\migrate.js
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "migrate: код $LASTEXITCODE" }
Pop-Location
Remove-Item Env:APP_ENV, Env:DATABASE_URL_FILE, Env:DB_MIGRATOR_PASSWORD_FILE
# 4. Проверка прав всех ролей после миграций (и ещё раз архивирование)
& "$kit\apply-roles.ps1" -InstallRoot D:\Optomstroy -GateOnly -Verify
# 5. Перезапуск при сбое (проверить один раз на тестовом адресе): после остановки процесса postmaster служба
#    должна сама вернуться в Running в течение ~10 с (sc.exe failure + failureflag)
Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" | Where-Object { $_.CommandLine -match '-D' -and $_.CommandLine -notmatch '--forkchild' } | Select-Object ProcessId, CommandLine
#    Stop-Process -Id <ProcessId postmaster> -Force; Start-Sleep 20; Get-Service OptomstroyPostgres
```

`apply-roles.ps1` нужен распакованный релиз (`current\node\node.exe`, `current\api\node_modules\pg`) или
`-NodeExe`/`-ApiDir`. Скрипт повторяемый: смена пароля роли = новый файл секрета + повторный запуск.
`-Verify` читает по одной строке из каждой таблицы (без полного прохода), но в одной транзакции держит блокировки
ACCESS SHARE на все таблицы — несколько секунд; на рабочей базе не запускайте его одновременно с миграциями.

Перезапуск при сбое. `pg_ctl register` создаёт службу, процесс которой (`pg_ctl runservice`) следит за postmaster.
Скрипт задаёт `sc.exe failure` (перезапуск через 10/30/60 с) и `sc.exe failureflag 1` (перезапуск и тогда, когда
служба сообщает «остановлена» с кодом ошибки). Если `pg_ctl` после аварии postmaster сообщает «остановлена» с кодом
0, Windows службу не перезапустит — исходный код `pg_ctl` здесь не проверялся, поэтому шаг 5 выше обязателен на
тестовом адресе; если служба не вернулась — сообщить нам (нужен внешний контроль, например задание планировщика).

## Откат

```powershell
& "$kit\stop-postgres.ps1" -PgBin $pg -InstallRoot D:\Optomstroy -Unregister   # служба снята, данные на месте
Remove-NetFirewallRule -DisplayName 'Optomstroy PostgreSQL 5433 block inbound'
```

Каталог `data\pg` удаляется только вручную и только после проверенной резервной копии.

Сбой `init-postgres.ps1` на середине:

| Где остановился | Что делать |
| --- | --- |
| до `initdb` или в `initdb` (каталог данных пуст или неполон, `PG_VERSION` нет) | исправить причину; если в `data\pg` что-то осталось — очистить его (базы ещё нет) и запустить скрипт заново |
| после `initdb`: `pg_ctl register`, права, `sc.exe`, запуск службы | исправить причину, затем `init-postgres.ps1 … -Resume`: `initdb` не повторяется, уже зарегистрированная служба не регистрируется заново, права, действия при сбое и запуск выполняются |
| нужно начать заново | `stop-postgres.ps1 -Unregister`, затем — только если базы и данных в ней ещё нет — очистить `data\pg` и запустить скрипт без `-Resume` |

## Проверка без прав администратора

`powershell -File infra\windows\tests\postgres.tests.ps1` — на встроенных бинарных файлах 17.10 из
`pos-api\node_modules\@embedded-postgres\windows-x64\native\bin`, порт 55432: разбор .ps1, проверка файла пароля
(одна строка), обязательная проверка общей учётной записи (разбор путей служб, сторонняя служба под
NetworkService находится, своя служба и другие учётные записи не считаются, виртуальная учётная запись, настоящий
список служб ПК, журнал `precheck-service-account.log` после init `-DevTest`), закрытые права папок (`Set-PgPrivateAcl`/`Test-PgPrivateAcl` на настоящих папках: наследование
отключено, у вложенных файлов нет Authenticated Users/Users/Everyone), отказ без прав администратора без изменений
на диске, init `-DevTest` (папки данных и журналов закрыты, права для `archive_command` выданы NetworkService на
корень, releases, `backup.json`, спул), параметры сервера и `pg_hba`, роли и права (дважды), проверка
архивирования в `apply-roles.ps1`, отрицательная стоп-проверка на базе libc `C`, `node dist\migrate.js` под
`pos_migrate` (дважды), проверка прав после миграций, стандартная `archive_command` с настоящим `pos-backup.mjs`
через junction `current` (пути с пробелами), `-ConfigOnly`, остановка, `-Resume` на существующем кластере.
Не проверяется здесь (нет прав администратора): регистрация службы, перезапуск ограниченным маркером `initdb` под
администратором, `/setowner`, `sc.exe failure`/`failureflag`, работа под NetworkService/виртуальной учётной
записью, реальный `pg_dump`/`pg_basebackup` (во встроенной сборке их нет — чтение всех таблиц под `pos_backup` и
подключение репликации проверяются эквивалентными запросами).
