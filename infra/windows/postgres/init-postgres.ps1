<#
.SYNOPSIS
  Инициализация кластера PostgreSQL 17.10 Optomstroy на Windows Server 2022 и регистрация службы OptomstroyPostgres.

.DESCRIPTION
  Что делает (по порядку):
    1. Проверяет бинарные файлы (-PgBin: initdb, pg_ctl, postgres; версия 17), права администратора и отсутствие
       службы (до любых изменений на диске), пустой -DataDir, свободный -Port и файл секрета pg_password (пароль
       суперпользователя: одна строка ASCII, без BOM).
    1а. Обязательная проверка общей учётной записи: какие ещё службы работают под -ServiceAccount (журнал
       <LogDir>\precheck-service-account.log). Сторонние службы (не из %SystemRoot%) под ней — остановка до
       изменений на диске, если не задан -AcceptSharedServiceAccount (при -DevTest/-Resume/-ConfigOnly —
       предупреждение). Для NT SERVICE\<имя> проверять нечего.
    2. Закрывает -DataDir и -LogDir: наследование прав от родителя отключается, права — только Administrators,
       SYSTEM (и на время initdb — запускающему; без -DevTest право снимается после регистрации службы).
    3. initdb: UTF8, --data-checksums, scram-sha-256, локаль как в Linux-комплекте и local-stack.mjs —
       провайдер builtin C.UTF-8 (lower()/upper() по Unicode), LC_COLLATE C, LC_CTYPE en-US (классификация кириллицы
       для FTS и pg_trgm; 16 §4.4 (а)). Пароль initdb читает из копии файла секрета во временной папке журналов
       (--pwfile; копия удаляется при любом исходе), в командную строку он не попадает.
    4. Пишет <DataDir>\optomstroy.conf (подключается строкой include в конце postgresql.conf): 127.0.0.1:<Port>,
       память для совместной работы с 1С и SQL Server, WAL для PITR (archive_command вызывает инструмент резервного
       копирования), журналы в -LogDir; и pg_hba.conf: только 127.0.0.1, только scram-sha-256.
    5. Права для стандартной archive_command: учётной записи службы — чтение корня (только сама папка), releases
       (чтение и выполнение), config\backup.json (чтение), спул WAL из walSpoolDir (изменение).
    6. Без -DevTest (администратор): регистрирует службу (pg_ctl register, учётная запись -ServiceAccount, по умолчанию
       NT AUTHORITY\NetworkService), выдаёт ей изменение -DataDir и -LogDir, снимает временное право запускающего,
       проверяет права папок, действия при сбое (перезапуск, failureflag), запускает.
       С -DevTest (проверка без прав администратора): служба не создаётся, сервер запускается pg_ctl start.
  Роли и база создаются отдельно: apply-roles.ps1 (там же — проверка архивирования WAL). Остановка и снятие
  службы: stop-postgres.ps1.
  -ConfigOnly: кластер уже есть — переписать только optomstroy.conf и pg_hba.conf (затем перезапуск службы).
  -Resume: продолжить после сбоя на шагах 5–6 (initdb уже прошёл, PG_VERSION есть): initdb пропускается,
  существующая служба не регистрируется заново; права, действия при сбое и запуск выполняются.

.EXAMPLE
  # Администратор, на сервере:
  .\init-postgres.ps1 -PgBin 'C:\Program Files\PostgreSQL\17\bin' -InstallRoot D:\Optomstroy
  # После сбоя регистрации/прав/запуска (кластер уже создан):
  .\init-postgres.ps1 -PgBin 'C:\Program Files\PostgreSQL\17\bin' -InstallRoot D:\Optomstroy -Resume
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgBin,
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$DataDir = '',
    [ValidateRange(1024, 65535)][int]$Port = 5433,
    [string]$SecretsDir = '',
    [string]$LogDir = '',
    [string]$ServiceName = 'OptomstroyPostgres',
    [string]$ServiceAccount = 'NT AUTHORITY\NetworkService',
    [ValidatePattern('^[a-z_][a-z0-9_]*$')][string]$Superuser = 'postgres',
    # Память: PostgreSQL делит сервер с 1С и SQL Server (план §3: 1,5–2,5 ГБ на PostgreSQL). 1GB — при 8 ГБ на нашу
    # часть; при 4 ГБ — 512MB (как PG_SHARED_BUFFERS Linux-комплекта).
    [ValidatePattern('^\d+(kB|MB|GB)$')][string]$SharedBuffers = '1GB',
    [ValidatePattern('^\d+(kB|MB|GB)$')][string]$EffectiveCacheSize = '2GB',
    [ValidatePattern('^\d+(kB|MB|GB)$')][string]$MaintenanceWorkMem = '128MB',
    [ValidateRange(20, 1000)][int]$MaxConnections = 100,
    [ValidateSet('on', 'off')][string]$ArchiveMode = 'on',
    # Конфигурация инструмента резервного копирования (пакет infra/windows/backup).
    [string]$BackupConfig = '',
    # Полная команда archive_command вместо стандартной (проверочный прогон); %p и %f обязательны.
    # С ней права для архивирования скрипт не выдаёт — их выдаёт тот, кто задал команду.
    [string]$ArchiveCommand = '',
    [string]$LcCtype = 'en-US',
    # Обязательная проверка общей учётной записи (шаг 1а): под -ServiceAccount работают сторонние службы (не из
    # %SystemRoot%) — регистрация останавливается. Этот ключ — осознанное согласие администратора (пишется в журнал);
    # лучше — -ServiceAccount 'NT SERVICE\OptomstroyPostgres' (см. README).
    [switch]$AcceptSharedServiceAccount,
    [switch]$DevTest,
    [switch]$ConfigOnly,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pg-common.ps1')

