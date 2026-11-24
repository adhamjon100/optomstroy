# Рабочий контур «Оптомстрой POS» на сервере заказчика — эксплуатация (RUNBOOK)

**Назначение.** Как установить, обновить, сохранить и восстановить серверную часть «Оптомстрой POS» на собственном
сервере заказчика и что делать при типовых сбоях. Документ для администратора заказчика (1-я линия) и DevOps
исполнителя (2-я линия).

**Основание:** 16_DEPLOYMENT_PLAN (сценарий A §3.1, топология §4, безопасность §7, копии §8, мониторинг §9,
обновления §10, тестовое и рабочее окружения §11, первичное развёртывание §14, runbooks §15; сервер вне магазина —
сценарий C-1 §3.3, туннель к 1С §12.2 — здесь §11). Если этот документ расходится с 16, прав 16.
2026-11-20 заказчик отменил P-003 (работу без 1С и ночной обмен): 1С — главная система, сервер POS днём онлайн с 1С
(15 ADR-120). Заказы, оплаты и возвраты сразу уходят в 1С через очередь; товары, цены и остатки берутся из 1С.
Рабочий запуск магазина — только с подключённой 1С; до подключения контур работает с `ONEC_MODE=extension` и пустым
`ONEC_BASE_URL` (§8.1). Сервер — у заказчика, оплата и SMS работают на нём (ответ владельца 2026-11-18,
интерпретация).

**Комплект (в репозитории):**

| Файл | Что это |
|---|---|
| `infra/compose.prod.yml` | сервисы api, worker, migrate, postgres, backup (портов хоста не публикует) |
| `infra/compose.prod.onec.yml`, `compose.prod.onec-odata.yml`, `compose.prod.onec-ca.yml`, `compose.prod.healthchecks.yml` | дополнения: подключаются сами, когда на сервере есть их секреты (1С: HTTP-сервис — три файла, OData — пара, §8.4) |
| `infra/compose.staging.yml`, `infra/env/test.env.example` | тестовая копия на том же сервере (проект `optomstroy-test`, 16 §11; §10) |
| `infra/compose.edge.yml`, `compose.edge.test.yml`, `infra/caddy/Caddyfile.edge`, `caddy/sites/*.caddy` | общий caddy — проект `optomstroy-edge`, единственный владелец портов 80/443, сайты `api.<домен>` и `api-test.<домен>` |
| `infra/env/prod.env.example` | шаблон `.env` рабочего контура с безопасными значениями первого запуска |
| `infra/scripts/install.sh` | первичная установка (`--contour test` — тестовая копия; повторный запуск безопасен) |
| `infra/scripts/update.sh` | обновление и откат (`--rollback`, сверка журнала миграций, §3.4) |
| `infra/scripts/backup-restore-test.sh` | проверка восстановления копии во временную базу, в том числе на момент времени (§4.4) |
| `infra/scripts/restore-db.sh` | восстановление базы контура из копии, на момент времени (`--to-time`) или до конца архива WAL (`--to-latest`); кластер — `--sysid`, базовая копия — `--base` (§4.8) |
| `infra/scripts/backup-caddy.sh` | копия сертификатов общего caddy (таймер systemd, §4.1) |
| `infra/scripts/metrics_check.sh` | метрики сервера каждые 10 минут (таймер systemd, §6.4) |
| `infra/scripts/host-net-check.sh` | проверка сети и времени хоста: пояс, NTP, порты, ufw, AAAA-записи, туннель к 1С — только читает (§2.6, §11.5) |
| `infra/host/wireguard/wg0.conf.example`, `store-peer.conf.example` | шаблоны туннеля WireGuard к 1С для сервера вне магазина — сервер и магазин, без ключей (§11) |
| `infra/docker/postgres/scripts/wal-archive.sh` | `archive_command` PostgreSQL — непрерывная копия WAL (§4.8) |
| `infra/scripts/rotate-secret.sh` | ротация секретов и ввод учётных данных внешних систем |
| `infra/scripts/dc`, `dc-edge`, `lib.sh` | обёртки `docker compose` (контур; общий caddy) и общие функции |
| `infra/docker/scripts/check_compose_prod.py`, `test_lib.sh` | проверка комплекта без Docker и самопроверка функций скриптов (CI, перед выпуском) |

**Не делать никогда:** публиковать порт PostgreSQL; класть приватный ключ age на сервер; передавать пароли и коды
через чат; запускать скрипты с `bash -x` (трассировка покажет значения секретов); `docker compose down -v` и
`docker system prune -a --volumes` (удалят сертификаты и данные); править чужие службы, firewall и DNS без
согласования (16 §6.3).

---

## 0. Как устроено на сервере

