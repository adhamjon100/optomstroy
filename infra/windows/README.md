# Optomstroy POS — установка на Windows Server 2022 (без Docker, WSL и Hyper-V)

Точка входа для администратора сервера. Комплект ставит сервер «Оптомстрой POS» прямо в Windows Server 2022,
рядом с уже работающими 1С, Microsoft SQL Server и Apache. Hyper-V, Docker Desktop, WSL и Ubuntu не нужны и не
включаются. Порты 80 и 443 остаются у Apache и публикации 1С; конфигурация 1С и SQL Server не меняется.

Обмен с 1С — **онлайн, через 1С** (`ONEC_MODE=extension`): HTTP-сервис расширения «OptomstroyPOS» в публикации 1С
(контракт 1.2.0, `docs/specification/18_ONEC_API_REQUEST.md`). Своей учётной системы у POS нет.

Обозначения: **[Администратор]** — администратор заказчика, PowerShell «от имени администратора»;
**[posdeploy]** — наш сотрудник под учётной записью `posdeploy` (не администратор).

## 1. Что устанавливается

| Служба Windows | Что делает | Как запускается | Учётная запись | Порт |
|---|---|---|---|---|
| `OptomstroyPostgres` | PostgreSQL 17.10: данные POS, очередь фоновых задач (pg-boss) | служба `pg_ctl register`, автозапуск | `NT AUTHORITY\NetworkService` | `127.0.0.1:5433` |
| `OptomstroyApi` | HTTP API для касс, планшетов и приложений (`node dist\main.js`) | `OptomstroySvc.exe`, отложенный автозапуск, перезапуск при сбое, зависит от `OptomstroyPostgres` | `NT SERVICE\OptomstroyApi` (виртуальная, без пароля) | `127.0.0.1:3000` |
| `OptomstroyWorker` | Фоновые задачи: обмен с 1С, очередь отправки в 1С, SMS, фото, отметки журнала аудита (`node dist\worker.js`) | так же | `NT SERVICE\OptomstroyWorker` | нет |
| `OptomstroyBackup` | Резервное копирование: ежедневный зашифрованный дамп, архив WAL (PITR), копия фото | так же | `NT SERVICE\OptomstroyBackup` | нет |
| `migrate` (не служба) | Миграции базы: `node dist\migrate.js --seed`, роль `pos_migrate` | запускают install / update / rollback | администратор | нет |

`OptomstroySvc.exe` — наш хост служб (C#, .NET Framework 4.x, собирается встроенным `csc.exe` из исходника
`svchost\OptomstroySvc.cs`; сторонних программ нет). Остановка службы = закрытие stdin процесса node
(`POS_SHUTDOWN_ON_STDIN_EOF=1`, штатное завершение), через `stopTimeoutSeconds` — завершение дерева процессов.
Подробно — `svchost\README.md`.

Своего веб-сервера нет: обратным прокси работает ваш Apache (раздел 4).

## 2. Требования (только наша часть, сверх 1С и SQL Server)

| Компонент | RAM | vCPU | Лимит в комплекте |
|---|---|---|---|
| PostgreSQL 17 | 1,5–2,5 ГБ (`shared_buffers` 1 ГБ по умолчанию, `-SharedBuffers`) | 1–2 | — |
| API (Node.js 24) | 0,5–1 ГБ | 1–1,5 | задание Windows: 1024 МБ, 1,5 ядра |
| Фоновые задачи | 0,5–1 ГБ (пики при обработке фото) | 1 | 1024 МБ, 1 ядро |
| Резервное копирование | до 0,5 ГБ | 0,5 | 512 МБ, 0,5 ядра |
| Тестовый контур (если работает одновременно; на одном сервере пока не ставится — раздел 7) | +1,5–2 ГБ | доля | — |

Итог (16 §5.3, D-34): **минимум 2 vCPU и 4 ГБ RAM** (только рабочий контур), **рекомендуется 4 vCPU и 8 ГБ RAM**
(рабочий и тестовый контуры). SQL Server с неограниченным `max server memory` может занять всю память —
install.ps1 только читает это значение и предупреждает; менять его — решение вашего администратора.

| Диск | Том данных (`D:\Optomstroy`) | Том копий (`D:\OptomstroyBackups`, лучше отдельный) |
|---|---|---|
| PostgreSQL: данные + запас (в том числе место для восстановления) | 20 ГБ | — |
| Фото товаров | 30 ГБ минимум / 100 ГБ рекомендуется | — |
| Журналы | 2–5 ГБ | — |
| Версии программы (2–3 хранимых релиза; пакет ≈ 80 МБ zip) | ≈ 1–2 ГБ | — |
| Дампы (30 дней + ежемесячные) | — | 2–6 ГБ |
| Копия фото | — | 30 / 100 ГБ |
| Архив WAL и базовые копии (PITR) | — | 10–45 ГБ |

