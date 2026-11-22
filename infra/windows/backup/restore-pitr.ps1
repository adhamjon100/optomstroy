<#
.SYNOPSIS
  Восстановление PostgreSQL на момент времени (PITR) под Windows: базовая копия + архив WAL.

.DESCRIPTION
  Выполняет администратор в присутствии держателя закрытого ключа (ключ приносится на время сеанса, на сервере
  не остаётся). Рабочая база при этом НЕ трогается: кластер восстанавливается рядом, в новую пустую папку
  (-DataDir), и запускается на временном порту только на 127.0.0.1 для проверки. Подмену рабочей базы
  выполняет второй запуск с -Apply (после проверки).

  Порядок (16 §8.5, вариант PITR; RUNBOOK §4.8):
    1. Остановка OptomstroyApi, OptomstroyWorker, OptomstroyBackup (без -DevTest).
    1а. Конец WAL в архив: pg_switch_wal() на рабочем кластере (суперпользователь: -SuperPassFile или ввод
       пароля), ожидание архивации (pg_stat_archiver), pos-backup.mjs wal-ship. Рабочий кластер недоступен —
       предупреждение; -SkipWalFlush — пропуск шага.
    2. Выбор базовой копии: самая новая, закончившаяся раньше -TargetTime (или самая новая при -Latest).
    3. Распаковка базовой копии в -DataDir (расшифровка, gunzip, tar — pos-backup.mjs restore-base; оценка места).
    4. Расшифровка WAL с начала базовой копии во временную папку (pos-backup.mjs wal-unpack): проверка
       непрерывности номеров сегментов и места на диске. Дыра или повреждённый сегмент: с -Latest — отказ
       (иначе восстановление молча остановилось бы на дыре), с -TargetTime — предупреждение; -AllowWalGap — осознанно.
    5. В postgresql.auto.conf: restore_command (copy из папки WAL), recovery_target_time, promote;
       logging_collector=off (журнал только в -l, не в общую папку logs\pg рабочего кластера);
       archive_mode=off (проверочный кластер ничего не пишет в архив рабочего), порт и адрес 127.0.0.1;
       файл recovery.signal.
    6. Запуск pg_ctl на временном порту, ожидание конца восстановления (recovery.signal удалён, в журнале
       «database system is ready to accept connections»), проверка журнала на ошибки восстановления.
    7. Итог: на каком месте остановлено восстановление. Дальше — проверка данных и -Apply.

  С -Apply (администратор, после проверки):
    останавливает временный кластер, убирает строки восстановления из postgresql.auto.conf, останавливает
    OptomstroyPostgres, переименовывает рабочую папку данных в pg-before-<время>, переносит восстановленную на её
    место, закрывает права как init-postgres.ps1 (без наследования; Administrators и SYSTEM — F, учётная запись
    службы PostgreSQL — M; владелец Administrators; проверка), архивирует файлы .history новой линии времени,
    запускает OptomstroyPostgres. Затем нужно сразу сделать новую базовую копию (backup.ps1 -Action base-now) и
    запустить службы программы (подсказка в конце).

.EXAMPLE
  .\restore-pitr.ps1 -KeyFile E:\key\backup-private.pem -TargetTime '2026-11-21 14:05:00+06:00' -DataDir D:\Optomstroy\data\pg-restore
.EXAMPLE
  .\restore-pitr.ps1 -Apply -DataDir D:\Optomstroy\data\pg-restore
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$BackupRoot = 'D:\OptomstroyBackups',
    [string]$SystemIdentifier,
    [string]$KeyFile,
    [string]$TargetTime,
    [switch]$Latest,
    [string]$PgBin = 'C:\Program Files\PostgreSQL\17\bin',
    [Parameter(Mandatory = $true)][string]$DataDir,
    [string]$WalStageDir,
    [int]$Port = 5434,
    [int]$TimeoutMinutes = 120,
    [string]$NodeExe,
    [string]$PgServiceName = 'OptomstroyPostgres',
    [string]$PgServiceAccount = 'NT AUTHORITY\NetworkService',
    [string]$BackupConfig,
    [int]$LivePort = 5433,
    [string]$SuperUser = 'postgres',
    [string]$SuperPassFile,
    [switch]$SkipWalFlush,
    [switch]$AllowWalGap,
    [switch]$Apply,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