if ($ConfigOnly -and $Resume) { throw '-ConfigOnly и -Resume вместе не используются' }
if ($DataDir -eq '') { $DataDir = Join-Path $InstallRoot 'data\pg' }
if ($SecretsDir -eq '') { $SecretsDir = Join-Path $InstallRoot 'secrets' } # check-secrets: allow — путь к папке секретов, не значение
if ($LogDir -eq '') { $LogDir = Join-Path $InstallRoot 'logs\pg' }
if ($BackupConfig -eq '') { $BackupConfig = Join-Path $InstallRoot 'config\backup.json' }
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$DataDir = [System.IO.Path]::GetFullPath($DataDir)
$LogDir = [System.IO.Path]::GetFullPath($LogDir)

$defaultArchive = ($ArchiveCommand -eq '')
if ($defaultArchive) {
    # Контракт пакета резервного копирования: node.exe и pos-backup.mjs активного релиза (через junction current —
    # после переключения релиза архивирование само берёт новую версию инструмента), конфигурация — config\backup.json.
    $node = Join-Path $InstallRoot 'current\node\node.exe'
    $tool = Join-Path $InstallRoot 'current\backup\pos-backup.mjs'
    $ArchiveCommand = '"' + $node + '" "' + $tool + '" wal-archive --config "' + $BackupConfig + '" "%p" "%f"'
}
if ($ArchiveCommand -notmatch '%p' -or $ArchiveCommand -notmatch '%f') { throw '-ArchiveCommand должна содержать %p и %f' }

Assert-PgBin $PgBin
$initdb = Join-Path $PgBin 'initdb.exe'
$pgctl = Join-Path $PgBin 'pg_ctl.exe'

# ---------- 1. Проверки до любых изменений на диске ----------
$serviceExists = $false
if (-not $DevTest) {
    if (-not (Test-IsAdministrator)) { throw 'Нужны права администратора (или -DevTest для проверочного прогона)' }
    $serviceExists = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
    if (-not $ConfigOnly -and -not $Resume -and $serviceExists) {
        throw "Служба $ServiceName уже существует — продолжить после сбоя: -Resume; заново: stop-postgres.ps1 -Unregister (данные не удаляются)"
    }
}

# ---------- 1а. Общая учётная запись службы (обязательная проверка; журнал — <LogDir>\precheck-service-account.log) ----------
# Службы под той же учётной записью получают те же права, что PostgreSQL (data\pg, спул WAL). Сторонние среди них —
# остановка до любых изменений на диске, если служба ещё не зарегистрирована (при -Resume/-ConfigOnly учётная запись
# уже выбрана — только предупреждение) и нет -AcceptSharedServiceAccount. -DevTest службу не регистрирует —
# предупреждение.
$precheck = Get-PgServiceAccountPrecheck -ServiceAccount $ServiceAccount -ServiceName $ServiceName
foreach ($l in $precheck.Lines) { Write-PgStep "проверка учётной записи: $l" }
$precheckVerdict = 'OK'
if ($precheck.ThirdParty.Count -gt 0) {
    $names = ($precheck.ThirdParty | ForEach-Object { $_.Name }) -join ', '
    $advice = "под $ServiceAccount работают сторонние службы ($names): они смогут изменить pg_hba.conf и спул WAL. " +
        "Рекомендуется -ServiceAccount 'NT SERVICE\$ServiceName' (виртуальная учётная запись; README, раздел «Учётная запись службы»)"
    if ($DevTest -or $ConfigOnly -or $serviceExists) {
        $precheckVerdict = 'WARN'
        Write-Warning $advice
    } elseif ($AcceptSharedServiceAccount) {
        $precheckVerdict = 'ACCEPTED'
        Write-Warning "$advice — продолжение по -AcceptSharedServiceAccount (записано в журнал)"
    } else {
        throw "$advice. Продолжить с общей учётной записью осознанно: -AcceptSharedServiceAccount. Ничего не изменено."
    }
}
Write-PgStep "проверка учётной записи службы: $precheckVerdict"

