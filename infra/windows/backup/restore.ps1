<#
.SYNOPSIS
  Восстановление базы POS из ежедневного дампа (pg_dump -Fc, зашифрован OPTBK1) под Windows Server.

.DESCRIPTION
  Выполняет администратор в присутствии держателя закрытого ключа (ключ — на время сеанса, на сервере не остаётся).
  Порядок — 16 §8.5 (как restore-db.sh в Linux: сначала проверка копии с ключом, потом подтверждение):
    0. Предварительные проверки (до любых изменений): программы PostgreSQL; для ролей (без -SkipPasswords) —
       postgres\apply-roles.ps1 релиза, secrets\pg_password, database_url с базой -Database, модуль pg (-ApiDir).
    1. Проверка копии ЦЕЛИКОМ с ключом (verify-file --key: структура, SHA-256, подлинность каждого куска,
       расшифровка без записи на диск); то же для -GlobalsFile. Ошибка — выход, база и службы не тронуты.
    2. Подтверждение вводом имени базы (без него ничего не меняется; -Force или -DevTest — без ввода).
    3. Остановка OptomstroyApi, OptomstroyWorker, OptomstroyBackup.
    4. Роли из globals (по желанию, -GlobalsFile; ошибки «уже существует» ожидаемы). В копии нет паролей.
    5. Прежняя база переименовывается в <база>_before_<время> (страховочная копия; -DropOld — удалить, только после
       успешной проверки шага 1). Новая пустая база — с локалью как при установке (UTF8, builtin C.UTF-8,
       LC_COLLATE C, LC_CTYPE -LcCtype):
         - без -SkipPasswords — postgres\apply-roles.ps1 (как при установке и в update.ps1/rollback.ps1): создаёт
           базу, приводит роли к эталону roles.sql (NOSUPERUSER, NOBYPASSRLS, у pos_backup — REPLICATION и
           pg_read_all_data; это же снимает лишние атрибуты из globals), пароли — верификаторами SCRAM-SHA-256 из
           файлов секретов (открытый пароль не уходит ни в журнал PostgreSQL, ни в командную строку), права на базу,
           стоп-проверка lower('ЁЯ') = 'ёя';
         - с -SkipPasswords — роли не трогаются (должны уже быть), база создаётся здесь, права на базу — как при
           установке.
       В обоих случаях — стоп-проверка локали новой базы (lower('ЁЯ') = 'ёя', builtin C.UTF-8, LC_COLLATE C).
    6. Восстановление потоком: pos-backup.mjs decrypt-pipe → pg_restore --exit-on-error (без -j: параллельному
       восстановлению нужен расшифрованный файл на диске). Проверяются и расшифровка (подлинность каждого куска,
       наличие последнего), и код pg_restore. Затем ANALYZE.
    7. Фото и отметки аудита: накопительная копия из папки копий обратно — каждая папка mediaDirs из backup.json
       (media\<name> → её path; по умолчанию media → data\media, audit-anchors → data\audit-anchors), robocopy /E /XO,
       без удаления.
    8. migrate — если программа новее копии (команда из инструкции установки; скрипт её не запускает).
    9. Предупреждение OPS-KI-04 для кассиров. 10. Запуск служб. 11. Ручной обмен с 1С.

  Пароль суперпользователя postgres для psql и pg_restore: файл паролей PostgreSQL (-SuperPassFile, формат pgpass)
  или ввод с клавиатуры. apply-roles.ps1 берёт его из secrets\pg_password (как при установке).

  Проверка восстановления без остановки служб и без изменения ролей — restore-drill.ps1 (временный кластер).

.EXAMPLE
  .\restore.ps1 -DumpFile D:\OptomstroyBackups\dumps\20261121-003000.dump.optbk -KeyFile E:\key\backup-private.pem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DumpFile,
    [Parameter(Mandatory = $true)][string]$KeyFile,
    [string]$GlobalsFile,
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$BackupRoot = 'D:\OptomstroyBackups',
    [string]$BackupConfig,
    [string]$Database = 'optomstroy',
    [string]$PgBin = 'C:\Program Files\PostgreSQL\17\bin',
    [string]$PgHost = '127.0.0.1',
    [int]$Port = 5433,
    [string]$SuperUser = 'postgres',
    [string]$SuperPassFile,
    [string]$SecretsDir,
    [string]$ApiDir,
    [string]$LcCtype = 'en-US',
    [switch]$SkipPasswords,
    [switch]$SkipMedia,
    [switch]$DropOld,
    [switch]$Force,
    [string]$NodeExe,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