$tool = Join-Path $PSScriptRoot 'pos-backup.mjs'
$pgCtl = Join-Path $PgBin 'pg_ctl.exe'
if (-not (Test-Path -LiteralPath $pgCtl)) { Stop-WithError "pg_ctl.exe не найден в $PgBin" }
if (-not $DevTest -and -not (Test-IsAdmin)) { Stop-WithError 'нужен PowerShell «от имени администратора» (или -DevTest для проверочного стенда)' }
$node = Resolve-NodeExe -NodeExe $NodeExe -InstallRoot $InstallRoot -DevTest:$DevTest
if (-not $WalStageDir) { $WalStageDir = "$DataDir-wal" }
if (-not $BackupConfig) { $BackupConfig = Join-Path $InstallRoot 'config\backup.json' }
$markBegin = '# pos-backup restore-pitr BEGIN'
$markEnd = '# pos-backup restore-pitr END'
$logFile = "$DataDir-recovery.log"

if ($Apply) {
    if ($DevTest) { Stop-WithError '-Apply не выполняется в режиме -DevTest' }
    Write-Step 'Подмена рабочей базы восстановленной (-Apply)'
    if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'PG_VERSION'))) { Stop-WithError "в $DataDir нет восстановленного кластера" }
    if (Test-Path -LiteralPath (Join-Path $DataDir 'recovery.signal')) { Stop-WithError 'восстановление не завершено (recovery.signal на месте)' }
    $code = Invoke-Native $pgCtl @('stop', '-D', $DataDir, '-m', 'fast', '-w')
    Write-Note "временный кластер остановлен (код pg_ctl $code)"
    $auto = Join-Path $DataDir 'postgresql.auto.conf'
    $lines = [IO.File]::ReadAllLines($auto)
    $keep = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -eq $markBegin) { $skip = $true; continue }
        if ($l -eq $markEnd) { $skip = $false; continue }
        if (-not $skip) { $keep.Add($l) }
    }
    [IO.File]::WriteAllLines($auto, $keep.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Note 'строки восстановления убраны из postgresql.auto.conf (архивирование WAL снова как в postgresql.conf)'
    $live = Join-Path $InstallRoot 'data\pg'
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $before = Join-Path $InstallRoot "data\pg-before-$stamp"
    Stop-AppServices
    Stop-Service -Name $PgServiceName -ErrorAction Stop
    Write-Note "служба $PgServiceName остановлена"
    Rename-Item -LiteralPath $live -NewName (Split-Path $before -Leaf)
    Write-Note "прежняя база сохранена: $before (удалить вручную после проверки)"
    Move-Item -LiteralPath $DataDir -Destination $live
    # Права как у init-postgres.ps1: наследование отключено, Administrators и SYSTEM — F, учётная запись службы
    # PostgreSQL — M, владелец — Administrators; проверка. Перенесённая папка иначе сохранила бы права места, где
    # создавалась (и записи администратора).
    try {
        $pgSid = Resolve-AccountSid $PgServiceAccount
        $baseSids = @($script:SidAdministrators, $script:SidSystem)
        Set-PrivateAcl -Path $live -FullSids $baseSids -ModifySids @($pgSid)
        Invoke-Icacls @($live, '/setowner', "*$($script:SidAdministrators)", '/T', '/C', '/Q')
        $problems = Test-PrivateAcl $live ($baseSids + @($pgSid))
        if ($problems.Count -gt 0) { throw ($problems -join "`n") }
    } catch {
        Stop-WithError "права папки $live не закрыты: $($_.Exception.Message). База перенесена в $live, служба $PgServiceName не запущена."
    }
    Write-Note "права ${live}: только Administrators, SYSTEM (F) и $PgServiceAccount (M), владелец Administrators — проверено"
    # Файл .history новой линии времени при archive_mode=off не попал в архив — отправляем его вручную, иначе
    # будущее восстановление «до последнего момента» не увидит новую линию времени.
    $cfg = $BackupConfig
    foreach ($h in (Get-ChildItem -LiteralPath (Join-Path $live 'pg_wal') -Filter '*.history' -ErrorAction SilentlyContinue)) {
        $c = Invoke-Native $node @($tool, 'wal-archive', '--config', $cfg, $h.FullName, $h.Name)
        if ($c -ne 0) { Write-Host "   ВНИМАНИЕ: $($h.Name) не отправлен в архив WAL (код $c)" -ForegroundColor Yellow }
    }
    Start-Service -Name $PgServiceName -ErrorAction Stop
    Write-Note "служба $PgServiceName запущена на восстановленной базе"
    Write-Step 'Дальше (администратор)'
    Write-Note '1) Новая базовая копия сразу: .\backup.ps1 -Action base-now (старые копии относятся к прежней линии времени).'
    Write-Note '2) Если программа новее копии — migrate по инструкции установки.'
    Write-Note '3) Предупредить кассиров (OPS-KI-04): заказы и корзины после момента восстановления потеряны, черновики на устройствах не переотправлять без проверки.'
    Write-Note '4) Запустить службы: Start-Service OptomstroyApi, OptomstroyWorker, OptomstroyBackup.'
    Write-Note '5) Ручной обмен с 1С и сверка очереди отправки в 1С за окно потери.'
    exit 0
}