Том не должен быть занят больше чем на 70 %. Наши данные не кладутся на том с базами SQL Server и 1С: install.ps1
требует, чтобы копии были на другом томе (иначе `-AllowSameVolume` после согласования). Перед обновлением
update.ps1 делает копию базы внутри PostgreSQL — нужен запас ≈ 1,2 × размер базы + 1 ГБ на томе данных.

Программы: Windows Server 2022, Windows PowerShell 5.1 (`powershell.exe`; PowerShell 7 не используется),
.NET Framework 4.8 (есть в Windows Server 2022), PostgreSQL 17.10 для Windows x64 (официальные двоичные файлы:
папка `bin` с `postgres.exe`, `pg_ctl.exe`, `pg_dump.exe`, `pg_basebackup.exe`, `psql.exe`, `pg_restore.exe`).
Node.js отдельно не ставится: `node.exe` — внутри пакета (версия и SHA256 — в `release.json`).

## 3. Порты

| Порт | Кто | Адрес | Доступ |
|---|---|---|---|
| 443, 80 | Apache (ваш) | как сейчас | не меняются; добавляется только виртуальный хост по имени |
| 3000/TCP | `OptomstroyApi` | только `127.0.0.1` (`API_HOST=127.0.0.1`) | только Apache на этом сервере; плюс правило брандмауэра «блокировать входящие» |
| 5433/TCP | `OptomstroyPostgres` | только `127.0.0.1` | только локальные процессы; плюс правило «блокировать входящие» |

install.ps1 проверяет, что порты свободны до установки и что после запуска слушается только `127.0.0.1`.
Правила брандмауэра: `Optomstroy-Block-In-TCP-3000`, `Optomstroy-Block-In-TCP-5433` (любой удалённый адрес).
Брандмауэр не фильтрует петлевой интерфейс, поэтому Apache подключается к `127.0.0.1:3000`.

## 4. Схема через ваш Apache

```
Кассы / планшеты / приложения
        │  HTTPS 443, имя api.<домен> (тест: api-test.<домен>)
        ▼
Apache (ваш; Listen 80/443 без изменений)
  ├─ виртуальные хосты 1С — без изменений (должны стоять РАНЬШЕ и быть хостом по умолчанию для *:443)
  └─ новый <VirtualHost *:443> api.<домен> (SNI, свой сертификат)
        ├─ /api/*, /health        → http://127.0.0.1:3000
        ├─ /images/<sha256>/...   → файлы D:\Optomstroy\data\media\images
        └─ остальное              → 404
OptomstroyApi / OptomstroyWorker ── HTTPS ──► публикация 1С (ONEC_BASE_URL)
OptomstroyApi / OptomstroyWorker / OptomstroyBackup ──► OptomstroyPostgres 127.0.0.1:5433
```

install.ps1 только готовит файл хоста `config\apache\optomstroy-pos.conf` (`render-apache-conf.ps1`).
Подключение — отдельный шаг администратора в согласованное окно: `apache\enable-apache-site.ps1` (сначала без
`-Apply` — только проверка, затем с `-Apply`), он проверяет вывод `httpd -S`, сертификат и пробный запуск и
делает копию `httpd.conf`. Откат — `apache\disable-apache-site.ps1`. Подробно — `apache\README.md`.
Нужна DNS-запись A `api.<домен>` на IP сервера и сертификат для этого имени (ACME здесь нет).

## 5. Раскладка на сервере

```
D:\Optomstroy\                    (-InstallRoot; наследование прав от диска отключено)
  releases\<версия>\              node\node.exe, api\(dist, node_modules, migrations, seeds, assets, package.json),
                                  svchost\OptomstroySvc.exe, backup\, postgres\, apache\, scripts\, release.json, SHA256SUMS.txt
  current                         ссылка (junction) на активную версию
  config\                         api.env, worker.env, migrate.env, *.svc.json, backup.json, backup-public.pem,
                                  install.json, apache\optomstroy-pos.conf — без значений секретов (*_FILE)
  secrets\                        по файлу на секрет (pg_password, database_url, jwt_private.pem, pin_pepper, …)
  data\pg, data\media, data\audit-anchors, data\walspool
  logs\api, logs\worker, logs\backup, logs\pg, install-*.log, update-*.log, deploy-state.json
  state\                          install-state.json (текущая и прежняя версии), releases.log
  incoming\                       сюда posdeploy загружает пакеты
D:\OptomstroyBackups\             (-BackupRoot): dumps\ (и dumps\secrets\ — защищённая копия secrets), pitr\, media\ …
(в обеих корневых папках — отметка .optomstroy-root, раздел 7)
```

