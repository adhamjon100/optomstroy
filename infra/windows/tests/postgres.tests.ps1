<#
.SYNOPSIS
  Проверочный прогон комплекта infra/windows/postgres без прав администратора (-DevTest) на встроенных бинарных
  файлах PostgreSQL 17.10 (pos-api\node_modules\@embedded-postgres\windows-x64\native\bin).

.DESCRIPTION
  Порт 55432 (диапазон пакета PostgreSQL 55432-55439). Временные данные — в .tmp\wn-postgres\run-<время> (в пути
  есть пробелы — проверяется кавычение archive_command); после прогона удаляются, остаётся журнал прогона
  .tmp\wn-postgres\postgres-tests-<время>.log.
  Шаги: разбор всех .ps1 парсером PowerShell → отказ без прав администратора → init (-DevTest) → параметры сервера и
  pg_hba → apply-roles (setup + verify) → повтор (идемпотентность) → отрицательная стоп-проверка локали →
  migrate (pos-api\dist, под pos_migrate) дважды → verify после миграций → архивирование WAL через archive_command →
  -ConfigOnly → stop → порт закрыт → очистка.
  Секреты генерируются случайно в папке прогона и удаляются вместе с ней.
#>
[CmdletBinding()]
param(
    [int]$Port = 55432,
    [string]$PgBin = '',
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$kit = Join-Path $repo 'infra\windows\postgres'
$apiDir = Join-Path $repo 'pos-api'
if ($PgBin -eq '') { $PgBin = Join-Path $apiDir 'node_modules\@embedded-postgres\windows-x64\native\bin' }
$node = (Get-Command node.exe).Source
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = Join-Path $repo '.tmp\wn-postgres'
$run = Join-Path $base "run-$stamp"
$root = Join-Path $run 'inst root'           # пробел в пути — намеренно
$secDir = Join-Path $root 'secrets'
$dataDir = Join-Path $root 'data\pg'
$logDir = Join-Path $root 'logs\pg'
$spool = Join-Path $root 'data\walspool'
$relDir = Join-Path $root 'releases\t1'
$currentLink = Join-Path $root 'current'
New-Item -ItemType Directory -Force -Path $secDir, (Join-Path $relDir 'node'), (Join-Path $relDir 'backup') | Out-Null
$evidence = Join-Path $base "postgres-tests-$stamp.log"
Start-Transcript -LiteralPath $evidence | Out-Null

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { $script:pass++; Write-Host "  PASS $Name $Detail" } else { $script:fail++; Write-Host "  FAIL $Name $Detail" }
}
function Write-NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function New-Secret {
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function Invoke-Helper([string]$Cmd, [string[]]$Extra = @(), [string]$SecDir = $secDir) {
    $argv = @((Join-Path $kit 'test\pg-test-helper.mjs'), $Cmd, '--modules', $apiDir, '--secrets', $SecDir, '--port', [string]$Port) + $Extra
    $out = & $node @argv
    return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

$started = $false
try {
    Write-Host "== Комплект: $kit"
    Write-Host "== PgBin: $PgBin"
    Write-Host "== Папка прогона: $run"

    # ---------- 0. Разбор PowerShell ----------
    Write-Host '== 0. Разбор .ps1 (Parser.ParseFile) и BOM'
    $files = @(Get-ChildItem -LiteralPath $kit -Filter *.ps1) + @(Get-Item -LiteralPath $PSCommandPath)
    foreach ($f in $files) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        Check "parse $($f.Name)" ($errors.Count -eq 0) ($errors | ForEach-Object { $_.Message } | Select-Object -First 3 | Out-String)
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        Check "BOM $($f.Name)" ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    }

    # ---------- 0б. Проверка файла пароля (одна строка) ----------
    Write-Host '== 0б. Assert-PasswordFile: одна строка, перевод строки только в конце'
    . (Join-Path $kit 'pg-common.ps1')
    $pwProbe = Join-Path $run 'pw-probe'
    $pwCases = @(
        @{ N = 'одна строка + CRLF'; T = ('A' * 20) + "`r`n"; Ok = $true },
        @{ N = 'одна строка + LF'; T = ('A' * 20) + "`n"; Ok = $true },
        @{ N = 'две строки (короткая первая)'; T = "short`r`n" + ('A' * 20); Ok = $false },
        @{ N = 'две строки (длинные)'; T = ('A' * 20) + "`n" + ('B' * 20) + "`n"; Ok = $false },
        @{ N = 'пустая строка в конце'; T = ('A' * 20) + "`r`n`r`n"; Ok = $false },
        @{ N = 'пробел'; T = ('A' * 10) + ' ' + ('A' * 10); Ok = $false })
    foreach ($c in $pwCases) {
        Write-NoBom $pwProbe $c.T
        $accepted = $true
        try { Assert-PasswordFile $pwProbe 'probe' } catch { $accepted = $false }
        Check "pg_password: $($c.N) — $(if ($c.Ok) { 'принят' } else { 'отклонён' })" ($accepted -eq $c.Ok)
    }
    Remove-Item -LiteralPath $pwProbe -Force

    # ---------- 0в. Закрытая папка: Set-PgPrivateAcl / Test-PgPrivateAcl ----------
    Write-Host '== 0в. Права NTFS: наследование отключено, только разрешённые SID'
    $meSid = Get-PgCurrentUserSid
    $aclAllowed = @('S-1-5-32-544', 'S-1-5-18', $meSid)
    $aclDir = Join-Path $run 'acl probe'
    New-Item -ItemType Directory -Force -Path (Join-Path $aclDir 'sub') | Out-Null
    Write-NoBom (Join-Path $aclDir 'sub\f.txt') 'x'
    $before = Test-PgPrivateAcl $aclDir $aclAllowed
    Check 'новая папка (наследует от родителя) — нарушения найдены' ($before.Count -gt 0) "$($before.Count)"
    Set-PgPrivateAcl -Path $aclDir -FullSids $aclAllowed -ModifySids @('S-1-5-20')
    $after = Test-PgPrivateAcl $aclDir ($aclAllowed + @('S-1-5-20'))
    Check 'после Set-PgPrivateAcl нарушений нет' ($after.Count -eq 0) ($after -join '; ')
    $childSids = @((Get-Acl -LiteralPath (Join-Path $aclDir 'sub\f.txt')).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
    Check 'вложенный файл: нет Authenticated Users/Users/Everyone' (@($childSids | Where-Object { $_ -in @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0') }).Count -eq 0) ($childSids -join ',')
    Check 'вложенный файл: права только от закрытой папки' (@($childSids | Where-Object { $_ -notin ($aclAllowed + @('S-1-5-20')) }).Count -eq 0) ($childSids -join ',')
    Set-PgPrivateAcl -Path $aclDir -FullSids $aclAllowed -RemoveSids @('S-1-5-20')
    Check '-RemoveSids снимает право' ((Test-PgPrivateAcl $aclDir $aclAllowed).Count -eq 0)

    # ---------- 0г. Обязательная проверка общей учётной записи (SEC-02) ----------
    Write-Host '== 0г. Get-PgServiceAccountPrecheck: службы под той же учётной записью'
    $sr = 'C:\Windows'
    $exeCases = @(
        @{ P = 'C:\Windows\system32\svchost.exe -k NetworkService -p'; E = 'C:\Windows\system32\svchost.exe' },
        @{ P = '"C:\Program Files\Acme Agent\agent.exe" --run'; E = 'C:\Program Files\Acme Agent\agent.exe' },
        @{ P = 'C:\Program Files\Acme Agent\agent.exe -k x'; E = 'C:\Program Files\Acme Agent\agent.exe' },
        @{ P = '\SystemRoot\System32\x.exe'; E = 'C:\Windows\System32\x.exe' },
        @{ P = 'system32\y.exe -a'; E = 'C:\Windows\system32\y.exe' })
    foreach ($c in $exeCases) {
        $got = Get-PgServiceExePath $c.P $sr
        Check "путь службы: $($c.P)" ($got -eq $c.E) $got
    }
    function New-FakeSvc($n, $acct, $path) { [pscustomobject]@{ Name = $n; DisplayName = $n; State = 'Running'; StartName = $acct; PathName = $path } }
    $fake = @(
        (New-FakeSvc 'Dnscache' 'NT AUTHORITY\NetworkService' 'C:\Windows\system32\svchost.exe -k NetworkService -p'),
        (New-FakeSvc 'CryptSvc' 'NT Authority\NetworkService' 'C:\Windows\system32\svchost.exe -k NetworkService -p'),
        (New-FakeSvc 'OptomstroyPostgres' 'NT AUTHORITY\NetworkService' '"D:\pg\bin\pg_ctl.exe" runservice -N "OptomstroyPostgres"'),
        (New-FakeSvc 'Spooler' 'LocalSystem' 'C:\Windows\System32\spoolsv.exe'),
        (New-FakeSvc 'SqlAgentX' 'NT Service\SQLAgent$X' '"C:\Program Files\Microsoft SQL Server\sqlagent.exe" -i X'))
    $pc = Get-PgServiceAccountPrecheck -ServiceAccount 'NT AUTHORITY\NetworkService' -ServiceName 'OptomstroyPostgres' -Services $fake -SystemRoot $sr
    Check 'только службы Windows: сторонних нет, своя служба и другие учётные записи не считаются' (($pc.Others.Count -eq 2) -and ($pc.ThirdParty.Count -eq 0)) "$($pc.Others.Count)/$($pc.ThirdParty.Count)"
    $fake2 = $fake + @((New-FakeSvc 'AcmeAgent' 'NT AUTHORITY\NetworkService' '"C:\Program Files\Acme Agent\agent.exe" --run'))
    $pc2 = Get-PgServiceAccountPrecheck -ServiceAccount 'NT AUTHORITY\NetworkService' -ServiceName 'OptomstroyPostgres' -Services $fake2 -SystemRoot $sr
    Check 'сторонняя служба под NetworkService найдена' (($pc2.ThirdParty.Count -eq 1) -and ($pc2.ThirdParty[0].Name -eq 'AcmeAgent'))
    Check 'строка журнала помечает стороннюю службу' (@($pc2.Lines | Where-Object { $_ -like '*СТОРОННЯЯ*AcmeAgent*' }).Count -eq 1) ($pc2.Lines -join ' | ')
    $pcSid = Get-PgServiceAccountPrecheck -ServiceAccount 'S-1-5-20' -ServiceName 'OptomstroyPostgres' -Services $fake2 -SystemRoot $sr
    Check 'учётная запись по SID — тот же результат' ($pcSid.ThirdParty.Count -eq 1)
    $pcV = Get-PgServiceAccountPrecheck -ServiceAccount 'NT SERVICE\OptomstroyPostgres' -ServiceName 'OptomstroyPostgres' -Services $fake2 -SystemRoot $sr
    Check 'виртуальная учётная запись: проверять нечего (служба ещё не зарегистрирована)' ($pcV.Virtual -and $pcV.ThirdParty.Count -eq 0)
    $pcReal = Get-PgServiceAccountPrecheck -ServiceAccount 'NT AUTHORITY\NetworkService' -ServiceName 'OptomstroyPostgres'
    Check 'настоящий список служб этого ПК (Win32_Service) читается без прав администратора' ($pcReal.Others.Count -gt 0) "под NetworkService: $($pcReal.Others.Count), сторонних: $($pcReal.ThirdParty.Count)"

    # ---------- секреты и макет релиза (archive_command — стандартная, настоящий pos-backup.mjs) ----------
    $dbName = 'optomstroy_test'
    Write-NoBom (Join-Path $secDir 'pg_password') ((New-Secret) + "`r`n")      # перевод строки — как от Notepad
    Write-NoBom (Join-Path $secDir 'db_migrator_password') (New-Secret)
    Write-NoBom (Join-Path $secDir 'db_backup_password') ((New-Secret) + "`n")
    Write-NoBom (Join-Path $secDir 'database_url') ("postgres://pos_app:" + (New-Secret) + "@127.0.0.1:$Port/$dbName")  # check-secrets: allow — шаблон тестовой строки, пароль случайный
    # releases\t1\{node\node.exe, backup\} и junction current → releases\t1 — как на сервере (план, раскладка).
    Copy-Item -LiteralPath $node -Destination (Join-Path $relDir 'node\node.exe')
    $bkSrc = Join-Path $repo 'infra\windows\backup'
    Copy-Item -LiteralPath (Join-Path $bkSrc 'pos-backup.mjs') -Destination (Join-Path $relDir 'backup')
    Copy-Item -LiteralPath (Join-Path $bkSrc 'lib') -Destination (Join-Path $relDir 'backup') -Recurse
    New-Item -ItemType Junction -Path $currentLink -Target $relDir | Out-Null
    $cfgDir = Join-Path $root 'config'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfg = Join-Path $cfgDir 'backup.json'
    Write-NoBom $cfg ((@{ walSpoolDir = $spool } | ConvertTo-Json -Compress))   # ключ — как backup.example.json
    $archCmd = '"' + (Join-Path $root 'current\node\node.exe') + '" "' + (Join-Path $root 'current\backup\pos-backup.mjs') + '" wal-archive --config "' + $cfg + '" "%p" "%f"'

    # ---------- 1. Без прав администратора и без -DevTest — отказ ----------
    Write-Host '== 1. Запуск без -DevTest без прав администратора'
    $refused = $false
    try { & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port 2>$null } catch { $refused = ($_.Exception.Message -like '*администратора*') }
    Check 'init без -DevTest отказывает без прав администратора' $refused
    Check 'после отказа каталог данных не создан' (-not (Test-Path -LiteralPath $dataDir))
    Check 'после отказа папка журналов не создана' (-not (Test-Path -LiteralPath $logDir))

    # ---------- 2. init -DevTest ----------
    Write-Host '== 2. init-postgres.ps1 -DevTest (стандартная archive_command)'
    & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port -DevTest `
        -SharedBuffers 128MB -EffectiveCacheSize 512MB
    $started = $true
    foreach ($d in @($dataDir, $logDir)) {
        $pr = Test-PgPrivateAcl $d $aclAllowed
        Check "права ${d}: наследование отключено, только Administrators/SYSTEM/запускающий" ($pr.Count -eq 0) ($pr -join '; ')
    }
    $pgvSids = @((Get-Acl -LiteralPath (Join-Path $dataDir 'pg_hba.conf')).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
    Check 'pg_hba.conf: нет прав Authenticated Users/Users/Everyone' (@($pgvSids | Where-Object { $_ -in @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0') }).Count -eq 0) ($pgvSids -join ',')
    $pcLog = Join-Path $logDir 'precheck-service-account.log'
    Check 'журнал обязательной проверки учётной записи записан' ((Test-Path -LiteralPath $pcLog) -and ((Get-Content -LiteralPath $pcLog -Raw -Encoding UTF8) -match 'DevTest.*итог: (OK|WARN)'))
    Check 'копия пароля для initdb удалена' (@(Get-ChildItem -LiteralPath $logDir -Recurse -Force -Filter 'initdb-pw-*').Count -eq 0)
    function Test-HasAce([string]$Path, [string]$Sid, [string]$Right) {
        $rules = @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $Sid -and $_.AccessControlType -eq 'Allow' })
        return (@($rules | Where-Object { ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]$Right) -eq [Security.AccessControl.FileSystemRights]$Right }).Count -gt 0)
    }
    Check 'archive: NetworkService — RX на корень' (Test-HasAce $root 'S-1-5-20' 'ReadAndExecute')
    Check 'archive: NetworkService — RX на releases' (Test-HasAce (Join-Path $root 'releases') 'S-1-5-20' 'ReadAndExecute')
    Check 'archive: NetworkService — RX на node.exe релиза (наследуется)' (Test-HasAce (Join-Path $relDir 'node\node.exe') 'S-1-5-20' 'ReadAndExecute')
    Check 'archive: NetworkService — R на backup.json' (Test-HasAce $cfg 'S-1-5-20' 'Read')
    Check 'archive: NetworkService — M на спул WAL' (Test-HasAce $spool 'S-1-5-20' 'Modify')
    Check 'init: PG_VERSION = 17' ((Get-Content -LiteralPath (Join-Path $dataDir 'PG_VERSION')) -eq '17')
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress })
    Check 'слушает только 127.0.0.1' (($listen.Count -ge 1) -and (@($listen | Where-Object { $_ -ne '127.0.0.1' }).Count -eq 0)) ($listen -join ',')
    $confBytes = [System.IO.File]::ReadAllBytes((Join-Path $dataDir 'optomstroy.conf'))
    Check 'optomstroy.conf без BOM' (-not ($confBytes[0] -eq 0xEF))

    $s = Invoke-Helper 'settings'
    Check 'settings: helper' ($s.Code -eq 0)
    $j = $s.Out | ConvertFrom-Json
    $st = $j.settings
    Check 'server_version 17.10' ($st.server_version -like '17.10*') $st.server_version
    Check 'listen_addresses = 127.0.0.1' ($st.listen_addresses -eq '127.0.0.1')
    Check "port = $Port" ($st.port -eq [string]$Port)
    Check 'password_encryption = scram-sha-256' ($st.password_encryption -eq 'scram-sha-256')  # check-secrets: allow — имя метода хеширования, не секрет
    Check 'wal_level = replica' ($st.wal_level -eq 'replica')
    Check 'archive_mode = on' ($st.archive_mode -eq 'on')
    Check 'archive_command без искажений (кавычки, \, пробелы)' ($st.archive_command -eq $archCmd) $st.archive_command
    Check 'data_checksums = on' ($st.data_checksums -eq 'on')
    Check 'shared_preload_libraries = pg_stat_statements' ($st.shared_preload_libraries -eq 'pg_stat_statements')
    Check 'shared_buffers из параметра (128MB = 16384 x 8kB)' ($st.shared_buffers -eq '16384')
    Check 'timezone = UTC' ($st.timezone -eq 'UTC')
    Check 'log_directory = -LogDir' ($st.log_directory -eq $logDir.Replace('\', '/')) $st.log_directory
    $hba = @($j.hba)
    Check 'pg_hba: 2 правила' ($hba.Count -eq 2)
    Check 'pg_hba: все host 127.0.0.1 scram-sha-256' (@($hba | Where-Object { $_.type -ne 'host' -or $_.address -ne '127.0.0.1' -or $_.auth_method -ne 'scram-sha-256' }).Count -eq 0)
    Check 'pg_hba: replication только pos_backup' ((@($hba | Where-Object { ($_.database -join ',') -eq 'replication' -and ($_.user_name -join ',') -eq 'pos_backup' }).Count) -eq 1)
    foreach ($d in @($j.dbs)) { Check "кластер $($d.datname): builtin C.UTF-8 / C / en-US" ($d.datlocprovider -eq 'b' -and $d.datlocale -eq 'C.UTF-8' -and $d.datcollate -eq 'C' -and $d.datctype -eq 'en-US') "$($d.datlocprovider) $($d.datlocale) $($d.datcollate) $($d.datctype)" }
    Check 'журнал сервера в -LogDir' (@(Get-ChildItem -LiteralPath $logDir -Filter 'postgresql-*.log').Count -ge 1)

    # ---------- 3. apply-roles: setup + verify, затем повтор ----------
    Write-Host '== 3. apply-roles.ps1 -Verify (до миграций)'
    $out3 = & (Join-Path $kit 'apply-roles.ps1') -InstallRoot $root -Port $Port -NodeExe $node -ApiDir $apiDir -Verify *>&1 | Out-String
    Write-Host $out3
    Check 'apply-roles: база создана' ($out3 -match "база $dbName создана")
    Check "apply-roles: стоп-проверка lower('ЁЯ') пройдена" ($out3 -match "lower\('ЁЯ'\) = 'ёя': пройдена")
    Check 'apply-roles: расширения доступны' ($out3 -match 'расширения доступны: pg_trgm')
    Check 'apply-roles: verify пройдена' ($out3 -match 'проверка прав ролей: пройдена')
    Check 'apply-roles: архивирование WAL работает (pg_stat_archiver)' ($out3 -match 'архивирование WAL: сегмент \w+ сохранён')
    $pwList = @('pg_password', 'db_migrator_password', 'db_backup_password') | ForEach-Object { ([System.IO.File]::ReadAllText((Join-Path $secDir $_))).Trim() }
    $pwList += ((Get-Content -LiteralPath (Join-Path $secDir 'database_url') -Raw) -replace '^postgres://pos_app:([^@]*)@.*$', '$1').Trim()

    Write-Host '== 3б. apply-roles.ps1 повторно (идемпотентность)'
    $out3b = & (Join-Path $kit 'apply-roles.ps1') -InstallRoot $root -Port $Port -NodeExe $node -ApiDir $apiDir -Verify *>&1 | Out-String
    Write-Host $out3b
    Check 'повтор: база уже есть, права применены, verify пройдена' (($out3b -match 'уже есть') -and ($out3b -match 'проверка прав ролей: пройдена'))
    $leak = @($pwList | Where-Object { $out3.Contains($_) -or $out3b.Contains($_) })
    Check 'вывод не содержит паролей' ($leak.Count -eq 0)

    # ---------- 4. Отрицательная стоп-проверка локали ----------
    Write-Host '== 4. Стоп-проверка: база с локалью libc C'
    $bad = Invoke-Helper 'make-bad-db' @('--arg', 'optomstroy_badlocale')
    Check 'создана база с LC_CTYPE C' ($bad.Code -eq 0)
    $badSecDir = Join-Path $run 'bad secrets'
    New-Item -ItemType Directory -Force -Path $badSecDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $secDir 'pg_password') -Destination $badSecDir
    Write-NoBom (Join-Path $badSecDir 'database_url') ((Get-Content -LiteralPath (Join-Path $secDir 'database_url') -Raw).Replace("/$dbName", '/optomstroy_badlocale'))
    $gateMsg = ''
    try { & (Join-Path $kit 'apply-roles.ps1') -InstallRoot $root -SecretsDir $badSecDir -Port $Port -NodeExe $node -ApiDir $apiDir -GateOnly *>&1 | Out-Null } catch { $gateMsg = $_.Exception.Message }
    Check 'gate на базе libc C: отказ с кодом 3' ($gateMsg -like '*СТОП*код 3*') $gateMsg

    # ---------- 5. migrate под pos_migrate ----------
    $migrateJs = Join-Path $apiDir 'dist\migrate.js'
    if (Test-Path -LiteralPath $migrateJs) {
        Write-Host '== 5. node dist\migrate.js (APP_ENV=staging, DATABASE_URL_FILE, DB_MIGRATOR_PASSWORD_FILE)'
        $saved = @{}
        $envs = @{ APP_ENV = 'staging'; LOG_LEVEL = 'info'; DATABASE_URL_FILE = (Join-Path $secDir 'database_url');
                   DB_MIGRATOR_PASSWORD_FILE = (Join-Path $secDir 'db_migrator_password'); DATABASE_URL = $null; DB_MIGRATOR_PASSWORD = $null }
        foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
        try {
            Push-Location $apiDir
            $m1 = (& $node $migrateJs 2>&1 | Out-String); $c1 = $LASTEXITCODE
            $m2 = (& $node $migrateJs 2>&1 | Out-String); $c2 = $LASTEXITCODE
        } finally {
            Pop-Location
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $m1lines = @($m1 -split "`r?`n" | Where-Object { $_ -match 'migrate: |pgboss|pg-boss|локаль|"level":(40|50|60)' })
        $m1lines | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
        Check 'migrate №1: код 0' ($c1 -eq 0) "код $c1"
        Check 'migrate №1: под pos_migrate, миграции применены' (($m1 -match '"user":"pos_migrate"') -and ($m1 -match 'migrate: готово'))
        Check 'migrate №1: нет предупреждения о локали' (-not ($m1 -match 'не приводит кириллицу'))
        Check 'migrate №2: код 0, 0 изменений' (($c2 -eq 0) -and ($m2 -match '0 изменений')) "код $c2"
        if ($c1 -ne 0) { Write-Host $m1 }

        Write-Host '== 5б. apply-roles.ps1 -GateOnly -Verify после миграций (pos_backup читает все схемы)'
        $out5 = & (Join-Path $kit 'apply-roles.ps1') -InstallRoot $root -Port $Port -NodeExe $node -ApiDir $apiDir -GateOnly -Verify *>&1 | Out-String
        Write-Host $out5
        Check 'после migrate: verify пройдена' ($out5 -match 'проверка прав ролей: пройдена')
        $tbl = [regex]::Match($out5, 'таблиц (\d+)')
        Check 'после migrate: pos_backup прочитал > 50 таблиц' ($tbl.Success -and [int]$tbl.Groups[1].Value -gt 50) $tbl.Value
    } else {
        Write-Host "== 5. ПРОПУЩЕНО: нет $migrateJs"
        $script:fail++
    }

    # ---------- 6. Архивирование WAL ----------
    # Настоящий pos-backup.mjs через junction current и backup.json с walSpoolDir. %p относителен каталога данных:
    # сегмент найден инструментом — значит рабочий каталог archive_command — каталог данных.
    Write-Host '== 6. archive_command (стандартная): сегмент WAL в спуле настоящего pos-backup.mjs'
    $a = Invoke-Helper 'archive-check' @('--arg', $spool)
    Write-Host "    $($a.Out)"
    Check 'архивирование: сегмент в спуле, failed_count = 0' ($a.Code -eq 0)
    $seg = @(Get-ChildItem -LiteralPath $spool -File | Where-Object { $_.Name -match '^[0-9A-F]{24}$' })
    Check 'спул: сегменты по 16 МБ' (($seg.Count -ge 1) -and (@($seg | Where-Object { $_.Length -ne 16MB }).Count -eq 0)) "$($seg.Count) шт."

    # ---------- 7. -ConfigOnly ----------
    Write-Host '== 7. init-postgres.ps1 -ConfigOnly -DevTest'
    & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port -DevTest -ConfigOnly -SharedBuffers 256MB
    $confText = [System.IO.File]::ReadAllText((Join-Path $dataDir 'optomstroy.conf'))
    Check '-ConfigOnly: shared_buffers обновлён' ($confText -match '(?m)^shared_buffers = 256MB$')
    $incl = ([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $dataDir 'postgresql.conf')), "(?m)^include 'optomstroy\.conf'")).Count
    Check 'include optomstroy.conf ровно один раз' ($incl -eq 1) "$incl"
    $dup = $false
    try { & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port -DevTest 2>$null } catch { $dup = ($_.Exception.Message -like '*не пуст*') }
    Check 'повторный init на непустом каталоге — отказ' $dup

    # ---------- 8. stop ----------
    Write-Host '== 8. stop-postgres.ps1 -DevTest'
    & (Join-Path $kit 'stop-postgres.ps1') -PgBin $PgBin -InstallRoot $root -DevTest
    $started = $false
    Start-Sleep -Milliseconds 500
    Check 'после stop порт закрыт' (-not (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue))
    Check 'после stop нет postmaster.pid' (-not (Test-Path -LiteralPath (Join-Path $dataDir 'postmaster.pid')))
    Check 'данные не удалены' (Test-Path -LiteralPath (Join-Path $dataDir 'PG_VERSION'))

    # ---------- 9. -Resume: продолжение после сбоя (кластер есть, initdb не повторяется) ----------
    Write-Host '== 9. init-postgres.ps1 -DevTest -Resume'
    & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port -DevTest -Resume -SharedBuffers 128MB
    $started = $true
    Check '-Resume: сервер запущен на том же кластере' ((Test-PortListening $Port) -and ((Get-Content -LiteralPath (Join-Path $dataDir 'PG_VERSION')) -eq '17'))
    $r9 = Invoke-Helper 'settings'
    Check '-Resume: роли и база на месте (вход суперпользователем)' ($r9.Code -eq 0)
    $both = $false
    try { & (Join-Path $kit 'init-postgres.ps1') -PgBin $PgBin -InstallRoot $root -Port $Port -DevTest -Resume -ConfigOnly 2>$null } catch { $both = ($_.Exception.Message -like '*вместе*') }
    Check '-Resume с -ConfigOnly — отказ' $both
    & (Join-Path $kit 'stop-postgres.ps1') -PgBin $PgBin -InstallRoot $root -DevTest
    $started = $false
} catch {
    $script:fail++
    Write-Host "  FAIL исключение: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
} finally {
    if ($started) {
        try { & (Join-Path $kit 'stop-postgres.ps1') -PgBin $PgBin -InstallRoot $root -DevTest } catch { Write-Host "stop: $($_.Exception.Message)" }
    }
    # junction current снимается отдельно (rmdir удаляет только ссылку): Remove-Item -Recurse в PowerShell 5.1 может
    # пройти по junction в цель.
    if (Test-Path -LiteralPath $currentLink) { & cmd.exe /c rmdir "$currentLink" | Out-Null }
    if (-not $KeepTemp) {
        if (Test-Path -LiteralPath $currentLink) { Write-Host "junction $currentLink не снят — папка прогона оставлена" }
        else { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "== ИТОГ: PASS $script:pass, FAIL $script:fail"
    Stop-Transcript | Out-Null
}
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
