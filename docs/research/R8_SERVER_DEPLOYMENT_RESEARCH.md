# R8. Исследование: размещение backend «Оптомстрой» на сервере заказчика, развёртывание и эксплуатация

**Роль:** DevOps / инфраструктурный инженер (поддержка Главного архитектора)
**Этап:** 1 — исследование и подготовка ТЗ. Ничего не устанавливалось и не запускалось; документ — только план.
**Дата:** 2026-10-18
**Статус исходных данных:** доступ к серверу заказчика НЕ предоставлен, характеристики НЕИЗВЕСТНЫ. Все утверждения о сервере заказчика — [НЕ ПОДТВЕРЖДЕНО] до выполнения чек-листа из раздела 1.

Легенда статусов:
- **[ПОДТВЕРЖДЕНО: источник]** — проверено по официальной документации (URL, дата обращения 2026-10-18) или по команде.
- **[ТИПОВО: контекст, требует проверки]** — верно для типовых конфигураций/версий, нужно подтвердить у заказчика.
- **[НЕ ПОДТВЕРЖДЕНО]** — предположение/оценка.

Сокращения: API — серверное приложение (backend) «Оптомстрой»; БД — PostgreSQL; RP — reverse-proxy (Caddy или Nginx); 1С — существующая учётная система магазина.

---

## 0. Резюме для Главного архитектора

1. Пока нет результата аудита (раздел 1), выбрать сценарий размещения нельзя. Решение принимается по дереву в разделе 2.5.
2. Предпочтительный целевой вариант при прочих равных — **сценарий A** (Linux + Docker Compose: `api` + `postgres` + `caddy`) либо **сценарий C-2** («исходящий» обмен: 1С сама обращается к backend по HTTPS, без входящих портов в магазин). Если сервер заказчика — Windows Server с 1С, то **сценарий B-3** (отдельная Linux-VM на том же железе) безопаснее, чем Docker Desktop/WSL2 (Docker Desktop официально не поддерживается на Windows Server [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/]).
3. Минимальные ресурсы Release 1 (оценка, раздел 3): 2 vCPU / 4 GB RAM / 80 GB SSD; рекомендуемые: 4 vCPU / 8 GB RAM / 160 GB SSD + отдельное хранилище бэкапов вне сервера. Объём фото — главная неизвестная величина.
4. Обязательные требования безопасности (раздел 5): БД не публикуется наружу; SSH только по ключам; секреты вне репозитория; HTTPS с авто-продлением; минимальные права.
5. Бэкапы (раздел 6): `pg_dump -Fc` ежедневно, хранение 30 дней, копия вне сервера, ежемесячная проверка восстановления. Целевые RPO ≤ 24 ч (R1), RTO ≤ 4 ч — требуют согласования.
6. Список того, что нужно согласовать с заказчиком до любого развёртывания — раздел 4.3.

---

## 1. Чек-лист аудита сервера (выполняет заказчик/его админ, результаты присылаются текстом)

Правила:
- Все команды **только читают** состояние; ничего не меняют. Исключение — тест скорости диска (1.1.19), его выполнять только с согласия и только на свободном месте.
- Вывод команд может содержать IP-адреса, имена пользователей и имена баз; это нормально, но **не присылайте пароли, содержимое `.env`, ключи и строки подключения**.
- Результаты сохранять в текстовый файл: Linux — `script -q audit.txt` перед началом, `exit` в конце; Windows — `Start-Transcript -Path C:\audit.txt` / `Stop-Transcript`.

### 1.1. Linux