## 6. Секреты

Создаёт install.ps1 (тот же набор, что `infra/scripts/install.sh` Linux-комплекта; значения не выводятся и не
пишутся в журнал): `pg_password`, `db_migrator_password`, `db_backup_password`, `database_url`, `otp_pepper`,
`pin_pepper`, `jwt_private.pem` (ES256) и `jwt_public.json`, `pgpass_backup.conf`.

Вводит человек заказчика при установке (ввод скрыт) или кладёт файлом в `secrets\` до запуска с `-NonInteractive`:

| Файл | Что | Когда |
|---|---|---|
| `smspro_login`, `smspro_password` | SMSPro | рабочий контур; на тестовом стенде (`-Stand`) — только когда заказчик сам решит включить настоящие SMS (Q-385), раздел 7.1 |
| `onec_hs_user`, `onec_hs_token` | пользователь `pos_hs` HTTP-сервиса 1С и ключ `X-POS-Client-Key` | всегда (без них API не запускается) |
| `onec_hs_password` | пароль `pos_hs` | если задан в 1С |
| `onec_user`, `onec_password` | OData 1С только чтение (`pos_integration`) — полная загрузка, срезы цен и остатков | кладутся файлом, если используются |
| `onec_ca.pem` | корневой сертификат веб-сервера 1С (если сертификат не публичный) | кладётся файлом |
| `healthchecks_url` | ping-URL внешнего мониторинга | кладётся файлом, если есть |

Закрытый ключ резервных копий на сервере **не хранится**: держатель ключа создаёт пару на своём ПК
(`backup\keygen.ps1`) и передаёт администратору только `backup-public.pem`.

**Защищённая копия `secrets\`** (16 §8.2, RUNBOOK §2 шаг 6). Без `pin_pepper` и `otp_pepper` после потери сервера PIN
сотрудников и аварийные коды планшетов из восстановленной базы не проверяются; `restore.ps1` нужны `database_url` и
пароли ролей. Поэтому install.ps1 (шаг 6, при каждом запуске, если состав `secrets\` изменился) шифрует все файлы
`secrets\` открытым ключом копий (OPTBK1) в `<BackupRoot>\dumps\secrets\secrets-<время>.json.optbk`; служба копий
уносит её вне сервера вместе с дампами. После ручной замены файла в `secrets\` (например, нового пароля SMSPro)
запустите install.ps1 снова — появится новая копия.

1. **[Держатель ключа]** Один раз после установки (и после каждой новой копии) проверить расшифровку и хранить
   расшифрованный файл офлайн (съёмный носитель в сейфе), как и закрытый ключ:
   `node pos-backup.mjs decrypt --key backup-private.pem secrets-<время>.json.optbk secrets.json`.
2. **Восстановление на новом сервере [Администратор]**: до install.ps1 создать `D:\Optomstroy\secrets`, получить от
   держателя ключа `secrets.json` и выполнить (из распакованного пакета):
   `node\node.exe scripts\ops-tool.mjs secrets-import --in <secrets.json> --dir D:\Optomstroy\secrets`, затем удалить
   `secrets.json`. Если в `-BackupRoot` уже есть копии базы, install.ps1 **не создаёт** новые `pin_pepper`/`otp_pepper`
   (стоп с подсказкой); `-AllowNewPeppers` — только осознанно (PIN и аварийные коды из копий перестанут проверяться).

## 7. Установка

Пакет `Optomstroy-Server-<версия>-win-x64.zip` и его SHA256 (из `SHA256SUMS.txt`) передаются разными каналами.
SHA256 задаётся `-Sha256 <значение>` (или `-Sha256Sums <файл из папки администратора>`); файл `SHA256SUMS.txt` внутри
папки установки (в том числе в `incoming\`, куда пишет posdeploy) скрипты **не принимают**: подложивший пакет
подложил бы и «совпадающий» SHA256SUMS.

`-InstallRoot` и `-BackupRoot` — только отдельные папки: новые, пустые или уже созданные install.ps1 (отметка
`.optomstroy-root`). Корень тома (`E:\`) и существующая папка с чужими файлами (например, общая папка копий SQL Server
или 1С) — стоп на шаге 1: шаг 2 снимает с папки и всего содержимого прежние права NTFS. `-AllowForeignRoot` — только
осознанно (корень тома не допускается и с ним).

1. **[Администратор]** Установить PostgreSQL 17.10 x64 (официальный zip двоичных файлов, например в
   `C:\Program Files\PostgreSQL\17`). Кластер и службу создаёт install.ps1 — свой кластер официальным установщиком
   не создавать (или не запускать его службу на 5432/5433).
2. **[Администратор]** Создать учётную запись `posdeploy` (обычный пользователь, не администратор), если её нет.
3. **[Держатель ключа]** `backup\keygen.ps1 -OutDir <съёмный носитель>` на своём ПК; `backup-public.pem` — администратору.
4. **[Администратор]** Распаковать zip в папку вне `D:\Optomstroy` (например `C:\Users\admin\setup\pkg`) и запустить:

```powershell
cd C:\Users\admin\setup\pkg\scripts
.\install.ps1 -Zip C:\Users\admin\setup\Optomstroy-Server-<версия>-win-x64.zip -Sha256 <SHA256 из письма> `
    -PgBin 'C:\Program Files\PostgreSQL\17\bin' -PublicBaseUrl https://api.<домен> `
    -OnecBaseUrl https://<публикация 1С>/<база> -OnecHsPath hs/<имя сервиса> `
    -BackupPublicKey C:\Users\admin\setup\backup-public.pem `
    -ApacheDir C:\Apache24 -ApacheServiceName <имя службы Apache> -ApacheServiceAccount <учётная запись службы Apache> `
    -AdminPhone +996XXXXXXXXX -AdminName "Фамилия Имя"