if (-not $KeyFile) { Stop-WithError 'не указан -KeyFile (закрытый ключ держателя)' }
if (-not $Latest -and -not $TargetTime) { Stop-WithError 'укажите -TargetTime (например, ''2026-11-21 14:05:00+06:00'') или -Latest' }
if ((Test-Path -LiteralPath $DataDir) -and @(Get-ChildItem -LiteralPath $DataDir -Force).Count -gt 0) { Stop-WithError "папка $DataDir не пуста" }
if ((Test-Path -LiteralPath $WalStageDir) -and @(Get-ChildItem -LiteralPath $WalStageDir -Force).Count -gt 0) { Stop-WithError "папка $WalStageDir не пуста" }

$target = $null
if (-not $Latest) {
    try {
        $target = [DateTimeOffset]::Parse($TargetTime, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Stop-WithError "не разобрано время -TargetTime «$TargetTime» (пример: 2026-11-21 14:05:00+06:00)"
    }
    if ($TargetTime -notmatch '([+-]\d\d(:?\d\d)?|Z)\s*$') { Stop-WithError '-TargetTime должен содержать смещение часового пояса (+06:00 или Z)' }
}

Write-Step '1. Остановка служб программы'
if ($DevTest) { Write-Note '-DevTest: службы не трогаются' } else { Stop-AppServices }

# 1а. Конец WAL в архив (как restore-db.sh в Linux): служба OptomstroyBackup остановлена, новых записей программы нет.
# Закрывается текущий сегмент (pg_switch_wal), ждём, пока archive_command положит его в спул, и отправляем спул в
# зашифрованный архив (wal-ship). Без этого «до последнего момента» потерял бы последние ~1–2 минуты и всё, что
# лежало в спуле. Рабочий кластер недоступен (авария) — шаг пропускается с предупреждением.
Write-Step '1а. Последний сегмент WAL в архив'
if ($SkipWalFlush) {
    Write-Note '-SkipWalFlush: пропущено (WAL после последней отправки службой в восстановление не попадёт)'
} else {
    $psqlLive = Join-Path $PgBin 'psql.exe'
    $switched = $null
    if (-not (Test-Path -LiteralPath $psqlLive)) {
        if (-not $DevTest) { Stop-WithError "нет $psqlLive (или -SkipWalFlush, если рабочий кластер недоступен)" }
        Write-Note "-DevTest: нет $psqlLive — сегмент не закрывается, только wal-ship"
    } else {
        $oldPassFile = $env:PGPASSFILE   # check-secrets: allow — имя переменной или пути, не значение секрета
        $oldPassword = $env:PGPASSWORD   # check-secrets: allow — имя переменной или пути, не значение секрета
        try {
            if ($SuperPassFile) {
                $env:PGPASSFILE = $SuperPassFile   # check-secrets: allow — имя переменной или пути, не значение секрета
            } elseif (-not $env:PGPASSWORD) {
                $sec = Read-Host -AsSecureString "Пароль $SuperUser (рабочий кластер, порт $LivePort)"
                $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                try { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            }
            $connLive = @('-X', '-A', '-t', '-h', '127.0.0.1', '-p', "$LivePort", '-U', $SuperUser, '-w', '-d', 'postgres')
            $r = Invoke-Capture $psqlLive ($connLive + @('-c', 'SELECT pg_walfile_name(pg_switch_wal())'))
            if ($r.Code -ne 0 -or $r.Out -notmatch '^[0-9A-F]{24}$') {
                Write-Host "   ВНИМАНИЕ: рабочий кластер 127.0.0.1:$LivePort недоступен — последний сегмент WAL не закрыт; восстановление дойдёт только до последнего сегмента в архиве" -ForegroundColor Yellow
            } else {
                $switched = $r.Out
                Write-Note "закрыт сегмент $switched; ожидание архивации (до 5 мин)"
                $deadline = (Get-Date).AddMinutes(5)
                $archived = $false
                while ((Get-Date) -lt $deadline) {
                    $a = Invoke-Capture $psqlLive ($connLive + @('-c', "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver"))
                    if ($a.Code -eq 0 -and $a.Out -match '^[0-9A-F]{24}' -and $a.Out.Substring(8, 16) -ge $switched.Substring(8, 16)) { $archived = $true; break }
                    Start-Sleep -Seconds 2
                }
                if (-not $archived) { Stop-WithError "сегмент $switched не заархивирован за 5 минут (pg_stat_archiver). Проверьте archive_command; без него конец WAL будет потерян. Продолжить без него: -SkipWalFlush" }
                Write-Note "сегмент $switched в спуле"
            }
        } finally {
            $env:PGPASSFILE = $oldPassFile   # check-secrets: allow — имя переменной или пути, не значение секрета
            $env:PGPASSWORD = $oldPassword   # check-secrets: allow — имя переменной или пути, не значение секрета
        }
    }
    if (Test-Path -LiteralPath $BackupConfig) {
        $code = Invoke-Native $node @($tool, 'wal-ship', '--config', $BackupConfig)
        if ($code -ne 0) { Stop-WithError "wal-ship: спул WAL не отправлен в архив (код $code). Без него конец WAL будет потерян. Продолжить без него: -SkipWalFlush" }
        Write-Note 'спул WAL отправлен в зашифрованный архив'
    } else {
        if (-not $DevTest) { Stop-WithError "нет $BackupConfig (укажите -BackupConfig или -SkipWalFlush)" }
        Write-Note "-DevTest: нет $BackupConfig — wal-ship пропущен"
    }
}

Write-Step '2. Выбор базовой копии'
$pitrRoot = Join-Path $BackupRoot 'pitr'
if (-not $SystemIdentifier) {
    $dirs = @(Get-ChildItem -LiteralPath $pitrRoot -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -ne 1) { Stop-WithError "в $pitrRoot кластеров: $($dirs.Count). Укажите -SystemIdentifier." }
    $SystemIdentifier = $dirs[0].Name
}
$baseDir = Join-Path $pitrRoot "$SystemIdentifier\base"
$walDir = Join-Path $pitrRoot "$SystemIdentifier\wal"
$candidates = @()
foreach ($j in (Get-ChildItem -LiteralPath $baseDir -Filter 'base-*.tar.gz.optbk.json' -ErrorAction SilentlyContinue)) {
    $m = Read-JsonFile $j.FullName
    $endUtc = [DateTimeOffset]::Parse($m.endUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($null -eq $target -or $endUtc -lt $target) {
        $candidates += [pscustomobject]@{ File = (Join-Path $baseDir $m.file); End = $endUtc; StartWal = $m.startWal; Label = $m.label }
    }
}
if ($candidates.Count -eq 0) { Stop-WithError "нет базовой копии, закончившейся раньше $TargetTime" }
$base = $candidates | Sort-Object End | Select-Object -Last 1
Write-Note "базовая копия: $($base.File) (закончена $($base.End.ToString('u')), WAL с $($base.StartWal))"

Request-KeyPassphrase $KeyFile
try {
    Write-Step '3. Распаковка базовой копии'
    $code = Invoke-Native $node @($tool, 'restore-base', '--key', $KeyFile, $base.File, '--to', $DataDir)
    if ($code -ne 0) { Stop-WithError "базовая копия не распакована (код $code). Рабочая база не тронута." }

    Write-Step '4. Расшифровка архива WAL (проверка непрерывности и места)'
    $unpackArgs = @($tool, 'wal-unpack', '--key', $KeyFile, '--from', $walDir, '--to', $WalStageDir, '--start-wal', $base.StartWal)
    if ($AllowWalGap) { $unpackArgs += '--allow-gap' }
    $code = Invoke-Native $node $unpackArgs
    if ($code -eq 3) {
        if ($Latest) {
            Stop-WithError "архив WAL неполный (дыра или повреждённый сегмент — см. строку «НЕПОЛНЫЙ АРХИВ» выше). С -Latest восстановление молча остановилось бы на дыре. Выберите -TargetTime до неё или осознанно -AllowWalGap. Рабочая база не тронута."
        }
        Write-Host '   ВНИМАНИЕ: архив WAL неполный — восстановление возможно только до последнего распакованного сегмента; момент позже вызовет «recovery ended before configured recovery target»' -ForegroundColor Yellow
    } elseif ($code -ne 0) { Stop-WithError "WAL не расшифрован (код $code). Рабочая база не тронута." }
} finally {
    Clear-KeyPassphrase
}

Write-Step '5. Настройка восстановления'
foreach ($f in @('postmaster.pid', 'postmaster.opts', 'standby.signal')) { Remove-Item -LiteralPath (Join-Path $DataDir $f) -Force -ErrorAction SilentlyContinue }
$restoreCmd = 'copy "' + (Join-Path $WalStageDir '%f') + '" "%p"'
# logging_collector = off: кластер из init-postgres.ps1 пишет журнал сборщиком в общую папку logs\pg (тот же
# postgresql-%a.log, что у рабочего). Временный кластер пишет только в свой журнал (-l), который читает этот скрипт.
$conf = @($markBegin,
    "restore_command = $(ConvertTo-PgConfString $restoreCmd)",
    "logging_collector = off",
    "log_destination = 'stderr'",
    "archive_mode = 'off'",
    "port = $Port",
    "listen_addresses = '127.0.0.1'")
if ($null -ne $target) {
    $conf += "recovery_target_time = '$($target.ToString('yyyy-MM-dd HH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture))'"
    $conf += "recovery_target_action = 'promote'"
} else {
    $conf += "recovery_target_timeline = 'latest'"
}
$conf += $markEnd
Add-TextNoBom (Join-Path $DataDir 'postgresql.auto.conf') ("`n" + ($conf -join "`n") + "`n")
Add-TextNoBom (Join-Path $DataDir 'recovery.signal') ''
Write-Note ($conf[1..($conf.Count - 2)] -join '; ')

Write-Step "6. Запуск восстановления (порт $Port, журнал $logFile)"
Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
$code = Invoke-PgCtlStart $pgCtl @('start', '-D', $DataDir, '-l', $logFile, '-W', '-o', "-p $Port")
if ($code -ne 0) { Stop-WithError "pg_ctl start: код $code (журнал $logFile)" }
$failRe = 'recovery ended before configured recovery target|requested recovery stop point|PANIC|could not locate a valid checkpoint|startup process .* (exited|terminated)|is not a child of this server.s history|requested timeline .* (is not|does not)'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $text = ''
    if (Test-Path -LiteralPath $logFile) { $text = Read-SharedText $logFile }
    if ($text -match $failRe) {
        Invoke-Native $pgCtl @('stop', '-D', $DataDir, '-m', 'immediate') -Quiet | Out-Null
        ((Read-SharedText $logFile) -split "`r?`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "   $_" }
        Stop-WithError "восстановление не удалось: $($Matches[0]). Если «recovery ended before configured recovery target» — в архиве нет фиксаций после момента ${TargetTime}: выберите более ранний момент или -Latest. Рабочая база не тронута."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'recovery.signal')) -and $text -match 'database system is ready to accept connections') { $done = $true; break }
}
if (-not $done) {
    Invoke-Native $pgCtl @('stop', '-D', $DataDir, '-m', 'immediate') -Quiet | Out-Null
    if (Test-Path -LiteralPath $logFile) { ((Read-SharedText $logFile) -split "`r?`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "   $_" } }
    Stop-WithError "восстановление не закончилось за $TimeoutMinutes мин (журнал $logFile); временный кластер остановлен. Рабочая база не тронута."
}

Write-Step '7. Итог восстановления'
(Read-SharedText $logFile) -split "`r?`n" | Where-Object { $_ -match 'recovery stopping|redo done at|last completed transaction was at log time|selected new timeline|archive recovery complete|consistent recovery state' } | ForEach-Object { Write-Host "   $_" }
Write-Note "восстановленный кластер работает: 127.0.0.1:$Port, папка $DataDir (архивирование WAL выключено)"
$psqlExe = Join-Path $PgBin 'psql.exe'
if (Test-Path -LiteralPath $psqlExe) {
    Write-Note "проверка данных: & '$psqlExe' -h 127.0.0.1 -p $Port -U postgres -d optomstroy"
}
if ($DevTest) {
    Write-Note '-DevTest: кластер оставлен запущенным для проверки; остановка — pg_ctl stop -D <папка>'
} else {
    Write-Note 'Проверьте данные. Затем подмена рабочей базы: .\restore-pitr.ps1 -Apply -DataDir <та же папка>'
    Write-Note "Папку WAL $WalStageDir удалить после -Apply."
}
exit 0