$tool = Join-Path $PSScriptRoot 'pos-backup.mjs'
$psqlExe = Join-Path $PgBin 'psql.exe'
$pgRestore = Join-Path $PgBin 'pg_restore.exe'
foreach ($p in @($psqlExe, $pgRestore)) { if (-not (Test-Path -LiteralPath $p)) { Stop-WithError "не найден $p" } }
if (-not $DevTest -and -not (Test-IsAdmin)) { Stop-WithError 'нужен PowerShell «от имени администратора» (или -DevTest для проверочного стенда)' }
if (-not (Test-Path -LiteralPath $DumpFile)) { Stop-WithError "нет файла $DumpFile" }
if ($Database -notmatch '^[a-z_][a-z0-9_]*$') { Stop-WithError "недопустимое имя базы $Database" }
if ($SuperUser -notmatch '^[a-z_][a-z0-9_]*$') { Stop-WithError "недопустимое имя суперпользователя $SuperUser" }
if ($LcCtype -notmatch '^[A-Za-z0-9_.\-]+$') { Stop-WithError "недопустимое имя локали -LcCtype $LcCtype" }
$node = Resolve-NodeExe -NodeExe $NodeExe -InstallRoot $InstallRoot -DevTest:$DevTest
if (-not $SecretsDir) { $SecretsDir = Join-Path $InstallRoot 'secrets' }   # check-secrets: allow — имя переменной или пути, не значение секрета
if (-not $BackupConfig) { $BackupConfig = Join-Path $InstallRoot 'config\backup.json' }
if (-not $ApiDir) { $ApiDir = Join-Path $InstallRoot 'current\api' }

# backup.json: папки фото и отметок аудита (mediaDirs) и корень копий (если -BackupRoot не задан явно).
$bkCfg = $null
if (Test-Path -LiteralPath $BackupConfig) {
    try { $bkCfg = Read-JsonFile $BackupConfig } catch { Write-Host "   ВНИМАНИЕ: $BackupConfig не прочитан ($($_.Exception.Message)) — папки фото по умолчанию" -ForegroundColor Yellow }
}
if ($null -ne $bkCfg -and -not $PSBoundParameters.ContainsKey('BackupRoot') -and $bkCfg.PSObject.Properties['backupRoot'] -and $bkCfg.backupRoot) { $BackupRoot = [string]$bkCfg.backupRoot }
$mediaDirs = @()
if ($null -ne $bkCfg -and $bkCfg.PSObject.Properties['mediaDirs'] -and @($bkCfg.mediaDirs).Count -gt 0) {
    foreach ($m in @($bkCfg.mediaDirs)) { $mediaDirs += [pscustomobject]@{ Name = [string]$m.name; Path = [string]$m.path } }
} else {
    $mediaDirs = @(
        [pscustomobject]@{ Name = 'media'; Path = (Join-Path $InstallRoot 'data\media') },
        [pscustomobject]@{ Name = 'audit-anchors'; Path = (Join-Path $InstallRoot 'data\audit-anchors') })
}

# Роли и база — apply-roles.ps1 релиза (тот же, что вызывают install.ps1, update.ps1 и rollback.ps1).
$applyRoles = Join-Path (Split-Path -Parent $PSScriptRoot) 'postgres\apply-roles.ps1'
if (-not $SkipPasswords) {
    Write-Step '0. Предварительные проверки (роли и пароли — apply-roles.ps1)'
    if (-not (Test-Path -LiteralPath $applyRoles)) { Stop-WithError "нет $applyRoles (или -SkipPasswords: роли не трогаются)" }
    if ($PgHost -ne '127.0.0.1') { Stop-WithError 'apply-roles.ps1 подключается только к 127.0.0.1 (или -SkipPasswords)' }
    foreach ($n in @('pg_password', 'db_migrator_password', 'db_backup_password', 'database_url')) {
        if (-not (Test-Path -LiteralPath (Join-Path $SecretsDir $n))) { Stop-WithError "нет файла секрета $(Join-Path $SecretsDir $n) (или -SkipPasswords)" }
    }
    $url = ([IO.File]::ReadAllText((Join-Path $SecretsDir 'database_url'))).Trim([char]0xFEFF, "`r", "`n", ' ')
    if ($url -notmatch '^postgres(ql)?://pos_app:[^@]*@[^/]+/([^/?]+)') { Stop-WithError 'database_url: ожидается postgres://pos_app:…@127.0.0.1:<порт>/<база>' }
    $urlDb = [Uri]::UnescapeDataString($Matches[2])
    if ($urlDb -cne $Database) { Stop-WithError "база в database_url ($urlDb) не совпадает с -Database $Database. Восстановление в другую базу — с -SkipPasswords (роли не трогаются) или проверка копии — restore-drill.ps1." }
    if (-not (Test-Path -LiteralPath (Join-Path $ApiDir 'node_modules\pg'))) { Stop-WithError "нет модуля pg: $ApiDir\node_modules\pg (укажите -ApiDir или -SkipPasswords)" }
    Write-Note "apply-roles.ps1: $applyRoles; база $Database из database_url; модуль pg — $ApiDir"
}