```

Параметры по умолчанию: `-InstallRoot D:\Optomstroy`, `-BackupRoot D:\OptomstroyBackups`, `-ApiPort 3000`,
`-PgPort 5433`, `-Contour prod`. Тестовый контур — `-Contour test` (`APP_ENV=staging`), адрес
`https://api-test.<домен>` и **только тестовая копия базы 1С** в `-OnecBaseUrl`. В тестовом контуре SMS не
отправляются (`SMS_PROVIDER=fake`): войти могут только номера из `-TestPhones +996…,+996…` (с кодом
`AUTH_OTP_TEST_CODE` из `config\api.env`) — номер первого администратора тоже включите в `-TestPhones`. Запрос кода на
номер не из списка завершается ошибкой SMS и на `SMSPRO_CB_OPEN_MINUTES` (в тестовом контуре 1 мин) закрывает выдачу
кодов всем, в том числе тестовым номерам (503 `SMS_PROVIDER_ERROR`).

Повторный запуск install.ps1 с изменёнными параметрами (например, новый `-TestPhones`) применяет их сам:
работающие службы, у которых изменились релиз, файлы настроек или секреты, штатно перезапускаются
(`state\service-config.json`); остальные не трогаются.

Файл хоста Apache формируется с `*:443` и сертификатом `<ApacheDir>\conf\ssl\api.<домен>.fullchain.crt` / `.key`.
Другие значения — параметрами `-CertFile <полный путь .crt>`, `-KeyFile <полный путь .key>`,
`-ApacheListenPort <порт HTTPS Apache>`; они запоминаются в `config\install.json` и действуют при повторных
запусках. Существующий `config\apache\optomstroy-pos.conf`, который отличается от нового (например, сформированный
вручную `apache\render-apache-conf.ps1`), без этих параметров не перезаписывается — новый вариант кладётся рядом
(`optomstroy-pos.conf.new`), в журнале — предупреждение. После замены файла подключите его заново
(`enable-apache-site.ps1`). Ограничение: имена служб
(`OptomstroyPostgres`, `OptomstroyApi`, …) в скриптах фиксированы, поэтому рабочий и тестовый контуры **на одном
сервере** этими скриптами одновременно не ставятся — тестовый контур ставится на тестовый адрес (отдельный сервер).

Шаги install.ps1 (каждый повторяемый: после исправления причины запускается снова с теми же параметрами):

