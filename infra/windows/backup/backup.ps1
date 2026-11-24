<#
.SYNOPSIS
  Ручной запуск шагов резервного копирования POS на Windows Server (обёртка над pos-backup.mjs).

.DESCRIPTION
  Обычная работа идёт в службе OptomstroyBackup (pos-backup.mjs daemon). Этот скрипт — для ручных шагов:
    status       состояние для мониторинга (код 0 — норма, 1 — есть проблемы; список в поле problems) и проверка
                 прав закрытых папок (корень копий, спул WAL — как set-backup-acl.ps1 -CheckOnly; -DevTest — без неё)
    dump-now     ежедневный прогон сейчас: дамп, (globals с -Globals), базовая копия PITR, фото, вне сервера, очистка
    dump-only    только дамп (обновление программы: код 0 — дамп создан; базовая копия, фото, вне сервера не делаются)
    base-now     только базовая копия PITR (после восстановления, после включения PITR)
    wal-ship     отправить WAL из спула в зашифрованный архив сейчас
    offsite-now  копия вне сервера сейчас (с -WalOnly — только PITR)
    prune        очистка по срокам хранения
    verify       проверка файла копии без ключа (-File)
  Запуск от имени учётной записи с правами службы резервного копирования (секрет pgpass_backup.conf читает
  только NT SERVICE\OptomstroyBackup и администраторы). Для status и verify прав на секрет не нужно (status -NoDb).

.EXAMPLE
  .\backup.ps1 -Action status
.EXAMPLE
  .\backup.ps1 -Action dump-now -Globals
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'dump-now', 'dump-only', 'base-now', 'wal-ship', 'offsite-now', 'prune', 'verify')]
    [string]$Action,
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$Config,
    [string]$File,
    [switch]$Globals,
    [switch]$WalOnly,
    [switch]$NoDb,
    [string]$NodeExe,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

$tool = Join-Path $PSScriptRoot 'pos-backup.mjs'
if (-not $Config) { $Config = Join-Path $InstallRoot 'config\backup.json' }
$node = Resolve-NodeExe -NodeExe $NodeExe -InstallRoot $InstallRoot -DevTest:$DevTest

$a = @($tool, $Action)
switch ($Action) {
    'verify' {
        if (-not $File) { Stop-WithError 'для -Action verify нужен -File <файл копии>' }
        $a = @($tool, 'verify-file', $File)
    }
    'status' { $a += @('--config', $Config); if ($NoDb) { $a += '--no-db' } }
    'dump-now' { $a += @('--config', $Config); if ($Globals) { $a += '--globals' } }
    'dump-only' { $a += @('--config', $Config) }
    'offsite-now' { $a += @('--config', $Config); if ($WalOnly) { $a += '--wal' } }
    default { $a += @('--config', $Config) }
}
$code = Invoke-Native $node $a
if ($Action -eq 'status' -and -not $DevTest) {
    # Подлинность архива держится на правах папок (OPTBK1 шифрует открытым ключом): проверка как set-backup-acl.ps1.
    $global:LASTEXITCODE = 0
    $aclArgs = @{ InstallRoot = $InstallRoot; CheckOnly = $true }
    try {
        $cfgJson = [IO.File]::ReadAllText($Config) | ConvertFrom-Json
        if ($cfgJson.backupRoot) { $aclArgs.BackupRoot = $cfgJson.backupRoot }
        if ($cfgJson.walSpoolDir) { $aclArgs.WalSpoolDir = $cfgJson.walSpoolDir }
    } catch {
        Write-Host "   ВНИМАНИЕ: $Config не прочитан — права проверяются по путям по умолчанию" -ForegroundColor Yellow
    }
    try {
        # учётная запись службы PostgreSQL — из install.json (install.ps1 -PgServiceAccount); нет — NetworkService
        $ijPath = Join-Path $InstallRoot 'config\install.json'
        if (Test-Path -LiteralPath $ijPath) {
            $ijJson = [IO.File]::ReadAllText($ijPath) | ConvertFrom-Json
            if ($ijJson.pgServiceAccount) { $aclArgs.PgServiceAccount = [string]$ijJson.pgServiceAccount }
        }
    } catch { Write-Host '   ВНИМАНИЕ: config\install.json не прочитан — учётная запись PostgreSQL по умолчанию' -ForegroundColor Yellow }
    $acl = Join-Path $PSScriptRoot 'set-backup-acl.ps1'
    & $acl @aclArgs   # exit внутри скрипта завершает только его; код — в $LASTEXITCODE
    if ($LASTEXITCODE -ne 0 -and $code -eq 0) { $code = 1 }
}
exit $code