# Подключение суперпользователя: только через переменные окружения процессов (не командная строка).
$oldPassFile = $env:PGPASSFILE   # check-secrets: allow — имя переменной или пути, не значение секрета
$oldPassword = $env:PGPASSWORD   # check-secrets: allow — имя переменной или пути, не значение секрета
if ($SuperPassFile) {
    $env:PGPASSFILE = $SuperPassFile   # check-secrets: allow — имя переменной или пути, не значение секрета
} elseif (-not $env:PGPASSWORD) {
    $sec = Read-Host -AsSecureString "Пароль $SuperUser (PostgreSQL)"
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
$conn = @('-h', $PgHost, '-p', "$Port", '-U', $SuperUser, '-w')

function Invoke-Sql([string]$Db, [string]$Sql, [switch]$AllowErrors, [switch]$Capture) {
    $stop = 'ON_ERROR_STOP=1'
    if ($AllowErrors) { $stop = 'ON_ERROR_STOP=0' }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        # Текст запроса — файлом (-f): кавычки внутри SQL не проходят через разбор командной строки PowerShell 5.1.
        [IO.File]::WriteAllText($tmp, $Sql, (New-Object System.Text.UTF8Encoding($false)))
        if ($Capture) { return (Invoke-Capture $psqlExe (@('-X', '-q', '-A', '-t', '-v', $stop) + $conn + @('-d', $Db, '-f', $tmp))) }
        return (Invoke-Native $psqlExe (@('-X', '-q', '-v', $stop) + $conn + @('-d', $Db, '-f', $tmp)))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

try {
    # Сначала — проверка копии ЦЕЛИКОМ с ключом (как «age -d в никуда» в Linux): неверный ключ или парольная фраза,
    # подменённый или повреждённый кусок обнаруживаются до того, как рабочая база переименована или удалена.
    Request-KeyPassphrase $KeyFile
    Write-Step '1. Проверка копии целиком с ключом (расшифровка без записи на диск)'
    $code = Invoke-Native $node @($tool, 'verify-file', $DumpFile, '--key', $KeyFile)
    if ($code -ne 0) { Stop-WithError "копия не прошла проверку с ключом (код $code): неверный ключ или парольная фраза, повреждённый или подменённый файл. База не тронута, службы не остановлены." }
    if ($GlobalsFile) {
        $code = Invoke-Native $node @($tool, 'verify-file', $GlobalsFile, '--key', $KeyFile)
        if ($code -ne 0) { Stop-WithError "файл globals не прошёл проверку с ключом (код $code). База не тронута." }
    }
    $su = Invoke-Capture $psqlExe (@('-X', '-A', '-t') + $conn + @('-d', 'postgres', '-c', 'SELECT 1'))
    if ($su.Code -ne 0) { Stop-WithError "нет подключения к PostgreSQL ${PgHost}:$Port суперпользователем $SuperUser. База не тронута." }

    Write-Step '2. Подтверждение'
    $action = "переименована в ${Database}_before_<время>"
    if ($DropOld) { $action = 'УДАЛЕНА (-DropOld)' }
    Write-Note "База $Database на ${PgHost}:$Port будет $action и восстановлена из $(Split-Path $DumpFile -Leaf)."
    if ($Force -or $DevTest) {
        Write-Note '-Force/-DevTest: без ввода подтверждения'
    } else {
        $typed = Read-Host "Для подтверждения введите имя базы ($Database)"
        if ($typed -cne $Database) { Stop-WithError 'подтверждение не совпало — ничего не сделано' }
    }

    Write-Step '3. Остановка служб программы'
    if ($DevTest) { Write-Note '-DevTest: службы не трогаются' } else { Stop-AppServices }

    if ($GlobalsFile) {
        Write-Step '4. Роли из globals (ошибки «уже существует» ожидаемы)'
        $code = Invoke-Native $node (@($tool, 'decrypt-pipe', '--key', $KeyFile, $GlobalsFile, '--', $psqlExe, '-X', '-q', '-v', 'ON_ERROR_STOP=0') + $conn + @('-d', 'postgres'))
        if ($code -ne 0) { Stop-WithError "globals не применены (код $code)" }
        if ($SkipPasswords) { Write-Host '   ВНИМАНИЕ: -SkipPasswords — атрибуты ролей из globals не приводятся к эталону roles.sql и пароли не выставлены' -ForegroundColor Yellow }
    } else {
        Write-Step '4. Роли: globals не указан — роли берутся из текущего кластера'
    }

    Write-Step "5. Пустая база $Database"
    $exists = Invoke-Capture $psqlExe (@('-X', '-A', '-t') + $conn + @('-d', 'postgres', '-c', "SELECT 1 FROM pg_database WHERE datname = '$Database'"))
    if ($exists.Code -ne 0) { Stop-WithError 'нет подключения к PostgreSQL суперпользователем' }
    if ($exists.Out -eq '1') {
        $old = "${Database}_before_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
        $sql = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$Database' AND pid <> pg_backend_pid();`n"
        if ($DropOld) { $sql += "DROP DATABASE `"$Database`";`n" } else { $sql += "ALTER DATABASE `"$Database`" RENAME TO `"$old`";`n" }
        $code = Invoke-Sql 'postgres' $sql
        if ($code -ne 0) { Stop-WithError "прежняя база не освобождена (код $code)" }
        if ($DropOld) { Write-Note 'прежняя база удалена (-DropOld)' } else { Write-Note "прежняя база сохранена как $old (удалить после проверки: DROP DATABASE `"$old`")" }
    }
    if (-not $SkipPasswords) {
        # Как install.ps1: база с локалью эталона, роли (верификаторы SCRAM, атрибуты roles.sql), права, стоп-проверка.
        $arArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $applyRoles, '-InstallRoot', $InstallRoot, '-SecretsDir', $SecretsDir,
            '-Port', "$Port", '-Superuser', $SuperUser, '-NodeExe', $node, '-ApiDir', $ApiDir, '-LcCtype', $LcCtype, '-SkipArchiveCheck')
        $code = Invoke-Native 'powershell.exe' $arArgs
        if ($code -ne 0) { Stop-WithError "apply-roles.ps1 завершился с кодом $code (роли, база или стоп-проверка локали). Службы остановлены; прежняя база — $(if ($DropOld) { 'удалена' } else { 'переименована' })." }
        Write-Note "база $Database, роли pos_migrate, pos_app, pos_readonly, pos_backup и права — по эталону roles.sql; пароли — верификаторами SCRAM из секретов"
    } else {
        $code = Invoke-Sql 'postgres' "CREATE DATABASE `"$Database`" OWNER pos_migrate TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE '$LcCtype';"
        if ($code -ne 0) { Stop-WithError "база $Database не создана (код $code; роль pos_migrate должна существовать)" }
        $grants = @'
DO $$ BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO pos_app', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO pos_readonly, pos_backup', current_database());
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
'@
        $code = Invoke-Sql $Database $grants
        if ($code -ne 0) { Stop-WithError "права на базу не выданы (код $code)" }
        Write-Note '-SkipPasswords: роли и пароли не менялись'
    }
    # Стоп-проверка локали (07 §10.1): байты UTF-8, не зависит от кодовой страницы консоли.
    $gateSql = @'
SELECT (lower(convert_from('\xd081d0af'::bytea, 'UTF8') COLLATE "default") = convert_from('\xd191d18f'::bytea, 'UTF8') COLLATE "default")::text
       || '|' || d.datlocprovider::text || '|' || coalesce(d.datlocale, '') || '|' || d.datcollate || '|' || d.datctype || '|' || pg_encoding_to_char(d.encoding)
  FROM pg_database d WHERE d.datname = current_database();
'@
    $gate = Invoke-Sql $Database $gateSql -Capture
    $g = @($gate.Out -split '\|')
    if ($gate.Code -ne 0 -or $g.Count -lt 6) { Stop-WithError "стоп-проверка локали базы $Database не выполнена (код $($gate.Code))" }
    if ($g[0] -ne 'true' -or $g[1] -ne 'b' -or $g[2] -ne 'C.UTF-8' -or $g[3] -ne 'C' -or $g[4] -eq 'C' -or $g[4] -eq 'POSIX' -or $g[5] -ne 'UTF8') {
        Stop-WithError "СТОП: локаль базы $Database не как при установке (lower('ЁЯ') = 'ёя': $($g[0]); провайдер $($g[1]) $($g[2]); LC_COLLATE $($g[3]); LC_CTYPE $($g[4]); $($g[5])). Восстановление не выполнено."
    }
    Write-Note "стоп-проверка lower('ЁЯ') = 'ёя': пройдена (builtin C.UTF-8, LC_COLLATE C, LC_CTYPE $($g[4]))"

    Write-Step '6. Восстановление потоком (decrypt-pipe → pg_restore)'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Native $node (@($tool, 'decrypt-pipe', '--key', $KeyFile, $DumpFile, '--', $pgRestore, '--exit-on-error') + $conn + @('-d', $Database))
    if ($code -ne 0) {
        Stop-WithError "pg_restore или расшифровка завершились с ошибкой (код $code). База $Database неполная, службы остановлены. Повторите с другой копией."
    }
    Write-Note "восстановлено за $([int]$sw.Elapsed.TotalSeconds) с"
    $code = Invoke-Sql $Database 'ANALYZE;'
    if ($code -ne 0) { Write-Host '   ВНИМАНИЕ: ANALYZE завершился с ошибкой' -ForegroundColor Yellow }
    $check = Invoke-Capture $psqlExe (@('-X', '-A', '-t') + $conn + @('-d', $Database, '-c', "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension"))
    Write-Note "расширения: $($check.Out)"
} finally {
    Clear-KeyPassphrase
    $env:PGPASSFILE = $oldPassFile   # check-secrets: allow — имя переменной или пути, не значение секрета
    $env:PGPASSWORD = $oldPassword   # check-secrets: allow — имя переменной или пути, не значение секрета
}

Write-Step '7. Фото и отметки аудита'
if ($SkipMedia) {
    Write-Note 'пропущено (-SkipMedia)'
} elseif ($DevTest -and $null -eq $bkCfg) {
    Write-Note '-DevTest без -BackupConfig: пропущено (папки рабочей установки не трогаются)'
} else {
    foreach ($m in $mediaDirs) {
        if ($m.Name -notmatch '^[A-Za-z0-9_-]+$' -or -not $m.Path) { Write-Host "   ВНИМАНИЕ: mediaDirs: пропущен элемент «$($m.Name)»" -ForegroundColor Yellow; continue }
        $src = Join-Path $BackupRoot "media\$($m.Name)"
        if (-not (Test-Path -LiteralPath $src)) { Write-Note "нет копии $src — пропуск"; continue }
        & robocopy.exe $src $m.Path /E /XO /R:2 /W:5 /NP /NFL /NDL | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host "   ВНИМАНИЕ: robocopy $src → $($m.Path): код $LASTEXITCODE" -ForegroundColor Yellow } else { Write-Note "$($m.Name): восстановлено из $src в $($m.Path)" }
    }
}

Write-Step '8–11. Дальше (администратор)'
Write-Note '8) Если программа новее копии — migrate по инструкции установки (до запуска служб).'
Write-Note '9) OPS-KI-04: до запуска касс предупредить кассиров — заказы и корзины после момента копии потеряны, черновики на устройствах не переотправлять без проверки.'
if ($DevTest) {
    Write-Note '10) -DevTest: службы не запускаются.'
} else {
    Write-Note '10) Запустить службы: Start-Service OptomstroyApi, OptomstroyWorker, OptomstroyBackup'
}
Write-Note '11) Ручной обмен с 1С и сверка очереди отправки в 1С за окно потери.'
exit 0