| Путь | Владелец, права | Содержимое |
|---|---|---|
| `/opt/optomstroy/src/<версия>` | root | исходники релиза (git-копия тега или архив) — из них собираются образы |
| `/opt/optomstroy/prod/` | `optomstroy`, 750 | каталог проекта compose `optomstroy-prod` и общего caddy `optomstroy-edge` |
| `…/prod/compose.*.yml`, `caddy/Caddyfile.edge`, `caddy/sites/`, `docker/postgres/initdb/` | root, 644 | комплект (копирует install.sh/update.sh) |
| `…/prod/.env` | `optomstroy`, 600 | несекретная конфигурация (16 §4.3) |
| `…/prod/secrets/` | `optomstroy`, 700; файлы 640, группа `optomstroy-secrets` (GID 10100) | секреты (§7) |
| `…/prod/bin/` | root, 750 | скрипты комплекта и обёртка `dc` |
| `…/prod/state/` | `optomstroy`, 700 | журналы `releases.log`, `secrets.log`, `restore-tests.log`, снимок для отката |
| `…/prod/onec-journal/` | uid 10001 | журнал перерегистрации плана обмена 1С (§8.4) |
| `/srv/optomstroy/prod/pgdata` | uid 999, 700 | данные PostgreSQL |
| `/srv/optomstroy/prod/media` | uid 10001, 755 | фото товаров |
| `/srv/optomstroy/prod/backups` | uid 10002, 700; **отдельный диск** (§2.2) | зашифрованные копии `*.dump.age`, `monthly/` (первая копия месяца), `globals_*.sql.age`, `media/` (копия фото), `caddy_data/` (сертификаты), `pitr/` (базовые копии и архив WAL, §4.8), `.offsite_ok`, `.wal_offsite_ok` (§4) |
| `/srv/optomstroy/prod/walspool` | uid 999, группа 10002, 2770; диск базы | спул WAL: `archive_command` кладёт сегмент, сервис backup за ~20 с шифрует его в `backups/pitr` и удаляет (§4.8) |
| `/srv/optomstroy/prod/pgdata.pre-pitr-<UTC>` | uid 999, 700 | прежний каталог данных после восстановления на момент времени — удалить после проверки (§4.8) |
| Docker: том `optomstroy-edge_caddy_data` | root | сертификаты общего caddy — не удалять (лимиты Let's Encrypt) |
| `/opt/optomstroy/test/`, `/srv/optomstroy/test/` | так же | тестовая копия (§10), если установлена |

Почему секреты 640 (16 §4.2 версии 1.16; 15 ADR-033, уточнение 2026-11-19): без Swarm Docker монтирует файл секрета с правами хоста, а процессы
контейнеров работают под uid 10001 (api, worker, migrate), 10002 (backup) и 999 (postgres). Файлы читает только
группа `optomstroy-secrets`; людей в ней нет, сервисы получают её через `group_add` (infra/NOTES.md «Рабочий
контур»). Комплект рассчитан на Docker с root-демоном; при rootless Docker uid и GID внутри контейнеров
сдвигаются — владельцев каталогов нужно пересчитать (DevOps).

**Все команды** выполняются через обёртку: `sudo /opt/optomstroy/prod/bin/dc <команда docker compose>`. Ниже
`dc` — сокращение этой записи. Обёртка сама подключает дополнения 1С и Healthchecks, если их секреты есть, и
создаёт внешнюю сеть `optomstroy_prod_edge` перед `up`/`run`. Общий caddy (порты 80/443, оба сайта) — отдельный
проект `optomstroy-edge`: `sudo /opt/optomstroy/prod/bin/dc-edge <команда>` (ниже `dc-edge`). Тестовая копия —
те же команды из `/opt/optomstroy/test/bin/` (§10).

| Задача | Команда |
|---|---|
| состояние сервисов | `dc ps`; общий caddy — `dc-edge ps` |
| журнал сервиса | `dc logs --since 1h api` (также `worker`, `postgres`, `backup`, `migrate`); caddy — `dc-edge logs --since 1h caddy` |
| перезапуск после правки `.env` | `dc up -d api worker` |
| консоль БД (только чтение, по согласованию) | `dc exec postgres psql -U pos_readonly -d optomstroy_prod` |

Сервисы поднимаются сами после перезагрузки сервера (`restart: unless-stopped`).

---

## 1. Требования к серверу

| Что | Минимум | Рекомендовано | Источник |
|---|---|---|---|
| ОС | Ubuntu 22.04/24.04 или Debian 12/13, x86_64 или aarch64 | Ubuntu 24.04 LTS | 16 §5.5 |
| CPU / RAM / диск | 2 vCPU / 4 GB / 80 GB SSD | 4 vCPU / 8 GB / 160–250 GB SSD | 16 §5, D-34 |
| Docker | Docker Engine, плагин Docker Compose 2.x или новее (включая 5.x; не `docker-compose` v1) и `docker-buildx-plugin` (BuildKit; не нужен при `--load-images`) — пакеты `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` из официального репозитория Docker, ставит администратор | — | 16 §14.1 шаг 1 |
| Сеть | из интернета — TCP 443 и TCP 80 (80 — выпуск сертификата вызовом HTTP-01 и перенаправление на HTTPS; при одном 443 сертификат выпускается вызовом TLS-ALPN-01), оба — на общий caddy; SSH — по ключам, с ограничением по IP или VPN; исходящие HTTPS: Let's Encrypt, SMSPro, реестры образов (Docker Hub, npm, Alpine) на время установки и обновления, внешнее хранилище копий, 1С по LAN или, если сервер вне магазина (дата-центр), через туннель WireGuard, который начинает магазин: тогда из интернета ещё UDP-порт туннеля `<WG_PORT>`, SSH — через туннель, консоль провайдера — запасной вход (§11) | — | 16 §4.2, §7, §12.2 |
| DNS | A-записи `api.<домен>` и (для тестовой копии) `api-test.<домен>` → внешний IPv4 сервера; AAAA-записи не создавать, пока сети Docker без IPv6 (§11.3) | — | 16 §14.1 шаг 2, §11 (Q-032) |
| Диск копий | отдельный диск под `/srv/optomstroy/prod/backups` (§2.2); с непрерывной копией WAL — ещё базовые копии и архив WAL за `BACKUP_KEEP_DAYS` (оценка — §4.8) | 250–500 ГБ | SERVER_REQUIREMENTS §1 |
| Запас на диске базы | для восстановления на момент времени: свободно не меньше размера базы плюс распакованный WAL (§4.8) | ×2 от размера базы | 16 §8.5 |
| Тестовая копия на этом же сервере | от 6 ГБ памяти всего (иначе — другой хост) | 8 GB | 16 §11 |
| Время | NTP, часовой пояс Asia/Bishkek (сервер в дата-центре вне КР обычно приходит с UTC или поясом площадки — install.sh предупреждает, настройка — §11.2) | — | 16 §14.1 шаг 1, H-11 |

Память сервисов задаётся в `.env` (16 §4.4 прим. 2): пусто — значения для 8 GB (`shared_buffers` 1GB, лимиты
postgres 2G, api 1G, worker 1G). На сервере меньше 7,5 ГБ install.sh сам пишет профиль 4 GB: `PG_SHARED_BUFFERS=512MB`,
`PG_MEM_LIMIT=1536M`, `API_MEM_LIMIT=768M`, `WORKER_MEM_LIMIT=768M`; update.sh делает то же для пустых значений.
Значения переживают обновления (комплект их не трогает). Правка — в `.env`, затем `dc up -d postgres api worker`.

**Сервер с большим запасом памяти (например, 64 ГБ)** `[ОЦЕНКА]`: значения по умолчанию работают, для запуска ничего
менять не нужно. База (1–3 ГБ, на третий год 3–7 ГБ) помещается в память и так, но кэш страниц файлов базы считается в
лимит контейнера postgres. После нагрузочной проверки T-PERF-002 на этом сервере в `.env` рабочего контура можно поднять:
`PG_SHARED_BUFFERS=4GB`, `PG_MEM_LIMIT=8G`, `API_MEM_LIMIT=1536M`, `WORKER_MEM_LIMIT=2G` (лимиты всего ≈ 14 ГБ; тестовая
копия — без изменений), затем `dc up -d postgres api worker`. Это техническая настройка исполнителя, не решение заказчика.

---

## 2. Установка

### 2.1. Что подготовить до установки

| Что | Кто | Как |
|---|---|---|
| Письменное разрешение на работы на сервере | заказчик | 16, шапка; без него установка не начинается |
| Домен и e-mail для сертификата | заказчик | `api.<домен>`; e-mail получает уведомления Let's Encrypt |
| Пара ключей age для шифрования копий | держатель ключа (заказчик или DevOps) | на своей машине: `age-keygen -o optomstroy-backup.key` — печатает публичный ключ `age1…`. Файл ключа — на съёмный носитель и в сейф, вторая копия у второго держателя (Q-106). **На сервер не кладётся** |
| Логин и пароль SMSPro | человек заказчика | вводит сам на сервере до установки двумя командами со скрытым вводом из §2.4 (файлы `secrets/smspro_login` и `secrets/smspro_password`: при вводе — 600, затем install.sh ставит 640 и группу `optomstroy-secrets`, §0); оператор подсказывает команды, значения не получает и не запрашивает (09 §6.12, SMS-030, SRC-B-122) |
| Имя отправителя SMSPro | заказчик | обычный канал → `SMSPRO_SENDER` в `.env` |
| Телефон и ФИО первого администратора | заказчик | вводятся только в терминале сервера (docs/ops/first_admin.md) |
| Docker Engine, плагин Docker Compose 2.x или новее, `docker-buildx-plugin` | администратор сервера | проверка: `docker compose version` (2.x или 5.x), `docker buildx version` |
| Отдельный диск для копий | администратор сервера | §2.2 |
| Сервер вне магазина (дата-центр): UDP-порт туннеля `<WG_PORT>`, доступ к консоли провайдера (KVM/rescue) и к фильтру его панели, пояс Asia/Bishkek | заказчик (порт, панель провайдера), DevOps (настройка) | §11 |

### 2.2. Диск для копий

Копии лежат на отдельном диске: отказ диска базы не должен уносить и копии (SERVER_REQUIREMENTS §1). install.sh
рабочего контура не продолжит, если `/srv/optomstroy/prod/backups` на том же физическом диске, что и база: та же
файловая система, другой раздел или том LVM того же диска (обход — `--allow-same-disk`: только стенд или письменное
исключение владельца, ниже «Сервер с одним диском»). До установки, от root:

```sh
lsblk -f                                         # найти диск копий, например /dev/sdb1 (ext4); UUID — в выводе
install -d -m 755 -o root -g root /srv/optomstroy/prod/backups
echo 'UUID=<UUID диска копий> /srv/optomstroy/prod/backups ext4 defaults,nofail 0 2' >> /etc/fstab
mount /srv/optomstroy/prod/backups
chown 10002:10002 /srv/optomstroy/prod/backups && chmod 700 /srv/optomstroy/prod/backups   # корень СМОНТИРОВАННОГО диска
```

Точка монтирования до `mount` остаётся `root:root`: если диск однажды не смонтируется при загрузке (`nofail`), сервис
backup не сможет писать на системный диск, копия упадёт и сервис станет `unhealthy` — сигнал, а не тихая копия на тот
же диск.

**Сервер с одним диском.** Отдельный диск — это другой физический носитель. Второй раздел или том LVM того же диска
(и другой массив RAID на тех же дисках) от отказа диска не защищает: install.sh сравнивает физические диски под
файловыми системами (`findmnt`, `lsblk`) и в этом случае останавливается с ошибкой «разные разделы одного диска от
отказа диска не защищают» — так же, как при одной файловой системе (безопасное значение вопроса Q-374: рабочую систему
на один диск не ставим). Не смог определить диски — молчит. У виртуального сервера второй диск может лежать на том же
хранилище провайдера — это подтверждает только провайдер. `--allow-same-disk` (ошибка становится предупреждением) —
только для стенда или по письменному исключению владельца (вопрос Q-374; слова владельца — дословно в журнал §9 до
запуска): при отказе диска теряются и база, и все копии на сервере, остаётся только копия вне сервера (§4.3) — она
должна работать до появления настоящих данных (`.offsite_ok` и `.wal_offsite_ok` свежие, §6.2).

### 2.3. Исходники релиза

```sh
sudo mkdir -p /opt/optomstroy/src && cd /opt/optomstroy/src
sudo git clone <адрес репозитория> <версия> && cd <версия> && sudo git checkout <тег версии>
# или: архив релиза, распакованный в /opt/optomstroy/src/<версия>
```

### 2.4. Запуск

Сначала человек заказчика сам вводит логин и пароль SMSPro — две команды со скрытым вводом (оператор их подсказывает,
значения не видит и не получает; 09 §6.12, SRC-B-122):

```sh
sudo install -d -m 700 /opt/optomstroy/prod/secrets
sudo bash -c 'umask 077; read -rs -p "Логин SMSPro: " v; printf %s "$v" > /opt/optomstroy/prod/secrets/smspro_login; echo'
sudo bash -c 'umask 077; read -rs -p "Пароль SMSPro: " v; printf %s "$v" > /opt/optomstroy/prod/secrets/smspro_password; echo'
```

Затем установка (файлы SMSPro уже есть — скрипт их не спрашивает; права он выставит сам, §0):

```sh
cd /opt/optomstroy/src/<версия>
sudo bash infra/scripts/install.sh --domain api.<домен> --acme-email <e-mail> --age-recipient age1… \
     --admin-phone +996XXXXXXXXX --admin-name "Фамилия Имя Отчество"
```

Если установку в терминале запускает сам человек заказчика, файлы SMSPro можно не создавать заранее: install.sh
спросит их со скрытым вводом. Без терминала (`--non-interactive`) и без этих файлов скрипт остановится. Остальные
параметры — `sudo bash infra/scripts/install.sh --help`. Тег версии по умолчанию — `<версия pos-api>-<git sha>`; из
каталога с незакоммиченными изменениями без `--tag` скрипт не запустится. Сервер без доступа к npm и Docker Hub:
образы готовятся на другой машине — `docker save optomstroy/api:<тег> optomstroy/backup:<тег> caddy:<тег>
postgres:<тег> -o optomstroy-<тег>.tar` (теги caddy и postgres — из `infra/compose.edge.yml` и `compose.prod.yml`
релиза) — и передаются с `--load-images <каталог>`.

### 2.5. Что делает install.sh

| Шаг | Действие | Если ошибка |
|---|---|---|
| 1 | проверяет ОС, Docker и плагин Compose 2.x или новее, память, CPU, свободное место (≥ 20 ГБ под данные, ≥ 5 ГБ под образы), свободные порты 80/443, синхронизацию времени и часовой пояс сервера (другой пояс — предупреждение, §11.2) | исправить сервер и запустить снова |
| 2 | создаёт группу `optomstroy-secrets` (GID 10100) и системного пользователя `optomstroy` без входа | GID занят — согласовать другой и поменять в `compose.prod.yml` и `lib.sh` |
| 3 | создаёт каталоги §0 с владельцами и правами (в том числе спул WAL `walspool`, §4.8); проверяет, что копии на отдельном физическом диске (§2.2; та же файловая система, другой раздел или том LVM того же диска — ошибка, с `--allow-same-disk` — предупреждение) | смонтировать отдельный диск копий; `--allow-same-disk` — только стенд или письменное исключение владельца (Q-374, журнал §9) |
| 4 | копирует комплект, создаёт `.env` из `prod.env.example`, заполняет тег, домен, e-mail, `MIN_APP_VERSION` (из `pos-app/pubspec.yaml`), `JWT_KEY_ID`, ключ age, профиль памяти 4 GB при необходимости; проверяет запреты рабочего контура (`APP_ENV=prod`, без тестовых режимов, без «`ИМЯ=   # комментарий`») | сообщение называет переменную |
| 5 | генерирует openssl пароли БД (в том числе роли копий `pos_backup`), `database_url`, ключ подписи JWT, pepper OTP и PIN; берёт файлы SMSPro или спрашивает их (§2.4); создаёт пустой `rclone.conf` | — |
| 6 | собирает образы `optomstroy/api` (стадия `release`, без тестовых данных) и `optomstroy/backup` или загружает их; скачивает caddy и postgres, если их нет | нет сети — `--load-images` |
| 7–8 | создаёт сеть `optomstroy_prod_edge`, запускает postgres (initdb создаёт роли `pos_migrate`, `pos_app`, `pos_readonly`, `pos_backup` — с REPLICATION и строкой `pg_hba.conf` для базовой копии PITR; в созданном раньше кластере это делает `pg_sync_backup_role`), применяет миграции и строки по умолчанию | `dc logs migrate` |
| 9 | запускает все сервисы и общий caddy (`optomstroy-edge`), ждёт `healthy`, проверяет `/health/ready` | `dc logs api`, `dc-edge logs caddy` |
| 10 | делает первую зашифрованную копию (при `BACKUP_PITR=on` — и первую базовую копию PITR, §4.8) | §4 |
| 11 | ставит таймеры systemd `optomstroy-caddy-backup.timer` (копия сертификатов в 06:00 по Бишкеку при любом поясе сервера, §4.1; делает первую копию) и `optomstroy-metrics.timer` (метрики сервера каждые 10 минут, §6.4) | §4.1, §6.4 |
| 12 | создаёт приглашение первого администратора (вход — по SMS, затем PIN) | docs/ops/first_admin.md §6 |

Повторный запуск ничего не перезаписывает: существующие `.env`, секреты, база и образы сохраняются. Если база уже
создана, а файла пароля нет, скрипт остановится — пароль восстанавливается из защищённой копии, а не генерируется.

### 2.6. Проверка после установки

1. `dc ps` — `api`, `worker`, `postgres` в состоянии `healthy`, `backup` — `healthy` или `starting`; `dc-edge ps` —
   `caddy` в состоянии `running`.
2. С внешнего компьютера: `curl -sI https://api.<домен>/health` — `200`, сертификат действителен.
3. На сервере: `sudo ss -tulpn` — наружу слушают только 80, 443 и SSH (сервер вне магазина — ещё UDP-порт туннеля);
   `sudo iptables -S DOCKER-USER` — без неожиданных правил (Docker обходит ufw, 16 §4.2);
   `sudo /opt/optomstroy/prod/bin/host-net-check.sh` — пояс, NTP, порты, ufw, AAAA-записи и туннель без замечаний
   (только читает; коды и подсказки — `--help`, §11.5). Замечание `FIREWALL` на сервере в магазине допустимо, если хост
   защищён иначе (16 H-5), — записать в журнал (§9).
4. `ls -l /srv/optomstroy/prod/backups` — есть файл `*.dump.age`, каталоги `monthly/` и `media/`;
   `systemctl list-timers optomstroy-caddy-backup.timer` — таймер включён, следующий запуск — 06:00 по Бишкеку
   (`list-timers` показывает его в поясе сервера).
5. Администратор вошёл в приложение по SMS-коду и установил PIN.
6. Защищённая копия `secrets/` и `.env` записана на носитель заказчика (16 §8.2): потеря `secrets/` без копии
   означает потерю доступа к базе и сброс всех сессий.

**Смена домена.** В `.env` поменять `CADDY_SITE_ADDRESS` и `PUBLIC_BASE_URL`, затем `dc up -d --force-recreate api worker`
и `dc-edge up -d --force-recreate caddy`. Приложения на устройствах собраны с адресом сервера — их нужно
пересобрать и переустановить (§5).

---

## 3. Обновление

### 3.1. Перед обновлением

- Релиз проверен в тестовом контуре (16 §10.3 шаг 1): CI-контур и тестовая копия на сервере — сначала
  `update.sh --contour test` (§10.2), затем рабочий контур. В записи релиза указан тег.
- Согласовано окно: простой API 1–3 минуты, синхронизация на время обновления останавливается (16 §10.1).
- Новые переменные релиза описаны в записи релиза: update.sh добавит их в `.env` со значениями шаблона.

### 3.2. Запуск

```sh
cd /opt/optomstroy/src && sudo git clone <адрес репозитория> <новая версия> && cd <новая версия> && sudo git checkout <тег>
sudo bash infra/scripts/update.sh --tag <новая версия>
```

Порядок: сборка образов и скачивание caddy/postgres (контур работает; без сети и без образа обновление не
начинается) → роль `pos_backup` (вход, чтение, репликация для базовой копии) и владелец схемы `pgboss` (§3.6,
идемпотентно) → остановка worker → резервная копия (без неё обновление не идёт) и журнал миграций до обновления
(`state/last_update`: `PRE_UPDATE_DUMP`, `MIGRATIONS_BEFORE`) → снимок комплекта и `.env` для отката → новый комплект
и теги → миграции (`MIGRATE_STARTED_AT`, `MIGRATIONS_AFTER`) → пересоздание сервисов и общего caddy (если изменились
его файлы) → проверка готовности → первая базовая копия PITR, если её ещё нет (§4.8), таймер метрик (§6.4) → запись в
`state/releases.log`. Мажорная смена версии PostgreSQL скриптом не выполняется (Q-104).

Если шаг между остановкой worker и успешной миграцией падает (нет образа, ошибка конфигурации, обрыв), update.sh
сам возвращает комплект и `.env` из снимка, запускает прежний worker и пишет «aborted: <шаг>» в `state/releases.log`.
Повторный запуск после прерванного обновления, которое не дошло до записи «ok», не перезапишет снимок отката: сначала
`--rollback` или, если новая версия проверена, `--overwrite-snapshot`.

### 3.3. После обновления

Prod-smoke без изменения данных (16 §10.9): `GET /health`, `/health/ready`, вход технического сотрудника по SMS,
чтение каталога, `GET /sync/status`, баланс SMSPro; счётчики бизнес-таблиц до и после совпадают. Запись в журнале
эксплуатации: версия, дата, кто, результат.

### 3.4. Откат

| Ситуация | Действие |
|---|---|
| ошибка миграции или сбой до неё (запись «aborted»/«failed: migrate») | update.sh сам вернул `.env` и комплект, api старой версии не пересоздавался, worker запущен снова. Разобрать `dc logs migrate` или сообщение шага |
| сервисы не готовы после обновления или ошибка найдена позже; обновление **не применило миграций** | `sudo /opt/optomstroy/prod/bin/update.sh --rollback` — сверяет журнал миграций базы с `MIGRATIONS_BEFORE` в `state/last_update`, возвращает теги и комплект, пересоздаёт postgres, api, worker, backup; migrate прежней версии проходит (0 изменений) |
| обновление **применило миграции** | `--rollback` отказывает и печатает порядок: мигратор прежней версии их не знает (`MIGRATION_MISSING_FILE`), база осталась бы новее кода. Откат вместе с базой: (1) `update.sh --rollback --code-only` — образы и комплект прежней версии; (2) `restore-db.sh --identity … --dump <PRE_UPDATE_DUMP>` (копия перед обновлением, данные после неё теряются) или, при `BACKUP_PITR=on`, точнее — `restore-db.sh --identity … --to-time '<момент запуска миграций>'` (§4.8); restore-db.sh запустит migrate прежней версии, журнал совпадёт с файлами. Обе подсказки — с именами и временем — в сообщении отказа |
| миграции только expand, нужен быстрый откат кода без потери данных (16 §10.4 строка 1) | `update.sh --rollback --code-only` — база не откатывается, сервисы поднимаются без migrate (ниже «Важно») |
| разрушающая миграция | восстановление из копии, сделанной update.sh перед миграцией (§4.5), или на момент перед миграцией (§4.8) |

**Важно после `--code-only`.** Журнал миграций базы содержит версии нового релиза, и мигратор старой версии
отказывает в запуске (`MIGRATION_MISSING_FILE`). Поэтому, пока не установлен новый релиз или не восстановлена копия,
сервисы запускаются без `migrate`: `dc up -d --no-deps api worker backup`. Команда `dc up -d` без `--no-deps` в этом
состоянии не поднимет api. Обновления, сделанные update.sh до 2026-11-19, журнала миграций в `state/last_update` не
содержат — для них `--rollback` откатывает только с `--code-only`.

### 3.5. Обновление ОС и Docker

Автоматические обновления безопасности ОС (unattended-upgrades) настраивает администратор сервера по 16 §7; комплект их не настраивает. После обновления Docker или перезагрузки: `dc ps`,
`/health/ready`, первая синхронизация. Тег caddy и postgres меняется только релизом комплекта.

### 3.6. Схема очередей pg-boss: перенос владельца (базы, созданные до 2026-11-19)

С релиза 2026-11-19 схему `pgboss` (очереди задач, D-44) ставит и обновляет контейнер `migrate` под ролью
`pos_migrate`. api и worker работают под `pos_app` без права менять структуру базы (07 DATA-012; `docs/ci.md`
CI-KI-03 закрыт). Раньше схему создавали сами api и worker, поэтому в базах, поднятых до этой даты, её владелец —
`pos_app`, а у `pos_app` есть право CREATE на базу. migrate нового релиза в такой базе останавливается с ошибкой
`PGBOSS_FOREIGN_OWNER`; update.sh при этом сам возвращает комплект (§3.4).

**Кому нужно:** только базам, где api или worker прежних версий уже запускались. Новая установка (§2) переноса не
требует. restore-db.sh (§4.5) переносит владельца сам.

**Автоматически (с 2026-11-19, вечер).** update.sh нового релиза выполняет блок ниже сам — на шаге 3, до остановки
worker и до миграций (текст берётся из restore-db.sh того же релиза), и проверяет, что владелец схемы — `pos_migrate`.
Вручную блок нужен, только если обновление идёт прежним update.sh или migrate уже остановился с
`PGBOSS_FOREIGN_OWNER`. Для тестовой копии (§10) — то же, через её обёртку `/opt/optomstroy/test/bin/dc`.

**Когда (вручную):** один раз, перед update.sh на релиз с этим изменением. Сервисы останавливать не нужно: права
`pos_app` на объекты схемы выдаются в той же транзакции, прежние api и worker продолжают работать (их pg-boss схему
не меняет, пока версия схемы совпадает). Право CREATE на базу вручную снимать не нужно: его снимет migrate нового
релиза.

```sh
dc exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 --no-psqlrc -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
DO $$
DECLARE r record;
BEGIN
  IF to_regnamespace('pgboss') IS NULL THEN RETURN; END IF;
  ALTER SCHEMA pgboss OWNER TO pos_migrate;
  -- таблицы и представления; индексы, TOAST и последовательности столбцов переходят вместе с таблицей
  FOR r IN SELECT c.oid::regclass AS o,
                  CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE'
                                 WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END AS kind
             FROM pg_class c
            WHERE c.relnamespace = 'pgboss'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
              AND c.relowner <> 'pos_migrate'::regrole
              AND (c.relkind <> 'S' OR NOT EXISTS (SELECT 1 FROM pg_depend d
                               WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                                 AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')))
            ORDER BY c.relkind = 'S' LOOP
    EXECUTE format('ALTER %s %s OWNER TO pos_migrate', r.kind, r.o);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS o FROM pg_proc p
            WHERE p.pronamespace = 'pgboss'::regnamespace AND p.proowner <> 'pos_migrate'::regrole LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO pos_migrate', r.o);
  END LOOP;
  -- перечисления, домены, диапазоны и отдельные составные типы (тип строки таблицы и массивы — вместе с владельцем)
  FOR r IN SELECT t.oid::regtype AS o, CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END AS kind
             FROM pg_type t LEFT JOIN pg_class c ON c.oid = t.typrelid
            WHERE t.typnamespace = 'pgboss'::regnamespace AND t.typowner <> 'pos_migrate'::regrole
              AND (t.typtype IN ('e', 'd', 'r') OR c.relkind = 'c') LOOP
    EXECUTE format('ALTER %s %s OWNER TO pos_migrate', r.kind, r.o);
  END LOOP;
  GRANT USAGE ON SCHEMA pgboss TO pos_app;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgboss TO pos_app;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgboss TO pos_app;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgboss TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT USAGE, SELECT ON SEQUENCES TO pos_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA pgboss GRANT EXECUTE ON FUNCTIONS TO pos_app;
END $$;
SQL
```

Блок идемпотентен: повторный запуск ничего не меняет. Тот же блок выполняют restore-db.sh и update.sh; совпадение
текстов RUNBOOK и restore-db.sh проверяет тест `pos-api/test/db/migrate-seed.db-spec.ts` (п. 13, там же блок
выполняется на настоящем PostgreSQL), а то, что update.sh отправляет именно этот текст, — `infra/docker/scripts/test_lib.sh`.

**Проверка и обновление:**

1. `printf "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'pgboss';\n" | dc exec -T postgres sh -c 'psql --no-psqlrc -qAt -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` → `pos_migrate`.
2. update.sh (§3.2). В журнале migrate (`dc logs migrate`) — «pg-boss: 0 изменений (схема актуальна)» или «схема
   обновлена» и «у pos_app снято право CREATE на базу (07 DATA-012)».
3. Если migrate вместо этого предупреждает «у pos_app есть право CREATE на базу» (владелец базы — не
   `pos_migrate`): под суперпользователем `REVOKE CREATE ON DATABASE <база> FROM pos_app;`, затем
   `has_database_privilege('pos_app', '<база>', 'CREATE')` → `f`.
4. Запись в журнале эксплуатации (§9).

---

## 4. Резервные копии и восстановление

### 4.1. Что копируется

| Данные | Как | Когда | Где |
|---|---|---|---|
| База PostgreSQL | роль `pos_backup` (чтение всех данных, не суперпользователь): `pg_dump -Fc` (с владельцами и правами) → шифрование age → файл `*.dump.age`; незашифрованный дамп на диск не пишется | ежедневно `BACKUP_SCHEDULE` — 05:30, после ночных заданий синхронизации (`SYNC_IMAGES_CRON` 02:30, `SYNC_COUNT_CHECK_CRON` 03:30, `SYNC_RECONCILE_CRON` вс 04:00) и до открытия магазина (сдвигается вместе с ними, Q-033); хранение `BACKUP_KEEP_DAYS` (30 суток) | `/srv/optomstroy/prod/backups` (отдельный диск, §2.2); вне сервера — `<BACKUP_REMOTE>/db` |
| Месячные копии | первая копия каждого месяца — жёсткая ссылка в `backups/monthly/`, хранится ещё 3 месяца после суточного срока (`BACKUP_KEEP_DAYS` + 93 суток ≈ 120 дней; 16 §8.1, OPS-001, 07 DATA-298) | ежедневно | `backups/monthly/`; вне сервера — `<BACKUP_REMOTE>/monthly` |
| Роли БД | создаются initdb из файлов `secrets/` при установке; дополнительно по воскресеньям — `pg_dumpall --globals-only --no-role-passwords` (роли и членство, без паролей) → age, 90 суток | еженедельно | `backups/globals_*.sql.age`; вне сервера — `<BACKUP_REMOTE>/db`; пароли — защищённая копия `secrets/` |
| `secrets/`, `.env` | копия на носитель заказчика вручную после каждого изменения | при изменении | офлайн у заказчика (16 §8.2) |
| Фото (`media`) | `rclone copy --immutable` без удаления (фото контент-адресуемы, D-30); служебные файлы и корзина очистки — мимо. Копия обязательна | ежедневно, после дампа | `backups/media/` (накопительно); вне сервера — `<BACKUP_REMOTE>/media` |
| Сертификаты (`optomstroy-edge_caddy_data`) | `bin/backup-caddy.sh`: том читается одноразовым контейнером без сети, tar сразу шифруется age сервисом backup; 30 суток | ежедневно в 06:00, таймер systemd `optomstroy-caddy-backup.timer` | `backups/caddy_data/`; вне сервера — `<BACKUP_REMOTE>/caddy_data` |
| Непрерывная копия WAL (PITR; `BACKUP_PITR=on` — по умолчанию в рабочем контуре) | `archive_command` PostgreSQL кладёт каждый сегмент WAL в спул на диске базы, сервис backup за ~20 с сжимает его, шифрует age и удаляет из спула; сегмент закрывается не реже раза в минуту (`archive_timeout=60`). Базовая копия кластера — `pg_basebackup` под ролью `pos_backup` (REPLICATION), сразу после дампа. Подробно — §4.8 | WAL — непрерывно, вне сервера раз в 5 минут; базовая копия — ежедневно с дампом; хранение — `BACKUP_KEEP_DAYS` (самая новая базовая копия — всегда) и WAL, нужный самой старой из них | `backups/pitr/<system_identifier>/{base,wal}`; вне сервера — `<BACKUP_REMOTE>/pitr` |

Сервис backup помечается `unhealthy` (проверка `backup.sh health`, причина — в `docker inspect --format
'{{json .State.Health}}' optomstroy-prod-backup-1`), если: последняя копия старше 26 часов; при `BACKUP_REMOTE` —
последняя полностью успешная ночная выгрузка вне сервера (`backups/.offsite_ok`) старше 26 часов; при `BACKUP_PITR=on`
— у postgres не `archive_mode=on`, архивация WAL сбоит (в `pg_stat_archiver` последняя ошибка новее последнего успеха),
сегмент лежит в спуле дольше 10 минут, самая новая базовая копия старше 26 часов, при `BACKUP_REMOTE` — выгрузка WAL
(`backups/.wal_offsite_ok`) старше 30 минут. Сбой фото, globals, базовой копии или выгрузки не отменяет копию базы: она
остаётся, прогон завершается с ошибкой (`/fail` в Healthchecks), а невыгруженные файлы уходят следующей ночью
(выгружается весь каталог).

### 4.2. Ручная копия

```sh
dc run --rm backup once                             # одна копия сейчас; журнал — в выводе
ls -lt /srv/optomstroy/prod/backups | head          # ежедневные копии
ls -lt /srv/optomstroy/prod/backups/monthly         # месячные копии
sudo /opt/optomstroy/prod/bin/backup-caddy.sh       # копия сертификатов сейчас
```

### 4.3. Копия вне сервера (обязательна, 16 §8.1)

1. Хранилище — предпочтительно в КР (16 §8.1). Учётная запись выгрузки **без права удаления и перезаписи**
   (11 SEC-111): скрипт выполняет только `rclone copy --immutable`, поэтому backup.sh вне сервера **ничего не удаляет**.
2. Хранение вне сервера задаётся правилом жизненного цикла (версионирования) самого хранилища, по каталогам:
   `db/` — не меньше 35 суток (30 суточных копий и globals), `monthly/` — не меньше 125 суток (3 месячные копии,
   16 §8.1), `media/` — без срока или не меньше 1 года (накопительная копия фото), `caddy_data/` — 30 суток,
   `pitr/` — не меньше 35 суток (базовые копии и архив WAL за `BACKUP_KEEP_DAYS`, §4.8).
   Если хранилище не умеет разные сроки по каталогам — один срок не меньше 125 суток для всего.
3. На машине администратора: `rclone config` → файл `rclone.conf` с remote (например, `offsite`).
4. На сервер: `sudo /opt/optomstroy/prod/bin/rotate-secret.sh set rclone.conf --from-file <путь>`; исходный файл удалить.
5. В `.env`: `BACKUP_REMOTE=offsite:optomstroy/prod` — **корень**: backup.sh сам добавляет `db`, `monthly`, `media`,
   `caddy_data`, `pitr` (прежняя запись `…/prod/db` понимается как корень, с предупреждением в журнале); затем
   `dc up -d backup`.
6. Проверка: `dc run --rm backup once` — в журнале строка «выгружено во внешнее хранилище»; файл
   `/srv/optomstroy/prod/backups/.offsite_ok` обновился (время выгрузки, UTC); через 5 минут обновился и
   `.wal_offsite_ok` (выгрузка WAL, при `BACKUP_PITR=on`); `dc ps` — backup `healthy`.

### 4.4. Ежемесячная проверка восстановления

Выполняет держатель ключа age (ключ на съёмном носителе, на сервере не остаётся):

```sh
sudo /opt/optomstroy/prod/bin/backup-restore-test.sh --identity /media/<носитель>/optomstroy-backup.key
```

Скрипт восстанавливает самую новую копию во временный PostgreSQL во временной внутренней сети без портов,
проверяет журнал миграций, расширения и ключевые таблицы, печатает число строк `products`, `product_variants`,
`customers`, `orders`, `payments`, `audit_logs` и время, затем всё удаляет. Рабочую базу не трогает. Результат —
в журнал эксплуатации (16 §8.5 п. 9).

При `BACKUP_PITR=on` тот же запуск проверяет и восстановление на момент времени (шаг PITR; `--no-pitr` — пропустить,
`--pitr` — потребовать): в отдельной базе учений `optomstroy_pitr_drill` того же кластера (рабочая база не меняется)
пишется метка A, запоминается момент T, пишется метка B; сегмент WAL закрывается, скрипт ждёт его в архиве; затем
самая новая базовая копия, закончившаяся раньше T, и архив WAL восстанавливаются во временный том и временный
PostgreSQL без сети и без архивации, с теми же настройками, что `restore-db.sh --to-time`. Проверка пройдена, если
метка A есть, метки B нет и после promote началась новая линия времени. С `--pitr-latest` — те же шаги с настройками
`restore-db.sh --to-latest` (весь архив, без цели): должны быть обе метки, A и B. Нужны базовая копия (ночная или
`dc run --rm backup base`) и работающий сервис backup; место — на диске Docker, примерно размер базы. Пропуск проверки ловит проверка Healthchecks «restore-drill»
(`--ping-url-file`, 16 §8.4). Раз в квартал — та же проверка месячной копии
(`--dump /srv/optomstroy/prod/backups/monthly/<файл>.dump.age`) и копии, скачанной из внешнего хранилища. По
согласованию с заказчиком (данные клиентов, Q-027) копию можно восстановить и в тестовую копию — §10.3.

### 4.5. Восстановление рабочей базы

Когда: повреждение базы, ошибочная разрушающая миграция, перенос на новый сервер (16 §15.3).

```sh
sudo /opt/optomstroy/prod/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key [--dump <файл>.dump.age]
```

Скрипт: проверяет, что копия расшифровывается целиком (иначе база не трогается) → просит ввести имя базы →
делает страховочную копию текущей базы → останавливает api, worker, backup → пересоздаёт базу (владелец
`pos_migrate`, права на базу — как при установке) → восстанавливает копию → проверяет владельцев и права роли
`pos_app` → переносит владельца схемы `pgboss` на `pos_migrate` (копии баз, созданных до 2026-11-19, §3.6) и
проверяет, что у `pos_app` нет права CREATE на базу → `ANALYZE` → `migrate` → запускает сервисы.

Потеря меньше суток — восстановление по непрерывной копии WAL (§4.8): на момент до ошибки — `--to-time`; гибель
сервера или диска базы — всё, что успело в архив, — `--to-latest` (момент угадывать не нужно).

После восстановления:
1. Предупредить кассиров: заказы и корзины после момента копии потеряны. Смена эпохи данных `server_epoch`
   (16 §8.5 п. 7) в текущей версии сервера не реализована: такого значения нет ни в базе, ни в коде сервера и
   приложения, поэтому приложения о восстановлении не узнают и сами полностью не пересинхронизируются — черновики,
   корзины и неотправленные действия на устройствах проверяются вручную (known_issues OPS-KI-04).
2. Когда 1С подключена — ручной прогон синхронизации и сверка `onec_outbox` за окно потери (16 §8.5 п. 8).
3. Prod-smoke (16 §10.9), запись в журнале: дата, копия, фактическое время восстановления, потерянный период.

**Новый сервер:** §2 на новом сервере с исходной копией `secrets/` и `.env` (положить в `/opt/optomstroy/prod/`
до запуска install.sh с `--skip-admin` и той же версией — тогда роли получат прежние пароли), затем restore-db.sh с копией, перенесённой с внешнего
хранилища, и смена A-записи DNS. Цель — 1 рабочий день (16 §8.1). При `BACKUP_PITR=on` — точнее:
`restore-db.sh --to-latest --sysid <прежний кластер>` по архиву WAL из внешнего хранилища (§4.8, «Новый сервер или
потерянный диск копий»).

Копии, сделанные до 2026-11-18 (без владельцев и прав), restore-db.sh не принимает: нужна ручная выдача прав (DevOps).

### 4.6. Восстановление фото

Фото — обычные файлы `images/<sha256>/<размер>.webp`, не зашифрованы (в них нет данных клиентов). С диска копий или
из внешнего хранилища — без удаления того, что уже есть:

```sh
sudo docker run --rm --network none -v /srv/optomstroy/prod/backups/media:/from:ro -v /srv/optomstroy/prod/media:/to \
     --user 10001:10001 --entrypoint rclone optomstroy/backup:<BACKUP_TAG> copy /from /to --log-level ERROR
# из внешнего хранилища (rclone.conf — на машине администратора): rclone copy offsite:optomstroy/prod/media <каталог>
```

### 4.7. Восстановление сертификатов caddy

Нужно только при переносе на новый сервер (иначе Caddy выпустит сертификаты заново; лимит Let's Encrypt — 5 одинаковых
за 7 дней). Держатель ключа age, после `install.sh` и до первого обращения клиентов:

```sh
sudo /opt/optomstroy/prod/bin/dc-edge stop caddy
sudo docker run --rm -i --network none --user 0:0 --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH \
     -v /media/<носитель>/optomstroy-backup.key:/k:ro -v <архив>.tar.age:/a:ro \
     --entrypoint age optomstroy/backup:<BACKUP_TAG> -d -i /k /a \
  | sudo docker run --rm -i --network none -v optomstroy-edge_caddy_data:/data --entrypoint tar caddy:<тег> -C /data -xf -
sudo /opt/optomstroy/prod/bin/dc-edge up -d caddy
```

Архив — `/srv/optomstroy/prod/backups/caddy_data/caddy_data_<UTC>.tar.age` или `<BACKUP_REMOTE>/caddy_data/`.

### 4.8. Непрерывная копия WAL и восстановление на момент времени (PITR)

**Зачем.** В базе POS — заказы, оплаты и возвраты, ещё не доставленные в 1С (`onec_outbox`, например пока 1С
недоступна), сессии и аудит: их нет больше нигде. Ежедневная копия
теряет до суток. Непрерывная копия журнала WAL теряет на этом сервере не больше минуты, при гибели сервера — не больше
нескольких минут (выгрузка вне сервера раз в 5 минут); документ заказчику обещает «не больше 15 минут». Основание:
15 ADR-035 (дополнение), 16 §8.1 «RPO при PITR ≤ 15 мин» (OPS-006, Q-033). Средства — встроенные
в PostgreSQL 17 (`archive_command`, `pg_basebackup`, `restore_command`, `recovery_target_time`); отдельный инструмент
(pgBackRest, WAL-G) не нужен: шифрование то же, что у дампов (age), выгрузка — та же (rclone, без удаления).

**Как устроено.**

| Звено | Что делает | Где |
|---|---|---|
| postgres | `wal_level=replica`, `archive_mode` из `BACKUP_PITR`, `archive_timeout=60` (сегмент закрывается не реже раза в минуту), `archive_command` = `wal-archive.sh`: копия во временный файл, fsync, публикация без перезаписи (тот же файл — успех, другой с тем же именем — отказ), fsync каталога; любой сбой — ненулевой код, PostgreSQL сегмент не удаляет и повторяет | `/srv/optomstroy/prod/walspool` — диск базы: недоступный диск копий не останавливает базу |
| backup, цикл WAL | раз в 20 с: файл спула → gzip → age → `backups/pitr/<system_identifier>/wal/<сегмент>.gz.age` (рядом `….sha256` — сумма сегмента для сверки повтора), затем удаляет его из спула; раз в 5 минут — вне сервера всё, что зашифровано с начала последней успешной выгрузки (после перебоя связи — всё накопленное за один проход), отметка `.wal_offsite_ok` — время начала этой выгрузки | диск копий, `<BACKUP_REMOTE>/pitr` |
| backup, ночной прогон | после дампа — базовая копия `pg_basebackup -X fetch` (роль `pos_backup`, REPLICATION; строка `host replication pos_backup` в `pg_hba.conf`) → gzip → age → `base/base_<UTC>.tar.gz.age` и сведения `base_<UTC>.info` (начало и конец, первый и последний сегмент WAL, размер до сжатия `base_bytes` — без данных); очистка: базовые копии старше `BACKUP_KEEP_DAYS` (самая новая — никогда) и WAL, не нужный самой старой оставшейся | диск копий; вне сервера — базовые копии и страховочная сверка WAL старше часа (по очереди с циклом WAL, замок `.wal_upload.lock`) |

`<system_identifier>` — номер кластера PostgreSQL: новый кластер (переустановка, новый сервер) пишет в свой каталог,
имена сегментов разных кластеров не сталкиваются ни на диске, ни во внешнем хранилище; сервис backup спрашивает номер
у базы на каждом проходе, поэтому и кластер, пересозданный без перезапуска backup, попадает в свой каталог.
Незашифрованный WAL лежит только в спуле на диске базы (секунды), на диск копий и вне сервера попадает только
зашифрованный; файлы `*.sha256` — суммы, по ним содержимое не восстановить, вне сервера они не выгружаются. Сегмент,
который уже лежит в архиве с другой суммой, сервис backup не удаляет и не перезаписывает (§6.3, `wal-spool-stuck`).

**Включение и выключение.** `.env`: `BACKUP_PITR=on` (по умолчанию в рабочем контуре) или `off`; затем
`dc up -d postgres backup` (postgres перезапускается — 10–30 секунд простоя) и для `on` — первая базовая копия сразу:
`dc run --rm backup base`. update.sh делает всё это сам при обновлении. Роль `pos_backup` и строку `pg_hba.conf`
выставляют install.sh (новый кластер — initdb) и update.sh (`pg_sync_backup_role`). При выключении сегменты, уже
лежащие в спуле, сервис backup не трогает — убедитесь, что `walspool/` пуст (иначе включите на время и дождитесь).
Тестовая копия (§10) — `BACKUP_PITR=off`.

**Проверка.** `dc ps` — backup `healthy`; `ls -lt /srv/optomstroy/prod/backups/pitr/*/wal | head` — свежие сегменты;
`ls -lt /srv/optomstroy/prod/backups/pitr/*/base` — базовая копия моложе суток; `ls /srv/optomstroy/prod/walspool` —
пусто или 1–2 файла; ежемесячно — шаг PITR проверки восстановления (§4.4).

**Место.** Базовая копия — одна в сутки, хранится `BACKUP_KEEP_DAYS`; WAL — 16 МиБ на сегмент до сжатия. Учение
2026-11-19 (PostgreSQL 17.10): сегмент, закрытый по `archive_timeout` или переключением почти пустым, после gzip —
16–90 КБ; сегмент с загрузкой данных — 0,3–3,6 МБ; базовая копия маленького кластера (39 МБ) — 5,5 МБ (около 15 %;
у реальной базы с индексами и текстом доля обычно выше). В минуту без изменений сегмент не закрывается. Оценка
`[ОЦЕНКА]` для базы 1–3 ГБ и обычного дня магазина: базовые копии 5–30 ГБ за 30 суток, WAL 0,1–0,5 ГБ в сутки
(3–15 ГБ за 30 суток) — всего 10–45 ГБ на диске копий и столько же вне сервера. Точное значение — по
`du -sh /srv/optomstroy/prod/backups/pitr` через неделю работы. Место на диске базы для восстановления restore-db.sh
считает по размеру копии до сжатия (измеряет при проверке ключа; он же — `base_bytes` в `.info`) × 1,1 плюс 16 МиБ на
каждый распакованный сегмент WAL; коэффициент к сжатой копии не годится — в учении 2026-11-19 копия сжалась в 7 раз.

**Восстановление на момент времени** (ошибочное удаление, повреждение базы, неудачная миграция). Выполняет держатель
ключа age:

```sh
sudo /opt/optomstroy/prod/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key --to-time '2026-11-19 14:30'
```

- Время — по часовому поясу контура (`TZ` в `.env`, Asia/Bishkek); восстанавливается всё, что зафиксировано не позже
  этого момента (`recovery_target_time`), затем база переводится в рабочий режим (`recovery_target_action=promote`,
  новая линия времени).
- Скрипт: выбирает кластер (в `backups/pitr/` один каталог — его; несколько — отказ со списком, нужен
  `--sysid <system_identifier>`) и в нём самую новую базовую копию, закончившуюся раньше момента (`--base <файл .info>`
  — другую) → печатает кластер копии и работающий кластер (разные — строка «кластер будет заменён ДРУГИМ кластером») →
  проверяет ключ (расшифровка и распаковка копии целиком, заодно — её размер) → просит ввести имя базы → делает
  страховочную копию (без очистки архива PITR) → закрывает текущий сегмент WAL и ждёт его в архиве → проверяет архив:
  базовая копия и её первый сегмент на месте, нет ли дыры в WAL (момент позже дыры — отказ до остановки), место на
  диске базы → останавливает api, worker, backup, postgres → **прежний каталог данных переименовывает в
  `pgdata.pre-pitr-<UTC>`** (не удаляет) → распаковывает базовую копию и нужные сегменты WAL (момент + 24 ч,
  `--wal-hours N`) → запускает postgres, ждёт восстановления и promote → снимает настройки восстановления, выставляет
  пароли ролей из `secrets/` → те же проверки владельцев, что §4.5 → migrate → сервисы → новая базовая копия.
- «recovery ended before configured recovery target was reached» — в распакованном WAL нет ни одной фиксации после
  момента: `--to-time` останавливается только на первой фиксации ПОЗЖЕ момента, поэтому последнюю фиксацию архива так
  не восстановить (после неё фиксаций нет) — и ночь без работы при малом `--wal-hours` даёт тот же отказ. Скрипт
  останавливается и печатает команду возврата к прежнему каталогу. Выход: восстановить всё до конца архива
  (`--to-latest`, ниже) или повторить с более ранним моментом либо бо́льшим `--wal-hours`.
- «is not a child of this server's history» — базовая копия с другой ветви линий времени (сделана после прошлого
  восстановления на момент): повторить с `--base` — копией нужной ветви.
