<#
.SYNOPSIS
  Проверка восстановления резервной копии (restore-drill; 16 §8.1, §8.5 «Ежемесячная проверка») под Windows Server.

.DESCRIPTION
  Перенос infra/scripts/backup-restore-test.sh (Linux) без Docker. Рабочую базу, службы и роли рабочего кластера НЕ
  трогает: зашифрованный дамп восстанавливается во ВРЕМЕННЫЙ кластер PostgreSQL (initdb в -WorkDir, только
  127.0.0.1, свободный -Port, archive_mode = off — в архив WAL рабочего ничего не пишет), затем всё временное
  удаляется. Можно запускать при работающем магазине (нагрузка — диск и процессор на время восстановления).

  Запускает администратор с держателем закрытого ключа (ключ — со съёмного носителя, на диск не копируется):
    1. Выбор копии: -DumpFile или самый новый dumps\*.dump.optbk (затем dumps\monthly).
    2. verify-file --key — копия целиком: подлинность каждого куска, расшифровка без записи на диск.
    3. Временный кластер: initdb (UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE -LcCtype — как рабочий; пароль
       суперпользователя — случайный, только на время проверки), pg_ctl start на 127.0.0.1:-Port.
       PostgreSQL под администратором снимает права администратора (ограниченный маркер), поэтому -WorkDir получает
       явное право текущего пользователя.
    4. Роли рабочего контура без входа (pos_migrate, pos_app, pos_readonly, pos_backup), база restore_check,
       стоп-проверка lower('ЁЯ') = 'ёя'.
    5. decrypt-pipe → pg_restore --exit-on-error (открытый дамп на диск не пишется).
    6. Проверки: журнал миграций pos_meta.schema_migrations не пуст; расширения pg_trgm, unaccent, pgcrypto;
       ключевые таблицы есть (число строк — в вывод, сверка с контрольными значениями — запись в журнале
       эксплуатации); владелец и права (pos_migrate, pos_app) — предупреждение, если их нет в копии.
    7. Уборка: pg_ctl stop, удаление -WorkDir (-Keep — оставить для разбора).
    8. Итог — в state\status.json корня копий (pos-backup.mjs drill-record): status показывает
       restore-drill-failed и restore-drill-older-35d (успешной проверки не было дольше 35 суток); -PingUrlFile —
       отдельная проверка Healthchecks «restore-drill» (успех — ping, ошибка — /fail).

  Коды выхода: 0 — копия восстанавливается; 1 — проверка не пройдена или ошибка.

.EXAMPLE
  .\restore-drill.ps1 -KeyFile E:\key\backup-private.pem
.EXAMPLE
  .\restore-drill.ps1 -KeyFile E:\key\backup-private.pem -DumpFile D:\OptomstroyBackups\dumps\monthly\20261101-003000.dump.optbk -WorkDir E:\drill
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KeyFile,
    [string]$DumpFile,
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$BackupRoot = 'D:\OptomstroyBackups',
    [string]$BackupConfig,
    [string]$PgBin = 'C:\Program Files\PostgreSQL\17\bin',
    [ValidateRange(1024, 65535)][int]$Port = 5435,
    [string]$WorkDir,
    [string]$LcCtype = 'en-US',
    [string]$PingUrlFile,
    [string]$NodeExe,
    [switch]$Keep,
    [switch]$NoRecord,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

$KeyTables = @('products', 'product_variants', 'customers', 'orders', 'payments', 'audit_logs')
$Extensions = @('pg_trgm', 'unaccent', 'pgcrypto')
$DrillDb = 'restore_check'

$tool = Join-Path $PSScriptRoot 'pos-backup.mjs'
if (-not $BackupConfig) { $BackupConfig = Join-Path $InstallRoot 'config\backup.json' }
if (-not $DevTest -and -not (Test-IsAdmin)) { Stop-WithError 'нужен PowerShell «от имени администратора» (или -DevTest для проверочного стенда)' }
$node = Resolve-NodeExe -NodeExe $NodeExe -InstallRoot $InstallRoot -DevTest:$DevTest
if ((Test-Path -LiteralPath $BackupConfig) -and -not $PSBoundParameters.ContainsKey('BackupRoot')) {
    try { $c = Read-JsonFile $BackupConfig; if ($c.PSObject.Properties['backupRoot'] -and $c.backupRoot) { $BackupRoot = [string]$c.backupRoot } } catch { }
}

