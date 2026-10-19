# 16. План развёртывания и эксплуатации backend «Оптомстрой POS» (16_DEPLOYMENT_PLAN)

Версия 1.7 · Дата 2026-10-19 (сверка с ядром R0 v1.8 §23 — §21.4; с v1.6 §21 и v1.7 §22 — §21.3; независимая проверка, волна 4 — журнал §22, доработка §10.7–§10.9 — §22.1; сверка с v1.4 — §21.2; с v1.3 — §21.1) · Статус: черновик для утверждения заказчиком

**Роль автора:** DevOps-инженер (поддержка главного архитектора).
**Этап:** ЭТАП 1 — подготовка ТЗ. Ничего не устанавливалось и не запускалось; документ — только план, требования и спецификации. Любая установка на сервер заказчика возможна **только** после сообщения «ТЗ УТВЕРЖДЕНО. НАЧИНАЙ РАЗРАБОТКУ» **и** отдельного письменного разрешения заказчика на работы на сервере [ПОДТВЕРЖДЕНО: мастер-промт, строки 963/976, 967/980 → SRC-F-139, SRC-F-145].

**Входные материалы**
- `docs/research/R0_DECISION_KERNEL.md` — ядро решений (D-01, D-03, D-06, D-24, D-28, D-29, D-30, D-33, D-34, D-35, D-36, D-37, D-44…D-48; вопросы Q-010, Q-011, Q-022, Q-023, Q-029…Q-033, Q-039; NFR §13; дополнения v1.1 §16, v1.2 §17, v1.3 §18, v1.4 §19, v1.5 §20, v1.6 §21, v1.7 §22 и v1.8 §23 — приоритет над текстом документа (более поздний — выше); по §18.1 этот документ (§4.3) — канонический владелец словаря переменных окружения).
- `docs/research/R8_SERVER_DEPLOYMENT_RESEARCH.md` — целиком (аудит, сценарии, ресурсы, изоляция, безопасность, бэкапы, мониторинг, обновления, VPS, план развёртывания).
- `docs/research/R5_BACKEND_RESEARCH.md` §7 — состав compose, переменные, ресурсы, логи.
- `docs/research/R1_1C_INTEGRATION_RESEARCH.md` §7 — публикация 1С на веб-сервере, сеть магазина → backend.
- `docs/research/R6_AUTH_SECURITY_RESEARCH.md` §8 — резервное копирование и восстановление (RPO/RTO, шифрование, 3-2-1).
- `docs/research/R2_SMSPRO_RESEARCH.md` §11 (имена переменных `SMSPRO_*`, `SMS_PROVIDER`).
- Мастер-промт заказчика `docs/specification/source/MASTER_PROMPT_extracted.md`: строки 955–980 («Использование существующего сервера», оба повтора), 445 (резервное копирование), 505 (сборка целевых платформ), 532 (инструкция по установке, настройке и развёртыванию).
- Реестр исходных требований: `REQ_REGISTER_F.md` (SRC-F-129 … SRC-F-145, включая подпункты SRC-F-134a…134e, SRC-F-138a…138c, SRC-F-139a, SRC-F-142a…142b), `REQ_REGISTER_D.md` (SRC-D-087, SRC-D-087a, SRC-D-141, SRC-D-171), `REQ_REGISTER_E.md` (SRC-E-179h, SRC-E-179i — для перекрёстной ссылки).

**Связанные документы**
- `05_ONEC_INTEGRATION.md` — протокол обмена с 1С (OData, HTTP-сервис расширения, план обмена) — здесь только сеть и публикация.
- `06_ARCHITECTURE.md` — компоненты `pos-api`, `pos-worker`, `pos-db`, `pos-proxy`, модули D-06.
- `08_API_SPECIFICATION.md` — `/health`, `/health/ready`, `/openapi.json`.
- `11_SECURITY_PRIVACY.md` — секреты, аудит, ПДн, RBAC и серверная проверка прав (SEC-027…SEC-029); здесь — только серверный hardening и граница «proxy не авторизует» (DEPLOY-049).
- `12_TEST_PLAN.md` — smoke-тесты, restore-drill, тесты безопасности инфраструктуры.
- `13_IMPLEMENTATION_ROADMAP.md` — место этапа «Развёртывание» в календаре.
- `14_OPEN_QUESTIONS.md`, `15_DECISION_LOG.md` (ADR-033…ADR-035 ↔ D-33…D-35), `17_TRACEABILITY_MATRIX.md`.

Легенда меток достоверности (обязательна): `[ПОДТВЕРЖДЕНО: источник]` — проверено по официальной документации или команде; `[ТИПОВО: контекст, требует проверки]` — верно для типовых версий; `[НЕ ПОДТВЕРЖДЕНО]` — оценка; `[РЕШЕНИЕ: D-xx]` — решение ядра; `[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-xxx]`. Все утверждения о сервере заказчика — `[НЕ ПОДТВЕРЖДЕНО]` до выполнения чек-листа раздела 2 (доступ к серверу не предоставлен — Q-030).

---

## 1. Краткое содержание (итог для ТЗ по SRC-F-144)

1. **Что размещается на сервере заказчика** (сценарий A по умолчанию, [РЕШЕНИЕ: D-33]): один Docker Compose-проект `optomstroy-prod` с сервисами `caddy` (reverse-proxy, автоматический TLS, отдача фото), `api` (NestJS, модульный монолит — `pos-api` [РЕШЕНИЕ: D-45]), `worker` (тот же образ в роли воркера, `WORKERS_ENABLED=true`; pg-boss: синхронизация с 1С, outbox, фоновые задачи — `pos-worker`; очереди, rate-limit OTP и идемпотентность — в PostgreSQL, **без Redis** [РЕШЕНИЕ: D-44]), `migrate` (одноразовый контейнер миграций), `postgres` (PostgreSQL 17, собственный экземпляр — `pos-db`), `backup` (суточные дампы и копия вне сервера); опционально `pgadmin` только на `127.0.0.1`. Плюс, насколько позволяют ресурсы, второй проект `optomstroy-test` (тестовое окружение) [ПОДТВЕРЖДЕНО: SRC-F-141].
2. **Какие ресурсы нужны** [РЕШЕНИЕ: D-34]: минимум 2 vCPU / 4 GB RAM / 80 GB SSD (только prod, фото ≤ 30 GB); рекомендовано 4 vCPU / 8 GB RAM / 160–250 GB SSD (prod + test, фото до 100 GB, запас на 2–3 года); внешнее хранилище бэкапов ≥ 2 × (БД + фото). Наружу открываются только порты 80/443 (и SSH для администрирования, ограниченный по IP/VPN).
3. **Какие компоненты остаются внешними**: 1С:Предприятие заказчика (в сети магазина; источник истины мастер-данных); SMSPro Nikita KG (HTTPS-API, OTP); ACME-центр сертификации (Let's Encrypt / ZeroSSL) для TLS; внешнее хранилище бэкапов (S3-совместимое / второй хост / NAS — Q-033); внешний монитор доступности и cron-проверок — по умолчанию **self-hosted** Uptime Kuma и Healthchecks на другом хосте **в КР**, канал алертов — e-mail через почтовый сервер в КР; зарубежные SaaS (Healthchecks.io, Telegram и т. п.) — только после ADR с оценкой по 6 пунктам 11 PRIV-020 (11 PRIV-001, PRIV-019; Q-103, Q-032); содержимое алертов — без ПДн (раздел 9); реестр Docker-образов проекта; API Бакай Банка — условно (Q-014). Flutter-приложение (`pos-app`) на устройствах сотрудников.
4. **Как будет происходить связь с 1С** [РЕШЕНИЕ: D-28, D-33; ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-031]: backend обращается к 1С **только** через опубликованные на веб-сервере HTTP-сервисы расширения и стандартный OData (разведённые пользователи ИБ с минимальными правами: `pos_integration` — только чтение OData, `pos_hs` — только HTTP-сервис, 12.1; HTTPS), никогда — к СУБД 1С. Три варианта сети: (a) сервер в LAN магазина — прямой доступ по локальному адресу; (b) backend вне LAN — туннель WireGuard, **инициируемый со стороны магазина** (входящие порты в магазине не нужны); (c) «исходящий обмен» — 1С сама вызывает HTTPS-эндпоинты backend по регламентному заданию. Выбор — после аудита сервера и ответа 1С-специалиста (раздел 12).
5. **Ничего не меняется в существующих службах** заказчика: чужие конфигурации, порты, DNS, firewall и базы данных не редактируются без предварительного согласования; перечень из 12 пунктов для согласования — раздел 6.3 [ПОДТВЕРЖДЕНО: SRC-F-135, SRC-F-136].
6. **Безопасность**: БД не публикуется в интернет; HTTPS/HSTS; секреты — файлы `600` вне git, подключаемые через Compose `secrets:` (безопасное хранение секретов — SRC-F-138a); SSH только по ключам, firewall, fail2ban, автообновления безопасности (ограничение доступа — SRC-F-138b); контейнеры не от root; логи без секретов (раздел 7); все проверки прав выполняются в `api` на каждом запросе, reverse-proxy авторизацию не выполняет (серверная проверка прав — SRC-F-138c, DEPLOY-049, 11_SECURITY_PRIVACY SEC-028/SEC-029) [ПОДТВЕРЖДЕНО: SRC-F-137, SRC-F-138, SRC-F-138a, SRC-F-138b, SRC-F-138c].
7. **Эксплуатация** (разделы 8–11, 15): бэкапы `pg_dump -Fc` ежедневно + копия вне сервера + ежемесячная проверка восстановления (RPO ≤ 24 ч / RTO ≤ 4 ч в R1, [РЕШЕНИЕ: D-35], Q-033); мониторинг `/health`, `/health/ready`, Healthchecks для cron, алерты о падении синхронизации с 1С; обновления с неизменяемыми тегами образов, миграции expand→contract, бэкап перед миграцией, smoke-тест и откат по тегу; runbooks на типовые инциденты.
8. **Если сервер слаб или небезопасен** — таблица минимальных улучшений и сравнение с VPS по подтверждённым тарифам (раздел 13) [ПОДТВЕРЖДЕНО: SRC-F-140].
9. **Артефакт этапа 1** — только этот план развёртывания и требования к серверу/эксплуатации (без действий на сервере) [ПОДТВЕРЖДЕНО: SRC-F-139a, DEPLOY-026]. **Артефакт этапа 2** — «Инструкция по установке, настройке и развёртыванию» (SRC-D-171) строится из разделов 4, 7, 8, 10, 14, 15 этого документа; план первичного развёртывания — раздел 14.

---

## 2. Чек-лист аудита сервера (выполняет заказчик или его администратор)

Назначение: заказчик не предоставил доступ к серверу; характеристики **не выдумываются** [ПОДТВЕРЖДЕНО: SRC-F-131]. Ниже — команды, которые заказчик выполняет сам, с объяснением результатов простым языком [ПОДТВЕРЖДЕНО: SRC-F-132]. Охват проверок соответствует перечню промта: ОС, CPU, RAM, диски, сетевые настройки, запущенные службы, используемые порты, домены, текущие приложения [ПОДТВЕРЖДЕНО: SRC-F-130].

### 2.1. Правила выполнения

| Правило | Пояснение |
|---|---|
| Команды **только читают** состояние | Ничего не устанавливают и не меняют. Единственное исключение — тест скорости диска (п. L-19): выполняется только с согласия, только в свободный каталог, файл удаляется сразу. |
| Не присылать секреты | В выводе могут быть IP-адреса, имена пользователей, имена баз — это нормально. **Не присылать** пароли, содержимое `.env`, ключи, строки подключения с паролями. |
| Записывать вывод в файл | Linux: `script -q audit_$(hostname)_$(date +%F).txt` перед началом, `exit` в конце. Windows: `Start-Transcript -Path C:\audit.txt` … `Stop-Transcript`. |
| Права | Linux — пользователь с `sudo`; Windows — PowerShell «от имени администратора». |
| Передача | Файл передаётся по защищённому каналу (не в публичный чат). |

### 2.2. Linux (команды и толкование)

| # | Зачем | Команда | Как прочитать результат простым языком | Что считать проблемой |
|---|---|---|---|---|
| L-1 | Ядро и архитектура | `uname -a` | `x86_64` — обычный сервер; `aarch64` — ARM (нужны multi-arch образы). Число после имени — версия ядра. | 32-битная система (`i686`) — Docker Engine не поддерживается [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/]. Ядро старше 5.x — инженерный порог комфортной работы overlay2/PostgreSQL [НЕ ПОДТВЕРЖДЕНО]. |
| L-2 | Дистрибутив и версия | `cat /etc/os-release` | `PRETTY_NAME` — название и версия ОС. | Ubuntu < 22.04, Debian < 12, CentOS Linux 7/8 — без обновлений безопасности (CentOS 8 EOL 2021-12-31, CentOS 7 EOL 2024-06-30 [ПОДТВЕРЖДЕНО: centos.org, redhat.com]). Ubuntu 22.04 — standard support до 2027 г., 24.04 — до 2029 г., 26.04 — до 2031 г. (Canonical указывает окончание в апреле–июне соответствующего года; точную дату уточнить на дату аудита) [ТИПОВО: https://ubuntu.com/about/release-cycle, уточнить на дату аудита]; Debian 13 — stable, 12 — oldstable [ПОДТВЕРЖДЕНО: https://www.debian.org/releases/]. |
| L-3 | Процессор | `lscpu` | `Model name` — модель; `CPU(s)` — число логических ядер; `Hypervisor vendor` — если заполнено, сервер сам является виртуальной машиной. | < 2 ядер [НЕ ПОДТВЕРЖДЕНО: инженерный порог]; сервер-VM без вложенной виртуализации — сценарий B-3 невозможен. |
| L-4 | Число CPU | `nproc` | Просто число. | < 2. |
| L-5 | Память | `free -h` | В строке `Mem:` — `total` (всего), `available` (реально свободно); строка `Swap:`. | `available` < 2 GB; `total` < 4 GB; swap = 0 при RAM < 8 GB. |
| L-6 | Диски и файловые системы | `df -hT` | Для `/` и `/var` (там живут Docker и БД): `Size`, `Avail`, `Use%`, `Type` (`ext4`, `xfs` — хорошо). | `Avail` < 40 GB; `Use%` > 80 %; данные на `vfat`/`ntfs`. |
| L-7 | Физические диски | `lsblk -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT,MODEL` | `ROTA=1` — вращающийся HDD; `ROTA=0` — SSD/NVMe. | БД на HDD — медленный поиск по 50 000 SKU; единственный диск без RAID/бэкапа. |
| L-8 | Сетевые интерфейсы | `ip a` | Адреса `inet`. `10.x`, `192.168.x`, `172.16–31.x` — локальная сеть; другие — вероятно публичный адрес. | Сервер только в локальной сети без публичного IP → нужен VPN или сценарий C. |
| L-9 | Публичный IP | `curl -4 -s https://ifconfig.me ; echo` (или `https://api.ipify.org`) | Адрес, под которым сервер виден из интернета. Если совпадает с L-8 — прямой публичный IP; если нет — сервер за NAT. | За NAT без проброса портов → входящий HTTPS невозможен без согласования с провайдером/роутером. |
| L-10 | Занятые порты | `ss -tulpn` (или `netstat -tulpn`) | `Local Address:Port` — какой порт слушается, `Process` — кем. `0.0.0.0:` — доступен со всех интерфейсов, `127.0.0.1:` — только локально. | Заняты 80/443 (конфликт с нашим reverse-proxy); 5432 на `0.0.0.0` (чужая БД доступна извне — сообщить владельцу); 1540/1541/1560–1591 — типовые порты кластера 1С [ТИПОВО: неофициальные источники; 1С-специалисту подтвердить по руководству администратора]. |
| L-11 | Запущенные службы | `systemctl list-units --type=service --state=running` | Список: `nginx`, `apache2`/`httpd`, `postgresql`, `docker`, `srv1cv8*` (сервер 1С), `mysql` и т. п. | Любая служба, с которой придётся делить порты или ресурсы. |
| L-12 | Docker | `docker --version ; docker compose version ; docker ps ; docker system df` | Версия Engine и Compose v2; запущенные контейнеры; занятое место. `command not found` — Docker нет (это нормально). | Compose v1 (`docker-compose`, Python) — устарел; `docker system df` > 50 % диска. |
| L-13 | Веб-серверы и публикации | `ls -la /etc/nginx /etc/nginx/sites-enabled /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null` | Какие сайты уже опубликованы (возможно — публикация 1С на Apache). | Публикация 1С на 80/443 этого же хоста — нужен отдельный поддомен и согласованное сосуществование. |
| L-14 | Firewall | `sudo ufw status verbose ; sudo iptables -S ; sudo nft list ruleset` | `Status: active` и правила `ALLOW`. Если `iptables -S` показывает только `-P … ACCEPT` — файрвола нет. | Файрвола нет; политика `ACCEPT` на всё; 22 открыт всему миру без fail2ban. |
| L-15 | Планировщик | `crontab -l ; sudo ls -la /etc/cron.d /etc/cron.daily ; systemctl list-timers` | Существующие задания (бэкапы, выгрузки 1С, обновления). | Нет ни одного бэкап-задания; задания, пишущие в те же каталоги, что планируем мы. |
| L-16 | Монтирование | `cat /etc/fstab` | Какие диски и сетевые папки (`nfs`, `cifs`) монтируются при загрузке. | Данные на сетевой папке — не подходит для БД. |
| L-17 | Аптайм и нагрузка | `uptime` | `up N days`; `load average: a, b, c` за 1/5/15 мин — сравнить с числом CPU (L-4). | Load стабильно > числа CPU — сервер перегружен. Аптайм > 365 дней — ядро давно не обновлялось. |
| L-18 | Ошибки железа | `sudo dmesg -T \| tail -n 100 ; sudo journalctl -p err -b \| tail -n 50` | Ищем `I/O error`, `EXT4-fs error`, `Out of memory`, `MCE`. | Ошибки диска/памяти — железо ненадёжно. |
| L-19 | Скорость диска (**только с согласия**) | `cd /var/tmp && dd if=/dev/zero of=./ddtest bs=1M count=1024 oflag=direct status=progress ; rm -f ./ddtest` ; если `fio` уже установлен: `fio --name=rnd --ioengine=libaio --rw=randrw --bs=4k --size=512m --numjobs=1 --iodepth=16 --direct=1 --runtime=20 --time_based --filename=/var/tmp/fiotest ; rm -f /var/tmp/fiotest` | `dd` — МБ/с последовательной записи; `fio` — IOPS случайного чтения/записи. | Запись < 100 MB/s или 4k IOPS < 2 000 — медленный диск. **Никогда** не указывать `of=/dev/sdX` — это уничтожит диск. Аудит ничего не устанавливает: нет `fio` — ограничиться `dd`. |
| L-20 | Существующие бэкапы | `ls -la /var/backups /backup /mnt 2>/dev/null` | Есть ли куда-либо регулярные копии. | Бэкапов нет или они на том же диске. |
| L-21 | Имя хоста и DNS | `hostname -f ; dig +short A <домен-заказчика> ; nslookup <домен> ; cat /etc/resolv.conf` | FQDN сервера; на какой IP указывает домен; какие DNS используются. | Домена нет или он указывает на другой сервер (например, на сайт магазина). |
| L-22 | PostgreSQL (если уже есть) | `psql --version ; sudo -u postgres psql -c "select version();" ; sudo ss -tlnp \| grep 5432 ; sudo -u postgres psql -c "show listen_addresses;" ; sudo -u postgres psql -c "show data_directory;"` | Версия; на каком адресе слушает; где данные. По умолчанию `listen_addresses='localhost'`, `max_connections=100` [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/runtime-config-connection.html]. | Версия ≤ 14 (PG 14 EOL 2026-11-12; 15 — 2027-11-11; 16 — 2028-11-09; 17 — 2029-11-08; 18 — 2030-11-14 [ПОДТВЕРЖДЕНО: https://www.postgresql.org/support/versioning/]); `listen_addresses='*'` без файрвола. Чужой экземпляр **не используем** — ставим свой (раздел 6.2). |
| L-23 | Администраторы и SSH | `getent group sudo wheel ; sudo grep -E '^(PasswordAuthentication\|PermitRootLogin\|Port)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null ; sudo lastb \| head -n 20` | Кто админ; разрешён ли вход по паролю и под root; есть ли волна неудачных входов. | `PasswordAuthentication yes` + `PermitRootLogin yes`; сотни неудачных попыток в `lastb`. |
| L-24 | Автообновления | `cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null ; systemctl status unattended-upgrades --no-pager 2>/dev/null ; sudo apt list --upgradable 2>/dev/null \| wc -l` | Включены ли автоматические обновления безопасности; сколько пакетов ждут обновления. | Сотни необновлённых пакетов; служба отсутствует. |
| L-25 | Время и NTP | `timedatectl` | `System clock synchronized: yes`; часовой пояс. | Время не синхронизировано (ломает TLS, OTP TTL, сверку с 1С). Ожидаемый пояс — `Asia/Bishkek` [ТИПОВО: tzdata]. |

### 2.3. Windows Server (PowerShell от администратора)

| # | Зачем | Команда | Как прочитать результат простым языком | Что считать проблемой |
|---|---|---|---|---|
| W-1 | Версия ОС, RAM, аптайм | `systeminfo` ; `Get-ComputerInfo \| Select-Object WindowsProductName, OsVersion, OsArchitecture, CsTotalPhysicalMemory, OsLastBootUpTime, HyperVisorPresent` | Редакция (2016/2019/2022/2025), память, дата последней загрузки; `HyperVisorPresent=True` — сервер сам VM. | 2012/2012 R2 — вне поддержки. 2019: extended до 2029-01-09; 2022: mainstream до 2026-10-13, extended до 2031-10-14; 2025: mainstream до 2029-10-09 (даты Microsoft приходятся на «patch Tuesday») [ПОДТВЕРЖДЕНО: learn.microsoft.com/lifecycle (Windows Server 2019/2022/2025); перепроверить на дату аудита]. 2019/2022 допустимы (security-обновления), при переустановке — 2025. |
| W-2 | CPU | `Get-CimInstance Win32_Processor \| Select-Object Name, NumberOfCores, NumberOfLogicalProcessors` | Модель, ядра. | < 2 ядер. |
| W-3 | Диски | `Get-PSDrive -PSProvider FileSystem` ; `Get-PhysicalDisk \| Select-Object FriendlyName, MediaType, Size, HealthStatus` | `Free` по дискам; `MediaType` = `SSD`/`HDD`; `HealthStatus`. | < 40 GB свободно; `HDD` для БД; `HealthStatus` ≠ `Healthy`. |
| W-4 | Слушающие порты | `Get-NetTCPConnection -State Listen \| Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Proc';e={(Get-Process -Id $_.OwningProcess).ProcessName}} \| Sort-Object LocalPort` | Порт → процесс. 80/443 (`w3wp`/`httpd`), 1540/1541/1560–1591 (`ragent`/`rmngr`/`rphost` — кластер 1С [ТИПОВО]), 5432 (`postgres`), 1433 (`sqlservr`). | 80/443 заняты IIS/Apache для 1С; 1433/5432 слушают на `0.0.0.0`. |
| W-5 | Службы | `Get-Service \| Where-Object Status -eq Running \| Select-Object Name, DisplayName \| Sort-Object Name` | Ищем `1C:Enterprise 8.3 Server Agent`, `Apache2.4`, `W3SVC`, `MSSQLSERVER`, `postgresql-x64-*`, `Docker Desktop Service`, `WireGuardTunnel$*`. | Сосед (MS SQL + сервер 1С) уже потребляет большую часть RAM. |
| W-6 | Процессы 1С | `Get-Process ragent, rmngr, rphost -ErrorAction SilentlyContinue \| Select-Object Name, Id, WorkingSet64, StartTime` ; `Get-Service \| Where-Object DisplayName -like '*1C*'` | Если `ragent`/`rphost` есть — клиент-серверная 1С на этом хосте; если нет — файловая база или сервер 1С на другой машине. | Суммарный `WorkingSet64` близок к RAM — места для backend нет. |
| W-7 | Публикации 1С (IIS) | `Import-Module WebAdministration ; Get-Website \| Select-Object Name, State, PhysicalPath, @{n='Bindings';e={$_.bindings.Collection.bindingInformation}}` ; `Get-ChildItem IIS:\Sites\*\* \| Where-Object { Test-Path (Join-Path $_.PhysicalPath 'default.vrd') }` | Сайты IIS, их порты; папки с `default.vrd` — публикации 1С (HTTP-сервисы/OData/веб-клиент) [ПОДТВЕРЖДЕНО (назначение файла): R1 §7]. | Публикаций нет — HTTP-доступ к 1С ещё предстоит согласовать (05_ONEC_INTEGRATION). |
| W-8 | Публикации 1С (Apache) | `Get-ChildItem 'C:\Program Files\Apache*','C:\Apache*' -ErrorAction SilentlyContinue` ; `Select-String -Path 'C:\Program Files\Apache Software Foundation\Apache2.4\conf\httpd.conf' -Pattern 'Alias\|_1cws_module\|Listen' -ErrorAction SilentlyContinue` | Есть ли Apache и публикации (`_1cws_module`, `Alias "/<имя_базы>"`). | Apache слушает 80 на всех интерфейсах без TLS. |
| W-9 | Firewall | `Get-NetFirewallProfile \| Select-Object Name, Enabled, DefaultInboundAction` ; `Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow \| Get-NetFirewallPortFilter \| Select-Object Protocol, LocalPort \| Sort-Object -Unique LocalPort` | Включены ли профили; какие входящие порты разрешены. | Профили `Enabled=False`; разрешены 1433/5432/3389 для `Any`. |
| W-10 | RDP наружу | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections` ; `(Get-NetTCPConnection -State Listen -LocalPort 3389).LocalAddress` | `fDenyTSConnections=0` — RDP включён. | RDP доступен из интернета без VPN — критический риск. |
| W-11 | Docker Desktop / WSL2 / Hyper-V | `wsl --status ; wsl -l -v` ; `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform, Microsoft-Hyper-V-All \| Select-Object FeatureName, State` ; `docker version 2>$null` | Включены ли Hyper-V / WSL; есть ли Docker. | Docker Desktop на Windows Server **официально не поддерживается** [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/]. |
| W-12 | OpenSSH | `Get-WindowsCapability -Online \| Where-Object Name -like 'OpenSSH*'` ; `Get-Service sshd -ErrorAction SilentlyContinue` | Установлен ли SSH-сервер (Feature on Demand с 2019; в 2025 — по умолчанию) [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse]. | Нет — администрирование только через RDP. |
| W-13 | Планировщик | `Get-ScheduledTask \| Where-Object State -ne Disabled \| Select-Object TaskName, TaskPath, State` | Существующие задания (бэкапы 1С, выгрузки). | Нет бэкапа базы 1С — сообщить заказчику (вне нашей зоны, но риск для бизнеса). |
| W-14 | PostgreSQL для 1С | `Get-Service postgresql* ; & 'C:\Program Files\PostgreSQL\*\bin\psql.exe' --version` | Версия (у 1С часто специальная сборка [ТИПОВО]). | Экземпляр БД 1С для backend **не используем**. |
| W-15 | Домен и внешний IP | `Resolve-DnsName <домен-заказчика> -Type A` ; `(Invoke-RestMethod https://api.ipify.org)` ; `Get-NetIPAddress -AddressFamily IPv4 \| Select-Object InterfaceAlias, IPAddress` | На что указывает домен; внешний IP; локальные адреса. | Сервер за NAT без проброса; домен занят сайтом. |
| W-16 | Обновления | `Get-HotFix \| Sort-Object InstalledOn -Descending \| Select-Object -First 5` | Дата последних обновлений. | Последнее обновление старше 90 дней. |
| W-17 | Ошибки системы | `Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2} -MaxEvents 30 \| Select-Object TimeCreated, Id, ProviderName, Message` | Критические ошибки, ошибки `disk`/`ntfs`/`volmgr`. | Ошибки диска/контроллера. |
| W-18 | Время | `w32tm /query /status` | Источник времени, смещение. | Источник `Local CMOS Clock` — время не синхронизируется. |

### 2.4. Вопросы заказчику (не команды)

| # | Вопрос | Зачем |
|---|---|---|
| A-1 | Где физически стоит сервер (магазин / дата-центр / у провайдера), кто за него отвечает | ответственность, окно обслуживания |
| A-2 | Интернет магазина: провайдер, тариф, есть ли **статический публичный IP**, есть ли резервный канал | выбор A/B vs C |
| A-3 | Есть ли домен магазина, кто управляет DNS, можно ли создать поддомены `api.<домен>` и `api-test.<домен>` (имена — предложение Q-032) | TLS и адрес API |
| A-4 | Кто обслуживает 1С (франчайзи/штатный), может ли включить публикацию HTTP-сервисов/OData, поставить расширение, предоставить тестовую копию базы | Q-010, Q-011 |
| A-5 | Есть ли облачный аккаунт / возможность оплаты внешнего хранилища бэкапов | Q-033 |
| A-6 | Канал оповещений (по умолчанию e-mail через почтовый сервер в КР; Telegram-группа — только после ADR по 11 PRIV-020, раздел 9) и допустимое окно обслуживания (день/час) | Q-032 |
| A-7 | Где и сколько хранится фотографий товаров (в ИБ 1С / в томах / в папке / в облаке), среднее число фото на товар, суммарный объём | Q-022, диск |
| A-8 | Ожидаемое число документов в день и глубина истории продаж для загрузки | Q-023, рост БД |

### 2.5. Форма ответа заказчика (заполняется по результатам аудита)

```text
АУДИТ СЕРВЕРА «ОПТОМСТРОЙ» — ФОРМА ОТВЕТА (дата: ____ , заполнил: ____ )
1.  ОС и версия: ______________________  (L-1/L-2 или W-1)
2.  Физический сервер / VM: ________  Вложенная виртуализация возможна: да / нет / неизвестно
3.  CPU: модель ________, логических ядер ____            (L-3/L-4 или W-2)
4.  RAM: всего ____ GB, свободно ____ GB, swap ____ GB     (L-5 или W-1)
5.  Диски: тип SSD/HDD ____, свободно на разделе данных ____ GB, RAID: да/нет (L-6/L-7 или W-3)
6.  Публичный IP: статический / динамический / нет (за NAT); совпадает с адресом интерфейса: да/нет (L-8/L-9, W-15)
7.  Порты 80 и 443 на сервере: свободны / заняты (кем: ______)   (L-10 или W-4)
8.  Порт 22 (SSH) / 3389 (RDP) доступен из интернета: да/нет; вход по паролю: да/нет (L-23, W-10)
9.  Запущенные службы, с которыми делим сервер: ______________ (L-11 или W-5/W-6)
10. 1С на этом сервере: да/нет; вариант: файловая / клиент-серверная; веб-публикация есть: да/нет (W-6/W-7/W-8, L-13)
11. PostgreSQL / MS SQL уже установлен: да/нет, версия ____, слушает на ____ (L-22, W-14)
12. Docker установлен: да/нет, версия ____ (L-12 или W-11)
13. Firewall включён: да/нет; разрешённые входящие порты: ______ (L-14 или W-9)
14. Существующие бэкапы: есть/нет; куда: ______ (L-15/L-20 или W-13)
15. Время синхронизировано (NTP): да/нет; часовой пояс: ______ (L-25 или W-18)
16. Ошибки железа в журналах: есть/нет (L-18 или W-17)
17. Домен магазина: ______; DNS управляет: ______; поддомены создать можно: да/нет (A-3)
18. Ответы на вопросы A-1…A-8: приложить отдельным списком.
Приложения: файл audit_*.txt (Linux) или C:\audit.txt (Windows) — без паролей и секретов.
```

Результат аудита фиксируется как ответ на Q-030 и входит в 14_OPEN_QUESTIONS.md; до его получения сценарий по умолчанию — A [РЕШЕНИЕ: D-33].

---
## 3. Сценарии размещения

Общие компоненты во всех сценариях [РЕШЕНИЕ: D-01, D-03, D-33]: `pos-proxy` (Caddy, TLS), `pos-api` (NestJS), `pos-worker` (pg-boss: синхронизация, outbox, фоновые задачи — планировщик **на сервере**, как требует мастер-промт), `pos-db` (PostgreSQL 17, собственный экземпляр), файловое хранилище фото (`media`), бэкапы. Backend обращается к 1С только через опубликованные HTTP-сервисы/OData [РЕШЕНИЕ: D-28]. Clean Architecture и модульная структура (D-05, D-06) **не зависят** от места размещения backend — меняются только compose-файл, сеть и секреты [ПОДТВЕРЖДЕНО: SRC-F-143].

### 3.1. Сценарий A — Linux-сервер заказчика + Docker Compose (по умолчанию)

Один compose-проект `optomstroy-prod` (и `optomstroy-test`) на сервере заказчика; наружу — только 80/443; 1С — в той же LAN или по VPN.

```mermaid
flowchart LR
  subgraph Internet["Интернет"]
    APP[pos-app<br/>Android / Windows / iOS]
    SMS[SMSPro Nikita KG]
    ACME[ACME CA<br/>Let's Encrypt / ZeroSSL]
    OFF[(Внешнее хранилище<br/>бэкапов)]
    MON[Uptime Kuma / Healthchecks<br/>на другом хосте]
  end
  subgraph Server["Сервер заказчика · Linux · Docker Compose · optomstroy-prod"]
    subgraph edge["сеть edge (выход наружу)"]
      C[caddy<br/>:80 :443]
      A[api<br/>:3000 внутр.]
      W[worker]
      B[backup]
    end
    subgraph backend["сеть backend (internal: true)"]
      P[(postgres 17<br/>без ports:)]
    end
    M[(том media)]
  end
  subgraph Shop["Сеть магазина (LAN)"]
    O[1С:Предприятие<br/>веб-публикация OData + HTTP-сервисы]
  end
  APP -- HTTPS 443 --> C
  C --> A
  C -- /images immutable --> M
  A --> P
  W --> P
  B --> P
  A --> M
  W --> M
  A -- OTP --> SMS
  C -- выпуск/продление TLS --> ACME
  W -- LAN / VPN --> O
  A -- синхронная проверка --> O
  B -- rclone, шифрование --> OFF
  MON -- GET /health/ready --> C
```

Свойства: Caddy выпускает и продлевает сертификаты автоматически при наличии A-записи и доступных снаружи 80/443 [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https]; сеть `backend` с `internal: true` — изолирована от внешнего мира [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/networks/]; `api`/`worker`/`backup` подключены к **обеим** сетям, иначе теряют доступ к 1С/SMSPro/хранилищу бэкапов; `postgres` — только к `backend`. Docker Engine поддерживает Ubuntu 22.04/24.04/26.04 LTS [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/].

### 3.2. Сценарий B — Windows Server, на котором уже стоит 1С

| Вариант | Суть | Ограничения и риски | Оценка |
|---|---|---|---|
| **B-1. Docker Desktop + WSL2** | Тот же compose, что в A, поверх Docker Desktop. | Docker Desktop **официально не поддерживается на Windows Server** [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/]; контейнеры живут, пока выполнен вход пользователя [ТИПОВО]; WSL2 — VM с собственным планировщиком памяти рядом с 1С/MS SQL; коммерческая лицензия при > 250 сотрудников **или** > $10 млн выручки [ПОДТВЕРЖДЕНО: там же]. | **Не для прода.** Допустимо только для тестового контура. |
| **B-2. Нативные службы Windows** | `api`/`worker` как службы через WinSW [ПОДТВЕРЖДЕНО: https://github.com/winsw/winsw] или NSSM [ПОДТВЕРЖДЕНО: https://nssm.cc/]; PostgreSQL for Windows — отдельный экземпляр на отдельном порту, `listen_addresses='localhost'`; Caddy для Windows как служба. | Общая ОС, обновления и перезагрузки с 1С; откат = переустановка версии; нет сетевой изоляции; рантайм Node ставится на хост 1С; нужен отдельный пользователь Windows с минимальными правами. | Рабочий, но хуже управляемый. Пилот/тест, если нет возможности выделить VM. |
| **B-3. Linux-VM на Hyper-V на том же железе** | Включить роль Hyper-V (сервер физический, ресурсов хватает), VM Ubuntu 24.04 LTS, внутри — сценарий A. Трафик к 1С — по внутренней/локальной сети. | Нужен запас: +2 vCPU, +4 GB RAM, +80 GB диска для VM; если сервер сам VM — нужна вложенная виртуализация [ТИПОВО: проверить `HyperVisorPresent`, W-1]; включение роли — изменение конфигурации и перезагрузка (согласование, окно). | **Рекомендуемый** при Windows-сервере с ресурсами: сохраняется A, 1С не затрагивается [РЕШЕНИЕ: D-33]. |
| **B-4. Windows-контейнеры / Linux-контейнеры на Windows** | Docker Engine для Windows-контейнеров или Linux-образы на Windows-хосте. | Linux-образы (`postgres`, `caddy`, `api`) требуют виртуализации; официальный путь — Docker Desktop (ограничения B-1) [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/linux-containers]; чисто Windows-образы — нетиповой стек. | **Отвергнут.** |

```mermaid
flowchart TB
  subgraph Host["Windows Server (физический) · 1С · MS SQL/PostgreSQL 1С"]
    HV[Роль Hyper-V]
    subgraph VM["Linux-VM Ubuntu 24.04 (B-3)"]
      CMP[Docker Compose · optomstroy-prod<br/>caddy · api · worker · postgres · backup]
    end
    ONEC[1С сервер + веб-публикация<br/>IIS/Apache]
  end
  HV --> VM
  CMP -- внутренняя сеть Hyper-V / LAN --> ONEC
  INET[Интернет] -- 443 проброшен на VM --> CMP
```

Общее для B: процессы 1С (`ragent`/`rmngr`/`rphost`) и СУБД 1С — чужие; backend идёт в 1С **только** через HTTP-сервисы/OData [РЕШЕНИЕ: D-28].

### 3.3. Сценарий C — 1С в магазине, backend на VPS/в облаке

| Вариант | Суть | Что нужно в магазине | Риски |
|---|---|---|---|
| **C-1. VPS + WireGuard, туннель инициирует магазин** | На VPS — WireGuard-«сервер» с `ListenPort` (в документации примеры с 51820; реальный порт согласовать), на машине с 1С (Windows/Linux) — WireGuard-«клиент»; backend обращается к HTTP-сервисам 1С по адресу внутри туннеля. Установка есть для Linux и Windows 10/11, Server 2016–2025 [ПОДТВЕРЖДЕНО: https://www.wireguard.com/install/]; cryptokey routing = ACL по ключу, roaming при смене IP магазина [ПОДТВЕРЖДЕНО: https://www.wireguard.com/]. | Только **исходящий UDP** к VPS; входящие порты в магазине не нужны; установка WireGuard на машину 1С (согласование). | При обрыве интернета в магазине останавливается синхронизация; POS внутри магазина без интернета теряет backend (кэш Flutter — D-32). |
| **C-2. VPS + «исходящий обмен» от 1С** | 1С по регламентному заданию сама вызывает HTTPS-эндпоинты backend (push изменений, pull заказов); авторизация — технический токен роли `integration` (`integration_tokens`, 4.3; mTLS в R1 не используется — 05 ONEC-060). | Исходящий HTTPS 443 и доработка/расширение в 1С (объект `HTTPСоединение`, регламентные задания — [ТИПОВО: платформа 8.3, конфигурация требует проверки, Q-010/Q-011]). | Расписание живёт в 1С (нужен сервер 1С или постоянный сеанс для файловой базы [ТИПОВО]); backend не может инициировать запрос «по требованию» — ручная синхронизация и полный срез в R1 выполняются только на стороне 1С (`POST /sync/runs` → `422`, `rule: inbound_mode` — ядро §22.8; 12.3, «Ограничения»); backend публичен → обязательны rate-limit, токен для 1С и allow-list IP магазина в `api` (`ONEC_INBOUND_ALLOWED_IPS`, 05 ONEC-060). |
| **C-3. Гибрид** (**вне R1**) | C-1 для pull по расписанию и ручной синхронизации + C-2 для событийных push из 1С. | Как C-1 + C-2. | Больше точек отказа. **В R1 не поддерживается**: по 05 ONEC-065 флаг `ONEC_INBOUND_ENABLED=true` одновременно включает входящий обмен и **отключает все исходящие вызовы** backend → 1С, поэтому сочетание C-1 + C-2 в одной инсталляции конфигурацией R1 не выражается; рассматривается в R2 только после изменения 05 (замечание в разделе 19). |

```mermaid
flowchart LR
  subgraph VPS["VPS (Linux) · optomstroy-prod"]
    CMPV[caddy · api · worker · postgres · backup]
    WG[WireGuard ListenPort UDP]
  end
  subgraph Shop["Сеть магазина за NAT"]
    WGC[WireGuard-клиент<br/>на машине 1С]
    ONEC1[1С веб-публикация<br/>только в подсети туннеля]
  end
  APP2[pos-app] -- HTTPS 443 --> CMPV
  WGC -- исходящий UDP, туннель --> WG
  CMPV -. "C-1: backend → 1С через туннель" .-> ONEC1
  ONEC1 -. "C-2: 1С → backend HTTPS 443" .-> CMPV
```

### 3.4. Сравнение сценариев

| Критерий | A: Linux + Docker (у заказчика) | B-2: Windows нативно | B-3: Linux-VM на Windows | C-1: VPS + WireGuard | C-2: VPS + исходящий обмен от 1С |
|---|---|---|---|---|---|
| Безопасность | Высокая: наружу только 443; БД в internal-сети | Средняя: общая ОС/файрвол/перезагрузки с 1С | Высокая (как A) + 1С изолирована | Высокая на VPS; в магазине нет входящих портов | Высокая; в магазине нет входящих портов; backend публичен (rate-limit, токен 1С обязательны) |
| Стоимость (деньги) | 0 за хостинг; электроэнергия/канал | 0 | 0, если ресурсов хватает | VPS от ~€37/мес за 2 vCPU/4 GB (раздел 13) | То же |
| Сложность внедрения | Низкая–средняя | Средняя | Средняя (Hyper-V + A) | Средняя (VPN с двух сторон) | Средняя–высокая (доработка 1С) |
| Сложность сопровождения | Низкая | Средняя–высокая | Низкая | Низкая–средняя | Средняя (две команды) |
| Зависимость от интернета магазина | **Критическая** для доступа извне магазина; внутри магазина по Wi-Fi всё работает | Как A | Как A | Backend доступен всегда; при обрыве — нет синхронизации, POS в магазине без интернета теряет backend | Как C-1 |
| Статический IP / проброс 443 | Нужен | Нужен | Нужен | Не нужен | Не нужен |
| Связь с 1С | LAN (лучшая латентность) | LAN | внутренняя сеть Hyper-V | через туннель, латентность канала | только по расписанию 1С, нет запросов по требованию |
| Производительность для POS в магазине | Лучшая (LAN) | Лучшая, но конкуренция с 1С | Хорошая | Зависит от канала | То же |
| Бэкап вне площадки | Организовать отдельно | То же | То же | VPS-снапшоты + второй хост | То же |
| Пригодность под R1 | Да, если аудит ОК | Условно (тест/пилот) | Да | Да | Да |

«Работа POS без интернета» обеспечивается кэшем во Flutter-приложении [РЕШЕНИЕ: D-32]; инфраструктура лишь определяет, где находится backend.

### 3.5. Дерево выбора (после аудита, Q-030/Q-031)

```mermaid
flowchart TD
  S([Результаты аудита §2]) --> Q1{ОС Linux<br/>Ubuntu 22.04+/Debian 12+?}
  Q1 -- да --> Q2{≥ 4 GB RAM свободно,<br/>SSD, публичный IP<br/>или проброс 443?}
  Q2 -- да --> A[Сценарий A]
  Q2 -- "нет: нет IP/443" --> C[Сценарий C-1 или C-2<br/>backend на VPS]
  Q2 -- "нет: слабое железо" --> IMP[Минимальные улучшения §13<br/>или C]
  Q1 -- "нет: Windows Server" --> Q3{2019+, физический,<br/>≥ 16 GB RAM и ≥ 50 % свободно,<br/>Hyper-V можно включить?}
  Q3 -- да --> B3[Сценарий B-3]
  Q3 -- нет --> B2[B-2 для теста/пилота<br/>+ план перехода на C для прода]
  Q1 -- "нет: ОС вне поддержки, ошибки диска" --> C2[C + минимальные улучшения §13]
  A --> Q4{1С в той же LAN?}
  B3 --> Q4
  Q4 -- да --> LAN[Связь с 1С: LAN §12.1]
  Q4 -- нет --> VPN[WireGuard, инициирует магазин §12.2<br/>или исходящий обмен §12.3]
```

Текстовая форма: 1) Linux (Ubuntu 22.04+/Debian 12+), ≥ 4 GB RAM свободно, SSD, публичный статический IP или проброс 443 → **A**. 2) Windows Server 2019+, физический, ≥ 16 GB RAM и ≥ 50 % свободно, Hyper-V можно включить → **B-3**. 3) Windows Server, ресурсов мало или Hyper-V нельзя → **B-2** для теста/пилота + переход на **C** для прода. 4) Сервер только в LAN без статического IP/проброса → **C-1** или **C-2**. 5) Сервер старый/нестабильный → **C** + минимальные улучшения (раздел 13).

---

## 4. Целевая топология по умолчанию (сценарий A) — спецификация

### 4.1. Сервисы compose

| Сервис compose | Канон. имя (R0 §5) | Образ / тег | Команда | Порты | Сети | Исходящие соединения | Тома | Healthcheck |
|---|---|---|---|---|---|---|---|---|
| `caddy` | `pos-proxy` | `caddy:2.<minor>.<patch>` (точный тег фиксируется при деплое) | — | `80`, `443` (единственные публичные) | `edge` | ACME CA (HTTPS) | `caddy_data` (сертификаты — persistent обязателен [ПОДТВЕРЖДЕНО: caddyserver.com/docs/automatic-https]), `caddy_config`, `media:ro` | нет (намеренно): proxy должен подниматься независимо от `api` (ACME-валидация, шаг 3 плана 14.1, runbook 15.4); доступность `/health` через proxy проверяет внешний монитор (раздел 9) |
| `api` | `pos-api` | `optomstroy/api:<версия>` (`API_TAG`) | `node dist/main.js` | внутренний `3000`, **без** `ports:` | `edge`, `backend` | SMSPro (HTTPS), 1С (LAN/VPN) — синхронные проверки, `postgres` | `media` (rw) | `wget -qO- http://localhost:3000/health` |
| `worker` | `pos-worker` | тот же образ | `node dist/worker.js` | нет | `edge`, `backend` | 1С (LAN/VPN) — обязательно; Healthchecks (HTTPS); `postgres` | `media` (rw) | процесс жив + heartbeat pg-boss (детали — 06_ARCHITECTURE) |
| `migrate` | — | тот же образ | `node dist/migrate.js` (Drizzle `migrate()`, SQL из `migrations/`) [РЕШЕНИЕ: D-03] | нет | `backend` | `postgres` | — | одноразовый: `restart: "no"`; `api` зависит через `service_completed_successfully` |
| `postgres` | `pos-db` | `postgres:17.<minor>` (18 — после решения Q-104) | — | **без `ports:`** | `backend` только | нет | `pgdata` | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` |
| `backup` | — | `optomstroy/backup:<версия>` (postgres-client + rclone + age) | cron внутри контейнера либо запуск с хоста по `crontab` (раздел 8.5) | нет | `edge`, `backend` | внешнее хранилище (HTTPS/SFTP), Healthchecks | `backups`, `media:ro` | завершение задания с кодом 0 + ping Healthchecks |
| `pgadmin` (опционально) | — | `dpage/pgadmin4:<версия>` | — | `127.0.0.1:5050:80` — только localhost + SSH-туннель | `edge`, `backend` | нет | `pgadmin` | — |
| хост | — | — | `docker compose pull` | — | — | реестр образов (HTTPS), apt-репозитории ОС/Docker | — | — |

Внутренний порт `api` — `3000` [РЕШЕНИЕ: R0 §16.1; R5 §7.2]; R8 использует `8080` — расхождение снято ядром v1.1 (см. раздел 19, №1).

Архитектурные рамки состава [РЕШЕНИЕ: D-44, D-45; R0 §17.1]: backend R1 — **модульный монолит**; `api` и `worker` — один и тот же образ `optomstroy/api:<версия>` с разной ролью процесса (команда `dist/main.js` / `dist/worker.js` и переменная `WORKERS_ENABLED`: `false` в `api`, `true` в `worker`; в минимальной конфигурации без отдельного `worker` — `true` в `api`, Q-135). **Redis не разворачивается**: очереди и расписания (pg-boss), rate-limit OTP и ключи идемпотентности хранятся в PostgreSQL (`postgres`), поэтому в compose нет сервиса кэша/брокера, а бэкап `postgres` (раздел 8) покрывает и состояние очередей.

### 4.2. Сети, порты, тома

| Объект | Имя | Свойства |
|---|---|---|
| Сеть | `optomstroy_prod_edge` (`edge`) | bridge с выходом наружу через NAT хоста; `caddy`, `api`, `worker`, `backup`, `pgadmin` |
| Сеть | `optomstroy_prod_backend` (`backend`) | `internal: true` — без выхода наружу [ПОДТВЕРЖДЕНО: docs.docker.com/reference/compose-file/networks/]; `postgres`, `migrate` + все, кому нужна БД |
| Публичные порты хоста | `80/tcp`, `443/tcp` | только `caddy`; **ничего больше** не публикуется; проверка — `ss -tulpn` и `iptables -S DOCKER-USER`, а не `ufw status` (Docker обходит ufw [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/network/packet-filtering-firewalls/]) |
| Локальные порты | `127.0.0.1:5050` (pgadmin, опц.) | доступ только через `ssh -L 5050:127.0.0.1:5050` |
| Том | `pgdata` → `/srv/optomstroy/prod/pgdata` | данные PostgreSQL; для `postgres:18+` точка монтирования `/var/lib/postgresql`, для 17 — `/var/lib/postgresql/data` [ПОДТВЕРЖДЕНО: https://hub.docker.com/_/postgres] |
| Том | `media` → `/srv/optomstroy/prod/media` | фото `images/{sha256}/{size}.webp` [РЕШЕНИЕ: D-30]; `caddy` монтирует `:ro` |
| Том | `backups` → `/srv/optomstroy/prod/backups` | локальные дампы (30 дней) |
| Том | `caddy_data`, `caddy_config` | сертификаты и состояние ACME — не пересоздавать при деплое (лимит дубликатов LE 5/7 дней [ПОДТВЕРЖДЕНО: https://letsencrypt.org/docs/rate-limits/]) |
| Каталоги конфигурации | `/opt/optomstroy/prod/{docker-compose.yml,.env,Caddyfile,secrets/,bin/}` | права `750` на каталоги, `600` на `.env` и `secrets/*`; владелец — пользователь ОС `optomstroy` |

### 4.3. Переменные окружения и секреты (канонический перечень; значения секретов не приводятся)

Правило: `.env` содержит только **несекретную** конфигурацию; всё секретное — файлы в `secrets/` (`600`), подключаемые через Compose `secrets:` и доступные в контейнере как `/run/secrets/<имя>` [ПОДТВЕРЖДЕНО: https://docs.docker.com/compose/how-tos/use-secrets/]. В репозитории — только `.env.example` без значений секретов (пример — в конце подраздела). Перечень ниже — **канонический словарь переменных окружения** для 05/06/08/09/10/11/13 [РЕШЕНИЕ: ядро §18.1 — владелец 16 §4.3; R0 §16.3, §17.7]: он включает **все** имена ядра v1.1 (R0 §16 п.3), дополнения ядра v1.2 (R0 §17.7), v1.3 (R0 §18.2 п.4, п.12, п.14) v1.4 (R0 §19.2, §19.3 — значения по умолчанию и границы R1/R2), v1.6 и v1.7 (ядро §21 п.1, §22.1, §22.8 — назначение флагов и пороги outbox), а также **каждую** серверную переменную, упомянутую в любом документе ТЗ (сверка Grep-ом по 05, 06, 08, 09, 10, 11, 13 — 2026-10-19; колонка «Примечание» содержит документ-источник). При расхождении имени или значения по умолчанию с другим документом прав этот перечень (§18.1). Пометки: `[РЕШЕНИЕ: R0 §16.3]` — имя из перечня ядра v1.1; `[РЕШЕНИЕ: R0 §17.7]` — имя из дополнения ядра v1.2; `[РЕШЕНИЕ: ядро §18.2 п.N]` — имя, канонизированное ядром v1.3 поимённо или по группе; `[РЕШЕНИЕ: ядро §19.x]` — имя, значение по умолчанию или граница релиза, закреплённые ядром v1.4; `[РЕШЕНИЕ: ядро §18.1]` — имя, внесённое в словарь его владельцем (уровень compose/образа/хоста или серверная переменная другого документа ТЗ, не названная в ядре поимённо). Переменные `INTEGRATION_API_KEY_FILE` и `ONEC_INBOUND_TOKEN_FILE` **не используются** и из перечня удалены [РЕШЕНИЕ: ядро §18.2 п.4] — технические токены роли `integration` выпускаются скриптом `bin/issue_integration_token` (см. абзац после таблицы). Происхождение имён: `SMSPRO_*` и `SMS_PROVIDER` — из R2 §11; `ONEC_BASE_URL`, `ONEC_USER`, `ONEC_PASSWORD`, `LOG_LEVEL`, `WORKERS_ENABLED` — из R5 §7.4; `SYNC_*_CRON` — введены этим документом и приняты ядром (R0 §16.3; в R5 §7.4 таких имён нет); `CUSTOMER_SELF_SERVICE`, `RECEIVABLES_MAX_AGE_MIN` — из R0 (D-07, D-24, §16.2); `APP_ENV`, `AUTH_OTP_TEST_MODE` — из R6 §1. Конвенция `*_FILE` (значение читается из файла, если задана переменная с суффиксом `_FILE`, иначе — из одноимённой переменной) — [РЕШЕНИЕ: R0 §16.3]; приложение **не** ищет `/run/secrets/<имя>` «по умолчанию» — путь всегда задаётся явно переменной `*_FILE` (см. 4.4, якорь `x-secret-env`).

Колонка «По умолчанию» содержит только **несекретные** значения: «—» — значения по умолчанию нет, переменная обязательна (при её отсутствии `api`/`worker`/`migrate` отказывают в старте, DEPLOY-014); для `*_FILE` указан путь внутри контейнера (сам путь не секретен; значение секрета в документе не приводится). Числовые значения по умолчанию, не зафиксированные ядром, — предложение [НЕ ПОДТВЕРЖДЕНО], уточняются в указанных документах/вопросах. Бизнес-настройки POS — **ключи `app_settings` в БД, не переменные окружения** [РЕШЕНИЕ: R0 §17.7]: `low_stock_threshold`, `cart_stale_minutes`, `parked_cart_ttl_days`, `overpay_allowed`, `return_approval_threshold`, `returns_enabled`, `cash_rounding`, `delivery_slots`, `receivables.max_age_minutes`, `min_app_version`, `recommended_app_version` [РЕШЕНИЕ: ядро §18.2 п.12], `secure_screens`, `privacy_contact`, `support_contacts` [РЕШЕНИЕ: ядро §19.2 — публикуется как `supportContacts` в `GET /settings/public`], `sync_interval.<entity>` (единственная форма интервалов синхронизации [РЕШЕНИЕ: ядро §19.2]); они меняются администратором (SCR-46, step-up, аудит) без перезапуска контейнеров; где у ключа есть env-аналог (`RECEIVABLES_MAX_AGE_MIN`, `MIN_APP_VERSION`, `RECOMMENDED_APP_VERSION`, `SYNC_*_CRON`), env задаёт значение по умолчанию, а `app_settings` его переопределяет (R0 §17.2, D-29, §18.2 п.12). Ключи `app_settings` в API — camelCase-проекция snake_case-ключей (таблица соответствия — 08) [РЕШЕНИЕ: ядро §19.2]. `CUSTOMER_SELF_SERVICE` — **только env**, не ключ `app_settings` (в UI — только чтение) [РЕШЕНИЕ: ядро §19.2]; он и env-флаги `QR_WEBHOOK_ENABLED`, `DEBT_PAYMENTS_FROM_POS`, а также ключ `app_settings.returns_enabled` публикуются клиенту в `GET /settings/public` → `features{customerSelfService, returnsFromPos, qrWebhook, debtPaymentsFromPos}` (`returnsFromPos` отражает `returns_enabled`, **не** `RETURNS_FROM_POS_ENABLED` — ядро §21 п.1) [РЕШЕНИЕ: ядро §19.2, §21 п.1; Q-218(б) — закрыт решением ядра v1.4]; изменение env-флагов — правкой `.env` и `docker compose up -d api worker`, ключа `returns_enabled` — `admin` в SCR-46.

| Переменная / секрет | Где | Назначение | Секрет | По умолчанию | Примечание |
|---|---|---|---|---|---|
| **Общие и платформа** | | | | | |
| `APP_ENV` | `.env` | `prod` \| `staging` \| `dev`; тестовые режимы допустимы только при `staging`/`dev` | нет | — (прод = `prod`, тест = `staging`) | [РЕШЕНИЕ: R0 §16.3]; R6 §1 |
| `API_TAG` | `.env` | тег образа `optomstroy/api` для текущего релиза | нет | — | [РЕШЕНИЕ: ядро §18.1] (уровень compose); неизменяемый тег версии, не `latest` |
| `BACKUP_TAG` | `.env` | тег образа `optomstroy/backup` | нет | — | [РЕШЕНИЕ: ядро §18.1] (уровень compose); неизменяемый тег |
| `PUBLIC_BASE_URL` | `.env` | `https://api.<домен>` — для ссылок в документах/вебхуках | нет | — | [РЕШЕНИЕ: R0 §16.3]; домен — Q-032 |
| `LOG_LEVEL` | `.env` | уровень структурированного лога | нет | `info` (тест — `debug`) | [РЕШЕНИЕ: R0 §16.3] |
| `TZ` | `.env` | часовой пояс процессов (cron, логи) | нет | `Asia/Bishkek` | [РЕШЕНИЕ: ядро §18.1] (стандартная переменная ОС); БД хранит `timestamptz` |
| `WORKERS_ENABLED` | `.env` / `environment:` сервиса | роль процесса единого образа модульного монолита [РЕШЕНИЕ: D-45]: `true` — процесс исполняет обработчики и расписания pg-boss (синхронизация, outbox, `sms.send`, фоновые задачи); `false` — только HTTP | нет | `false`; в сервисе `worker` — `true`; в минимальной конфигурации без отдельного `worker` — `true` в `api` | [РЕШЕНИЕ: R0 §17.7; D-44, D-45]; R5 §7.2; очереди, расписания, rate-limit OTP и идемпотентность — в PostgreSQL (pg-boss, таблицы), Redis не разворачивается (D-44); Q-135 |
| `APP_READ_ONLY` | `.env` | режим сдерживания инцидента: все мутации → `503 APP_READ_ONLY`, чтение (каталог, остатки) работает | нет | `false` | [РЕШЕНИЕ: R0 §17.4, §17.7]; включается по runbook 15.6 и 11_SECURITY_PRIVACY; применяется `docker compose up -d api worker` |
| `CORS_ALLOWED_ORIGINS` | `.env` | список разрешённых origin для web-таргета | нет | пусто (CORS выключен — мобильные/desktop клиенты) | [РЕШЕНИЕ: R0 §17.7]; нужна только при web-таргете R2 (D-37, D-39); R5 §7.4 |
| `OPENAPI_PUBLIC` | `.env` | `true` — `GET /openapi.json` доступен без аутентификации (тестовый контур); `false` — только Bearer с правом `system.openapi.read` (`admin`), без него `404 NOT_FOUND` | нет | `false` (тест — `true`) | [РЕШЕНИЕ: ядро §18.1]; источник — 08 §4.19.2; право — 11 §4.3 №70 |
| `MIN_APP_VERSION` | `.env` | минимальная поддерживаемая версия `pos-app` **по платформам** (D-46). Формат значения: `platform=semver` через запятую, например `android=1.2.0,windows=1.2.0` [РЕШЕНИЕ: ядро §18.2 п.12]; платформа берётся из заголовка запроса `X-Platform`. Сервер добавляет к **каждому** ответу заголовок `X-Min-App-Version` (значение для платформы клиента) и публикует его в `GET /health`; при меньшей версии клиента — `426 APP_UPDATE_REQUIRED` (10.2, OPS-024). Источник значения — `app_settings.min_app_version` (если задан), иначе эта переменная | нет | — (обязательна) | [РЕШЕНИЕ: R0 §16.3, §16.4, §17.1 D-46; ядро §18.2 п.12]; политика N/N−1 — Q-133 (06); источник — 06, 08 |
| `RECOMMENDED_APP_VERSION` | `.env` | рекомендуемая версия `pos-app` по платформам; формат как у `MIN_APP_VERSION` (`platform=semver` через запятую, например `android=1.3.0,windows=1.3.0`). Сервер добавляет к каждому ответу заголовок `X-Recommended-App-Version` (для платформы из `X-Platform`); клиент ниже неё показывает мягкий баннер обновления без блокировки. Источник — `app_settings.recommended_app_version` (если задан), иначе эта переменная | нет | пусто (заголовок не отправляется, баннер не показывается) | [РЕШЕНИЕ: R0 §17.1 D-46, §17.7; ядро §18.2 п.12]; Q-133 |
| `CUSTOMER_SELF_SERVICE` | `.env` | самообслуживание покупателя в R1 (в т. ч. доступ роли `customer` к SCR-21 «Оформление заказа», R0 §18.2 п.11); **только env** — не ключ `app_settings`, в UI отображается только для чтения; клиенту публикуется в `GET /settings/public` → `features.customerSelfService`; при `true` также разрешено самоподтверждение привязки клиентом `customer.link.self_resolve` (подтверждение/отклонение сотрудником — только `admin`; ядро §22.12; правило — 11, эндпоинты — 08 §4.2.4) | нет | `false` | [РЕШЕНИЕ: R0 §16.3; D-07; Q-001; ядро §19.2]; изменение — правкой `.env` и `docker compose up -d api worker` |
| `RECEIVABLES_MAX_AGE_MIN` | `.env` | допустимый возраст снимка долгов (минуты) [РЕШЕНИЕ: D-24]; применяется в шаге (3) порядка решения о продаже в долг (владелец — 10 PAY-031; ядро §22.4): снимок отсутствует, неполон или старше порога → попытка синхронного обновления; 1С недоступна или вариант C-2 → `422 RECEIVABLES_STALE`; свежий полный снимок без блокировок — долг без обращения к 1С; `503 ONEC_UNAVAILABLE` для `credit` не возвращается | нет | `60` | каноническое имя [РЕШЕНИЕ: R0 §16.2, §17.2]; переопределение — `app_settings.receivables.max_age_minutes`; имя `RECEIVABLES_MAX_AGE` не используется |
| **База данных** | | | | | |
| `POSTGRES_USER`, `POSTGRES_DB` | `.env` | суперпользователь образа `postgres` (инициализация, бэкап) и имя БД | нет | — (`optomstroy_prod` / `optomstroy_test`) | [РЕШЕНИЕ: ядро §18.1] (переменные официального образа) |
| `POSTGRES_PASSWORD_FILE` | secret `pg_password` | пароль суперпользователя образа; образ `postgres` читает `_FILE`-вариант [ПОДТВЕРЖДЕНО: hub.docker.com/_/postgres] | **да** | `/run/secrets/pg_password` | [РЕШЕНИЕ: ядро §18.1] (переменная образа) |
| `DATABASE_URL_FILE` | secret `database_url` | строка подключения **рабочей роли приложения** `pos_app` (07 DATA-012; без DDL) для `api`/`worker`; `migrate` берёт из неё только хост/порт/БД | **да** | `/run/secrets/database_url` | [РЕШЕНИЕ: R0 §16.3]: вариант `_FILE` вместо `DATABASE_URL` из R5 §7.4, чтобы пароль не попадал в `.env` |
| `DB_MIGRATOR_PASSWORD_FILE` | secret `db_migrator_password` | пароль роли БД **`pos_migrate`** — владельца схемы (DDL), под которой работает **только** `migrate` (логин роли — `pos_migrate`, хост/порт/БД — из `DATABASE_URL_FILE`); `api`/`worker` этот секрет не получают (минимум прав) | **да** | `/run/secrets/db_migrator_password` | [РЕШЕНИЕ: R0 §17.7] (имя переменной); имя роли `pos_migrate` — по владельцу схемы прав БД 07 §2.1–§2.2 (DATA-012, D-36); в ядре имя роли не задано; источник — 07, 11 §5 (ротация 180 дней) |
| **Аутентификация, OTP, PIN** | | | | | |
| `JWT_PRIVATE_KEY_FILE` | secret `jwt_private.pem` | закрытый ключ подписи access JWT (EdDSA/ES256) для активного `JWT_KEY_ID` [РЕШЕНИЕ: D-12]; только `api` | **да** | `/run/secrets/jwt_private.pem` | [РЕШЕНИЕ: R0 §16.3]; R5 §7.4 использует `_PATH`, канонично `_FILE` |
| `JWT_PUBLIC_KEY_FILE` | secret `jwt_public.json` | **набор** публичных ключей `{kid: pem}` (активный и предыдущий) для проверки подписи; `api`, `worker` | нет (публичный; хранится в `secrets/` для единообразия) | `/run/secrets/jwt_public.json` | [РЕШЕНИЕ: R0 §16.3; формат `{kid: pem}` — R0 §17.7] |
| `JWT_KEY_ID` | `.env` | `kid` активного ключа подписи (заголовок `kid` access JWT); ротация — новый `kid` + ключ в наборе, предыдущий удаляется из набора после истечения выданных им токенов | нет | — (обязательна) | [РЕШЕНИЕ: R0 §17.7]; 11_SECURITY (AC-SEC-053) |
| `OTP_HMAC_SECRET_FILE` | secret `otp_pepper` | pepper HMAC-SHA-256 для хранения OTP [РЕШЕНИЕ: D-10, D-47 `OtpService`]; только `api` | **да** | `/run/secrets/otp_pepper` | [РЕШЕНИЕ: R0 §16.3]; R5 §7.4 (`OTP_HMAC_SECRET`) |
| `OTP_HMAC_SECRET_VERSION` | `.env` | версия pepper OTP (ротация без отказа активных кодов) | нет | `1` | [РЕШЕНИЕ: R0 §17.7] |
| `PIN_PEPPER_FILE` | secret `pin_pepper` | pepper для Argon2id-хэшей PIN приложения (`app_pins`, серверная проверка PIN) [РЕШЕНИЕ: D-48]; только `api` | **да** | `/run/secrets/pin_pepper` | [РЕШЕНИЕ: R0 §17.1 D-48, §17.7] |
| `PIN_PEPPER_VERSION` | `.env` | версия pepper PIN (ротация без сброса всех PIN) | нет | `1` | [РЕШЕНИЕ: R0 §17.7] |
| `SESSION_IDLE_LOCK_MINUTES` | `.env` | бездействие `staff` до блокировки (SCR-08 overlay, `/auth/unlock`) | нет | `30` | [РЕШЕНИЕ: R0 §17.7; ядро §19.3 — idle 30 мин]; для `customer` не применяется |
| `AUTH_OTP_TEST_MODE` | `.env` | тест-режим OTP (без отправки SMS) только для номеров из `AUTH_OTP_TEST_PHONES` | нет | `false` | [РЕШЕНИЕ: R0 §17.7]; R6 §1; сервер отказывает в старте при `APP_ENV=prod` + `true` |
| `AUTH_OTP_TEST_PHONES` | `.env` | allowlist номеров E.164 для тест-режима OTP | нет | пусто | [РЕШЕНИЕ: R0 §17.7]; только `staging`/`dev`; непустое значение при `APP_ENV=prod` — отказ в старте |
| `OTP_GLOBAL_PER_MIN` | `.env` | глобальный предохранитель отправки OTP в минуту: при превышении — circuit-breaker, `429`, алерт | нет | `60` | [РЕШЕНИЕ: R0 §17.7]; счётчик — в PostgreSQL (D-44) |
| `AUTH_OTP_TEST_CODE` | `.env` | фиксированный 6-значный код, который сервер принимает для номеров из `AUTH_OTP_TEST_PHONES` при `AUTH_OTP_TEST_MODE=true` (SMS не отправляется) | нет (тестовое значение; в prod не задаётся) | пусто; непустое значение при `APP_ENV=prod` — отказ в старте | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.8, §6.11 |
| `OTP_TTL_SECONDS` | `.env` | срок действия OTP-кода (SCR-02 показывает обратный отсчёт) | нет | `300` | [РЕШЕНИЕ: ядро §18.2 п.14]; D-10, Q-004; источник — 09 §5.3, §6.11; 11 |
| `OTP_RESEND_COOLDOWN_SECONDS` | `.env` | пауза до повторной отправки кода на тот же номер | нет | `60` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.3, §6.11 |
| `OTP_MAX_VERIFY_ATTEMPTS` | `.env` | число попыток ввода одного кода до его аннулирования (`423 OTP_LOCKED`) | нет | `5` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.3, §6.11 |
| `OTP_MAX_SENDS_PER_PHONE_15M`, `OTP_MAX_SENDS_PER_PHONE_24H` | `.env` | лимиты отправок OTP на номер за 15 мин / 24 ч (счётчики — в PostgreSQL, D-44) | нет | `3`; `10` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.4, §6.11 |
| `OTP_MAX_SENDS_PER_IP_10M`, `OTP_MAX_SENDS_PER_IP_24H` | `.env` | лимиты отправок OTP с одного IP за 10 мин / 24 ч | нет | `20`; `100` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.4, §6.11 |
| `OTP_MAX_SENDS_PER_DEVICE_10M`, `OTP_MAX_SENDS_PER_DEVICE_24H` | `.env` | лимиты отправок OTP на одно устройство (`X-Device-Id`) за 10 мин / 24 ч | нет | `5`; `20` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.4, §6.11 |
| `OTP_LOCK_AFTER_LOCKED_CODES` | `.env` | число подряд аннулированных (`locked`/исчерпанных) кодов на номер, после которого включается пауза номера | нет | `3` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.4, §6.11; 11 |
| `OTP_PHONE_PAUSE_MINUTES` | `.env` | длительность паузы отправки OTP на номер после `OTP_LOCK_AFTER_LOCKED_CODES` (+ алерт; аккаунт не блокируется навсегда) | нет | `30` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §5.4, §6.11; 11 |
| `OTP_RESEND_ON_DLR_FAILED` | `.env` | разрешает повторную отправку раньше cooldown, если DLR SMSPro вернул `FAILED` | нет | `true` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §6.5, §6.11 |
| `OTP_PROVIDER` | `.env` | реализация `OtpProvider`: `internal` (собственный `OtpService`, D-47) \| `smspro` (OTP API SMSPro, вариант B — только R2) | нет | `internal` | [РЕШЕНИЕ: ядро §18.2 п.14]; D-47, Q-242; источник — 09 §6.10 |
| `AUTH_ACCESS_TTL_SECONDS` | `.env` | срок жизни access JWT (все роли) | нет | `900` | [РЕШЕНИЕ: ядро §18.2 п.14]; D-12, Q-004; источник — 09 §8 |
| `AUTH_REFRESH_TTL_STAFF_DAYS`, `AUTH_REFRESH_TTL_CUSTOMER_DAYS` | `.env` | абсолютный срок жизни refresh-токена для `staff` / `customer` | нет | `7`; `30` | [РЕШЕНИЕ: ядро §18.2 п.14]; Q-004; источник — 09 §8 |
| `AUTH_REFRESH_IDLE_STAFF_HOURS`, `AUTH_REFRESH_IDLE_CUSTOMER_DAYS` | `.env` | срок неиспользования refresh-токена до отзыва для `staff` (часы) / `customer` (дни) | нет | `24`; `14` | [РЕШЕНИЕ: ядро §18.2 п.14]; Q-004; источник — 09 §8 |
| `AUTH_REFRESH_GRACE_SECONDS` | `.env` | окно грации ротации refresh-токена (повтор с предыдущим токеном в пределах окна не считается кражей) | нет | `30` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §8.3 |
| `AUTH_BACKGROUND_LOCK_MINUTES` | `.env` | Android/iOS: время в фоне, после которого при возврате показывается overlay блокировки SCR-08 (значение передаётся клиенту сервером) | нет | `5` | [РЕШЕНИЕ: ядро §18.2 п.14; ядро §19.3 — 5 мин]; источник — 09 §8, §6.11 |
| `AUTH_BIO_AUTO_PROMPT` | `.env` | Android/iOS: автоматический вызов системного промпта биометрии на SCR-08 (значение передаётся клиенту сервером) | нет | `true` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §9.2 |
| `AUTH_NOTIFY_OLD_PHONE` | `.env` | информационная SMS на старый номер при смене номера входа (платно) | нет | `false` | [РЕШЕНИЕ: ядро §18.2 п.14]; Q-038; источник — 09 §4.7 |
| `PIN_MIN_LENGTH_STAFF` | `.env` | минимальная длина PIN приложения для `staff` (для `customer` — 4) | нет | `6` | [РЕШЕНИЕ: ядро §18.2 п.14]; D-48; источник — 09 §9.6 |
| `PIN_MAX_ATTEMPTS` | `.env` | число неверных PIN подряд до `423 PIN_LOCKED` (разблокировка — успешный OTP-вход) | нет | `5` | [РЕШЕНИЕ: ядро §18.2 п.14]; D-48, Q-004; источник — 09 §9.6 |
| **SMSPro** | | | | | |
| `SMS_PROVIDER` | `.env` | `smspro` \| `fake` (`FakeSmsGateway`, запись в `dev_outbox` — только dev/test, R0 §17.3) | нет | — (прод — `smspro`, тест — `fake`) | [РЕШЕНИЕ: R0 §16.3]; R2 §11 |
| `SMSPRO_BASE_URL` | `.env` | базовый URL API SMSPro | нет | `https://smspro.nikita.kg/api` | [РЕШЕНИЕ: R0 §16.3]; только https [РЕШЕНИЕ: D-11] |
| `SMSPRO_LOGIN_FILE`, `SMSPRO_PASSWORD_FILE` | secrets `smspro_login`, `smspro_password` | учётные данные SMSPro (пароль = пароль от кабинета с деньгами — R2); `api`, `worker` | **да** | `/run/secrets/smspro_login`, `/run/secrets/smspro_password` | [РЕШЕНИЕ: R0 §16.3]: `_FILE`-варианты для `SMSPRO_LOGIN`/`SMSPRO_PASSWORD` |
| `SMSPRO_SENDER` | `.env` | имя отправителя | нет | — (согласуется с SMSPro, Q-029) | [РЕШЕНИЕ: R0 §16.3] |
| `SMSPRO_TEST_FLAG` | `.env` | тест-флаг SMSPro (`true` только в тесте) | нет | `false` | [РЕШЕНИЕ: R0 §16.3]; `true` при `APP_ENV=prod` — **отказ в старте** `api`/`worker` (как любой тестовый флаг, OPS-027, DEPLOY-014; согласование с 11 SEC-056 — раздел 22) |
| `SMS_STAGING_ALLOWED_PHONES` | `.env` | только `APP_ENV=staging` при `SMS_PROVIDER=smspro` и `SMSPRO_TEST_FLAG=false`: номера команды (с их согласия), на которые отправляются реальные SMS; на любой другой номер запрос уходит с тест-флагом SMSPro (через запятую) | нет | пусто (реальные SMS в `staging` не отправляются); при `APP_ENV=prod` не читается | [РЕШЕНИЕ: ядро §18.1] (внесено владельцем словаря); источник — 09 §5.8 |
| `SMSPRO_TIMEOUT_MS` | `.env` | таймаут одного HTTP-вызова SMSPro | нет | `15000` | [РЕШЕНИЕ: R0 §17.7]; R2 §11 |
| `SMSPRO_RETRY_MAX` | `.env` | число повторов отправки | нет | `3` | [РЕШЕНИЕ: R0 §17.7]; R2 §11 |
| `SMSPRO_DLR_MODE` | `.env` | получение отчётов о доставке: `poll` \| `push` | нет | `poll` | [РЕШЕНИЕ: R0 §17.4, §17.7]; `push` включает маршрут `POST /api/v1/integrations/smspro/dlr` (4.6) |
| `SMSPRO_DLR_ALLOWED_IPS` | `.env` | allowlist IP/CIDR шлюза SMSPro для push-DLR (через запятую) | нет | пусто (push-эндпоинт → `404`) | [РЕШЕНИЕ: R0 §17.7]; проверка — в `api` по реальному IP клиента (4.6) |
| `SMSPRO_BALANCE_POLL_MINUTES` | `.env` | период опроса баланса SMSPro (`worker`) | нет | `15` | [РЕШЕНИЕ: R0 §17.7] |
| `SMSPRO_BALANCE_ALERT_SOM` | `.env` | порог баланса (сом) для алерта | нет | `300` | [РЕШЕНИЕ: R0 §17.7]; раздел 9 |
| `SMSPRO_CB_OPEN_MINUTES` | `.env` | время открытого состояния circuit-breaker SMSPro (при `CONFIG_ERROR`/`INSUFFICIENT_FUNDS` или ≥ 50 % `RETRYABLE` за 1 мин), затем half-open | нет | `5` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §6.4, §6.8 |
| `SMSPRO_DEF_PRECHECK` | `.env` | опциональная проверка номера через `/api/def` SMSPro перед отправкой OTP | нет | `false` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §3.4, §6.11 |
| `SMS_OTP_TEMPLATE` | `.env` | шаблон текста OTP-SMS с плейсхолдером `{code}`; шаблон длиннее одной части SMS отвергается при старте | нет | `Kod: {code}. Optomstroy` | [РЕШЕНИЕ: ядро §18.2 п.14]; текст — Q-029; источник — 09 §6.7, §6.11 |
| `SMSPRO_OTP_API_KEY_FILE` | secret | только при альтернативной реализации OTP через OTP API SMSPro (D-47, Q-242) | **да** | пусто (не монтируется) | [РЕШЕНИЕ: ядро §18.2 п.14]; только при `OTP_PROVIDER=smspro` (R2); источник — 09 §6.10, §6.11 |
| **Регистрация, приглашения, FACE-SCAN** | | | | | |
| `INVITATION_TTL_DAYS` | `.env` | срок действия приглашения сотрудника (`user_invitations.expires_at = now + INVITATION_TTL_DAYS`) | нет | `30` | [РЕШЕНИЕ: ядро §18.1]; Q-141; источник — 07 §5.3, 09 §7.5 |
| `INVITE_SMS` | `.env` | SMS-уведомление приглашённому сотруднику (платно) | нет | `false` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §7.5, §6.11 |
| `REGISTRATION_SECOND_OTP` | `.env` | буквальный порядок «форма → OTP»: второй код `purpose=login_or_register` после SCR-04 (+1 SMS на регистрацию) | нет | `false` | [РЕШЕНИЕ: ядро §18.2 п.14]; источник — 09 §7.4, §6.11 |
| `FACE_SCAN_MODE` | `.env` | **R2.** Режим FACE-SCAN: `off` \| `guided_only` \| `sdk_liveness`; в R1 значение фиксировано `off` (SCR-05 и маршрут `/register/face-scan` отсутствуют; `RegistrationStepper` R1 — 3 шага без FACE-SCAN, R0 §19.3) | нет | `off` | [РЕШЕНИЕ: ядро §18.2 п.14; ядро §19.3]; R2 — D-14, Q-003; источник — 09 §10 |
| `FACE_SCAN_STORE_FRAMES` | `.env` | **R2.** Сохранять ли кадры FACE-SCAN (при `false` — только факт прохождения в `consents`); в R1 не читается | нет | `false` (off) | [РЕШЕНИЕ: ядро §18.1]; R2; источник — 09 §10 |
| `FACE_SCAN_REQUIRED` | `.env` | **R2.** Обязателен ли шаг FACE-SCAN при регистрации; в R1 не читается | нет | `false` (off) | [РЕШЕНИЕ: ядро §18.1]; R2, Q-003; источник — 09 §10 |
| **1С** | | | | | |
| `ONEC_MODE` | `.env` | `extension` (HTTP-сервис + план обмена) \| `odata_only` (fallback DataVersion) [РЕШЕНИЕ: D-28] \| `fixtures` (режим без 1С: тестовый контур, CI, `FakeOnecClient` — раздел 11, 06_ARCHITECTURE) | нет | — (прод — `extension`/`odata_only`; тест — `fixtures` или тестовая копия) | [РЕШЕНИЕ: R0 §16.3]; `fixtures` при `APP_ENV=prod` — отказ в старте (как OPS-027); валидация сочетаний при старте `api`/`worker`: `ONEC_INBOUND_ENABLED=true` допустимо **только** при `ONEC_MODE=extension` (05 ONEC-065), `ONEC_ODATA_WRITE_ENABLED=true` — только при `ONEC_MODE=odata_only` (05 ONEC-028); иное — отказ в старте (DEPLOY-014, DEPLOY-036) |
| `ONEC_BASE_URL` | `.env` | базовый URL публикации 1С (`https://<хост>/<база>` в LAN/туннеле) | нет | — | [РЕШЕНИЕ: R0 §16.3]; R5 §7.4; адрес — Q-031 |
| `ONEC_ODATA_PATH`, `ONEC_HS_PATH` | `.env` | пути стандартного OData и HTTP-сервиса расширения | нет | `odata/standard.odata`; для `ONEC_HS_PATH` — нет (`hs/<имя>`, имя — 05_ONEC_INTEGRATION) | [РЕШЕНИЕ: R0 §16.3]; [ТИПОВО] |
| `ONEC_USER_FILE`, `ONEC_PASSWORD_FILE` | secrets `onec_user`, `onec_password` | пользователь ИБ для OData `pos_integration` (имя — предложение R1 §7): **только** стандартный OData, **только чтение** (allow-list объектов, 05 ONEC-083), без роли HTTP-сервиса `POS_ИнтеграцияPOS` (05 ONEC-052, ONEC-082; 12.1) | **да** | `/run/secrets/onec_user`, `/run/secrets/onec_password` | [РЕШЕНИЕ: R0 §16.3]; R5 §7.4 (`ONEC_USER`, `ONEC_PASSWORD`) |
| `ONEC_HS_USER_FILE`, `ONEC_HS_PASSWORD_FILE` | secrets `onec_hs_user`, `onec_hs_password` | пользователь ИБ HTTP-сервиса расширения (`pos_hs` по 05), отдельный от OData-пользователя | **да** | `/run/secrets/onec_hs_user`, `/run/secrets/onec_hs_password` | [РЕШЕНИЕ: R0 §17.7]; 05_ONEC_INTEGRATION |
| `ONEC_HS_TOKEN_FILE` | secret `onec_hs_token` | значение заголовка `X-POS-Client-Key` — второй фактор при вызовах HTTP-сервиса расширения (05) | **да** | `/run/secrets/onec_hs_token` | [РЕШЕНИЕ: R0 §17.7] |
| `ONEC_CA_CERT_FILE` | secret `onec_ca.pem` (файл CA/самоподписанного сертификата веб-сервера 1С; сам по себе не секрет, но хранится в `secrets/` для единообразия) | доверие сертификату публикации 1С в LAN/VPN без отключения проверки TLS (12.1) | нет (публичный) | пусто — системное хранилище CA | [РЕШЕНИЕ: R0 §16.3]; 05_ONEC_INTEGRATION, 11_SECURITY |
| `ONEC_TIMEOUT_MS`, `ONEC_SYNC_CHECK_TIMEOUT_MS` | `.env` | таймауты фоновых и синхронных запросов к 1С (синхронная проверка при оформлении заказа, `POST /customers/{id}/receivables/refresh`; NFR-PERF-004: ≤ 8 с); при истечении `ONEC_SYNC_CHECK_TIMEOUT_MS` при оформлении — `202` с `warnings[STALE_DATA]` (проверка по снимку), заказ в `submitting`, документ 1С создаёт воркер outbox после коммита (ядро §22.3; владелец — 08 §4.8.1) | нет | `30000`; `6000` | [РЕШЕНИЕ: R0 §16.3; ядро §19.2 — `ONEC_SYNC_CHECK_TIMEOUT_MS` = 6000] |
| `ONEC_SYNC_PAGE_SIZE` | `.env` | размер страницы чтения (`$top`) | нет | `1000` (диапазон 200–2000) | [РЕШЕНИЕ: R0 §17.7]; 05 |
| `ONEC_MAX_CONCURRENCY` | `.env` | число одновременных соединений backend → 1С | нет | `2` | [РЕШЕНИЕ: R0 §17.7]; 05 |
| `ONEC_ODATA_WRITE_ENABLED` | `.env` | запись документов в 1С через OData в режиме `odata_only` (временный режим 05 ONEC-028 — только по письменному решению заказчика) | нет | `false` | [РЕШЕНИЕ: R0 §17.7]; 05; при `true` обязательны `ONEC_ODATA_WRITE_USER_FILE`/`ONEC_ODATA_WRITE_PASSWORD_FILE`, иначе отказ в старте |
| `ONEC_ODATA_WRITE_USER_FILE`, `ONEC_ODATA_WRITE_PASSWORD_FILE` | secrets `onec_odata_write_user`, `onec_odata_write_password` | отдельный пользователь ИБ `pos_odata_write` (05 ONEC-028, ONEC-052) с правом добавления только `ЗаказКлиента`; только `worker`; монтируются **только** при `ONEC_ODATA_WRITE_ENABLED=true`, при выключении режима пользователь блокируется в 1С, секреты удаляются | **да** | пусто (не монтируется) | [РЕШЕНИЕ: ядро §18.1] (имя внесено владельцем словаря по 05 ONEC-028; волна 4); OData-пользователь чтения `pos_integration` прав записи не получает |
| `ONEC_INBOUND_ENABLED` | `.env` | включает входящий обмен `/api/v1/integrations/onec/*` (вариант C-2, 12.3) и отключает все исходящие вызовы backend → 1С (05 ONEC-065); в этом режиме ручной запуск синхронизации недоступен — `POST /sync/runs` → `422` (`rule: inbound_mode`), кнопка на SCR-43 неактивна (ядро §22.8; 05 SYNC-025, 08 §4.17.2); при `true` обязательна непустая `ONEC_INBOUND_ALLOWED_IPS`; аутентификация — технический токен роли `integration` из `integration_tokens`, выпускаемый `bin/issue_integration_token` (без переменной окружения) | нет | `false` (весь префикс → `404`) | [РЕШЕНИЕ: R0 §17.7; ядро §18.2 п.4]; 4.6; источник — 05 §10.1, 08 §4.21 |
| `ONEC_INBOUND_ALLOWED_IPS` | `.env` | allow-list внешних IP/CIDR магазина для входящего обмена C-2 (через запятую); **обязательная** проверка в `pos-api` по реальному IP клиента из `X-Forwarded-For`, выставленного `caddy` (4.6), независимо от фильтра proxy; при динамическом IP — согласованный с заказчиком диапазон провайдера (Q-031); фильтр `remote_ip` в Caddy — необязательный дублирующий слой (DEPLOY-050), правила доступа в proxy не требуются (H-15, DEPLOY-049) | нет | пусто; при `ONEC_INBOUND_ENABLED=true` пустой список — **отказ в старте** `api` (ошибка конфигурации); при `false` не читается | [РЕШЕНИЕ: ядро §18.1] (внесено владельцем словаря; по образцу ядра §18.2 п.13); источник — 05 ONEC-060, ONEC-066 |
| `MANUAL_ORDER_SLA_MIN` | `.env` | SLA ручного оформления заказа в 1С (режим без канала записи): заказы, не сопоставленные дольше, выделяются для эскалации | нет | `60` (минуты, в рабочие часы) | [РЕШЕНИЕ: ядро §18.2 п.14]; Q-119; источник — 05 §9 |
| **Синхронизация** | | | | | |
| `SYNC_STOCK_CRON`, `SYNC_PRICES_CRON`, `SYNC_ORDER_STATUS_CRON`, `SYNC_MASTER_CRON`, `SYNC_IMAGES_CRON`, `SYNC_RECONCILE_CRON` | `.env` | расписания D-29 по умолчанию (остатки 5–10 мин; цены 10–15; статусы 5; мастер-данные/клиенты/долги 30; фото — сутки; сверка — неделя); оперативное переопределение — `app_settings.sync_interval.<entity>` без перезапуска (R0 §17.2) | нет | `*/10 * * * *`; `*/15 * * * *`; `*/5 * * * *`; `*/30 * * * *`; `30 2 * * *`; `0 4 * * 0` (предложение) | имена — этот документ / [РЕШЕНИЕ: R0 §16.3] (в R5 §7.4 отсутствуют); значения — Q-020 |
| `SYNC_NIGHT_WINDOW` | `.env` | окно тяжёлых заданий (первичная загрузка истории, ночные сверки), Asia/Bishkek | нет | `01:00-06:00` | [РЕШЕНИЕ: R0 §17.7]; 05; тяжёлые задания не планируются на время `BACKUP_SCHEDULE` |
| `SALES_HISTORY_MONTHS` | `.env` | глубина первичной загрузки истории продаж (`shipments`) | нет | `12` | [РЕШЕНИЕ: R0 §17.7]; Q-123 (05) |
| `SYNC_COUNT_CHECK_CRON` | `.env` | ночная сверка количества записей 1С ↔ backend в режиме `odata_only` (05 SYNC-068), а также добор элементов `onec_outbox`, не подтверждённых чтением (`sent → confirmed`; для подтверждения состояние `dead` не используется — ядро §22.1, 05 SYNC-045); в окне `SYNC_NIGHT_WINDOW`, не пересекаясь с `BACKUP_SCHEDULE` | нет | `30 3 * * *` (03:30 Asia/Bishkek) | [РЕШЕНИЕ: ядро §18.2 п.14, §22.1]; источник — 05 SYNC-068, SYNC-045 |
| `SYNC_ALERT_UNREACHABLE_MIN` | `.env` | порог непрерывной недоступности 1С в минутах (`onec_reachable=false`; в C-2 — отсутствие `ping` дольше 2× периода, 05 ONEC-064), после которого формируется уведомление `sync_error` и `SyncStatus.overall=failed`; максимальная задержка алерта от начала недоступности — 15 мин (значение больше `14` нарушает AC-SYNC-038) | нет | `10` | [РЕШЕНИЕ: ядро §18.1] (внесено владельцем словаря); источник — 05 SYNC-038, §7.6.1 |
| `OUTBOX_MAX_ATTEMPTS` | `.env` | число попыток доставки элемента `onec_outbox` при **временных** ошибках (таймаут, неизвестный результат, сеть, 5xx — элемент возвращается в `pending`), после которого элемент → `dead` + алерт; заказ при этом остаётся `submitting` с пометкой (07 §6.3, 10 ORD-031). График повторов фиксирован ядром — 1, 2, 5, 15, 60 мин, далее каждые 60 мин (§22.1, §22.13 п.7) — и переменной окружения **не настраивается**; при нём 20 попыток исчерпываются примерно через 15–16 ч, т. е. раньше `OUTBOX_MAX_AGE_HOURS`. Ошибка данных 1С → `failed` без автоповтора; 401/403/ошибка конфигурации → `dead` сразу. Автомат — 07 §6.5 (владелец), обработка — 05 §8 | нет | `20` | [РЕШЕНИЕ: ядро §18.2 п.14 — имя; ядро §22.1 — значение]; уточнение заказчиком — Q-176; источник — 07 §6.5, 05 SYNC-044, 10 ORD-031 |
| `OUTBOX_MAX_AGE_HOURS` | `.env` | максимальный возраст элемента `onec_outbox` (часы) при временных ошибках — от создания, после ручного повтора — от момента повтора (10 ORD-031); по достижении очередная временная ошибка → `dead` + алерт | нет | `24` | [РЕШЕНИЕ: ядро §18.2 п.14 — имя; ядро §22.1 — значение]; уточнение заказчиком — Q-176; источник — 07 §6.5, 05 SYNC-044, 10 ORD-031 |
| **Платежи, долги, возвраты** | | | | | |
| `DEBT_PAYMENTS_FROM_POS` | `.env` | разрешает `POST /payments` — оплату долга без заказа | нет | `false` (→ `403`) | [РЕШЕНИЕ: R0 §17.7]; Q-152 |
| `RETURNS_FROM_POS_ENABLED` | `.env` | **только** автоматическая передача заявок на возврат в 1С через outbox `return_request` (05 SYNC-050); `false` по умолчанию — пока 1С не подтвердит приём таких документов (Q-012/Q-018); при `false` заявка остаётся в backend в статусе `submitted`, печатается и оформляется в 1С вручную (согласование `accepted` — старшим в POS, ядро §22.11), статус заказа `partially_returned` приходит из 1С; правило — 10 RET-012. Наличие сценария возврата в приложении этим флагом не управляется — его включает ключ `app_settings.returns_enabled` (по умолчанию `true`), он же публикуется как `features.returnsFromPos` | нет | `false` | [РЕШЕНИЕ: R0 §17.7; ядро §21 п.1, §22.11]; Q-012, Q-018 |
| `QR_PROVIDER` | `.env` | `none` \| `bakai` | нет | `none` (оплата QR подтверждается вручную) | [РЕШЕНИЕ: R0 §17.7]; Q-014 |
| `QR_TTL_MINUTES` | `.env` | срок действия выданного QR | нет | `15` | [РЕШЕНИЕ: R0 §17.7] |
| `QR_WEBHOOK_ENABLED` | `.env` | включает приём `POST /api/v1/payments/qr/webhook` | нет | `false` (→ `404`) | [РЕШЕНИЕ: R0 §17.7]; 4.6; Q-014 |
| `QR_WEBHOOK_SECRET_FILE` | secret `qr_webhook_secret` | секрет подписи (HMAC) вебхука банка | **да** | `/run/secrets/qr_webhook_secret` (только при `QR_WEBHOOK_ENABLED=true`) | [РЕШЕНИЕ: R0 §16.3]; только при подтверждении API банка (Q-014) |
| `QR_WEBHOOK_PUBLIC_KEY_FILE` | secret `qr_webhook_public.pem` | публичный ключ банка — если подпись вебхука асимметричная (вместо `QR_WEBHOOK_SECRET_FILE`) | нет (публичный; хранится в `secrets/`) | `/run/secrets/qr_webhook_public.pem` (только при `QR_WEBHOOK_ENABLED=true`) | [РЕШЕНИЕ: R0 §17.7] |
| `QR_WEBHOOK_ALLOWED_IPS` | `.env` | allowlist IP/CIDR банка для вебхука | нет | пусто; при `QR_WEBHOOK_ENABLED=true` — обязательна | [РЕШЕНИЕ: R0 §17.7]; обязательная проверка — в `pos-api`, фильтр на `pos-proxy` — необязательный дополнительный слой [РЕШЕНИЕ: ядро §18.2 п.13]; 4.6 |
| **Фото** | | | | | |
| `MEDIA_DIR` | `.env` / `environment:` | путь к тому фото внутри контейнера | нет | `/data/media` | [РЕШЕНИЕ: R0 §16.3] |
| `MEDIA_MAX_SOURCE_PX` | `.env` | предел длинной стороны при приёме фото (размеры хранения — 160/400/1200 px WebP, D-30) | нет | `1600` (предложение) | [РЕШЕНИЕ: R0 §16.3]; Q-105 |
| **Мониторинг и резервное копирование** | | | | | |
| `HEALTHCHECKS_PING_URL_FILE` | secret `healthchecks_url` | ping-URL Healthchecks (UUID — секрет) | **да** | `/run/secrets/healthchecks_url` | R8 §7; [РЕШЕНИЕ: R0 §16.3] |
| `BACKUP_KEEP_DAYS`, `BACKUP_REMOTE`, `BACKUP_SCHEDULE` | `.env` | срок локального хранения дампов; имя remote rclone; расписание бэкапа | нет | `30`; — (`offsite:` условно); `0 3 * * *` | [РЕШЕНИЕ: R0 §16.3] |
| `BACKUP_AGE_RECIPIENT` | `.env` | публичный получатель `age` для шифрования дампов | нет (публичный) | — (обязательна для `backup`) | [РЕШЕНИЕ: R0 §16.3]; Q-106 |
| `BACKUP_AGE_IDENTITY_FILE` | **не на сервере**: машина восстановления / офлайн у заказчика | приватный identity-ключ `age` для расшифровки дампов при восстановлении (8.5) | **да** | — (на сервере не задаётся) | [РЕШЕНИЕ: R0 §17.7]; Q-106; наличие файла на сервере backend — нарушение OPS-004 |
| `RCLONE_CONFIG_FILE` | secret `rclone.conf` | конфигурация rclone с учётными данными хранилища; в контейнере `backup` путь передаётся rclone его стандартной переменной `RCLONE_CONFIG` (4.4, 8.3) | **да** | `/run/secrets/rclone.conf` | [РЕШЕНИЕ: ядро §18.1] (используется только контейнером/скриптом `backup`); источник — 11 §5 |
| `PGPASSWORD_FILE` | `environment:` сервиса `backup` | путь к паролю суперпользователя БД для `pg_dump`; entrypoint образа `optomstroy/backup` читает файл в `PGPASSWORD` (не стандарт `libpq`) | **да** | `/run/secrets/pg_password` | [РЕШЕНИЕ: ядро §18.1] (соглашение образа `backup`); 4.4, примечание 5 |
| `WG_*` (только C-1) | хост, `/etc/wireguard/wg0.conf` (600) | ключи WireGuard | **да** | — | [РЕШЕНИЕ: ядро §18.1] (уровень хоста); вне compose |

Состав словаря после сверки с ядром v1.3 [РЕШЕНИЕ: ядро §18.1, §18.2 п.4, п.12, п.14]. (1) Имена уровня compose/образов/хоста (`API_TAG`, `BACKUP_TAG`, `TZ`, `POSTGRES_USER`/`POSTGRES_DB`/`POSTGRES_PASSWORD_FILE`, `RCLONE_CONFIG_FILE`, `PGPASSWORD_FILE`, `WG_*`) входят в словарь владельца и помечены `[РЕШЕНИЕ: ядро §18.1]`; стандартные переменные образов, задаваемые только в примере compose (`POSTGRES_INITDB_ARGS`, `PGHOST`, `PGUSER`, `PGDATABASE`, `RCLONE_CONFIG`), и локальные переменные скриптов `bin/*.sh` (8.3) приложением не читаются и в таблицу не выносятся. (2) Серверные переменные других документов, ранее не входившие в перечень (§19 №13), включены: из 09 §6.11 — `AUTH_OTP_TEST_CODE`, `OTP_TTL_SECONDS`, `OTP_RESEND_COOLDOWN_SECONDS`, `OTP_MAX_VERIFY_ATTEMPTS`, `OTP_MAX_SENDS_PER_{PHONE_15M,PHONE_24H,IP_10M,IP_24H,DEVICE_10M,DEVICE_24H}`, `OTP_LOCK_AFTER_LOCKED_CODES`, `OTP_PHONE_PAUSE_MINUTES`, `OTP_RESEND_ON_DLR_FAILED`, `OTP_PROVIDER`, `SMSPRO_CB_OPEN_MINUTES`, `SMSPRO_DEF_PRECHECK`, `SMS_OTP_TEMPLATE`, `SMSPRO_OTP_API_KEY_FILE`, `AUTH_ACCESS_TTL_SECONDS`, `AUTH_REFRESH_TTL_{STAFF,CUSTOMER}_DAYS`, `AUTH_REFRESH_IDLE_STAFF_HOURS`, `AUTH_REFRESH_IDLE_CUSTOMER_DAYS`, `AUTH_REFRESH_GRACE_SECONDS`, `AUTH_BACKGROUND_LOCK_MINUTES`, `AUTH_BIO_AUTO_PROMPT`, `AUTH_NOTIFY_OLD_PHONE`, `INVITE_SMS`, `PIN_MIN_LENGTH_STAFF`, `PIN_MAX_ATTEMPTS`, `REGISTRATION_SECOND_OTP`, `FACE_SCAN_MODE`, `FACE_SCAN_STORE_FRAMES`, `FACE_SCAN_REQUIRED`; из 05 — `MANUAL_ORDER_SLA_MIN`, `SYNC_COUNT_CHECK_CRON`; из 10 — `OUTBOX_MAX_ATTEMPTS`, `OUTBOX_MAX_AGE_HOURS`; из 07/09 — `INVITATION_TTL_DAYS`; из 08 — `OPENAPI_PUBLIC`. (3) **Не используются** (в коде и `.env.example` не появляются; встречаются в документах только как историческая ссылка «заменено на»): `INTEGRATION_API_KEY_FILE`, `ONEC_INBOUND_TOKEN_FILE` (§18.2 п.4); `ONEC_INBOUND_ONLY` → `ONEC_INBOUND_ENABLED` (05); `ONEC_WRITE_ENABLED`, `PAYMENTS_ENABLED`, `RETURNS_ENABLED`, `NODE_ENV` (13 v1.0; вместо `NODE_ENV` — `APP_ENV`); `OTP_GLOBAL_SENDS_PER_MIN` → `OTP_GLOBAL_PER_MIN`; `AUTH_IDLE_LOCK_MINUTES` → `SESSION_IDLE_LOCK_MINUTES`; `RECEIVABLES_MAX_AGE` → `RECEIVABLES_MAX_AGE_MIN`; `LOW_STOCK_THRESHOLD`, `CART_STALE_MINUTES`, `PARKED_CART_TTL_DAYS`, `OVERPAY_ALLOWED`, `RETURN_APPROVAL_THRESHOLD`, `RETURNS_ENABLED`, `CASH_ROUNDING`, `DELIVERY_SLOTS`, `VOID_CASH_WINDOW_MIN` → ключи `app_settings` (10, 08); `*_PATH`-варианты R5 §7.4 → `*_FILE`. Обычные (не-`_FILE`) варианты секретов (`DATABASE_URL`, `SMSPRO_LOGIN`, `SMSPRO_PASSWORD`, `OTP_HMAC_SECRET`, `PIN_PEPPER`, `ONEC_USER`, `ONEC_PASSWORD`) — только fallback конвенции `*_FILE` при `APP_ENV=dev` (R0 §16.3; 09 §6.11). (4) **Клиентская конфигурация `pos-app`** (`--dart-define`/`config/*.json`: `API_BASE_URL`, `ENVIRONMENT`/`ENV`, `FEATURE_CUSTOMER_SELF_SERVICE`, `FEATURE_FACE_SCAN`, `FEATURE_FLAGS`, `SENTRY_DSN`, константа `MIN_SUPPORTED_VERSION_CHECK` — 06 §6.9, 11, 13) — не переменные окружения сервера, в словарь 4.3 не входит и секретов не содержит. Платформенные константы (`BIOMETRIC_STRONG`, `AUTH_BIOMETRIC_STRONG`, `FEATURE_STRONGBOX_KEYSTORE`, `CRED_PERSIST_LOCAL_MACHINE`) и переменная `psql` `ON_ERROR_STOP` (13) — не переменные окружения сервера. Имена, ранее числившиеся здесь «вне перечня» (`WORKERS_ENABLED`, `SMSPRO_TIMEOUT_MS`, `SMSPRO_RETRY_MAX`, `SMSPRO_DLR_MODE`, `SMSPRO_DLR_ALLOWED_IPS`, `AUTH_OTP_TEST_MODE`, `CORS_ALLOWED_ORIGINS`), приняты ядром v1.2 (R0 §17.7); замечание K-11 06_ARCHITECTURE снято. (5) **Сверка с ядром v1.4** [РЕШЕНИЕ: ядро §19.2, §19.3]: новых серверных переменных ядро v1.4 не вводит; закреплены значения по умолчанию `AUTH_BACKGROUND_LOCK_MINUTES=5`, `SESSION_IDLE_LOCK_MINUTES=30`, `ONEC_SYNC_CHECK_TIMEOUT_MS=6000`; `CUSTOMER_SELF_SERVICE` — только env (не ключ `app_settings`); `FACE_SCAN_MODE`, `FACE_SCAN_STORE_FRAMES`, `FACE_SCAN_REQUIRED` — R2 (в R1 — `off`/`false`); контакты поддержки — ключ `app_settings.support_contacts`, не переменная окружения. (6) **Сверка с ядром v1.6/v1.7** [РЕШЕНИЕ: ядро §21 п.1, §22]: ядро новых имён не вводит; значения `OUTBOX_MAX_ATTEMPTS=20` и `OUTBOX_MAX_AGE_HOURS=24` закреплены §22.1; график повторов outbox (1, 2, 5, 15, 60 мин, далее каждые 60 мин — §22.13 п.7) — константа, переменной окружения для него нет; `RETURNS_FROM_POS_ENABLED` управляет только outbox заявок в 1С (§21 п.1). Владельцем словаря внесены серверные переменные других документов: из 05 — `ONEC_INBOUND_ALLOWED_IPS` (ONEC-060), `SYNC_ALERT_UNREACHABLE_MIN` (SYNC-038); из 09 — `SMS_STAGING_ALLOWED_PHONES` (§5.8).

**Технические токены роли `integration`** [РЕШЕНИЕ: ядро §18.2 п.4]: хранятся только в таблице `integration_tokens` (хэш токена, `scope`, `expires_at`, `revoked_at`), **без строки в `users`** и без выпуска через `POST /admin/users`; переменных окружения и секрет-файлов `secrets/*` для них **нет**. Выпуск — серверный скрипт оператора `bin/issue_integration_token` (спецификация этапа 1, не для запуска): запускается на сервере пользователем ОС `optomstroy` через `docker compose run --rm api node dist/cli/issue_integration_token.js` (вызов `docker compose` — по варианту прав 6.1/Q-102), параметры — `--scope` (для 1С — `onec_inbound`), `--ttl-days` (по умолчанию и максимум — `180`), `--comment`; скрипт генерирует токен из CSPRNG, сохраняет в `integration_tokens` только его хэш и **один раз** выводит открытое значение в терминал (не в лог, не в файл); оператор передаёт значение администратору 1С защищённым каналом, где оно хранится как секрет расширения. Ротация — выпуск нового токена до истечения срока (180 дней), перенастройка 1С, отзыв старого; отзыв — тем же скриптом (`--revoke <id>`, заполняет `revoked_at`) или `DELETE`-операцией в админ-разделе (R2). Выпуск и отзыв фиксируются в аудите (словарь событий — 11 §7.2). Проверка при приёмке: в `secrets/` и `.env` нет файлов и переменных с токенами роли `integration`; токен с истёкшим `expires_at` или заполненным `revoked_at` → `401`.

Запрещено: помещать секреты в образы, в логи, в видимые через `docker inspect` `environment:` (используем `secrets:`), в git, во Flutter-приложение [ПОДТВЕРЖДЕНО: мастер-промт, строка 446 — зона 11_SECURITY].

#### Пример `.env.example` (спецификация; хранится в git, значений секретов не содержит)

```dotenv
# /opt/optomstroy/prod/.env.example — СПЕЦИФИКАЦИЯ (этап 1). Канонический перечень — таблица 4.3.
# Здесь ТОЛЬКО несекретная конфигурация. Секреты — файлы secrets/* (600); указатели *_FILE
# на /run/secrets/* задаются в docker-compose.yml (4.4), а не в этом файле.
# Пустое значение после «=» — переменная обязательна и заполняется при деплое.

# --- Общие и платформа ---
APP_ENV=                              # prod | staging | dev
API_TAG=                              # неизменяемый тег optomstroy/api (не latest)
BACKUP_TAG=                           # неизменяемый тег optomstroy/backup
PUBLIC_BASE_URL=                      # https://api.<домен> (Q-032)
LOG_LEVEL=info
TZ=Asia/Bishkek
WORKERS_ENABLED=false                 # D-45: в сервисе worker переопределяется на true (4.4)
APP_READ_ONLY=false                   # true — режим сдерживания инцидента (503 APP_READ_ONLY)
# CORS_ALLOWED_ORIGINS — R2 (web-таргет), в R1-пример не входит (граница R1/R2 — после таблицы 4.3)
OPENAPI_PUBLIC=false                  # true только на тестовом контуре (08 §4.19.2)
MIN_APP_VERSION=                      # platform=semver через запятую: android=1.2.0,windows=1.2.0 (R0 §18.2 п.12)
RECOMMENDED_APP_VERSION=              # тот же формат; пусто — заголовок X-Recommended-App-Version не отправляется
CUSTOMER_SELF_SERVICE=false           # только env, не app_settings (R0 §19.2); features.customerSelfService
RECEIVABLES_MAX_AGE_MIN=60

# --- База данных ---
POSTGRES_USER=                        # optomstroy_prod / optomstroy_test
POSTGRES_DB=                          # optomstroy_prod / optomstroy_test

# --- Аутентификация, OTP, PIN ---
JWT_KEY_ID=                           # kid активного ключа подписи
OTP_HMAC_SECRET_VERSION=1
PIN_PEPPER_VERSION=1
SESSION_IDLE_LOCK_MINUTES=30
AUTH_OTP_TEST_MODE=false              # true допустимо только при APP_ENV=staging|dev
AUTH_OTP_TEST_PHONES=                 # только staging|dev; в prod — пусто
AUTH_OTP_TEST_CODE=                   # только staging|dev; в prod — пусто
OTP_GLOBAL_PER_MIN=60
OTP_PROVIDER=internal                 # internal | smspro (smspro — только R2, Q-242)
OTP_TTL_SECONDS=300
OTP_RESEND_COOLDOWN_SECONDS=60
OTP_MAX_VERIFY_ATTEMPTS=5
OTP_MAX_SENDS_PER_PHONE_15M=3
OTP_MAX_SENDS_PER_PHONE_24H=10
OTP_MAX_SENDS_PER_IP_10M=20
OTP_MAX_SENDS_PER_IP_24H=100
OTP_MAX_SENDS_PER_DEVICE_10M=5
OTP_MAX_SENDS_PER_DEVICE_24H=20
OTP_LOCK_AFTER_LOCKED_CODES=3
OTP_PHONE_PAUSE_MINUTES=30
OTP_RESEND_ON_DLR_FAILED=true
AUTH_ACCESS_TTL_SECONDS=900
AUTH_REFRESH_TTL_STAFF_DAYS=7
AUTH_REFRESH_TTL_CUSTOMER_DAYS=30
AUTH_REFRESH_IDLE_STAFF_HOURS=24
AUTH_REFRESH_IDLE_CUSTOMER_DAYS=14
AUTH_REFRESH_GRACE_SECONDS=30
AUTH_BACKGROUND_LOCK_MINUTES=5
AUTH_BIO_AUTO_PROMPT=true
AUTH_NOTIFY_OLD_PHONE=false           # Q-038 (платная SMS)
PIN_MIN_LENGTH_STAFF=6
PIN_MAX_ATTEMPTS=5

# --- SMSPro ---
SMS_PROVIDER=                         # smspro (prod) | fake (test)
SMSPRO_BASE_URL=https://smspro.nikita.kg/api
SMSPRO_SENDER=                        # согласуется с SMSPro (Q-029)
SMSPRO_TEST_FLAG=false                # true только при APP_ENV=staging|dev; при prod — отказ в старте
# SMS_STAGING_ALLOWED_PHONES — условная: только APP_ENV=staging (09 §5.8); в прод-пример не входит
SMSPRO_TIMEOUT_MS=15000
SMSPRO_RETRY_MAX=3
SMSPRO_DLR_MODE=poll                  # poll | push
# SMSPRO_DLR_ALLOWED_IPS — условная: задаётся только при SMSPRO_DLR_MODE=push (4.6)
SMSPRO_BALANCE_POLL_MINUTES=15
SMSPRO_BALANCE_ALERT_SOM=300
SMSPRO_CB_OPEN_MINUTES=5
SMSPRO_DEF_PRECHECK=false
SMS_OTP_TEMPLATE="Kod: {code}. Optomstroy"   # текст — Q-029; ровно одна часть SMS

# --- Регистрация, приглашения, FACE-SCAN ---
INVITATION_TTL_DAYS=30                # Q-141
INVITE_SMS=false
REGISTRATION_SECOND_OTP=false
# FACE_SCAN_MODE / FACE_SCAN_STORE_FRAMES / FACE_SCAN_REQUIRED — R2 (Q-003), в R1-пример не входят

# --- 1С ---
ONEC_MODE=                            # extension | odata_only | fixtures (fixtures запрещён при prod)
ONEC_BASE_URL=                        # https://<хост 1С>/<база> (Q-031)
ONEC_ODATA_PATH=odata/standard.odata
ONEC_HS_PATH=                         # hs/<имя> (05_ONEC_INTEGRATION)
ONEC_TIMEOUT_MS=30000
ONEC_SYNC_CHECK_TIMEOUT_MS=6000         # R0 §19.2
ONEC_SYNC_PAGE_SIZE=1000
ONEC_MAX_CONCURRENCY=2
ONEC_ODATA_WRITE_ENABLED=false
ONEC_INBOUND_ENABLED=false            # true только в сценарии C-2 и только при ONEC_MODE=extension (12.3, 4.6); токен — bin/issue_integration_token
# ONEC_INBOUND_ALLOWED_IPS — условная: обязательна при ONEC_INBOUND_ENABLED=true (05 ONEC-060; пусто — отказ в старте)
MANUAL_ORDER_SLA_MIN=60               # Q-119

# --- Синхронизация (значения по умолчанию; переопределение — app_settings.sync_interval.<entity>) ---
SYNC_STOCK_CRON="*/10 * * * *"
SYNC_PRICES_CRON="*/15 * * * *"
SYNC_ORDER_STATUS_CRON="*/5 * * * *"
SYNC_MASTER_CRON="*/30 * * * *"
SYNC_IMAGES_CRON="30 2 * * *"
SYNC_RECONCILE_CRON="0 4 * * 0"
SYNC_NIGHT_WINDOW=01:00-06:00
SALES_HISTORY_MONTHS=12
SYNC_COUNT_CHECK_CRON="30 3 * * *"    # сверка odata_only + добор sent→confirmed; не пересекается с BACKUP_SCHEDULE
SYNC_ALERT_UNREACHABLE_MIN=10         # 05 SYNC-038; алерт о недоступности 1С не позже 15 мин
OUTBOX_MAX_ATTEMPTS=20                # ядро §22.1 (Q-176); график повторов фиксирован, не env
OUTBOX_MAX_AGE_HOURS=24               # ядро §22.1 (Q-176)

# --- Платежи, долги, возвраты ---
DEBT_PAYMENTS_FROM_POS=false          # Q-152
RETURNS_FROM_POS_ENABLED=false        # только outbox заявок на возврат в 1С (ядро §21 п.1); сценарий возврата — app_settings.returns_enabled
QR_PROVIDER=none                      # none | bakai (Q-014)
QR_TTL_MINUTES=15
QR_WEBHOOK_ENABLED=false
# QR_WEBHOOK_ALLOWED_IPS — условная: задаётся только при QR_WEBHOOK_ENABLED=true (после Q-014)

# --- Фото ---
MEDIA_DIR=/data/media
MEDIA_MAX_SOURCE_PX=1600

# --- Резервное копирование ---
BACKUP_KEEP_DAYS=30
BACKUP_REMOTE=                        # имя remote rclone, например offsite:
BACKUP_SCHEDULE="0 3 * * *"
BACKUP_AGE_RECIPIENT=                 # публичный получатель age (age1...)
# BACKUP_AGE_IDENTITY_FILE — НЕ на сервере (машина восстановления, офлайн у заказчика)
```

Значения с пробелами (cron) взяты в кавычки; встроенный комментарий `#` у значения без кавычек допускается только после пробела [ТИПОВО: синтаксис `env_file` Docker Compose — https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax]. Проверка полноты: каждое имя таблицы 4.3 с местом `.env`, **кроме** перечня «R2 и условные» ниже, присутствует в `.env.example`, и наоборот (DEPLOY-014).

**Граница R1 / R2 для конфигурации** [РЕШЕНИЕ: ядро §19.3 — FACE-SCAN в R2; D-37, D-39 — web-таргет вне R1; Q-014]. Таблица 4.3 остаётся единым словарём (R0 §18.1), но переменные делятся на две группы. (1) **R1 (обязательные и с R1-значением по умолчанию)** — все имена таблицы, кроме группы (2); входят в `.env.example` и в схему валидации конфигурации R1. (2) **R2 и условные — в `.env.example` R1 не включаются**: `FACE_SCAN_MODE`, `FACE_SCAN_STORE_FRAMES`, `FACE_SCAN_REQUIRED` (R2; в R1 код их не читает, FACE-SCAN отсутствует); `CORS_ALLOWED_ORIGINS` (web-таргет R2; в R1 читается только проверкой SEC-056 «`*` при `prod` — отказ в старте»); `SMSPRO_DLR_ALLOWED_IPS` (только при `SMSPRO_DLR_MODE=push`); `QR_WEBHOOK_ALLOWED_IPS`, `QR_WEBHOOK_SECRET_FILE`, `QR_WEBHOOK_PUBLIC_KEY_FILE` (только при `QR_WEBHOOK_ENABLED=true`, после ответа на Q-014); `SMSPRO_OTP_API_KEY_FILE` (только `OTP_PROVIDER=smspro`, R2); `ONEC_ODATA_WRITE_USER_FILE`/`ONEC_ODATA_WRITE_PASSWORD_FILE` (только временный режим ONEC-028); `ONEC_INBOUND_ALLOWED_IPS` (только при `ONEC_INBOUND_ENABLED=true`, вариант C-2; при включённом флаге пустое значение — отказ в старте); `SMS_STAGING_ALLOWED_PHONES` (только `APP_ENV=staging`). Условные переменные валидируются **только** при включённом флаге-родителе (иначе не читаются); переменные R2 добавляются в `.env.example` вместе с релизом R2. Флаги `QR_WEBHOOK_ENABLED`, `SMSPRO_DLR_MODE`, `OTP_PROVIDER`, `ONEC_ODATA_WRITE_ENABLED` остаются в R1-примере со значениями «выключено», т. к. публикуются клиенту или участвуют в проверках старта (4.3, OPS-027).

### 4.4. Пример `docker-compose.yml` (спецификация, без секретов; тег-плейсхолдеры заменяются при деплое)

```yaml
# /opt/optomstroy/prod/docker-compose.yml — СПЕЦИФИКАЦИЯ (этап 1), не для запуска
name: optomstroy-prod

x-common: &common
  restart: unless-stopped
  logging:
    driver: json-file
    options: { max-size: "20m", max-file: "5" }
  security_opt: [ "no-new-privileges:true" ]

# Указатели на секреты (сами пути не секретны). Вынесены в отдельный якорь,
# потому что слияние `<<:` в YAML ПОВЕРХНОСТНОЕ: ключ `environment:` в сервисе
# полностью заменил бы карту, унаследованную из якоря. Поэтому каждый сервис подключает
# `<<: *secret-env` внутри своего `environment:` (см. api/worker ниже).
# Якорь содержит только указатели, общие для api и worker; указатели на секреты,
# нужные лишь api (JWT_PRIVATE_KEY_FILE, OTP_HMAC_SECRET_FILE, PIN_PEPPER_FILE, входящие
# интеграции), задаются в самом api — иначе worker получил бы *_FILE на НЕсмонтированный
# файл (минимум прав, H-7). Перечень имён — таблица 4.3 (владелец словаря, R0 §18.1).
x-secret-env: &secret-env
  DATABASE_URL_FILE: /run/secrets/database_url
  JWT_PUBLIC_KEY_FILE: /run/secrets/jwt_public.json   # набор {kid: pem} (R0 §17.7)
  SMSPRO_LOGIN_FILE: /run/secrets/smspro_login
  SMSPRO_PASSWORD_FILE: /run/secrets/smspro_password
  ONEC_USER_FILE: /run/secrets/onec_user               # OData (pos_integration)
  ONEC_PASSWORD_FILE: /run/secrets/onec_password
  ONEC_HS_USER_FILE: /run/secrets/onec_hs_user         # HTTP-сервис расширения (pos_hs, 05)
  ONEC_HS_PASSWORD_FILE: /run/secrets/onec_hs_password
  ONEC_HS_TOKEN_FILE: /run/secrets/onec_hs_token       # заголовок X-POS-Client-Key (05)
  ONEC_CA_CERT_FILE: /run/secrets/onec_ca.pem
  MEDIA_DIR: /data/media

x-app: &app
  <<: *common
  image: optomstroy/api:${API_TAG}
  user: "10001:10001"              # non-root пользователь образа
  read_only: true
  tmpfs: [ "/tmp" ]
  cap_drop: [ "ALL" ]
  env_file: .env                   # несекретная конфигурация (4.3), в т.ч. MIN_APP_VERSION
  # environment/secrets НЕ задаются в якоре: каждый сервис объявляет свои (слияние
  # поверхностное, а набор секретов у migrate/api/worker разный — минимум прав).
  networks: [ edge, backend ]

services:
  caddy:
    <<: *common
    image: caddy:2.10.0            # плейсхолдер: точный тег фиксируется при деплое
    ports: [ "80:80", "443:443" ]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - media:/srv/media:ro
    networks: [ edge ]
    # Намеренно БЕЗ depends_on: api — proxy поднимается независимо (ACME-валидация
    # на шаге 3 плана 14.1 до миграций и api; перевыпуск сертификата при упавшем api,
    # runbook 15.4). При недоступном api Caddy отдаёт 502 на /api/* и /health*.
    deploy: { resources: { limits: { memory: 256M, cpus: "0.5" } } }

  migrate:
    <<: *app
    command: [ "node", "dist/migrate.js" ]
    restart: "no"
    environment:
      DATABASE_URL_FILE: /run/secrets/database_url   # migrate нужна только БД (хост/порт/БД)
      DB_MIGRATOR_PASSWORD_FILE: /run/secrets/db_migrator_password  # роль pos_migrate — владелец схемы (07 DATA-012)
      WORKERS_ENABLED: "false"
    secrets: [ database_url, db_migrator_password ]
    networks: [ backend ]
    depends_on:
      postgres: { condition: service_healthy }

  api:
    <<: *app
    command: [ "node", "dist/main.js" ]
    environment:
      <<: *secret-env              # общие указатели (поверхностное слияние — см. примечание 6)
      JWT_PRIVATE_KEY_FILE: /run/secrets/jwt_private.pem   # подпись токенов (kid = JWT_KEY_ID) — только api
      OTP_HMAC_SECRET_FILE: /run/secrets/otp_pepper         # HMAC OTP — только api
      PIN_PEPPER_FILE: /run/secrets/pin_pepper              # Argon2id PIN (D-48) — только api
      WORKERS_ENABLED: "false"     # D-45: только HTTP; задачи pg-boss исполняет worker
      # Входящие интеграции (4.6) — раскомментировать ВМЕСТЕ с секретом ниже и флагом в .env.
      # Входящий обмен 1С (ONEC_INBOUND_ENABLED=true, C-2) секрет-файла НЕ требует: токены роли
      # integration — только в таблице integration_tokens, выпуск bin/issue_integration_token (R0 §18.2 п.4).
      # QR_WEBHOOK_SECRET_FILE: /run/secrets/qr_webhook_secret            # QR_WEBHOOK_ENABLED=true (Q-014)
      # QR_WEBHOOK_PUBLIC_KEY_FILE: /run/secrets/qr_webhook_public.pem    # вместо SECRET при асимметричной подписи
    secrets: [ database_url, jwt_private.pem, jwt_public.json, otp_pepper, pin_pepper,
               smspro_login, smspro_password, onec_user, onec_password,
               onec_hs_user, onec_hs_password, onec_hs_token, onec_ca.pem ]
               # + qr_webhook_* — только при включении QR-вебхука
    volumes: [ "media:/data/media" ]
    expose: [ "3000" ]             # без ports: — доступен только из сетей compose
    healthcheck:
      test: [ "CMD", "wget", "-qO-", "http://localhost:3000/health" ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 40s
    depends_on:
      postgres: { condition: service_healthy }
      migrate:  { condition: service_completed_successfully }
    deploy: { resources: { limits: { memory: 1G, cpus: "1.5" } } }

  worker:
    <<: *app
    command: [ "node", "dist/worker.js" ]
    environment:
      <<: *secret-env
      WORKERS_ENABLED: "true"      # D-45: тот же код в роли воркера (pg-boss в PostgreSQL, без Redis — D-44)
      HEALTHCHECKS_PING_URL_FILE: /run/secrets/healthchecks_url
      # Только временный режим записи через OData (05 ONEC-028, ONEC_ODATA_WRITE_ENABLED=true;
      # пользователь pos_odata_write) — раскомментировать вместе с секретами ниже:
      # ONEC_ODATA_WRITE_USER_FILE: /run/secrets/onec_odata_write_user
      # ONEC_ODATA_WRITE_PASSWORD_FILE: /run/secrets/onec_odata_write_password
    secrets: [ database_url, jwt_public.json, smspro_login, smspro_password,
               onec_user, onec_password, onec_hs_user, onec_hs_password, onec_hs_token,
               onec_ca.pem, healthchecks_url ]
               # + onec_odata_write_* — только при ONEC_ODATA_WRITE_ENABLED=true (ONEC-028)
    volumes: [ "media:/data/media" ]
    depends_on:
      postgres: { condition: service_healthy }
      migrate:  { condition: service_completed_successfully }
    deploy: { resources: { limits: { memory: 1G, cpus: "1.0" } } }

  postgres:
    <<: *common
    image: postgres:17.6           # плейсхолдер минорной версии
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
      POSTGRES_INITDB_ARGS: "--data-checksums"
    command: >
      postgres -c shared_buffers=1GB -c work_mem=16MB
               -c log_min_duration_statement=500ms
               -c shared_preload_libraries=pg_stat_statements
               -c wal_level=replica
    secrets: [ pg_password ]
    volumes: [ "pgdata:/var/lib/postgresql/data" ]   # для postgres:18+ — /var/lib/postgresql
    networks: [ backend ]          # только internal-сеть, порты НЕ публикуются
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB" ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    deploy: { resources: { limits: { memory: 2G, cpus: "2.0" } } }
    shm_size: 256m

  backup:
    <<: *common
    image: optomstroy/backup:${BACKUP_TAG}   # postgres-client + rclone + age; cron внутри
    env_file: .env
    environment:
      PGHOST: postgres
      PGUSER: ${POSTGRES_USER}
      PGDATABASE: ${POSTGRES_DB}
      PGPASSWORD_FILE: /run/secrets/pg_password
      RCLONE_CONFIG: /run/secrets/rclone.conf
      HEALTHCHECKS_PING_URL_FILE: /run/secrets/healthchecks_url
    secrets: [ pg_password, rclone.conf, healthchecks_url ]
    volumes:
      - backups:/backups
      - media:/data/media:ro
    networks: [ edge, backend ]
    depends_on:
      postgres: { condition: service_healthy }
    deploy: { resources: { limits: { memory: 512M, cpus: "0.5" } } }

  # pgadmin — опционально, только для администрирования через SSH-туннель
  # pgadmin:
  #   image: dpage/pgadmin4:<версия>
  #   ports: [ "127.0.0.1:5050:80" ]
  #   networks: [ edge, backend ]
  #   volumes: [ "pgadmin:/var/lib/pgadmin" ]

networks:
  edge:
    name: optomstroy_prod_edge       # явное имя по R0 §16.6 (без name: было бы optomstroy-prod_edge)
  backend:
    name: optomstroy_prod_backend
    internal: true

volumes:
  pgdata:
    driver_opts: { type: none, o: bind, device: /srv/optomstroy/prod/pgdata }
  media:
    driver_opts: { type: none, o: bind, device: /srv/optomstroy/prod/media }
  backups:
    driver_opts: { type: none, o: bind, device: /srv/optomstroy/prod/backups }
  caddy_data: {}
  caddy_config: {}

secrets:
  pg_password:      { file: ./secrets/pg_password }
  database_url:     { file: ./secrets/database_url }
  db_migrator_password: { file: ./secrets/db_migrator_password }   # только migrate
  jwt_private.pem:  { file: ./secrets/jwt_private.pem }
  jwt_public.json:  { file: ./secrets/jwt_public.json }  # {kid: pem}, не секрет
  otp_pepper:       { file: ./secrets/otp_pepper }
  pin_pepper:       { file: ./secrets/pin_pepper }
  smspro_login:     { file: ./secrets/smspro_login }
  smspro_password:  { file: ./secrets/smspro_password }
  onec_user:        { file: ./secrets/onec_user }
  onec_password:    { file: ./secrets/onec_password }
  onec_hs_user:     { file: ./secrets/onec_hs_user }
  onec_hs_password: { file: ./secrets/onec_hs_password }
  onec_hs_token:    { file: ./secrets/onec_hs_token }
  onec_ca.pem:      { file: ./secrets/onec_ca.pem }     # CA публикации 1С (не секрет; пусто — не монтировать)
  healthchecks_url: { file: ./secrets/healthchecks_url }
  rclone.conf:      { file: ./secrets/rclone.conf }
  # Только при включении соответствующей интеграции (4.6); иначе файл не создаётся и строка закомментирована:
  # qr_webhook_secret:     { file: ./secrets/qr_webhook_secret }
  # qr_webhook_public.pem: { file: ./secrets/qr_webhook_public.pem }
  # onec_odata_write_user:     { file: ./secrets/onec_odata_write_user }      # только ONEC-028
  # onec_odata_write_password: { file: ./secrets/onec_odata_write_password }  # только ONEC-028
  # BACKUP_AGE_IDENTITY_FILE (приватный ключ age) на сервере НЕ хранится (R0 §17.7, OPS-004).
```

Примечания к спецификации: (1) `depends_on … condition: service_healthy / service_completed_successfully` и параметры `healthcheck` — по документации Compose [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/services/#healthcheck]; (2) значения `shared_buffers`/лимитов — для 8 GB RAM (раздел 5), при 4 GB — `shared_buffers=512MB`, лимит `postgres` 1.5G; (3) `wal_level=replica` оставлен для будущего PITR (R2, Q-033) — без `archive_mode` накладные расходы минимальны [ТИПОВО: PostgreSQL]; (4) при одном Caddy на prod и test — `caddy` выносится в отдельный проект `optomstroy-edge` с подключением к сетям обоих проектов (раздел 11); (5) `PGPASSWORD_FILE` в `backup` — соглашение образа `optomstroy/backup` (entrypoint читает файл в `PGPASSWORD`), не стандарт `libpq` [РЕШЕНИЕ: ядро §18.1]; роль миграций в `migrate` — `pos_migrate` (4.3; имя — по 07 DATA-012); (6) **слияние YAML-якорей поверхностное**: `<<: *app` копирует верхний уровень, а ключ `environment:`, объявленный в сервисе, **полностью замещает** карту `environment` якоря (не объединяет её) [ПОДТВЕРЖДЕНО: YAML Merge Key spec; https://docs.docker.com/reference/compose-file/fragments/] — поэтому общие указатели `*_FILE` вынесены в `x-secret-env` и подключаются внутри `environment:` каждого сервиса, а якорь `x-app` не содержит ни `environment`, ни `secrets`; набор секретов — по минимуму прав: `migrate` — только `database_url` и `db_migrator_password` (роль-владелец схемы, R0 §17.7); `api` — полный (включая `jwt_private.pem`, `otp_pepper`, `pin_pepper`, а при включении QR-вебхука — `qr_webhook_*`, 4.6; для входящего обмена 1С секрет-файл не нужен — токены роли `integration` только в `integration_tokens`, R0 §18.2 п.4); `worker` — без ключа подписи JWT, pepper OTP/PIN и секретов входящих интеграций (указатели `JWT_PRIVATE_KEY_FILE`/`OTP_HMAC_SECRET_FILE`/`PIN_PEPPER_FILE` ему не передаются, чтобы не ссылаться на несмонтированный файл); `api` и `worker` — один образ модульного монолита, роль задаётся командой и `WORKERS_ENABLED` [РЕШЕНИЕ: D-45]; отдельного сервиса Redis нет [РЕШЕНИЕ: D-44]; ключ `secrets:` в сервисе также замещает, а не дополняет список; сети названы явно (`name:`) по R0 §16.6 — без этого Compose дал бы имена с префиксом проекта `optomstroy-prod_edge` [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/networks/#name]; (7) `caddy` намеренно не зависит от `api` и не имеет healthcheck через `/health` (иначе proxy считался бы нездоровым при любом простое `api`, а ACME-валидация на шаге 3 плана 14.1 была бы невозможна) — доступность через proxy контролирует внешний монитор (раздел 9); при недоступном `api` Caddy отвечает 502 [ТИПОВО: reverse_proxy Caddy].

### 4.5. Пример `Caddyfile` (спецификация)

```caddyfile
# /opt/optomstroy/prod/Caddyfile — СПЕЦИФИКАЦИЯ. Имена хостов — плейсхолдеры (Q-032).
{
    email admin@<домен>            # контакт для ACME; согласовать
    # acme_ca https://acme-staging-v02.api.letsencrypt.org/directory   # только на время отладки
}

api.<домен> {
    encode zstd gzip

    # Заголовки безопасности — 11 SEC-003, SEC-018; 08 §2 (API-033); R6 §7.2 (OWASP HTTP Headers CS).
    # Caddy ЗАДАЁТ (заменяет) значения — дубликатов с заголовками pos-api не возникает.
    # preload в HSTS — только после проверки домена на hstspreload.org и решения заказчика (Q-032).
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Content-Security-Policy "frame-ancestors 'none'"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
        -X-Powered-By
    }

    # Фото: контент-адресуемые пути, неизменяемый кэш (D-30).
    # URL канона R0 §7 / 08_API — /images/{sha}/{size} БЕЗ расширения, файл на диске —
    # images/{sha}/{size}.webp (D-30): try_files подставляет расширение.
    handle_path /images/* {
        root * /srv/media/images
        try_files {path}.webp {path}
        header Cache-Control "public, max-age=31536000, immutable"
        file_server
    }

    # Health для внешнего монитора (без авторизации, без чувствительных данных)
    handle /health* {
        reverse_proxy api:3000
    }

    # API. read_timeout 30s покрывает long-polling GET /api/v1/payments/{id}?wait= (≤ 25 с, R0 §17.4).
    handle /api/* {
        reverse_proxy api:3000 {
            header_up X-Request-Id {http.request.uuid}
            transport http { read_timeout 30s }
        }
    }

    # Входящие интеграции (правила — 4.6; R0 §16.5, §17.4): /api/v1/integrations/onec/*
    # (вариант C-2), /api/v1/integrations/smspro/dlr (push-DLR), /api/v1/payments/qr/webhook.
    # Тот же upstream api:3000; Bearer на границе не проверяется. Аутентификация (токен
    # integration / подпись банка) и проверка IP по *_ALLOWED_IPS (4.3) — ТОЛЬКО в api;
    # выключенная интеграция → 404 из api (ONEC_INBOUND_ENABLED / SMSPRO_DLR_MODE /
    # QR_WEBHOOK_ENABLED). Caddy подставляет реальный IP клиента в X-Forwarded-For
    # (входящий X-Forwarded-For от недоверенного клиента не принимается).
    # Пути более специфичны, чем /api/*, — Caddy сортирует handle по специфичности пути.
    handle /api/v1/integrations/* {
        # Необязательный сетевой фильтр (defence-in-depth, DEPLOY-050) — только при
        # статических IP источников; НЕ заменяет проверку в api:
        # @dlr_foreign {
        #     path /api/v1/integrations/smspro/dlr
        #     not remote_ip <IP/CIDR шлюза SMSPro — те же, что SMSPRO_DLR_ALLOWED_IPS>
        # }
        # respond @dlr_foreign 403
        # @onec_foreign {
        #     path /api/v1/integrations/onec/*
        #     not remote_ip <IP/CIDR магазина — те же, что ONEC_INBOUND_ALLOWED_IPS>
        # }
        # respond @onec_foreign 403
        reverse_proxy api:3000 {
            header_up X-Request-Id {http.request.uuid}
            transport http { read_timeout 30s }
        }
    }
    handle /api/v1/payments/qr/webhook {
        # @qr_foreign not remote_ip <IP/CIDR банка — те же, что QR_WEBHOOK_ALLOWED_IPS>
        # respond @qr_foreign 403
        reverse_proxy api:3000 {
            header_up X-Request-Id {http.request.uuid}
        }
    }
    # Отдельного блока /integrations/* на корне НЕТ (только под /api/v1).
    # Proxy НЕ выполняет авторизацию: проверка прав — только в api (DEPLOY-049).

    # Всё остальное — 404 (веб-таргет вне R1, D-39)
    respond 404

    log {
        output file /data/access.log { roll_size 20MiB roll_keep 5 }
        format json
    }
}

# HTTP → HTTPS редирект Caddy выполняет автоматически (automatic HTTPS).
```

Ограничения размера тела (`request_body max_size`) и rate-limit — на уровне `api` [РЕШЕНИЕ: D-37]; при необходимости дублируются в Caddy на этапе 2. Примечания: (1) `try_files {path}.webp {path}` — директива Caddy `file_server`/`try_files` [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/caddyfile/directives/try_files]; если 08_API окончательно зафиксирует публичный путь фото с префиксом `/api/v1/images/...` (так записано в схеме `Image` 08_API §3.6; эндпоинт 4.4.7 там же — `/images/{sha}/{size}`), блок переименовывается в `handle_path /api/v1/images/*` и ставится **до** блока `/api/*` — расхождение внутри 08_API отмечено в разделе 19 (№10); (2) Caddy не содержит ни одной проверки аутентификации/авторизации: маршруты без Bearer пользователя — `/health*`, статика `/images/*` (без Bearer в R1 по 08_API) и входящие интеграции 4.6 (технический токен/подпись/IP-allowlist проверяет `api`; необязательный `remote_ip` в Caddy — лишь дублирующий сетевой слой, DEPLOY-050) — все решения о доступе принимает `api` на каждом запросе (11_SECURITY_PRIVACY SEC-028, SEC-029; DEPLOY-049) [ПОДТВЕРЖДЕНО: SRC-F-138c].

### 4.6. Входящие интеграционные маршруты: правила proxy и allowlist [РЕШЕНИЕ: R0 §16.5, §17.4, §17.7]

Входящие вызовы от внешних систем (1С в варианте C-2, шлюз SMSPro, банк) — единственные маршруты под `/api/v1`, которые не используют Bearer access JWT пользователя. Общие правила: (1) маршруты живут только под `/api/v1/...` и проксируются тем же `caddy` на `api:3000`; `worker` входящих HTTP не принимает; (2) proxy **не** аутентифицирует и не авторизует (DEPLOY-049) — токен роли `integration`, подпись банка и IP-allowlist проверяет `api` (deny by default); (3) `api` определяет IP источника только по `X-Forwarded-For`, выставленному `caddy` (доверенный прокси — только адрес `caddy` в сети `edge`; `reverse_proxy` Caddy не доверяет входящему `X-Forwarded-For` от клиентов без настройки `trusted_proxies` [ТИПОВО: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy, раздел о заголовках по умолчанию]); (4) выключенная интеграция отвечает `404` из `api` (маршрут неотличим от несуществующего); (5) необязательный сетевой фильтр `remote_ip` в Caddy (закомментирован в 4.5) — только дублирующий слой при статических IP источника, он не является авторизацией и не отменяет проверку в `api` (DEPLOY-050); (6) лимиты размера тела и rate-limit — в `api` (D-37; счётчики rate-limit — в PostgreSQL, D-44): превышение тела → `413 PAYLOAD_TOO_LARGE`, неверный тип → `415 UNSUPPORTED_MEDIA_TYPE`, превышение частоты → `429` (R0 §17.4); (7) обработка тяжёлых пакетов — асинхронно через pg-boss (`worker`), HTTP-ответ — в пределах `read_timeout` proxy (30 с).

| Маршрут (R0 §17.4) | Включение (по умолчанию) | Аутентификация (в `api`) | Allowlist IP | Proxy (`caddy`) | Секреты / переменные |
|---|---|---|---|---|---|
| `POST /api/v1/integrations/onec/changes`, `POST /api/v1/integrations/onec/snapshots/{entity}`, `POST /api/v1/integrations/onec/order-status`, `GET /api/v1/integrations/onec/outbox`, `POST /api/v1/integrations/onec/outbox/{outboxId}/ack`, `GET /api/v1/integrations/onec/ping` (вариант `heartbeat` не используется) | только сценарий C-2: `ONEC_INBOUND_ENABLED=true` (допустимо только при `ONEC_MODE=extension`) (по умолчанию `false` → `404` на всём префиксе) | технический токен роли `integration` (хэш в `integration_tokens`, R0 §17.3; без строки в `users`); выпуск и отзыв — `bin/issue_integration_token` (токен показывается один раз), срок жизни 180 дней с ротацией (4.3) [РЕШЕНИЕ: ядро §18.2 п.4]; токен роли `integration` не даёт доступа к иным путям (`403`); отдельный rate-limit | **обязателен** в `api`: IP источника ∈ `ONEC_INBOUND_ALLOWED_IPS` (при динамическом IP — согласованный диапазон провайдера, Q-031), иначе `403`; пустой список при `ONEC_INBOUND_ENABLED=true` — отказ в старте (05 ONEC-060); дополнительно — фильтр `remote_ip` в Caddy (опц.) | `handle /api/v1/integrations/*` → `api:3000`, `read_timeout 30s`; без `basic_auth`/`forward_auth` | `ONEC_INBOUND_ENABLED`, `ONEC_INBOUND_ALLOWED_IPS` (секрет-файла нет — токены в `integration_tokens`) |
| `POST /api/v1/integrations/smspro/dlr` | только `SMSPRO_DLR_MODE=push` и непустой `SMSPRO_DLR_ALLOWED_IPS` (по умолчанию `poll` → `404`) | без Bearer; принимаются только известные `id` сообщений; ответ `200` ≤ 1 с, обработка в фоне (09) | **обязателен** в `api`: IP источника ∈ `SMSPRO_DLR_ALLOWED_IPS`, иначе `403`; дополнительно — фильтр `remote_ip` в Caddy (опц.) | тот же блок `handle /api/v1/integrations/*` | `SMSPRO_DLR_MODE`, `SMSPRO_DLR_ALLOWED_IPS` |
| `POST /api/v1/payments/qr/webhook` | только при подтверждении API банка (Q-014): `QR_PROVIDER=bakai` и `QR_WEBHOOK_ENABLED=true` (по умолчанию `false` → `404`) | подпись банка: `QR_WEBHOOK_SECRET_FILE` (HMAC) или `QR_WEBHOOK_PUBLIC_KEY_FILE` (асимметричная), сравнение constant-time; защита от повтора — `payment_webhook_events` (R0 §17.3) | **обязателен** в `api`: IP ∈ `QR_WEBHOOK_ALLOWED_IPS` (обязательна при включении), иначе `403`; дополнительно — фильтр `remote_ip` в Caddy (опц.) | `handle /api/v1/payments/qr/webhook` → `api:3000` | `QR_WEBHOOK_ENABLED`, `QR_WEBHOOK_SECRET_FILE` / `QR_WEBHOOK_PUBLIC_KEY_FILE`, `QR_WEBHOOK_ALLOWED_IPS` |

Проверка при приёмке (12_TEST_PLAN): при значениях по умолчанию все три группы маршрутов отвечают `404`; при включении — запрос с неразрешённого IP → `403`, без токена/подписи → `401`, с токеном роли `integration` на `/api/v1/orders` → `403`; `Caddyfile` не содержит директив аутентификации.

---
## 5. Требования к ресурсам (D-34) и рост на 2–3 года

Вводные: ~50 000 SKU, 20–50 одновременных сотрудников (ориентир Q-023), фото — объём **неизвестен** (Q-022). Все цифры — инженерная оценка [НЕ ПОДТВЕРЖДЕНО], уточняется нагрузочным тестом на этапе 2 (12_TEST_PLAN).

### 5.1. База данных

| Объект | Оценка объёма | Обоснование |
|---|---|---|
| `products`, `product_variants`, `product_attributes`, `variant_attribute_values` (50k SKU, до 100k вариантов) | ~0,3–0,6 GB с индексами | 1–3 KB на строку + btree (артикул/штрихкод) + GIN pg_trgm/tsvector [РЕШЕНИЕ: D-31] |
| `stock_balances` (варианты × склады, 100k × 3) | ~0,1 GB | узкие строки, частые UPDATE → bloat; autovacuum обязателен |
| `prices`, `price_lists` | ~0,1 GB | виды цен × варианты |
| `customers`, `customer_contacts`, `receivables`, `receivable_documents`, история покупок за 2–3 года | 0,2–1 GB | зависит от глубины выгрузки истории из 1С (Q-023) |
| `orders`, `order_items`, `payments`, `transactions`, `audit_logs` | ~0,5–1 GB/год при ~300–500 документов/день [НЕ ПОДТВЕРЖДЕНО] | строки документов + append-only аудит (хранение 3 года, D-36) |
| `sync_runs`, `sync_errors`, `onec_outbox`, `sms_outbox`, `idempotency_keys` | ~0,1 GB/год | ротация старых записей (OPS) |
| **Итого R1** | **~1–3 GB**, рост **1–2 GB/год** | `shared_buffers` 1–2 GB достаточно |

### 5.2. Фотографии (Q-022)

Формула: `объём = SKU × среднее число фото × (сумма размеров thumb 160 + card 400 + full 1200 в WebP)` [РЕШЕНИЕ: D-30]. Оценка при 1,5 фото/SKU и ~340 KB на набор размеров — ≈ 25 GB; при 3 фото/SKU и ~640 KB — ≈ 100 GB. Оригиналы из 1С не хранятся дольше, чем нужно для генерации размеров (предложение: сервер ограничивает длинную сторону `MEDIA_MAX_SOURCE_PX`=1600 — Q-105), что снижает объём в 3–5 раз [ТИПОВО]. До ответа на Q-022 планировать диск по верхней границе 100 GB.

### 5.3. Расчёт CPU / RAM / диска

| Компонент | RAM | CPU | Диск | Комментарий |
|---|---|---|---|---|
| ОС + Docker Engine | 0,7–1 GB | — | 10–15 GB | |
| `postgres` | 1,5–2,5 GB (`shared_buffers` 512 MB–1 GB при 4 GB RAM; 2 GB при 8 GB; `work_mem` 8–16 MB; `max_connections` 100 по умолчанию достаточно при пуле 10–20 соединений в `api`/`worker`) | 1–2 vCPU | 10 GB данных + 10 GB запас + WAL | 50 сотрудников ≠ 50 соединений |
| `api` + `worker` (Node 24) | 0,5–1,5 GB (пики `worker` при обработке фото) | 1–2 vCPU | образ 0,2–1 GB | поиск — в PostgreSQL, не в памяти приложения |
| `caddy` | 50–100 MB | доля ядра | < 1 GB | |
| Фото (`media`) | кэш ОС | — | **25–100 GB** | отдельный том, лучше отдельный диск |
| Логи (json-file с ротацией) | — | — | 2–5 GB | раздел 9 |
| Локальные бэкапы (30 дампов + копия фото) | — | — | 2–6 GB + N GB | внешняя копия обязательна |
| Тестовый контур `optomstroy-test` | +1,5–2 GB | доля CPU | +10 GB + уменьшенный набор фото | |

**Итог [РЕШЕНИЕ: D-34]:** минимум (только prod, фото ≤ 30 GB) — **2 vCPU / 4 GB RAM / 80 GB SSD**; рекомендовано (prod + test, фото до 100 GB, запас на 2–3 года) — **4 vCPU / 8 GB RAM / 160–250 GB SSD**; внешнее хранилище бэкапов **≥ 2 × (БД + фото)**. Сеть: пиковая полоса 5–20 Mbit/s при 50 сотрудниках; важнее латентность и стабильность [НЕ ПОДТВЕРЖДЕНО].

### 5.4. Рост на 2–3 года

| Ресурс | Год 1 | Год 2 | Год 3 | Правило |
|---|---|---|---|---|
| БД | 1–3 GB | 2–5 GB | 3–7 GB | +1–2 GB/год; аудит 3 года без удаления (D-36) |
| Фото | N | N × 1,1–1,3 | N × 1,2–1,7 | +10–30 %/год (новые SKU, замена фото) |
| Логи | постоянно 2–5 GB | то же | то же | ротация |
| Диск в целом | — | — | **≤ 70 % заполнения к концу 3-го года** | алерт при > 80 % (раздел 9) |
| RAM | 4–8 GB | 8 GB | 8–16 GB | рост числа сотрудников до 200 (NFR-SCALE-001) → 16 GB |

### 5.5. Версии ПО (фиксируются в ТЗ)

| Компонент | Версия | Основание |
|---|---|---|
| ОС (A / B-3) | Ubuntu Server 24.04 LTS (standard support до 2029 г.) или 26.04 LTS (до 2031 г.) | [ТИПОВО: https://ubuntu.com/about/release-cycle — точный месяц уточнить на дату аудита] |
| Docker | Docker Engine + Compose v2 plugin из репозитория Docker (`docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`) | [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/] |
| PostgreSQL | 17 (EOL 2029-11-08) [РЕШЕНИЕ: D-03]; 18 (EOL 2030-11-14) — по решению Q-104 с учётом драйверов | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/support/versioning/] |
| Reverse-proxy | Caddy 2 (авто-TLS) по умолчанию; Nginx + certbot — если админ заказчика настаивает (`certbot --nginx`, `certbot renew --dry-run` [ПОДТВЕРЖДЕНО: https://certbot.eff.org/instructions?ws=nginx&os=snap]) | [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https] |
| Рантайм `api` | Node.js 24 LTS, образ `node:24-alpine`, non-root, read-only FS | [РЕШЕНИЕ: D-03] |

---

## 6. Изоляция от существующих сервисов и перечень согласований

### 6.1. Принципы изоляции [ПОДТВЕРЖДЕНО: SRC-F-135, SRC-F-136]

| Область | Правило | Как реализуется / проверяется |
|---|---|---|
| Пользователь ОС | Отдельный пользователь `optomstroy` (имя согласовать) без пароля, вход только по SSH-ключу. **Риск:** членство в группе `docker` эквивалентно root на хосте [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/linux-postinstall/]. Варианты (Q-102): (а) **rootless Docker** (демон от `optomstroy`; порты 80/443 — `sysctl net.ipv4.ip_unprivileged_port_start=80` либо хостовый RP) [ПОДТВЕРЖДЕНО (режим): https://docs.docker.com/engine/security/rootless/; настройка портов — ТИПОВО]; (б) обычный Docker, `optomstroy` **не** в группе `docker`, запуск через `sudo` с ограниченным `sudoers` (только `/usr/bin/docker compose -p optomstroy-* …`); (в) принять риск членства в `docker` с обоснованием — допустимо для B-3/VPS, где на хосте нет чужих служб | `adduser --disabled-password optomstroy`; `id optomstroy` — нет группы `docker` при (а)/(б) |
| Каталоги | Конфигурация — `/opt/optomstroy/{prod,test}`; данные — `/srv/optomstroy/{prod,test}/{pgdata,media,backups}`. Ничего не пишем в `/etc` чужих служб | права `750` на каталоги, `600` на `.env` и секреты |
| Порты хоста | Наружу — только `80` и `443` нашего RP; `api`, `postgres`, `pgadmin` — без `ports:` либо `127.0.0.1:` | `ss -tulpn` после деплоя |
| Сети Docker | Свои сети `optomstroy_prod_edge`, `optomstroy_prod_backend` (`internal: true`); тест — отдельные сети | compose создаёт сети с префиксом проекта |
| Ресурсы | `deploy.resources.limits` (memory/cpus) на каждый контейнер; `restart: unless-stopped` | особенно важно при соседстве с 1С (B-3) |
| Логи | ротация json-file (раздел 9), чтобы не заполнить диск соседям | `daemon.json` + `logging.options` в compose |
| Чужие конфигурации | Не редактируем чужие `nginx.conf`, `httpd.conf`, `pg_hba.conf`, правила firewall, DNS, cron. Если 80/443 заняты чужим веб-сервером: (а) наш RP на других портах за чужим прокси — чужой конфиг меняет **его владелец**; (б) отдельный IP/хост; (в) VPS (сценарий C) | согласование до любых действий (6.3) |
| Имена проектов compose | `optomstroy-prod`, `optomstroy-test` — `docker compose down` одного не трогает другой | `name:` в compose или `-p` |

### 6.2. Если на сервере уже есть PostgreSQL (например, под 1С)

Не используем его: разные версии/сборки (у 1С часто специальная сборка PostgreSQL [ТИПОВО]), разные политики бэкапа и обновления, риск повлиять на учётную систему. Свой контейнер `postgres` в internal-сети без публикации портов; администрирование — SSH-туннель + `docker compose -p optomstroy-prod exec postgres psql -U <роль> <база>` или `pgadmin` на `127.0.0.1:5050`. Если временно нужен прямой TCP-доступ клиентом с рабочей станции — на время работ подключить `postgres` к `edge` и опубликовать `127.0.0.1:5433:5432` (нестандартный порт, чтобы не конфликтовать с 5432 чужого экземпляра); после работ вернуть. Публикация порта контейнера в internal-сети не работает — NAT для internal-сетей Docker не настраивает [ТИПОВО: проверить на этапе 2].

### 6.3. Что потребуется согласовать с заказчиком (12 пунктов, R8 §4.3) — до любого развёртывания

| # | Что | Зачем | Кто решает | Вопрос |
|---|---|---|---|---|
| 1 | Домен/поддомены для API (`api.<домен>`, `api-test.<домен>` — имена условные) и доступ к DNS для A-записей | TLS и адрес для приложений | Владелец домена | Q-032 |
| 2 | Открытие входящих 80 и 443 на сервер (роутер/провайдер/firewall) | авто-TLS (HTTP-01/TLS-ALPN-01) и сам API | Админ сети / провайдер | Q-030 |
| 3 | Разрешение на SSH (22 или нестандартный порт) с ограничением по IP или через VPN | администрирование | Админ сети | Q-030 |
| 4 | Правила firewall на сервере: разрешить 80/443 к RP; запретить всё остальное входящее для нашего проекта | безопасность | Админ сервера | Q-030 |
| 5 | Сертификат: Let's Encrypt (бесплатно, автоматически) или корпоративный/платный | TLS | Заказчик | Q-032 |
| 6 | Хранилище бэкапов вне сервера: S3-совместимое / второй сервер / NAS; кто оплачивает | защита от потери сервера | Заказчик | Q-033 |
| 7 | Создание пользователя ОС `optomstroy` и каталогов; вариант прав `docker` (6.1) | изоляция | Админ сервера | Q-102 |
| 8 | Установка Docker Engine (если нет); в B-3 — включение Hyper-V + перезагрузка | платформа | Админ сервера, окно обслуживания | Q-101 |
| 9 | Сетевой доступ от backend к HTTP-сервисам 1С (адрес, порт, учётная запись с минимальными правами) | обмен с 1С | Специалист 1С | Q-031, Q-010, Q-011 |
| 10 | Окна обслуживания (день/час), когда допустима перезагрузка сервера | обновления ОС | Заказчик | Q-032 |
| 11 | Канал оповещений для алертов (по умолчанию e-mail через почтовый сервер в КР; Telegram-группа — только после ADR по 11 PRIV-020) | мониторинг | Заказчик | Q-032 |
| 12 | Политика хранения логов и персональных данных (срок) | приватность | Заказчик + юр. требования КР (11_SECURITY_PRIVACY) | Q-027, Q-028 |

Ни один пункт не выполняется до письменного согласования [ПОДТВЕРЖДЕНО: SRC-F-136, SRC-F-139].

---

## 7. Безопасность сервера (hardening)

Зона 11_SECURITY_PRIVACY — приложение и ПДн; здесь — только хост и контейнеры.

| # | Требование | Реализация (план этапа 2) | Проверка | Статус |
|---|---|---|---|---|
| H-1 | БД не доступна из интернета [ПОДТВЕРЖДЕНО: SRC-F-137] | `postgres` без `ports:`, только сеть `backend` (`internal: true`); в нативном варианте — `listen_addresses='localhost'` (значение по умолчанию) | `ss -tulpn` не показывает 5432/5433 на `0.0.0.0`; `nmap -p 5432,5433 <публичный IP>` извне → `closed/filtered` | [ПОДТВЕРЖДЕНО: postgresql.org runtime-config-connection; docs.docker.com compose networks] |
| H-2 | SSH только по ключам | `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers optomstroy <админ>`, ключи ed25519; изменение `sshd_config` — только с согласия админа (6.3 №3) | `ssh -o PreferredAuthentications=password` → отказ | [ТИПОВО: OpenSSH] |
| H-3 | Защита от перебора | `fail2ban`, jail `sshd` (bantime ≥ 1 ч, maxretry 5 — согласовать) | `fail2ban-client status sshd` | [ПОДТВЕРЖДЕНО: https://github.com/fail2ban/fail2ban] |
| H-4 | Автообновления безопасности ОС | Ubuntu `unattended-upgrades` (установлен по умолчанию, только security); `Automatic-Reboot` включать только с `Automatic-Reboot-Time` в окно обслуживания | `cat /etc/apt/apt.conf.d/20auto-upgrades` | [ПОДТВЕРЖДЕНО: https://ubuntu.com/server/docs/how-to/software/automatic-updates/] |
| H-5 | Firewall хоста | Входящие: 22 (ограничить по IP/VPN), 80, 443; C-1 на VPS: + UDP `<ListenPort>` WireGuard; всё остальное `deny`. Исходящие — allow-list (рекомендуется; 11 PRIV-019, T-SEC-047): 1С (LAN/туннель), SMSPro, реестр образов, ACME CA, хранилище бэкапов в КР, хост монитора (self-hosted Healthchecks/Uptime Kuma в КР), почтовый сервер для алертов, зеркала обновлений ОС/Docker, NTP; иные хосты — только после ADR по 11 PRIV-020. **Docker обходит ufw** (правила в таблице `nat` до `INPUT`) [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/network/packet-filtering-firewalls/] → порты публиковать только как `127.0.0.1:` или не публиковать; проверять фактические порты | `ss -tulpn`; `iptables -S DOCKER-USER` [ТИПОВО: имя цепочки]; `nmap` извне; `ufw status` — недостаточно | |
| H-6 | Секреты | только `secrets/*` с `600`, Compose `secrets:`; `.env` без секретов; `.env.example` в git без значений; секреты **никогда** в git/образах/логах | `ls -la secrets/` → `-rw-------`; `git ls-files \| grep -i secret` пусто | [ПОДТВЕРЖДЕНО: docs.docker.com/compose/how-tos/use-secrets/] |
| H-7 | Минимальные права контейнеров | не `privileged`; `api`/`worker` от non-root (`user:`); `read_only: true` + `tmpfs`; `cap_drop: [ALL]`; `no-new-privileges`; Docker socket никому не монтируется; пользователь `optomstroy` — вариант (а)/(б) из 6.1 | `docker inspect` по каждому контейнеру | [ТИПОВО: Docker security best practices] |
| H-8 | TLS | только HTTPS; HTTP → редирект (Caddy автоматически); HSTS `max-age=63072000; includeSubDomains` и прочие заголовки 11 SEC-003/SEC-018, 08 API-033 (Caddyfile 4.5); TLS 1.2+/1.3 (NFR-SEC-001) | `curl -I http://…` → 308/301; SSL Labs — по согласованию | [ПОДТВЕРЖДЕНО: caddyserver.com/docs/automatic-https] |
| H-9 | Журналирование без секретов | Caddy access-log JSON; `api`/`worker` — структурированный JSON (pino) без OTP/паролей/токенов/ПДн (NFR-LOG-001); `postgres` — `log_min_duration_statement=500ms`, `pg_stat_statements`; `auth.log`/journald; fail2ban | этап 2: grep логов по секретным паттернам (12_TEST_PLAN) | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/pgstatstatements.html] |
| H-10 | Админ-панели | `pgadmin` (на сервере backend) — только `127.0.0.1:5050` + SSH-туннель; панель **Uptime Kuma — на хосте монитора, не на сервере backend** (раздел 9, Q-103): публикуется только `127.0.0.1:3001` за HTTPS-RP с авторизацией или VPN, администрирует её DevOps/админ заказчика по решению Q-103; на сервере backend порт 3001 не ожидается вовсе; сменить пароли по умолчанию | извне порты закрыты: на сервере backend `nmap` не показывает 5050 (и 3001 отсутствует); на хосте монитора `nmap` не показывает 3001 | |
| H-11 | Время | NTP включён (`timedatectl`), пояс `Asia/Bishkek` | `timedatectl` | обязательно для TLS, OTP TTL, JWT `exp`, сверки с 1С |
| H-12 | Образы | только фиксированные теги; `docker scout`/Trivy-скан в CI перед публикацией (R2 — обязательно, R1 — рекомендация); базовый образ `node:24-alpine` | журнал релизов | [ТИПОВО] |
| H-13 | Windows (сценарий B) | службы под отдельной учётной записью с минимальными правами; OpenSSH Server вместо RDP из интернета; RDP только через VPN + NLA; Windows Firewall включён для всех профилей; Windows Update/WSUS с окном перезагрузки, согласованным с 1С; Account Lockout Policy как аналог fail2ban | `Get-NetFirewallProfile`; `Get-NetFirewallRule` 3389/22; `net accounts`; `Get-HotFix` | [ПОДТВЕРЖДЕНО: learn.microsoft.com OpenSSH]; остальное [ТИПОВО] |
| H-14 | 1С-публикация | не публиковать веб-клиент 1С в интернет; OData/HTTP-сервисы только по HTTPS в LAN/VPN; отдельный пользователь ИБ; ограничение `$top` и rate-limit на границе (R1 §7) | 05_ONEC_INTEGRATION | [ТИПОВО] |
| H-15 | Серверная проверка прав [ПОДТВЕРЖДЕНО: SRC-F-138c] | Reverse-proxy не выполняет аутентификацию/авторизацию и не содержит правил `basic_auth`/`forward_auth`/allow-list по путям API; все проверки прав — в `api` на каждом запросе (deny by default, 11_SECURITY_PRIVACY SEC-028/SEC-029); маршруты без Bearer — только `/health*`, статика `/images/*` и входящие интеграции 4.6 (аутентифицируются в `api` техническим токеном/подписью/IP-allowlist `*_ALLOWED_IPS` — для 1С `ONEC_INBOUND_ALLOWED_IPS`, 05 ONEC-060); единственное допустимое сетевое правило на proxy — необязательный фильтр `remote_ip` для маршрутов 4.6 (дублирующий слой, не авторизация, DEPLOY-050) | `Caddyfile` не содержит директив авторизации; тест 12_TEST_PLAN «403 для чужой роли» через proxy | DEPLOY-049 |

---
## 8. Резервное копирование и восстановление (D-35)

Требование заказчика: резервное копирование и документированное восстановление [ПОДТВЕРЖДЕНО: мастер-промт, строка 445 — SRC-D-087; строка 960/973 — SRC-F-134b, SRC-F-134e]. База 1С бэкапится заказчиком отдельно — вне зоны этого документа (но отсутствие бэкапа 1С по аудиту L-15/W-13 сообщается заказчику как риск).

### 8.1. Целевые показатели [РЕШЕНИЕ: D-35; ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-033]

| Показатель | Release 1 | Пояснение |
|---|---|---|
| RPO (допустимая потеря данных) | **≤ 24 ч** для БД (суточный дамп) | Мастер-данные восстанавливаются повторной синхронизацией из 1С; теряются только операционные данные POS за окно (корзины, черновики, заказы, не ушедшие в 1С через outbox). Заказы, уже подтверждённые 1С, сохранены в 1С |
| RPO при PITR (R2 или по требованию) | ≤ 15 мин | `archive_mode=on` + WAL-архив (pgBackRest/WAL-G) [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/continuous-archiving.html]; предложение R6 §8 — см. раздел 19 |
| RTO (время восстановления) | **≤ 4 ч** на том же сервере; ≤ 1 рабочий день на новом сервере/VPS | при наличии внешней копии и runbook 15.3; plaintext-дампа на сервере нет (SEC-110), поэтому RTO включает доставку приватного ключа `age` держателем (Q-106) — доступность держателя ключа (дежурство/второй держатель) обязательна |
| Деградированный режим | ≤ 1 ч | приложение работает с кэшем каталога (D-32); заказы магазин принимает в 1С напрямую |
| Хранение | 30 суточных дампов + 3 месячных (локально и вне сервера); globals — 90 дней; фото — накопительная копия `rclone copy` (без удаления на remote; ротация — политикой жизненного цикла хранилища, SEC-111) | |
| Копия вне сервера | **обязательна**: S3-совместимое хранилище / второй хост / NAS. Предпочтение — хранилище **в КР** (хранение ПДн за рубежом = трансграничная передача, Цифровой кодекс КР ст. 89 — [НЕ ПОДТВЕРЖДЕНО: юр. заключение, Q-027]) | потеря сервера целиком — реальный сценарий |
| Правило 3-2-1 | локальная копия + внешняя копия + офлайн-копия раз в месяц (носитель у заказчика) | [НЕ ПОДТВЕРЖДЕНО — рекомендация R6 §8] |
| Шифрование | дампы и архивы шифруются **до** выгрузки (`age`, получатель — публичный ключ заказчика; приватный ключ — офлайн у заказчика, копия у DevOps в защищённом хранилище) | Q-106 |
| Проверка восстановления | **ежемесячно** автоматическое восстановление последнего дампа в тестовый контур + smoke-тест + `SELECT count(*)` по ключевым таблицам; **ежеквартально** ручное учение с замером RTO; результат — в журнал эксплуатации | «непроверенный бэкап = отсутствие бэкапа» |

### 8.2. Что бэкапим, как и как часто

| Данные | Метод | Частота | Куда |
|---|---|---|---|
| БД PostgreSQL (`optomstroy_prod`) | `pg_dump -Fc` (custom-формат: сжатие, выборочное и параллельное восстановление `pg_restore -j`); не блокирует пишущих | ежедневно 03:00 Asia/Bishkek (согласовать) | локально → `age` → внешнее хранилище |
| Роли/глобальные объекты | `pg_dumpall --globals-only` | еженедельно (вс) и при изменении ролей | то же |
| Фото (`media`) | `rclone copy --immutable` (инкрементально; без удаления и перезаписи на remote — SEC-111; удалённые на сервере фото хранятся до истечения политики жизненного цикла хранилища) или `restic` (append-only) | ежедневно после дампа | внешнее хранилище |
| Конфигурация (`docker-compose.yml`, `Caddyfile`, `.env.example`, `bin/*.sh`, `daemon.json`) | git-репозиторий проекта (без секретов) | при изменении | git |
| Секреты (`secrets/*`, `.env`) | зашифрованная копия (`age`/`gpg`) в отдельном защищённом месте у заказчика; реестр секретов (где лежат, без значений) | при изменении | офлайн |
| Сертификаты (`caddy_data`) | включить в суточную копию (иначе при потере — перевыпуск, лимит дубликатов LE 5/7 дней) | ежедневно | внешнее хранилище |
| Ключи JWT | в составе секретов; при утере — все сессии отзываются (допустимо, D-12) | при изменении | офлайн |
| База 1С | **вне зоны** — ответственность заказчика | — | — |

Обоснование выбора `pg_dump`: документация PostgreSQL оговаривает, что «except in simple cases, pg_dump is generally not the right choice for taking regular backups of production databases» [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/app-pgdump.html]; отнесение R1 (БД 1–3 GB, мастер-данные восстановимы из 1С) к «простому случаю» — инженерное решение [НЕ ПОДТВЕРЖДЕНО], фиксируется в 15_DECISION_LOG (ADR-035). PITR — R2 или по требованию бизнеса (Q-033).

### 8.3. Пример скрипта бэкапа (ТОЛЬКО КАК ДОКУМЕНТ, не для выполнения на этапе 1)

```bash
#!/usr/bin/env bash
# /opt/optomstroy/prod/bin/backup_db.sh — запускается cron от пользователя optomstroy
# Спецификация этапа 1. Имена remote/секретов — условные, фиксируются на этапе 2.
set -euo pipefail
umask 077                                     # все создаваемые файлы — 600 (ПДн в дампах; H-6)
export TZ=Asia/Bishkek                        # не полагаемся на CRON_TZ (8.4)
PROJECT=optomstroy-prod
# Вызов docker compose зависит от варианта прав 6.1 (Q-102):
#   (а) rootless Docker — демон от optomstroy: DC="docker compose"
#   (б) optomstroy НЕ в группе docker — ограниченный sudoers: DC="sudo /usr/bin/docker compose"
#   (в) optomstroy в группе docker (B-3/VPS, с обоснованием): DC="docker compose"
DC="${DOCKER_COMPOSE_CMD:-sudo /usr/bin/docker compose}"
BACKUP_DIR=/srv/optomstroy/prod/backups/db
CADDY_DIR=/srv/optomstroy/prod/backups/caddy_data
MEDIA_DIR=/srv/optomstroy/prod/media
KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
REMOTE="${BACKUP_REMOTE:-offsite}"           # имя remote rclone, условно
AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:?}"      # публичный ключ age (не секрет)
HC_URL_FILE=/opt/optomstroy/prod/secrets/healthchecks_url
export RCLONE_CONFIG=/opt/optomstroy/prod/secrets/rclone.conf   # 600; не ~/.config/rclone
STAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR" "$CADDY_DIR"
chmod 700 "$BACKUP_DIR" "$CADDY_DIR"

hc() { [ -f "$HC_URL_FILE" ] && curl -fsS -m 10 --retry 3 "$(cat "$HC_URL_FILE")$1" >/dev/null || true; }
trap 'hc /fail' ERR
# plaintext удаляется при ЛЮБОМ завершении скрипта, в т.ч. при сбое до шага 4a (SEC-110)
trap 'rm -f "$BACKUP_DIR/optomstroy_${STAMP}.dump"' EXIT
hc /start

# 1. Дамп БД из контейнера postgres (роль и база — из переменных POSTGRES_USER/POSTGRES_DB
#    контейнера; локальное подключение внутри контейнера, пароль не передаётся в командной строке)
$DC -p "$PROJECT" exec -T postgres \
  sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > "$BACKUP_DIR/optomstroy_${STAMP}.dump"

# 2. Еженедельно — глобальные объекты (роли; содержит хэши паролей → тоже шифруется)
if [ "$(date +%u)" = "7" ]; then
  $DC -p "$PROJECT" exec -T postgres \
    sh -c 'pg_dumpall --globals-only -U "$POSTGRES_USER"' \
    | age -r "$AGE_RECIPIENT" -o "$BACKUP_DIR/globals_${STAMP}.sql.age"
fi

# 3. Проверка, что дамп читается
$DC -p "$PROJECT" exec -T postgres pg_restore --list /dev/stdin \
  < "$BACKUP_DIR/optomstroy_${STAMP}.dump" >/dev/null

# 4. Шифрование перед выгрузкой (age; приватный ключ — не на сервере)
age -r "$AGE_RECIPIENT" -o "$BACKUP_DIR/optomstroy_${STAMP}.dump.age" "$BACKUP_DIR/optomstroy_${STAMP}.dump"

# 4a. Нешифрованный дамп удаляется сразу после успешного шифрования (11 SEC-110:
#     plaintext на диске сервера существует только до завершения шифрования).
#     Постоянного plaintext-файла (latest.dump) НЕТ. Страховка от сбоя прошлых запусков —
#     удаление любых оставшихся *.dump (в т.ч. устаревшего latest.dump).
rm -f "$BACKUP_DIR/optomstroy_${STAMP}.dump"
find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -delete

# 5. Ротация локальных зашифрованных копий
find "$BACKUP_DIR" -name '*.dump.age' -mtime +"$KEEP_DAYS" -delete
find "$BACKUP_DIR" -name 'globals_*.sql.age' -mtime +90 -delete

# 6. Копия вне сервера (remote настраивается отдельно; секреты — в rclone.conf с правами 600).
#    Том caddy_data копируется через docker compose cp (не нужен root-доступ к
#    /var/lib/docker/volumes; в rootless-варианте тома лежат в ~/.local/share/docker/volumes,
#    путь отличается). Альтернатива — bind-mount /srv/optomstroy/prod/caddy_data (4.2).
#    Учётная запись выгрузки БЕЗ права удаления и перезаписи (11 SEC-111, WORM/версионирование):
#    только `rclone copy` (никогда sync/move/delete); --immutable — ошибка вместо
#    перезаписи изменённого объекта; ротация — политикой жизненного цикла хранилища.
rclone copy "$BACKUP_DIR" "$REMOTE:optomstroy/prod/db" --include '*.age' --min-age 1m --immutable
#    Фото контент-адресуемы (images/{sha}/{size}.webp, D-30) — объект не меняется после записи;
#    удалённые на сервере фото остаются в хранилище до истечения политики жизненного цикла.
rclone copy "$MEDIA_DIR" "$REMOTE:optomstroy/prod/media" --immutable
#    caddy_data (сертификаты меняются при перевыпуске) — в новый каталог с датой, без перезаписи.
$DC -p "$PROJECT" cp caddy:/data "$CADDY_DIR" && \
  rclone copy "$CADDY_DIR" "$REMOTE:optomstroy/prod/caddy_data/$STAMP" || true

# 7. Контроль: внешняя копия существует и размер > 0
rclone lsl "$REMOTE:optomstroy/prod/db/optomstroy_${STAMP}.dump.age" | awk '$1 > 0 {ok=1} END {exit !ok}'

hc ""
echo "OK $STAMP"
```

Пояснения к скрипту: `umask 077` и `chmod 700` каталогов гарантируют права `600/700` на всё созданное (H-6; дампы содержат ПДн); нешифрованный дамп существует на диске только до завершения шифрования и удаляется тем же скриптом (шаг 4a и `trap … EXIT` — также при сбое), постоянного plaintext-файла (`latest.dump`) нет [РЕШЕНИЕ: 11 SEC-110, AC-SEC-110]; восстановление на том же сервере поэтому всегда идёт из `.age` и требует приватного ключа `age` (Q-106) — время его доставки входит в RTO ≤ 4 ч (OPS-006, 8.1). Хранение постоянного plaintext-дампа ради ускорения RTO допускается **только** как исключение из SEC-110 по письменному решению заказчика (ответ на Q-033 + ADR в 15_DECISION_LOG) с явным остаточным риском в 11 §2.3, на томе с шифрованием диска (LUKS, Q-182) и с включением файла в реестр SEC-117/PRIV-011; без такого решения исключение не применяется. Для сценария (б) из 6.1 `sudoers` разрешает `optomstroy` только `/usr/bin/docker compose -p optomstroy-* *` без пароля [ТИПОВО: sudoers]; `docker compose cp` поддерживается Compose v2 [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/cli/docker/compose/cp/]. Фильтр `--include '*.age'` в `rclone copy` дополнительно исключает выгрузку любого нешифрованного файла. Все выгрузки — `rclone copy` (без `sync`, `move`, `delete`, `--backup-dir`), поэтому учётной записи выгрузки достаточно прав «чтение + создание» (11 SEC-111): попытка перезаписи завершается ошибкой (`--immutable`), а не удалением; удалённые на сервере фото и устаревшие копии удаляются только политикой жизненного цикла/версионирования хранилища [ТИПОВО: зависит от провайдера, Q-188 в 11]. Конфигурация rclone читается из `secrets/rclone.conf` через переменную `RCLONE_CONFIG` [ПОДТВЕРЖДЕНО: https://rclone.org/docs/ (флаг `--config`, переменная `RCLONE_CONFIG`)], а не из домашнего каталога. При варианте (б) файлы, скопированные `sudo docker compose cp`, принадлежат root — тогда предпочтителен bind-mount `caddy_data` в `/srv/optomstroy/prod/caddy_data` с владельцем `optomstroy` либо выгрузка `caddy_data` из контейнера `backup` (Q-103) [ТИПОВО: проверить на этапе 2]; сертификаты Caddy перевыпускаемы, поэтому сбой этого шага не прерывает бэкап (`|| true`), но отражается в журнале.

### 8.4. Пример crontab (документ)

```cron
# crontab пользователя optomstroy — СПЕЦИФИКАЦИЯ
# CRON_TZ поддерживается cronie (RHEL/Fedora) и Debian/Ubuntu cron (vixie-cron с патчем),
# но не всеми реализациями (busybox cron, dcron) [ТИПОВО: cronie/Debian cron — проверить
# `man 5 crontab` на хосте]. Поэтому скрипты сами выставляют TZ=Asia/Bishkek; при
# отсутствии поддержки CRON_TZ строку ниже убрать и задать часы по времени хоста (H-11).
CRON_TZ=Asia/Bishkek
# m h dom mon dow command
0 3 * * *   /opt/optomstroy/prod/bin/backup_db.sh      >> /srv/optomstroy/prod/backups/backup.log 2>&1
# restore_drill.sh НЕ запускается из cron: расшифровка требует приватного ключа age, которого
# на сервере нет (SEC-110, OPS-004). Его ежемесячно запускает держатель ключа (8.5, абзац о drill);
# пропуск ловит отдельная проверка Healthchecks «restore-drill» (период 31 сут, grace 3 сут).
*/10 * * * * /opt/optomstroy/prod/bin/metrics_check.sh >> /srv/optomstroy/prod/backups/metrics.log 2>&1
```

Альтернатива — cron внутри контейнера `backup` (образ `optomstroy/backup`) с теми же шагами; выбор — этап 2 (Q-103). При ошибке скрипт завершается ненулевым кодом до финального ping → Healthchecks переходит в `Down` → алерт (раздел 9).

### 8.5. Процедура восстановления БД (документ; runbook — 15.3)

1. Остановить потребителей БД: `docker compose -p optomstroy-prod stop api worker backup` (здесь и ниже `docker compose` вызывается по варианту прав 6.1 / Q-102 — при варианте (б) через `sudo /usr/bin/docker compose`, как `DC` в 8.3).
2. Получить дамп: на том же сервере — локальный `backups/db/optomstroy_<дата>.dump.age`, иначе `rclone copy offsite:optomstroy/prod/db/<файл>.age .` (plaintext-копий на сервере нет — SEC-110); расшифровать `age -d -i <приватный ключ> -o <файл>.dump <файл>.age` (ключ — у заказчика/DevOps офлайн, Q-106). Глобальные объекты — `globals_<дата>.sql.age` аналогично.
3. Восстановить роли (при новом кластере): `psql -U postgres -f globals_<дата>.sql postgres`.
4. Создать пустую БД из `template0` (или `DROP/CREATE DATABASE` под сопровождением) и выполнить `pg_restore -U <роль> -d <база> -j 4 optomstroy_<дата>.dump` (параллельное восстановление поддерживается custom-форматом) [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/backup-dump.html].
5. `ANALYZE` после восстановления (рекомендация документации).
6. Восстановить `media`: `rclone copy offsite:optomstroy/prod/media /srv/optomstroy/prod/media` (в хранилище могут остаться фото, удалённые после дампа, — они безвредны, контент-адресуемы и не имеют ссылок; при восстановлении на новый сервер — с машины восстановления под учётной записью с правом чтения); `caddy_data` — из последнего каталога `caddy_data/<дата>` (или перевыпуск сертификата).
7. Запустить `migrate` (если версия образа новее дампа); **до запуска `api`** назначить новую эпоху данных `server_epoch` (новое значение; восстановленный дамп содержит прежнее) — по 05 F16/SYNC-063 клиенты при смене эпохи не повторяют `POST /orders` из `checkout_draft` автоматически, переотправляют `outbox_actions`, пересоздают `cart_draft`, а 24 ч после restore действует мягкая проверка дубля (10 ORD-022); место хранения, команда смены, заголовок ответа и поле `/health` — контракт 08 §2.11 и 07 (передано, раздел 19 №17); затем `api`, `worker`; smoke-тест: в проде — только prod-smoke без мутаций (10.9, T-OPS-024), в тестовом контуре — 10.5.
8. Запустить ручную синхронизацию с 1С (`POST /sync/runs`, `mode=manual`) для наверстывания изменений после момента дампа (в варианте C-2 ручной запуск недоступен — `422`, `rule: inbound_mode`, ядро §22.8; полный срез по всем сущностям запускает 1С-специалист на стороне 1С, 12.3, 15.2); проверить `sync_runs.status=success` по всем сущностям; выполнить reconcile зеркала заказов по регистру `ВнешниеИдентификаторыPOS` (05 SYNC-063); проверить `onec_outbox` на записи `pending`/`sending`/`failed`/`dead` за окно потери (автомат — ядро §22.1, 07 §6.5) и сверить их с 1С вручную: если документ в 1С уже существует (в том числе `ORDER_MATCH_AMBIGUOUS`), заказ привязывается к нему вручную `POST /orders/{id}/onec-link` (`senior_seller`/`admin`/`owner`, step-up, аудит `order.onec_linked`; элемент outbox `pending`/`failed`/`dead` → `sent`, далее `sent → confirmed` обычной синхронизацией — ядро §23 п.1; контракт — 08, автомат — 07 §6.5), а не повтором (риск дубля) и не отменой; если документа нет — повтор `POST /sync/outbox/{id}/retry`.
9. Записать в журнал: дата, версия дампа, длительность (фактический RTO), результат, расхождения.

Ежемесячная проверка (`restore_drill.sh`): шаги 2–5 и 7 выполняются в **тестовом** контуре (`optomstroy-test`), без остановки прода; скрипт запускает держатель приватного ключа `age` (Q-106), передавая identity-ключ на время сеанса (со съёмного носителя или через stdin в `tmpfs`; после завершения ключ на сервере не остаётся — OPS-004); тем самым каждый drill проверяет и дамп, и работоспособность ключа (11 SEC-110); пропуск drill → алерт проверки Healthchecks «restore-drill» (период 31 сут); критерий — `SELECT count(*)` по `products`, `product_variants`, `customers`, `orders`, `payments`, `audit_logs` совпадает с контрольными значениями, зафиксированными при дампе; `GET /health/ready` → 200.

---

## 9. Мониторинг и алерты

Требование: план мониторинга [ПОДТВЕРЖДЕНО: SRC-F-134d]. Минимальный набор R1 без Prometheus/Grafana (R2).

| Что | Как | Детали / пороги (предложение, согласовать) |
|---|---|---|
| Liveness `api` | `GET /health` → `200 {status:"ok", minAppVersion}` без авторизации — **только** эти поля, без версии ПО/сборки, имён хостов и строк ошибок [РЕШЕНИЕ: 11 SEC-019 — канон состава служебных ответов; D-37] (расхождение с 08 §4.19.1/API-120 — `apiVersion`, `onec`, `sms`, `stockAgeSec` — передано в notes волны 4, раздел 22) | `healthcheck` compose каждые 30 с |
| Readiness `api` | `GET /health/ready` → `200` если: БД доступна, миграции применены (версия схемы = версия релиза — проверяется внутри и влияет только на `status`, номер версии не выводится), pg-boss жив, последняя успешная синхронизация не старше порога; иначе `503`. Поля ответа — **только** `status`, `db`, `queue`, `syncAgeOk`, `lastSuccessfulSyncAt` [РЕШЕНИЕ: 11 SEC-019]; состояние 1С/SMSPro, возраст по сущностям и тексты ошибок — только в `GET /sync/status` с авторизацией (08) | порог «устаревшей синхронизации» — 2–3 интервала сущности (для 30-минутных — 60–90 мин; для остатков 5–10 мин — 30 мин) |
| Compose healthcheck | `api` — `wget … /health`; `postgres` — `pg_isready`; `depends_on … service_healthy` | [ПОДТВЕРЖДЕНО: docs.docker.com compose healthcheck] |
| Внешняя доступность | **Uptime Kuma** (self-hosted, MIT) на **другом хосте** (VPS/офисный ПК) — мониторы HTTP(s)/Keyword/JSON Query на `GET /health/ready` каждые 60 с; уведомления — e-mail (Telegram — только после ADR по 11 PRIV-020) [ПОДТВЕРЖДЕНО: https://github.com/louislam/uptime-kuma]. Хост монитора — **в КР** (офисный ПК заказчика или VPS в КР). Панель Uptime Kuma публикуется **на хосте монитора** (не на сервере backend) только как `127.0.0.1:3001` за HTTPS-RP с авторизацией или VPN; на сервере backend порт 3001 не открывается вовсе (H-10, DEPLOY-047); сменить пароль администратора. Внешний SaaS-монитор — только после ADR по 6 пунктам 11 PRIV-020 (получатель видит IP сервера и тексты алертов) | Q-103 (где хостить, кто администрирует) |
| Cron-задачи (бэкап, drill, метрики) | **Healthchecks** — по умолчанию **self-hosted** экземпляр на хосте монитора в КР (тот же хост, что Uptime Kuma); ping-URL `https://<хост монитора>/ping/<uuid>`, сигналы `/start`, `/fail`; период + grace → `Down` → алерт [ПОДТВЕРЖДЕНО: https://healthchecks.io/docs/ — протокол ping; self-hosted — открытый код проекта]. SaaS `hc-ping.com` (Healthchecks.io, вне КР) — только после ADR по 11 PRIV-020 | UUID — секрет (`secrets/healthchecks_url`); бэкап: период 24 ч, grace 2 ч |
| Синхронизация с 1С (три уровня) | (1) `worker` после каждого прогона пишет `sync_runs` и пингует Healthchecks (успех — ping, ошибка — `/fail`); (2) `/health/ready` → `503` + `lastSuccessfulSyncAt` при простое синхронизации → Uptime Kuma шлёт алерт; (3) в приложении — `SyncIndicator`, SCR-43, уведомление `sync_error` [РЕШЕНИЕ: D-41] | алерт администратору при `sync_state.consecutive_errors ≥ 3` (R5 §6) |
| Outbox в 1С | число записей `onec_outbox` в `failed`/`dead` > 0 более 15 мин → алерт; `pending` старше 30 мин → алерт | метрика в `metrics_check.sh` через `psql` |
| Логи | Docker `json-file`: по умолчанию `max-size=-1`, `max-file=1` — **ротации нет** [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/logging/drivers/json-file/] → `/etc/docker/daemon.json`: `{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"5"}}` (для новых контейнеров) **и** `logging.options` в compose; Caddy access-log с `roll_size 20MiB roll_keep 5`; `postgres` — медленные запросы ≥ 500 мс | просмотр: `docker compose -p optomstroy-prod logs --since 1h api` |
| Централизация логов | не в R1; Grafana Loki + Alloy — R2 при появлении второго сервера | [НЕ ПОДТВЕРЖДЕНО — отложено] |
| Метрики минимум (`metrics_check.sh`, cron каждые 10 мин) | диск (`df`): `Use% > 80 %` → `/fail`; `available` RAM < 10 %; load average > число CPU 15 мин; размер БД (`pg_database_size`); число ошибок синхронизации за сутки; время ответа `/health/ready` > 2 с; срок сертификата < 20 дней (`openssl s_client`) | каждый порог → Healthchecks `/fail` с текстом (только технический код и значение метрики) |
| PostgreSQL | `pg_stat_statements` для медленных запросов; `log_min_duration_statement=500ms`; раз в неделю — отчёт top-10 по `total_exec_time` | [ПОДТВЕРЖДЕНО: postgresql.org pgstatstatements] |
| SMSPro | баланс/ответы `status≠0` — алерт при 3 подряд `SMS_PROVIDER_ERROR`; `SMSPRO_TEST_FLAG=true` в `APP_ENV=prod` — `api`/`worker` не стартуют (OPS-027; R2 §11), алерт формирует внешний монитор по недоступности; `worker` опрашивает баланс каждые `SMSPRO_BALANCE_POLL_MINUTES` (15) — алерт при балансе < `SMSPRO_BALANCE_ALERT_SOM` (300 сом); срабатывание предохранителя `OTP_GLOBAL_PER_MIN` — алерт [РЕШЕНИЕ: R0 §17.7] | канал тот же |
| Каналы алертов | по умолчанию — e-mail администраторам через почтовый сервер в КР; Telegram-группа или иной зарубежный мессенджер/SaaS — только после ADR в 15_DECISION_LOG по 6 пунктам 11 PRIV-020 и решения заказчика | [ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-032]; [РЕШЕНИЕ: 11 PRIV-001, PRIV-019] |
| Содержимое алертов и пингов (минимизация ПДн) | тексты алертов, тела `/fail`, сообщения Uptime Kuma/Healthchecks, e-mail — **только** технические коды (`ONEC_UNAVAILABLE`, `SMS_PROVIDER_ERROR`, код события аудита `auth.otp.locked` и т. п.), счётчики, имя сущности/задачи, `requestId`/`runId`, порог и значение метрики; **запрещены** номера телефонов (в т. ч. маскированные), IP-адреса клиентов, `userId`/логины, ФИО и наименования клиентов, суммы и тексты ошибок outbox/1С с данными документа (05 SYNC-038). Подробности события — только в журнале аудита и `/sync/*` с авторизацией. Алерты 11 SEC-068/069/070 передают в канал только код события и счётчик | [РЕШЕНИЕ: 11 PRIV-001, PRIV-019; R6 §4.2]; проверка — тест 12 (T-SEC-047: сетевой трафик сервера) и ревью шаблонов алертов |
| Эскалация | 1-я линия — админ заказчика (перезапуск по runbook 15); 2-я — DevOps проекта; 3-я — backend-разработчик / 1С-специалист | контакты — в акте передачи (14, шаг 10) |

```mermaid
flowchart LR
  W[worker: sync_run] -- ping / fail --> HC[Healthchecks self-hosted<br/>хост монитора в КР]
  CR[cron: backup, drill, metrics] -- start / ping / fail --> HC
  UK[Uptime Kuma<br/>другой хост] -- GET /health/ready 60 c --> API[api]
  HC -- Down --> TG[e-mail через почтовый сервер в КР<br/>Telegram — только после ADR PRIV-020]
  UK -- 503 / таймаут --> TG
  API -- degraded --> APP[pos-app: SyncIndicator, SCR-43, уведомление sync_error]
```

---

## 10. Обновления и откат

Требование: план обновления, безопасные миграции, откат обновлений [ПОДТВЕРЖДЕНО: SRC-F-134c, SRC-F-142, строка 965/978].

### 10.1. Принципы

| Принцип | Содержание |
|---|---|
| Неизменяемые теги | каждый релиз backend — образ `optomstroy/api:<semver>` (+ метка `git sha`); `latest` в проде не используется; `API_TAG` в `.env` — единственный источник версии |
| Миграции expand → migrate → contract [РЕШЕНИЕ: D-03] | SQL-миграции forward-only (Drizzle `migrate()`); **expand**: только добавляющие изменения (новые таблицы/колонки nullable или с default, новые индексы) — код совместим со старой и новой схемой; **contract** (удаление/переименование/NOT NULL) — через ≥ 1 релиз, когда старая версия точно не вернётся. Откат кода без отката БД |
| Индексы на больших таблицах | `CREATE INDEX CONCURRENTLY` вне транзакции [ТИПОВО: PostgreSQL]; миграция помечается `-- no-transaction` |
| Бэкап перед миграцией | `backup_db.sh` вручную, проверка внешней копии |
| Отдельный шаг `migrate` | миграции — одноразовым контейнером `migrate`, **не** при старте `api`, чтобы ошибка миграции не положила сервис; `api` стартует только после `service_completed_successfully` |
| Простой | blue/green не требуется; допустим простой 1–3 мин в окно обслуживания (Q-032); `pos-app` переживает недоступность backend (кэш, повторы — D-32) |
| Журнал релизов | версия, дата, кто, результат, ссылка на smoke-тест — в `RELEASES.md` репозитория + журнал эксплуатации |

### 10.2. Совместимость приложения и API (минимальная версия)

| Правило | Содержание |
|---|---|
| Версия API | префикс `/api/v1` [РЕШЕНИЕ: D-37]; ломающие изменения — только в `/api/v2` (R2+); в R1 — только аддитивные изменения контракта |
| Минимальная версия приложения | backend публикует в `GET /health` и добавляет к **каждому** ответу заголовки `X-Min-App-Version` и `X-Recommended-App-Version` (значения для платформы из `X-Platform`; источник — `app_settings.min_app_version`/`recommended_app_version`, иначе env `MIN_APP_VERSION`/`RECOMMENDED_APP_VERSION`; формат env — `platform=semver` через запятую, например `android=1.2.0,windows=1.2.0`) [РЕШЕНИЕ: ядро §18.2 п.12]; `pos-app` сравнивает со своей версией и при несовместимости показывает экран «Требуется обновление» (SCR-90) с блокировкой финансовых операций. Значения задаются **по платформам** (`MIN_APP_VERSION`); необязательная `RECOMMENDED_APP_VERSION` включает мягкий баннер обновления без блокировки [РЕШЕНИЕ: D-46; R0 §17.1, §17.7] |
| Версия приложения в запросах | `pos-app` отправляет `X-App-Version`, `X-Platform`; `api` логирует и отвечает `426 Upgrade Required` (problem+json, `code=APP_UPDATE_REQUIRED`, заголовок `X-Min-App-Version`) при версии ниже `MIN_APP_VERSION` (4.3) [РЕШЕНИЕ: R0 §16.4] |
| Порядок обновления | 1) backend (совместимый со старым приложением) → 2) приложения (Android — APK; Windows — **zip-архив (`.exe` + DLL + `data/` + VC++ runtime), установка администратором** по процедуре 10.7 [РЕШЕНИЕ: ядро §20.2 п.13; Q-130/Q-193/Q-243 — допущение R1; подписанный MSIX — R2, ADR-039, 13 RM-H-007]; iOS — только при Q-008 «да»); в R1 Windows-сборка передаётся администратору заказчика вместе с файлом `SHA256SUMS` (10.7 шаг 1); MDM / внутренний портал раздачи в R1 не используются; канал раздачи APK и ключи подписи — Q-008, 13_ROADMAP Q-193 [НЕ ПОДТВЕРЖДЕНО] → 3) сразу после раздачи — поднятие `recommended_app_version` (мягкий баннер); 4) поднятие `min_app_version` — **только по регламенту 10.8**: не ранее чем через 30 дней после выпуска версии, становящейся минимальной (поддерживаются N и N−1) [РЕШЕНИЕ: ядро §20.2 п.14; Q-133] |
| OpenAPI | `GET /openapi.json` версии релиза хранится в артефактах CI; Dart-клиент генерируется из него [РЕШЕНИЕ: D-03] — расхождение контракта ловится на сборке |
| Сборка целевых платформ | CI собирает Android и Windows на каждый релиз; iOS — при наличии macOS-раннера (Q-008) [ПОДТВЕРЖДЕНО: мастер-промт, строка 505 — SRC-D-141] |

### 10.3. Процедура обновления прод (документ)

| Шаг | Действие | Проверка |
|---|---|---|
| 1 | Релиз проверен в `optomstroy-test` на копии прод-данных (восстановленный дамп, обезличенный при необходимости — Q-027) | протокол тестов 12_TEST_PLAN |
| 2 | Объявить окно (Q-032); остановить синхронизацию на время релиза: `docker compose stop worker` (в R1 — единственный способ; API-операции паузы синхронизации — **R2** [РЕШЕНИЕ: ядро §19.2, Q-219]) | `docker compose ps worker` → `exited` |
| 3 | `backup_db.sh` вручную; убедиться в наличии внешней копии | ping Healthchecks «OK» |
| 4 | `API_TAG=<новая версия>` в `.env`; `docker compose -p optomstroy-prod pull api worker migrate` | образы скачаны |
| 5 | `docker compose -p optomstroy-prod up -d migrate` → дождаться завершения с кодом 0 | `docker compose logs migrate`; версия схемы = версия релиза |
| 6 | `docker compose -p optomstroy-prod up -d api worker` — пересоздание контейнеров | `docker compose ps` → `healthy` |
| 7 | Prod-smoke без мутаций данных (10.9; T-OPS-024) — набор 10.5 в проде **не** выполняется | все пункты «OK» |
| 8 | Возобновить синхронизацию: `docker compose up -d worker` (API-возобновление — R2 [РЕШЕНИЕ: ядро §19.2, Q-219]); дождаться первого успешного `sync_run` по остаткам и статусам | `GET /sync/runs` |
| 9 | Запись в журнал релизов | |

Если шаг 5 или 7 не пройден — откат (10.4). Общая длительность — 5–15 мин, простой API — 1–3 мин.

### 10.4. Откат

| Ситуация | Действие |
|---|---|
| Smoke-тест не пройден, миграция была expand-only | `API_TAG=<предыдущая версия>` в `.env`; `docker compose up -d api worker`; smoke-тест; журнал. БД совместима — данные не теряются |
| Ошибка на шаге `migrate` (контейнер завершился с ошибкой) | миграция в транзакции откатывается сама; `api` старой версии продолжает работать (не пересоздавался); разбор причины; при необходимости — откат тега |
| Разрушающая миграция (не должно случаться) | восстановление из дампа шага 3 (8.5) с принятием потери данных за окно; запись инцидента |
| Ошибка обнаружена через часы после релиза | откат тега допустим, пока не выполнен `contract`; данные, записанные новой версией в expand-колонки, сохраняются |

### 10.5. Smoke-тест после деплоя в тестовом контуре (минимум; полный — 12_TEST_PLAN)

Набор 10.5 (8 шагов, 12 T-OPS-014) выполняется **только в тестовом контуре** `optomstroy-test` (E3, `api-test.<домен>`). В проде (E5) он не выполняется: после каждого деплоя, восстановления и обновления прода — только prod-smoke без мутаций данных по 10.9 (12 T-OPS-024) [РЕШЕНИЕ: ядро §20.2 п.6, исключение к 11 SEC-129].

1. `GET https://api-test.<домен>/health` → 200 (тело — только `status`, `minAppVersion`; SEC-019); `GET /health/ready` → 200; версия релиза проверяется на хосте: `docker compose -p optomstroy-test images api` показывает тег = `API_TAG` (публичные endpoint'ы версию ПО не раскрывают).
2. `curl -vI https://api-test.<домен>` — сертификат валиден, истекает > 20 дней; `curl -I http://…` → редирект 308/301.
3. Авторизация тестового сотрудника (`SMS_PROVIDER=fake` или `AUTH_OTP_TEST_MODE=true` с номером из `AUTH_OTP_TEST_PHONES`; реальные SMS в тестовом контуре — только приёмочный smoke 12 T-SMS-019 по Q-235).
4. `GET /search/products?q=<артикул>` → ≥ 1 результат; `GET /catalog/products/{id}` → 200; `GET /images/{sha}/thumb` → 200, `Content-Type: image/webp`.
5. `POST /sync/runs` (manual, `stock`) → `sync_runs.status=success` (`ONEC_MODE=fixtures` или тестовая копия 1С; рабочая 1С к тестовому контуру на запись не подключается — 13 §8.1).
6. Создание тестового заказа на тестовом контрагенте (Q-012): `POST /orders` → `201` (или `202` с `warnings[STALE_DATA]`), статус `submitting`; воркер outbox создаёт документ (`onec_outbox` → `sent`); в момент перехода в `sent` заказ получает номер 1С и проецируется по 10 §2.2: неоплаченный `cash`/`qr_bakai` → `awaiting_payment` (P8), `credit` или оплаченный → `pending_approval` (P9); последующий `sent → confirmed` повторной проекции не требует (ядро §22.3, §22.1, §23 п.2; 08 §4.8.1) — на тестовой копии 1С или фикстуре.
7. `ss -tulpn` на хосте — наружу только 80/443; `docker compose -p optomstroy-test ps` — все `healthy`.
8. `GET /settings/public` (Bearer тестового сотрудника) → 200; `features{customerSelfService, returnsFromPos, qrWebhook, debtPaymentsFromPos}` соответствуют конфигурации: `customerSelfService` = `CUSTOMER_SELF_SERVICE`, **`returnsFromPos` = `app_settings.returns_enabled`** (по умолчанию `true`; `RETURNS_FROM_POS_ENABLED` управляет только передачей заявок в 1С через outbox и в `features` не публикуется) [РЕШЕНИЕ: ядро §21 п.1], `qrWebhook` = `QR_WEBHOOK_ENABLED`, `debtPaymentsFromPos` = `DEBT_PAYMENTS_FROM_POS`; `supportContacts` заполнен из `app_settings.support_contacts` [РЕШЕНИЕ: ядро §19.2].

### 10.6. Обновления ОС и Docker

| Что | Как | Окно |
|---|---|---|
| Security-обновления ОС | `unattended-upgrades` автоматически; перезагрузка — только в окно обслуживания | согласованное окно (Q-032) |
| Обновления Docker Engine/Compose | вручную раз в квартал из apt-репозитория Docker; перед этим — бэкап; после — `docker compose up -d` и prod-smoke без мутаций (10.9) | окно |
| Минорные обновления `postgres` (17.x → 17.y) | смена тега образа; данные совместимы внутри мажорной версии [ТИПОВО: PostgreSQL] | окно |
| Мажорное обновление PostgreSQL (17 → 18) | отдельный план: `pg_dump`/`pg_restore` в новый контейнер или `pg_upgrade`; изменение точки монтирования тома (`/var/lib/postgresql`) [ПОДТВЕРЖДЕНО: hub.docker.com/_/postgres] | R2, Q-104 |
| Обновление Caddy | смена тега; том `caddy_data` сохраняется | окно |

### 10.7. Установка и обновление Windows-сборки `pos-app` из zip-архива (R1) [РЕШЕНИЕ: ядро §20.2 п.13]

Допущение R1 (Q-130/Q-193/Q-243): Windows-сборка распространяется **zip-архивом** и устанавливается **администратором ПК заказчика**; подписанный MSIX, сертификат code-signing, MDM и автообновление — R2 (ADR-039, 13 RM-H-007, 06 — таблица платформ). Процедура одна для первичной установки и для обновления; состав артефакта задают 13 RM-H-007 и 12 T-BUILD-005, здесь — только шаги установки. Под «администратором ПК» понимается сотрудник заказчика с правами локального администратора Windows на POS-терминале; это **не** роль `admin` приложения. Рабочий аккаунт ОС на терминале — общий, без прав администратора (ядро §20.2 п.12, Q-034); персональный вход сотрудников — PIN/OTP приложения.

**Ответственные:** релиз-менеджер исполнителя (DevOps) — выпуск и передача артефакта, контрольная сумма, release notes; администратор ПК заказчика — шаги 2–9 на каждом терминале; сотрудник с ролью `senior_seller`/`admin` приложения — проверка входа (шаг 8); DevOps — сводный журнал установок (шаг 9), который используется в 10.8.

| Шаг | Кто | Действие | Проверка / критерий |
|---|---|---|---|
| 0. Предусловия | DevOps | Backend, совместимый с новой и предыдущей версией клиента, уже развёрнут и прошёл prod-smoke (10.3, 10.9); в `docs/release/<version>.md` указаны версия, дата выпуска по платформам, SHA-256 архива, изменения локальной схемы drift и план `min_app_version` (13 RM-H-007, 10.8) | запись релиза существует |
| 1. Передача артефакта | DevOps → администратор ПК | Передать `optomstroy-pos-windows-<version>.zip` и файл `SHA256SUMS` **разными путями**: архив — по каналу, согласованному с заказчиком (по умолчанию — сетевая папка магазина с правом записи только у DevOps/администратора ПК или съёмный носитель; иной канал — Q-008 [НЕ ПОДТВЕРЖДЕНО]), значение SHA-256 — отдельно (письмом/сообщением ответственному или в `docs/release/<version>.md`) | администратор ПК подтвердил получение обоих |
| 2. Проверка целостности | администратор ПК | PowerShell от администратора: `Get-FileHash -Algorithm SHA256 .\optomstroy-pos-windows-<version>.zip` — значение совпадает с `SHA256SUMS`. Несовпадение → установка **прекращается**, архив удаляется, DevOps уведомляется (подпись исполняемого файла в R1 отсутствует, поэтому хэш — единственная проверка подлинности; остаточный риск — 11, Q-243) | хэш совпал |
| 3. Снятие отметки загрузки | администратор ПК | После совпадения хэша: `Unblock-File .\optomstroy-pos-windows-<version>.zip` (иначе файлы наследуют отметку «загружено из интернета» и SmartScreen выдаёт предупреждение для неподписанного `.exe`) [ТИПОВО: Windows 10/11 — проверить на терминале заказчика] | — |
| 4. Остановка приложения | администратор ПК + продавец терминала | Вне активной продажи (окно — конец смены или согласованное время, Q-032): завершить текущую операцию, выйти из учётной записи приложения, закрыть `pos-app`. Локальные черновики корзин сохраняются: файл БД и защищённое хранилище лежат в профиле ОС (`getApplicationSupportDirectory()`, `%APPDATA%\<CompanyName>\<ProductName>` — 07, 06/09), а не в каталоге программы | процесс `pos-app` не запущен (`Get-Process`) |
| 5. Распаковка | администратор ПК | `Expand-Archive -Path .\optomstroy-pos-windows-<version>.zip -DestinationPath "C:\Program Files\OptomstroyPOS\<version>"` — каждая версия в своём каталоге; каталог `Program Files` доступен на запись только администраторам, поэтому общий аккаунт ОС не может подменить исполняемые файлы. `CompanyName`/`ProductName` в `Runner.rc` между версиями не меняются (иначе меняется путь данных и теряются черновики/токены — 06) | в каталоге есть `.exe`, DLL, `data\` |
| 6. VC++ runtime | администратор ПК | По умолчанию DLL среды выполнения Visual C++ (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`) входят в архив рядом с `.exe` (13 RM-H-007, 12 T-BUILD-005) [ТИПОВО: docs.flutter.dev — раздел о распространении Windows-сборок; проверить на этапе 2]. Если при первом запуске Windows сообщает об отсутствии DLL — однократно установить Microsoft Visual C++ Redistributable 2015–2022 x64 **только** с сайта Microsoft (learn.microsoft.com, раздел «Latest supported Visual C++ Redistributable») и сообщить DevOps о дефекте артефакта | приложение запускается |
| 7. Ярлык | администратор ПК | Обновить общий ярлык `C:\Users\Public\Desktop\Оптомстрой POS.lnk` (и, если используется, ярлык в `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\`) на `C:\Program Files\OptomstroyPOS\<version>\<имя>.exe`; при первичной установке — создать | ярлык указывает на новую версию |
| 8. Проверка | администратор ПК + сотрудник `senior_seller`/`admin` | Запуск под **общим** аккаунтом ОС (не под администратором): экран «О приложении» (SCR-42) показывает `<version>`; вход сотрудника (PIN, при необходимости OTP); открывается каталог; нет экрана «Требуется обновление» (SCR-90); черновик корзины, сохранённый до обновления, на месте; при изменении локальной схемы drift — первая загрузка без ошибки миграции (12 T-COMPAT-006) | все пункты «да» |
| 9. Журнал установок | администратор ПК → DevOps | Запись: имя/инвентарный номер терминала, версия, дата и время, кто устанавливал, результат, совпадение хэша. DevOps ведёт сводный журнал установок по терминалам в журнале эксплуатации (10.1 «Журнал релизов») | все терминалы магазина отмечены |
| 10. Хранение предыдущей версии | администратор ПК | Каталог предыдущей версии (N−1) сохраняется до выпуска следующей версии — для отката; каталоги N−2 и старше удаляются | на терминале не более двух версий |

**Откат клиента на терминале:** вернуть ярлык (шаг 7) на каталог предыдущей версии — допустимо, только пока предыдущая версия не ниже действующего `min_app_version` (10.8). Если новая версия уже мигрировала локальную схему drift, запуск предыдущей версии с той же БД не гарантирован [НЕ ПОДТВЕРЖДЕНО: проверяется на этапе 2 по 07 §11.2 и 12 T-COMPAT-006]; тогда решение об удалении локального файла БД пользователя (теряются только кэш каталога и несинхронизированные черновики; серверная корзина сохраняется, D-32) принимает DevOps вместе с `admin` заказчика с записью в журнале.

### 10.8. Регламент изменения `MIN_APP_VERSION` (`app_settings.min_app_version`) [РЕШЕНИЕ: ядро §20.2 п.14; ADR-059, ADR-062; Q-133]

Правило ядра: поддерживаются минорные версии клиента **N и N−1** (N — последняя выпущенная версия **для данной платформы**); принудительное обновление (`426 APP_UPDATE_REQUIRED`, SCR-90) — только для версий ниже минимальной; значение задаёт `admin` **по платформам**; окно поддержки N−1 — **не менее 30 дней** с выпуска N. Сервер даты выпусков не проверяет (08 §2, политика поддержки версий) — соблюдение обеспечивает этот регламент.

**Где хранится значение:** действующее — `app_settings.min_app_version` (формат `platform=semver` через запятую), меняется `admin` через SCR-46 / `PUT /admin/settings` со step-up и событием аудита, без перезапуска контейнеров; env `MIN_APP_VERSION` (4.3) — только значение по умолчанию при отсутствии ключа (первичное развёртывание). `owner` — только просмотр SCR-46 (ядро §21 п.3). DevOps исполнителя значение в проде не меняет, а готовит предложение.

**Ограничения значения (проверяются перед каждым изменением):**
1. Для платформы минимум не выше N−1, пока с даты выпуска N на этой платформе не прошло 30 дней; поднятие до N — не ранее даты выпуска N + 30 дней.
2. Минимум никогда не выше последней **розданной** версии платформы (иначе блокируются все устройства).
3. Минимум меняется только для одной платформы за раз; значения других платформ в строке сохраняются без изменений.
4. Понижение минимума (возврат) допустимо в любой момент тем же способом.

| Шаг | Кто | Действие | Проверка / критерий |
|---|---|---|---|
| 1. План | DevOps (релиз-менеджер) | В `docs/release/<version>.md` — дата выпуска N по каждой платформе (D0) и самая ранняя допустимая дата поднятия минимума по ограничению 1 (13 RM-H-007, критерий 4) | запись есть |
| 2. Мягкий баннер | `admin` заказчика | Сразу после раздачи (D0): `recommended_app_version` для платформы = N (SCR-46, step-up) — клиенты ниже N видят неблокирующий баннер | `X-Recommended-App-Version` в ответах = N |
| 3. Раздача | администратор ПК / ответственный за Android-устройства | Windows — 10.7 на каждом терминале; Android — установка APK (канал — Q-008, Q-193) | журнал установок 10.7 шаг 9 |
| 4. Предпроверка (не ранее чем за 1 рабочий день до изменения) | DevOps | (а) выполнены ограничения 1–2; (б) по журналу установок все POS-терминалы платформы на версии ≥ новой минимальной; (в) по журналу `api` за 7 дней — агрегат «платформа × `X-App-Version`» (без телефонов, `userId` и иных ПДн — раздел 9): запросов от версий ниже новой минимальной нет, либо их перечень по `deviceId` передан `admin` для обновления; (г) сотрудники предупреждены о дате | протокол предпроверки приложен к записи релиза |
| 5. Изменение | `admin` заказчика | В согласованное окно вне пиковых часов (Q-032): SCR-46 → `min_app_version`, изменена пара только целевой платформы; step-up; аудит | событие аудита изменения настройки (AC-ADR-062) |
| 6. Контроль | DevOps | `GET /health` с `X-Platform: <платформа>` → `minAppVersion` = новое значение; любой ответ API содержит `X-Min-App-Version` = новое значение; в течение часа — нет обращений в поддержку о SCR-90 с актуальной версией. Проверка `426` старым клиентом — только в тестовом контуре (12 T-COMPAT-004), в проде — без мутаций | значения совпадают |
| 7. Выравнивание env | DevOps | В ближайшем релизе backend env `MIN_APP_VERSION` в `.env` выставляется не ниже действующего `app_settings.min_app_version` (чтобы удаление ключа не понизило минимум незаметно) | `.env` = значение ключа |
| 8. Журнал | DevOps | Дата, платформа, старое → новое значение, кто изменил, ссылка на событие аудита и протокол предпроверки | запись в журнале эксплуатации |

**Возврат:** если после изменения работа терминала заблокирована SCR-90 (терминал не обновлён), `admin` возвращает прежнее значение (SCR-46, step-up, аудит), терминал обновляется по 10.7, изменение повторяется с шага 4. **Досрочное повышение** (например, уязвимость в N−1) ядром не предусмотрено: только по письменному решению заказчика с записью ADR в 15_DECISION_LOG (открытый остаток Q-133) [НЕ ПОДТВЕРЖДЕНО].

### 10.9. Prod-smoke без мутаций данных (E5) [РЕШЕНИЕ: ядро §20.2 п.6; 11 SEC-129; 12 T-OPS-024]

Выполняется в проде после каждого деплоя (10.3 шаг 7), восстановления (8.5 шаг 7), обновления Docker/PostgreSQL/Caddy (10.6) и при первичном развёртывании (14.1). Перечень API-проверок **исчерпывающий** (исключение к SEC-129); всё, чего нет в таблице, в проде не выполняется. Набор 10.5 в проде не применяется.

**Участники:** DevOps исполнителя — запускает `scripts/smoke.sh prod --read-only` (12 T-OPS-024) [ТИПОВО] и оформляет протокол; **технический сотрудник** заказчика — учётная запись приложения с ролью `seller` (минимум прав, достаточный для чтения каталога и `sync.status.read`, 11 §4.4; без `cashier`/`admin`), внутренний (служебный) номер телефона, **письменное согласие** на получение OTP и обработку номера (хранится у заказчика; бюджет SMS — Q-235); учётная запись создаётся `admin` заранее и не является частью smoke; `admin` заказчика — получает протокол.

| № | Проверка | Ожидание | Кто |
|---|---|---|---|
| 1 | `GET https://api.<домен>/health` | 200; тело — только `status`, `minAppVersion` (SEC-019); сертификат валиден, истекает > 20 дней (`curl -v`) | DevOps |
| 2 | `GET /health/ready` | 200; `db`, `queue`, `syncAgeOk` в норме (раздел 9, DEPLOY-038) | DevOps |
| 3 | Вход по OTP технического сотрудника: `POST /auth/otp/request` → одна реальная SMS на внутренний номер → `POST /auth/otp/verify`; по окончании прогона — `POST /auth/logout` (закрытие созданной сессии) | вход выполнен, токен получен; код вводит сам сотрудник или сообщает DevOps в момент прогона — код и номер в протокол и логи не записываются (номер — в маске) | DevOps + технический сотрудник |
| 4 | Чтение каталога: `GET /catalog/products?limit=40` (допускаются также `GET /catalog/products/{id}`, `GET /search/products?q=<артикул>`, `GET /images/{sha}/thumb`) | 200; ≥ 1 товар; миниатюра — `image/webp` | DevOps |
| 5 | `GET /sync/status` | 200; свежесть сущностей в пределах порогов раздела 9; прогоны **не** запускаются | DevOps |
| 6 | Баланс SMSPro: `POST /api/info` SMSPro (R2 §5.1) — с сервера, из контейнера `worker`; учётные данные — только из `secrets/` (не в командной строке и не в выводе; служебная команда — этап 2 [НЕ ПОДТВЕРЖДЕНО]) | ответ получен; баланс ≥ `SMSPRO_BALANCE_ALERT_SOM` | DevOps |

**Проверки на хосте** (без обращений к данным, не входят в перечень SEC-129 как API-тесты): `docker compose -p optomstroy-prod images api` — тег = `API_TAG`; `docker compose -p optomstroy-prod ps` — все `healthy`; `ss -tulpn` — наружу только 80/443; счётчики `SELECT count(*)` бизнес-таблиц (`orders`, `payments`, `carts`, `cart_items`, `onec_outbox`, `return_requests` — имена по 07 §5; `sms_outbox` не входит: шаг 3 пишет в него одну OTP) под ролью только чтения (`pos_readonly`, 07) — **до и после** прогона совпадают.

**Запрещено в prod-smoke:** любые `POST`/`PUT`/`PATCH`/`DELETE` к API, кроме трёх вызовов шага 3; создание корзин, заказов, платежей, заявок на возврат; `POST /sync/runs`, повтор outbox, изменение настроек и пользователей; иные SMS, кроме одной OTP; нагрузочные тесты и тесты перебора (SEC-129). Допустимые служебные записи — только порождённые шагом 3 (OTP-запрос, сессия и её закрытие, события аудита входа, журнал SMS); это не бизнес-данные.

**Результат:** протокол (дата, версия, отметки «ok» по шагам 1–6 и проверкам хоста, счётчики до/после, кто выполнял) прикладывается к записи релиза (OPS-023). Непройденный шаг → откат по 10.4. Исключение: при шаге 6 с работающим API SMSPro и балансом ниже порога — это не дефект релиза: алерт и пополнение баланса (раздел 9), откат не выполняется.

---

## 11. Тестовое и рабочее окружения на одном сервере

Требование: разделить тестовое и рабочее окружения настолько, насколько позволяют ресурсы [ПОДТВЕРЖДЕНО: SRC-F-141].

| Параметр | prod | test |
|---|---|---|
| Compose project | `optomstroy-prod` | `optomstroy-test` |
| Каталоги | `/opt/optomstroy/prod`, `/srv/optomstroy/prod` | `/opt/optomstroy/test`, `/srv/optomstroy/test` |
| Поддомен | `api.<домен>` (предложение Q-032) | `api-test.<домен>` — разные имена для разделения контуров (свои сертификаты, конфиги, учётные данные) |
| Reverse-proxy | один общий Caddy в отдельном проекте `optomstroy-edge`, подключённый к `edge`-сетям обоих проектов (один набор 80/443), **либо** два Caddy на 443 и 8443 (второй вариант — только если нельзя объединить) | |
| БД | свой контейнер `postgres`, том `pgdata`, роль и БД `optomstroy_prod` | свой контейнер, свой том, роль и БД `optomstroy_test`; **при нехватке RAM** — одна БД-инстанция с двумя базами (R5 §7.2), с отметкой «пониженная изоляция» |
| Секреты | свои `secrets/` | свои, **никогда** не копии прод-секретов (кроме публичных) |
| `APP_ENV` / режимы | `prod`; `SMS_PROVIDER=smspro`; `AUTH_OTP_TEST_MODE=false`, `AUTH_OTP_TEST_PHONES` пусто | `staging`; `SMS_PROVIDER=fake` (`FakeSmsGateway`: OTP пишется в таблицу `dev_outbox` — только dev/test, R0 §17.3; не в прод-логи) или `smspro` + `SMSPRO_TEST_FLAG=true` для smoke учётных данных; `AUTH_OTP_TEST_MODE=true` с allowlist `AUTH_OTP_TEST_PHONES` |
| 1С | рабочая 1С (на пилоте — только чтение до разрешения записи) | **тестовая копия 1С** (Q-011) или режим «изолированный тест» с фикстурами (`ONEC_MODE=fixtures` [РЕШЕНИЕ: R0 §16.3]) — требование мастер-промта об изолированном тестовом режиме; **никогда** — рабочая 1С |
| Данные | реальные | копия прод-дампа, обезличенная при необходимости (телефоны, ФИО) — Q-027; или синтетические фикстуры |
| Ресурсы | лимиты по разделу 5 | меньшие лимиты (`postgres` 512M, `api` 512M, `worker` 512M); можно останавливать вне тестов (`docker compose -p optomstroy-test stop`) |
| Бэкапы | полные (раздел 8) | не требуются (кроме цели restore-drill) |
| Мониторинг | полный | только `/health/ready` в Uptime Kuma с низким приоритетом |
| Фото | полный набор | уменьшенный набор (например, 1 000 SKU) |

Если ресурсов не хватает даже на уменьшенный тест (RAM < 6 GB), тестовый контур разворачивается на другом хосте (ноутбук разработчика / недорогой VPS, раздел 13) — это не снижает требований к проду.

```mermaid
flowchart TB
  subgraph HOST["Сервер заказчика"]
    subgraph EDGE["optomstroy-edge"]
      CD[caddy :80 :443<br/>api.домен → prod · api-test.домен → test]
    end
    subgraph PROD["optomstroy-prod"]
      PA[api] --- PW[worker] --- PP[(postgres prod)]
    end
    subgraph TEST["optomstroy-test"]
      TA[api] --- TW[worker] --- TP[(postgres test)]
    end
  end
  CD --> PA
  CD --> TA
  PW -- LAN/VPN --> ONEP[1С рабочая]
  TW -- LAN/VPN --> ONET[1С тестовая копия / фикстуры]
```

---
## 12. Связь с 1С: сеть и публикация

Протокол обмена (OData, HTTP-сервис расширения `onec-extension`, план обмена «POS») — 05_ONEC_INTEGRATION.md [РЕШЕНИЕ: D-28]. Здесь — сетевой уровень и публикация [ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-031, Q-010, Q-011]. Конфигурация и версия платформы 1С **неизвестны** — все имена и параметры публикации `[ТИПОВО]`.

### 12.1. Вариант LAN — backend и 1С в одной сети магазина (сценарии A, B-3)

| Аспект | Содержание |
|---|---|
| Адресация | `ONEC_BASE_URL=https://<lan-ip-или-имя>/<база>`; имя хоста 1С резолвится локальным DNS или записью в `/etc/hosts` контейнера (`extra_hosts:` в compose) |
| Транспорт | HTTPS даже в LAN (самоподписанный/корпоративный сертификат веб-сервера 1С — доверять через `ONEC_CA_CERT_FILE` (4.3) [РЕШЕНИЕ: R0 §16.3], не отключать проверку); HTTP допустим **только** на тестовой копии в изолированной сети |
| Веб-сервер 1С | Apache 2.4 или IIS; публикация через Конфигуратор «Администрирование → Публикация на веб-сервере» или `webinst`; `default.vrd` с `<httpServices>` и стандартным OData [ПОДТВЕРЖДЕНО (существование механизма): R1 §7; имена атрибутов — ТИПОВО] |
| Доступ | только из IP backend (allow-list на веб-сервере 1С или firewall хоста 1С); веб-клиент 1С не публикуется |
| Сервер 1С | в B-3 — сеть Hyper-V «internal/external» с маршрутом до хоста; в A — обычная LAN |
| Пользователи ИБ | **разведены** (05 ONEC-052, ONEC-082; D-28 — отдельный пользователь только чтение): (1) `pos_integration` (имя — предложение R1 §7) — **только** стандартный OData, **только чтение** объектов из allow-list 05 §5 (ONEC-083) + «Удалённый доступ через OData» (БСП); без прав «Добавление/Изменение/Удаление» и **без** роли `POS_ИнтеграцияPOS`; секреты — `ONEC_USER_FILE`/`ONEC_PASSWORD_FILE` (4.3); (2) `pos_hs` (05) — **только** HTTP-сервис расширения с ролью `POS_ИнтеграцияPOS`, без роли OData и без прямых прав записи объектов (запись — только привилегированный код `POS_Сервер`, ONEC-053); секреты — `ONEC_HS_USER_FILE`/`ONEC_HS_PASSWORD_FILE` + `ONEC_HS_TOKEN_FILE` (4.3); (3) `pos_odata_write` (05 ONEC-028) — **только** во временном режиме записи через OData (`ONEC_ODATA_WRITE_ENABLED=true`), право добавления только `ЗаказКлиента`, блокируется при выключении режима; секреты — `ONEC_ODATA_WRITE_USER_FILE`/`ONEC_ODATA_WRITE_PASSWORD_FILE` (4.3). У всех: «Показывать в списке выбора» снято, интерактивный вход запрещён, не администраторы, пароль ≥ 16 символов |
| Требования к сети | латентность LAN < 5 мс; backend выдерживает недоступность 1С (outbox, `ONEC_UNAVAILABLE`, D-32) |

### 12.2. Вариант WireGuard — backend вне LAN, туннель инициирует магазин (сценарии C-1, также A при 1С на другой площадке)

```mermaid
sequenceDiagram
  participant M as Машина 1С (магазин, за NAT)
  participant V as VPS / сервер backend (WireGuard ListenPort UDP)
  participant W as worker / api
  participant O as 1С веб-публикация (только в подсети туннеля)
  M->>V: Handshake WireGuard (исходящий UDP, PersistentKeepalive 25 c)
  Note over M,V: входящих портов в магазине нет, AllowedIPs = подсеть туннеля
  W->>O: HTTPS через 10.x.x.x (адрес 1С в туннеле)
  O-->>W: OData / HTTP-сервис ответы
  Note over M,V: при смене публичного IP магазина туннель переезжает (roaming)
```

| Аспект | Содержание |
|---|---|
| Роли | VPS — `[Interface] ListenPort=<порт>` (в документации примеры с 51820 — реальный порт согласовать), `[Peer]` магазина с `AllowedIPs=<адрес 1С в туннеле>/32`; машина 1С — `[Peer] Endpoint=<VPS>:<порт>`, `PersistentKeepalive=25` [ПОДТВЕРЖДЕНО: https://www.wireguard.com/] |
| ПО в магазине | WireGuard для Windows (официальный установщик, Windows 10/11, Server 2016–2025) или Linux (`apt install wireguard`) [ПОДТВЕРЖДЕНО: https://www.wireguard.com/install/]; установка на машину 1С — согласование (6.3 №9) |
| Firewall VPS | входящий UDP `<порт>` разрешён только для WireGuard; публикация 1С доступна только из подсети туннеля |
| Ключи | генерируются на каждой стороне; приватные не покидают хост; `wg0.conf` — `600`; ротация при компрометации |
| Отказ | при обрыве интернета в магазине — синхронизация останавливается, `/health/ready` → `degraded`, алерт; backend продолжает обслуживать приложения по кэшу (D-32); `onec_outbox` накапливает заказы |
| Альтернатива | IPsec/OpenVPN на роутере магазина, если админ заказчика настаивает — [ТИПОВО], не рекомендовано из-за сложности |

### 12.3. Вариант «исходящий обмен» — 1С сама вызывает backend (сценарий C-2)

| Аспект | Содержание |
|---|---|
| Механизм | регламентное задание 1С (расширение `onec-extension`) по расписанию вызывает `https://api.<домен>/api/v1/integrations/onec/*` [РЕШЕНИЕ: R0 §16.5, §17.4; детали — 05, 08]: `POST …/changes` и `POST …/snapshots/{entity}` — push изменений и снимков справочников/остатков/цен; `POST …/order-status` — статусы заказов; `GET …/outbox` + `POST …/outbox/{outboxId}/ack` — pull заказов, платежей, новых клиентов из outbox и подтверждение; `GET …/ping` — проверка связи (вариант `heartbeat` не используется). Префикс включается только здесь: `ONEC_INBOUND_ENABLED=true` (по умолчанию `false` → `404`) |
| Авторизация | технический токен роли `integration` [РЕШЕНИЕ: D-15; R0 §16.5]: хэш в `integration_tokens` (без строки в `users`, R0 §17.3), выпуск — `bin/issue_integration_token` (токен показывается один раз; переменных окружения и секрет-файлов нет), срок жизни 180 дней с ротацией, отзыв — тем же скриптом или `DELETE`-операцией в админ-разделе R2 [РЕШЕНИЕ: ядро §18.2 п.4]; токен хранится в 1С как секрет расширения; mTLS в R1 **не используется** (05 ONEC-060); отдельный rate-limit (05 ONEC-060); **обязательный** allow-list внешнего IP магазина в `api` — `ONEC_INBOUND_ALLOWED_IPS` (при динамическом IP — согласованный диапазон провайдера, Q-031; пустой список при `ONEC_INBOUND_ENABLED=true` — отказ в старте); фильтр `remote_ip` в proxy — необязательный дублирующий слой (4.6, DEPLOY-050) |
| Требования к 1С | платформа 8.3 с `HTTPСоединение` и регламентными заданиями; для файловой базы — постоянно запущенный сеанс/планировщик [ТИПОВО: Q-010] |
| Ограничения | backend не может запросить обмен «по требованию»: контракт входящего обмена (05 §10.1 — владелец, R0 §18.1) механизма запроса со стороны backend не содержит, механизм `requests[]` не вводится. Ручной запуск синхронизации в C-2 **недоступен** [РЕШЕНИЕ: ядро §22.8]: `POST /sync/runs` → `422 VALIDATION_FAILED` (`rule: inbound_mode`) для любой сущности и роли, кнопка на SCR-43 неактивна с пояснением (05 SYNC-025, 08 §4.17.2, 11 §4.3.1); данные обновляются на ближайшем регламентном вызове 1С (период задаётся в 1С), полный срез (`full`) и сверку (`reconcile`) запускает администратор 1С обработкой расширения по runbook 15.2. Входящий `…/order-status` несёт сырые статусы 1С, проекцию делает backend (ядро §22.8; 08 §4.21.4). Синхронная проверка `/check` невозможна — заказ создаётся с `202` и `warnings[STALE_DATA]` по снимку (ядро §22.3; 08 §4.8.1); продажа в долг — по порядку ядра §22.4 (владелец — 10 PAY-031): свежий полный снимок без блокировок — долг без обращения к 1С, иначе `422 RECEIVABLES_STALE`; `503 ONEC_UNAVAILABLE` для `credit` не возвращается |
| Когда выбирать | входящие порты в магазине недоступны **и** нельзя поставить WireGuard на машину 1С |

### 12.4. Если входящие порты в магазине недоступны — порядок действий

1. Подтвердить у провайдера/админа: статический IP, возможность проброса 443 (и UDP для WireGuard-«сервера» в магазине — не требуется при варианте 12.2, где магазин — клиент).
2. Если backend остаётся в магазине (A/B-3), а приложения нужны вне магазина: заказать статический IP + проброс 443 (стоимость — Q-039) **или** DDNS + проброс; при невозможности — перенос backend на VPS (C).
3. Если backend на VPS: вариант 12.2 (магазин инициирует туннель — входящие порты не нужны) → при запрете установки WireGuard на машину 1С — вариант 12.3.
4. Любой вариант фиксируется ответом на Q-031 и отражается в `ONEC_MODE`, `ONEC_BASE_URL`, `ONEC_INBOUND_ENABLED` (C-2 — `ONEC_MODE=extension` + `ONEC_INBOUND_ENABLED=true`, 05 ONEC-065; LAN и WireGuard — `ONEC_INBOUND_ENABLED=false`).

### 12.5. Требования к публикации 1С (передаются 1С-специалисту; детали — 05_ONEC_INTEGRATION)

| # | Требование | Статус |
|---|---|---|
| P-1 | Публикация ИБ на веб-сервере (Apache/IIS) с включёнными HTTP-сервисами расширения и стандартным OData; веб-клиент — выключен | [ТИПОВО] |
| P-2 | HTTPS на веб-сервере 1С (IIS — штатно; Apache — `mod_ssl`) | [ПОДТВЕРЖДЕНО (существование раздела руководства): R1 §7] |
| P-3 | Доступ только из адреса backend/подсети туннеля; `$top` ограничен, rate-limit на прокси | рекомендация R1 §7 |
| P-4 | Разведённые пользователи ИБ (05 ONEC-052, ONEC-082): `pos_integration` — только OData, только чтение (allow-list объектов); `pos_hs` — только роль `POS_ИнтеграцияPOS` HTTP-сервиса, без OData и без прямых прав записи; `pos_odata_write` — только при временном режиме ONEC-028 (добавление `ЗаказКлиента`), блокируется при его выключении; у всех — без интерактивного входа, не администраторы; секреты — 4.3 (`ONEC_USER_FILE`/`ONEC_PASSWORD_FILE`, `ONEC_HS_USER_FILE`/`ONEC_HS_PASSWORD_FILE`/`ONEC_HS_TOKEN_FILE`, `ONEC_ODATA_WRITE_USER_FILE`/`ONEC_ODATA_WRITE_PASSWORD_FILE`). Приёмка: POST/PATCH/DELETE через OData под `pos_integration` → 403; любой OData-запрос под `pos_hs` → 401/403 (AC-ONEC-082) | [ТИПОВО] |
| P-5 | Тестовая копия ИБ с отдельной публикацией для `optomstroy-test` | Q-011 |
| P-6 | Серверная лицензия 1С для HTTP-сервисов/OData — уточнить у франчайзи | [НЕ ПОДТВЕРЖДЕНО] |

---

## 13. Если сервер слаб или небезопасен: минимальные улучшения vs VPS

Требование [ПОДТВЕРЖДЕНО: SRC-F-140]. Цены компонентов в КР не исследованы [НЕ ПОДТВЕРЖДЕНО]; тарифы VPS — по официальным страницам, дата обращения 2026-10-18 (R8 §9.2).

### 13.1. Минимальные улучшения существующего сервера

| Проблема по аудиту | Минимальное улучшение | Стоимость (ориентир) | Комментарий |
|---|---|---|---|
| RAM < 4 GB или занята 1С/MS SQL | добавить RAM до 8–16 GB | разовая покупка модулей [НЕ ПОДТВЕРЖДЕНО] | самое дешёвое и эффективное; требует остановки сервера |
| Данные на HDD | добавить SSD/NVMe ≥ 250 GB под `/srv/optomstroy` | разовая [НЕ ПОДТВЕРЖДЕНО] | БД и фото — на SSD; HDD остаётся под локальные бэкапы |
| ОС вне поддержки (CentOS 7, Ubuntu ≤ 20.04, Windows Server ≤ 2012 R2) | переустановка ОС (Ubuntu 24.04 LTS) или Linux-VM (B-3) | трудозатраты | переустановка «боевого» сервера с 1С — высокий риск; предпочесть VM или VPS |
| Нет статического IP / 443 закрыт провайдером | статический IP у провайдера или сценарий C | ежемесячно, Q-039 [НЕ ПОДТВЕРЖДЕНО] | |
| Нет бэкапов, один диск | второй диск + внешнее хранилище (раздел 8) | разовая + ежемесячно за хранилище | обязательно при любом сценарии |
| RDP/SSH по паролю из интернета | ключи, fail2ban, VPN (раздел 7) | трудозатраты | |
| Сервер — VM без вложенной виртуализации, Windows | B-2 для теста + VPS для прода | VPS ежемесячно | |

### 13.2. Альтернатива — VPS (подтверждённые тарифы с URL)

Требование к VPS для R1: 2–4 vCPU, 4–8 GB RAM, 80–160 GB SSD/NVMe, Linux.

| Провайдер / локация | Тариф (vCPU / RAM / диск) | Цена | Статус |
|---|---|---|---|
| **Serverspace** (vStack), Алматы (Казахстан), Ташкент и др. | 2 vCPU / 4 GB / 80 GB SSD, 200 Mbit/s | €36,93/мес (€0,051/ч), без НДС | [ПОДТВЕРЖДЕНО: https://serverspace.io/pricing/] |
| | 4 vCPU / 8 GB / 160 GB SSD, 500 Mbit/s | €91,74/мес (€0,127/ч) | [ПОДТВЕРЖДЕНО: там же]; доп. диск €0,10/GB/мес (100 GB фото ≈ €10/мес) |
| | 1 vCPU / 2 GB / 50 GB SSD | €15,38/мес | [ПОДТВЕРЖДЕНО: там же] — мало для прода, подходит для тестового контура |
| **Timeweb Cloud**, Москва | MSK Ultra 50: 2 vCPU / 4 GB / 50 GB NVMe | 5 480 ₽/мес | [ПОДТВЕРЖДЕНО: https://timeweb.cloud/services/cloud-servers — цены только для Москвы] |
| | Cloud KZ 80 (Казахстан): 4 vCPU / 8 GB / 80 GB SSD | ~8 690 ₽/мес | [НЕ ПОДТВЕРЖДЕНО: агрегатор hostinghub.ru] |
| **DigitalOcean** (Франкфурт/Бангалор/Сингапур — латентность до КР выше) | 2 vCPU / 4 GiB / 80 GiB SSD | $24/мес | [ПОДТВЕРЖДЕНО: https://www.digitalocean.com/pricing/droplets] |
| | 4 vCPU / 8 GiB / 160 GiB SSD | $48/мес | [ПОДТВЕРЖДЕНО: там же] |
| **Hetzner Cloud** (Германия/Финляндия) | CX/CPX — цены на официальных страницах не отображались при обращении | — | [НЕ ПОДТВЕРЖДЕНО: https://www.hetzner.com/cloud/] |
| **Hoster.kg** (Бишкек) | KVM-SMALL 1 vCPU / 1 GB / 15 GB; KVM-MIDDLE/LARGE | 800 / 1 200 / 1 600 KGS/мес | [НЕ ПОДТВЕРЖДЕНО: агрегатор whtop.com, 2020 г.] — мало для R1, запросить КП на 4–8 GB |
| **Borneo.kg** | Bungalow+ 2 ядра / 1 GB / 20 GB | 1 100 KGS/мес | [НЕ ПОДТВЕРЖДЕНО: whtop.com, 2023 г.] — мало, запросить КП |
| **ProHost** (Бишкек, ЦОД), Datatime, NSP Data Center | VPS/колокейшн — цены по запросу | — | [НЕ ПОДТВЕРЖДЕНО: datacentermap.com] — кандидаты для КП и для колокейшна сервера заказчика |

### 13.3. Сравнение «улучшить сервер» vs «VPS» (3 года)

| Критерий | Апгрейд сервера заказчика | VPS (Serverspace 4/8/160, Алматы) | VPS в КР (по КП) |
|---|---|---|---|
| Разовые затраты | RAM + SSD (разовая, [НЕ ПОДТВЕРЖДЕНО]) | 0 | 0 |
| Ежемесячно | электроэнергия/канал; статический IP (Q-039) | ≈ €92 + €10 за диск фото ≈ €102/мес → ≈ €3 700 за 3 года | по КП (оплата в сомах) |
| Латентность до магазина | LAN — минимальная | десятки мс (Алматы) [НЕ ПОДТВЕРЖДЕНО: измерить `ping`/`mtr`] | минимальная в пределах КР |
| Связь с 1С | LAN | WireGuard / исходящий обмен (раздел 12) | то же |
| Зависимость от интернета магазина | критическая для доступа извне | backend всегда доступен; синхронизация зависит | то же |
| Локализация ПДн (ст. 89 ЦК КР) | в КР | за рубежом — трансграничная передача, требует юр. заключения (Q-027) | в КР |
| Окупаемость | апгрейд обычно окупается относительно VPS за 6–12 мес [НЕ ПОДТВЕРЖДЕНО — оценка] | — | — |
| Рекомендация | если сервер исправен и есть публичный IP — **апгрейд + A** | если сервер непригоден и нет IP — **C** с предпочтением местного ЦОД после КП | |

Во всех VPS-вариантах 1С остаётся в магазине → сценарий C.

---

## 14. План первичного развёртывания (этап 2) и план отката

Предусловия: ТЗ утверждено («ТЗ УТВЕРЖДЕНО. НАЧИНАЙ РАЗРАБОТКУ» — единственная фраза, разрешающая этап 2; блокирующие вопросы 14 §2 условием утверждения не являются и блокируют только зависящие задачи, 13 §9 — ядро §22.13 п.5; вопросы этого раздела Q-030/Q-031/Q-033 блокируют шаги развёртывания, а не утверждение); аудит (раздел 2) выполнен; сценарий выбран (3.5); 12 пунктов (6.3) согласованы; **отдельное письменное разрешение заказчика на установку на сервер** [ПОДТВЕРЖДЕНО: SRC-F-139, SRC-F-145]. Результат этапа — «Инструкция по установке, настройке и развёртыванию» (SRC-D-171), собираемая из этого раздела и разделов 4, 7, 8, 10, 15.

### 14.1. Пошаговый план

| Шаг | Действия | Проверка (критерий) | Откат шага | Кто |
|---|---|---|---|---|
| 0. Предусловия | чек-лист предусловий подписан; выбран вариант прав `optomstroy` (Q-102); получены DNS-доступ, канал алертов, учётные данные SMSPro/1С по защищённому каналу (не чат) | подписанный чек-лист | — | Заказчик + главный архитектор |
| 1. Подготовка хоста | пользователь `optomstroy`, SSH-ключи, `sshd` без паролей (по согласованию), fail2ban, unattended-upgrades, NTP/`Asia/Bishkek`, Docker Engine + Compose v2, каталоги `/opt/optomstroy`, `/srv/optomstroy`, `/etc/docker/daemon.json` (ротация логов), firewall 22/80/443 (C-1: + UDP WireGuard на VPS) | `docker compose version`; `ss -tulpn` и `iptables -S DOCKER-USER` — только ожидаемые порты; `timedatectl` synced | удаление пользователя/пакетов по списку установленного (журнал шага) | DevOps |
| 2. DNS | A-записи `api.<домен>`, `api-test.<домен>` → публичный IP | `dig +short` с внешнего резолвера = IP сервера | удаление записей | Владелец домена |
| 3. TLS | запуск `caddy` с реальными именами; на время отладки — staging CA (чтобы не упереться в лимиты LE) | `curl -vI https://api.<домен>` без ошибок; HTTP → редирект | `docker compose down caddy`; том `caddy_data` сохраняется | DevOps |
| 4. Секреты и конфиг | генерация пароля БД и пароля роли миграций (`db_migrator_password`), ключей JWT (ed25519/ES256) с `JWT_KEY_ID` и набором `jwt_public.json` (`{kid: pem}`), `otp_pepper`, `pin_pepper`, `age`-ключа (приватный `BACKUP_AGE_IDENTITY_FILE` — заказчику офлайн, на сервер не кладётся); учётные данные SMSPro, 1С OData (`onec_user/onec_password`) и HTTP-сервиса (`onec_hs_user/onec_hs_password/onec_hs_token`) — в `secrets/` (`600`); в C-2 — выпуск токена 1С скриптом `bin/issue_integration_token` после шага миграций (не файл в `secrets/`, R0 §18.2 п.4); `.env` из `.env.example` (4.3); `rclone.conf` к внешнему хранилищу | `ls -la secrets/` → `-rw-------`; `git status` чист; `rclone lsd offsite:` | удаление `secrets/` (перегенерация) | DevOps + заказчик |
| 5. Тестовый контур | `optomstroy-test`: `postgres`, `migrate`, `api`, `worker` в режиме `staging` (`SMS_PROVIDER=fake`, `ONEC_MODE=fixtures` или тестовая копия 1С) | smoke-тест 10.5 пройден на `api-test.<домен>` | `docker compose -p optomstroy-test down -v` | DevOps + backend |
| 6. Миграции прод | `optomstroy-prod`: `postgres` + `migrate` на пустой БД (expand) | версия схемы = версия релиза; `migrate` завершён с кодом 0 | `down -v` (БД пуста) | Backend |
| 7. Первичный импорт из 1С | полная загрузка справочников (категории, товары, варианты, единицы, штрихкоды, склады, цены, остатки, клиенты, долги, история) по согласованному протоколу; загрузка фото; **сверка количеств** `$count` 1С = `count(*)` backend по каждой сущности; контроль дубликатов | отчёт сверки: расхождения = 0 или объяснены; `sync_runs.status=success` по всем `sync_entity` | очистка реплик (`TRUNCATE` реплик 1С) и повтор | 1С-специалист + backend |
| 8. Деплой прод | `api`, `worker` с релизным тегом; расписание D-29; `backup` + первый ручной `backup_db.sh`; Uptime Kuma (внешний хост) + Healthchecks подключены; алерты в согласованный канал | `/health/ready` 200; первый успешный `sync_run` по остаткам/ценам/статусам; внешняя копия бэкапа существует; тестовый алерт получен | `docker compose -p optomstroy-prod stop api worker` (данные сохраняются) | DevOps |
| 9. Smoke-тест и пилот | prod-smoke без мутаций 10.9 (в тестовом контуре — 10.5) + сценарии пилота из 12_TEST_PLAN на тестовом контрагенте (Q-012); реальные продажи — только после согласования | протокол приёмки | возврат к работе без POS (1С напрямую) | QA + заказчик |
| 10. Передача | инструкция по установке/настройке/развёртыванию (SRC-D-171), runbooks (раздел 15), схема сети и портов, реестр секретов (без значений), контакты и эскалация, журнал релизов; обучение админа заказчика; передача ключей/доступов | акт передачи; админ заказчика самостоятельно выполняет обновление и restore-drill в тесте | — | DevOps |

```mermaid
flowchart LR
  S0[0 Предусловия] --> S1[1 Хост] --> S2[2 DNS] --> S3[3 TLS] --> S4[4 Секреты] --> S5[5 Тест-контур] --> S6[6 Миграции prod] --> S7[7 Импорт из 1С + сверка] --> S8[8 Деплой prod + мониторинг + бэкап] --> S9[9 Smoke + пилот] --> S10[10 Передача]
  S5 -. не пройден .-> S4
  S7 -. расхождения .-> S7
  S9 -. не пройден .-> R[Откат 14.2]
```

### 14.2. План отката первичного развёртывания

| Уровень | Когда | Действия | Что сохраняется |
|---|---|---|---|
| Откат релиза | smoke/пилот не пройден после шага 8 | 10.4: предыдущий тег или остановка `api`/`worker`; магазин работает в 1С напрямую | БД, фото, бэкапы, сертификаты |
| Откат данных | импорт из 1С с расхождениями | `TRUNCATE` реплик 1С, повторный импорт; операционные таблицы не затрагиваются | пользователи, настройки |
| Полный откат проекта | заказчик отзывает разрешение / переход на другой сценарий | `docker compose -p optomstroy-prod down` (без `-v` — данные остаются для переноса), экспорт дампа и `media` во внешнее хранилище, затем `down -v` по письменному подтверждению; удаление пользователя `optomstroy`, пакетов Docker (если ставили мы), правил firewall, DNS-записей — по списку установленного из журнала шага 1 | дамп и фото во внешнем хранилище |
| Перенос на VPS (сценарий C) | решение по 3.5 после пилота | восстановление дампа и `media` на VPS по 8.5; смена A-записи; настройка WireGuard/исходящего обмена (раздел 12) | всё |

Принцип: ни один шаг не изменяет чужие конфигурации, порты, DNS, firewall и базы без согласования (6.3); каждое изменение хоста фиксируется в журнале шага 1 для обратимости [ПОДТВЕРЖДЕНО: SRC-F-136].

---

## 15. Runbooks (кратко)

Формат: симптом → диагностика → действия → проверка → эскалация. Все команды — для сценария A. Выполняет админ заказчика (1-я линия) или DevOps.

### 15.1. 1С недоступна

| Шаг | Содержание |
|---|---|
| Симптом | алерт Healthchecks `/fail` от `worker`; уведомление `sync_error` после `SYNC_ALERT_UNREACHABLE_MIN` (не позже 15 мин, 05 SYNC-038); `/health/ready` → 503 `degraded`; в приложении `SyncIndicator` «данные старше N мин»; `sync_errors` с `ONEC_UNAVAILABLE` |
| Диагностика | `docker compose -p optomstroy-prod exec worker wget -qO- --timeout=5 $ONEC_BASE_URL/odata/standard.odata/` (ожидается XML/401); `ping`/`curl` хоста 1С с хоста; C-1: `sudo wg show` (последний handshake < 3 мин); проверить, работает ли веб-сервер 1С (у 1С-специалиста) |
| Действия | backend продолжает работу по снимку (D-32): заказы создаются с `202` и `warnings[STALE_DATA]` и ждут в `onec_outbox` (`pending`, повторы по графику ядра §22.1); продажа в долг — по ядру §22.4 (10 PAY-031): по свежему полному снимку без блокировок разрешена, при устаревшем снимке — `422 RECEIVABLES_STALE`; **ничего не перезапускать в 1С самостоятельно** — сообщить 1С-специалисту; при обрыве туннеля — перезапуск WireGuard на стороне магазина |
| Проверка | `POST /sync/runs` (manual) → `success` (в C-2 недоступен — `422`, `rule: inbound_mode`; ждать регламентного вызова 1С и `GET …/ping`); в `onec_outbox` нет `pending`/`sending` старше 30 мин, элементы переходят в `sent`, затем в `confirmed` (ядро §22.1); `/health/ready` → 200 |
| Эскалация | > 30 мин — 1С-специалист; > 2 ч — уведомить руководителя магазина (продажа в долг по устаревшим снимкам недоступна — `RECEIVABLES_STALE`) |

### 15.2. Синхронизация падает (1С доступна)

| Шаг | Содержание |
|---|---|
| Симптом | `sync_runs.status=failed/partial`, `sync_state.consecutive_errors ≥ 3`, алерт |
| Диагностика | `GET /sync/runs/{id}/errors` (код, сущность, запись); `docker compose logs --since 1h worker`; типовые причины: изменение состава OData/метаданных 1С, смена пароля `pos_integration`, 401/403, таймаут на больших выборках, нарушение уникальности `onec_ref`, диск заполнен |
| Действия | 401/403 — проверить учётные данные с 1С-специалистом, обновить `secrets/onec_*` (OData — `onec_user/onec_password`, HTTP-сервис — `onec_hs_*`) и `docker compose up -d api worker`; изменение метаданных — задача backend-разработчику (версия адаптера); таймаут — временно увеличить `ONEC_TIMEOUT_MS`, уменьшить размер страницы `ONEC_SYNC_PAGE_SIZE` и/или `ONEC_MAX_CONCURRENCY` (4.3); зацикливание на одной записи — сообщить 1С-специалисту для исправления данных в 1С (пометка ошибки синхронизации решённой/пропущенной и пауза сущности через API — **R2** [РЕШЕНИЕ: ядро §19.2, Q-219]); для записей `onec_outbox` — существующий `POST /sync/outbox/{id}/retry` (R0 §7; `failed`/`dead` → `pending` по ядру §22.1; `admin` и `senior_seller` — все элементы без step-up, фильтров «свой магазин» в R1 нет — ядро §22.10, R0 §19.4); если документ в 1С уже существует (`ORDER_MATCH_AMBIGUOUS`, ответ потерян) — не повтор, а ручная привязка `POST /orders/{id}/onec-link` (step-up, элемент `pending`/`failed`/`dead` → `sent` — ядро §23 п.1; 8.5 шаг 8); **вариант C-2** (`ONEC_INBOUND_ENABLED=true`): backend не обращается к 1С, ручной запуск недоступен (`POST /sync/runs` → `422`, `rule: inbound_mode`; кнопка SCR-43 неактивна — ядро §22.8) — 1С-специалист запускает регламентное задание/обработку расширения (полный срез — `POST …/snapshots/{entity}`, 05 §10.1) и проверяет вызовы `GET …/ping` (ONEC-064; 12.3) |
| Проверка | ручной прогон сущности → `success`; `consecutive_errors=0` |
| Эскалация | backend-разработчик при ошибках адаптера; 1С-специалист при изменении данных/прав |

### 15.3. Восстановление из бэкапа

| Шаг | Содержание |
|---|---|
| Когда | повреждение БД, ошибочная разрушающая миграция, потеря диска/сервера |
| Действия | процедура 8.5 (остановить потребителей → получить и расшифровать дамп → globals → `pg_restore -j 4` → `ANALYZE` → `media` → `migrate` → новая `server_epoch` → `api`/`worker` → smoke → ручная синхронизация → reconcile зеркала заказов (05 SYNC-063) и сверка `onec_outbox`) |
| На новом сервере | шаги 1–4 раздела 14 (хост, DNS на новый IP, TLS, секреты из защищённой копии заказчика), затем 8.5; цель RTO ≤ 1 рабочий день |
| Проверка | `count(*)` ключевых таблиц = контрольным; `/health/ready` 200; заказы за окно потери сверены с 1С вручную (существующие в 1С документы привязаны `POST /orders/{id}/onec-link` — ядро §23 п.1, 8.5 шаг 8; отчёт кассиру/руководителю) |
| Журнал | дата, дамп, фактический RTO, потерянные данные (RPO), кто выполнял |

### 15.4. Истёк или не выпускается сертификат

| Шаг | Содержание |
|---|---|
| Симптом | приложения показывают «ошибка сервера/сети» (SCR-90); `curl -vI https://api.<домен>` → ошибка сертификата; алерт `metrics_check` «срок < 20 дней» не был отработан |
| Диагностика | `docker compose logs caddy \| grep -i acme`; `dig +short api.<домен>` = IP сервера?; порты 80/443 доступны извне (`nmap` с внешнего хоста)?; лимиты LE (5 дубликатов/7 дней, 5 неудачных валидаций/час) [ПОДТВЕРЖДЕНО: letsencrypt.org/docs/rate-limits/]; время на сервере верное (`timedatectl`)? |
| Действия | исправить DNS/проброс портов/время; `docker compose restart caddy` — Caddy повторит выпуск; при упоре в лимит — ждать окна или временно использовать ZeroSSL (Caddy переключается автоматически); **не** удалять том `caddy_data` без необходимости |
| Проверка | `curl -vI https://api.<домен>` → срок > 60 дней; приложения работают |
| Эскалация | DevOps; владелец домена при проблемах DNS |

### 15.5. Переполнен диск

| Шаг | Содержание |
|---|---|
| Симптом | алерт `metrics_check` `Use% > 80 %`; PostgreSQL в логах `No space left on device`; `api` → 500/503 |
| Диагностика | `df -hT`; `du -sh /srv/optomstroy/prod/* /var/lib/docker/*`; `docker system df`; `ls -la /srv/optomstroy/prod/backups/db` (ротация работает?); размер логов контейнеров `du -sh /var/lib/docker/containers/*` |
| Действия (по порядку) | 1) `docker system prune -f` (неиспользуемые образы старых релизов — **не** `-a --volumes`); 2) удалить локальные дампы старше 30 дней, если ротация не сработала (внешняя копия есть!); 3) проверить ротацию логов (`daemon.json`), при отсутствии — применить и пересоздать контейнеры в окно; 4) при нехватке под фото — расширение диска/тома (раздел 13.1); 5) PostgreSQL после освобождения места — проверить `docker compose logs postgres`, при необходимости `docker compose restart postgres` |
| Проверка | `df -h` < 70 %; `/health/ready` 200; следующий бэкап успешен |
| Эскалация | DevOps; заказчик — решение о расширении диска |

### 15.6. Прочие короткие сценарии

| Ситуация | Действие |
|---|---|
| `api` не стартует после обновления | `docker compose logs api`; типично — не применена миграция (`migrate` упал) или отсутствует секрет; откат 10.4 |
| Утечка/компрометация секрета | при необходимости сначала сдерживание: `APP_READ_ONLY=true` в `.env` + `docker compose up -d api worker` (все мутации → `503 APP_READ_ONLY`, чтение работает, R0 §17.4) и/или отключение входящих интеграций (`ONEC_INBOUND_ENABLED=false`, `QR_WEBHOOK_ENABLED=false`, `SMSPRO_DLR_MODE=poll`); ротация: сгенерировать новый, заменить файл в `secrets/`, `docker compose up -d <сервис>`; для JWT-ключа — новый `JWT_KEY_ID`, скомпрометированный `kid` удаляется из `jwt_public.json` → все его токены отклоняются (D-12); для pepper OTP/PIN — новая версия (`OTP_HMAC_SECRET_VERSION`/`PIN_PEPPER_VERSION`); для токена 1С — выпуск нового и отзыв скомпрометированного через `bin/issue_integration_token` (R0 §18.2 п.4); для SMSPro/1С — сменить пароль у провайдера/в ИБ; запись в аудит/журнал инцидентов (11_SECURITY); снять `APP_READ_ONLY` после проверки |
| Подозрение на вторжение | изолировать (firewall deny all кроме админ-IP), снять образ логов, не удалять; сменить все секреты; уведомить заказчика; разбор по 11_SECURITY_PRIVACY |
| Сервер перезагружен | `restart: unless-stopped` поднимает контейнеры; проверить `docker compose ps`, `/health/ready`, первый `sync_run`, WireGuard (`wg show`) |
| Нужен доступ к БД администратору | `ssh -L 5050:127.0.0.1:5050 optomstroy@<хост>` + pgAdmin, или `docker compose exec postgres psql -U $POSTGRES_USER $POSTGRES_DB`; действия с данными — только по согласованию и с записью в аудит |

---
## 16. Таблица требований DEPLOY-NNN / OPS-NNN

Формат по R0 §10. Приоритет: must/should/could. Статус: ПОДТВЕРЖДЕНО / ТИПОВО / НЕ ПОДТВЕРЖДЕНО / РЕШЕНИЕ. Критерии приёмки `AC-DEPLOY-NNN` / `AC-OPS-NNN` детализирует 12_TEST_PLAN.

### 16.1. DEPLOY — размещение, топология, безопасность хоста

| ID | Требование | Приоритет | Статус | Источник | Критерий приёмки |
|---|---|---|---|---|---|
| DEPLOY-001 | До выбора инфраструктуры рассматривается размещение backend на существующем сервере заказчика; сценарий по умолчанию — A (Linux + Docker Compose), окончательный выбор — по дереву 3.5 после аудита | must | РЕШЕНИЕ | SRC-F-129, D-33 | AC-DEPLOY-001: в 14_OPEN_QUESTIONS зафиксирован ответ Q-030 и выбранный сценарий с обоснованием по 3.5 |
| DEPLOY-002 | Аудит сервера выполняется заказчиком по чек-листу раздела 2 (ОС, CPU, RAM, диски, сеть, службы, порты, домены, приложения); характеристики без аудита не предполагаются | must | ПОДТВЕРЖДЕНО | SRC-F-130, SRC-F-131 | AC-DEPLOY-002: заполнена форма 2.5 и приложен файл вывода команд; в ТЗ нет утверждений о сервере без метки [НЕ ПОДТВЕРЖДЕНО] до аудита |
| DEPLOY-003 | Чек-лист содержит для каждой проверки: цель, команду только для чтения, толкование простым языком, признак проблемы — для Linux и Windows Server | must | ПОДТВЕРЖДЕНО | SRC-F-132 | AC-DEPLOY-003: таблицы 2.2 и 2.3 содержат все четыре колонки для каждой строки; ни одна команда не изменяет состояние (кроме L-19 с согласием) |
| DEPLOY-004 | Возможность безопасного размещения backend, БД и задач синхронизации оценивается по критериям 3.4/3.5 и фиксируется в отчёте по аудиту | must | ПОДТВЕРЖДЕНО | SRC-F-133 | AC-DEPLOY-004: отчёт содержит оценку по каждому критерию таблицы 3.4 для выбранного сценария |
| DEPLOY-005 | В ТЗ зафиксирован итог: что размещается на сервере, какие ресурсы нужны, какие компоненты внешние, как организована связь с 1С | must | ПОДТВЕРЖДЕНО | SRC-F-144 | AC-DEPLOY-005: раздел 1 содержит четыре пункта итога, согласованные с D-33/D-34/D-28 |
| DEPLOY-006 | Схема развёртывания представлена для каждого сценария (A, B-3, C-1/C-2) в виде Mermaid-диаграммы с компонентами, сетями и направлениями соединений | must | ПОДТВЕРЖДЕНО | SRC-F-134 | AC-DEPLOY-006: диаграммы 3.1–3.3 рендерятся и содержат `pos-proxy`, `pos-api`, `pos-worker`, `pos-db`, 1С, SMSPro |
| DEPLOY-007 | Прод-окружение — compose-проект `optomstroy-prod` с сервисами `caddy`, `api`, `worker`, `migrate`, `postgres`, `backup` (опц. `pgadmin`) по спецификации 4.1–4.4; `api`/`worker`/`migrate` — один образ модульного монолита (роль — `WORKERS_ENABLED`, D-45); сервиса Redis нет (очереди, rate-limit, идемпотентность — в PostgreSQL, D-44) | must | РЕШЕНИЕ | D-33, D-44, D-45, R5 §7.2, R8 §2.1 | AC-DEPLOY-007: `docker compose -p optomstroy-prod ps` показывает ровно эти сервисы в состоянии `healthy`/`exited 0` (`migrate`) |
| DEPLOY-008 | Наружу публикуются только порты 80 и 443 сервиса `caddy`; `api`, `postgres`, `pgadmin` без `ports:` или только `127.0.0.1:` | must | РЕШЕНИЕ | SRC-F-137, SRC-F-138b, R8 §4.1 | AC-DEPLOY-008: `ss -tulpn` на хосте и `nmap` извне показывают только 22 (ограниченный), 80, 443 (C-1: + UDP WireGuard на VPS) |
| DEPLOY-009 | PostgreSQL не доступна из интернета: `postgres` только в сети `backend` (`internal: true`), без `ports:`; в нативном варианте — `listen_addresses='localhost'` | must | ПОДТВЕРЖДЕНО | SRC-F-137, R8 §5 | AC-DEPLOY-009: `nmap -p 5432,5433 <публичный IP>` → closed/filtered; `docker inspect postgres` — только сеть `backend` |
| DEPLOY-010 | Весь внешний трафик к backend — только HTTPS (TLS 1.2+/1.3, HSTS); HTTP → редирект; сертификаты выпускаются и продлеваются автоматически (Caddy/ACME) | must | ПОДТВЕРЖДЕНО | SRC-F-138, NFR-SEC-001, R8 §2.1 | AC-DEPLOY-010: `curl -I http://api.<домен>` → 301/308; `curl -vI https://…` — валидный сертификат, заголовок HSTS; срок > 20 дней после выпуска |
| DEPLOY-011 | Том `caddy_data` persistent и не пересоздаётся при деплое; на время отладки используется staging CA | must | ПОДТВЕРЖДЕНО | R8 §2.1, letsencrypt.org rate-limits | AC-DEPLOY-011: после `docker compose up -d --force-recreate caddy` сертификат не перевыпускается (один и тот же серийный номер) |
| DEPLOY-012 | Сети compose: `edge` (выход наружу) и `backend` (`internal: true`); `api`, `worker`, `backup` — в обеих; `postgres`, `migrate` — только `backend` | must | ПОДТВЕРЖДЕНО | R8 §2.1, §4.1 | AC-DEPLOY-012: `docker network inspect` подтверждает членство; из `postgres` исходящее соединение в интернет невозможно |
| DEPLOY-013 | Секреты (пароль БД и роли миграций, строка подключения, ключи JWT, pepper OTP и PIN, учётные данные SMSPro и 1С (OData, HTTP-сервис и — только в режиме ONEC-028 — `pos_odata_write`), секреты подписи входящих интеграций (QR-вебхук; токены роли `integration` хранятся только хэшем в `integration_tokens` и в `secrets/` не попадают — R0 §18.2 п.4), rclone, Healthchecks) хранятся только в `secrets/*` с правами 600 и подключаются через Compose `secrets:`; `.env` без секретов; в git — только `.env.example` | must | ПОДТВЕРЖДЕНО | SRC-F-138, SRC-F-138a, R8 §5, R5 §7.4 | AC-DEPLOY-013: `ls -la secrets/` → `-rw-------`; `git ls-files` не содержит `secrets/` и `.env`; `docker inspect api` не показывает значений секретов в `Env` |
| DEPLOY-014 | Перечень переменных окружения и секретов (4.3) полон и включает все имена ядра (R0 §16 п.3 и §17.7) с назначением, признаком секрета и несекретным значением по умолчанию: любая новая переменная добавляется в `.env.example` и в таблицу 4.3 с указанием, секрет ли она | must | РЕШЕНИЕ | R5 §7.4, R2 §11, R0 §16.3, R0 §17.7 | AC-DEPLOY-014: автотест конфигурации (`config.validate` при старте `api`) отказывает при отсутствии обязательной переменной и при `APP_ENV=prod` + любом тестовом флаге |
| DEPLOY-015 | Контейнеры `api`/`worker`/`migrate` запускаются от non-root, с `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`; `privileged` запрещён; Docker socket не монтируется | must | ТИПОВО | R8 §5 | AC-DEPLOY-015: `docker inspect` каждого контейнера: `User≠0`, `ReadonlyRootfs=true`, `CapDrop=[ALL]`, `Privileged=false` |
| DEPLOY-016 | На каждый контейнер заданы `deploy.resources.limits` (memory, cpus) и `restart: unless-stopped` | must | РЕШЕНИЕ | R8 §4.1 | AC-DEPLOY-016: `docker inspect` показывает `Memory>0`, `NanoCpus>0`, `RestartPolicy=unless-stopped` |
| DEPLOY-017 | Отдельный пользователь ОС `optomstroy` без пароля, вход только по SSH-ключу; права на Docker — по одному из вариантов 6.1 (rootless / sudo с ограниченным sudoers / группа `docker` с обоснованием) | must | ПОДТВЕРЖДЕНО | SRC-F-138b, R8 §4.1, docs.docker.com linux-postinstall | AC-DEPLOY-017: `id optomstroy`; `sudo -l -U optomstroy`; решение Q-102 записано в 15_DECISION_LOG |
| DEPLOY-018 | SSH: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers`, ключи ed25519; доступ к 22 ограничен по IP/VPN; fail2ban jail `sshd` | must | ТИПОВО | SRC-F-138b, R8 §5 | AC-DEPLOY-018: `ssh -o PreferredAuthentications=password` → отказ; `fail2ban-client status sshd` → jail активен |
| DEPLOY-019 | Автообновления безопасности ОС включены (`unattended-upgrades`); автоматическая перезагрузка — только в согласованное окно | must | ПОДТВЕРЖДЕНО | R8 §5, ubuntu.com automatic-updates | AC-DEPLOY-019: `20auto-upgrades` содержит `Unattended-Upgrade "1"`; `Automatic-Reboot-Time` = окно Q-032 |
| DEPLOY-020 | Firewall хоста: входящие только 22 (ограничен), 80, 443 (+ UDP WireGuard на VPS в C-1); проверка фактических портов (`ss`, `iptables -S DOCKER-USER`), а не только `ufw status` | must | ПОДТВЕРЖДЕНО | SRC-F-138b, R8 §5, docs.docker.com packet-filtering | AC-DEPLOY-020: отчёт `nmap` с внешнего хоста по всем портам: открыты только ожидаемые |
| DEPLOY-021 | NTP включён, часовой пояс `Asia/Bishkek`; `TZ` передаётся в контейнеры cron/логов | must | ТИПОВО | R8 §5, R5 §7.5 | AC-DEPLOY-021: `timedatectl` → `synchronized: yes`; смещение < 1 с |
| DEPLOY-022 | Все образы — фиксированные теги версий (`optomstroy/api:<semver>`, `postgres:17.x`, `caddy:2.x.y`); `latest` в проде запрещён | must | РЕШЕНИЕ | R8 §8.1 | AC-DEPLOY-022: `docker compose config` не содержит тега `latest` или образов без тега |
| DEPLOY-023 | Приложение изолировано от существующих служб: отдельные пользователь, каталоги `/opt/optomstroy`, `/srv/optomstroy`, сети, имена проектов; чужие конфиги не редактируются | must | ПОДТВЕРЖДЕНО | SRC-F-135, R8 §4.1 | AC-DEPLOY-023: `git diff`/контрольные суммы чужих конфигов (`/etc/nginx`, `/etc/apache2`, `pg_hba.conf`, firewall, cron) до и после деплоя идентичны |
| DEPLOY-024 | Существующие конфигурации, порты, DNS, firewall и базы данных не изменяются без предварительного письменного согласования по перечню 6.3 | must | ПОДТВЕРЖДЕНО | SRC-F-136 | AC-DEPLOY-024: по каждому из 12 пунктов 6.3 есть запись «согласовано/отклонено, дата, кем» до шага 1 раздела 14 |
| DEPLOY-025 | Существующий экземпляр PostgreSQL заказчика (например, под 1С) не используется; backend работает со своим экземпляром | must | РЕШЕНИЕ | R8 §4.2 | AC-DEPLOY-025: секрет `DATABASE_URL_FILE` указывает на контейнер `postgres` проекта; чужой экземпляр не имеет роли/базы проекта |
| DEPLOY-026 | Ничего не устанавливается и не запускается на сервере до утверждения ТЗ и отдельного письменного разрешения заказчика; на первом этапе готовятся **только** план развёртывания и требования (этот документ) | must | ПОДТВЕРЖДЕНО | SRC-F-139, SRC-F-139a, SRC-F-145 | AC-DEPLOY-026: журнал шага 0 (14.1) содержит ссылку на сообщение об утверждении ТЗ и на разрешение; до этого на сервере нет следов проекта; результат этапа 1 — только документы (шапка, §1 п.9) |
| DEPLOY-027 | Минимальные ресурсы прод: 2 vCPU / 4 GB / 80 GB SSD; рекомендованные: 4 vCPU / 8 GB / 160–250 GB SSD; внешнее хранилище бэкапов ≥ 2 × (БД + фото) | must | РЕШЕНИЕ | SRC-F-134a, D-34 | AC-DEPLOY-027: по аудиту ресурсы ≥ минимума; при меньших — выполнен раздел 13 |
| DEPLOY-028 | Диск планируется с заполнением ≤ 70 % к концу 3-го года с учётом роста БД (+1–2 GB/год) и фото (+10–30 %/год); объём фото уточняется по Q-022 | should | НЕ ПОДТВЕРЖДЕНО | R8 §3.3, Q-022 | AC-DEPLOY-028: расчёт 5.4 пересчитан по фактическим данным Q-022/Q-023 и приложен к отчёту аудита |
| DEPLOY-029 | При недостаточной мощности или небезопасной конфигурации сервера заказчику предлагаются минимальные улучшения (13.1) и сравнение стоимости с VPS (13.2–13.3) по подтверждённым тарифам | must | ПОДТВЕРЖДЕНО | SRC-F-140, Q-039 | AC-DEPLOY-029: отчёт содержит таблицу 13.3, заполненную по результатам аудита и КП местных провайдеров |
| DEPLOY-030 | Тестовое и рабочее окружения разделены: отдельные compose-проекты, БД, тома, секреты, поддомены; тест никогда не подключается к рабочей 1С | must | ПОДТВЕРЖДЕНО | SRC-F-141, R8 §8.4 | AC-DEPLOY-030: `docker compose -p optomstroy-test config` не содержит прод-путей/секретов; `ONEC_BASE_URL` теста ≠ прод |
| DEPLOY-031 | При нехватке ресурсов на сервере тестовый контур размещается на другом хосте без снижения требований к проду | should | РЕШЕНИЕ | SRC-F-141, R5 §7.6 | AC-DEPLOY-031: решение по размещению теста зафиксировано в 14_OPEN_QUESTIONS |
| DEPLOY-032 | Clean Architecture и модульная структура backend/приложения не зависят от сценария размещения: различия только в compose, сети и секретах | must | ПОДТВЕРЖДЕНО | SRC-F-143, D-05, D-06 | AC-DEPLOY-032: один и тот же образ `optomstroy/api:<версия>` используется в A/B-3/C без пересборки; архитектурные тесты (06_ARCHITECTURE) проходят |
| DEPLOY-033 | Backend обращается к 1С только через опубликованные HTTP-сервисы расширения и OData по HTTPS; прямой доступ к СУБД 1С запрещён | must | РЕШЕНИЕ | D-28, R1 §7 | AC-DEPLOY-033: в конфигурации нет строк подключения к СУБД 1С; `ONEC_BASE_URL` — HTTPS-URL публикации |
| DEPLOY-034 | Вариант сетевой связи с 1С (LAN / WireGuard, инициируемый магазином / исходящий обмен от 1С) выбирается по 12.4 и фиксируется ответом на Q-031 | must | РЕШЕНИЕ | D-33, Q-031 | AC-DEPLOY-034: в 14_OPEN_QUESTIONS зафиксирован выбранный вариант; `ONEC_MODE`/`ONEC_BASE_URL` соответствуют |
| DEPLOY-035 | В варианте WireGuard туннель инициирует сторона магазина (исходящий UDP); входящие порты в магазине не открываются; на VPS входящий UDP разрешён только для WireGuard | must | ПОДТВЕРЖДЕНО | R8 §2.3, wireguard.com | AC-DEPLOY-035: `wg show` на VPS показывает handshake от магазина; на роутере магазина нет правил проброса |
| DEPLOY-036 | В варианте «исходящий обмен» backend аутентифицирует 1С отдельным техническим токеном роли `integration` (`integration_tokens`, выпуск/отзыв — `bin/issue_integration_token`, срок 180 дней, R0 §18.2 п.4; mTLS в R1 не используется — 05 ONEC-060) с отдельным rate-limit; префикс `/api/v1/integrations/onec/*` включается только `ONEC_INBOUND_ENABLED=true`, что допустимо только при `ONEC_MODE=extension` (05 ONEC-065; иное сочетание — отказ в старте); IP источника проверяется в `api` по обязательному allow-list `ONEC_INBOUND_ALLOWED_IPS` (05 ONEC-060; пустой список при включённом флаге — отказ в старте); ручной запуск синхронизации в этом режиме недоступен — `POST /sync/runs` → `422` (`rule: inbound_mode`), обмен инициирует 1С (ядро §22.8) | must | РЕШЕНИЕ | D-15, R8 §2.3, R0 §16.5, R0 §17.3, R0 §17.7, ядро §22.8, 05 ONEC-060 | AC-DEPLOY-036: запрос без токена → 401; старт `api` с `ONEC_MODE=odata_only` (или `fixtures`) и `ONEC_INBOUND_ENABLED=true` → отказ с ошибкой конфигурации; старт с `ONEC_INBOUND_ENABLED=true` и пустым `ONEC_INBOUND_ALLOWED_IPS` → отказ с ошибкой конфигурации; запрос с действующим токеном с IP вне списка → 403 от `api` при отключённом фильтре proxy; превышение лимита → 429; при `ONEC_INBOUND_ENABLED=true` `POST /sync/runs` (любая сущность и роль) → `422 VALIDATION_FAILED` (`inbound_mode`); при `ONEC_INBOUND_ENABLED=false` любой путь префикса → 404 |
| DEPLOY-037 | Публикация 1С: веб-клиент не публикуется в интернет; OData/HTTP-сервисы — только по HTTPS, только из адреса backend/туннеля; отдельный пользователь ИБ с минимальными правами | must | ТИПОВО | R1 §7, R8 §5 | AC-DEPLOY-037: с постороннего адреса `GET <ONEC_BASE_URL>/odata/...` недоступен; пользователь `pos_integration` не имеет роли администратора |
| DEPLOY-038 | Health-эндпоинты `GET /health` (liveness: только `status`, `minAppVersion`) и `GET /health/ready` (readiness: БД, миграции, очередь, свежесть синхронизации; поля только `status`, `db`, `queue`, `syncAgeOk`, `lastSuccessfulSyncAt`) доступны без авторизации, не раскрывают версий ПО, имён хостов, состояния интеграций и строк ошибок (11 SEC-019), `/health/ready` → 503 при неготовности | must | РЕШЕНИЕ | D-37, R5 §5.2, R8 §7 | AC-DEPLOY-038: при остановленном `postgres` `/health/ready` → 503 с `db=false`; `/health` → 200; тела обоих ответов не содержат полей вне перечня SEC-019 (T-SEC-028) |
| DEPLOY-039 | Compose healthchecks для `api` и `postgres`; `api` стартует после `postgres` (`service_healthy`) и `migrate` (`service_completed_successfully`) | must | ПОДТВЕРЖДЕНО | R5 §7.2, docs.docker.com healthcheck | AC-DEPLOY-039: при падении `migrate` контейнер `api` не создаётся; `docker compose ps` показывает `healthy` |
| DEPLOY-040 | Ротация логов Docker настроена в `daemon.json` и в compose (`max-size=20m`, `max-file=5`); access-log Caddy с ротацией | must | ПОДТВЕРЖДЕНО | R8 §7, docs.docker.com json-file | AC-DEPLOY-040: `docker inspect api` → `LogConfig.Config.max-size=20m`; размер логов контейнера не превышает 100 MB |
| DEPLOY-041 | Фото хранятся в томе `media` по контент-адресуемым путям и отдаются Caddy с `Cache-Control: immutable`; том монтируется в `caddy` только для чтения | must | РЕШЕНИЕ | D-30 | AC-DEPLOY-041: `curl -I https://api.<домен>/images/<sha>/thumb` → 200, `Cache-Control: public, max-age=31536000, immutable`, `Content-Type: image/webp` |
| DEPLOY-042 | План первичного развёртывания (14.1) выполняется по шагам с проверкой и откатом каждого шага; результат — акт передачи и инструкция по установке, настройке и развёртыванию | must | ПОДТВЕРЖДЕНО | SRC-D-171, R8 §10 | AC-DEPLOY-042: инструкция содержит разделы установки хоста, конфигурации, секретов (без значений), запуска, обновления, отката, восстановления; админ заказчика выполняет по ней обновление теста самостоятельно |
| DEPLOY-043 | Первичный импорт из 1С завершается сверкой количеств по каждой сущности (`$count` в 1С = `count(*)` в backend); расхождения объясняются до деплоя прод | must | РЕШЕНИЕ | R8 §10 шаг 7, D-29 | AC-DEPLOY-043: отчёт сверки по всем `sync_entity` с нулевым необъяснённым расхождением |
| DEPLOY-044 | CI собирает образ backend и целевые платформы приложения (Android, Windows; iOS при наличии macOS-раннера) на каждый релиз; OpenAPI версии релиза сохраняется как артефакт | must | ПОДТВЕРЖДЕНО | SRC-D-141, D-03, D-39 | AC-DEPLOY-044: пайплайн релиза публикует образ `optomstroy/api:<semver>`, APK и Windows-сборку — zip-архив (`.exe` + DLL + `data/` + VC++ runtime) с файлом `SHA256SUMS` для установки администратором по 10.7 [РЕШЕНИЕ: ядро §20.2 п.13; MSIX — R2, 13 RM-H-007] — и `openapi.json` с одним номером версии |
| DEPLOY-045 | Сценарий B-1 (Docker Desktop на Windows Server) не используется для прода; при Windows-сервере предпочтителен B-3; B-4 отвергнут | must | ПОДТВЕРЖДЕНО | R8 §2.2, docs.docker.com windows-install | AC-DEPLOY-045: если по аудиту ОС — Windows Server, в отчёте выбор между B-2/B-3/C с обоснованием; Docker Desktop в проде отсутствует |
| DEPLOY-046 | Для сценария B-3 включение роли Hyper-V и создание VM выполняется только после согласования и в окно обслуживания; VM получает ≥ 2 vCPU / 4 GB / 80 GB | must | ТИПОВО | R8 §2.2, Q-101 | AC-DEPLOY-046: протокол окна обслуживания; `Get-VM` показывает VM с заданными ресурсами; 1С после перезагрузки работает |
| DEPLOY-047 | Административные панели доступны только локально: `pgadmin` на сервере backend — `127.0.0.1:5050` + SSH-туннель; панель Uptime Kuma — **на хосте монитора** (не на сервере backend, Q-103) только `127.0.0.1:3001` за HTTPS-RP с авторизацией или VPN; на сервере backend порт 3001 не открывается; пароли по умолчанию сменены | must | ТИПОВО | SRC-F-138b, R8 §5, §7 | AC-DEPLOY-047: `nmap` извне: сервер backend — 5050 закрыт и 3001 отсутствует; хост монитора — 3001 закрыт; вход в панели с паролем по умолчанию невозможен |
| DEPLOY-048 | Локализация данных (реализация 11 PRIV-001, PRIV-019): прод-БД, бэкапы, монитор доступности, Healthchecks и канал алертов по умолчанию размещаются в КР; размещение за рубежом (VPS, хранилище, SaaS-монитор, мессенджер для алертов) — только после ADR в 15_DECISION_LOG по 6 пунктам 11 PRIV-020 и решения заказчика; содержимое алертов и пингов — без ПДн (раздел 9); исходящий трафик сервера — только к разрешённым хостам (H-5) | must | РЕШЕНИЕ: D-01, D-33 (через 11 PRIV-001); ст. 89 ЦК — ТИПОВО (R6 §4.2) | R6 §8, Q-027, Q-033, Q-103, 11 PRIV-001/PRIV-019/PRIV-020 | AC-DEPLOY-048: в 14_OPEN_QUESTIONS есть решение по локации с ссылкой на заключение или явное принятие риска заказчиком; для каждого внешнего сервиса вне КР есть ADR (AC-PRIV-020); перехват исходящего трафика сервера показывает только хосты из allow-list H-5 (T-SEC-047); выборка шаблонов алертов не содержит телефонов, IP, ФИО, сумм |
| DEPLOY-049 | Все проверки аутентификации и прав выполняются в `api` на **каждом** запросе (deny by default — 11_SECURITY_PRIVACY SEC-028, SEC-029; контракт — 08_API); reverse-proxy (`caddy`/Nginx) авторизацию не выполняет и не содержит правил доступа по путям API (исключение — необязательный сетевой фильтр `remote_ip` для входящих интеграций по DEPLOY-050, не являющийся авторизацией); маршруты без Bearer пользователя на границе — `/health*`, статика `/images/*` (без Bearer в R1 по 08_API, контент-адресуемые пути D-30) и входящие интеграции 4.6 (аутентификация — в `api`) | must | ПОДТВЕРЖДЕНО | SRC-F-138c, SEC-028, SEC-029, D-37, R0 §17.4 | AC-DEPLOY-049: `Caddyfile` не содержит директив `basic_auth`/`forward_auth`/allow-list по путям `/api/*` (кроме необязательного фильтра `remote_ip` маршрутов 4.6 по DEPLOY-050); запрос через proxy к любому защищённому endpoint без токена → 401, с токеном роли без permission → 403 (тест «403 для чужой роли», 12_TEST_PLAN); `GET /health` без токена → 200 |
| DEPLOY-050 | Входящие интеграционные маршруты (`/api/v1/integrations/onec/*`, `/api/v1/integrations/smspro/dlr`, `/api/v1/payments/qr/webhook`) обслуживаются по правилам 4.6: по умолчанию выключены (`ONEC_INBOUND_ENABLED=false`, `SMSPRO_DLR_MODE=poll`, `QR_WEBHOOK_ENABLED=false` → `404`); аутентификация (технический токен роли `integration` / подпись банка) и IP-allowlist (`ONEC_INBOUND_ALLOWED_IPS`, `SMSPRO_DLR_ALLOWED_IPS`, `QR_WEBHOOK_ALLOWED_IPS` — для каждой группы обязателен при её включении) проверяются в `api` по реальному IP клиента из `X-Forwarded-For`, выставленного только `caddy`; фильтр `remote_ip` в Caddy допустим лишь как дублирующий сетевой слой; секреты интеграций монтируются только в `api` | must | РЕШЕНИЕ | R0 §16.5, R0 §17.4, R0 §17.7, D-37, SEC-025/SEC-026 (11_SECURITY_PRIVACY), 05 ONEC-060 | AC-DEPLOY-050: при конфигурации по умолчанию все три группы маршрутов → 404; при включении: неразрешённый IP → 403 (в т. ч. с подложным заголовком `X-Forwarded-For` от клиента), без токена/подписи → 401, токен `integration` на `/api/v1/orders` → 403; `docker inspect worker` не содержит секретов `qr_webhook_*`; токены 1С отсутствуют в `secrets/` и `.env` (R0 §18.2 п.4) |

### 16.2. OPS — эксплуатация: бэкапы, мониторинг, обновления, инциденты

| ID | Требование | Приоритет | Статус | Источник | Критерий приёмки |
|---|---|---|---|---|---|
| OPS-001 | Ежедневный `pg_dump -Fc` прод-БД в 03:00 Asia/Bishkek (время согласовать); еженедельно `pg_dumpall --globals-only`; локальное хранение 30 суточных + 3 месячных зашифрованных дампов (`.age`), globals — 90 дней; нешифрованный дамп существует только до завершения шифрования и удаляется тем же скриптом, в т. ч. при сбое (11 SEC-110); все файлы бэкапов создаются с `umask 077` | must | РЕШЕНИЕ | SRC-D-087, SRC-F-134b, SRC-F-142a, D-35 | AC-OPS-001: через 31 день в `backups/db` — 30 суточных дампов `.age`; `pg_restore --list` каждого после `age -d` проходит; `find /srv/optomstroy -name '*.dump' -mmin +60` пусто (AC-SEC-110) |
| OPS-002 | Ежедневная инкрементальная копия тома `media` и суточная копия `caddy_data` (через `docker compose cp` или bind-mount, без прямого доступа к `/var/lib/docker`) во внешнее хранилище только `rclone copy --immutable` (без `sync`/`--backup-dir`; учётная запись выгрузки без права удаления и перезаписи — 11 SEC-111); `caddy_data` — в каталог с датой; удалённые на сервере файлы хранятся до истечения политики жизненного цикла хранилища | must | РЕШЕНИЕ | SRC-F-142a, D-35, R8 §6.2, SEC-111 | AC-OPS-002: `rclone check --one-way` между `media` и remote без расхождений после ночного запуска; скрипты бэкапа не содержат `rclone sync`/`move`/`delete`; `rclone delete` под учётной записью сервера → отказ (AC-SEC-111) |
| OPS-003 | Копия бэкапов вне сервера обязательна (S3-совместимое хранилище / второй хост / NAS); хранилище и плательщик определяются заказчиком | must | РЕШЕНИЕ | SRC-F-142a, D-35, Q-033, SRC-E-179h | AC-OPS-003: `rclone lsl offsite:optomstroy/prod/db` показывает дамп сегодняшней даты; хранилище физически вне сервера |
| OPS-004 | Дампы шифруются до выгрузки (`age`, публичный ключ заказчика); приватный ключ не хранится на сервере; копия ключа — у заказчика офлайн и в защищённом хранилище DevOps | must | ТИПОВО | SRC-F-138a, R6 §8, Q-106 | AC-OPS-004: файлы в remote имеют расширение `.age` и не читаются `pg_restore --list` без ключа; на сервере `find / -name '*age*key*'` пусто |
| OPS-005 | Конфигурация (compose, Caddyfile, скрипты, `.env.example`) хранится в git без секретов; секреты — в зашифрованной копии у заказчика; ведётся реестр секретов (где лежат, без значений) | must | РЕШЕНИЕ | SRC-F-138a, R8 §6.2 | AC-OPS-005: `git log` содержит актуальные конфиги; реестр секретов приложен к акту передачи |
| OPS-006 | Целевые показатели R1: RPO ≤ 24 ч, RTO ≤ 4 ч на том же сервере, ≤ 1 рабочий день на новом; PITR с RPO ≤ 15 мин — R2 или по решению заказчика | must | РЕШЕНИЕ | D-35, Q-033, R6 §8 | AC-OPS-006: результаты restore-drill показывают фактический RTO ≤ 4 ч; значения RPO/RTO утверждены в 14_OPEN_QUESTIONS |
| OPS-007 | Ежемесячно выполняется проверка восстановления в тестовом контуре (restore-drill: шаги автоматизированы `restore_drill.sh`, запуск — держатель ключа `age`, т. к. ключа на сервере нет, SEC-110) с `count(*)` по ключевым таблицам и smoke-тестом; ежеквартально — ручное учение с замером RTO; результаты — в журнал | must | РЕШЕНИЕ | D-35, R6 §8, SRC-E-179i | AC-OPS-007: журнал содержит ≥ 1 запись в месяц с результатом «успех» и временем восстановления |
| OPS-008 | Процедура восстановления (8.5) и runbook 15.3 документированы и переданы админу заказчика; включают порядок БД → секреты → новая эпоха данных `server_epoch` (05 F16/SYNC-063) → приложение → синхронизация с 1С → reconcile зеркала заказов и сверка outbox | must | ПОДТВЕРЖДЕНО | SRC-D-087, SRC-D-087a, SRC-F-134e, R6 §8, 05 SYNC-063 | AC-OPS-008: админ заказчика выполняет восстановление в тестовом контуре по документу без участия DevOps; после восстановления `server_epoch` отличается от значения до restore, клиент с `checkout_draft` заказа после точки бэкапа не отправляет `POST /orders` автоматически (AC-SYNC-063) |
| OPS-009 | Бэкап выполняется перед каждой миграцией БД и перед обновлением Docker/PostgreSQL; наличие внешней копии проверяется до продолжения | must | РЕШЕНИЕ | R8 §8.1, SRC-F-142, SRC-F-142a | AC-OPS-009: журнал релизов содержит ссылку на дамп, сделанный перед каждым релизом |
| OPS-010 | Задания cron (бэкап, drill, метрики) отчитываются в Healthchecks (`/start`, ping, `/fail`); отсутствие успешного бэкапа > 24 ч + grace → алерт | must | ПОДТВЕРЖДЕНО | R8 §7, healthchecks.io | AC-OPS-010: искусственный сбой скрипта (`exit 1`) → алерт в канале в течение grace-периода |
| OPS-011 | Внешний монитор (Uptime Kuma на другом хосте или SaaS) опрашивает `GET /health/ready` каждые 60 с; алерт при 503/таймауте ≥ 2 проверок подряд | must | ПОДТВЕРЖДЕНО | SRC-F-134d, R8 §7, github.com/louislam/uptime-kuma | AC-OPS-011: остановка `api` → алерт ≤ 3 мин; монитор расположен не на сервере backend |
| OPS-012 | Алерт о неудачной синхронизации с 1С на трёх уровнях: ping/fail от `worker` после каждого прогона; `/health/ready` → 503 при простое синхронизации дольше порога (2–3 интервала сущности); индикатор и уведомление `sync_error` в приложении | must | РЕШЕНИЕ | D-41, R5 §6, R8 §7 | AC-OPS-012: блокировка доступа к 1С (firewall) → алерт в канал ≤ 15 мин для остатков; `SyncIndicator` показывает возраст данных |
| OPS-013 | Алерты по outbox: записи `onec_outbox` в `failed`/`dead` > 0 дольше 15 мин или `pending` старше 30 мин → алерт | must | РЕШЕНИЕ | D-28, R5 §6 | AC-OPS-013: искусственно «мёртвая» запись → алерт; после `POST /sync/outbox/{id}/retry` алерт снимается |
| OPS-014 | Минимальные метрики каждые 10 мин: диск > 80 %, RAM < 10 % свободно, load > CPU, размер БД, ошибки синхронизации за сутки, время ответа `/health/ready` > 2 с, срок сертификата < 20 дней → алерт через Healthchecks `/fail` | must | РЕШЕНИЕ | R8 §7, R5 §7.5 | AC-OPS-014: заполнение диска до 85 % в тесте → алерт ≤ 10 мин |
| OPS-015 | Канал алертов — по умолчанию e-mail через почтовый сервер в КР (Telegram-группа или иной зарубежный сервис — только после ADR по 11 PRIV-020); содержимое алертов — без ПДн (раздел 9, «Содержимое алертов»); эскалация: админ заказчика → DevOps → backend-разработчик/1С-специалист; контакты в акте передачи | must | РЕШЕНИЕ | Q-032, R8 §4.3 | AC-OPS-015: тестовый алерт доставлен всем участникам канала; схема эскалации подписана |
| OPS-016 | Логи `api`/`worker` — структурированный JSON без OTP, паролей, токенов, ПДн; сквозной `requestId`; `postgres` логирует запросы ≥ 500 мс; `pg_stat_statements` включён | must | РЕШЕНИЕ | NFR-LOG-001, D-37, R8 §5 | AC-OPS-016: тест 12_TEST_PLAN: grep логов по паттернам OTP/JWT/паролей → 0 совпадений; `SELECT * FROM pg_stat_statements LIMIT 1` работает |
| OPS-017 | Централизация логов (Loki) и Prometheus/Grafana — не в R1; в R1 достаточно `docker compose logs` + ротация | could | НЕ ПОДТВЕРЖДЕНО | R8 §7 | AC-OPS-017: в 13_ROADMAP запись о R2 |
| OPS-018 | Каждый релиз backend — образ с неизменяемым тегом semver (+ git sha); `API_TAG` в `.env` — единственный источник версии; ведётся журнал релизов | must | РЕШЕНИЕ | SRC-F-134c, R8 §8.1 | AC-OPS-018: `docker compose -p optomstroy-prod images api` и стартовая запись структурированного лога `api` показывают тег = `API_TAG` (`GET /health` версию не раскрывает — 11 SEC-019); журнал содержит запись на каждый релиз |
| OPS-019 | Миграции БД — forward-only SQL (Drizzle), по схеме expand → migrate → contract; `contract` не ранее чем через один релиз; индексы на больших таблицах — `CONCURRENTLY` | must | РЕШЕНИЕ | SRC-F-142, D-03, R8 §8.1 | AC-OPS-019: code-review чек-лист миграций; тест: предыдущая версия `api` работает на схеме после expand-миграции |
| OPS-020 | Миграции применяются отдельным контейнером `migrate` до старта `api`; ошибка миграции не останавливает работающую старую версию | must | РЕШЕНИЕ | R5 §7.2, R8 §8.2 | AC-OPS-020: намеренно сломанная миграция в тесте → `migrate` exit≠0, старый `api` продолжает отвечать 200 |
| OPS-021 | Процедура обновления прод (10.3): тест на копии данных → окно → пауза синхронизации → бэкап → pull → migrate → up → smoke → снятие паузы → журнал | must | РЕШЕНИЕ | SRC-F-134c, R8 §8.2 | AC-OPS-021: протокол релиза содержит все 9 шагов с отметками; простой API ≤ 3 мин |
| OPS-022 | Откат обновления (10.4): смена `API_TAG` на предыдущий + `up -d`; БД совместима благодаря expand/contract; при разрушающей миграции — восстановление из дампа шага 3 | must | РЕШЕНИЕ | SRC-F-142, SRC-F-142b, R8 §8.3 | AC-OPS-022: учение отката в тестовом контуре: ≤ 10 мин, данные expand-колонок сохранены |
| OPS-023 | Smoke-тест после каждого деплоя обязателен: в тестовом контуре — 10.5, в проде — только prod-smoke без мутаций данных 10.9 (ядро §20.2 п.6); непройденный smoke → откат | must | РЕШЕНИЕ | R8 §8.5, ядро §20.2 п.6 | AC-OPS-023: чек-лист smoke с отметками приложен к записи релиза; для прода — протокол 10.9 со счётчиками бизнес-таблиц до/после (совпадают) и без запросов вне перечня 10.9 (12 T-OPS-024) |
| OPS-024 | Совместимость приложения и API: backend публикует `X-Min-App-Version` и `X-Recommended-App-Version` в каждом ответе (R0 §18.2 п.12); приложение ниже минимальной версии получает `426` с `code=APP_UPDATE_REQUIRED` и показывает экран «Требуется обновление»; поддерживаются версии N и N−1; минимальная версия по платформе меняется `admin` только по регламенту 10.8 (не выше N−1 в течение 30 дней с выпуска N) [РЕШЕНИЕ: ядро §20.2 п.14] | must | РЕШЕНИЕ | D-37, SCR-90, R8 §8, ядро §20.2 п.14, ADR-059, ADR-062 | AC-OPS-024: запрос с `X-App-Version` ниже минимальной → 426; приложение показывает SCR-90 и блокирует финансовые операции; каждое изменение `min_app_version` имеет событие аудита и протокол предпроверки 10.8 шаг 4, дата изменения соответствует ограничению 1 раздела 10.8 |
| OPS-025 | Окно обслуживания согласовано с заказчиком; перезагрузки сервера и обновления Docker/PostgreSQL — только в окно; уведомление пользователей в приложении (`system`-уведомление) за ≥ 1 час | must | РЕШЕНИЕ | Q-032, R8 §4.3 | AC-OPS-025: журнал обслуживания: все перезагрузки в окне; уведомление `notification_kind=system` отправлено |
| OPS-026 | Обновления Docker Engine/Compose — ежеквартально; минорные обновления PostgreSQL — сменой тега в окно; мажорное (17→18) — отдельный план в R2 | should | ТИПОВО | R8 §3.4, Q-104 | AC-OPS-026: журнал обслуживания содержит квартальные записи |
| OPS-027 | Тестовый контур использует `APP_ENV=staging`, `SMS_PROVIDER=fake` (или `SMSPRO_TEST_FLAG=true`), `AUTH_OTP_TEST_MODE=true`, тестовую копию 1С или фикстуры; прод отказывает в старте при любом тестовом флаге: `AUTH_OTP_TEST_MODE=true`, непустые `AUTH_OTP_TEST_PHONES`/`AUTH_OTP_TEST_CODE`, `SMS_PROVIDER=fake`, `SMSPRO_TEST_FLAG=true`, `ONEC_MODE=fixtures`, `OPENAPI_PUBLIC=true`, а также условия 11 SEC-056 (`LOG_LEVEL=debug`, `SMSPRO_BASE_URL=http://…`, пустые pepper'ы, `CORS_ALLOWED_ORIGINS=*`); `SMSPRO_TEST_FLAG`, `ONEC_MODE=fixtures` и `OPENAPI_PUBLIC` предлагается внести в стоп-список SEC-056 (раздел 22) | must | РЕШЕНИЕ | R5 §7.2, R2 §11, R6 §1 | AC-OPS-027: `APP_ENV=prod` + любой флаг из перечня (в т. ч. `SMSPRO_TEST_FLAG=true`) → `api` и `worker` не стартуют с понятной ошибкой в логе (без значений секретов) |
| OPS-028 | Runbooks 15.1–15.6 (1С недоступна; синхронизация падает; восстановление; сертификат; диск; прочие) переданы админу заказчика и проверены учением | must | ПОДТВЕРЖДЕНО | SRC-F-134e, SRC-D-171, R8 §10 | AC-OPS-028: по каждому runbook проведено ≥ 1 учение в тестовом контуре с записью в журнал |
| OPS-029 | Ротация секретов документирована: смена пароля БД, ключей JWT (с отзывом всех сессий), учётных данных SMSPro/1С, rclone, Healthchecks; плановая ротация — раз в год и при компрометации | must | РЕШЕНИЕ | SRC-F-138a, R5 §7.4, 11_SECURITY | AC-OPS-029: учение ротации пароля БД в тесте без потери данных; журнал ротаций |
| OPS-030 | Ротация служебных таблиц: `sync_runs`/`sync_errors` старше 90 дней, `idempotency_keys` старше 24 ч, `otp_challenges` истёкшие, `sms_outbox` старше 90 дней, `token_denylist` с истёкшим `exp` (R0 §17.3) удаляются заданием pg-boss; `audit_logs` не удаляются (3 года, D-36; срок хранения аудита — Q-028 по R0 §17.2) | should | РЕШЕНИЕ | D-36, D-37, R8 §3.1 | AC-OPS-030: размер `sync_runs` стабилен после 90 дней; `audit_logs` только растёт |
| OPS-031 | Передача эксплуатации: акт, инструкция (SRC-D-171), схема сети и портов, реестр секретов без значений, контакты, журнал релизов; обучение админа заказчика; передача ключей и доступов | must | ПОДТВЕРЖДЕНО | SRC-D-171, R8 §10 шаг 10 | AC-OPS-031: акт подписан; админ заказчика выполняет обновление и restore-drill в тесте самостоятельно |
| OPS-032 | Журнал эксплуатации ведётся (релизы, бэкапы, drill, инциденты, ротации, окна обслуживания) в репозитории проекта или согласованном месте | must | РЕШЕНИЕ | R8 §8.2, §6.4 | AC-OPS-032: журнал содержит записи всех событий за пилот |
| OPS-033 | Доступность backend в рабочие часы ≥ 99,5 % (без учёта простоев 1С) измеряется внешним монитором; отчёт ежемесячно | should | РЕШЕНИЕ | NFR-AVAIL-001 | AC-OPS-033: отчёт Uptime Kuma за месяц ≥ 99,5 % |
| OPS-034 | При инциденте безопасности: изоляция хоста, сохранение логов, ротация всех секретов, уведомление заказчика; разбор по 11_SECURITY_PRIVACY | must | РЕШЕНИЕ | R8 §5, 11_SECURITY | AC-OPS-034: план реагирования проверен учением (table-top) до передачи |
| OPS-035 | Режим сдерживания инцидента: администратор может перевести API в «только чтение» (`APP_READ_ONLY=true` → все мутации `503 APP_READ_ONLY`, чтение каталога/остатков работает) и отключить входящие интеграции флагами 4.3 без пересборки образа; включение и снятие режима фиксируются в журнале инцидентов | should | РЕШЕНИЕ | R0 §17.4, R0 §17.7, 11_SECURITY_PRIVACY | AC-OPS-035: после `APP_READ_ONLY=true` и `docker compose up -d api worker` `POST /orders` → 503 `APP_READ_ONLY`, `GET /catalog/products/{id}` → 200; после снятия — мутации снова проходят |

Итого: 50 требований DEPLOY + 35 требований OPS = **85** (DEPLOY-050 и OPS-035 добавлены при сверке с ядром v1.2).

---

## 17. Открытые вопросы

### 17.1. Ссылки на канонический список R0 §12

| Q | Что нужно от заказчика | Влияние на этот документ |
|---|---|---|
| Q-030 | Результаты аудита сервера (раздел 2, форма 2.5) | выбор сценария 3.5; всё остальное |
| Q-031 | Сетевая связь backend ↔ 1С: LAN / WireGuard (магазин инициирует) / исходящий обмен от 1С | раздел 12, `ONEC_MODE`, `ONEC_BASE_URL` |
| Q-032 | Домен/поддомены (`api.<домен>`, `api-test.<домен>`), доступ к DNS, окно обслуживания, канал алертов | 4.5, 6.3 №1/10/11, 9, 10 |
| Q-033 | Целевые RPO/RTO и внешнее хранилище бэкапов (и его локация — в КР или нет) | 8.1, OPS-003, OPS-006 |
| Q-039 | Тарифы местных ЦОД/VPS, стоимость статического IP и апгрейда сервера | 13.2–13.3 |
| Q-022 | Где и сколько хранятся фото, среднее число на SKU | 5.2, диск |
| Q-023 | Объёмы (SKU, клиенты, документы/год, одновременные пользователи, история) | 5.1, 5.4 |
| Q-010 / Q-011 | Конфигурация 1С, веб-публикация, 1С-разработчик, тестовая копия базы | 12.5, DEPLOY-037, тестовый контур |
| Q-020 | Допустимая свежесть остатков/цен (значения `SYNC_*_CRON`) | 4.3, OPS-012 |
| Q-027 / Q-028 | Юридические требования к ПДн (трансграничная передача, сроки хранения логов) | DEPLOY-048, 6.3 №12 |
| Q-029 | Параметры SMSPro (передача через защищённый канал) | 4.3, шаг 4 раздела 14 |
| Q-014 | API Бакай Банка — нужен ли публичный вебхук и способ его подписи (`QR_WEBHOOK_SECRET_FILE` или `QR_WEBHOOK_PUBLIC_KEY_FILE`), IP банка для `QR_WEBHOOK_ALLOWED_IPS`; `QR_PROVIDER` | 4.3, 4.5, 4.6 |
| Q-012 | Тестовый контрагент в 1С (тестовая копия — smoke 10.5 п. 6; рабочая база — только пилот 14.1 шаг 9) | 10.5 п. 6, 14.1 шаг 9 (prod-smoke 10.9 выполняется без мутаций — ядро §20.2 п.6, контрагент для него не нужен) |
| Q-008 | iOS — нужен ли macOS-раннер в CI; совместно с 13_ROADMAP Q-193 (ключи подписи) — канал раздачи APK и канал передачи zip-архива администратору ПК (по умолчанию в 10.7 — сетевая папка магазина или съёмный носитель) [НЕ ПОДТВЕРЖДЕНО]. Формат Windows-сборки R1 закрыт ядром §20.2 п.13 (zip + установка администратором; MSIX — R2; Q-130/Q-243) | DEPLOY-044, 10.2 «Порядок обновления», 10.7 |
| Q-001 | `CUSTOMER_SELF_SERVICE` в R1 | 4.3 |
| Q-018 | Возвраты: заявка из POS — R1 must, `app_settings.returns_enabled=true` по умолчанию (отключение — только при ответе «возвраты полностью в 1С»); `RETURNS_FROM_POS_ENABLED` — только автоматическая передача заявки в 1С через outbox (по умолчанию `false`) [РЕШЕНИЕ: ядро §21 п.1] — частично закрыт решением ядра v1.6 | 4.3, 10.5 п. 8 |
| Q-123 (05) | Глубина первичной загрузки истории продаж (`SALES_HISTORY_MONTHS`) | 4.3, 14.1 шаг 7 |
| Q-133 (06) | Политика `MIN_APP_VERSION` / `RECOMMENDED_APP_VERSION`: правило N / N−1, окно ≥ 30 дней, значение задаёт `admin` по платформам — закрыто ядром §20.2 п.14 (Q-153, Q-240 — дубли); открытый остаток — более длинное окно и досрочное повышение | 4.3, 10.2, 10.8 |
| Q-135 (06) | Минимальная конфигурация без отдельного `worker` (`WORKERS_ENABLED=true` в `api`) | 4.1, 4.3 |
| Q-152 (08) | Оплата долга без заказа из POS (`DEBT_PAYMENTS_FROM_POS`) | 4.3 |
| Q-242 (15) | OTP API SMSPro как альтернативная реализация доставки OTP (`SMSPRO_OTP_API_KEY_FILE`) | 4.3 |

### 17.2. Новые вопросы [НОВЫЙ ВОПРОС]

| Q | Вопрос | Влияние | Рекомендуемое допущение |
|---|---|---|---|
| Q-101 [НОВЫЙ ВОПРОС] | Если сервер заказчика — Windows Server: является ли он физическим или VM; допускается ли включение роли Hyper-V (с перезагрузкой) для сценария B-3; доступна ли вложенная виртуализация | 3.2, DEPLOY-046 | B-3 при физическом сервере; иначе B-2 для теста + C для прода |
| Q-102 [НОВЫЙ ВОПРОС] | Какой вариант прав пользователя `optomstroy` допускает админ заказчика: rootless Docker / `sudo` с ограниченным sudoers / членство в группе `docker` (root-эквивалент) | 6.1, DEPLOY-017 | rootless Docker на выделенном хосте; `sudo`-вариант при соседстве с чужими службами |
| Q-103 [НОВЫЙ ВОПРОС] | Где разместить внешний монитор (Uptime Kuma): офисный ПК заказчика, недорогой VPS, SaaS-монитор; кто оплачивает; где выполнять cron бэкапа — на хосте или в контейнере `backup` | 9, 8.4, OPS-011 | self-hosted Healthchecks + Uptime Kuma на отдельном хосте в КР (офисный ПК заказчика или недорогой VPS в КР); Healthchecks.io и иные зарубежные SaaS — только после ADR по 11 PRIV-020; cron на хосте |
| Q-104 [НОВЫЙ ВОПРОС] | PostgreSQL 17 (D-03) или 18 для первичного развёртывания — с учётом поддержки драйверами Drizzle/pg и точки монтирования тома | 4.1, 4.4, OPS-026 | 17 (по D-03); 18 — при подтверждении backend-инженером до шага 6 |
| Q-105 [НОВЫЙ ВОПРОС] | Допустимо ли сжимать оригиналы фото при приёме из 1С (`MEDIA_MAX_SOURCE_PX`=1600) и не хранить исходники сверх размеров thumb/card/full | 5.2, 4.3 | да — хранить только три размера WebP; исходники остаются в 1С |
| Q-106 [НОВЫЙ ВОПРОС] | Кто хранит приватный ключ шифрования бэкапов (`age`) у заказчика (ответственное лицо, носитель, процедура передачи при смене сотрудника) | 8.1, OPS-004 | руководитель + копия у DevOps в защищённом хранилище; процедура в акте передачи |
| Q-107 [НОВЫЙ ВОПРОС] | Нужен ли доступ к API из-за пределов магазина (мобильные продавцы вне Wi-Fi магазина) уже в R1 — определяет необходимость публичного IP/443 для сценариев A/B | 3.4, 12.4 | да (приложение на телефонах) → публичный доступ по HTTPS обязателен |

---

## 18. Трассировка на исходные требования

| ID требования ТЗ | SRC-ID | Строки промта | Раздел документа |
|---|---|---|---|
| DEPLOY-001 | SRC-F-129 | 956; 969 | 1, 3, 3.5 |
| DEPLOY-002 | SRC-F-130, SRC-F-131 | 957–958; 970–971 | 2, 2.5 |
| DEPLOY-003 | SRC-F-132 | 958; 971 | 2.2, 2.3 |
| DEPLOY-004 | SRC-F-133 | 959; 972 | 3.4, 3.5 |
| DEPLOY-005 | SRC-F-144 | 967; 980 | 1 |
| DEPLOY-006 | SRC-F-134 | 960; 973 | 3.1–3.3, 4 |
| DEPLOY-027, DEPLOY-028 | SRC-F-134a | 960; 973 | 5 |
| OPS-001, OPS-002, OPS-003, OPS-004, OPS-009 | SRC-F-134b, SRC-D-087, SRC-E-179h | 960; 973; 445; 746 | 8 |
| OPS-018, OPS-021, OPS-026 | SRC-F-134c | 960; 973 | 10 |
| OPS-010, OPS-011, OPS-012, OPS-013, OPS-014, OPS-015 | SRC-F-134d | 960; 973 | 9 |
| OPS-006, OPS-007, OPS-008, OPS-028 | SRC-F-134e, SRC-D-087, SRC-E-179i | 960; 973; 445; 746 | 8.1, 8.5, 15 |
| DEPLOY-023, DEPLOY-025, DEPLOY-012 | SRC-F-135 | 961; 974 | 6.1, 6.2 |
| DEPLOY-024, DEPLOY-046 | SRC-F-136 | 961; 974 | 6.3, 14.2 |
| DEPLOY-008, DEPLOY-009, DEPLOY-020 | SRC-F-137 | 962; 975 | 4.2, 7 (H-1, H-5) |
| DEPLOY-010, DEPLOY-011, DEPLOY-013, DEPLOY-015, DEPLOY-018, DEPLOY-047 | SRC-F-138 | 962; 975 | 4.5, 7 |
| DEPLOY-013, OPS-004, OPS-005, OPS-029 | SRC-F-138a (безопасное хранение секретов) | 962; 975 | 4.3, 7 (H-6), 8.2, 15.6 |
| DEPLOY-008, DEPLOY-017, DEPLOY-018, DEPLOY-020, DEPLOY-047 | SRC-F-138b (ограничение доступа) | 962; 975 | 4.2, 6.1, 7 (H-2, H-5, H-10) |
| DEPLOY-049 | SRC-F-138c (серверная проверка прав) | 962; 975 | 1 п.6, 4.5, 7 (H-15); 11_SECURITY_PRIVACY SEC-028/SEC-029 |
| DEPLOY-026 | SRC-F-139 | 963; 976 | 0 (шапка), 14 предусловия |
| DEPLOY-026 | SRC-F-139a (на первом этапе — только план) | 963; 976 | 0 (шапка), 1 п.9, 14 предусловия |
| DEPLOY-029 | SRC-F-140 | 964; 977 | 13 |
| DEPLOY-030, DEPLOY-031 | SRC-F-141 | 965; 978 | 11 |
| OPS-019, OPS-020, OPS-022, OPS-009 | SRC-F-142 | 965; 978 | 10.1, 10.4 |
| OPS-001, OPS-002, OPS-003, OPS-009 | SRC-F-142a (резервные копии) | 965; 978 | 8.2, 8.3, 10.1 |
| OPS-022 | SRC-F-142b (откат обновлений) | 965; 978 | 10.4, 14.2 |
| DEPLOY-032 | SRC-F-143 | 966; 979 | 3 (вводная) |
| DEPLOY-026, DEPLOY-042 | SRC-F-145 | 967; 980 | 14 предусловия |
| OPS-001, OPS-003, OPS-008 | SRC-D-087 | 445 | 8 |
| OPS-008, OPS-028 | SRC-D-087a (документированное восстановление) | 445 | 8.5, 15.3 |
| DEPLOY-044 | SRC-D-141 | 505 | 10.2 |
| DEPLOY-042, OPS-028, OPS-031 | SRC-D-171 | 532 | 14, 15 |
| DEPLOY-007, DEPLOY-016, DEPLOY-022, DEPLOY-033…041, DEPLOY-043, DEPLOY-045, DEPLOY-048, DEPLOY-050, OPS-005 (также SRC-F-138a), OPS-016, OPS-017, OPS-023…025, OPS-027, OPS-029, OPS-030, OPS-032…035 | производные от D-xx / R8 / R5 / R6 (не из промта напрямую) | — | 4, 7, 9–12, 15 |

Покрытие зоны (по реестрам F и D на 2026-10-18): SRC-F-129, 130, 131, 132, 133, 134, 134a, 134b, 134c, 134d, 134e, 135, 136, 137, 138, 138a, 138b, 138c, 139, 139a, 140, 141, 142, 142a, 142b, 143, 144, 145; SRC-D-087, SRC-D-087a, SRC-D-141, SRC-D-171 — каждая строка имеет хотя бы одно требование в таблице выше (32 SRC-ID). Перекрёстно: SRC-E-179h, SRC-E-179i (владелец — 11_SECURITY_PRIVACY); SRC-F-138c — совместно с 11_SECURITY_PRIVACY (SEC-028/SEC-029), здесь — граница proxy/api.

---

## 19. Замечания к ядру

Статус замечаний сверен с R0 v1.1 §16 («Дополнения ядра», 2026-10-18): принятые ядром замечания закрыты, в документе соответствующие имена помечены `[РЕШЕНИЕ: R0 §16.x]`. Открытыми остаются только №2 (частично), №6 и новые №10–№11. Дополнительно статус сверен с R0 v1.2 §17 (2026-10-18): остаток замечания №8 (`[НОВОЕ ИМЯ]` уровня compose/образов) в §17.7 не вошёл и остаётся информационным; имена, которые 4.3 ранее относил к «вне перечня» (`WORKERS_ENABLED`, `SMSPRO_TIMEOUT_MS`, `SMSPRO_RETRY_MAX`, `SMSPRO_DLR_*`, `AUTH_OTP_TEST_MODE`, `CORS_ALLOWED_ORIGINS`), приняты ядром §17.7; по итогам сверки v1.2 добавлены №12–№14. Сверка с R0 v1.3 §18 (2026-10-19): №12 закрыт §18.2 п.4, №13 — §18.1 и §18.2 п.12, п.14 (формат версий, все переменные документов внесены в 4.3, роль миграций — `pos_migrator`, в волне 4 исправлено на `pos_migrate` по 07), №14 — §18.2 п.13; остаток №8 закрыт §18.1 (имена уровня compose/образов входят в словарь владельца). Сверка с R0 v1.4 §19 (2026-10-19): №11 закрыт §19.2 (операции паузы/пропуска — R2); открытыми остаются №2 (частично), №6 и №10. Сверка с R0 v1.6 §21 и v1.7 §22 (2026-10-19): №15 частично закрыт §22.8 (ручной запуск в C-2 — `422`, механизм `requests[]` не вводится; C-3 в ядре по-прежнему не упомянут); добавлены №17 (контракт `server_epoch`) и №18 (новые имена словаря 4.3). Сверка с R0 v1.8 §23 (2026-10-19): ядро не закрывает ни одно открытое замечание этого раздела — №2 (частично), №6, №10, №15 (C-3), №17 (`server_epoch`; в 07, 08, 11 по-прежнему не определён) и №18 (имена `ONEC_INBOUND_ALLOWED_IPS`, `SYNC_ALERT_UNREACHABLE_MIN`, `SMS_STAGING_ALLOWED_PHONES` — в ядро §17.7 не внесены) остаются **открытыми**.

| # | Замечание | Предложение оркестратору | Статус |
|---|---|---|---|
| 1 | Внутренний порт `api`: R5 §7.2 — `3000`, R8 §2.1/§7 — `8080`; в ядре v1.0 порт не был зафиксирован. Документ использует `3000`. | — | **Принято в R0 v1.1 §16.1** (порт 3000; поддомены по умолчанию `api.`/`api-test.`) |
| 2 | Поддомены: R8 использует `pos.<домен>` / `pos-test.<домен>`, R5 — `test.`-префикс, Q-032 ядра рекомендует `api.<домен>` / `api-test.<домен>`. Документ следует Q-032. | Окончательно закрепить имена в ответе заказчика на Q-032 | **Частично принято в R0 v1.1 §16.1** (имена по умолчанию); окончательно — **открыто до ответа на Q-032** |
| 3 | Health-эндпоинты: R8 §7 упоминает `/ready`, ядро — `/health/ready`. Документ следует ядру. | — | **Принято в R0 v1.1 §16.8** (`/health`, `/health/ready` с составом readiness) |
| 4 | Переменная возраста долгов: D-24 — `RECEIVABLES_MAX_AGE`, этот документ — `RECEIVABLES_MAX_AGE_MIN` (единица в имени). | — | **Принято в R0 v1.1 §16.2** (`RECEIVABLES_MAX_AGE_MIN`) |
| 5 | Имена файлов-секретов: R5 §7.4 — `*_PATH`/без суффикса; документ ввёл единообразные `_FILE`-варианты (Compose `secrets:`); приложение поддерживает оба способа (значение или `_FILE`). | — | **Принято в R0 v1.1 §16.3** (конвенция `*_FILE`; перечень 4.3 — канонический для 06/08/11) |
| 6 | RPO: R6 §8 предлагает RPO ≤ 15 мин (WAL/PITR) в R1; D-35 ядра — RPO ≤ 24 ч в R1, PITR — R2. Документ следует D-35, `wal_level=replica` оставлен для безболезненного включения PITR. | Подтвердить D-35 у заказчика через Q-033 с явным указанием потери «заказов, не ушедших в 1С за сутки» | **Открыто** (решение заказчика, Q-033) |
| 7 | Compose-сервисы в D-33 — `caddy, api, worker, migrate, postgres, backup`; R8 §2.1 называет `proxy` и `sync`. Документ следует D-33. | — | **Принято в R0 v1.1 §16.6** (сервисы, проект `optomstroy-edge`, сети `optomstroy_<env>_edge/backend`, образ `optomstroy/backup`, скрипты `bin/*.sh`) |
| 8 | Новые имена, введённые документом: переменные `PUBLIC_BASE_URL`, `DATABASE_URL_FILE`, `SMSPRO_LOGIN_FILE`, `SMSPRO_PASSWORD_FILE`, `ONEC_ODATA_PATH`, `ONEC_HS_PATH`, `ONEC_MODE` (`extension \| odata_only \| fixtures`), `ONEC_USER_FILE`, `ONEC_PASSWORD_FILE`, `ONEC_CA_CERT_FILE`, `ONEC_TIMEOUT_MS`, `ONEC_SYNC_CHECK_TIMEOUT_MS`, `SYNC_*_CRON` (6 имён), `QR_WEBHOOK_SECRET_FILE`, `MEDIA_DIR`, `MEDIA_MAX_SOURCE_PX`, `HEALTHCHECKS_PING_URL_FILE`, `BACKUP_KEEP_DAYS`, `BACKUP_REMOTE`, `BACKUP_SCHEDULE`, `BACKUP_AGE_RECIPIENT`, `MIN_APP_VERSION`; заголовки `X-Min-App-Version`, `X-App-Version`, `X-Platform`; код `APP_UPDATE_REQUIRED` (HTTP 426); префикс `/api/v1/integrations/onec/*`; проект `optomstroy-edge`; образ `optomstroy/backup`; вопросы Q-101…Q-107. **Остаются вне ядра** (дополнения этого документа, помечены `[НОВОЕ ИМЯ]`): `SMSPRO_OTP_API_KEY_FILE`, `RCLONE_CONFIG_FILE`, `BACKUP_TAG`, `API_TAG`, `PGPASSWORD_FILE` (соглашение образа `backup`). | Оставшиеся имена — при необходимости добавить в R0 §16.3 на следующей ревизии (конфликтов с 08/05 не выявлено) | **Принято в R0 v1.1 §16.3, §16.4, §16.5, §16.6, §16.9** (перечисленные в первой части); остаток — **закрыт R0 v1.3 §18.1** (16 §4.3 — владелец словаря; имена помечены `[РЕШЕНИЕ: ядро §18.1]`, `SMSPRO_OTP_API_KEY_FILE` — `[РЕШЕНИЕ: ядро §18.2 п.14]`) |
| 9 | Ядро (NFR-SCALE-001) допускает рост до 200 пользователей; D-34 даёт ресурсы под 50. Документ добавил ориентир 16 GB RAM при 200 (5.4). | — | **Принято в R0 v1.1 §16.7** (4–8 vCPU / 16 GB при 200 пользователях) |
| 10 | Публичный путь фото: R0 §7 и 08_API 4.4.7 — `/images/{sha}/{size}` (через proxy, без расширения); схема `Image` в 08_API содержит `thumbUrl: "/api/v1/images/{sha}/thumb"` (с префиксом `/api/v1`). Caddyfile 4.5 следует R0 §7 и использует `try_files {path}.webp` для файлов `{size}.webp` (D-30); при выборе префикса `/api/v1/images/*` блок переносится выше `/api/*`. | 08_API: привести `Image.*Url` и 4.4.7 к одному пути; зафиксировать, что расширение в URL отсутствует | [НОВЫЙ] открыто для 08_API |
| 11 | Операции эксплуатации, отсутствующие в R0 §7: пауза/возобновление синхронизации на время релиза (`POST /sync/pause`, `POST /sync/resume`, поле `paused` в `/sync/status`) и пропуск проблемной записи `sync_errors` (`POST /sync/runs/{id}/errors/{errorId}/skip`) — используются в 10.3 и 15.2, помечены `[НОВОЕ ИМЯ]`; без них допустима эквивалентная замена `docker compose stop/up worker`. | 08_API/R0 §7: добавить операции или зафиксировать замену через compose | **Закрыто решением ядра v1.4 §19.2**: пауза сущности и пометка ошибки синхронизации решённой — R2 (Q-219); в R1 — `docker compose stop/up worker` (10.3) и `POST /sync/outbox/{id}/retry` (15.2); метки `[НОВОЕ ИМЯ]` у операций удалены |
| 12 | `INTEGRATION_API_KEY_FILE` (R0 §17.7) принят ядром без назначения; рядом существует `ONEC_INBOUND_TOKEN_FILE` для того же класса токенов (`integration_tokens`). Документ трактует `INTEGRATION_API_KEY_FILE` как резервный технический ключ роли `integration` для интеграций, не относящихся к 1С, в R1 не монтируемый. | Зафиксировать назначение в ядре (или объявить имя синонимом/резервом) и согласовать с 08/11 | **Закрыто R0 v1.3 §18.2 п.4**: обе переменные не используются и удалены из 4.3 и compose; токены — только `integration_tokens`, выпуск `bin/issue_integration_token` (4.3), срок 180 дней |
| 13 | В других документах ТЗ встречаются имена переменных вне перечня ядра (например, `AUTH_OTP_TEST_CODE`, `SYNC_COUNT_CHECK_CRON`, `SMSPRO_CB_OPEN_MINUTES`, `OTP_TTL_SECONDS`); канонический перечень 4.3 их не включает. Также ядро не задаёт формат «по платформам» для `MIN_APP_VERSION`/`RECOMMENDED_APP_VERSION` (документ предлагает semver или список `<platform>=<semver>`) и имя роли миграций для `DB_MIGRATOR_PASSWORD_FILE`. | Решить: внести имена в ядро §17.7 (тогда 4.3 дополняется) или заменить их в документах ключами `app_settings`/каноническими именами; формат версий — закрепить в 08 | **Закрыто R0 v1.3**: §18.1 (4.3 содержит каждую серверную переменную документов — добавлены 39 имён из 05, 07, 08, 09, 10), §18.2 п.12 (формат `platform=semver` через запятую, заголовки `X-Min-App-Version`/`X-Recommended-App-Version`), §18.2 п.14 (пороги outbox/сверок и параметры 09 §6.11 канонические); роль миграций — `pos_migrate` (4.3; исправлено в волне 4 по 07 DATA-012) |
| 14 | Место IP-allowlist для вебхуков: 11_SECURITY_PRIVACY (угрозы QR) говорит об allowlist «на `pos-proxy`», тогда как DEPLOY-049/H-15 запрещают правила доступа по путям в proxy. Документ (4.6, DEPLOY-050) закрепляет: обязательная проверка IP — в `api` по `X-Forwarded-For` от `caddy`; фильтр `remote_ip` в Caddy — необязательный дублирующий слой. | Подтвердить трактовку и выровнять формулировку 11 | **Закрыто R0 v1.3 §18.2 п.13** (трактовка 16 — канон; 11 выравнивает) |
| 15 | Вариант C-3 (гибрид C-1 + C-2, 3.3) несовместим с 05 ONEC-065: `ONEC_INBOUND_ENABLED=true` одновременно включает входящий обмен и отключает все исходящие вызовы backend → 1С; ядро вариант C-3 не упоминает. Кроме того, в контракте 05 §10.1 нет механизма запроса среза/перерегистрации со стороны backend, поэтому ручная синхронизация и `full`/`reconcile` в C-2 выполняются только на стороне 1С (12.3) | Зафиксировать в ядре: C-3 — вне R1; для R2 — либо отдельный флаг «отключить исходящие вызовы», либо отказ от C-3; механизм запроса со стороны backend (поле `requests[]` в ответе `/ping` `[НОВОЕ ИМЯ]`) — решение владельца 05 §10.1 и 08 §4.17.2 | **Частично закрыто ядром v1.7 §22.8**: в C-2 `POST /sync/runs` → `422` (`rule: inbound_mode`), кнопка SCR-43 неактивна, механизм `requests[]` не вводится (12.3, 15.1, 15.2, 8.5, DEPLOY-036 выровнены); C-3 — вне R1, в ядре не упомянут — **открыто** |
| 16 | Имя роли БД миграций: 16 ссылался на «ядро §18.1» для `pos_migrator`, но в ядре имя роли не задано, а владелец схемы прав БД (07 §2.2, DATA-012) использует `pos_migrate` | 16 выровнен на `pos_migrate`; предлагается внести имена ролей БД (`pos_migrate`, `pos_app`, `pos_readonly`, `pos_backup`) в ядро как словарь 07 | **Исправлено в 16** (волна 4); в ядро — предложение |
| 17 | Эпоха данных `server_epoch` (05 F16/SYNC-063: смена после restore, клиент не повторяет `POST /orders` из `checkout_draft`) определена только в 05: в 08 §2.11 нет заголовка ответа и поля `/health`, в 07 — места хранения; кроме того, канонический состав `/health` (11 SEC-019: только `status`, `minAppVersion`) поля эпохи не допускает. Runbook 8.5 шаг 7, 15.3 и OPS-008 дополнены шагом «назначить новую `server_epoch` до запуска `api`» без конкретной команды | Зафиксировать в ядре: имя заголовка (`X-Server-Epoch` `[НОВОЕ ИМЯ]`), место хранения (07, не env — значение должно меняться при каждом restore), допустимость поля в `/health` (11 SEC-019) и команду смены (скрипт этапа 2); владельцы — 08 §2.11, 07, 11 | **Открыто** (передано 08, 07, 11; 12 — тест restore-drill с `checkout_draft`) |
| 18 | Серверные переменные других документов, отсутствовавшие в 4.3: `ONEC_INBOUND_ALLOWED_IPS` (05 ONEC-060), `SYNC_ALERT_UNREACHABLE_MIN` (05 SYNC-038), `SMS_STAGING_ALLOWED_PHONES` (09 §5.8) | Внести имена в ядро (§17.7) как канонические | **Внесено в 16 §4.3** владельцем словаря (ядро §18.1); в ядро — предложение |

---

## 20. Журнал проверки (доработка по замечаниям независимого проверяющего, 2026-10-18)

Правки внесены точечно, структура и ID сохранены; добавлено одно требование (DEPLOY-049) и одна строка hardening (H-15). Итог: 49 DEPLOY + 34 OPS = 83 требования; покрыты все 32 SRC-ID зоны (включая подпункты 138a/b/c, 139a, 142a/b, SRC-D-087a).

| # | Серьёзность | Замечание (кратко) | Решение | Где исправлено |
|---|---|---|---|---|
| 1 | major | Семь SRC-подпунктов (SRC-F-138a/b/c, 139a, 142a/b, SRC-D-087a) отсутствуют в трассировке при заявленном полном покрытии; для SRC-F-138c нет требования | **Исправлено.** Добавлено требование DEPLOY-049 (серверная проверка прав в `api`, proxy не авторизует; ссылки на 11_SECURITY SEC-028/SEC-029 и 08_API) и строка H-15; SRC-ID дописаны в колонку «Источник» DEPLOY-008/013/017/018/020/026/047, OPS-001/002/003/004/005/008/009/022/029; в §18 добавлены 7 строк трассировки; абзац «Покрытие зоны» переписан с перечислением фактически покрытых 32 SRC-ID (слово «все покрыты» убрано); шапка и §1 п.6/п.9 дополнены | шапка, §1, §4.5 (примечание 2), §7 (H-15), §16.1 (DEPLOY-049), §16.2, §18 |
| 2 | major | Поверхностное слияние YAML `<<: *app`: `environment:` в `api`/`worker` замещает карту якоря, указатели `*_FILE` не доходят до контейнеров | **Исправлено.** Введён якорь `x-secret-env: &secret-env`; в `x-app`, `api`, `worker` — `environment: { <<: *secret-env, … }`; добавлено примечание (6) о поверхностном слиянии; в 4.3 явно зафиксировано, что приложение не ищет `/run/secrets/<имя>` по умолчанию — путь всегда задаётся `*_FILE` | §4.3 (вводный абзац), §4.4 |
| 3 | major | Таблица 4.3 неполна/противоречива: нет `ONEC_CA_CERT_FILE` и `MIN_APP_VERSION`; `ONEC_MODE` без `fixtures`; `[НОВОЕ ИМЯ]` у имён, уже принятых ядром; `SYNC_*_CRON` приписаны R5 §7.4 | **Исправлено.** Добавлены строки `ONEC_CA_CERT_FILE` (secret `onec_ca.pem`, подключён в compose) и `MIN_APP_VERSION`; `ONEC_MODE` = `extension \| odata_only \| fixtures` [РЕШЕНИЕ: R0 §16.3]; все имена из перечня R0 §16.3 помечены `[РЕШЕНИЕ: R0 §16.x]`, `[НОВОЕ ИМЯ]` оставлено только у имён вне перечня (`SMSPRO_OTP_API_KEY_FILE`, `RCLONE_CONFIG_FILE`); источник `SYNC_*_CRON` — «этот документ / R0 §16.3»; добавлен абзац о переменных вне перечня | §4.3, §4.4, §11, §12.1 |
| 4 | minor | Caddyfile: `file_server` отдаёт `{size}` вместо `{size}.webp` (404 в smoke-тесте); блок `/integrations/*` на корне противоречит R0 §16.5/§7 | **Исправлено.** Добавлен `try_files {path}.webp {path}` с комментарием; блок `/integrations/*` удалён и заменён комментарием «вебхуки и входящий обмен 1С — под `/api/v1/...`, обслуживаются блоком `/api/*`»; расхождение путей `/images` vs `/api/v1/images` внутри 08_API вынесено в §19 №10 | §4.5, §19 |
| 5 | minor | 4.1 заявляет healthcheck `caddy`, в compose его нет; `depends_on: api: service_healthy` мешает ACME-валидации (шаг 3 плана 14.1) и перевыпуску сертификата при упавшем `api` (15.4) | **Исправлено** (вариант «убрать»): зависимость удалена с комментарием; в 4.1 для `caddy` указано «healthcheck нет (намеренно)» с обоснованием — проверка `/health` через proxy делала бы proxy «нездоровым» при любом простое `api`; доступность через proxy контролирует внешний монитор (§9). Добавлено примечание (7) к compose | §4.1, §4.4 |
| 6 | minor | Даты жизненного цикла Windows Server сдвинуты относительно «patch Tuesday»; Ubuntu — «05.20xx» вместо апреля/июня | **Исправлено.** Windows Server: 2019 extended 2029-01-09; 2022 mainstream 2026-10-13 / extended 2031-10-14; 2025 mainstream 2029-10-09 [ПОДТВЕРЖДЕНО: learn.microsoft.com/lifecycle; перепроверить на дату аудита]. Ubuntu смягчено до года с пометкой [ТИПОВО: уточнить на дату аудита] в L-2 и 5.5 | §2.2 (L-2), §2.3 (W-1), §5.5 |
| 7 | minor | `backup_db.sh`: plaintext-дамп 30 дней рядом с `.age`, нет `umask`; `rclone` тома `caddy_data` требует root и не учитывает rootless; `docker compose` от `optomstroy` противоречит вариантам (а)/(б) 6.1; `CRON_TZ` не везде поддерживается | **Исправлено.** `umask 077`, `chmod 700`, `export TZ`; plaintext удаляется сразу после шифрования, остаётся только `latest.dump` (600) для RTO на том же сервере (обоснование и альтернатива `rm` — в пояснении); `globals` тоже шифруются; `caddy_data` копируется через `docker compose cp` (с указанием пути томов для rootless и альтернативы bind-mount); переменная `DC` с вариантами (а)/(б)/(в) и `sudo /usr/bin/docker compose` по умолчанию; `CRON_TZ` помечен [ТИПОВО] с инструкцией; 8.5 шаг 2 и OPS-001/OPS-002 синхронизированы | §8.3, §8.4, §8.5, §16.2 |
| 8 | minor | Замечания к ядру №1, 4, 5, 7, 8, 9 уже приняты в R0 v1.1 §16; документ по-прежнему помечает имена `[НОВОЕ ИМЯ]` / «согласовать с 08_API» | **Исправлено.** В §19 добавлена колонка «Статус» (принято в R0 v1.1 §16.x для №1, 3, 4, 5, 7, 8, 9; №2 — частично, открыто до Q-032; №6 — открыто); пометки у `APP_UPDATE_REQUIRED` (§10.2), `/api/v1/integrations/onec/*` (§12.3), `ONEC_MODE=fixtures` (§11), `ONEC_CA_CERT_FILE` (§12.1), порт 3000 (§4.1) заменены на `[РЕШЕНИЕ: R0 §16.x]`. Отклонение от предложения проверяющего: №3 также отмечено принятым, поскольку R0 §16.8 фиксирует `/health/ready` | §4.1, §10.2, §11, §12.1, §12.3, §19 |
| 9 | minor | §10.3 шаг 2 и §15.2 используют операции вне R0 §7 (`sync.paused` через `/admin/settings`, `GET /sync/status → paused`, `skipped` через `/admin/settings`) без пометки | **Исправлено.** Предложены `POST /sync/pause` / `POST /sync/resume` (поле `paused` в `/sync/status`) и `POST /sync/runs/{id}/errors/{errorId}/skip` с пометкой `[НОВОЕ ИМЯ — согласовать с 08_API]`; для outbox — существующий `POST /sync/outbox/{id}/retry`; эквивалент без API — `docker compose stop/up worker`; вынесено в §19 №11 | §10.3, §15.2, §19 |
| 10 | minor | Mermaid: двоеточия в подписях рёбер без кавычек (§3.3, §3.5); `direction LR` внутри subgraph (§3.1) | **Исправлено.** Подписи взяты в кавычки (`-- "нет: нет IP/443" -->`, `-. "C-1: …" .->` и т. д.); `direction LR` из subgraph `Server` удалён | §3.1, §3.3, §3.5 |
| 11 | minor | DEPLOY-044 упоминает `MSIX`, не зафиксированный ядром; канал раздачи сборок не решён | **Исправлено.** Критерий приёмки: «установщик Windows (MSIX или zip — по 13_IMPLEMENTATION_ROADMAP RM-H-007, [НЕ ПОДТВЕРЖДЕНО])»; в 10.2 канал раздачи помечен [НЕ ПОДТВЕРЖДЕНО] со ссылкой на Q-008 и 13_ROADMAP Q-193; строка Q-008 в 17.1 расширена (новый номер Q-1xx не вводится, т.к. R0 §16.9 закрепил за 16_DEPLOYMENT_PLAN диапазон Q-101…Q-107, а Q-108+ — за другими документами) | §10.2, §16.1 (DEPLOY-044), §17.1 |
| 12 | minor | Неясно, на каком хосте закрывается порт 3001 Uptime Kuma (H-10, DEPLOY-047 vs §9/OPS-011) | **Исправлено.** H-10, §9 и DEPLOY-047 уточнены: панель Uptime Kuma — на хосте монитора (не на сервере backend), публикуется только `127.0.0.1:3001` за HTTPS-RP/VPN; на сервере backend порт 3001 не ожидается вовсе; критерий приёмки разделён по хостам | §7 (H-10), §9, §16.1 (DEPLOY-047) |

### 20.1. Повторная проверка (повтор попытки, 2026-10-18)

При повторном прогоне все 12 замечаний сверены с текстом документа: исправления №1–№12 присутствуют на месте (DEPLOY-049 и H-15; строки SRC-F-138a/b/c, 139a, 142a/b, SRC-D-087a в §16 и §18; якорь `x-secret-env`; строки `ONEC_CA_CERT_FILE`/`MIN_APP_VERSION`, `ONEC_MODE` с `fixtures`; `try_files` и удалённый блок `/integrations/*`; `caddy` без `depends_on`/healthcheck; даты W-1/L-2; `umask 077`/`latest.dump`/`docker compose cp`/`CRON_TZ`; статусы §19; `[НОВОЕ ИМЯ]` у операций паузы/пропуска; DEPLOY-044 без безусловного MSIX; H-10/DEPLOY-047 по хостам). Ни одно замечание не признано ошибочным. Дополнительно найдены и исправлены остаточные дефекты:

| # | Остаточный дефект | Решение | Где исправлено |
|---|---|---|---|
| R-1 | После исправления №2 якорь `x-secret-env` передавал `worker` указатели `JWT_PRIVATE_KEY_FILE`/`OTP_HMAC_SECRET_FILE`, хотя список `secrets:` у `worker` (замещающий, тоже поверхностное слияние) эти файлы не монтирует — ссылка на несуществующий `/run/secrets/...`; `migrate` получал все секреты при потребности только в БД | Якорь `x-secret-env` сокращён до общих для `api`/`worker` указателей; `JWT_PRIVATE_KEY_FILE`, `OTP_HMAC_SECRET_FILE` и полный `secrets:` — только у `api`; у `migrate` — `DATABASE_URL_FILE` и `secrets: [database_url]`; `x-app` больше не содержит `environment`/`secrets`; примечание (6) дополнено (замещение `secrets:`, минимум прав) | §4.4 |
| R-2 | Сети в примере compose без `name:` получили бы имена `optomstroy-prod_edge`/`optomstroy-prod_backend`, что расходится с 4.2, 6.1 и R0 §16.6 (`optomstroy_<env>_edge/backend`) | Сетям заданы явные `name: optomstroy_prod_edge` / `optomstroy_prod_backend`; ссылка на документацию Compose — в примечании (6) | §4.4 |
| R-3 | Строка H-15 стояла между H-10 и H-11 (нарушение порядка нумерации таблицы hardening) | Строка перенесена после H-14; содержание не менялось | §7 |
| R-4 | `backup_db.sh` вызывал `rclone` без явного пути к `secrets/rclone.conf`; комментарий шага 1 ошибочно говорил о `/run/secrets`; при варианте (б) файлы `docker compose cp` принадлежат root; 8.5 вызывал `docker compose` без учёта варианта прав 6.1 | Добавлен `export RCLONE_CONFIG=…/secrets/rclone.conf`; комментарий шага 1 исправлен; в пояснениях — рекомендация bind-mount `caddy_data` с владельцем `optomstroy` для варианта (б); в 8.5 шаг 1 — оговорка о вызове `docker compose` по варианту 6.1/Q-102 | §8.3, §8.5 |

Итог без изменений: 49 DEPLOY + 34 OPS = 83 требования; ID не менялись; покрыты 32 SRC-ID зоны, включая SRC-F-138a, SRC-F-138b, SRC-F-138c, SRC-F-139a, SRC-F-142a, SRC-F-142b, SRC-D-087a.

Проверка целостности после правок: файл дочитывается до строки «Конец документа», все таблицы закрыты, блоки кода (в т. ч. 8 Mermaid) парные.

---

## 21. Журнал сверки с ядром v1.2

Сверка с R0 v1.2 §16 и §17 (2026-10-19), правки точечные: существующие ID требований не менялись, добавлены DEPLOY-050 и OPS-035 (итог — 50 DEPLOY + 35 OPS = 85), подраздел 4.6, пример `.env.example` в 4.3 и замечания к ядру №12–№14.

| Пункт ядра | Что изменено | Где |
|---|---|---|
| §17.7 (+ §16 п.3) — канонический перечень переменных | Таблица 4.3 переписана: включены **все** 77 имён ядра (§16 п.3 + §17.7), добавлена колонка «По умолчанию» (только несекретные значения), группировка по назначению, пометки `[РЕШЕНИЕ: R0 §17.7]`/`[НОВОЕ ИМЯ]`; новые строки: `PIN_PEPPER_FILE`, `PIN_PEPPER_VERSION`, `OTP_HMAC_SECRET_VERSION`, `JWT_KEY_ID` (и формат `JWT_PUBLIC_KEY_FILE` = `{kid: pem}`), `DB_MIGRATOR_PASSWORD_FILE`, `ONEC_HS_USER_FILE`/`ONEC_HS_PASSWORD_FILE`/`ONEC_HS_TOKEN_FILE`, `ONEC_INBOUND_ENABLED`/`ONEC_INBOUND_TOKEN_FILE`, `ONEC_ODATA_WRITE_ENABLED`, `ONEC_SYNC_PAGE_SIZE`, `ONEC_MAX_CONCURRENCY`, `SYNC_NIGHT_WINDOW`, `SALES_HISTORY_MONTHS`, `RETURNS_FROM_POS_ENABLED`, `DEBT_PAYMENTS_FROM_POS`, `QR_PROVIDER`, `QR_TTL_MINUTES`, `QR_WEBHOOK_ENABLED`/`QR_WEBHOOK_PUBLIC_KEY_FILE`/`QR_WEBHOOK_ALLOWED_IPS`, `INTEGRATION_API_KEY_FILE`, `AUTH_OTP_TEST_PHONES`, `OTP_GLOBAL_PER_MIN`, `SMSPRO_BALANCE_*`, `SESSION_IDLE_LOCK_MINUTES`, `APP_READ_ONLY`, `RECOMMENDED_APP_VERSION`, `BACKUP_AGE_IDENTITY_FILE` (вне сервера); абзац «вне перечня» переписан | 4.3 |
| §17.7 — ключи `app_settings` (не env) | Перечислены бизнес-настройки POS как ключи `app_settings`; правило «env — значение по умолчанию, `app_settings` переопределяет» | 4.3 (вводная) |
| §17.7 — пример конфигурации | Добавлен пример `.env.example` со всеми несекретными переменными и значениями по умолчанию (без значений секретов; указатели `*_FILE` — только в compose) | 4.3, «Пример `.env.example`» |
| §17.7 — compose | `x-secret-env`: `ONEC_HS_*`, `JWT_PUBLIC_KEY_FILE` → `jwt_public.json`; `api`: `PIN_PEPPER_FILE`, закомментированные указатели входящих интеграций; `worker`: секреты `onec_hs_*`; `migrate`: `DB_MIGRATOR_PASSWORD_FILE`; блок `secrets:` дополнен (`db_migrator_password`, `pin_pepper`, `onec_hs_*`, условные `onec_inbound_token`/`qr_webhook_*`/`integration_api_key`); примечание 6 (минимум прав) обновлено | 4.4 |
| §17.1 D-44 (без Redis) | Зафиксировано отсутствие сервиса Redis; очереди/расписания/rate-limit OTP/идемпотентность — в PostgreSQL | 1 п.1, 4.1 (абзац «Архитектурные рамки»), 4.3 (`WORKERS_ENABLED`, `OTP_GLOBAL_PER_MIN`), 4.4 (комментарии, прим. 6), 4.6 п.(6), DEPLOY-007 |
| §17.1 D-45 (модульный монолит, `WORKERS_ENABLED`) | `api`/`worker`/`migrate` — один образ; роль процесса — команда + `WORKERS_ENABLED` (`false`/`true`; минимальная конфигурация — `true` в `api`, Q-135); `WORKERS_ENABLED` переведена из «вне перечня» в канон | 1 п.1, 4.1, 4.3, 4.4, DEPLOY-007, 17.1 (Q-135) |
| §17.1 D-46 (`MIN_APP_VERSION` по платформам, `RECOMMENDED_APP_VERSION`) | Формат по платформам, мягкий баннер, порядок поднятия версий | 4.3, 10.2, 17.1 (Q-133), §19 №13 |
| §17.1 D-47 / D-48 | `OTP_HMAC_SECRET_FILE` отнесён к `OtpService`; `PIN_PEPPER_FILE`/`PIN_PEPPER_VERSION` (серверная проверка PIN) — только `api`; `SMSPRO_OTP_API_KEY_FILE` привязан к Q-242 | 4.3, 4.4, 14.1 шаг 4, 15.6 |
| §17.4 — входящий обмен `/integrations/onec/*` | Канонический состав путей (`changes`, `snapshots/{entity}`, `order-status`, `outbox`, `outbox/{outboxId}/ack`, `ping`; не `heartbeat`), включение `ONEC_INBOUND_ENABLED`, токен `integration_tokens` + `ONEC_INBOUND_TOKEN_FILE` | 4.5, 4.6, 12.3, DEPLOY-036, DEPLOY-050 |
| §17.4 — `/integrations/smspro/dlr`, QR-вебхук: правила proxy/allowlist | Новый подраздел 4.6 (таблица маршрутов: включение, аутентификация, allowlist IP, proxy, переменные); Caddyfile: блоки `handle /api/v1/integrations/*` и `handle /api/v1/payments/qr/webhook` с необязательным фильтром `remote_ip`; IP-allowlist обязателен в `api` по `X-Forwarded-For` от `caddy`; H-15, DEPLOY-049 (и AC) уточнены; новое требование DEPLOY-050; расхождение с 11 — §19 №14 | 4.5, 4.6, 7 (H-15), 16.1 (DEPLOY-049, DEPLOY-050), 19 |
| §17.4 — коды `APP_READ_ONLY`, `PAYLOAD_TOO_LARGE`, `UNSUPPORTED_MEDIA_TYPE`; long-polling `?wait=` | Режим «только чтение» как средство сдерживания (runbook, OPS-035); лимиты тела/типа в `api`; `read_timeout 30s` покрывает long-polling ≤ 25 с | 4.3, 4.5, 4.6, 15.6, OPS-035 |
| §17.2 D-24, D-29 | Синхронное обновление снимка долгов перед checkout с `credit`; в C-2 — проверка по снимку с `STALE_DATA`; `SYNC_*_CRON` — значения по умолчанию, переопределение `app_settings.sync_interval.<entity>` | 4.3, 12.3 |
| §17.2 D-36 | Срок хранения аудита — Q-028 (не Q-034) | OPS-030 |
| §17.3 (`dev_outbox`, `integration_tokens`, `token_denylist`, `payment_webhook_events`) | `dev_outbox` — только тест-контур (`FakeSmsGateway`); `integration_tokens` — для входящего обмена; очистка `token_denylist`; журнал вебхуков — защита от повтора | 11 (таблица), 4.6, 12.3, OPS-030 |
| §17.6 — нумерация вопросов | Добавлены ссылки на Q-018, Q-123, Q-133, Q-135, Q-152, Q-242; Q-014 уточнён; собственные Q-101…Q-107 без изменений | 17.1 |
| Шапка / замечания к ядру | Версия 1.1 с датой сверки; во входных материалах — D-44…D-48 и §16–§17; §19 — вводная обновлена, замечания №12–№14 | шапка, 19 |
| §17.5 (дизайн-система) | Не относится к документу — изменений нет | — |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; таблицы закрыты, символ `\|` внутри ячеек экранирован; блоки кода (yaml, caddyfile, dotenv, bash, text, mermaid) парные.

### 21.1. Сверка с ядром v1.3 (2026-10-19)

Сверка с R0 v1.3 §18 (§18 — высший приоритет), правки точечные: ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85). Документ — владелец словаря переменных окружения (§18.1); словарь 4.3 сверен Grep-ом с 05, 06, 07, 08, 09, 10, 11, 13.

| Пункт ядра | Что изменено | Где |
|---|---|---|
| §18.1 — владелец словаря переменных окружения (16 §4.3) | Вводный абзац 4.3: перечень объявлен каноническим словарём для 05/06/08/09/10/11/13, при расхождении прав 4.3; введена пометка `[РЕШЕНИЕ: ядро §18.1]`; в колонку «Примечание» добавлен документ-источник | 4.3 (вводная) |
| §18.1 — каждая серверная переменная документов | Добавлены 39 имён из других документов с назначением, признаком секрета и значением по умолчанию: из 09 §6.11 — `AUTH_OTP_TEST_CODE`, `OTP_TTL_SECONDS`, `OTP_RESEND_COOLDOWN_SECONDS`, `OTP_MAX_VERIFY_ATTEMPTS`, шесть `OTP_MAX_SENDS_PER_*`, `OTP_LOCK_AFTER_LOCKED_CODES`, `OTP_PHONE_PAUSE_MINUTES`, `OTP_RESEND_ON_DLR_FAILED`, `OTP_PROVIDER`, `AUTH_ACCESS_TTL_SECONDS`, `AUTH_REFRESH_TTL_STAFF_DAYS`/`_CUSTOMER_DAYS`, `AUTH_REFRESH_IDLE_STAFF_HOURS`/`AUTH_REFRESH_IDLE_CUSTOMER_DAYS`, `AUTH_REFRESH_GRACE_SECONDS`, `AUTH_BACKGROUND_LOCK_MINUTES`, `AUTH_BIO_AUTO_PROMPT`, `AUTH_NOTIFY_OLD_PHONE`, `PIN_MIN_LENGTH_STAFF`, `PIN_MAX_ATTEMPTS`, `SMSPRO_CB_OPEN_MINUTES`, `SMSPRO_DEF_PRECHECK`, `SMS_OTP_TEMPLATE`, `INVITE_SMS`, `REGISTRATION_SECOND_OTP`, `FACE_SCAN_MODE`, `FACE_SCAN_STORE_FRAMES`, `FACE_SCAN_REQUIRED`; из 07/09 — `INVITATION_TTL_DAYS`; из 05 — `MANUAL_ORDER_SLA_MIN`, `SYNC_COUNT_CHECK_CRON`; из 10 — `OUTBOX_MAX_ATTEMPTS`, `OUTBOX_MAX_AGE_HOURS`; из 08 — `OPENAPI_PUBLIC`. Новая группа «Регистрация, приглашения, FACE-SCAN». Добавлена строка `PGPASSWORD_FILE` (уже использовалась в compose 4.4) | 4.3 (таблица), пример `.env.example` |
| §18.1 — состав и исключения словаря | Абзац после таблицы переписан: имена уровня compose/образов/хоста; включённые имена других документов; перечень **неиспользуемых** имён-синонимов (`ONEC_INBOUND_ONLY`, `ONEC_WRITE_ENABLED`, `PAYMENTS_ENABLED`, `RETURNS_ENABLED`, `NODE_ENV`, `OTP_GLOBAL_SENDS_PER_MIN`, `AUTH_IDLE_LOCK_MINUTES`, `RECEIVABLES_MAX_AGE`, бизнес-настройки в верхнем регистре → ключи `app_settings`); не-`_FILE` варианты секретов — только fallback в `APP_ENV=dev`; клиентская конфигурация `pos-app` (`API_BASE_URL`, `FEATURE_*`, `SENTRY_DSN`, `MIN_SUPPORTED_VERSION_CHECK`) и платформенные константы в словарь сервера не входят | 4.3 (абзац после таблицы) |
| §18.1 / §17 — метки `[НОВОЕ ИМЯ]` | У имён словаря `[НОВОЕ ИМЯ]` заменено на `[РЕШЕНИЕ: ядро §18.1]` (`API_TAG`, `BACKUP_TAG`, `TZ`, `POSTGRES_USER`/`POSTGRES_DB`, `POSTGRES_PASSWORD_FILE`, `RCLONE_CONFIG_FILE`, `WG_*`, `PGPASSWORD_FILE` в примечании 5 к 4.4) и на `[РЕШЕНИЕ: ядро §18.2 п.14]` (`SMSPRO_OTP_API_KEY_FILE`); у `RCLONE_CONFIG_FILE` пояснено, что в контейнере путь передаётся стандартной переменной rclone `RCLONE_CONFIG` | 4.3, 4.4 (примечание 5) |
| §18.2 п.4 — технические токены роли `integration` | Строки `ONEC_INBOUND_TOKEN_FILE` и `INTEGRATION_API_KEY_FILE` удалены из 4.3; из compose удалены указатели и секреты `onec_inbound_token`/`integration_api_key`; описан скрипт оператора `bin/issue_integration_token` (хэш в `integration_tokens`, `scope`, `expires_at`, `revoked_at`; токен показывается один раз; срок 180 дней с ротацией; отзыв скриптом или `DELETE` в админ-разделе R2; без строки в `users`); ротация токена 1С в runbook — через скрипт вместо SCR-46 | 4.3 (вводная, `ONEC_INBOUND_ENABLED`, абзац «Технические токены»), 4.4 (`api`, `secrets:`, примечание 6), 4.6, 12.3, 14.1 шаг 4, 15.6, DEPLOY-036, DEPLOY-050 (AC), §19 №12 |
| §18.2 п.12 — минимальная/рекомендуемая версия клиента | Формат `MIN_APP_VERSION`/`RECOMMENDED_APP_VERSION` — `platform=semver` через запятую (`android=1.2.0,windows=1.2.0`), вариант «одна semver для всех платформ» снят; заголовки `X-Min-App-Version` и `X-Recommended-App-Version` в каждом ответе для платформы из `X-Platform`; источник — `app_settings.min_app_version`/`recommended_app_version`, иначе env; ключ `recommended_app_version` добавлен в перечень `app_settings` | 4.3 (вводная, строки `MIN_APP_VERSION`, `RECOMMENDED_APP_VERSION`, `.env.example`), 10.2, OPS-024, §19 №13 |
| §18.1 — роль БД миграций | Для `DB_MIGRATOR_PASSWORD_FILE` зафиксировано имя роли `pos_migrator` (**исправлено в волне 4** на `pos_migrate` по 07 DATA-012 — ссылка на ядро §18.1 была ошибочной, раздел 22) (владелец схемы, только `migrate`; хост/порт/БД — из `DATABASE_URL_FILE`) | 4.3, 4.4 (`migrate`, примечание 5), §19 №13 |
| §18.2 п.13 — IP-allowlist QR-вебхука | Строка `QR_WEBHOOK_ALLOWED_IPS`: обязательная проверка — в `pos-api`, фильтр `pos-proxy` — необязательный слой (трактовка 4.6/DEPLOY-050 подтверждена ядром) | 4.3, §19 №14 |
| §18.2 п.14 — пороги outbox/сверок, параметры OTP/SMS/сессий 09 §6.11 | Все перечисленные ядром имена внесены в 4.3 и `.env.example` со значениями по умолчанию (`OUTBOX_MAX_ATTEMPTS=20`, `OUTBOX_MAX_AGE_HOURS=24` — Q-176; `MANUAL_ORDER_SLA_MIN=60` — Q-119; `SYNC_COUNT_CHECK_CRON="30 3 * * *"`; параметры 09 — по 09 §6.11) | 4.3, `.env.example`, §19 №13 |
| §18.2 п.16 — номера вопросов | Собственные Q-101…Q-107 и ссылки на Q-119, Q-176, Q-141, Q-038 согласуются с ядром; изменений нумерации нет | 4.3, 17 |
| §18.2 п.1–3, 5–11, 15 | Не относятся к документу (локальная схема клиента, токены на устройстве, `deviceId`, разблокировка, `stepUpToken`, OTP `purpose`, `revoke_reason`, `provider_message_id`, коды журнала синхронизации, роли на экранах, дизайн) — изменений нет | — |
| Шапка / замечания к ядру | Версия 1.2, сверка с R0 v1.3; во входных материалах — §18 и статус владельца словаря; §19: вводная дополнена, №8 (остаток), №12, №13, №14 — закрыты | шапка, 19 |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; таблица 4.3 и все изменённые таблицы имеют одинаковое число колонок в каждой строке, символ `\|` внутри ячеек экранирован; блоки кода (yaml, caddyfile, dotenv, bash, text, mermaid) парные.

### 21.2. Сверка с ядром v1.4 (2026-10-19)

Сверка с R0 v1.4 §19 (§19 — высший приоритет), правки точечные: ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85). Ссылок на `02_screens/02x…` и меток `[УСЛОВНО: нет в 08]` в документе нет; закрытые ядром вопросы Q-204, Q-216, Q-221 в документе не упоминаются, Q-218(б) упомянут в 4.3 как «закрыт решением ядра v1.4».

| Пункт ядра | Что изменено | Где |
|---|---|---|
| §19.3 — блокировка из фона 5 мин, idle 30 мин | `AUTH_BACKGROUND_LOCK_MINUTES=5`: снята пометка «НЕ ПОДТВЕРЖДЕНО — предложение 09», добавлена `[РЕШЕНИЕ: ядро §19.3]`; `SESSION_IDLE_LOCK_MINUTES=30` — добавлена ссылка на §19.3 | 4.3 (таблица), 4.3 абзац (5) |
| §19.2 — `ONEC_SYNC_CHECK_TIMEOUT_MS` = 6000 | Значение по умолчанию 5000 → `6000`, пометка «предложение» снята; назначение уточнено (синхронная проверка при оформлении, `POST /customers/{id}/receivables/refresh`; при недоступности 1С — `202 submitting`) | 4.3 (таблица), `.env.example` |
| §19.2 — `CUSTOMER_SELF_SERVICE` только env | Описание подтверждено и дополнено: только env, не ключ `app_settings`, в UI — только чтение, публикация `features.customerSelfService` в `GET /settings/public`; доступ `customer` к SCR-21 (R0 §18.2 п.11) | 4.3 (вводная, таблица, `.env.example`) |
| §19.2 — `GET /settings/public` (Q-218(б) закрыт решением ядра v1.4) | Env-флаги `RETURNS_FROM_POS_ENABLED`, `QR_WEBHOOK_ENABLED`, `DEBT_PAYMENTS_FROM_POS`, `CUSTOMER_SELF_SERVICE` публикуются в `features{…}`; добавлен пункт 8 smoke-теста | 4.3 (вводная), 10.5 |
| §19.2 — `supportContacts`; camelCase-проекция; `sync_interval.<entity>` | В перечень ключей `app_settings` (не env) добавлен `support_contacts`; зафиксированы camelCase-проекция ключей в API (таблица — 08) и `sync_interval.<entity>` как единственная форма интервалов | 4.3 (вводная), 4.3 абзац (5) |
| §19.3 / §19.2 — FACE-SCAN | `FACE_SCAN_MODE`, `FACE_SCAN_STORE_FRAMES`, `FACE_SCAN_REQUIRED` помечены **R2**, по умолчанию `off`/`false`; в R1 `RegistrationStepper` — 3 шага без FACE-SCAN | 4.3 (таблица, `.env.example`) |
| §19.2 «Не в R1 (R2)» — пауза сущности, пометка ошибки синхронизации решённой (Q-219) | Метки `[НОВОЕ ИМЯ]` у `POST /sync/pause`, `POST /sync/resume`, поля `paused`, `POST /sync/runs/{id}/errors/{errorId}/skip` удалены вместе с операциями; в R1 — `docker compose stop/up worker` и `POST /sync/outbox/{id}/retry`; операции API отнесены к R2 | 10.3 (шаги 2, 8), 15.2, §19 №11 |
| §19.4 — повтор outbox для `admin` без step-up | Упомянуто в runbook вместе с правом `senior_seller` своего магазина (R0 §18.2 п.11) | 15.2 |
| §19.1, §19.2 (прочие эндпоинты и DTO), §19.4 (прочее), §19.5 | Не относятся к документу (экраны, ARB, DTO, POS-правила, диапазоны вопросов: собственные Q-101…Q-107 вне новых диапазонов) — изменений нет | — |
| Шапка / замечания к ядру | Версия 1.3, сверка с R0 v1.4; во входных материалах — §19 (высший приоритет); §19: вводная дополнена, №11 закрыт | шапка, 19 |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; изменённые таблицы (4.3, 10.3, 15.2, 19, 21.2) имеют одинаковое число колонок в каждой строке, символ `\|` внутри ячеек экранирован; блоки кода (yaml, caddyfile, dotenv, bash, text, mermaid) парные.

### 21.3. Сверка с ядром v1.6 (§21) и v1.7 (§22) (2026-10-19)

Сверка с R0 v1.6 §21 и v1.7 §22 (§22 — высший приоритет), правки точечные: существующие ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85); изменены DEPLOY-036, DEPLOY-050, OPS-008, строка H-15. Документ не является владельцем ни одного пункта §22: пересказ правил заменён краткими формулировками, совпадающими с ядром, и ссылками на владельцев (07, 08, 10, 05, 11). Как владелец словаря переменных окружения (ядро §18.1) документ внёс в 4.3 три имени других документов. Учтены открытые замечания повторной проверки волны 4, относящиеся к 16: C-2 без ручного запуска (#20), allow-list ONEC-060 (#14а), порог и график outbox (#18), `SYNC_ALERT_UNREACHABLE_MIN` (#19), шаг `server_epoch` в runbook restore (#1 к 05 F16), `RETURNS_FROM_POS_ENABLED` (Q-018).

| Пункт ядра | Что изменено | Где |
|---|---|---|
| v1.6 §21 п.1 — заявка на возврат must, `RETURNS_FROM_POS_ENABLED` — только outbox | Строка `RETURNS_FROM_POS_ENABLED`: только передача заявок в 1С через outbox `return_request`; `false` по умолчанию до подтверждения 1С (Q-012/Q-018); при `false` — `submitted`, печать и ручное оформление в 1С, `partially_returned` из 1С; сценарий возврата включает `app_settings.returns_enabled` (публикуется как `features.returnsFromPos`, 10.5 п.8 — без изменений); правило — 10 RET-012 | 4.3 (таблица, абзац (6)), `.env.example` |
| v1.7 §22.1 — автомат `onec_outbox`, пороги 20 / 24 ч, backoff | `OUTBOX_MAX_ATTEMPTS`/`OUTBOX_MAX_AGE_HOURS`: значения `20`/`24` помечены `[РЕШЕНИЕ: ядро §22.1]` (вместо «НЕ ПОДТВЕРЖДЕНО»; уточнение — Q-176), назначение — только временные ошибки; график 1, 2, 5, 15, 60 мин — константа, переменной окружения нет (§22.13 п.7); `SYNC_COUNT_CHECK_CRON` — также добор `sent → confirmed`; runbooks проверяют статусы по автомату (`pending`/`sending`/`failed`/`dead`, затем `sent` → `confirmed`); автомат — 07 §6.5, обработка — 05 §8 | 4.3, `.env.example`, 8.5 шаг 8, 15.1, 15.2 |
| v1.7 §22.3 — `POST /orders` без синхронной записи в 1С | `ONEC_SYNC_CHECK_TIMEOUT_MS`: при истечении — `202` с `warnings[STALE_DATA]`, заказ `submitting`, документ создаёт воркер; smoke 10.5 п.6: `201`/`202` → `submitting` → `sent` → `pending_approval`; 12.3 и 15.1 — `202` с `STALE_DATA` (владелец — 08 §4.8.1) | 4.3, 10.5, 12.3, 15.1 |
| v1.7 §22.4 — решение о продаже в долг | Формулировка «fail-closed» заменена порядком ядра со ссылкой на владельца 10 PAY-031: свежий полный снимок без блокировок — долг без обращения к 1С (и в C-2); устаревший/неполный снимок при недоступной 1С или в C-2 — `422 RECEIVABLES_STALE`; `503 ONEC_UNAVAILABLE` для `credit` не возвращается | 4.3 (`RECEIVABLES_MAX_AGE_MIN`), 12.3, 15.1 |
| v1.7 §22.8 — обмен с 1С; ручной запуск в C-2 недоступен | 12.3 «Ограничения» переписан: `POST /sync/runs` → `422 VALIDATION_FAILED` (`rule: inbound_mode`), кнопка SCR-43 неактивна (05 SYNC-025, 08 §4.17.2, 11 §4.3.1); механизм `requests[]` не вводится; `/order-status` — сырые статусы, проекция в backend; ссылка «поведение определяет 08» заменена решением ядра; то же — в `ONEC_INBOUND_ENABLED`, DEPLOY-036 (+AC), 8.5 шаг 8, 15.1, 15.2; замечание к ядру №15 частично закрыто | 4.3, 12.3, 8.5, 15.1, 15.2, 16.1, 19 |
| 05 ONEC-060 (сведение v1.7) — allow-list входящего обмена | Новая переменная `ONEC_INBOUND_ALLOWED_IPS`: обязательная проверка в `pos-api`, пустой список при `ONEC_INBOUND_ENABLED=true` — отказ в старте; фильтр `remote_ip` в Caddy — необязательный слой, правила доступа в proxy не требуются (H-15, DEPLOY-049 без изменения смысла); 4.6 (столбцы «Allowlist IP», «Секреты / переменные»), 12.3 «Авторизация», Caddyfile (плейсхолдер), DEPLOY-036 (+AC), DEPLOY-050, граница R1/R2 | 3.3, 4.3, 4.5, 4.6, 7 (H-15), 12.3, 16.1 |
| v1.7 §22.10 — одна торговая точка | 15.2: «`senior_seller` своего магазина» заменено на «`admin` и `senior_seller` — все элементы outbox, фильтров „свой магазин“ в R1 нет» | 15.2 |
| v1.7 §22.11 — возвраты | В строке `RETURNS_FROM_POS_ENABLED`: при `false` согласование `accepted` — старшим в POS (правило — 10 RET) | 4.3 |
| v1.7 §22.12 — привязка клиента | `CUSTOMER_SELF_SERVICE` также разрешает `customer.link.self_resolve`; подтверждение сотрудником — только `admin` (правило — 11, эндпоинты — 08 §4.2.4) | 4.3 |
| v1.7 §22.13 п.5 — правило утверждения ТЗ | Предусловия раздела 14: точная фраза — единственное разрешение этапа 2; блокирующие вопросы 14 §2 не являются условием утверждения (вопросы раздела блокируют шаги развёртывания) | 14 |
| 05 SYNC-038 — `SYNC_ALERT_UNREACHABLE_MIN` | Внесена в 4.3 (`10` мин, алерт ≤ 15 мин) и `.env.example`; 15.1 «Симптом» | 4.3, 15.1 |
| 05 F16/SYNC-063 — `server_epoch` после restore | 8.5 шаг 7 (новая эпоха до запуска `api`), шаг 8 (reconcile зеркала заказов), 15.3, OPS-008 (+AC); контракт заголовка/хранения отсутствует в 08/07 — замечание к ядру №17 | 8.5, 15.3, 16.2, 19 |
| 09 §5.8 — `SMS_STAGING_ALLOWED_PHONES` | Внесена в 4.3 (только `staging`), группа «условные» границы R1/R2, комментарий в `.env.example` | 4.3 |
| v1.7 §22.2, §22.5, §22.6, §22.7, §22.9, §22.13 п.1–4, 6 | Не относятся к развёртыванию (автомат платежа, приём оплаты, ключи идемпотентности, API офлайн-кэша, отмена заказа, поиск, аварийный код, отчёты, хэш-цепочка, чертежи) — изменений нет | — |
| Шапка, входные материалы, вводная 4.3, замечания к ядру | Версия 1.6; во входных материалах — v1.7 §22; вводная 4.3 — ссылка на v1.6/v1.7; §19: вводная, №15, новые №17–№18 | шапка, 4.3, 19 |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; изменённые таблицы (4.3, 4.6, 7, 12.3, 15.1, 15.2, 15.3, 16.1, 16.2, 19, 21.3) имеют одинаковое число колонок в каждой строке, символ `\|` внутри ячеек экранирован; блоки кода (yaml, caddyfile, dotenv, bash, cron, mermaid) парные; в `sequenceDiagram` 12.2 символы «;» в тексте сообщений заменены запятыми (Mermaid трактует «;» как разделитель операторов).

### 21.4. Сверка с ядром v1.8 (§23) (2026-10-19)

Сверка с R0 v1.8 §23 (высший приоритет) и с уже выровненными владельцами 05, 07, 08, 10, 11; правки точечные: существующие ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85). Документ не является владельцем ни одного пункта §23: правила не пересказываются, даны ссылки на владельцев. Новых переменных окружения §23 не вводит — словарь 4.3 не менялся. Замечания итоговой проверки по этому документу имеют пометку [left-by-author] и относятся к ядру или другим документам (`server_epoch` — 08, 07, 11, 12; C-3 и имена словаря — ядро; 04, 10, 13, 08, 11, 12 — их владельцы): в 16 они уже отражены в разделе 19 и здесь не правились.

| Пункт ядра | Что изменено | Где |
|---|---|---|
| v1.8 §23 п.1 — ручная привязка `onec-link`: `pending`/`failed`/`dead` → `sent` | Сверка outbox после восстановления: существующий в 1С документ (в том числе `ORDER_MATCH_AMBIGUOUS`) привязывается `POST /orders/{id}/onec-link` (`senior_seller`/`admin`/`owner`, step-up, аудит `order.onec_linked`; далее `sent → confirmed`), а не повтором и не отменой; повтор `POST /sync/outbox/{id}/retry` — только если документа в 1С нет; то же в runbook 15.2 и проверке 15.3 (автомат — 07 §6.5, 05 §8; контракт — 08) | 8.5 шаг 8, 15.2, 15.3 |
| v1.8 §23 п.2 — проекция статуса заказа в момент `sent` | Smoke 10.5 п.6: при переходе outbox в `sent` заказ получает номер 1С и проецируется по 10 §2.2 (P8: неоплаченный `cash`/`qr_bakai` → `awaiting_payment`; P9: `credit` или оплаченный → `pending_approval`); `confirmed` повторной проекции не требует (вместо «после проекции — `pending_approval`») | 10.5 |
| v1.8 §23 п.3–п.10 | Не относятся к развёртыванию (смена способа оплаты, поздняя оплата QR, отказы в долге, `order.cancel.own`, дашборд кассира, экраны SCR-39/SCR-45, вопросы Q-168/Q-264, статистика 00/README) — изменений нет; в документе нет упоминаний `order.cancel.own_draft`, `review_reason`, `creditReason` | — |
| Замечания итоговой проверки [left-by-author] №1–№5 | Без правок текста: №1 (`server_epoch`) — замечание к ядру №17, открыто; №2 (C-3) — №15, открыто; №3 (имена словаря) — №18, открыто; №4 — правки других документов (04, 10, 13, 08, 11, 12); №5 — №2, №6, №10, открыты. Вводная раздела 19 дополнена итогом сверки v1.8 | 19 |
| Шапка, входные материалы | Версия 1.7; во входных материалах — v1.8 §23 | шапка |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; изменённые таблицы (15.2, 15.3, 21.4) имеют одинаковое число колонок в каждой строке; блоки кода закрыты; новых Mermaid-диаграмм нет.

## 22. Журнал независимой проверки (волна 4)

Независимая проверка (агент 8, 2026-10-19): 11 замечаний (critical — 0, major — 6, minor — 5). Правки точечные: ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85); новые имена словаря 4.3 — `ONEC_ODATA_WRITE_USER_FILE`, `ONEC_ODATA_WRITE_PASSWORD_FILE` (по 05 ONEC-028, владелец словаря — 16, R0 §18.1). Правки других документов, необходимые для полного закрытия, перечислены в последнем столбце как «передано» (этот документ их не вносит).

| Замечание | Линза | Действие |
|---|---|---|
| 1 (major). §12.1/§12.5 P-4: один пользователь ИБ `pos_integration` с ролями OData и HTTP-сервиса — противоречит 05 ONEC-052/ONEC-082, 4.3 и D-28 | onec | **Исправлено.** 12.1 «Пользователи ИБ» и P-4 переписаны: `pos_integration` — только OData, только чтение (allow-list, ONEC-083); `pos_hs` — только `POS_ИнтеграцияPOS`, без OData и прямой записи; `pos_odata_write` — только режим ONEC-028; ссылки на секреты 4.3. В 4.3 уточнена строка `ONEC_USER_FILE`, добавлена строка `ONEC_ODATA_WRITE_USER_FILE`/`ONEC_ODATA_WRITE_PASSWORD_FILE` (только `worker`, только при `ONEC_ODATA_WRITE_ENABLED=true`); compose (4.4) — закомментированные указатели и секреты; DEPLOY-013 и 1 п.4 выровнены |
| 2 (major). §12.3: «флаг запросить при следующем вызове 1С» не существует в контракте 05 §10.1; ручной запуск и `full`/`reconcile` в C-2 нереализуемы | onec | **Исправлено в 16 / передано в 05, 08.** Выдуманный механизм удалён; 12.3 «Ограничения» описывает фактическое поведение R1: `POST /sync/runs` в C-2 обмен не инициирует, срез/сверку запускает 1С-специалист (runbook 15.2 и 8.5 шаг 8 дополнены). Предложение для 05 §10.1 (поле `requests[]` `[НОВОЕ ИМЯ]` в ответе `/ping`) и 08 §4.17.2 (ответ `POST /sync/runs` при `ONEC_INBOUND_ENABLED=true`) — передано владельцам; замечание к ядру №15 |
| 3 (minor). «C-3» не определён; mTLS «допустимое усиление» против 05 ONEC-060; 12.4 п.4 без `ONEC_INBOUND_ENABLED`; нет валидации `odata_only` + inbound | onec | **Исправлено, в части (1) отклонено.** C-3 определён в 3.3 (гибрид) — утверждение «нигде не определён» неверно; но C-3 несовместим с 05 ONEC-065, поэтому помечен «вне R1» и убран из описаний `ONEC_INBOUND_ENABLED` (4.3, `.env.example`, 4.6); замечание к ядру №15. mTLS приведён к ONEC-060 («в R1 не используется») в 3.3, 12.3, DEPLOY-036. 12.4 п.4 — `ONEC_MODE`, `ONEC_BASE_URL`, `ONEC_INBOUND_ENABLED`. Валидация старта (строка `ONEC_MODE` 4.3, DEPLOY-036 + AC): `ONEC_INBOUND_ENABLED=true` только при `ONEC_MODE=extension`, `ONEC_ODATA_WRITE_ENABLED=true` только при `odata_only` |
| 4 (major). Постоянный plaintext `latest.dump` нарушает 11 SEC-110 / AC-SEC-110 | privacy | **Исправлено.** Шаг 4a скрипта 8.3 — удаление plaintext сразу после шифрования + `trap … EXIT` (удаление и при сбое) + очистка остатков `*.dump`; пояснения, 8.1 (RTO включает доставку ключа `age`, Q-106), 8.5 шаг 2, OPS-001 и AC-OPS-001 (`find … -name '*.dump' -mmin +60` пусто) выровнены. Исключение из SEC-110 допускается только по решению заказчика (Q-033 + ADR в 15, остаточный риск в 11 §2.3, LUKS, SEC-117/PRIV-011). Следствие: `restore_drill.sh` больше не в cron — запускает держатель ключа (8.4, 8.5, OPS-007), пропуск ловит проверка Healthchecks |
| 5 (major). Зарубежные Healthchecks.io и Telegram по умолчанию; нет запрета ПДн в алертах; DEPLOY-048 — should против PRIV-001 must | privacy | **Исправлено в 16 / передано в 11, 12.** 1 п.3, 2.4 A-6, 6.3 №11, раздел 9 (внешняя доступность, cron-задачи, каналы, mermaid), OPS-015, Q-103: по умолчанию self-hosted Healthchecks + Uptime Kuma на хосте в КР, алерты — e-mail через почтовый сервер в КР; Telegram/SaaS — только после ADR по 6 пунктам PRIV-020. Добавлена строка раздела 9 «Содержимое алертов» (только коды, счётчики, `requestId`/`runId`; без телефонов, IP, `userId`, ФИО, сумм). DEPLOY-048 → **must** (реализация PRIV-001), AC дополнен; H-5 — allow-list исходящих хостов. Передано: 11 §6.2 (правило содержимого алертов), 12 T-SEC-047 (перечень разрешённых хостов: монитор, ACME, почта), 12 T-DEPLOY-020 (приоритет must) |
| 6 (minor). Три разных состава `/health`, `/health/ready` (16, 08, 11 SEC-019) | privacy | **Исправлено в 16 / передано в 08.** Канон — 11 SEC-019: `/health` — только `status`, `minAppVersion`; `/health/ready` — только `status`, `db`, `queue`, `syncAgeOk`, `lastSuccessfulSyncAt` (раздел 9, DEPLOY-038 + AC). Проверка версии релиза перенесена на хост (10.5 п.1, AC-OPS-018: `docker compose images`, стартовый лог). Передано: 08 §4.19.1 и API-120 (убрать `apiVersion`, `checks.onec`, `checks.sms`, `stockAgeSec` из публичных ответов; подробности — `/sync/status`) |
| 7 (minor). `rclone sync` несовместим с учётной записью «без удаления и перезаписи» 11 SEC-111 | privacy | **Исправлено.** Шаг 6 скрипта 8.3: только `rclone copy --immutable` (БД, фото); `caddy_data` — в каталог с датой; удаление и ротация — политикой жизненного цикла хранилища. 8.1 «Хранение», 8.2 «Фото», пояснения, 8.5 шаг 6, OPS-002 + AC (`rclone check --one-way`, отсутствие `sync`/`move`/`delete`, `rclone delete` → отказ) выровнены |
| 8 (minor). `SMSPRO_TEST_FLAG=true` в prod — алерт (4.3, 9) против OPS-027 «отказ старта» | privacy | **Исправлено в 16 / передано в 11.** Выбран отказ в старте: 4.3, `.env.example`, раздел 9 (SMSPro), OPS-027 (явный перечень тестовых флагов, включая условия 11 SEC-056) + AC. Передано: внести `SMSPRO_TEST_FLAG=true`, `ONEC_MODE=fixtures`, `OPENAPI_PUBLIC=true` в стоп-список 11 SEC-056 и AC-SEC-056 |
| 9 (major). Caddyfile: HSTS `31536000`, `Referrer-Policy: no-referrer`, нет CSP `frame-ancestors` и удаления `X-Powered-By` | facts | **Исправлено.** Блок `header` 4.5: `max-age=63072000; includeSubDomains` (без `preload` до Q-032), `Referrer-Policy: strict-origin-when-cross-origin`, `Content-Security-Policy: frame-ancestors 'none'`, `-X-Powered-By` (11 SEC-003/SEC-018, 08 §2/API-033, R6 §7.2); H-8 дополнен. Попутно: 11 SEC-018 задаёт для `/images/*` `max-age=86400`, а 08 §2.8/§4.4.7 и 4.5 — `31536000` — передано в 11 |
| 10 (minor). §4.3: переменные R2 и условные попадают в `.env.example` R1 | scope | **Исправлено.** Добавлен абзац «Граница R1 / R2 для конфигурации» после `.env.example`: группа «R2 и условные» (`FACE_SCAN_*`, `CORS_ALLOWED_ORIGINS`, `SMSPRO_DLR_ALLOWED_IPS`, `QR_WEBHOOK_ALLOWED_IPS`/`_SECRET_FILE`/`_PUBLIC_KEY_FILE`, `SMSPRO_OTP_API_KEY_FILE`, `ONEC_ODATA_WRITE_*_FILE`) исключена из R1-примера и валидируется только при включённом флаге-родителе; правило полноты DEPLOY-014 уточнено. Таблица 4.3 остаётся единым словарём (R0 §18.1 — владелец обязан содержать каждую переменную), поэтому физическое разделение таблицы не выполнялось. `QR_WEBHOOK_ENABLED` оставлен в примере (публикуется в `features`, 10.5 п.8) |
| 11 (major). Роль DDL: 07 `pos_migrate` против 16 `pos_migrator` с ложной ссылкой на ядро §18.1 | ids | **Исправлено.** По владельцу схемы прав (07 §2.2, DATA-012) — `pos_migrate`: 4.3 (`DB_MIGRATOR_PASSWORD_FILE`, ложная ссылка на §18.1 удалена), 4.4 (`migrate`, примечание 5); в 4.3 рабочая роль названа `pos_app`; исторические записи 19 №13 и 21.1 помечены. Замечание к ядру №16 (словарь ролей БД). Передано: 16 использует для `pg_dump` суперпользователя образа (`POSTGRES_USER`), а 07 вводит роль `pos_backup` — согласовать в 07/16 на этапе 2 |
| Попутно (самопроверка) | consistency | 10.5 п.5–6 и Q-012 выровнены с ядром §20.2 п.6 (prod-smoke без мутаций: в проде — только `GET /sync/status`, заказы запрещены); DEPLOY-013 — токены роли `integration` не хранятся в `secrets/` (R0 §18.2 п.4) |

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; изменённые таблицы (4.3, 8.1, 8.2, 9, 12.1, 12.3, 12.5, 15.2, 16.1, 16.2, 17.1, 17.2, 19, 22) имеют одинаковое число колонок в каждой строке, символ `\|` внутри ячеек экранирован; блоки кода (yaml, caddyfile, dotenv, bash, cron, mermaid) парные.

### 22.1. Доработка по замечанию волны 4 к §10 (дистрибуция, `MIN_APP_VERSION`, prod-smoke)

Независимая проверка (агент 8, 2026-10-19): 1 замечание (major). Правки точечные: ID требований не менялись, новых требований нет (итог — 50 DEPLOY + 35 OPS = 85); добавлены подразделы 10.7–10.9 (нумерация существующих подразделов сохранена).

| Замечание | Линза | Действие |
|---|---|---|
| (major) §10: нет процедуры установки Windows-сборки из zip администратором (ядро §20.2 п.13), регламента изменения `MIN_APP_VERSION` (п.14) и состава prod-smoke без мутаций (п.6) | known | **Исправлено.** Новый **10.7** — установка/обновление zip-архива: ответственные (DevOps исполнителя, администратор ПК заказчика — не роль `admin` приложения, сотрудник для проверки входа), 11 шагов (передача архива и SHA-256 разными путями, `Get-FileHash`, `Unblock-File`, остановка вне продажи, распаковка в `Program Files\OptomstroyPOS\<version>`, VC++ runtime, общий ярлык, проверка под общим аккаунтом ОС — Q-034, журнал установок, хранение N−1) и откат клиента. Новый **10.8** — регламент `min_app_version`: где хранится (ключ `app_settings`, SCR-46, step-up, аудит; env — только значение по умолчанию), 4 ограничения (не выше N−1 30 дней с выпуска N; не выше розданной версии; по одной платформе; понижение — всегда), 8 шагов с ответственными (план → баннер → раздача → предпроверка по журналу установок и агрегату `X-App-Version` без ПДн → изменение `admin` → контроль → выравнивание env → журнал), возврат, досрочное повышение — только по решению заказчика + ADR (остаток Q-133). Новый **10.9** — prod-smoke: исчерпывающий перечень 11 SEC-129 (6 шагов: `/health`, `/health/ready`, OTP-вход технического сотрудника с ролью `seller` на внутренний номер с письменным согласием + `POST /auth/logout`, чтение каталога, `GET /sync/status`, `POST /api/info` SMSPro), проверки на хосте, счётчики бизнес-таблиц до/после, запреты, протокол. Попутно выровнены: 10.2 «Порядок обновления» (zip вместо «MSIX или zip [НЕ ПОДТВЕРЖДЕНО]», «≥ 1 неделя» → правило 30 дней), 10.3 шаг 7 и 8.5 шаг 7 (в проде — 10.9), 10.5 (объявлен набором тестового контура, 12 T-OPS-014; п.3 без «реальной SMS на номер DevOps»), 10.6, 14.1 шаг 9, OPS-023 + AC, OPS-024 + AC («через неделю» → регламент 10.8), DEPLOY-044 AC (zip + `SHA256SUMS`), 17.1 Q-008, Q-012, Q-133 |
| Попутно (сверка с ядром v1.6 §21 п.1) | known | 10.5 п.8: `features.returnsFromPos` = `app_settings.returns_enabled` (не `RETURNS_FROM_POS_ENABLED`); 4.3 — вводный абзац, строка `RETURNS_FROM_POS_ENABLED` («только outbox в 1С»), `.env.example`; 17.1 Q-018 — «частично закрыт решением ядра v1.6» |

Передано владельцам (этот документ их не правит): 12 T-OPS-024 — перечень таблиц-счётчиков (в 07 нет таблицы `outbox`; использовать `onec_outbox`, `cart_items`, `return_requests`), шаг `POST /auth/logout`, роль технического сотрудника `seller`, исключение «низкий баланс SMSPro — не откат»; 12 T-OPS-014 — шаги 10.5 выполняются только на E3 (адрес `api-test.<домен>`); 11 SEC-129 — уточнить, что закрытие сессии `POST /auth/logout` входит в п.(3); 12 T-BUILD-005 / 13 RM-H-007 — файл `SHA256SUMS` и имя архива `optomstroy-pos-windows-<version>.zip` в составе артефакта; 02 SCR-46 — подсказка у `min_app_version` о правиле 30 дней (10.8).

Проверка целостности после правок: файл дочитывается до строки «Конец документа»; новые и изменённые таблицы (10.2, 10.3, 10.7, 10.8, 10.9, 4.3, 14.1, 16.1, 16.2, 17.1, 22.1) имеют одинаковое число колонок в каждой строке; блоки кода парные.

Конец документа.