| № | Шаг | Нужны права администратора |
|---|---|---|
| 1 | Проверки (только чтение): Windows Server 2022, PowerShell 5.1, права, свободное место, порты 3000/5433, PostgreSQL 17, `httpd -S`, `max server memory` SQL Server, адрес 1С | — |
| 2 | Папки и отметка `.optomstroy-root`; NTFS: наследование отключено, полный доступ только Administrators и SYSTEM; posdeploy — чтение корня и `releases`, запись в `incoming`, чтение `logs` | да |
| 3 | Брандмауэр: блокировка входящих на 3000 и 5433 | да |
| 4 | Пакет: копия zip сверяется с SHA256, распаковка в `releases\<версия>`, сверка `SHA256SUMS.txt`, ссылка `current` | — |
| 5 | Секреты (раздел 6); при копиях базы в `-BackupRoot` новые перцы не создаются | — |
| 6 | Файлы настроек `config\*` (`API_HOST=127.0.0.1`, `POS_SHUTDOWN_ON_STDIN_EOF=1`, `ONEC_MODE=extension`, секреты путями `*_FILE`); существующие файлы не переписываются, дописываются только новые имена. Защищённая копия `secrets\` в `<BackupRoot>\dumps\secrets` (раздел 6) | — |
| 7 | PostgreSQL: `postgres\init-postgres.ps1` — кластер (`C.UTF-8`, `scram-sha-256`, `127.0.0.1:5433`, архивирование WAL), служба `OptomstroyPostgres` | да |
| 8 | Роли и база, стоп-проверка локали `lower('ЁЯ')`, проверка архивирования WAL (`postgres\apply-roles.ps1`) | — |
| 9 | Миграции `migrate --seed` | — |
| 10 | Службы: `sc.exe create` (`NT SERVICE\<служба>`, `delayed-auto`, `depend= OptomstroyPostgres`, перезапуск 10 с / 10 с / 60 с), права NTFS по файлам секретов (`data\audit-anchors` — запись только у `OptomstroyWorker`), `backup\set-backup-acl.ps1`, права posdeploy на `OptomstroyApi` и `OptomstroyWorker` (`sc sdset`, прежние SDDL — `state\*.sddl.backup`) | да |
| 11 | Запуск, проверка `/health` и `/health/ready` на `127.0.0.1`, фоновых задач и службы копий | — |
| 12 | Файл хоста Apache `config\apache\optomstroy-pos.conf` (не подключается) | — |
| 13 | Приглашение первому администратору (`-AdminPhone`, `-AdminName`; позже — `scripts\first-admin.ps1`) | — |

Журнал без секретов — `logs\install-<время>.log`, в конце — итог по шагам и время.
`-WhatIf` — только проверки шага 1. Права для учётной записи службы Apache (чтение `data\media`) install.ps1
выдаёт при `-ApacheServiceAccount`, иначе — командой `icacls D:\Optomstroy\data\media /grant "<учётная запись>:(OI)(CI)RX"`
(и `RX` без наследования на `D:\Optomstroy` и `D:\Optomstroy\data`).

5. **[Администратор, согласованное окно]** Подключить хост в Apache (раздел 4), перезапустить Apache, проверить 1С.
6. **[Администратор]** Один раз проверить службы под SCM: `svchost\rehearse-service.ps1` и проверки
   `svchost\README.md` и `postgres\README.md` (перезапуск после сбоя, остановка при выключении Windows).

### 7.1. Тестовый стенд `optomstroy-test` (`-Stand`; ADR-125)

Стенд — тот же комплект на сервере заказчика, только с вымышленными данными. `-Stand` включает контур `test`
(`APP_ENV=staging`) и профиль `scripts\templates\stand.env.example` (в репозитории — `infra/env/stand.env.example`;
настройки собираются слоями `prod.env.example` → `test.env.example` → `stand.env.example`, затем параметры
install.ps1). Секретов в профиле нет.

| Что | Значение на стенде | Почему |
|---|---|---|
| Адрес | `https://api-test.37.114.51.144.sslip.io` (по умолчанию из профиля; другое — `-PublicBaseUrl`) | временное имя до домена заказчика; постоянное — `api-test.optomstroy.kg` `[ПРЕДЛОЖЕНИЕ]`; сертификат для имени — у Apache заказчика (Q-384), без него приложения видят ошибку имени |
| 1С | `ONEC_MODE=fixtures` — ответы 1С из фикстур (`<релиз>\contracts\onec\fixtures`, кладёт build-release.ps1); `-OnecBaseUrl`, `-OnecHsPath` и секреты `onec_hs_*` не задаются и не спрашиваются | API 1С ещё нет; рабочая 1С к стенду не подключается никогда |
| QR | `QR_PROVIDER=bank`, `BANK_QR_ADAPTER=sandbox`, `QR_WEBHOOK_ENABLED=false` — песочница банка внутри `OptomstroyApi`, статус — опросом | ADR-123; банк — `[НЕ ПОДТВЕРЖДЕНО: Q-381]` |
| SMS | `SMS_PROVIDER=fake`, `SMSPRO_TEST_FLAG=true`, учётных данных SMSPro нет — **SMS не отправляются, денег не тратят** | ADR-124 |
| Вход | `AUTH_OTP_TEST_MODE=true`, номера `+996700000001…+996700000005` (вымышленные; `-TestPhones` заменяет список), код — `AUTH_OTP_TEST_CODE` в `config\api.env` (шесть случайных цифр, создаёт install.ps1; код демо `246810` API при `staging` не принимает) | 09 §5.8; первый администратор — номер из списка (`-AdminPhone +996700000001`) |
| Секрет OTP | `OTP_HMAC_SECRET_FILE=<InstallRoot>\secrets\otp_pepper` — и в `api.env`, и в `worker.env` (один файл) | EQ-AUTH-08: worker расшифровывает задание `sms.send` |