$started = Get-Date
$failReason = $null
$dumpName = $null
$dataDir = $null
$pgStarted = $false
$workCreated = $false
$oldPassFile = $env:PGPASSFILE   # check-secrets: allow — имя переменной или пути, не значение секрета
$oldPassword = $env:PGPASSWORD   # check-secrets: allow — имя переменной или пути, не значение секрета

function Stop-Drill([string]$Text) { throw [System.Exception]::new("DRILL: $Text") }

function Invoke-DrillSql([string]$Db, [string]$Sql) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $Sql, (New-Object System.Text.UTF8Encoding($false)))
        return (Invoke-Capture $script:psqlExe @('-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-p', "$Port", '-U', 'postgres', '-w', '-d', $Db, '-f', $tmp))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Step '0. Предварительные проверки'
    $script:psqlExe = Join-Path $PgBin 'psql.exe'
    $initdb = Join-Path $PgBin 'initdb.exe'
    $pgCtl = Join-Path $PgBin 'pg_ctl.exe'
    $pgRestore = Join-Path $PgBin 'pg_restore.exe'
    foreach ($p in @($initdb, $pgCtl, $script:psqlExe, $pgRestore)) { if (-not (Test-Path -LiteralPath $p)) { Stop-Drill "не найден $p (нужны программы PostgreSQL 17: -PgBin)" } }
    if ($LcCtype -notmatch '^[A-Za-z0-9_.\-]+$') { Stop-Drill "недопустимое имя локали -LcCtype $LcCtype" }
    if (-not (Test-Path -LiteralPath $KeyFile)) { Stop-Drill "закрытый ключ не найден: $KeyFile" }
    if (-not $DumpFile) {
        foreach ($d in @((Join-Path $BackupRoot 'dumps'), (Join-Path $BackupRoot 'dumps\monthly'))) {
            $f = Get-ChildItem -LiteralPath $d -Filter '*.dump.optbk' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}\.dump\.optbk$' } | Sort-Object Name | Select-Object -Last 1
            if ($null -ne $f) { $DumpFile = $f.FullName; break }
        }
        if (-not $DumpFile) { Stop-Drill "в $BackupRoot\dumps нет копий *.dump.optbk — укажите -DumpFile" }
    }
    if (-not (Test-Path -LiteralPath $DumpFile)) { Stop-Drill "нет файла $DumpFile" }
    $dumpName = Split-Path $DumpFile -Leaf
    Write-Note "копия: $DumpFile ($((Get-Item -LiteralPath $DumpFile).Length) байт)"
    # Порт свободен на 127.0.0.1 (иначе pg_ctl подключился бы к чужому серверу или не запустился).
    $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $probe.Start() } catch { Stop-Drill "порт 127.0.0.1:$Port занят — укажите другой -Port" } finally { try { $probe.Stop() } catch { } }
    if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('optomstroy-restore-drill-' + (Get-Date).ToString('yyyyMMdd-HHmmss')) }
    if ((Test-Path -LiteralPath $WorkDir) -and @(Get-ChildItem -LiteralPath $WorkDir -Force).Count -gt 0) { Stop-Drill "папка $WorkDir не пуста" }
    $dumpBytes = (Get-Item -LiteralPath $DumpFile).Length
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $workCreated = $true
    $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $WorkDir).Path)
    $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
    # Сжатый дамп -Fc обычно в 3–10 раз меньше базы с индексами: оценка — 10 × размер копии + 1 ГиБ.
    $need = 10 * $dumpBytes + 1GB
    if ($free -lt $need) { Write-Host "   ВНИМАНИЕ: на томе $root свободно $([math]::Round($free / 1GB, 1)) ГиБ, оценка нужного — $([math]::Round($need / 1GB, 1)) ГиБ (-WorkDir на другом томе)" -ForegroundColor Yellow }
    # PostgreSQL под администратором работает с ограниченным маркером (группа Administrators — только запрет):
    # папке нужно явное право самого пользователя.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Icacls @($WorkDir, '/grant', "*${me}:(OI)(CI)F")
    $dataDir = Join-Path $WorkDir 'pg'
    $logFile = Join-Path $WorkDir 'postgres.log'

    Request-KeyPassphrase $KeyFile
    Write-Step '1. Проверка копии целиком с ключом (расшифровка без записи на диск)'
    $code = Invoke-Native $node @($tool, 'verify-file', $DumpFile, '--key', $KeyFile)
    if ($code -ne 0) { Stop-Drill "копия не прошла проверку с ключом (код $code): неверный ключ, повреждённый или подменённый файл" }

    Write-Step "2. Временный кластер (127.0.0.1:$Port, $dataDir)"
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $drillPw = -join ($bytes | ForEach-Object { $_.ToString('x2') })   # check-secrets: allow — случайный пароль временного кластера, живёт до конца проверки
    $pwFile = Join-Path $WorkDir 'initdb-pw.txt'
    [IO.File]::WriteAllText($pwFile, $drillPw, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $code = Invoke-Native $initdb @('-D', $dataDir, '-U', 'postgres', "--pwfile=$pwFile", '--auth=scram-sha-256', '-E', 'UTF8',
            '--locale-provider=builtin', '--builtin-locale=C.UTF-8', '--locale=C', "--lc-ctype=$LcCtype", '--no-sync') -Quiet
    } finally {
        Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { Stop-Drill "initdb: код $code" }
    $opts = "-p $Port -c listen_addresses=127.0.0.1 -c archive_mode=off -c logging_collector=off -c fsync=off -c full_page_writes=off -c shared_preload_libraries=pg_stat_statements"
    $code = Invoke-PgCtlStart $pgCtl @('start', '-D', $dataDir, '-l', $logFile, '-w', '-t', '180', '-o', $opts)
    if ($code -ne 0) {
        if (Test-Path -LiteralPath $logFile) { ((Read-SharedText $logFile) -split "`r?`n" | Select-Object -Last 10) | ForEach-Object { Write-Host "   $_" } }
        Stop-Drill "pg_ctl start: код $code"
    }
    $pgStarted = $true
    Remove-Item Env:\PGPASSFILE -ErrorAction SilentlyContinue
    $env:PGPASSWORD = $drillPw   # check-secrets: allow — пароль временного кластера, только в окружении процесса

    Write-Step "3. Роли (без входа) и база $DrillDb"
    $r = Invoke-DrillSql 'postgres' @'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_migrate') THEN CREATE ROLE pos_migrate NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN CREATE ROLE pos_app NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_readonly') THEN CREATE ROLE pos_readonly NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_backup') THEN CREATE ROLE pos_backup NOLOGIN; END IF;