- Отказ распознаётся по журналу postgres и по самому контейнеру (остановился или перезапускался) — скрипт не ждёт
  2 часа, а сразу останавливает postgres и печатает журнал.
- Вернуть всё как было до восстановления: `dc rm -f -s postgres`, `rm -rf /srv/optomstroy/prod/pgdata`,
  `mv /srv/optomstroy/prod/pgdata.pre-pitr-<UTC> /srv/optomstroy/prod/pgdata`, `dc up -d`.
- После проверки — удалить `pgdata.pre-pitr-<UTC>` (занимает место размером с базу).
- Дальше — как после §4.5 (кассиры, `server_epoch` не реализован, 1С, prod-smoke, журнал).

**Восстановление до конца архива** (гибель сервера или диска базы, повреждённый каталог данных — нужно всё, что
успело в архив, а момент последней фиксации неизвестен):

```sh
sudo /opt/optomstroy/prod/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key --to-latest [--sysid <system_identifier>]
```

- Без цели восстановления: PostgreSQL проигрывает весь архив WAL после самой новой базовой копии кластера и сам
  переводит базу в рабочий режим (новая линия времени). Момент угадывать не нужно, отказа «recovery ended before…» не
  бывает.
- Шаги — те же, что у `--to-time`; подтверждение называет последний сегмент архива и время его шифрования. Если
  работает тот же кластер, текущий сегмент перед остановкой закрывается и тоже входит.