```powershell
cd C:\Users\admin\setup\pkg\scripts
.\install.ps1 -Stand -Zip C:\Users\admin\setup\Optomstroy-Server-<версия>-win-x64.zip -Sha256 <SHA256 из письма> `
    -PgBin 'C:\Program Files\PostgreSQL\17\bin' -BackupPublicKey C:\Users\admin\setup\backup-public.pem `
    -ApacheDir C:\Apache24 -ApacheServiceName <имя службы Apache> -ApacheServiceAccount <учётная запись службы Apache> `
    -AdminPhone +996700000001 -AdminName "Тестовый Администратор"
```

Профиль стенда после установки не меняется параметрами (`-Stand` записан в `config\install.json`; смена — только
вручную). update.ps1 дописывает новые имена и из `stand.env.example`. Рабочий контур этим не разрешается (ADR-125
п. 8: нужны Q-379 и Q-371). Любая команда, меняющая сервер, — только после явного «да» пользователя (16 §6.3);
мы проверяем стенд под `posdeploy` (`status.ps1`, журналы, `/health`).

**Настоящая SMS на стенде** (ADR-124 п. 5) — только (1) после того, как заказчик **сам** положит
`secrets\smspro_login` и `secrets\smspro_password` (в репозиторий, чат и журналы — ничего; Q-385), и (2) после
письменного «да» пользователя на конкретную отправку (число SMS и номер; Q-235). Порядок: повторный запуск
install.ps1 с теми же параметрами (дописывает `SMSPRO_LOGIN_FILE`/`SMSPRO_PASSWORD_FILE` и права служб на файлы), затем
в `config\api.env` и `config\worker.env` вручную: `SMS_PROVIDER=smspro`, `AUTH_OTP_TEST_MODE=false`, `AUTH_OTP_TEST_CODE=`
и `AUTH_OTP_TEST_PHONES=` (пусто — иначе API не стартует: при `smspro` тестового кода нет), `SMSPRO_SENDER=<имя>`;
сначала `SMSPRO_TEST_FLAG=true` (проверка канала без SMS, `docs/integration/smspro_connect.md` §4), потом
`SMSPRO_TEST_FLAG=false` и `SMS_STAGING_ALLOWED_PHONES=<разрешённые номера>` — остальным уходит `<test>1</test>` (§5);
перезапуск `OptomstroyApi` и `OptomstroyWorker`.

## 8. Резервное копирование

Порядок и сроки — как в Linux-комплекте (16 §8): ежедневный `pg_dump -Fc` в 05:30 по Бишкеку (30 дней + первый дамп
месяца ещё 93 дня), `pg_dumpall --globals-only` по воскресеньям, базовая копия и архив WAL для восстановления на
момент времени, копия фото и отметок журнала аудита. Дампы базы, базовые копии и архив WAL шифруются на сервере
открытым ключом (RSA-OAEP-4096 + AES-256-GCM, формат OPTBK1, только встроенный Node.js; сторонних программ нет) —
расшифровать может только держатель закрытого ключа. **Копия фото и отметок аудита (`<BackupRoot>\media\…`) не
шифруется** — это обычная копия файлов (как в Linux-комплекте); защищают её права NTFS папки копий
(`backup\README.md`). Копия вне сервера в `backup.json` пока не настроена (`offsite: null`) — вариант выбирает заказчик
(`backup\README.md`, BK-09). Перед каждым обновлением update.ps1 делает отдельный дамп (`pos-backup.mjs dump-only`).
Восстановление — `backup\restore.ps1`, на момент времени — `backup\restore-pitr.ps1`; ежемесячная проверка
восстановления — у держателя ключа. Подробно — `backup\README.md`.

## 9. Обновление

**[posdeploy]** загружает пакет в `D:\Optomstroy\incoming\`. **[Администратор]**:

```powershell
D:\Optomstroy\current\scripts\update.ps1 -Zip D:\Optomstroy\incoming\Optomstroy-Server-<версия>-win-x64.zip -Sha256 <SHA256 из письма>
```

`-Sha256` обязателен для пакета из `incoming\`: `SHA256SUMS.txt` из папки установки не принимается (раздел 7).

1. Пакет копируется в `releases`, сверяются SHA256 zip и всех файлов, `config\*.svc.json` проверяются
   `OptomstroySvc.exe --check-config` новой версии; службы в это время работают.
2. План: журнал миграций базы сравнивается с новой версией (если в базе есть миграции, неизвестные новой версии, — стоп).
3. Остановка `OptomstroyApi` и `OptomstroyWorker`. `OptomstroyBackup` **продолжает работать**: архив WAL не
   прерывается; дамп и ежедневный прогон не пересекаются благодаря замкам `state\*.lock`.
4. Зашифрованный дамп перед обновлением; нет дампа — обновление прекращается, прежняя версия запускается.
5. Если меняется схема базы — копия базы внутри PostgreSQL (`CREATE DATABASE <база>_preupd_<время> TEMPLATE <база>`):
   миграции только вперёд, а закрытого ключа для расшифровки дампа на сервере нет. `-NoDbSnapshot` — без неё.
6. В `config\api.env` и `worker.env` дописываются только **новые** имена несекретных настроек из шаблонов новой версии
   (как `env_merge_template` Linux-комплекта; прежние файлы — `state\update-env-<время>`, при откате возвращаются).
   Новые секреты так не добавляются: если в примечаниях к выпуску есть новый файл секрета, администратор до
   update.ps1 кладёт его в `secrets\`, дописывает строку `ИМЯ_FILE=D:\Optomstroy\secrets\<файл>` в нужный `.env` и
   выдаёт службе чтение файла (`icacls <файл> /grant "NT SERVICE\OptomstroyApi:(R)"`).
7. `current` → новая версия, `migrate --seed`, перезапуск `OptomstroyBackup`, запуск API и фоновых задач, проверки.

Сбой на шагах 4–7 — автоматический откат: `current` и `.env` возвращаются, база — из копии шага 5, если migrate новой
версии запускался (даже без новой строки журнала миграций: `--seed` и миграции без транзакции тоже меняют базу;
изменённая сохраняется как `<база>_failed_<время>`), прежняя версия запускается и проверяется. Копия, которая не
понадобилась, удаляется. Если сбой случился уже после запуска новой версии, созданные ею заказы и записи обмена с 1С
есть только в `<база>_failed_<время>` — перед её удалением сверьте с 1С. Если база изменена, а копии нет, — службы не
запускаются, в журнале — команда восстановления из дампа шага 4 (нужен держатель ключа). Коды выхода: 0 — обновлено,
1 — не обновлено. `-KeepSnapshot` — оставить копию базы для ручного отката.

## 10. Откат

```powershell
D:\Optomstroy\current\scripts\rollback.ps1                # на версию до последнего обновления
D:\Optomstroy\current\scripts\rollback.ps1 -RestoreSnapshot   # вместе с базой (если update.ps1 -KeepSnapshot)
```

Если база новее прежней версии (миграции были), откат только программы отклоняется: варианты — `-RestoreSnapshot`,
восстановление из дампа перед обновлением (`backup\restore.ps1`) или `-CodeOnly` (только по решению разработчика).
`-DropSnapshot` — удалить сохранённую копию базы.

## 11. Удаление

Запускать из распакованного пакета (не из `D:\Optomstroy\current\scripts`):

```powershell
.\uninstall.ps1                                   # программа и службы удалены, данные и копии остаются
.\uninstall.ps1 -KeepData:$false                  # и данные (база, фото, секреты, настройки) — после ввода УДАЛИТЬ
```

Порядок: наш хост в Apache отключается (`disable-apache-site.ps1`, только если он был подключён; Apache не
перезапускается — это делает администратор в окно), службы `OptomstroyWorker/Api/Backup` останавливаются и
удаляются, PostgreSQL останавливается и служба снимается, правила брандмауэра удаляются, `current` и `releases`
удаляются — только если предыдущие шаги прошли без ошибок (иначе программа остаётся: исправьте и повторите). Папка
копий (`-BackupRoot`) не удаляется никогда. С сохранением данных с `InstallRoot` и `BackupRoot` снимаются права
`NT SERVICE\Optomstroy*` и posdeploy. Apache (кроме нашего хоста), 1С и SQL Server не затрагиваются. Журнал: при
сохранении данных — `<InstallRoot>\logs\uninstall-<время>.log`, при `-KeepData:$false` — `%TEMP%\optomstroy-uninstall`;
копия — `<BackupRoot>\logs`.

## 12. Что может posdeploy

| Действие | posdeploy | Администратор |
|---|---|---|
| Загрузить пакет в `incoming\` | да | да |
| Читать журналы `logs\`, `logs\deploy-state.json` | да | да |
| Состояние: `<InstallRoot>\current\scripts\status.ps1` (службы, версии, готовность, копии по журналу, диск; без WMI — работает и по SSH; папку установки находит сам) | да (чтение `releases\`) | да (плюс итог `pos-backup status`) |
| Запуск, остановка, опрос `OptomstroyApi` и `OptomstroyWorker` (`Start-Service`, `Stop-Service`, `sc.exe query`) | да (права `sc sdset` из шага 10) | да |
| Опрос `OptomstroyPostgres`, `OptomstroyBackup` (`CC LC RC` в `sc sdset`, для `status.ps1`) | да, только опрос | да |
| Запуск, остановка `OptomstroyPostgres`, `OptomstroyBackup` | нет | да |
| install / update / rollback / uninstall, секреты, `config\`, `data\`, `state\`, изменение `releases\`, Apache, брандмауэр, PostgreSQL | нет | да |

`status.ps1` ничего не меняет; код выхода 0 — всё в порядке, 1 — есть проблемы (список в конце), `-Json` — для
мониторинга.

## 13. Проверка комплекта без прав администратора (`-DevTest`)

На ПК разработчика: `release\build-release.ps1` собирает пакет (pos-api собирается в копии, `npm prune --omit=dev`
offline, проверка `@node-rs/argon2` и `sharp` под win32-x64, `OptomstroySvc.exe` из исходника, поиск секретов,
`SHA256SUMS.txt`, `release.json`). Затем:

```powershell
scripts\install.ps1 -DevTest -Zip .tmp\wn-release\Optomstroy-Server-<версия>-win-x64.zip -InstallRoot .tmp\wn-install\root `
    -BackupRoot .tmp\wn-install\backups -PgBin pos-api\node_modules\@embedded-postgres\windows-x64\native\bin -ApiPort 3330 -PgPort 55450
scripts\status.ps1 -InstallRoot .tmp\wn-install\root
scripts\uninstall.ps1 -DevTest -InstallRoot .tmp\wn-install\root -KeepData:$false -Force
```

