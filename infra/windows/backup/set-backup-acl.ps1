<#
.SYNOPSIS
  Права NTFS для резервного копирования POS (выполняет администратор сервера; posdeploy этого сделать не может).

.DESCRIPTION
  Формат OPTBK1 шифрует открытым ключом: зашифровать «правильный» файл может кто угодно. Поэтому подлинность
  архива (дампы, базовые копии, сегменты WAL) держится на правах папок: писать в корень копий и в спул WAL могут
  только службы и администраторы. На томе данных по умолчанию «Прошедшие проверку» (Authenticated Users) имеют
  право изменения вложенных папок — без этого скрипта любой локальный пользователь мог бы подложить сегмент WAL,
  и PITR воспроизвёл бы его.

  Что делает (повторный запуск безопасен):
    1. Корень копий (-BackupRoot): наследование отключено; Administrators, SYSTEM — F; NT SERVICE\OptomstroyBackup — M.
    2. Спул WAL (data\walspool): наследование отключено; Administrators, SYSTEM — F; OptomstroyBackup и учётная
       запись службы PostgreSQL (archive_command) — M.
    3. Служба OptomstroyBackup: RX на саму папку -InstallRoot (только папка — переход к current), (OI)(CI)RX на
       releases (node.exe и pos-backup.mjs любого релиза), RX на папки фото, M на logs\backup, R на
       config\backup.json и config\backup-public.pem.
    4. Секреты secrets\pgpass_backup.conf и secrets\healthchecks_url (если есть): наследование отключено,
       Administrators — F, OptomstroyBackup — R.
    5. Проверка закрытых папок (1, 2): нет унаследованных записей и нет лишних разрешений. Нарушение — код 1.
  -CheckOnly — только проверка 5 (ничего не меняет).
  -DevTest — проверочный стенд без прав администратора: вместо учётных записей служб — текущий пользователь,
  пути — свои временные папки.

.EXAMPLE
  .\set-backup-acl.ps1
.EXAMPLE
  .\set-backup-acl.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$BackupRoot = 'D:\OptomstroyBackups',
    [string]$WalSpoolDir,
    [string[]]$MediaDirs,
    [string]$ServiceAccount = 'NT SERVICE\OptomstroyBackup',
    [string]$PgServiceAccount = 'NT AUTHORITY\NetworkService',
    [switch]$CheckOnly,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

if (-not $DevTest -and -not $CheckOnly -and -not (Test-IsAdmin)) { Stop-WithError 'нужен PowerShell «от имени администратора» (или -DevTest для проверочного стенда)' }
if (-not $WalSpoolDir) { $WalSpoolDir = Join-Path $InstallRoot 'data\walspool' }
if (-not $MediaDirs) { $MediaDirs = @((Join-Path $InstallRoot 'data\media'), (Join-Path $InstallRoot 'data\audit-anchors')) }

try {
    if ($DevTest) {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $svcSid = $me
        $pgSid = $me
        Write-Note "-DevTest: учётные записи служб заменены текущим пользователем ($me)"
    } else {
        $svcSid = Resolve-AccountSid $ServiceAccount
        $pgSid = Resolve-AccountSid $PgServiceAccount
    }
} catch {
    Stop-WithError $_.Exception.Message
}
$baseSids = @($script:SidAdministrators, $script:SidSystem)
$private = @(
    @{ Path = $BackupRoot; Modify = @($svcSid) },
    @{ Path = $WalSpoolDir; Modify = @($svcSid, $pgSid) | Select-Object -Unique }
)

if (-not $CheckOnly) {
    try {
        Write-Step '1–2. Закрытые папки: корень копий и спул WAL'
        foreach ($p in $private) {
            if (-not (Test-Path -LiteralPath $p.Path)) { New-Item -ItemType Directory -Force -Path $p.Path | Out-Null }
            Set-PrivateAcl -Path $p.Path -FullSids $baseSids -ModifySids $p.Modify
            Write-Note "$($p.Path): наследование отключено; Administrators, SYSTEM — F; $($p.Modify -join ', ') — M"
        }

        Write-Step '3. Доступ службы OptomstroyBackup к релизу, настройкам, фото и журналу'
        $releases = Join-Path $InstallRoot 'releases'
        $logs = Join-Path $InstallRoot 'logs\backup'
        foreach ($d in @($releases, $logs)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
        Invoke-Icacls @($InstallRoot, '/grant', "*${svcSid}:(RX)")            # только сама папка: переход к current
        Invoke-Icacls @($releases, '/grant', "*${svcSid}:(OI)(CI)RX")         # node.exe и pos-backup.mjs любого релиза
        Invoke-Icacls @($logs, '/grant', "*${svcSid}:(OI)(CI)M")              # журнал службы (пишет OptomstroySvc.exe)
        Write-Note "$InstallRoot — RX (только папка); $releases — RX; $logs — M"
        foreach ($m in $MediaDirs) {
            if (Test-Path -LiteralPath $m) {
                Invoke-Icacls @($m, '/grant', "*${svcSid}:(OI)(CI)RX")
                Write-Note "$m — RX"
            } else {
                Write-Host "   ВНИМАНИЕ: нет папки $m — права не выданы (повторите после установки)" -ForegroundColor Yellow
            }
        }
        foreach ($f in @('config\backup.json', 'config\backup-public.pem')) {
            $p = Join-Path $InstallRoot $f
            if (Test-Path -LiteralPath $p) { Invoke-Icacls @($p, '/grant', "*${svcSid}:(R)"); Write-Note "$p — R" }
            else { Write-Host "   ВНИМАНИЕ: нет файла $p — права не выданы (повторите после настройки)" -ForegroundColor Yellow }
        }

        Write-Step '4. Секреты службы резервного копирования'
        foreach ($f in @('secrets\pgpass_backup.conf', 'secrets\healthchecks_url')) {   # check-secrets: allow — имена файлов, не значения
            $p = Join-Path $InstallRoot $f
            if (Test-Path -LiteralPath $p) {
                Invoke-Icacls @($p, '/inheritance:r', '/grant:r', "*$($script:SidAdministrators):F", "*${svcSid}:R")
                Write-Note "$p — наследование отключено; Administrators — F, служба — R"
            } else {
                Write-Note "нет $p — пропуск"
            }
        }
    } catch {
        Stop-WithError $_.Exception.Message
    }
}

Write-Step '5. Проверка закрытых папок'
$bad = @()
foreach ($p in $private) {
    $problems = Test-PrivateAcl $p.Path ($baseSids + $p.Modify)
    if ($problems.Count -eq 0) { Write-Note "$($p.Path): в порядке" } else { $bad += $problems }
}
if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Host "   НАРУШЕНИЕ: $_" -ForegroundColor Red }
    Stop-WithError 'права закрытых папок резервного копирования нарушены (исправление: .\set-backup-acl.ps1 без -CheckOnly)'
}
Write-Note 'права проверены'
exit 0