- Дыра в архиве (сегмента нет): без цели PostgreSQL на ней молча закончил бы восстановление, и всё после неё пропало бы
  без сообщения (учение 2026-11-19). Поэтому скрипт проверяет архив до остановки, печатает последний сегмент перед
  дырой и время его шифрования и спрашивает, восстанавливать ли до дыры (`--yes` — без вопроса).
- После promote скрипт печатает строки журнала postgres «redo done at …» и «last completed transaction was at log time
  …» и записывает время последней фиксации в журнал и в `state/releases.log` (`… → конец архива (последняя фиксация
  …)`): это начало окна потерь для кассиров и журнала эксплуатации.
- `--to-time` — только чтобы вернуться в момент ДО ошибки (ошибочное удаление, неудачная миграция).

**Новый сервер или потерянный диск копий.** Установка §2 (с исходной копией `secrets/` и `.env`), затем копия архива
из внешнего хранилища на диск копий (на машине с `rclone.conf`):
`rclone copy offsite:optomstroy/prod/pitr /srv/optomstroy/prod/backups/pitr` (права — `chown -R 10002:10002`).
После этого в `backups/pitr/` **два каталога**: прежний кластер (из внешнего хранилища) и новый пустой — первую
базовую копию нового кластера сделал install.sh. Прежний — тот, чей WAL кончается временем гибели сервера:
`ls /srv/optomstroy/prod/backups/pitr`, `ls -lt /srv/optomstroy/prod/backups/pitr/<каталог>/wal | head -3` или строка
`system_identifier=` в `base/*.info`; restore-db.sh без `--sysid` откажет и сам напечатает по каждому кластеру первую и
последнюю базовую копию и время последнего сегмента WAL. Затем:

