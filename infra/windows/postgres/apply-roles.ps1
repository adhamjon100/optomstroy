<#
.SYNOPSIS
  Роли, база и стоп-проверка локали PostgreSQL Optomstroy на Windows Server (перенос 10-roles.sh Linux-комплекта).

.DESCRIPTION
  Запускает pg-tool.mjs на node.exe релиза с модулем pg из пакета api релиза (psql не нужен):
    setup  — база из database_url (если её нет): UTF8, builtin C.UTF-8, LC_COLLATE C, LC_CTYPE en-US;
             roles.sql: pos_migrate (владелец базы и схемы public), pos_app (CONNECT, TEMPORARY), pos_readonly (без
             пароля), pos_backup (REPLICATION, pg_read_all_data); REVOKE ALL ON DATABASE FROM PUBLIC,
             REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    gate   — стоп-проверка lower('ЁЯ') = 'ёя' (провал — код 3, установка останавливается), параметры базы,
             наличие pg_trgm, unaccent, pgcrypto, pg_stat_statements;
    verify — (-Verify) проверка прав каждой роли входом под ней: быстрая (по одной строке из каждой таблицы, без
             полного чтения), но в одной транзакции держит ACCESS SHARE на все таблицы — несколько секунд;
    archive — архивирование WAL работает: pg_switch_wal, сегмент сохранён archive_command, failed_count не растёт
             (пропуск: -SkipArchiveCheck; при archive_mode = off пропускается сама).
  Пароли — только из файлов секретов (-SecretsDir): pg_password, db_migrator_password, db_backup_password,
  database_url. В командную строку и вывод не попадают; серверу передаются верификаторы SCRAM-SHA-256.
  Скрипт повторяемый: повторный запуск приводит роли и права к эталону и обновляет пароли из секретов.

.EXAMPLE
  .\apply-roles.ps1 -InstallRoot D:\Optomstroy                 # node и api — из D:\Optomstroy\current
  .\apply-roles.ps1 -InstallRoot D:\Optomstroy -Verify         # после migrate: ещё и проверка прав
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$SecretsDir = '',
    [ValidateRange(1024, 65535)][int]$Port = 5433,
    [ValidatePattern('^[a-z_][a-z0-9_]*$')][string]$Superuser = 'postgres',
    # node.exe и папка пакета api (с node_modules\pg); по умолчанию — активный релиз (current).
    [string]$NodeExe = '',
    [string]$ApiDir = '',
    [string]$LcCtype = 'en-US',
    [switch]$GateOnly,
    [switch]$Verify,
    [switch]$SkipArchiveCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pg-common.ps1')

if ($SecretsDir -eq '') { $SecretsDir = Join-Path $InstallRoot 'secrets' } # check-secrets: allow — путь к папке секретов, не значение
if ($NodeExe -eq '') { $NodeExe = Join-Path $InstallRoot 'current\node\node.exe' }
if ($ApiDir -eq '') { $ApiDir = Join-Path $InstallRoot 'current\api' }
if (-not (Test-Path -LiteralPath $NodeExe)) { throw "Нет node.exe: $NodeExe (распакуйте релиз или укажите -NodeExe)" }
if (-not (Test-Path -LiteralPath (Join-Path $ApiDir 'node_modules\pg'))) { throw "Нет модуля pg: $ApiDir\node_modules\pg (укажите -ApiDir)" }
if (-not (Test-Path -LiteralPath $SecretsDir)) { throw "Нет папки секретов: $SecretsDir" }

$tool = Join-Path $PSScriptRoot 'pg-tool.mjs'
$common = @('--modules', $ApiDir, '--secrets', $SecretsDir, '--port', [string]$Port, '--superuser', $Superuser, '--ctype', $LcCtype)

function Invoke-PgTool([string]$Command) {
    $argv = @($tool, $Command) + $common
    if ($Command -eq 'setup') { $argv += @('--roles-sql', (Join-Path $PSScriptRoot 'roles.sql')) }
    # Вызов через & (не Start-Process): вывод pg-tool без секретов, процесс не оставляет потомков. stderr в PS 5.1
    # при перенаправлении превращается в ErrorRecord — при Stop это прервало бы скрипт до проверки кода выхода.
    $ErrorActionPreference = 'Continue'
    & $NodeExe @argv 2>&1 | ForEach-Object { Write-Host "$_" }
    return $LASTEXITCODE
}

$steps = @()
if (-not $GateOnly) { $steps += 'setup' } else { $steps += 'gate' }
if ($Verify) { $steps += 'verify' }
if (-not $SkipArchiveCheck) { $steps += 'archive' }
foreach ($s in $steps) {
    Write-PgStep "pg-tool $s"
    $code = Invoke-PgTool $s
    if ($code -eq 3) { throw "СТОП: проверка локали/расширений не пройдена (pg-tool $s, код 3). Установка остановлена." }
    if ($code -ne 0) { throw "pg-tool $s завершился с кодом $code" }
}
Write-PgStep 'Готово.'