В `-DevTest` пропускаются только шаги администратора (права NTFS, брандмауэр, `sc.exe`, права posdeploy) — в журнал
пишется, что пропущено; PostgreSQL запускается `pg_ctl`, службы — `OptomstroySvc.exe --console` в скрытых консолях,
адрес 1С — `https://127.0.0.1:9/devtest-1c` (никто не слушает: API работает, вызовы 1С получают отказ),
секреты 1С — тестовые. В сборке PostgreSQL из `@embedded-postgres` нет `pg_dump`, поэтому дампы в `-DevTest` не
создаются (на сервере это стоп).

## 14. Отличия от плана (WINDOWS_NATIVE_PLAN v0.2)

- Хост служб — свой `OptomstroySvc.exe` вместо WinSW; учётные записи — виртуальные `NT SERVICE\Optomstroy*` вместо
  локальных `svc-optomstroy-*` (паролей нет).
- Резервное копирование — служба `OptomstroyBackup` и свой формат OPTBK1 вместо `age` и Планировщика.
- `pin_pepper` выдаётся и фоновым задачам (в плане — только API): `dist\worker.js` без `PIN_PEPPER` при
  `APP_ENV=prod/staging` завершается (глобальный CryptoModule, ADR-115) — проверено. С 2026-11-24 так же и в
  `compose.prod.yml`/`compose.test.yml` (Linux-комплект).