```sh
sudo /opt/optomstroy/prod/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key --to-latest --sysid <прежний>
# или на момент, не позже гибели прежнего сервера:  --to-time '<момент>' --sysid <прежний>
# или конкретная копия:                             --to-latest --base /srv/optomstroy/prod/backups/pitr/<прежний>/base/base_<UTC>.info
```

Без `--sysid` выбор только по времени взял бы копию нового пустого кластера (она новее) — и «восстановил» бы пустую
базу. Восстановленный кластер получает прежний `system_identifier` и продолжает писать в прежний каталог архива;
каталог нового пустого кластера ночная очистка уберёт через `BACKUP_KEEP_DAYS`. Начинайте восстановление сразу после
копирования: rclone сохраняет время изменения файлов, и ночной прогон копий удалит базовые копии из внешнего
хранилища старше `BACKUP_KEEP_DAYS` (страховочная копия самого restore-db.sh архив не чистит). Если нужна старая
копия — скопируйте её каталог кластера (`base/` и `wal/`) в отдельный каталог вне `backups/pitr` и укажите
`--base <…/base/base_<UTC>.info>`: туда очистка не заглядывает, а WAL скрипт берёт из `wal/` рядом с `base/`.

**Ограничения.** Минута до сбоя (незакрытый сегмент) не восстанавливается; при гибели сервера — сегменты, не
выгруженные вне сервера (до 5–6 минут), а при обрыве связи с внешним хранилищем — всё за время обрыва: после
восстановления связи первый успешный проход цикла WAL (раз в 5 минут, после сбоя — раз в минуту) выгружает всё
накопленное, сколько бы ни длился перебой; через 30 минут перебоя backup становится `unhealthy:
wal-offsite-older-30m` (§6.3). Восстановление заменяет весь кластер (все базы контура), а не одну таблицу. Момент
раньше конца самой старой базовой копии недоступен — тогда ежедневная или месячная копия (§4.5).

---

## 5. Устройства магазина

| Устройство | Что сделать | Источник |
|---|---|---|
| Все приложения | сборка `pos-app` выпускается исполнителем с адресом `https://api.<домен>/api/v1` (`API_BASE_URL`, профиль `--dart-define-from-file`); версия не ниже `MIN_APP_VERSION` в `.env` | 16 §10.2, §10.8 |
| Кассы Windows | zip-архив и `SHA256SUMS` разными каналами; проверка хэша, распаковка в `C:\Program Files\OptomstroyPOS\<версия>`, ярлык | 16 §10.7 |
| Телефоны и планшеты сотрудников (Android) | установка APK от исполнителя; вход по SMS-коду и PIN | 16 §10.2 |
| Сотрудники | приглашает администратор в приложении (SCR-45): сотрудник входит по SMS на свой номер и задаёт PIN | docs/ops/first_admin.md §4 |
| Вход по лицу | на рабочем контуре выключен: `AUTH_BIO_ALLOW_WEAK=off`, `AUTH_WINDOWS_HELLO_KEY=off` до записей проверок T-BIO-026 и T-BIO-031 | 16 DEPLOY-055 |
| Планшет магазина (киоск) | выключен: `KIOSK_MODE=false`. Включение — только по письменному разрешению заказчика: пилот одного планшета, `KIOSK_MODE=true` и `KIOSK_ALLOWED_CIDRS` в `.env` (адреса, с которых сервер видит планшет: при сервере вне магазина — внешний IP магазина, как его видит сервер; при сервере в магазине — адреса LAN; пусто — без проверки сети; при переходе магазина на резервный 4G планшет со списком только основного IP перестанет принимать заявки — вопрос Q-377), `dc up -d api worker`, подключение в SCR-54. Планшет никогда не предлагает вход по лицу | 16 §4.3, §10.10, DEPLOY-053; P-002 |

Минимальная версия приложения меняется в `.env` (`MIN_APP_VERSION`) или администратором в настройках (SCR-46) —
только после установки новой версии на всех устройствах (16 §10.8).

---

## 6. Журналы и состояние

### 6.1. Журналы

| Что | Команда | Где хранится |
|---|---|---|
| api, worker | `dc logs --since 1h api worker` | JSON в журнале Docker, ротация 20 МБ × 5 на сервис |
| Caddy (доступ, сертификаты; оба сайта) | `dc-edge logs --since 1h caddy` | то же |
| Копия сертификатов (таймер) | `journalctl -u optomstroy-caddy-backup --since today` | журнал systemd |
| Метрики сервера (таймер) | `journalctl -u optomstroy-metrics --since today` | журнал systemd |
| Миграции | `dc logs migrate` | то же |
| Копии | `dc logs backup` | то же |
| Установки, обновления, восстановления | `sudo cat /opt/optomstroy/prod/state/releases.log` | `state/` |

Журналы не содержат значений секретов. Номера телефонов и коды в журналы не пишутся; перед передачей журнала
третьим лицам всё равно просмотрите его (11 §7).

### 6.2. Состояние

| Проверка | Как | Норма |
|---|---|---|
| Контейнеры | `dc ps`, `dc-edge ps` | api, worker, postgres, backup — `healthy`; caddy — `running` |
| Копии | `ls -l --time-style=+%F\ %T /srv/optomstroy/prod/backups/.offsite_ok /srv/optomstroy/prod/backups/.wal_offsite_ok`; `systemctl list-timers 'optomstroy-*'` | ночная выгрузка моложе 26 ч, выгрузка WAL — 30 мин; таймеры копии сертификатов и метрик включены |
| Непрерывная копия WAL | `ls /srv/optomstroy/prod/walspool`; `ls -lt /srv/optomstroy/prod/backups/pitr/*/base \| head -3` | спул пуст или 1–2 файла; базовая копия моложе суток (§4.8) |
| Живость снаружи | `curl -s https://api.<домен>/health` | `200` |
| Готовность | `dc exec -T api wget -qO- http://127.0.0.1:3000/health/ready` (снаружи путь закрыт, 06 ARCH-006) | `ok`; `degraded` — синхронизация устарела (пока 1С не подключена — ожидаемо); `503 failed` — нет БД или очередей |
| Диск | `df -h /srv/optomstroy /var/lib/docker` | занято < 80 % |

### 6.3. Типовые сбои