$ver = Get-PgServerVersion $PgBin ([System.IO.Path]::GetTempPath())
if ($ver.Major -ne 17) { throw "Нужен PostgreSQL 17 (комплект проверен на 17.10), в -PgBin версия $ver" }
if ($ver -ne (New-Object System.Version(17, 10))) { Write-Warning "PostgreSQL ${ver}: комплект проверен на 17.10" }
Write-PgStep "PostgreSQL $ver ($PgBin)"

$pgVersionFile = Join-Path $DataDir 'PG_VERSION'
$runInitdb = -not ($ConfigOnly -or $Resume)
if (-not $runInitdb) {
    if (-not (Test-Path -LiteralPath $pgVersionFile)) { throw "в $DataDir нет кластера (PG_VERSION) — -ConfigOnly/-Resume неприменимы" }
} else {
    if ((Test-Path -LiteralPath $DataDir) -and @(Get-ChildItem -LiteralPath $DataDir -Force).Count -gt 0) {
        throw "Каталог данных $DataDir не пуст — initdb не выполняется (существующий кластер: -ConfigOnly; после сбоя: -Resume)"
    }
    if (Test-PortListening $Port) { throw "Порт $Port уже занят (Get-NetTCPConnection -LocalPort $Port -State Listen)" }
    $pwFile = Join-Path $SecretsDir 'pg_password'
    Assert-PasswordFile $pwFile 'pg_password'
}