- Адрес и секреты HTTP-сервиса 1С обязательны уже при установке: в режиме `extension` API без них не запускается.
- Роли и база создаются после распаковки пакета (`apply-roles.ps1` использует `node.exe` и модуль `pg` из релиза).
- Перед обновлением, кроме зашифрованного дампа, делается копия базы в PostgreSQL — для автоматического отката.
- Защищённая копия `secrets\` — не ручная (как `install.sh`: «копия secrets/ — у заказчика офлайн»), а файл OPTBK1 в
  `<BackupRoot>\dumps\secrets`, который уходит вне сервера вместе с дампами; расшифровка — у держателя ключа.
- posdeploy запускает и останавливает только `OptomstroyApi` и `OptomstroyWorker` (не PostgreSQL и не службу копий);
  `data\audit-anchors` пишет только `OptomstroyWorker`.
- Задание «метрики» не сделано: `scripts\status.ps1 -Json` и Healthchecks службы копий (`backup.json`).
- Тестовый контур: `SMSPRO_CB_OPEN_MINUTES=1` (в шаблоне Linux-комплекта — 5) — см. раздел 7: запрос кода на номер
  вне `AUTH_OTP_TEST_PHONES` при `SMS_PROVIDER=fake` в схеме staging закрывает выдачу кодов всем на это время.