| Симптом | Действия |
|---|---|
| `api` не стартует после изменения `.env` | `dc logs api` — сообщение называет переменную (без значения); исправить `.env`, `dc up -d api worker` |
| приложения пишут «ошибка сети», сертификат истёк | `dc-edge logs caddy \| grep -i acme`; DNS указывает на сервер, порт 443 открыт снаружи, время верное; `dc-edge restart caddy`; том `optomstroy-edge_caddy_data` не удалять (16 §15.4), копия — §4.7 |
| общий caddy не стартует: «network optomstroy_…_edge declared as external, but could not be found» | сеть удалили (`docker network prune`): `dc-edge up -d` и `dc up -d` создают её снова; prune сетей на сервере не выполнять |
| backup `unhealthy`, копии свежие | причина — в `docker inspect --format '{{json .State.Health}}' optomstroy-prod-backup-1` (строка `unhealthy: …`); `offsite-older-26h` — выгрузка вне сервера не удалась больше суток: `dc logs --since 26h backup`; проверить хранилище и `rclone.conf` (§4.3), затем `dc run --rm backup once` |
| backup `unhealthy: wal-archiving-failing` | `dc logs --since 1h postgres \| grep -i archive` — ошибка `wal-archive.sh`: нет спула или прав (`ls -ld /srv/optomstroy/prod/walspool` → 999, группа 10002, `drwxrws---`; исправить — `install -d -m 2770 -o 999 -g 10002 …`), «другим содержимым» — в спуле чужой файл с именем сегмента (разбор — DevOps, файл не удалять). PostgreSQL копит WAL в `pg_wal`, пока архивация не пройдёт — следите за диском базы |
| backup `unhealthy: wal-spool-stuck` | сегменты не шифруются: `dc logs --since 1h backup \| grep WAL` — нет `BACKUP_AGE_RECIPIENT`, БД недоступна, диск копий не смонтирован или полон, посторонний файл в спуле (не трогается — убрать вручную после разбора). «уже в архиве с другим содержимым» — в спуле сегмент с тем же именем, что в архиве, но другим содержимым (откат диска базы, базовая копия запущена без `recovery.signal`, кластер пересоздан при работающем backup): файл не удалять и архив не трогать, разбор — DevOps |
| backup `unhealthy: base-backup-older-26h` | `dc logs backup \| grep 'базовая копия'`; «no pg_hba.conf entry for replication connection» или «must have replication» — `sudo /opt/optomstroy/prod/bin/update.sh` того же релиза или вручную `pg_sync_backup_role` (lib.sh); затем `dc run --rm backup base`. Кластер пересоздан (новый `system_identifier`, новый каталог в `backups/pitr/`) — у нового кластера ещё нет базовой копии: `dc run --rm backup base` (сервис backup спрашивает номер кластера у базы на каждом проходе, перезапуск не нужен) |
| backup `unhealthy: archive_mode-off` | `BACKUP_PITR=on`, а postgres запущен без архивации: `dc up -d postgres backup` (§4.8) |
| backup `unhealthy: wal-offsite-older-30m` | выгрузка WAL вне сервера не проходит 30 минут: хранилище, связь, `rclone.conf` (§4.3). Пока сигнал горит, копия вне сервера отстаёт на всё время перебоя (при гибели сервера это и есть потеря). Сегменты догрузятся сами: после восстановления связи первый успешный проход (раз в минуту, пока выгрузка не удаётся) выгружает всё, что зашифровано с начала последней успешной выгрузки, — за один проход, независимо от длительности перебоя; отметка `.wal_offsite_ok` обновляется только после него. Ускорить: `dc exec backup backup.sh wal-upload` (код 75 — выгрузку сейчас делает ночной прогон, повторить через минуту) |
| диск заполнен | `docker system df`; `docker image prune` (не `-a --volumes`); старые копии сверх срока хранения — только при наличии внешней копии (16 §15.5) |
| сервер перезагружен | `dc ps`, `/health/ready`; контейнеры поднимаются сами; сервер вне магазина — `sudo wg show wg0`: рукопожатие магазина моложе 3 минут (16 §15.6) |
| сервер вне магазина: сигнал метрик `WG_HANDSHAKE_STALE` (в любое время), заказы и оплаты копятся в очереди к 1С | туннель магазина не активен — §11.6 |
| `/health/ready` → 503, в `dc logs api` или `dc logs worker` — «pg-boss is not installed» или «requires migrations» | схему очередей ставит только migrate: `dc logs migrate`, затем `dc run --rm migrate` и `dc up -d api worker`. Ошибка migrate `PGBOSS_FOREIGN_OWNER` — §3.6 |

### 6.4. Внешний мониторинг (16 §9)

- Uptime Kuma на **другом** хосте: `https://api.<домен>/health` каждые 60 секунд, уведомление на e-mail. Сервер в
  дата-центре — монитор в КР, не на самом сервере (§11.8).
- Healthchecks (self-hosted, в КР): `sudo /opt/optomstroy/prod/bin/rotate-secret.sh set healthchecks_url` — URL
  проверки; после этого дополнение `compose.prod.healthchecks.yml` подключается само, backup пингует после каждой копии.
- Метрики сервера (16 §8.4, §9 «Метрики минимум», OPS-014): `bin/metrics_check.sh` каждые 10 минут по таймеру
  `optomstroy-metrics.timer` (ставят install.sh и update.sh рабочего контура). Пороги: диск базы, копий и Docker
  > 80 %, доступная память < 10 %, load average за 15 минут > числа CPU, `/health/ready` через caddy > 2 с или не 200,
  сертификат < 20 дней; при подключённой 1С — ≥ 3 неудачных прогона синхронизации за сутки, `onec_outbox` в
  `failed`/`dead` дольше 15 минут, `pending` старше 30 минут; при туннеле к 1С (сервер вне магазина, §11) — последнее
  рукопожатие пира 1С старше 3 минут, `WG_HANDSHAKE_STALE`: сигнал в любое время — 1С нужна весь день (заказы,
  оплаты, возвраты — сразу; остатки и цены — каждые 5–30 минут). Сигнал — отдельная проверка Healthchecks «metrics»
  (период 10 минут): `sudo /opt/optomstroy/prod/bin/rotate-secret.sh set healthchecks_metrics_url`. Нарушение — `/fail`
  с кодами (`DISK_USAGE:/srv=85%` и т. п.). Журнал: `journalctl -u optomstroy-metrics --since today`; вручную —
  `sudo /opt/optomstroy/prod/bin/metrics_check.sh`.
- Алерты содержат только технические коды, без персональных данных (16 §9).

### 6.5. Старые образы

update.sh не удаляет образы прежних версий (нужны для отката). Через 2–3 недели стабильной работы:
`docker image ls optomstroy/api` и `docker image rm optomstroy/api:<старая версия>` (кроме текущей и предыдущей).

---

## 7. Ротация секретов

Все команды — `sudo /opt/optomstroy/prod/bin/rotate-secret.sh <команда>`; значения не печатаются, затронутые
сервисы пересоздаются, запись — в `state/secrets.log`. После любой ротации обновите защищённую копию `secrets/` и `.env`.

| Секрет | Команда | Влияние | Срок (предложение, infra/env/README.md §4) |
|---|---|---|---|
| Ключ подписи JWT | `jwt`, через 15 минут `jwt-prune` | плановая — нет; при компрометации `jwt-prune --force` сразу — все сессии входят заново | 12 месяцев |
| Pepper OTP | `otp-pepper` | нет (коды доживают срок) | 12 месяцев |
| Pepper PIN | `pin-pepper` | нет (PIN сохраняются) | 12 месяцев |
| Пароль роли `pos_app` | `db-app` | перерыв в несколько секунд | 12 месяцев и при смене персонала |
| Пароль роли `pos_migrate` | `db-migrator` | нет | то же |
| Пароль суперпользователя БД | `db-superuser` (нужен только обслуживанию: restore-db.sh, ротации ролей) | нет | то же |
| Пароль роли копий `pos_backup` | `db-backup` | backup пересоздаётся | то же |
| SMSPro | человек заказчика меняет пароль в кабинете SMSPro и сам вводит его: `sudo /opt/optomstroy/prod/bin/rotate-secret.sh set smspro_password` (и `set smspro_login`), ввод скрыт; оператор подсказывает команду, значений не получает (09 §6.12, SRC-B-122) | SMS не уходят на время пересоздания | при смене персонала |
| 1С | после смены пароля `pos_hs` или ключа клиента специалистом 1С: `set onec_hs_password`, `set onec_hs_token`; после смены пароля `pos_integration` — `set onec_password` (пара OData нужна режимам `extension` и `odata_only`) | синхронизация на время пересоздания | то же |
| Healthchecks, rclone | `set healthchecks_url`, `set rclone.conf --from-file <файл>` | нет | при изменении |

**7.1. Ключ JWT.** `jwt` выпускает новый ключ с новым `JWT_KEY_ID` и оставляет прежний публичный ключ в наборе
`jwt_public.json`, чтобы выданные токены доживали 15 минут. Если `JWT_KEY_ID` в `.env` и набор разошлись, install.sh
и rotate-secret.sh остановятся — восстановите оба файла из одной защищённой копии.

**7.2. Pepper.** Файл становится набором версий `{"1":"…","2":"…"}`, `*_VERSION` в `.env` увеличивается. Прежние
версии из набора не удаляются: по ним проверяются ранее сохранённые значения (16 §4.3, уточнения п. 1).

**Компрометация** (16 §15.6): сначала сдерживание — `APP_READ_ONLY=true` в `.env` и `dc up -d api worker` (изменения
данных → `503`, чтение работает), затем ротация, запись в журнал инцидентов, снятие `APP_READ_ONLY`.

---

## 8. 1С: до подключения, подключение и сбои обмена

### 8.1. Пока 1С не подключена

Контур запускается с `ONEC_MODE=extension` и пустым `ONEC_BASE_URL` (16 §4.3, §14.1 шаг 8). Сервер работает, но
синхронизация не может обратиться к 1С. Это ожидаемо и отличается от аварии:

| Признак | Почему |
|---|---|
| в журнале worker ошибки конфигурации шлюза 1С (`ONEC_BASE_URL: обязательна…`) | 1С не задана; worker при этом не падает |
| `/health/ready` → `degraded` | данных синхронизации нет или они устарели |
| уведомления `sync_error`, `SyncIndicator` «данные устарели» в приложении | то же |
| `QR_PROVIDER=none` | QR через 1С недоступен; кассир — статический QR с ручным подтверждением (16 §14.1 шаг 8) |

Рабочий запуск магазина — только с подключённой 1С: 1С — главная система, товары, цены, остатки и долги берутся из 1С,
своего учёта на сервере нет (15 ADR-120; P-003 «учёт у нас» отменён заказчиком 2026-11-20). До подключения сервер
годится для проверки установки, входа и копий — не для продаж.

### 8.2. Обмен с 1С не работает (1С подключена)

| Шаг | Действия (16 §15.1, §15.2) |
|---|---|
| Симптом | алерт Healthchecks `/fail` от worker; `sync_error` в приложении; `/health/ready` → `degraded`; ошибки `ONEC_UNAVAILABLE` в журнале worker |
| Диагностика | `dc logs --since 1h worker`; доступность HTTP-сервиса 1С изнутри: `dc exec worker wget -S -qO- -T 5 <ONEC_BASE_URL>/<ONEC_HS_PATH>/pos/v1/health` (ожидается `401` без ключа клиента — сервис опубликован; таймаут или `404` — нет публикации); с хоста — `curl` к веб-серверу 1С; работает ли веб-публикация 1С (у специалиста 1С). Режим `odata_only` — `…/odata/standard.odata/`. Сервер вне магазина (туннель, §11): `sudo wg show wg0` — последнее рукопожатие магазина моложе 3 минут; `sudo /opt/optomstroy/prod/bin/host-net-check.sh` — маршрут к 1С через `wg0`, рукопожатие, HTTPS публикации; рукопожатия нет — §11.6 |
| 1С недоступна | backend работает по снимку: заказы ждут в очереди отправки в 1С и уходят после восстановления; продажа в долг — по свежему снимку, иначе `422 RECEIVABLES_STALE`. **В 1С самостоятельно ничего не перезапускать** — сообщить специалисту 1С. Долгая недоступность QR через 1С — `QR_PROVIDER=none` в `.env` и `dc up -d api worker`, возврат после восстановления |
| 401/403 | учётные данные сменились: специалист 1С выдаёт новые → `rotate-secret.sh set onec_hs_password` (или `set onec_hs_token`); после смены пароля `pos_integration` — `set onec_password` (пара OData нужна режимам `extension` и `odata_only`) |
| таймауты на больших выборках | временно увеличить `ONEC_TIMEOUT_MS`, уменьшить `ONEC_SYNC_PAGE_SIZE` и/или `ONEC_MAX_CONCURRENCY` в `.env`, `dc up -d api worker` |
| изменились метаданные 1С, зацикливание на одной записи | backend-разработчику (версия адаптера) или специалисту 1С (данные) |
| Проверка | ручной прогон синхронизации в приложении (экран синхронизации) → `success`; нет записей очереди в 1С старше 30 минут; `/health/ready` → `ok` |
| Эскалация | DevOps → backend-разработчик (адаптер) / специалист 1С (публикация, права, данные) |