| # | Зачем | Команда | Как прочитать результат | Что считать проблемой |
|---|---|---|---|---|
| 1 | Ядро и архитектура | `uname -a` | `x86_64` — обычный сервер; `aarch64` — ARM (образы Docker нужны multi-arch). Версия ядра. | Ядро старше 5.x — инженерный порог для комфортной работы Docker Engine/overlay2 и современного PostgreSQL [НЕ ПОДТВЕРЖДЕНО — инженерный порог, формально Docker работает и на более старых ядрах]; 32-битная система (`i686`) — Docker Engine не поддерживается (пакеты только для x86_64/arm64/armhf/ppc64le/s390x) [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/]. |
| 2 | Дистрибутив и версия | `cat /etc/os-release` | `PRETTY_NAME`, `VERSION_ID`. | Ubuntu < 22.04, Debian < 12, CentOS Linux 7/8 — ОС без обновлений безопасности. CentOS Linux 8 — EOL 2021-12-31 [ПОДТВЕРЖДЕНО: https://www.centos.org/centos-linux-eol/]; CentOS Linux 7 — EOL 2024-06-30 [ПОДТВЕРЖДЕНО: https://www.redhat.com/en/topics/linux/centos-linux-eol]. Сроки: Ubuntu 22.04 LTS поддерживается до мая 2027, 24.04 — до мая 2029, 26.04 — до мая 2031 [ПОДТВЕРЖДЕНО: https://ubuntu.com/about/release-cycle]; Debian 13 «trixie» — stable с 2025-08-09, Debian 12 «bookworm» — oldstable [ПОДТВЕРЖДЕНО: https://www.debian.org/releases/]. |
| 3 | Процессор | `lscpu` | `Model name`, `CPU(s)`, `Thread(s) per core`, `Virtualization`/`Hypervisor vendor` (физический сервер или VM). | < 2 ядер [НЕ ПОДТВЕРЖДЕНО — инженерный порог]; виртуализация без поддержки вложенной — нельзя поднять VM внутри (актуально для B-3). Отсутствие AVX для выбранного стека (PostgreSQL, Caddy/Nginx, рантайм `api`) не критично; важно лишь для отдельных продуктов (например, MongoDB ≥ 5), которые в стеке не планируются [ТИПОВО]. |
| 4 | Число логических CPU | `nproc` | Число. | < 2. |
| 5 | Память | `free -h` | Строка `Mem:` → `total` (всего), `available` (реально свободно). `Swap:`. | `available` < 2 GB при текущей нагрузке; `total` < 4 GB; swap = 0 на машине с < 8 GB. |
| 6 | Диски и ФС | `df -hT` | Для `/` и `/var` (там живут Docker и БД): `Size`, `Avail`, `Use%`, тип ФС (`ext4`, `xfs`). | `Avail` < 40 GB; `Use%` > 80 %; ФС `vfat`/`ntfs` для данных. |
| 7 | Физические диски | `lsblk -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT,MODEL` | `ROTA=1` — HDD (вращающийся), `ROTA=0` — SSD/NVMe. | Данные БД на HDD (`ROTA=1`) — медленно для поиска по 50k SKU; единственный диск без RAID/бэкапа. |
| 8 | Сетевые интерфейсы и адреса | `ip a` | Интерфейсы (`eth0`, `ens…`), адреса `inet`. Адреса `10.x`, `192.168.x`, `172.16–31.x` — локальная сеть; иной — возможно публичный. | Сервер только в локальной сети без публичного IP → нужен VPN или сценарий C. |
| 9 | Публичный IP | `curl -4 -s https://ifconfig.me ; echo` (или `https://api.ipify.org`) | Внешний адрес, через который сервер выходит в интернет. Сравнить с 1.1.8: если совпадает — у сервера прямой публичный IP; если нет — сервер за NAT. | За NAT без проброса портов → входящий HTTPS невозможен без согласования с провайдером/роутером. |
| 10 | Занятые порты | `ss -tulpn` (или `netstat -tulpn`) | Колонка `Local Address:Port` — какие порты слушаются, `Process` — кем. `0.0.0.0:` — слушает на всех интерфейсах, `127.0.0.1:` — только локально. | Заняты 80/443 (конфликт с RP — потребуется согласование); 5432 открыт на `0.0.0.0` (чужая БД торчит наружу — сообщить владельцу); 1540/1541/1560–1591 — типовые порты кластера 1С [ТИПОВО: статьи Infostart, не официальная документация; https://infostart.ru/1c/articles/377023/ — страница не открылась при проверке 2026-10-18 (HTTP 429), содержимое не верифицировано; 1С-эксперту подтвердить порты по официальному руководству администратора на its.1c.ru при наличии доступа]. |
| 11 | Запущенные службы | `systemctl list-units --type=service --state=running` | Список служб: `nginx`, `apache2`/`httpd`, `postgresql`, `docker`, `srv1cv8*` (сервер 1С), `mysql`, и т.п. | Любая служба, с которой придётся делить порты/ресурсы. |
| 12 | Docker | `docker --version ; docker compose version ; docker ps ; docker system df` | Версия Engine и Compose v2; запущенные контейнеры; занятое место. `command not found` — Docker не установлен (это нормально). | Docker Compose v1 (`docker-compose`, Python) — устарел; `docker system df` > 50 % диска. |
| 13 | Веб-серверы и их конфиги | `ls -la /etc/nginx /etc/nginx/sites-enabled /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null` | Какие сайты/публикации уже есть (возможно — публикация 1С на Apache). | Публикация 1С на 80/443 того же хоста — нужны отдельный поддомен и согласованный способ сосуществования. |
| 14 | Firewall | `sudo ufw status verbose` ; `sudo iptables -S` ; `sudo nft list ruleset` | `Status: active` и правила `ALLOW`. Пустой вывод `iptables -S` кроме `-P … ACCEPT` — файрвола нет. | Файрвола нет вообще; политика `ACCEPT` на всё; открыт 22 для всего мира без fail2ban. |
| 15 | Планировщик | `crontab -l ; sudo ls -la /etc/cron.d /etc/cron.daily ; systemctl list-timers` | Существующие задания (бэкапы, выгрузки 1С, обновления). | Нет ни одного бэкап-задания; задания, пишущие в те же каталоги. |
| 16 | Монтирование | `cat /etc/fstab` | Какие диски/сетевые папки монтируются при загрузке (`nfs`, `cifs` — сетевые). | Данные на сетевой папке `cifs`/`nfs` — не подходит для БД. |
| 17 | Аптайм и нагрузка | `uptime` | `up N days` и `load average: a, b, c` (за 1/5/15 мин). Load сравнивать с числом CPU из 1.1.4. | Load average стабильно > числа CPU — сервер перегружен. Аптайм > 365 дней — ядро давно не обновлялось. |
| 18 | Ошибки ядра/железа | `sudo dmesg -T \| tail -n 100` ; `sudo journalctl -p err -b \| tail -n 50` | Сообщения об ошибках: `I/O error`, `EXT4-fs error`, `Out of memory`, `MCE`. | Ошибки диска/памяти — железо ненадёжно. |
| 19 | Скорость диска (ОСТОРОЖНО, только в пустой каталог, с согласия) | `cd /var/tmp && dd if=/dev/zero of=./ddtest bs=1M count=1024 oflag=direct status=progress ; rm -f ./ddtest` ; лучше (только если `fio` уже установлен — аудит ничего не устанавливает, иначе ограничиться `dd`) `fio --name=rnd --ioengine=libaio --rw=randrw --bs=4k --size=512m --numjobs=1 --iodepth=16 --direct=1 --runtime=20 --time_based --filename=/var/tmp/fiotest ; rm -f /var/tmp/fiotest` | `dd`: МБ/с последовательной записи. `fio`: IOPS чтения/записи. `--ioengine=libaio` обязателен: с движком по умолчанию (`psync`) параметр `--iodepth` не действует и IOPS занижаются [ТИПОВО: документация fio, параметр `ioengine`]. | Последовательная запись < 100 MB/s или случайные 4k IOPS < 2 000 — HDD/медленный диск; для БД желателен SSD. **Не запускать `dd` с `of=/dev/sdX`** — это уничтожит диск. |
| 20 | Существующие бэкапы | `ls -la /var/backups /backup /mnt 2>/dev/null` | Есть ли куда-либо регулярные копии. | Бэкапов нет или они на том же диске. |
| 21 | Имя хоста и DNS | `hostname -f` ; `dig +short A <домен-заказчика>` ; `nslookup <домен>` ; `cat /etc/resolv.conf` | FQDN сервера; на какой IP указывает домен; какие DNS используются. | Домена нет или он указывает на другой сервер (например, на сайт магазина). |
| 22 | PostgreSQL, если есть | `psql --version ; sudo -u postgres psql -c "select version();" ; sudo ss -tlnp \| grep 5432 ; sudo -u postgres psql -c "show listen_addresses;" ; sudo -u postgres psql -c "show data_directory;"` | Версия; на каком адресе слушает; где данные. По умолчанию `listen_addresses = 'localhost'`, `max_connections = 100` [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/runtime-config-connection.html]. | Версия ≤ 14 (PostgreSQL 14 EOL 2026-11-12; 15 — 2027-11-11; 16 — 2028-11-09; 17 — 2029-11-08; 18 — 2030-11-14) [ПОДТВЕРЖДЕНО: https://www.postgresql.org/support/versioning/]; `listen_addresses='*'` без файрвола. Чужой PostgreSQL мы **не используем** — поднимаем свой экземпляр (раздел 4). |
| 23 | Пользователи с sudo и SSH | `getent group sudo wheel ; sudo grep -E '^(PasswordAuthentication|PermitRootLogin|Port)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null ; sudo lastb \| head -n 20` | Кто админ; разрешён ли вход по паролю/под root; есть ли волна неудачных входов (`lastb`). | `PasswordAuthentication yes` + `PermitRootLogin yes`; сотни неудачных попыток в `lastb` → нужен fail2ban и ключи. |
| 24 | Автообновления | `cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null ; systemctl status unattended-upgrades --no-pager 2>/dev/null ; sudo apt list --upgradable 2>/dev/null \| wc -l` | Включены ли автоматические обновления безопасности; сколько пакетов ждут обновления. | Сотни необновлённых пакетов; служба отсутствует. |
| 25 | Время/NTP | `timedatectl` | `System clock synchronized: yes`, часовой пояс. | Время не синхронизировано (ломает TLS и логи сверки с 1С). Часовой пояс для Кыргызстана — `Asia/Bishkek` [ТИПОВО: tzdata, требует проверки на сервере]. |

### 1.2. Windows Server (PowerShell от администратора)

| # | Зачем | Команда | Как прочитать результат | Что считать проблемой |
|---|---|---|---|---|
| 1 | Версия ОС, RAM, аптайм | `systeminfo` ; `Get-ComputerInfo \| Select-Object WindowsProductName, OsVersion, OsArchitecture, CsTotalPhysicalMemory, OsLastBootUpTime, HyperVisorPresent` | Редакция (2016/2019/2022/2025), память в байтах, был ли перезапуск, `HyperVisorPresent=True` — это VM. | Windows Server 2012/2012 R2 (вне поддержки); 2019: mainstream закончился 2024-01-10, extended до 2029-01-10 [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2019]; 2022: mainstream закончился 2026-10-14 — т.е. на дату отчёта (2026-10-18) 2022 уже в extended-поддержке (только security-обновления) до 2031-10-15 [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2022]. Актуальная версия — Windows Server 2025: mainstream до 2029-11-14, extended до 2034-11-15 [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2025]. Вывод: 2019 и 2022 допустимы (получают security-обновления), но новых функций не получают; при переустановке — 2025. |
| 2 | CPU | `Get-CimInstance Win32_Processor \| Select-Object Name, NumberOfCores, NumberOfLogicalProcessors` | Модель, ядра. | < 2 ядер. |
| 3 | Диски | `Get-PSDrive -PSProvider FileSystem` ; `Get-PhysicalDisk \| Select-Object FriendlyName, MediaType, Size, HealthStatus` | `Free` по дискам; `MediaType` = `SSD`/`HDD`; `HealthStatus`. | < 40 GB свободно на диске для данных; `HDD` для БД; `HealthStatus` ≠ `Healthy`. |
| 4 | Слушающие порты | `Get-NetTCPConnection -State Listen \| Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Proc';e={(Get-Process -Id $_.OwningProcess).ProcessName}} \| Sort-Object LocalPort` | Порт → процесс. Ищем 80/443 (`w3wp`/`httpd`), 1540/1541/1560–1591 (`ragent`/`rmngr`/`rphost` — кластер 1С [ТИПОВО]), 5432 (`postgres`), 1433 (`sqlservr` — MS SQL под 1С). | 80/443 заняты (IIS/Apache для 1С) — нужен отдельный порт/хост для RP; 1433/5432 слушают на `0.0.0.0`. |
| 5 | Запущенные службы | `Get-Service \| Where-Object Status -eq Running \| Select-Object Name, DisplayName \| Sort-Object Name` | Ищем `1C:Enterprise 8.3 Server Agent` (ragent), `Apache2.4`, `W3SVC` (IIS), `MSSQLSERVER`, `postgresql-x64-*`, `Docker Desktop Service`, `com.docker.service`, `WireGuardTunnel$*`. | Сосед по ресурсам (MS SQL + сервер 1С) уже потребляет большую часть RAM. |
| 6 | Процессы 1С | `Get-Process ragent, rmngr, rphost -ErrorAction SilentlyContinue \| Select-Object Name, Id, WorkingSet64, StartTime` ; `Get-Service \| Where-Object DisplayName -like '*1C*'` | Если `ragent`/`rphost` есть — клиент-серверная 1С на этом хосте; если нет — возможно файловая база или сервер 1С на другой машине. | `WorkingSet64` суммарно близок к RAM машины — для backend места нет. |
| 7 | Публикации 1С (IIS) | `Import-Module WebAdministration ; Get-Website \| Select-Object Name, State, PhysicalPath, @{n='Bindings';e={$_.bindings.Collection.bindingInformation}}` ; `Get-ChildItem IIS:\Sites\*\* \| Where-Object { Test-Path (Join-Path $_.PhysicalPath 'default.vrd') }` | Сайты IIS, их порты (`*:80:`), папки с `default.vrd` — это публикации 1С (HTTP-сервисы/OData/веб-клиент). | Нет публикаций — значит HTTP-доступ к 1С ещё предстоит согласовать (см. отчёт 1С-эксперта). |
| 8 | Публикации 1С (Apache) | `Get-ChildItem 'C:\Program Files\Apache*','C:\Apache*' -ErrorAction SilentlyContinue` ; `Select-String -Path 'C:\Program Files\Apache Software Foundation\Apache2.4\conf\httpd.conf' -Pattern 'Alias|_1cws_module|Listen' -ErrorAction SilentlyContinue` | Есть ли Apache и публикации (`_1cws_module`, `Alias "/<имя_базы>"`). | Apache слушает 80 на всех интерфейсах без TLS. |
| 9 | Файрвол | `Get-NetFirewallProfile \| Select-Object Name, Enabled, DefaultInboundAction` ; `Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow \| Get-NetFirewallPortFilter \| Select-Object Protocol, LocalPort \| Sort-Object -Unique LocalPort` | Включены ли профили; какие входящие порты разрешены. | Профили `Enabled=False`; разрешён 1433/5432/3389 для `Any`. |
| 10 | RDP наружу | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections` ; `(Get-NetTCPConnection -State Listen -LocalPort 3389).LocalAddress` | `0` — RDP включён. | RDP (3389) доступен из интернета без VPN — критический риск. |
| 11 | Docker Desktop / WSL2 / Hyper-V | `wsl --status ; wsl -l -v` ; `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform, Microsoft-Hyper-V-All \| Select-Object FeatureName, State` ; `docker version 2>$null` | Включены ли Hyper-V / WSL. | Docker Desktop на Windows Server **официально не поддерживается** [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/ — «Docker Desktop is not supported on server versions of Windows, such as Windows Server 2019 or Windows Server 2022»]. Если уже стоит — учесть при выборе сценария B. |
| 12 | OpenSSH | `Get-WindowsCapability -Online \| Where-Object Name -like 'OpenSSH*'` ; `Get-Service sshd -ErrorAction SilentlyContinue` | Установлен ли сервер SSH (доступен как Feature on Demand с Windows Server 2019; в 2025 — установлен по умолчанию) [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse]. | Нет — администрирование только через RDP. |
| 13 | Планировщик задач | `Get-ScheduledTask \| Where-Object State -ne Disabled \| Select-Object TaskName, TaskPath, State` | Существующие задания (бэкапы 1С, выгрузки). | Нет бэкапа базы 1С — сообщить заказчику (не наша зона, но риск для бизнеса). |
| 14 | PostgreSQL для 1С | `Get-Service postgresql* ; & 'C:\Program Files\PostgreSQL\*\bin\psql.exe' --version` | Версия (у 1С часто сборка PostgreSQL от 1С/PostgresPro [ТИПОВО]). | Мы **не используем** экземпляр БД 1С для backend — отдельный экземпляр/контейнер. |
| 15 | Домен и внешний IP | `Resolve-DnsName <домен-заказчика> -Type A` ; `(Invoke-RestMethod https://api.ipify.org)` ; `Get-NetIPAddress -AddressFamily IPv4 \| Select-Object InterfaceAlias, IPAddress` | На что указывает домен; внешний IP; локальные адреса. | Сервер за NAT без проброса; домен занят сайтом. |
| 16 | Обновления | `Get-HotFix \| Sort-Object InstalledOn -Descending \| Select-Object -First 5` | Дата последних обновлений. | Последнее обновление старше 90 дней. |
| 17 | Ошибки системы | `Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2} -MaxEvents 30 \| Select-Object TimeCreated, Id, ProviderName, Message` | Критические ошибки и ошибки диска (`disk`, `ntfs`, `volmgr`). | Ошибки диска/контроллера. |
| 18 | Время | `w32tm /query /status` | Источник времени, смещение. | Источник `Local CMOS Clock` — время не синхронизируется. |

### 1.3. Что ещё нужно спросить у заказчика (не команды)

- Где физически стоит сервер (в магазине / в дата-центре / у провайдера) и кто за него отвечает.
- Интернет магазина: провайдер, тариф, есть ли **статический публичный IP**, есть ли резервный канал. (Влияет на выбор A/B/C.)
- Есть ли домен магазина, кто управляет DNS, можно ли создать поддомен (например, `pos.<домен>`) — точное имя не выдумываю, согласовать.
- Кто обслуживает 1С (франчайзи/штатный) и может ли он включить публикацию HTTP-сервисов/OData и регламентные задания (см. отчёт 1С-эксперта).
- Есть ли облачный аккаунт/оплата картой для внешнего хранилища бэкапов.

---

## 2. Сценарии размещения

Общие компоненты во всех сценариях: `api` (модульный монолит backend, язык/рантайм выбирает Главный архитектор; здесь только требования к контейнеризации/службе), `postgres` (отдельный экземпляр только для «Оптомстрой»), `reverse-proxy` с TLS, `sync-worker` (задачи обмена с 1С — отдельный процесс/контейнер или фоновая часть `api`; планировщик **на сервере**, как требует мастер-промт), хранилище фото (локальный том + бэкап).

### 2.1. Сценарий A — сервер Linux + Docker Compose

Состав (один `docker-compose.yml`, проект `optomstroy-prod`):

| Сервис | Образ/тег | Порты | Сети | Исходящие соединения (нужны) | Тома |
|---|---|---|---|---|---|
| `proxy` | `caddy:2.x` (точный тег фиксируется при деплое) либо `nginx` + certbot на хосте | `80`, `443` наружу (единственные публичные) | `edge` | ACME CA (Let's Encrypt/ZeroSSL, HTTPS) для выпуска/продления сертификатов | `caddy_data` (сертификаты — обязателен persistent том [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https — data directory must be writable and persistent]) |
| `api` | `optomstroy/api:<версия>` | внутренний `8080`, **не публикуется** на хост | `edge`, `backend` | SMSPro (HTTPS); HTTP-сервисы/OData 1С (LAN магазина или через VPN) — если синхронные запросы к 1С делает `api`; `postgres` по сети `backend` | `media` (фото), `logs` |
| `sync` | тот же образ, другая команда | нет | `edge`, `backend` | **обязательно**: HTTP-сервисы/OData 1С (LAN/VPN), при необходимости Healthchecks (HTTPS); `postgres` по сети `backend`. Поэтому `sync` подключён к `edge` (внешний выход), а не только к `backend` | — |
| `postgres` | `postgres:17` (или 18, см. 3.4) | **не публикуется** (без `ports:`) | `backend` | нет (исходящий доступ не нужен) | `pgdata` |
| `pgadmin` (опционально) | `dpage/pgadmin4` | `127.0.0.1:5050:80` — только localhost, доступ через SSH-туннель | `edge`, `backend` | нет | `pgadmin` |
| хост (`docker pull`) | — | — | — | реестр образов (Docker Hub / GHCR / свой registry, HTTPS); apt-репозитории ОС и Docker | — |

Сети: `edge` — обычная bridge-сеть с выходом наружу (через NAT хоста); `backend` — `internal: true` («externally isolated network», без доступа наружу) [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/networks/]. Следствия, которые нужно учесть в compose:
- Сервис, подключённый **только** к `backend`, не имеет выхода в интернет/LAN — поэтому `sync` и `api` подключены к обеим сетям, а `postgres` — только к `backend` (ему исходящие соединения не нужны).
- Для контейнера, который находится только в internal-сети, публикация портов на хост (`ports:`) не работает — Docker не настраивает NAT для internal-сетей [ТИПОВО: поведение Docker Engine, проверить на этапе 2]. Поэтому вариант `127.0.0.1:5433:5432` для `postgres` в таблице **не используется**.
- Административный доступ к БД (резервный путь, без публикации портов): SSH-туннель на хост + `docker compose -p optomstroy-prod exec postgres psql -U <роль> <база>`, либо `pgadmin` (он в обеих сетях, его порт — только `127.0.0.1:5050` через SSH-туннель). Если всё же потребуется прямой TCP-доступ клиентом с рабочей станции (например, DBeaver через SSH-туннель), временно подключить `postgres` к `edge` и опубликовать `127.0.0.1:5433:5432`, после работ — вернуть.
- Допустимая альтернатива (если `internal: true` неудобен): обе сети обычные, `postgres` без `ports:` + firewall хоста; изоляция БД тогда обеспечивается только отсутствием публикации порта.

Ключевые свойства:
- Caddy включает HTTPS автоматически для имён хостов в конфиге; нужны A/AAAA-запись на сервер и доступные снаружи порты 80 и 443; CA по умолчанию Let's Encrypt с запасным ZeroSSL; продление — фоново [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https].
- Альтернатива Nginx + certbot: `snap install --classic certbot`, `certbot --nginx`, проверка автопродления `certbot renew --dry-run` [ПОДТВЕРЖДЕНО: https://certbot.eff.org/instructions?ws=nginx&os=snap]. Больше ручной конфигурации, зато Nginx чаще уже есть у админов.
- Лимиты Let's Encrypt: 50 сертификатов на зарегистрированный домен за 7 дней; 5 дубликатов (одинаковый набор имён) за 7 дней; 5 неудачных валидаций на имя в час [ПОДТВЕРЖДЕНО: https://letsencrypt.org/docs/rate-limits/]. Практический вывод: от лимита дубликатов защищают persistent-том `caddy_data` (не пересоздавать при деплое) и staging CA при отладке; тест/прод — **разные поддомены** по причине разделения контуров (см. 8.4).
- Docker Engine поддерживает Ubuntu 22.04 / 24.04 / 26.04 LTS; установка из apt-репозитория Docker пакетами `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/].
- Секреты: Compose `secrets:` с `file:` монтируются в контейнер как файл `/run/secrets/<имя>` [ПОДТВЕРЖДЕНО: https://docs.docker.com/compose/how-tos/use-secrets/]; образ `postgres` читает `POSTGRES_PASSWORD_FILE` [ПОДТВЕРЖДЕНО: https://hub.docker.com/_/postgres].
- Зависимости запуска: `depends_on: postgres: condition: service_healthy` с `healthcheck` у `postgres` [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/services/#healthcheck].

Плюсы: изоляция, воспроизводимость, простой откат по тегу образа, минимальная поверхность атаки. Минусы: нужен Linux-хост; админу заказчика нужно базовое знание Docker.

### 2.2. Сценарий B — Windows Server, на котором уже стоит 1С

| Вариант | Суть | Ограничения / риски | Оценка |
|---|---|---|---|
| **B-1. Docker Desktop + WSL2** | Поставить Docker Desktop и запускать тот же compose, что в A. | Docker Desktop **официально не поддерживается на Windows Server** [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/]. Docker Desktop — приложение пользовательской сессии: контейнеры живут, пока выполнен вход пользователя [ТИПОВО: поведение Docker Desktop, требует проверки на конкретной версии]. WSL2 на Windows Server 2022/2025 ставится `wsl.exe --install`, на 2019 — вручную [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/windows/wsl/install-on-server]. WSL2 — это VM с собственным планировщиком памяти, что трудно контролировать рядом с 1С/MS SQL. Коммерческая лицензия Docker Desktop нужна компаниям > 250 сотрудников или > $10 млн выручки [ПОДТВЕРЖДЕНО: там же]. | **Не рекомендуется** для продакшена. Допустимо только для тестового контура. |
| **B-2. Нативные службы Windows** | `api` как служба Windows через WinSW (MIT, XML-конфиг, `winsw install app.xml`) [ПОДТВЕРЖДЕНО: https://github.com/winsw/winsw] или NSSM (перезапускает приложение при падении, пишет в Event Log) [ПОДТВЕРЖДЕНО: https://nssm.cc/]; PostgreSQL for Windows (отдельный экземпляр на отдельном порту, `listen_addresses='localhost'`); RP — Caddy для Windows как служба (WinSW) либо IIS с ARR (сложнее). | Делит ОС, обновления и перезагрузки с 1С; откат = переустановка версии; нет изоляции сети; рантайм (.NET/Node) ставится на хост 1С. Нужен отдельный пользователь Windows с минимальными правами для служб. | Рабочий, но менее управляемый вариант. Подходит, если нет возможности выделить VM. |
| **B-3. Отдельная Linux-VM на том же железе (Hyper-V)** | Включить роль Hyper-V (если сервер физический и ресурсов хватает), создать VM Ubuntu 24.04 LTS, в ней — сценарий A. Трафик к 1С — по внутренней сети Hyper-V/локальной сети. | Требует запаса ресурсов (минимум +4 GB RAM, +2 vCPU, +80 GB диска для VM); если сервер сам уже VM — нужна вложенная виртуализация [ТИПОВО: требует проверки `HyperVisorPresent` из 1.2.1]. Включение роли Hyper-V — изменение конфигурации сервера, требует согласования и перезагрузки. | **Рекомендуемый** вариант при Windows-сервере с достаточными ресурсами: сохраняется сценарий A, 1С не затрагивается. |
| **B-4. Контейнеры Windows / Linux-контейнеры на Windows-хосте** | Docker Engine для Windows Server (Windows-контейнеры) либо запуск Linux-образов на Windows. | Linux-образы (`postgres`, `caddy`, наш `api`) не могут работать на ядре Windows: «running Linux containers directly on Windows isn't an option» — требуется виртуализация (Hyper-V), и официальный путь Microsoft для Linux-контейнеров — Docker Desktop (Windows 10/11 или Windows Server 2019 1809+ с Hyper-V) [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/linux-containers — редирект на set-up-linux-containers], что возвращает к ограничениям B-1 (Docker Desktop не поддерживается на Windows Server). Чисто Windows-контейнеры потребовали бы Windows-образов PostgreSQL/Caddy/рантайма и пересборки всего compose — отдельный, нетиповой стек. | **Отвергнут**: не даёт преимуществ перед B-3 (та же Hyper-V), добавляет нетиповой стек. |

Общее для B: сервер 1С (ragent/rmngr/rphost) и его СУБД — чужие процессы; наш backend обращается к 1С **только через опубликованные HTTP-сервисы/OData**, а не к СУБД 1С напрямую — это архитектурное решение (согласуется с запретом мастер-промта на прямое подключение Flutter к базе 1С; прямой доступ к таблицам 1С мимо платформы не поддерживается технически/лицензионно — [ТИПОВО]). Детали обмена — см. отчёт 1С-эксперта. Публикация 1С на веб-сервере описана в разделе «Настройка веб-серверов для работы с „1С:Предприятием“» руководства администратора (утилита `webinst`, файл `default.vrd`) [ТИПОВО: оглавление https://its.1c.ru/db/v8324doc/content/113/1 подтверждает наличие раздела; текст раздела в рамках этого исследования недоступен, параметры не привожу].

### 2.3. Сценарий C — 1С в локальной сети магазина, backend на VPS/в облаке

| Вариант | Суть | Что нужно в магазине | Риски |
|---|---|---|---|
| **C-1. VPN WireGuard** между VPS и сетью магазина | На VPS и на машине с 1С (Windows или Linux) поднимается WireGuard; backend обращается к HTTP-сервисам 1С по адресу внутри туннеля. WireGuard есть для Linux (`apt install wireguard`) и Windows (официальный установщик, поддержка Windows 10/11, Server 2016–2025) [ПОДТВЕРЖДЕНО: https://www.wireguard.com/install/]. Cryptokey routing: список разрешённых IP на каждый ключ работает как ACL; при смене IP магазина туннель «переезжает» сам (roaming) [ПОДТВЕРЖДЕНО: https://www.wireguard.com/]. | Если магазин инициирует соединение к VPS (магазин = «клиент», VPS = «сервер» с `ListenPort`, в документации в примерах используется 51820 [ПОДТВЕРЖДЕНО: там же]), входящие порты в магазине **не нужны** — только исходящий UDP. На стороне VPS в firewall открывается входящий UDP `<ListenPort>` (см. раздел 5, «Сетевая фильтрация»). | Установка ПО на машину 1С (согласование); при падении интернета в магазине синхронизация останавливается, но POS продолжает работать с кэшем backend. |
| **C-2. «Исходящий» обмен со стороны 1С** | 1С по регламентному заданию сама вызывает HTTPS-эндпоинты backend (`push` справочников/остатков, `pull` заказов). Backend публичен по HTTPS, авторизация — отдельный служебный токен/клиентский сертификат для 1С. | Ничего, кроме исходящего HTTPS (443) и доработки/расширения в 1С (см. отчёт 1С-эксперта: возможность HTTP-запросов из 1С и регламентных заданий — [ТИПОВО: типовая платформа 8.3 поддерживает объект `HTTPСоединение` и регламентные задания; конкретная конфигурация требует проверки]). | Вся логика расписания — в 1С (нужен сервер 1С или постоянно запущенный сеанс для регламентных заданий в файловой базе [ТИПОВО]); сложнее «вытягивать» данные по требованию (ручная синхронизация = «запрос на следующую выгрузку»). |
| **C-3. Гибрид** | C-1 для запросов backend → 1С (pull по расписанию каждые 30 мин, ручная синхронизация) + C-2 для событийных push из 1С. | Как C-1 + C-2. | Больше точек отказа, но максимальная гибкость. |

### 2.4. Сравнение A / B / C

| Критерий | A: Linux + Docker (у заказчика) | B-2: Windows нативно (у заказчика) | B-3: Linux-VM на Windows-сервере | C-1: VPS + WireGuard | C-2: VPS + исходящий обмен от 1С |
|---|---|---|---|---|---|
| Безопасность | Высокая: наружу только 443; БД в внутренней сети Docker | Средняя: общая ОС с 1С, общий файрвол, общие перезагрузки | Высокая (как A) + 1С изолирована | Высокая на VPS; в магазине нет входящих портов | Высокая; в магазине нет входящих портов; backend публичен (обязателен rate-limit и токен для 1С) |
| Стоимость (деньги) | 0 за хостинг (сервер есть); электроэнергия/канал | 0 | 0, если ресурсов хватает | VPS ~ от 4 GB RAM — ориентиры в разделе 9 | То же |
| Сложность внедрения | Низкая–средняя | Средняя (службы, ручные обновления) | Средняя (Hyper-V + A) | Средняя (VPN на обеих сторонах) | Средняя–высокая (доработка 1С) |
| Сложность сопровождения | Низкая | Средняя–высокая | Низкая | Низкая–средняя | Средняя (две команды: backend и 1С) |
| Зависимость от интернета магазина | **Критическая**: если backend в магазине и интернет упал, мобильные продавцы вне Wi-Fi магазина теряют доступ; внутри магазина (Wi-Fi) всё работает | Как A | Как A | Backend доступен всегда; при обрыве интернета в магазине не работает синхронизация и POS в магазине без интернета теряет backend | Как C-1 |
| Зависимость от канала/статического IP | Нужен статический публичный IP (или DDNS + проброс 443) для доступа извне | Как A | Как A | Не нужен | Не нужен |
| Производительность для POS в магазине | Лучшая (LAN) | Лучшая (LAN), но конкуренция с 1С за CPU/RAM | Хорошая | Зависит от канала (латентность до VPS) | То же |
| Бэкап вне площадки | Нужно организовать отдельно (облако/другой хост) | То же | То же | VPS-снапшоты + бэкап на второй хост | То же |
| Пригодность под Release 1 | Да, если аудит ОК | Условно | Да | Да | Да |

Замечание: «работа POS при отсутствии интернета» по мастер-промту обеспечивается кэшем во Flutter-клиенте; инфраструктура лишь определяет, где находится backend. Это должен учесть Flutter-архитектор.

### 2.5. Дерево решения (после аудита)

1. Сервер Linux (Ubuntu 22.04+/Debian 12+), ≥ 4 GB RAM свободно, SSD, публичный статический IP или возможность проброса 443 → **A**.
2. Windows Server 2019+, физический, ≥ 16 GB RAM и ≥ 50 % свободно, Hyper-V можно включить → **B-3**.
3. Windows Server, ресурсов мало или Hyper-V нельзя → **B-2** для теста/пилота + план перехода на VPS (**C**) для прода.
4. Сервер только в локальной сети без статического IP/проброса → **C-1** (WireGuard, магазин инициирует) или **C-2**; backend на VPS.
5. Сервер старый/нестабильный (ошибки диска, ОС без поддержки) → **C** + минимальные улучшения (раздел 9).

---

## 3. Требования к ресурсам Release 1

Вводные (из мастер-промта и задания): ~50 000 SKU, до 20–50 одновременных сотрудников, фото — объём неизвестен (N ГБ). Все цифры ниже — **инженерная оценка** [НЕ ПОДТВЕРЖДЕНО], подлежит уточнению нагрузочным тестом на этапе 2.

### 3.1. База данных

| Объект | Оценка объёма | Обоснование |
|---|---|---|
| `products` + `product_variants` (50k SKU, допустим до 100k вариантов) | ~0,3–0,6 GB с индексами | 1–3 KB на строку с описанием/характеристиками (JSONB) + индексы (btree по артикулу/штрихкоду, GIN/trigram для поиска по названию) |
| `stock_balances` (варианты × склады, например 100k × 3) | ~0,1 GB | узкие строки, частые UPDATE → bloat, нужен autovacuum |
| `price_lists` | ~0,1 GB | несколько видов цен × варианты |
| `customers`, `receivables`, история покупок за 2–3 года | 0,2–1 GB | зависит от объёма выгрузки истории из 1С — уточнить у 1С-эксперта |
| `orders`, `order_items`, `transactions`, `audit_logs` | ~0,5–1 GB/год при ~300–500 документов/день [НЕ ПОДТВЕРЖДЕНО] | строки заказов + журнал аудита |
| `sync_runs`, `sync_errors` | ~0,1 GB/год | с ротацией старых записей |
| **Итого R1** | **~1–3 GB**, рост **1–2 GB/год** | PostgreSQL легко держит это на 2 GB `shared_buffers` |

### 3.2. Фотографии

Формула: `N_фото = SKU × среднее число фото`; объём = `N_фото × (оригинал + превью)`.
Пример расчёта (параметры — предположение, заменить на реальные): 50 000 × 1,5 фото × (300 KB оригинал + 40 KB превью) ≈ **25 GB**. При 3 фото на SKU и 600 KB оригиналах — ≈ 100 GB. **Нужно запросить у заказчика:** где сейчас хранятся фото (в 1С как хранилище значений, в папке, в облаке), их количество и суммарный размер (1С-эксперт).
Рекомендация: хранить оригиналы с ограничением размера (сервер при загрузке сжимает до, например, 1600 px по длинной стороне — параметр согласовать) и генерировать превью; это снижает объём в 3–5 раз [ТИПОВО].

### 3.3. Расчёт CPU/RAM/диска

| Компонент | RAM | CPU | Диск | Комментарий |
|---|---|---|---|---|
| ОС + Docker | 0,7–1 GB | — | 10–15 GB | |
| `postgres` | 1,5–2,5 GB (`shared_buffers` 1 GB при 4 GB RAM, 2 GB при 8 GB; `work_mem` 8–16 MB; `max_connections` 100 по умолчанию достаточно при пуле на стороне `api`) | 1–2 vCPU | 10 GB данных + 10 GB запас + WAL | 50 сотрудников ≠ 50 соединений: пул 10–20 соединений |
| `api` + `sync` | 0,5–1,5 GB (зависит от рантайма; JVM — больше, Go/.NET/Node — меньше) | 1–2 vCPU | образ 0,2–1 GB | Поиск по 50k SKU — в PostgreSQL (trigram/FTS), не в памяти приложения |
| `proxy` (Caddy/Nginx) | 50–100 MB | доля ядра | < 1 GB | |
| Фото | кэш ОС | — | **N GB** (25–100 GB по 3.2) | отдельный том, лучше отдельный диск |
| Логи (json-file с ротацией) | — | — | 2–5 GB | см. раздел 7 |
| Локальные бэкапы (30 дней дампов + последний снимок фото) | — | — | 30 × (сжатый дамп ~50–200 MB) ≈ 2–6 GB + копия фото N GB | внешняя копия обязательна |
| Тестовый контур на том же сервере | +1,5–2 GB RAM | + доля CPU | +10 GB + уменьшенный набор фото | |

**Итог:**
- Минимум (только прод, фото ≤ 30 GB): **2 vCPU / 4 GB RAM / 80 GB SSD**.
- Рекомендуется (прод + тест, фото до 100 GB, запас на 2–3 года): **4 vCPU / 8 GB RAM / 160–250 GB SSD** + внешнее хранилище бэкапов ≥ 2 × (БД + фото).
- Рост на 2–3 года: БД +1–2 GB/год; фото +10–30 %/год (новые SKU и замена фото); логи постоянны при ротации. Диск планировать с заполнением не более 70 % к концу 3-го года.
- Сеть: для 50 сотрудников при каталожных запросах 20–100 KB и фото 40–300 KB пиковая полоса оценочно 5–20 Mbit/s; важнее латентность и стабильность канала, чем ширина [НЕ ПОДТВЕРЖДЕНО].

### 3.4. Версии ПО (рекомендации для фиксации в ТЗ)

| Компонент | Рекомендация | Основание |
|---|---|---|
| ОС (сценарий A/B-3) | Ubuntu Server 24.04 LTS (поддержка до мая 2029) или 26.04 LTS (до мая 2031) | [ПОДТВЕРЖДЕНО: https://ubuntu.com/about/release-cycle]; Docker Engine поддерживает обе [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/] |
| PostgreSQL | 17 (EOL 2029-11-08) или 18 (EOL 2030-11-14); выбор за Backend-инженером с учётом поддержки драйверами | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/support/versioning/]. В образе `postgres:18+` том монтируется в `/var/lib/postgresql`, а не `/var/lib/postgresql/data` [ПОДТВЕРЖДЕНО: https://hub.docker.com/_/postgres] — учесть в compose |
| Reverse-proxy | Caddy 2 (авто-TLS) — по умолчанию; Nginx + certbot — если админ заказчика настаивает | [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https; https://certbot.eff.org/instructions?ws=nginx&os=snap] |
| Docker | Docker Engine + Compose v2 plugin из репозитория Docker | [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/ubuntu/] |

---

## 4. Изоляция от существующих сервисов

### 4.1. Принципы

| Область | Правило | Как реализуется |
|---|---|---|
| Пользователь ОС | Отдельный пользователь `optomstroy` (имя согласовать) без пароля, вход только по SSH-ключу. **Риск:** членство в группе `docker` даёт права, эквивалентные root на хосте («The docker group grants root-level privileges to the user») [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/linux-postinstall/]. Варианты (решение — на этапе 2, согласовать с админом заказчика): (а) **rootless Docker** (демон от пользователя `optomstroy`; для портов 80/443 — `sysctl net.ipv4.ip_unprivileged_port_start=80` либо хостовый RP, проксирующий на непривилегированные порты) [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/security/rootless/ — режим; настройка привилегированных портов — ТИПОВО, требует проверки]; (б) обычный Docker, `optomstroy` **не** в группе `docker`, запуск `docker compose` через `sudo` с ограниченным `sudoers` (только `/usr/bin/docker compose -p optomstroy-* …`); (в) принять риск членства в `docker` с обоснованием (единственный сервис на хосте, доступ только по ключу) — допустимо для сценария B-3/VPS, где на хосте нет чужих служб | `adduser --disabled-password`; далее по выбранному варианту (а/б/в) — выполняется на этапе 2 |
| Каталоги | Всё приложение в `/opt/optomstroy/{prod,test}` (compose-файлы, `.env`, `secrets/`) и `/srv/optomstroy/{prod,test}/{pgdata,media,backups}` (данные). Ничего не пишем в `/etc` чужих служб | Права `750` на каталоги, `600` на `.env` и секреты |
| Порты хоста | Наружу публикуются только `80` и `443` нашего RP. `api`, `postgres`, `pgadmin` — без `ports:` либо только `127.0.0.1:` | Проверяется `ss -tulpn` после деплоя |
| Сети Docker | Свои сети `optomstroy_prod_edge` (с выходом наружу: `proxy`, `api`, `sync`, `pgadmin`) и `optomstroy_prod_backend` (`internal: true` — без выхода наружу; в ней только `postgres` плюс те, кому нужна БД). Сервисы, которым нужны исходящие соединения к 1С/SMSPro (`api`, `sync`), **обязательно** в обеих сетях (см. 2.1); тест — отдельные сети | Compose создаёт сети с префиксом проекта |
| Ресурсы | `deploy.resources.limits` (memory/cpus) на каждый контейнер, чтобы не «съесть» память соседей; `restart: unless-stopped` | Особенно важно в сценарии B-3 и при соседстве с 1С |
| Логи | Ротация json-file (раздел 7), чтобы не заполнить диск соседям | |
| Существующие конфиги | Не редактируем чужие `nginx.conf`, `httpd.conf`, `pg_hba.conf`, правила firewall, DNS, cron | Если 80/443 заняты чужим веб-сервером — варианты: (а) наш RP на других портах за чужим прокси (чужой конфиг меняет его владелец), (б) отдельный IP/хост, (в) VPS (сценарий C) |
| Имена проектов Compose | `optomstroy-prod`, `optomstroy-test` — чтобы `docker compose down` одного не трогал другой | `-p` или `name:` в compose |

### 4.2. Если на сервере уже есть PostgreSQL (например, под 1С)

Не используем его. Причины: разные версии/сборки (у 1С часто специальная сборка PostgreSQL [ТИПОВО]), разные политики бэкапа и обновления, риск повлиять на учётную систему. Свой контейнер `postgres` на внутренней сети Docker без публикации портов; администрирование — SSH-туннель + `docker compose exec postgres psql` (см. 2.1). Если временно нужен прямой TCP-доступ — `127.0.0.1:5433` (нестандартный порт, чтобы не конфликтовать с 5432 чужого экземпляра) при подключении `postgres` к сети `edge` на время работ.

### 4.3. Что потребуется согласовать с заказчиком (список для раздела 14_OPEN_QUESTIONS)

| # | Что | Зачем | Кто решает |
|---|---|---|---|
| 1 | Домен/поддомен для API (например, `pos.<домен>` — имя условное) и доступ к DNS для создания A-записи (и, при тесте, второго поддомена) | TLS и адрес для приложений | Владелец домена |
| 2 | Открытие входящих 80 и 443 на сервер (на роутере/провайдере/firewall) | Авто-TLS (HTTP-01 / TLS-ALPN-01) и сам API | Админ сети / провайдер |
| 3 | Разрешение на SSH (22 или нестандартный порт) с ограничением по IP или через VPN | Администрирование | Админ сети |
| 4 | Правила firewall на сервере: разрешить 80/443 к RP; запретить всё остальное входящее для нашего проекта | Безопасность | Админ сервера |
| 5 | Сертификат: Let's Encrypt (бесплатно, автоматически) или корпоративный/платный — если у заказчика политика | TLS | Заказчик |
| 6 | Хранилище для бэкапов вне сервера: S3-совместимое облако / второй сервер / NAS в офисе; кто оплачивает | Защита от потери сервера | Заказчик |
| 7 | Создание пользователя ОС `optomstroy` и каталогов; права `docker` | Изоляция | Админ сервера |
| 8 | Установка Docker Engine (если нет) и, в сценарии B-3, включение Hyper-V + перезагрузка | Платформа | Админ сервера, окно обслуживания |
| 9 | Сетевой доступ от backend к HTTP-сервисам 1С (адрес, порт, учётная запись с минимальными правами) | Обмен с 1С | Специалист 1С |
| 10 | Окна обслуживания (день/час), когда допустима перезагрузка сервера | Обновления ОС | Заказчик |
| 11 | Канал оповещений (Telegram-группа/e-mail) для алертов | Мониторинг | Заказчик |
| 12 | Политика хранения логов и персональных данных (срок) | Приватность | Заказчик + юр. требования КР [НЕ ПОДТВЕРЖДЕНО — уточнить у QA/Security] |

---

## 5. Безопасность инфраструктуры

| Требование | Реализация (план) | Проверка | Источник |
|---|---|---|---|
| БД не доступна из интернета | `postgres` без `ports:` и только в сети `backend` с `internal: true` (сервисы `api`/`sync` при этом в обеих сетях, иначе они теряют доступ к 1С/SMSPro — см. 2.1); на хосте `ss -tulpn` не показывает 5432/5433 на `0.0.0.0`. Админ-доступ — SSH-туннель + `docker compose exec postgres psql`. В нативном варианте — `listen_addresses='localhost'` (значение по умолчанию) | `nmap -p 5432,5433 <публичный IP>` извне → `closed/filtered` | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/runtime-config-connection.html; https://docs.docker.com/reference/compose-file/networks/] |
| SSH только по ключам | `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers optomstroy <админ>`; ключи ed25519. Изменение `sshd_config` — только с согласия админа заказчика (п. 4.3) | `ssh -o PreferredAuthentications=password` → отказ | [ТИПОВО: OpenSSH sshd_config, требует применения на сервере] |
| Защита от перебора | `fail2ban` с jail `sshd` (следит за логами, временно блокирует IP через firewall; не заменяет ключи/2FA) | `fail2ban-client status sshd` | [ПОДТВЕРЖДЕНО: https://github.com/fail2ban/fail2ban] |
| Автообновления безопасности ОС | Ubuntu: `unattended-upgrades` установлен по умолчанию, применяет только security-обновления; настройки в `/etc/apt/apt.conf.d/50unattended-upgrades` и `20auto-upgrades`; `Automatic-Reboot` по умолчанию `false` — включать только с указанием `Automatic-Reboot-Time` в окно обслуживания | `cat /etc/apt/apt.conf.d/20auto-upgrades` | [ПОДТВЕРЖДЕНО: https://ubuntu.com/server/docs/how-to/software/automatic-updates/] |
| Секреты | `.env` только с несекретной конфигурацией; пароли БД, ключи JWT, учётные данные SMSPro и 1С — в файлах `secrets/*` с правами `600`, подключённых через Compose `secrets:` → `/run/secrets/<имя>`; образ `postgres` читает `POSTGRES_PASSWORD_FILE`. Пример `.env.example` без значений — в репозитории; сами секреты — **никогда** в git | `ls -la secrets/` → `-rw-------`; `git ls-files \| grep -i secret` пусто | [ПОДТВЕРЖДЕНО: https://docs.docker.com/compose/how-tos/use-secrets/; https://hub.docker.com/_/postgres] |
| Минимальные права | Контейнеры не `privileged`; `api` запускается не от root (`user:` в compose/образе); `read_only: true` + `tmpfs` где возможно; `cap_drop: [ALL]` для `api`; Docker socket никому не монтируется. Пользователь ОС `optomstroy`: группа `docker` = root-эквивалент на хосте — предпочесть rootless Docker или `sudo` с ограниченным `sudoers` (варианты в 4.1) | `docker inspect`; `id optomstroy` (нет группы `docker` при вариантах а/б) | [ТИПОВО: Docker security best practices]; [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/install/linux-postinstall/; https://docs.docker.com/engine/security/rootless/] |
| TLS | Только HTTPS; HTTP → редирект (Caddy делает автоматически); HSTS; TLS 1.2+ | `curl -I http://…` → 308/301; SSL Labs по согласованию | [ПОДТВЕРЖДЕНО: https://caddyserver.com/docs/automatic-https] |
| Сетевая фильтрация | Входящие: 22 (ограничить IP/VPN), 80, 443; **C-1: дополнительно UDP `<ListenPort>` WireGuard на VPS** (в примерах документации 51820; реальный порт согласовать). Всё остальное — `deny`. Исходящие — без ограничений или allow-list (1С, SMSPro, реестр образов, ACME CA). **Нюанс Docker + ufw:** Docker управляет правилами iptables сам; трафик к опубликованным портам контейнеров обрабатывается в таблице `nat` до цепочек `INPUT`/`OUTPUT`, на которые опирается ufw, т.е. «effectively ignoring your firewall configuration» [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/network/packet-filtering-firewalls/]. Поэтому публиковать порты только как `127.0.0.1:…` или не публиковать вовсе, а проверку делать по фактическим портам, а не по `ufw status` | `ss -tulpn` (фактически слушающие порты) и `sudo iptables -S DOCKER` / `sudo iptables -S DOCKER-USER` после деплоя [ТИПОВО: имена цепочек Docker]; `nmap` извне; `ufw status` — недостаточно | [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/network/packet-filtering-firewalls/; https://www.wireguard.com/] |
| Журналирование | Логи RP (доступ), `api` (структурированные JSON без OTP/паролей/токенов), `postgres` (медленные запросы `log_min_duration_statement`, рекомендуется `pg_stat_statements` через `shared_preload_libraries`), `auth.log`/`journald` ОС, fail2ban | Проверка на этапе 2: grep по логам на секретные паттерны | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/pgstatstatements.html] |
| Доступ к pgAdmin/админ-панелям | Только `127.0.0.1` + SSH-туннель (`ssh -L 5050:127.0.0.1:5050`) | извне порт закрыт | |
| Время | NTP включён (`timedatectl`), иначе ломается TLS и сверка с 1С | | |
| Windows (сценарий B) | Службы под отдельной учётной записью с минимальными правами; OpenSSH Server (FoD) вместо RDP из интернета; RDP только через VPN; Windows Firewall включён для всех профилей. **Обновления:** Windows Update (или WSUS, если есть) с автоматической установкой security-обновлений и заданным окном перезагрузки (active hours / политика «Запланировать время перезагрузки»), окно согласовать с работой 1С и регламентными заданиями; перезагрузка вне окна запрещена [ТИПОВО: групповая политика Windows Update, требует проверки у админа]. **Аналог fail2ban:** политика блокировки учётных записей (Account Lockout Policy: порог/длительность), ограничение входящих RDP (3389) и SSH (22) по IP/VPN правилами Windows Firewall, отключение RDP для `Any`; при наличии — Network Level Authentication для RDP [ТИПОВО] | `Get-NetFirewallProfile`; `Get-NetFirewallRule` для 3389/22; `net accounts` (lockout); `Get-HotFix` | [ПОДТВЕРЖДЕНО: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse]; остальное [ТИПОВО] |

---

## 6. Резервное копирование и восстановление

### 6.1. Целевые показатели (предложение, согласовать)

| Показатель | Release 1 | Пояснение |
|---|---|---|
| RPO (допустимая потеря данных) | ≤ 24 ч для БД (суточный дамп); опционально ≤ 1 ч при включении WAL-архивирования | Мастер-данные восстанавливаются повторной синхронизацией из 1С; потеря — только операционных данных POS (корзины, черновики, заказы, ещё не ушедшие в 1С). Заказы, уже переданные в 1С, сохранены в 1С |
| RTO (время восстановления) | ≤ 4 ч на том же сервере; ≤ 1 рабочий день на новом сервере/VPS | При наличии внешней копии и документированной процедуры |
| Хранение | 30 суточных дампов + 3 месячных; фото — последняя полная копия + инкременты | |
| Копия вне сервера | Обязательна (S3-совместимое хранилище / другой хост / NAS) | Потеря сервера целиком — реальный сценарий (пожар, кража, отказ диска) |
| Проверка восстановления | Ежемесячно: восстановление дампа в тестовый контур, smoke-тест, запись результата в журнал | Непроверенный бэкап = отсутствие бэкапа |

### 6.2. Что бэкапим

| Данные | Метод | Частота |
|---|---|---|
| БД PostgreSQL | `pg_dump -Fc` (формат custom: сжатие, выборочное восстановление, `pg_restore -j`); дамп консистентен и не блокирует пишущих | Ежедневно ночью (например, 03:00 по Asia/Bishkek — согласовать) |
| Роли/глобальные объекты | `pg_dumpall --globals-only` | Еженедельно и при изменении ролей |
| Фото (`media`) | `rsync`/`restic`/`rclone` инкрементально во внешнее хранилище | Ежедневно |
| Конфигурация (`compose`, Caddyfile, `.env.example`, скрипты) | в git-репозитории проекта (без секретов) | при изменении |
| Секреты | зашифрованная копия (например, `age`/`gpg`) в отдельном защищённом месте у заказчика | при изменении |
| Сертификаты Caddy (`caddy_data`) | необязательно — перевыпускаются автоматически, но лимит дубликатов 5/нед; желательно включить в копию | ежедневно |

Обоснование: документация `pg_dump` оговаривает: «except in simple cases, pg_dump is generally not the right choice for taking regular backups of production databases. See Chapter 25» [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/app-pgdump.html]; параметры continuous archiving / PITR (`wal_level=replica`, `archive_mode=on`, `archive_command`) описаны в [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/continuous-archiving.html]. Отнесение R1 к «простому случаю» (БД 1–3 GB, мастер-данные восстанавливаются из 1С) — наша оценка [НЕ ПОДТВЕРЖДЕНО — инженерное решение]. Для R1 при объёме БД 1–3 GB суточный дамп — адекватный компромисс; PITR (например, через pgBackRest/WAL-G) — кандидат на Release 2, если бизнес потребует RPO < 1 ч.

### 6.3. Пример скрипта (ТОЛЬКО КАК ДОКУМЕНТ, не для выполнения на этапе 1)

```bash
#!/usr/bin/env bash
# /opt/optomstroy/prod/bin/backup_db.sh  — запускается cron от пользователя optomstroy
set -euo pipefail
PROJECT=optomstroy-prod
BACKUP_DIR=/srv/optomstroy/prod/backups/db
KEEP_DAYS=30
STAMP=$(date +%Y%m%d_%H%M%S)
HC_URL_FILE=/opt/optomstroy/prod/secrets/healthchecks_url   # опционально: ping-URL Healthchecks.io
mkdir -p "$BACKUP_DIR"

[ -f "$HC_URL_FILE" ] && curl -fsS -m 10 --retry 3 "$(cat "$HC_URL_FILE")/start" >/dev/null || true

# дамп из контейнера postgres (имя сервиса: postgres; БД и пользователь — из /run/secrets внутри контейнера)
docker compose -p "$PROJECT" exec -T postgres \
  sh -c 'pg_dump -Fc -U "$(cat /run/secrets/pg_user)" "$(cat /run/secrets/pg_db)"' \
  > "$BACKUP_DIR/optomstroy_${STAMP}.dump"

# еженедельно — глобальные объекты (роли)
if [ "$(date +%u)" = "7" ]; then
  docker compose -p "$PROJECT" exec -T postgres \
    sh -c 'pg_dumpall --globals-only -U "$(cat /run/secrets/pg_user)"' \
    > "$BACKUP_DIR/globals_${STAMP}.sql"
fi

# проверка, что дамп читается
docker compose -p "$PROJECT" exec -T postgres pg_restore --list /dev/stdin \
  < "$BACKUP_DIR/optomstroy_${STAMP}.dump" >/dev/null

# ротация локальных копий
find "$BACKUP_DIR" -name '*.dump' -mtime +"$KEEP_DAYS" -delete
find "$BACKUP_DIR" -name 'globals_*.sql' -mtime +90 -delete

# копия вне сервера (пример для rclone; remote настраивается отдельно, без секретов в скрипте)
rclone copy "$BACKUP_DIR" offsite:optomstroy/prod/db --min-age 1m
rclone sync /srv/optomstroy/prod/media offsite:optomstroy/prod/media --backup-dir "offsite:optomstroy/prod/media_deleted/$STAMP"

[ -f "$HC_URL_FILE" ] && curl -fsS -m 10 --retry 3 "$(cat "$HC_URL_FILE")" >/dev/null || true
```

Пример crontab пользователя `optomstroy` (документ):

```
# m h dom mon dow command
0 3 * * * /opt/optomstroy/prod/bin/backup_db.sh >> /srv/optomstroy/prod/backups/backup.log 2>&1
```

При ошибке скрипт завершится ненулевым кодом до финального ping — Healthchecks перейдёт в `Down` и отправит алерт (см. раздел 7). Имена секрет-файлов `pg_user`, `pg_db` — условные; имя удалённого хранилища `offsite:` — условное; выбирается на этапе 2.

### 6.4. Процедура восстановления (документ)

1. Остановить `api`/`sync`: `docker compose -p optomstroy-prod stop api sync`.
2. Создать пустую БД из `template0` (или `DROP/CREATE DATABASE` под сопровождением), восстановить роли: `psql -f globals_*.sql postgres` (нужны права суперпользователя кластера).
3. `pg_restore -d <база> -j 4 optomstroy_<дата>.dump` (параллельное восстановление поддерживается custom-форматом) [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/backup-dump.html].
4. `ANALYZE` после восстановления (рекомендация документации).
5. Восстановить `media` из внешнего хранилища: `rclone sync offsite:… /srv/optomstroy/prod/media`.
6. Запустить `api`, выполнить smoke-тест (раздел 8.5), запустить ручную синхронизацию с 1С для наверстывания изменений после момента дампа.
7. Записать в журнал: дата, версия дампа, длительность, результат.

Ежемесячная проверка: шаги 2–4 и 6 выполняются в **тестовом** контуре (другой compose-проект), без остановки прода.

---

## 7. Мониторинг и алерты

| Что | Как | Детали |
|---|---|---|
| Health-эндпоинт `api` | `GET /health` (liveness: процесс жив) и `GET /ready` (readiness: БД доступна, миграции применены, последняя синхронизация не старше порога). Без авторизации, но без чувствительных данных; отдавать `503` при неготовности | Точные пути фиксирует Backend-инженер в 08_API_SPECIFICATION |
| Compose healthcheck | `healthcheck.test` для `api` (`curl -f http://localhost:8080/health`), `postgres` (`pg_isready`), `proxy`; `depends_on … condition: service_healthy` | [ПОДТВЕРЖДЕНО: https://docs.docker.com/reference/compose-file/services/#healthcheck] |
| Внешняя доступность | **Uptime Kuma** (self-hosted, MIT; команда из README: `docker run -d --restart=always -p 3001:3001 -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:2`; типы мониторов HTTP(s), Keyword, JSON Query, TCP, Ping, DNS, Push, Docker; уведомления Telegram/e-mail/Slack и др.) — ставится **на другой хост** (VPS/офисный ПК), иначе он «умрёт» вместе с сервером. **Безопасность:** `-p 3001:3001` из README публикует веб-панель на всех интерфейсах без TLS — на внешнем VPS это открытая админ-панель. Для прода публиковать `127.0.0.1:3001:3001` и выводить через reverse-proxy с HTTPS (или открывать только через VPN/firewall по IP); сменить пароль администратора при первом входе; учесть, что опубликованный порт обходит ufw (раздел 5). Альтернатива без своего хоста — внешний сервис | [ПОДТВЕРЖДЕНО: https://github.com/louislam/uptime-kuma — команда; рекомендации по публикации — ТИПОВО] |
| Cron-задачи (бэкап, синхронизация) | **Healthchecks.io** (ping-URL вида `https://hc-ping.com/<uuid>`; сигналы `/start`, `/fail`; период + grace → состояние `Down` → алерт; есть self-hosted версия) | [ПОДТВЕРЖДЕНО: https://healthchecks.io/docs/]. UUID ping-URL — секрет (хранить в `secrets/`) |
| Алерт о неудачной синхронизации с 1С | Три уровня: (1) `sync`-воркер после каждого прогона пишет `sync_runs` и пингует Healthchecks (успех — обычный ping, ошибка — `/fail`); (2) `/ready` возвращает `503` + поле `last_successful_sync_at`, если синхронизации не было дольше X минут (X = 2–3 интервала, т.е. 60–90 мин при интервале 30 мин — согласовать); Uptime Kuma с монитором JSON Query/Keyword шлёт алерт; (3) в приложении — индикатор статуса синхронизации (требование мастер-промта) | |
| Логи | Docker `json-file` с ротацией: по умолчанию `max-size=-1` (без ограничения) и `max-file=1`, т.е. **ротации нет** — задать в `/etc/docker/daemon.json` `"log-opts": {"max-size": "20m", "max-file": "5"}` (применится к новым контейнерам) и/или в compose `logging.options` | [ПОДТВЕРЖДЕНО: https://docs.docker.com/engine/logging/drivers/json-file/] |
| Централизация логов (опционально) | Grafana Loki + Promtail/Alloy — только если появится второй сервер или потребность в поиске по логам; для R1 достаточно `docker compose logs` + ротации | [НЕ ПОДТВЕРЖДЕНО — решение отложено] |
| Метрики минимально | Диск (`df`), память, CPU load, размер БД, число ошибок синхронизации за сутки, время ответа `/ready`. Для R1: скрипт в cron, пишущий в лог + алерт при `Use% > 80 %` через Healthchecks `/fail`; node_exporter + Prometheus/Grafana — R2 | |
| PostgreSQL | `pg_stat_statements` для поиска медленных запросов; `log_min_duration_statement = 500ms` [ТИПОВО] | [ПОДТВЕРЖДЕНО: https://www.postgresql.org/docs/current/pgstatstatements.html] |
| Каналы алертов | Telegram-группа администраторов + e-mail (согласовать, п. 4.3 №11) | |

---

## 8. Обновления и откат

### 8.1. Принципы

- Каждый релиз backend — образ с **неизменяемым тегом версии** (`optomstroy/api:1.4.2`, плюс сборка с `git sha`); тег `latest` в проде не используется.
- Миграции БД — только **expand/contract**: сначала добавляем (новые колонки/таблицы/индексы, nullable/с default), деплоим код, совместимый со старой и новой схемой; «удаляющая» часть (`contract`) — через один-два релиза, когда старая версия точно не вернётся. Это позволяет откатить образ без отката БД.
- Индексы на больших таблицах создаются `CREATE INDEX CONCURRENTLY` (вне транзакции) [ТИПОВО: PostgreSQL].
- Перед любой миграцией — свежий `pg_dump` (раздел 6).
- Blue/green не требуется: допустим простой 1–3 минуты в окно обслуживания; POS-клиент обязан корректно переживать недоступность backend (кэш/повторы).

### 8.2. Процедура обновления прод (документ)

1. Обновление проверено в тестовом контуре (тот же сервер, проект `optomstroy-test`, свои порты/БД/поддомен) на копии прод-данных (восстановлённый дамп, обезличенный при необходимости).
2. Объявить окно, убедиться, что синхронизация с 1С не идёт (`sync` ставится на паузу).
3. `backup_db.sh` вручную; убедиться в успешности.
4. `docker compose pull` нового тега (переменная `API_TAG=1.4.2` в `.env`).
5. Применить миграции (`expand`) отдельной командой/контейнером `migrate` — не в момент старта `api`, чтобы ошибка миграции не положила сервис.
6. `docker compose up -d api sync` — пересоздание контейнеров с новым образом.
7. Smoke-тест (8.5). Если не пройден — откат (8.3).
8. Снять паузу с `sync`, проверить первый успешный прогон.
9. Записать в журнал релизов: версия, дата, кто, результат.

### 8.3. Откат

1. `API_TAG=<предыдущая версия>` в `.env`, `docker compose up -d api sync`.
2. Благодаря expand/contract БД совместима; если миграция была разрушающей (не должно случаться) — восстановление из дампа п. 3 (раздел 6.4) с принятием потери данных за окно.
3. Smoke-тест. Запись в журнал.

### 8.4. Тест и прод на одном сервере

| Параметр | prod | test |
|---|---|---|
| Compose project | `optomstroy-prod` | `optomstroy-test` |
| Каталог | `/opt/optomstroy/prod`, `/srv/optomstroy/prod` | `/opt/optomstroy/test`, `/srv/optomstroy/test` |
| Поддомен | `pos.<домен>` (условно) | `pos-test.<домен>` (условно) — разные имена для разделения контуров (свои сертификаты, конфиги RP, учётные данные). От лимита дубликатов Let's Encrypt (5 за 7 дней на одинаковый набор имён) защищают persistent-том `caddy_data` (2.1) и staging CA при отладке (раздел 10, шаг 3), а не разные имена |
| RP | один общий Caddy может обслуживать оба имени (две сети) либо два RP на разных портах (443 и 8443) | |
| БД | свой контейнер `postgres`, том `pgdata` | свой контейнер, свой том, меньшие лимиты памяти |
| 1С | прод-1С (только чтение на пилоте) | тестовая копия 1С или режим «изолированный тест» с фикстурами (требование мастер-промта) |
| Ресурсы | лимиты по 3.3 | меньшие лимиты; можно останавливать вне тестов |

### 8.5. Smoke-тест после деплоя (минимум)

1. `GET https://<хост>/health` → 200; `GET /ready` → 200 с актуальной версией.
2. Авторизация тестового сотрудника (тестовый режим OTP, без реальной SMS).
3. Поиск товара по артикулу → ≥ 1 результат; карточка товара открывается; фото отдаётся (200, `Content-Type: image/*`).
4. Создание тестового заказа в тестовом контуре (в проде — только если согласован тестовый контрагент в 1С).
5. Ручной запуск синхронизации → `sync_runs` со статусом успех.
6. Проверка сертификата: `curl -vI https://<хост>` без ошибок, дата истечения > 20 дней.

---

## 9. Если сервер слабый или небезопасный

### 9.1. Минимальные улучшения существующего сервера

| Проблема по аудиту | Минимальное улучшение | Комментарий |
|---|---|---|
| RAM < 4 GB или занята 1С/MS SQL | Добавить RAM до 8–16 GB | Самое дешёвое и эффективное; требует остановки сервера |
| Данные на HDD | Добавить SSD/NVMe ≥ 250 GB под `/srv/optomstroy` | БД и фото на SSD, HDD остаётся под бэкапы |
| ОС вне поддержки (CentOS 7, Ubuntu ≤ 20.04, Windows Server ≤ 2012 R2) | Переустановка ОС (Ubuntu 24.04 LTS) или Linux-VM (B-3) | Переустановка «боевого» сервера с 1С — высокий риск; предпочесть VM или VPS |
| Нет статического IP / порт 443 закрыт провайдером | Заказать статический IP у провайдера или перейти к сценарию C | Стоимость у провайдера КР не исследована [НЕ ПОДТВЕРЖДЕНО] |
| Нет бэкапов, один диск | Второй диск + внешнее хранилище (раздел 6) | Обязательно независимо от сценария |
| RDP/SSH по паролю из интернета | Ключи, fail2ban, VPN | Раздел 5 |

### 9.2. Альтернатива — VPS (опубликованные тарифы; дата обращения 2026-10-18)

Требование к VPS для R1: 2–4 vCPU, 4–8 GB RAM, 80–160 GB SSD/NVMe, Linux. Цены ниже — **по официальным страницам провайдеров** там, где они открывались, иначе отмечено.

| Провайдер / локация | Тариф (vCPU / RAM / диск) | Цена | Статус |
|---|---|---|---|
| **Serverspace** (vStack), Алматы (Казахстан), Ташкент (Узбекистан) и др. | 2 vCPU / 4 GB / 80 GB SSD, 200 Mbit/s | €36,93/мес (€0,051/ч), без НДС | [ПОДТВЕРЖДЕНО: https://serverspace.io/pricing/] |
| | 4 vCPU / 8 GB / 160 GB SSD, 500 Mbit/s | €91,74/мес (€0,127/ч) | [ПОДТВЕРЖДЕНО: там же] |
| | 1 vCPU / 2 GB / 50 GB SSD | €15,38/мес | [ПОДТВЕРЖДЕНО: там же]; доп. диск €0,10/GB/мес; биллинг pay-as-you-go |
| **Timeweb Cloud**, Москва (локации Казахстан/Алматы, Нидерланды, Германия заявлены на сайте, но цены для KZ на странице не показаны) | MSK Ultra 50: 2 vCPU 3,3 ГГц / 4 GB / 50 GB NVMe | 5 480 ₽/мес | [ПОДТВЕРЖДЕНО: https://timeweb.cloud/services/cloud-servers — цены только для Москвы] |
| | MSK Ultra 40: 2 vCPU / 2 GB / 40 GB NVMe | 3 960 ₽/мес | [ПОДТВЕРЖДЕНО: там же] |
| | Cloud KZ 80 (Казахстан): 4 vCPU / 8 GB / 80 GB SSD | ~8 690 ₽/мес | [НЕ ПОДТВЕРЖДЕНО: данные агрегатора hostinghub.ru, не официальный прайс; проверить на timeweb.cloud] |
| **DigitalOcean** (Basic Droplets; ближайшие регионы — Франкфурт/Бангалор/Сингапур; латентность до КР выше) | 2 vCPU / 4 GiB / 80 GiB SSD, 4 TB трафика | $24/мес | [ПОДТВЕРЖДЕНО: https://www.digitalocean.com/pricing/droplets] |
| | 4 vCPU / 8 GiB / 160 GiB SSD | $48/мес | [ПОДТВЕРЖДЕНО: там же] |
| | 2 vCPU / 2 GiB / 60 GiB | $18/мес | [ПОДТВЕРЖДЕНО: там же] |
| **Hetzner Cloud** (Германия/Финляндия) | CX/CPX-линейки: на официальных страницах цены в момент обращения не отображались (поля «from … /mo» пустые), линейка Cost-Optimized (CX) помечена «Currently not available» | — | [ПОДТВЕРЖДЕНО: https://www.hetzner.com/cloud/ и /cloud/regular-performance/ — характеристики CPX без цен]. Сторонние источники сообщают о повышениях цен в 2026 г. и называют CX23 (2 vCPU/4 GB/40 GB) ≈ €4–6/мес, CX33 ≈ €6,5–9/мес — [НЕ ПОДТВЕРЖДЕНО], проверять в консоли Hetzner |
| **Vultr** | страница тарифов вернула HTTP 403 | — | [НЕ ПОДТВЕРЖДЕНО] |
| **Хостинг в Кыргызстане** — общее | Официальные прайсы местных провайдеров на их сайтах в рамках исследования не открывались; ниже — данные агрегаторов (устаревшие, конфигурации заведомо меньше требований R1) | — | [НЕ ПОДТВЕРЖДЕНО] — запросить КП напрямую на 2–4 vCPU / 4–8 GB RAM / 80–160 GB SSD, Linux (латентность до магазина минимальна, оплата в сомах) |
| **Hoster.kg** (Бишкек; компания с 2007 г.) | KVM-SMALL: 1 vCPU / 1 GB / 15 GB, канал до 100 Mbit/s; у провайдера есть также KVM-MIDDLE/KVM-LARGE | 800 KGS/мес без НДС (KVM-MIDDLE 1 200, KVM-LARGE 1 600 KGS/мес) | [НЕ ПОДТВЕРЖДЕНО: данные агрегатора whtop.com, запись от 2020-05-11, официальный прайс не открыт; https://www.whtop.com/plans/hoster.kg/99414 — обращение 2026-10-18]. Конфигурация мала для R1 → запросить КП на 4–8 GB RAM |
| **Borneo.kg** (Кыргызстан) | Bungalow+: 2 ядра 1,8 ГГц / 1 GB / 20 GB; Bungalow: 512 MB / 10 GB; Lounge: 40 GB | Bungalow+ 1 100 KGS/мес; Bungalow 600; Lounge 1 800 KGS/мес | [НЕ ПОДТВЕРЖДЕНО: агрегатор whtop.com, запись обновлена 2023-04-14; https://www.whtop.com/plans/borneo.kg/121146 — обращение 2026-10-18]. Мало для R1 → запросить КП |
| **ProHost** (Бишкек, ул. Ахунбаева 119а; ЦОД, компания с 2007 г.) | Колокейшн (стойки/юниты), аренда серверов, виртуальный хостинг; канал 10 Gbit/s заявлен | цены только по запросу | [НЕ ПОДТВЕРЖДЕНО: справочник datacentermap.com — https://www.datacentermap.com/kyrgyzstan/bishkek/prohost-data-center/ (обращение 2026-10-18; страница компании вернула HTTP 429 при повторной проверке), цен нет]. Кандидат для КП на VPS/аренду сервера и для колокейшна собственного сервера заказчика |
| Другие ЦОД Бишкека (по datacentermap.com) | Datatime (заявлен как TIER III*), NSP Data Center | — | [НЕ ПОДТВЕРЖДЕНО: https://www.datacentermap.com/kyrgyzstan/ — обращение 2026-10-18; услуги/цены не проверялись] — кандидаты для запроса КП |

Выводы:
- Ближайший по географии подтверждённый вариант — **Serverspace, Алматы**: ~€37/мес за минимальную и ~€92/мес за рекомендуемую конфигурацию; дополнительно диск под фото €0,10/GB/мес (100 GB ≈ €10/мес).
- Самый дешёвый подтверждённый на 4 GB RAM — DigitalOcean $24/мес, но дальше по сети (ожидаемая латентность из Бишкека до Франкфурта — десятки мс; измерить `ping`/`mtr` перед выбором [НЕ ПОДТВЕРЖДЕНО]).
- Сравнение с апгрейдом сервера заказчика: +8–16 GB RAM и SSD 250–500 GB — разовая покупка; стоимость комплектующих в КР не исследована [НЕ ПОДТВЕРЖДЕНО]. Если сервер заказчика в принципе исправен и имеет публичный IP, апгрейд обычно окупается относительно VPS за 6–12 месяцев [НЕ ПОДТВЕРЖДЕНО — оценка].
- Местные провайдеры (Hoster.kg, Borneo.kg, ProHost, Datatime, NSP) существуют, но их открытые тарифы по данным агрегаторов (2020–2023 гг.) малы для R1 (≤ 1 GB RAM); актуальные конфигурации 4–8 GB RAM и цены — только по КП. Преимущества местного размещения: минимальная латентность до магазина, оплата в сомах, локальная поддержка; риск — меньшая зрелость инфраструктуры/SLA (не проверено) [НЕ ПОДТВЕРЖДЕНО].
- Во всех VPS-вариантах 1С остаётся в магазине → сценарий C (WireGuard или исходящий обмен).

---

## 10. План первичного развёртывания (этап 2, после утверждения ТЗ и отдельного разрешения заказчика)

| Шаг | Действия | Результат / критерий | Кто |
|---|---|---|---|
| 0. Предусловия | Аудит (раздел 1) выполнен; сценарий выбран; все пункты 4.3 согласованы; ТЗ утверждено сообщением «ТЗ УТВЕРЖДЕНО. НАЧИНАЙ РАЗРАБОТКУ»; отдельное письменное разрешение на установку на сервер | Чек-лист подписан | Заказчик + Главный архитектор |
| 1. Подготовка хоста | Пользователь `optomstroy`, SSH-ключи, `sshd` без паролей (по согласованию), fail2ban, unattended-upgrades, NTP, Docker Engine + Compose v2, каталоги `/opt/optomstroy`, `/srv/optomstroy`, `daemon.json` с ротацией логов, лимиты firewall (22/80/443; C-1: + UDP WireGuard на VPS); выбор варианта прав пользователя `optomstroy` (rootless / sudo / группа `docker`, см. 4.1) | `docker compose version` работает; `ss -tulpn` и `iptables -S DOCKER-USER` — только ожидаемые порты (не только `ufw status`) | DevOps |
| 2. DNS | A-запись `pos.<домен>` (и `pos-test.<домен>`) → публичный IP; проверка `dig +short` с внешнего резолвера | Имя резолвится на сервер | Владелец домена |
| 3. TLS | Запуск RP (Caddy) с реальным именем; проверка выпуска сертификата (`curl -vI`); на время отладки — staging CA, чтобы не упереться в лимиты | HTTPS работает, редирект с HTTP | DevOps |
| 4. Секреты и конфиг | Сгенерировать пароли БД, ключи JWT; получить от заказчика учётные данные SMSPro и 1С через защищённый канал (не чат); файлы в `secrets/` с `600`; `.env` из `.env.example` | `git status` чист от секретов | DevOps + заказчик |
| 5. Деплой тест-контура | `optomstroy-test`: `postgres`, `api`, `sync` в тестовом режиме (SMS mock, 1С fixtures) | Smoke-тест 8.5 пройден | DevOps + Backend |
| 6. Миграции | Запуск контейнера `migrate` на пустой БД прод (`expand`); проверка схемы | Версия схемы = версия релиза | Backend |
| 7. Первичный импорт из 1С | Полная загрузка справочников (товары, категории, цены, остатки, клиенты, взаиморасчёты) по согласованному протоколу; **сверка количеств** объектов с 1С; загрузка фото; контроль дубликатов | Отчёт сверки: количество в 1С = количество в БД по каждой сущности; ошибки = 0 или объяснены | 1С-эксперт + Backend |
| 8. Деплой прод | `optomstroy-prod` с образом релизного тега; `sync` по расписанию 30 мин; мониторинг (Uptime Kuma на внешнем хосте, Healthchecks для cron) и первый бэкап | `/ready` 200; первый успешный `sync_run`; бэкап во внешнем хранилище | DevOps |
| 9. Smoke-тест и пилот | Раздел 8.5 + сценарии пилота из 12_TEST_PLAN на копии/тестовом контрагенте; реальные продажи — только после согласования (мастер-промт, этап I) | Протокол приёмки | QA + заказчик |
| 10. Передача | Документы: runbook (запуск/остановка/обновление/откат/восстановление), схема сети и портов, реестр секретов (где хранятся, без значений), контакты, журнал релизов; обучение админа заказчика; передача ключей/доступов | Акт передачи; админ заказчика самостоятельно выполняет обновление и восстановление в тесте | DevOps |

---

## 11. Открытые вопросы (для 14_OPEN_QUESTIONS.md)

1. ОС, ресурсы, сеть и занятые порты сервера заказчика — ждём результатов чек-листа (раздел 1).
2. Есть ли у сервера статический публичный IP и возможность открыть 443 (определяет A/B vs C).
3. Где и в каком объёме хранятся фотографии товаров; среднее число фото на SKU (определяет диск и трафик).
4. Домен/поддомен и доступ к DNS.
5. Куда складывать внешние бэкапы и кто платит за хранилище.
6. Окна обслуживания и канал алертов.
7. Способ связи с 1С (VPN vs исходящий обмен vs локальная сеть) — совместно с отчётом 1С-эксперта; доступны ли HTTP-сервисы/OData, есть ли сервер 1С (ragent) или файловая база.
8. Требования законодательства КР к хранению персональных данных и срокам хранения логов — для QA/Security.
9. Ожидаемое число документов в день и глубина истории из 1С — для уточнения роста БД.
10. Политика лицензирования Docker Desktop не актуальна, если выбран Docker Engine на Linux; если заказчик настаивает на Windows — подтвердить, что компания подпадает под бесплатное использование Docker Desktop (< 250 сотрудников **и** < $10 млн годовой выручки) [ПОДТВЕРЖДЕНО: https://docs.docker.com/desktop/setup/install/windows-install/] — и только для тестового контура.

---

## 12. Источники (дата обращения 2026-10-18)

- PostgreSQL versioning policy — https://www.postgresql.org/support/versioning/
- PostgreSQL `pg_dump` — https://www.postgresql.org/docs/current/app-pgdump.html
- PostgreSQL SQL dump / restore — https://www.postgresql.org/docs/current/backup-dump.html
- PostgreSQL continuous archiving (PITR) — https://www.postgresql.org/docs/current/continuous-archiving.html
- PostgreSQL connection settings (`listen_addresses`, `max_connections`) — https://www.postgresql.org/docs/current/runtime-config-connection.html
- PostgreSQL `pg_stat_statements` — https://www.postgresql.org/docs/current/pgstatstatements.html
- Docker Hub `postgres` image — https://hub.docker.com/_/postgres
- Docker Desktop on Windows (unsupported on Windows Server; licensing) — https://docs.docker.com/desktop/setup/install/windows-install/
- Docker Engine on Ubuntu — https://docs.docker.com/engine/install/ubuntu/
- Docker json-file logging driver — https://docs.docker.com/engine/logging/drivers/json-file/
- Docker Compose secrets — https://docs.docker.com/compose/how-tos/use-secrets/
- Docker Compose services (healthcheck, depends_on) — https://docs.docker.com/reference/compose-file/services/#healthcheck
- Microsoft: WSL on Windows Server — https://learn.microsoft.com/en-us/windows/wsl/install-on-server
- Microsoft: Linux containers on Windows (используется в 2.2, B-4; редирект на …/set-up-linux-containers) — https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/linux-containers
- Microsoft Lifecycle: Windows Server 2025 — https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2025
- Docker Engine post-install (группа `docker` = root-level privileges) — https://docs.docker.com/engine/install/linux-postinstall/
- Docker rootless mode — https://docs.docker.com/engine/security/rootless/
- Docker packet filtering and firewalls (Docker и ufw) — https://docs.docker.com/engine/network/packet-filtering-firewalls/
- Docker Compose networks (`internal`) — https://docs.docker.com/reference/compose-file/networks/
- CentOS Linux EOL — https://www.centos.org/centos-linux-eol/ ; https://www.redhat.com/en/topics/linux/centos-linux-eol
- Агрегаторы хостинга КР (не официальные прайсы) — https://www.whtop.com/plans/hoster.kg/99414 ; https://www.whtop.com/plans/borneo.kg/121146 ; https://www.datacentermap.com/kyrgyzstan/bishkek/prohost-data-center/ ; https://www.datacentermap.com/kyrgyzstan/
- Microsoft: OpenSSH Server for Windows — https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse
- Microsoft Lifecycle: Windows Server 2019 — https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2019
- Microsoft Lifecycle: Windows Server 2022 — https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2022
- Ubuntu release cycle — https://ubuntu.com/about/release-cycle
- Ubuntu automatic updates — https://ubuntu.com/server/docs/how-to/software/automatic-updates/
- Debian releases — https://www.debian.org/releases/
- Caddy automatic HTTPS — https://caddyserver.com/docs/automatic-https
- Certbot (nginx, snap) — https://certbot.eff.org/instructions?ws=nginx&os=snap
- Let's Encrypt rate limits — https://letsencrypt.org/docs/rate-limits/
- WireGuard — https://www.wireguard.com/ ; установка — https://www.wireguard.com/install/
- fail2ban — https://github.com/fail2ban/fail2ban
- Uptime Kuma — https://github.com/louislam/uptime-kuma
- Healthchecks.io docs — https://healthchecks.io/docs/
- WinSW — https://github.com/winsw/winsw ; NSSM — https://nssm.cc/
- 1С: оглавление руководства администратора 8.3.24, раздел о веб-серверах — https://its.1c.ru/db/v8324doc/content/113/1 (содержимое раздела недоступно без авторизации; параметры `webinst` не приводятся)
- Порты кластера 1С (неофициально; при проверке 2026-10-18 страница вернула HTTP 429, содержимое не верифицировано) — https://infostart.ru/1c/articles/377023/
- Serverspace pricing — https://serverspace.io/pricing/
- Timeweb Cloud servers — https://timeweb.cloud/services/cloud-servers
- DigitalOcean Droplet pricing — https://www.digitalocean.com/pricing/droplets
- Hetzner Cloud — https://www.hetzner.com/cloud/ ; https://www.hetzner.com/cloud/regular-performance/ (цены не отображались)

---

## 13. Журнал проверки (исправления по замечаниям независимого проверяющего, 2026-10-18)

| # | Серьёзность | Где | Что исправлено | Источник проверки (обращение 2026-10-18) |
|---|---|---|---|---|
| 1 | major | 2.1 таблица состава; 4.1 «Сети Docker»; 4.2; 5 «БД не доступна из интернета» | Устранено противоречие: `sync` (и `pgadmin`) подключены к обеим сетям `edge` + `backend`; `postgres` — только в `backend` (`internal: true`) без `ports:`; убран нерабочий вариант `127.0.0.1:5433:5432` для контейнера в internal-сети; описан админ-доступ к БД (SSH-туннель + `docker compose exec psql`, временное подключение к `edge`); добавлена колонка «Исходящие соединения» (1С, SMSPro, реестр образов, ACME CA, apt) | https://docs.docker.com/reference/compose-file/networks/ (`internal` — «externally isolated network»); непробрасывание портов internal-сети — [ТИПОВО] |
| 2 | major | 9.2 «Хостинг в Кыргызстане», выводы 9.2 | Добавлены строки Hoster.kg (KVM-SMALL 800 KGS/мес, 1 vCPU/1 GB/15 GB), Borneo.kg (Bungalow+ 1 100 KGS/мес, 2 ядра/1 GB/20 GB), ProHost (Бишкек, цены по запросу), Datatime и NSP как кандидаты для КП; все со статусом [НЕ ПОДТВЕРЖДЕНО: агрегатор], с рекомендацией запросить КП на 2–4 vCPU / 4–8 GB / 80–160 GB SSD | whtop.com (записи 2020/2023 гг.), datacentermap.com (страница компании ProHost вернула HTTP 429) |
| 3 | minor | 6.2 «Обоснование» | Переформулировано: приведена точная цитата app-pgdump.html («except in simple cases … not the right choice»), PITR-параметры отнесены к continuous-archiving.html; отнесение R1 к «простому случаю» помечено как инженерное решение | https://www.postgresql.org/docs/current/app-pgdump.html |
| 4 | minor | 1.2 п. 1 | Указано, что на дату отчёта Windows Server 2022 уже в extended-поддержке (до 2031-10-15), 2019 — extended до 2029-01-10; добавлен Windows Server 2025 (mainstream до 2029-11-14, extended до 2034-11-15) | https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2025 |
| 5 | minor | 2.2 «Общее для B» | Переформулировано как архитектурное решение (обращение к 1С только через HTTP-сервисы/OData), без приписывания требования мастер-промту; упомянуто, что мастер-промт запрещает прямое подключение именно Flutter | MASTER_PROMPT_extracted.md, строка 89 |
| 6 | minor | 1.1 п. 1–3 | Пороги «ядро < 5.x», «< 2 ядер» помечены [НЕ ПОДТВЕРЖДЕНО — инженерный порог]; даты EOL CentOS Linux 7/8 даны со ссылками; формулировка про AVX заменена на «не критично для выбранного стека» | https://www.centos.org/centos-linux-eol/ (CentOS 8 — 2021-12-31); https://www.redhat.com/en/topics/linux/centos-linux-eol (CentOS 7 — 2024-06-30); https://docs.docker.com/engine/install/ubuntu/ (архитектуры) |
| 7 | minor | 1.1 п. 19 | В команду `fio` добавлен `--ioengine=libaio`; оговорено, что `fio` не устанавливается в рамках аудита (иначе — только `dd`) | [ТИПОВО: документация fio] |
| 8 | minor | 4.1 «Пользователь ОС»; 5 «Минимальные права»; 10 шаг 1 | Явно указан риск группы `docker` (root-эквивалент) и три варианта: rootless Docker (+ `ip_unprivileged_port_start`/хостовый RP), `sudo` с ограниченным sudoers, принятие риска с обоснованием | https://docs.docker.com/engine/install/linux-postinstall/ (цитата подтверждена); https://docs.docker.com/engine/security/rootless/ (режим подтверждён; настройка привилегированных портов на загруженной странице не найдена — [ТИПОВО]) |
| 9 | minor | 5 «Сетевая фильтрация»; 2.3 C-1; 10 шаг 1 | Добавлен входящий UDP-порт WireGuard на VPS для C-1; добавлено замечание, что опубликованные порты контейнеров обходят ufw, проверка — `ss -tulpn` и `iptables -S DOCKER`/`DOCKER-USER` (имена цепочек — [ТИПОВО], на странице документации не названы) | https://docs.docker.com/engine/network/packet-filtering-firewalls/ («effectively ignoring your firewall configuration») |
| 10 | minor | 8.4 «Поддомен»; 2.1 вывод по лимитам LE | Обоснование заменено: разные имена — для разделения контуров; от лимита дубликатов защищают persistent-том сертификатов и staging CA | https://letsencrypt.org/docs/rate-limits/ (ранее подтверждено) |
| 11 | minor | 11 п. 10 | Дополнено вторым условием бесплатного Docker Desktop: < 250 сотрудников **и** < $10 млн выручки | https://docs.docker.com/desktop/setup/install/windows-install/ |
| 12 | minor | 2.2 таблица B; 12 «Источники» | Добавлена строка B-4 «Контейнеры Windows / Linux-контейнеры на Windows-хосте» с выводом «отвергнут» (Linux-образы требуют виртуализации; официальный путь — Docker Desktop, что возвращает к ограничениям B-1); источник Microsoft теперь используется в тексте | https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/linux-containers (редирект на set-up-linux-containers) |
| 13 | minor | 5 «Windows (сценарий B)» | Добавлены: Windows Update/WSUS с окном перезагрузки, согласованным с 1С; ограничение RDP/SSH по IP/VPN; Account Lockout Policy как аналог fail2ban; NLA — всё [ТИПОВО] | — |
| 14 | minor | 7 «Внешняя доступность» | Добавлена оговорка о безопасности Uptime Kuma: публиковать `127.0.0.1:3001:3001` за HTTPS-reverse-proxy либо только через VPN/firewall; сменить пароль администратора; учесть обход ufw | https://github.com/louislam/uptime-kuma (команда — подтверждена ранее) |
| 15 | minor | 1.1 п. 10; 12 «Источники» | Добавлена пометка: страница Infostart не открылась при проверке (HTTP 429), содержимое не верифицировано; 1С-эксперту подтвердить порты по официальному руководству администратора (its.1c.ru) | https://infostart.ru/1c/articles/377023/ — HTTP 429 при повторной проверке 2026-10-18 |

Не изменено (замечаний нет, но проверено повторно): цитата Docker Desktop о неподдержке на Windows Server; условия лицензирования Docker Desktop в 2.2 (оба условия были указаны верно).