END $$;
CREATE DATABASE restore_check OWNER pos_migrate TEMPLATE template0 ENCODING 'UTF8';
'@
    if ($r.Code -ne 0) { Stop-Drill "роли или база $DrillDb не созданы (код $($r.Code))" }
    $gate = Invoke-DrillSql $DrillDb @'
SELECT (lower(convert_from('\xd081d0af'::bytea, 'UTF8') COLLATE "default") = convert_from('\xd191d18f'::bytea, 'UTF8') COLLATE "default")::text;
'@
    if ($gate.Code -ne 0 -or $gate.Out -ne 'true') { Stop-Drill "СТОП: lower('ЁЯ') <> 'ёя' во временном кластере (локаль $LcCtype)" }
    Write-Note "стоп-проверка lower('ЁЯ') = 'ёя': пройдена"

    Write-Step '4. Восстановление потоком (decrypt-pipe → pg_restore)'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Native $node @($tool, 'decrypt-pipe', '--key', $KeyFile, $DumpFile, '--', $pgRestore, '--exit-on-error', '-h', '127.0.0.1', '-p', "$Port", '-U', 'postgres', '-w', '-d', $DrillDb)
    if ($code -ne 0) { Stop-Drill "копия НЕ восстанавливается: pg_restore или расшифровка — код $code" }
    Write-Note "восстановлено за $([int]$sw.Elapsed.TotalSeconds) с"

    Write-Step '5. Проверки восстановленной базы'
    $mig = Invoke-DrillSql $DrillDb 'SELECT coalesce(max(version)::text, '''') FROM pos_meta.schema_migrations;'
    if ($mig.Code -ne 0 -or -not $mig.Out) { Stop-Drill 'журнал миграций pos_meta.schema_migrations пуст или отсутствует' }
    Write-Note "последняя миграция: $($mig.Out)"
    foreach ($e in $Extensions) {
        $x = Invoke-DrillSql $DrillDb "SELECT count(*) FROM pg_extension WHERE extname = '$e';"
        if ($x.Out -ne '1') { Stop-Drill "в восстановленной базе нет расширения $e" }
    }
    Write-Note "расширения: $($Extensions -join ', ') — есть"
    Write-Host ('   {0,-20} {1}' -f 'таблица', 'строк')
    foreach ($t in $KeyTables) {
        $x = Invoke-DrillSql $DrillDb "SELECT to_regclass('public.$t') IS NOT NULL;"
        if ($x.Out -ne 't') { Stop-Drill "в восстановленной базе нет таблицы $t" }
        $n = Invoke-DrillSql $DrillDb "SELECT count(*) FROM public.$t;"
        Write-Host ('   {0,-20} {1}' -f $t, $n.Out)
    }
    $tables = Invoke-DrillSql $DrillDb "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"
    Write-Note "таблиц в public: $($tables.Out)"
    $own = Invoke-DrillSql $DrillDb "SELECT coalesce((SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'products'), '') || '|' || has_table_privilege('pos_app', 'public.products', 'SELECT')::text;"
    if ($own.Out -ne 'pos_migrate|true') {
        Write-Host "   ВНИМАНИЕ: в копии нет владельцев или прав ролей ($($own.Out)) — для рабочей базы после восстановления понадобится выдача прав вручную" -ForegroundColor Yellow
    }
    Write-Note 'копия восстанавливается'
} catch {
    $failReason = $_.Exception.Message -replace '^DRILL: ', ''
} finally {
    Clear-KeyPassphrase
    $env:PGPASSFILE = $oldPassFile   # check-secrets: allow — имя переменной или пути, не значение секрета
    $env:PGPASSWORD = $oldPassword   # check-secrets: allow — имя переменной или пути, не значение секрета
    Write-Step '6. Уборка'
    if ($pgStarted) {
        $c = Invoke-Native $pgCtl @('stop', '-D', $dataDir, '-m', 'fast', '-w', '-t', '120') -Quiet
        if ($c -ne 0) { $c = Invoke-Native $pgCtl @('stop', '-D', $dataDir, '-m', 'immediate', '-w') -Quiet }
        Write-Note "временный кластер остановлен (код pg_ctl $c)"
    }
    if ($workCreated) {
        if ($Keep) {
            Write-Note "-Keep: папка $WorkDir оставлена (запуск: pg_ctl start -D `"$dataDir`" -o `"-p $Port`"; удалить вручную после разбора)"
        } else {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $WorkDir) { Write-Host "   ВНИМАНИЕ: папка $WorkDir не удалена полностью — удалите вручную" -ForegroundColor Yellow } else { Write-Note "папка $WorkDir удалена" }
        }
    }
}

$seconds = [int]((Get-Date) - $started).TotalSeconds
$result = 'ok'
if ($failReason) { $result = 'fail' }
Write-Step '7. Итог'
if ($NoRecord) {
    Write-Note '-NoRecord: итог в state\status.json не записан'
} elseif (Test-Path -LiteralPath $BackupConfig) {
    $recArgs = @($tool, 'drill-record', '--config', $BackupConfig, '--result', $result, '--seconds', "$seconds")
    if ($dumpName) { $recArgs += @('--dump', $dumpName) }
    if ($failReason) { $recArgs += @('--detail', $failReason) }
    if ($PingUrlFile) { $recArgs += @('--ping-url-file', $PingUrlFile) }
    $c = Invoke-Native $node $recArgs
    if ($c -ne 0) { Write-Host "   ВНИМАНИЕ: итог не записан в state\status.json (drill-record: код $c)" -ForegroundColor Yellow }
} else {
    Write-Host "   ВНИМАНИЕ: нет $BackupConfig — итог в state\status.json не записан (status покажет restore-drill-older-35d)" -ForegroundColor Yellow
}
if ($failReason) {
    Write-Host ''
    Write-Host "ПРОВЕРКА НЕ ПРОЙДЕНА: $failReason" -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host "Проверка пройдена: $dumpName восстанавливается ($seconds с). Число строк ключевых таблиц — в журнал эксплуатации; ключ унести." -ForegroundColor Green
exit 0