### 8.3. Ночное окно

Тяжёлые задания (загрузка фото, сверка количеств) по умолчанию идут ночью: `SYNC_NIGHT_WINDOW=01:00-06:00`,
`SYNC_IMAGES_CRON`, `SYNC_COUNT_CHECK_CRON`. Днём сервер работает с 1С постоянно: заказы, оплаты и возвраты уходят
сразу через очередь, остатки и цены читаются каждые 5–30 минут. Сервер вне магазина: туннель к 1С проверяется в любое
время, компьютер 1С включён круглосуточно (§11.4). Ежедневная полная копия — в 05:30 (`BACKUP_SCHEDULE`), после ночных
заданий; копия тестовой копии — в 05:45. Если ночные задания сдвигаются, `BACKUP_SCHEDULE` сдвигается вместе с ними
(`.env`, затем `dc up -d backup`).

### 8.4. Подключение 1С

1. Специалист 1С делает работу по «Требованиям к API 1С» версии 1.2 (`docs/integration/1C_API_requirements.md`
   §1.1, §4.2, §4.4, §8.1) и контракту `contracts/onec/onec-http-service.v1.yaml` 1.2.0: публикует по HTTPS
   HTTP-сервис расширения **и** стандартный OData только на чтение (состав — `contracts/onec/odata-allowlist.yaml`,
   05 ONEC-083) с доступом только с адреса сервера POS (сервер вне магазина — только с адреса сервера в туннеле
   `10.77.0.1`, публикация в интернет не открывается, §11.4); создаёт двух технических пользователей — `pos_hs`
   (роль `POS_ИнтеграцияPOS`, только HTTP-сервис) и `pos_integration` (только чтение OData) — и передаёт
   пользователей, пароли и ключ клиента `X-POS-Client-Key` лично (не через чат). Первым — на тестовой копии базы 1С
   и тестовой копии POS (§10), затем на рабочей.
2. Секреты — по одному, со скрытым вводом на сервере (вводит человек заказчика или специалист 1С; в чат и почту
   значения не передаются). Режиму `extension` нужны оба набора: HTTP-сервис — `rotate-secret.sh set onec_hs_user`,
   `set onec_hs_password`, `set onec_hs_token`; OData — `set onec_user`, `set onec_password` (`pos_integration`:
   полная загрузка справочников, срезы цен и остатков, список фото). Пока набор введён не целиком, сервисы не
   пересоздаются (частичный набор — ошибка); без пары OData install.sh и update.sh предупреждают. Самоподписанный
   сертификат публикации 1С: `set onec_ca.pem --from-file <файл CA>`.
3. В `.env`: `ONEC_BASE_URL=https://<хост 1С>/<база>`, `ONEC_HS_PATH=hs/<имя>`; затем `dc up -d api worker`. Сервер
   вне магазина — адрес 1С в туннеле: `ONEC_BASE_URL=https://10.77.0.2/<база>` (туннель на роутере — LAN-адрес
   веб-сервера 1С), сертификат публикации — с этим адресом в SAN (§11.4).
4. Разовая перерегистрация плана обмена (16 §14.1 шаг 8, ночью):
   ```sh
   dc run --rm -v /opt/optomstroy/prod/onec-journal:/journal worker \
     node dist/cli/onec_reregister.js --confirm --reason "переход в рабочий режим" \
     --journal /journal/onec_reregister.journal.jsonl
   ```
5. `QR_PROVIDER=onec` — только после приёмки методов QR по контрольному примеру `18_ONEC_API_REQUEST.md` (DEPLOY-051).
6. Первичная загрузка и сверка количеств с 1С (16 §14.1 шаг 7), запись в журнале.

---

## 9. Журнал эксплуатации

Ведёт администратор заказчика (вне сервера): установки, обновления и откаты (версия, дата, кто, результат prod-smoke),
проверки восстановления (копия, числа строк, время), ротации секретов (что, когда, кто — без значений), инциденты.
Скрипты дублируют краткие записи в `/opt/optomstroy/prod/state/*.log` (тестовая копия — `/opt/optomstroy/test/state/`).

---

## 10. Тестовая копия на том же сервере (RM-I-002; 16 §11)

На тестовой копии проверяются обновления до рабочего контура (16 §10.3 шаг 1) и подключение 1С (§8.4). Состав — тот
же, что у рабочего контура (`compose.prod.yml` + `compose.staging.yml`), но свой проект `optomstroy-test`, свои сети,
тома, база `optomstroy_test` и секреты (никогда не копии рабочих, 16 §11). Портов не публикует: сайт
`api-test.<домен>` обслуживает общий caddy (`compose.edge.test.yml`, сеть `optomstroy_test_edge`).

| Параметр | Рабочий контур | Тестовая копия |
|---|---|---|
| Каталоги | `/opt/optomstroy/prod`, `/srv/optomstroy/prod` | `/opt/optomstroy/test`, `/srv/optomstroy/test` |
| `APP_ENV` | `prod` | `staging` (закреплён в `compose.staging.yml`) |
| SMS | SMSPro — отправляет только `worker` (api → `sms_outbox` → `worker` → SMSPro; `OTP_HMAC_SECRET_FILE` у `api` и `worker` — один файл `secrets/otp_pepper`; ADR-124) | не отправляются (`SMS_PROVIDER=fake`); вход — номера `AUTH_OTP_TEST_PHONES` с кодом `AUTH_OTP_TEST_CODE` (09 §5.8; шесть случайных цифр — код демо `246810` при `staging` pos-api не принимает) |
| 1С | рабочая база | только тестовая копия базы 1С (своя `ONEC_BASE_URL` и секреты) или не подключена; рабочая — никогда (install.sh/update.sh сверяют адрес). Без 1С можно `ONEC_MODE=fixtures` (фикстуры 1С, как на стенде ADR-125): тогда install.sh/update.sh собирают образ стадии `test-fixtures` (`/contracts/onec/fixtures` в образе) и требуют для тестовой копии свой `API_TAG` (по умолчанию `<версия>-<sha>-fixtures`) — прод-образ того же тега без фикстур не подходит, а образ с меткой фикстур рабочий контур отклоняет (FQ-INT-08); в рабочем контуре `fixtures` — отказ (OPS-027) |
| `pin_pepper` | у `api` и `worker` | так же (CryptoModule общий: без него `worker` при `staging`/`prod` не стартует) |
| Память | профиль по объёму сервера | `postgres` 512M (shared_buffers 128MB), `api` 512M, `worker` 512M |
| Копии | §4, вне сервера; непрерывная копия WAL (`BACKUP_PITR=on`, §4.8) | только локальные, 7 суток, в 05:45; без непрерывной копии (`BACKUP_PITR=off`) |

Нужно: от 6 ГБ памяти на сервере (рекомендуемый — 8 ГБ; иначе тестовая копия — на другом хосте, 16 §11), A-запись
`api-test.<домен>` на тот же внешний IP, номера сотрудников для входа.

### 10.1. Установка

После рабочего контура, из того же каталога релиза:

```sh
cd /opt/optomstroy/src/<версия>
sudo bash infra/scripts/install.sh --contour test --domain api-test.<домен> --age-recipient age1… \
     --test-phones +996XXXXXXXXX,+996YYYYYYYYY [--admin-phone +996XXXXXXXXX --admin-name "…"]
```

Скрипт создаёт `/opt/optomstroy/test/.env` из `prod.env.example` с заменами `infra/env/test.env.example`, свои
секреты (SMSPro — пустые файлы: не используются), запускает контур, пишет `CADDY_TEST_SITE_ADDRESS` в `.env` рабочего
контура и пересоздаёт общий caddy с сайтом теста. Код входа тестовых номеров — в `.env` тестовой копии
(`sudo grep AUTH_OTP_TEST_CODE /opt/optomstroy/test/.env`), в журнал не печатается. Сборка `pos-app` для теста — с
адресом `https://api-test.<домен>/api/v1` (профиль `staging`).

### 10.1а. Тестовый стенд на Windows-сервере заказчика (ADR-125)

На Windows VPS заказчика (Windows Server 2022, без Docker и Hyper-V, порты 80/443 — у Apache заказчика) стенд
`optomstroy-test` ставится не `install.sh`, а Windows-комплектом: `install.ps1 -Stand` (`infra/windows/README.md` §7.1;
профиль `infra/env/stand.env.example`): `APP_ENV=staging`, `ONEC_MODE=fixtures`, `QR_PROVIDER=bank` +
`BANK_QR_ADAPTER=sandbox`, SMS без трат (`SMS_PROVIDER=fake`, вход — `+996700000001…05` с кодом из
`config\api.env`), адрес `https://api-test.37.114.51.144.sslip.io` (постоянный — `api-test.optomstroy.kg`
`[ПРЕДЛОЖЕНИЕ]`; сертификат — у Apache заказчика, Q-384). Ставит администратор заказчика по
`docs/customer/WINDOWS_SERVER_INSTALL.md`, мы проверяем под `posdeploy` по SSH (`status.ps1`, журналы, `/health`;
SSH 23.11.2026 недоступен — Q-386). Каждая команда, меняющая сервер, — после явного «да» пользователя (16 §6.3).
Настоящая SMS на стенде — только после секретов SMSPro от заказчика (Q-385) и письменного «да» пользователя
(`infra/windows/README.md` §7.1, `docs/integration/smspro_connect.md` §4–§5).

Уведомления QR банка (`QR_PROVIDER=bank`, 08 §6.2) и что делать: «Оплата QR по неизвестному референсу» (кассирам и
администраторам) — найти операцию в выписке, строка есть в отчёте «Сверка QR» (`unknownOperations`), деньги —
`confirm-manual` нужного платежа или документом в 1С; «Сверка QR: повторная оплата» — на один платёж пришли две
операции банка (`payment_webhook_events.processing_error = duplicate_payment`), лишнюю сумму оформить в 1С возвратом
или авансом (Q-012); «Документ оплаты 1С: ссылка занята» — 1С вернула один документ на два платежа: запись
`DUPLICATE_SUSPECTED` (`payload.code = ONEC_REF_CONFLICT`) в журнале синхронизации, разбор со специалистом 1С. Лимит
вебхука RL-WEBHOOK — 600 запросов в минуту с IP (`429`).

### 10.2. Обновление: сначала тест, потом рабочий контур

```sh
cd /opt/optomstroy/src/<новая версия>
sudo bash infra/scripts/update.sh --contour test --tag <новая версия>      # тестовая копия, проверка (§3.3)
sudo bash infra/scripts/update.sh --tag <новая версия>                     # рабочий контур
```

Файлы общего caddy обновляет обновление рабочего контура. Откат тестовой копии —
`sudo /opt/optomstroy/test/bin/update.sh --rollback`.

### 10.3. Копия рабочей базы в тестовой копии

Ежемесячная проверка восстановления по умолчанию — во временную базу (§4.4). По согласованию с заказчиком (данные
клиентов, Q-027) копию рабочей базы можно восстановить в тестовую копию — тогда проверяется и запуск приложения.

**Тестовая копия на сервере вне КР** (например, во Франкфурте, а рабочий контур — в Кыргызстане): копию рабочей базы
туда не восстанавливать — это перенос персональных данных за рубеж (16 DEPLOY-048; 15 ADR-119 — до решения о месте
сервера, вопрос Q-371). На таком сервере — только вымышленные данные.

Восстановление в тестовую копию на том же сервере:

```sh
sudo /opt/optomstroy/test/bin/restore-db.sh --identity /media/<носитель>/optomstroy-backup.key \
     --dump /srv/optomstroy/prod/backups/<файл>.dump.age
```

Войти смогут только номера `AUTH_OTP_TEST_PHONES` (SMS не отправляются). После проверки — обратно на чистую базу
(новая копия теста или повторная установка тестовой копии с пустым `/srv/optomstroy/test/pgdata`), если так решит
заказчик.

### 10.4. Смена имени и удаление

Смена имени сайта теста: `CADDY_SITE_ADDRESS` и `PUBLIC_BASE_URL` в `/opt/optomstroy/test/.env`,
`CADDY_TEST_SITE_ADDRESS` в `/opt/optomstroy/prod/.env`, затем `sudo /opt/optomstroy/test/bin/dc up -d api worker` и
`dc-edge up -d --force-recreate caddy`. Удаление: `sudo /opt/optomstroy/test/bin/dc down` (без `-v`), пустой
`CADDY_TEST_SITE_ADDRESS` в `.env` рабочего контура, `dc-edge up -d --force-recreate caddy`; каталоги
`/opt/optomstroy/test` и `/srv/optomstroy/test` — по решению заказчика.

---

## 11. Сервер вне магазина (дата-центр): туннель к 1С и firewall