# ---------- 2. Закрытые папки данных и журналов ----------
# Без отключения наследования любая локальная учётная запись (службы 1С, SQL Server, пользователи RDP) могла бы
# изменить pg_hba.conf (trust) и получить базу. Запускающему — временное полное право: initdb под администратором
# перезапускает себя с ограниченным маркером (группа Administrators в нём только запрещающая), и без явного права
# своей учётной записи не смог бы писать в папку. Без -DevTest это право снимается после регистрации службы.
$meSid = Get-PgCurrentUserSid
$baseSids = @($script:PgSidAdministrators, $script:PgSidSystem)
$tmpOut = Join-Path $LogDir '.tmp'
if (-not $ConfigOnly) {
    foreach ($d in @($DataDir, $LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-PgPrivateAcl -Path $d -FullSids ($baseSids + @($meSid))
    }
    Write-PgStep "права $DataDir и $LogDir`: наследование отключено; Administrators, SYSTEM, запускающий"
}
New-Item -ItemType Directory -Force -Path $tmpOut | Out-Null
# Журнал обязательной проверки (шаг 1а) — в закрытой папке журналов PostgreSQL, дописывается при каждом запуске.
$precheckLog = Join-Path $LogDir 'precheck-service-account.log'
$mode = if ($DevTest) { 'DevTest' } elseif ($ConfigOnly) { 'ConfigOnly' } elseif ($Resume) { 'Resume' } else { 'install' }
$logText = (@("=== $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')) init-postgres.ps1 ($mode), служба $ServiceName, итог: $precheckVerdict") +
    @($precheck.Lines)) -join "`r`n"
$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::AppendAllText($precheckLog, $logText + "`r`n", $enc)
Write-PgStep "журнал проверки учётной записи: $precheckLog"

# ---------- 3. initdb ----------
if ($runInitdb) {
    $pwCopy = Join-Path $tmpOut ('initdb-pw-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.File]::Copy($pwFile, $pwCopy)
        Write-PgStep "initdb → $DataDir (UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE $LcCtype, scram-sha-256, контрольные суммы)"
        $code = Invoke-PgNative -FilePath $initdb -OutDir $tmpOut -ArgumentList @(
            '-D', $DataDir, '-U', $Superuser, "--pwfile=$pwCopy", '-E', 'UTF8', '--data-checksums',
            '--locale-provider=builtin', '--builtin-locale=C.UTF-8',
            '--locale=C', "--lc-ctype=$LcCtype",
            '--auth-local=scram-sha-256', '--auth-host=scram-sha-256')
    } finally {
        Remove-Item -LiteralPath $pwCopy -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { throw "initdb завершился с кодом $code" }
}

# ---------- 4. optomstroy.conf и pg_hba.conf ----------
$q = { param($v) ConvertTo-PgConfString $v }
$logDirConf = $LogDir.Replace('\', '/')
$conf = @"
# optomstroy.conf — параметры Optomstroy (infra/windows/postgres/init-postgres.ps1). Файл перезаписывается
# скриптом (-ConfigOnly); свои изменения вносите в параметры скрипта, а не сюда.
# Сеть: только локальные процессы (Apache проксирует на API, а не на PostgreSQL). Unix-сокеты не используются.
listen_addresses = '127.0.0.1'
port = $Port
unix_socket_directories = ''
max_connections = $MaxConnections
password_encryption = 'scram-sha-256' # check-secrets: allow — имя метода хеширования, не секрет

# Память: сервер общий с 1С и SQL Server (ограничьте max server memory SQL Server). Жёсткого предела памяти
# процесса (как memory в compose.prod.yml) на Windows нет: объём задают shared_buffers и work_mem × соединения.
shared_buffers = $SharedBuffers
effective_cache_size = $EffectiveCacheSize
work_mem = 16MB
maintenance_work_mem = $MaintenanceWorkMem
huge_pages = off

shared_preload_libraries = 'pg_stat_statements'
timezone = 'UTC'
log_timezone = 'UTC'

# WAL и непрерывное архивирование (PITR; RUNBOOK §4.8, 16 §8.1 «RPO при PITR ≤ 15 мин»).
wal_level = replica
archive_mode = $ArchiveMode
archive_command = $(& $q $ArchiveCommand)
archive_timeout = 60
wal_keep_size = 256MB

# Журналы: неделя по дням (postgresql-Mon.log …), файл дня перезаписывается через неделю.
logging_collector = on
log_directory = $(& $q $logDirConf)
log_filename = 'postgresql-%a.log'
log_rotation_age = 1d
log_rotation_size = 0
log_truncate_on_rotation = on
log_line_prefix = '%m [%p] %q%u@%d '
log_min_duration_statement = 500ms
log_checkpoints = on
"@
Write-Utf8NoBom (Join-Path $DataDir 'optomstroy.conf') ($conf.Replace("`r`n", "`n") + "`n")

$mainConf = Join-Path $DataDir 'postgresql.conf'
$includeLine = "include 'optomstroy.conf'"
$mainText = [System.IO.File]::ReadAllText($mainConf)
if ($mainText -notmatch "(?m)^\s*include\s+'optomstroy\.conf'") {
    $add = "`n# Optomstroy: параметры комплекта (последними — перекрывают значения выше)`n$includeLine`n"
    Write-Utf8NoBom $mainConf ($mainText.TrimEnd() + "`n" + $add)
}

$hba = @"
# pg_hba.conf — Optomstroy (init-postgres.ps1). Только локальные TCP-подключения 127.0.0.1, только scram-sha-256.
# TYPE  DATABASE     USER        ADDRESS        METHOD
host    all          all         127.0.0.1/32   scram-sha-256
# Базовая копия PITR: pg_basebackup роли pos_backup (атрибут REPLICATION; RUNBOOK §4.8)
host    replication  pos_backup  127.0.0.1/32   scram-sha-256
"@
Write-Utf8NoBom (Join-Path $DataDir 'pg_hba.conf') ($hba.Replace("`r`n", "`n") + "`n")
Write-PgStep "optomstroy.conf и pg_hba.conf записаны (127.0.0.1:$Port, archive_mode=$ArchiveMode, журналы $LogDir)"
Write-PgStep "archive_command: $ArchiveCommand"

if ($ConfigOnly) {
    if (-not $DevTest) {
        # Только предупреждение: -ConfigOnly меняет параметры и не должен блокироваться из-за прав.
        $svcSidCheck = $null
        try { $svcSidCheck = Resolve-PgSid $ServiceAccount } catch { Write-Warning $_.Exception.Message }
        if ($svcSidCheck) {
            foreach ($d in @($DataDir, $LogDir)) {
                foreach ($p in (Test-PgPrivateAcl $d ($baseSids + @($svcSidCheck)))) { Write-Warning "права: $p (исправление: init-postgres.ps1 -Resume)" }
            }
        }
    }
    Write-PgStep 'Готово (-ConfigOnly). Применение: перезапуск службы (Restart-Service) или pg_ctl restart.'
    Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
    return
}

# ---------- 5. Права для archive_command ----------
function Grant-ArchiveIfNeeded([string]$Sid) {
    if ($ArchiveMode -ne 'on') { Write-PgStep 'archive_mode=off: права для archive_command не нужны'; return }
    if (-not $defaultArchive) { Write-Warning 'Задана своя -ArchiveCommand: права учётной записи службы на её файлы выдайте сами'; return }
    $g = Grant-PgArchiveAccess -InstallRoot $InstallRoot -BackupConfig $BackupConfig -Sid $Sid
    Write-PgStep "archive_command: $ServiceAccount — RX $InstallRoot (только папка), RX $($g.Releases), R $BackupConfig, M $($g.Spool)"
}

# ---------- 6. запуск ----------
if ($DevTest) {
    # Права выдаются и здесь (на свои папки прогона права администратора не нужны) — проверяется сама команда.
    Grant-ArchiveIfNeeded (Resolve-PgSid $ServiceAccount)
    if (Test-PortListening $Port) { throw "Порт $Port уже занят — сервер уже запущен?" }
    Write-PgStep "DevTest: служба не регистрируется; pg_ctl start (127.0.0.1:$Port)"
    $code = Invoke-PgNative -FilePath $pgctl -OutDir $tmpOut -ArgumentList @(
        'start', '-D', $DataDir, '-l', (Join-Path $LogDir 'pg_ctl.log'), '-w', '-t', '90')
    if ($code -ne 0) { throw "pg_ctl start завершился с кодом $code (журнал: $LogDir)" }
} else {
    # Учётная запись службы. По умолчанию NetworkService (как установщик EDB): без пароля, не администратор
    # (postgres.exe под администратором не запускается). Виртуальная учётная запись NT SERVICE\<имя службы> тоже
    # передаётся в pg_ctl register (-U с «\» без изменений), но на Windows Server не проверялась — см. README.
    if ($serviceExists) {
        Write-PgStep "-Resume: служба $ServiceName уже зарегистрирована — pg_ctl register пропущен"
    } else {
        Write-PgStep "pg_ctl register -N $ServiceName -U $ServiceAccount (автозапуск)"
        $code = Invoke-PgNative -FilePath $pgctl -OutDir $tmpOut -ArgumentList @(
            'register', '-N', $ServiceName, '-U', $ServiceAccount, '-D', $DataDir, '-S', 'auto', '-w', '-t', '120')
        if ($code -ne 0) { throw "pg_ctl register завершился с кодом $code (продолжить после исправления: -Resume)" }
    }
    # Права выдаются после регистрации: SID виртуальной учётной записи появляется вместе со службой.
    $svcSid = Resolve-PgSid $ServiceAccount
    Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($d in @($DataDir, $LogDir)) {
        Set-PgPrivateAcl -Path $d -FullSids $baseSids -ModifySids @($svcSid) -RemoveSids @($meSid | Where-Object { $baseSids -notcontains $_ })
        Invoke-PgIcacls @($d, '/setowner', "*$($script:PgSidAdministrators)", '/T', '/C', '/Q')
        $problems = Test-PgPrivateAcl $d ($baseSids + @($svcSid))
        if ($problems.Count -gt 0) { throw ("Права папки не закрыты:`n" + ($problems -join "`n")) }
    }
    Write-PgStep "права $DataDir и $LogDir`: только Administrators, SYSTEM (F) и $ServiceAccount (M); проверено"
    Grant-ArchiveIfNeeded $svcSid
    & sc.exe description $ServiceName 'Optomstroy: PostgreSQL 17 (127.0.0.1)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe description завершился с кодом $LASTEXITCODE" }
    & sc.exe failure $ServiceName reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe failure завершился с кодом $LASTEXITCODE" }
    # Перезапуск и тогда, когда служба сама сообщает «остановлена» с кодом ошибки (а не только при аварии процесса).
    & sc.exe failureflag $ServiceName 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe failureflag завершился с кодом $LASTEXITCODE" }
    if ((Get-Service -Name $ServiceName).Status -ne 'Running') { Start-Service -Name $ServiceName }
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
}

$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-PortListening $Port) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (-not (Test-PortListening $Port)) { throw "PostgreSQL не слушает порт $Port (журнал: $LogDir)" }
$listen = @(Get-NetTCPConnection -State Listen -LocalPort $Port | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" })
Write-PgStep ("PostgreSQL запущен; слушает: " + ($listen -join ', '))
foreach ($l in $listen) { if ($l -notlike '127.0.0.1:*') { throw "PostgreSQL слушает не только 127.0.0.1: $l" } }
Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
Write-PgStep 'Готово. Далее: apply-roles.ps1 (роли, база, стоп-проверка локали, проверка архивирования WAL).'