Сценарий C-1 (16 §3.3, §12.2): сервер POS — в дата-центре (2026-11-19 заказчик предложил сервер во Франкфурте), 1С —
в магазине. Кассы, планшет и приложение покупателя ходят на сервер через интернет; сервер весь день вызывает публикацию
1С (заказы, оплаты, возвраты — сразу; остатки и цены — каждые 5–30 минут; ночью — тяжёлые задания) по HTTPS **внутри
туннеля WireGuard, который начинает магазин**. Всё ниже — только по письменному разрешению заказчика
(§2.1) и по согласованию (16 §6.3 №3–4; в магазине — №9). Комплект туннель, firewall и пояс **не настраивает**: команды
выполняет DevOps вручную, `bin/host-net-check.sh` только проверяет.

Сервер вне Кыргызстана: настоящие данные (телефоны, имена, долги, выгрузка 1С с персональными данными) — только после
решения владельца о месте сервера (16 DEPLOY-048; 15 ADR-119, вопрос Q-371); до него на сервере только вымышленные
данные. Снимки (snapshots) сервера в панели провайдера не включать без решения владельца (вопрос Q-376): это
незашифрованная копия всех данных у провайдера, а наши копии шифруются (§4).

### 11.1. Схема и адреса

Адреса туннеля — предложение (16 §12.2), не значения заказчика:

| Адрес | Узел |
|---|---|
| `10.77.0.1` | сервер POS (`wg0`) |
| `10.77.0.2` | магазин: компьютер с веб-публикацией 1С (по умолчанию) или роутер магазина — где кончается туннель, решают владелец и администратор 1С (Q-031) |
| `10.77.0.3`–`10.77.0.9` | постоянные узлы в КР (NAS для копии вне сервера, хост монитора) — только если заказчик выбрал такое место (§11.8) |
| `10.77.0.10` и дальше | администраторы исполнителя, по одному адресу на человека |

UDP-порт туннеля — `<WG_PORT>`, согласуется с заказчиком. Подсеть не должна пересекаться с сетями Docker, частной
сетью провайдера и сетью магазина: `docker network inspect optomstroy_prod_edge optomstroy_prod_backend --format
'{{json .IPAM.Config}}'`, `ip route`, адреса LAN магазина. Контейнеры выходят в туннель через NAT хоста (сеть `edge`
не `internal`), правки compose не нужны. Пропал интернет в магазине — кассы не оформляют заказы, оплаты и продажи в
долг до восстановления связи (16 §3.3); резервный канал в магазине — решение владельца (вопрос Q-375); при переходе на
него туннель переезжает сам (roaming), на сервере ничего не меняется.

### 11.2. Сервер: пояс и туннель

Из каталога релиза (`cd /opt/optomstroy/src/<версия>`), от root:

```sh
timedatectl set-timezone Asia/Bishkek          # журналы хоста — по Бишкеку (16 H-11, DEPLOY-021)
timedatectl                                    # Time zone: Asia/Bishkek; System clock synchronized: yes
systemd-analyze calendar '*-*-* 06:00:00 Asia/Bishkek'   # systemd понимает пояс в таймере копии сертификатов
apt-get install -y wireguard-tools
install -d -m 700 /etc/wireguard
( umask 077; wg genkey > /etc/wireguard/server.private )                  # приватный ключ: не печатать, не копировать
wg pubkey < /etc/wireguard/server.private > /etc/wireguard/server.public  # открытый — магазину (не секретный)
install -m 600 -o root -g root infra/host/wireguard/wg0.conf.example /etc/wireguard/wg0.conf
# в /etc/wireguard/wg0.conf заменить все <…>: <WG_PORT>, открытые ключи магазина и администраторов
systemctl enable --now wg-quick@wg0 && wg show wg0
```

Таймер копии сертификатов (`optomstroy-caddy-backup.timer`) закреплён за 06:00 по Бишкеку при любом поясе сервера;
пояс хоста всё равно ставится на Бишкек, иначе журналы хоста идут по чужому времени. Приватный ключ сервера лежит
отдельным файлом и подставляется командой `PostUp`, поэтому в `wg0.conf` секрета нет.

### 11.3. Firewall сервера (по согласованию)

Порядок важен — иначе можно потерять доступ к серверу:

1. Проверить вход в **консоль провайдера** (KVM или rescue в панели провайдера): видно приглашение входа на сервер.
   Кто у заказчика держит доступ к панели — записать в журнал эксплуатации (§9).
2. Поднять туннель администратора (свой `[Peer]` с адресом `10.77.0.10` в `wg0.conf`, `systemctl restart wg-quick@wg0`)
   и войти по SSH **через туннель**: `ssh <пользователь>@10.77.0.1`.
3. Только после п. 1 и 2 — правила ufw (комментарии правил — латиницей):

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow proto udp from 0.0.0.0/0 to any port <WG_PORT> comment 'WireGuard tunnel'
sudo ufw allow in on wg0 proto tcp from 10.77.0.10 to any port 22 comment 'SSH admin via tunnel'
sudo ufw allow proto tcp from 0.0.0.0/0 to any port 80,443 comment 'caddy IPv4 only'
sudo ufw enable && sudo ufw status verbose
```

Если согласован вход по SSH не через туннель, а с постоянных адресов администраторов, — вместо правила `in on wg0`:
`sudo ufw allow proto tcp from <IPv4 администратора> to any port 22 comment 'SSH admin'`. После `ufw enable` SSH из
интернета закрыт; запасной вход — консоль провайдера.

- 80/443 открываются только для IPv4, AAAA-записи для `api.<домен>` и `api-test.<домен>` не создаются, пока сети
  Docker без IPv6: иначе клиенты IPv6 приходят к api адресом моста Docker — ломаются лимиты по IP и правило
  `/health/ready` для частных адресов.
- Docker публикует 80/443 мимо ufw (16 §4.2): фактические порты — `sudo ss -tulpn`, `sudo iptables -S DOCKER-USER`,
  `bin/host-net-check.sh`; снаружи (с компьютера вне сервера) открыты только TCP 80, 443 и UDP `<WG_PORT>`, по IPv6 —
  ничего (16 DEPLOY-008).
- Фильтр в панели провайдера (если он есть) — те же порты: TCP 80, 443, UDP `<WG_PORT>`.

### 11.4. Магазин: туннель и публикация 1С

Ставит администратор магазина с согласия владельца или администратора 1С (16 §6.3 №9); DevOps подсказывает по
видеосвязи. Шаблон и команды — `infra/host/wireguard/store-peer.conf.example`:

- WireGuard для Windows, «Добавить пустой туннель» (ключ создаётся на месте, нам передаётся только открытый ключ),
  имя туннеля `pos`; `Address = 10.77.0.2/32`, `AllowedIPs = 10.77.0.1/32` (никогда `0.0.0.0/0`),
  `Endpoint = <IPv4 сервера>:<WG_PORT>`, `PersistentKeepalive = 25`; служба `WireGuardTunnel$pos` поднимается после
  перезагрузки без входа пользователя (проверить после первой перезагрузки).
- Публикация 1С — только с сервера: правило Windows Firewall «входящий 443 только с `10.77.0.1`» (других разрешений на
  443 нет), на веб-сервере — `Require ip 10.77.0.1` (Apache) или ограничение IP (IIS); сертификат публикации — с адресом
  `10.77.0.2` в SAN (туннель на компьютере 1С; вариант с роутером — ниже), его CA — `rotate-secret.sh set onec_ca.pem --from-file <файл>` (§8.4 п. 2); в интернет публикация
  не открывается, на роутере магазина ничего не пробрасывается.
- **Компьютер 1С включён и не засыпает круглосуточно**: днём сервер сразу передаёт в 1С заказы, оплаты и возвраты и
  каждые 5–30 минут читает остатки и цены, ночью (`SYNC_NIGHT_WINDOW`, 01:00–06:00 по Бишкеку) — тяжёлые задания;
  сигнал о туннеле — в любое время. Схема питания — без сна; перезагрузки Windows Update — по согласованию, вне часов
  магазина и вне 01:00–06:00.
- На сервере — открытый ключ магазина в `[Peer]` магазина в `/etc/wireguard/wg0.conf`, затем
  `sudo systemctl restart wg-quick@wg0`. В `.env` — `ONEC_BASE_URL=https://10.77.0.2/<база>` (§8.4 п. 3).
- Туннель на роутере магазина (вариант б): тот же шаблон на роутере, фильтр «из туннеля только `10.77.0.1` → LAN-адрес
  веб-сервера 1С, TCP 443», на сервере в `AllowedIPs` пира магазина добавляется `<LAN-адрес веб-сервера 1С>/32`,
  `ONEC_BASE_URL` — с этим LAN-адресом, сертификат публикации — с этим LAN-адресом в SAN (не `10.77.0.2`).

### 11.5. Проверка на сервере

- `sudo wg show wg0` — у пира магазина `latest handshake` моложе 3 минут.
- `sudo /opt/optomstroy/prod/bin/host-net-check.sh` — без замечаний. Коды замечаний: `TZ_HOST`, `NTP`,
  `LISTEN_UNEXPECTED`, `FIREWALL`, `AAAA`, `WG_SERVICE`, `WG_CONF_PERMS`, `WG_PORT_CLOSED`, `WG_ALLOWEDIPS_WIDE`,
  `WG_ROUTE`, `WG_HANDSHAKE_STALE`, `ONEC_HTTPS` (описание — `host-net-check.sh --help`); код выхода 0 — замечаний нет,
  1 — есть. Скрипт ничего не меняет: команды в тексте замечаний — подсказки, их выполняет DevOps по согласованию.
- Метрики (§6.4): при заданном `ONEC_BASE_URL` и интерфейсе `wg0` в журнале `journalctl -u optomstroy-metrics`
  появляется `wg_onec_handshake=<секунды>`.

### 11.6. Сбои

| Симптом | Действия |
|---|---|
| сигнал `WG_HANDSHAKE_STALE` (Healthchecks «metrics», в любое время); заказы, оплаты и возвраты копятся в очереди к 1С | в магазине: включён ли компьютер 1С (или роутер), запущена ли служба `WireGuardTunnel$pos`, есть ли интернет; перезапуск туннеля — на стороне магазина (16 §15.1). На сервере: `sudo wg show wg0`, `sudo systemctl status wg-quick@wg0`, `sudo ufw status` (UDP-порт), фильтр в панели провайдера. Заказы, оплаты и возвраты из очереди уйдут в 1С сами после восстановления туннеля (§8.2). Кто в магазине получает сигнал днём и ночью и может включить компьютер 1С — решает владелец (16 §12.2, 14 Q-032) |
| пропал интернет в магазине днём | кассы не оформляют заказы, оплаты и продажи в долг до восстановления связи или переключения на резервный канал; приложение покупателя и SMS работают (сервер в дата-центре); туннель переедет сам |
| большие ответы 1С «зависают», а `…/pos/v1/health` отвечает | MTU: `MTU = 1280` в `wg0.conf` сервера и в туннеле магазина, перезапуск туннеля на обеих сторонах |
| туннель не поднимается из сети магазина, а через 4G поднимается (или наоборот) | сеть ограничивает UDP: другой UDP-порт по согласованию с заказчиком (ufw, фильтр провайдера, `ListenPort`, `Endpoint` магазина) |
| плановые работы провайдера | ночь по Европе — это утро и день по Бишкеку (05:00–11:00): попросить провайдера присылать уведомления, работы — вне часов магазина |

### 11.7. Проверка из магазина до запуска

С компьютера магазина — по основному каналу и через 4G (если резервный канал есть):

```bat
ping -n 50 <IPv4 сервера>
pathping <IPv4 сервера>
```

и рукопожатие WireGuard по каждому каналу (`sudo wg show wg0` на сервере, пока туннель магазина активен по этому
каналу). Задержку, потери и результат рукопожатия — в журнал эксплуатации (§9). Задержка Бишкек — Франкфурт между
дата-центрами ≈ 0,1 с, из сети магазина больше `[ОЦЕНКА]`; при 10 Мбит/с весь обмен устройств идёт через интернет —
ориентир около 10 активных устройств `[ОЦЕНКА]`, первую загрузку каталога на новое устройство — вне часов пик.

### 11.8. Копия вне сервера и монитор при сервере в дата-центре

Хранилище копии вне сервера (§4.3) и хост монитора (§6.4) — в Кыргызстане (16 §12.2, DEPLOY-048) и никогда не на самом
сервере. Для сервера в дата-центре удобнее узлы вне туннеля — облачное хранилище или небольшой арендованный сервер в КР
(доступны круглые сутки; один хост может нести и копию, и монитор). NAS или офисный компьютер в магазине возможны
только как постоянный узел туннеля (адреса `10.77.0.3`–`10.77.0.9`, закомментированный блок в `wg0.conf.example`; узел
1С пропускает только 443): копия прерывается при каждом обрыве интернета в магазине, восстановление фото оттуда
медленное (≈ 22 ч на 100 ГБ при 10 Мбит/с `[ОЦЕНКА]`), а сигнал о туннеле шёл бы через тот же туннель. Выбор места —
за владельцем (вопросы Q-033, Q-103). На сервере с одним диском эта копия — единственная защита от отказа диска (§2.2):
она должна работать до появления настоящих данных.
