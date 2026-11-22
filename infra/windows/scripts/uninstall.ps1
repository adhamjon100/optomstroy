<#
.SYNOPSIS
  Удаление сервера Optomstroy POS с Windows Server 2022. [Администратор]

.DESCRIPTION
  Порядок:
    1. Apache: если наш виртуальный хост подключён (manifest.json со статусом enabled в <ApacheDir>\conf\optomstroy-backup),
       — disable-apache-site.ps1 -Apply (только наша строка Include и наш файл; Apache НЕ перезапускается — перезапуск
       в согласованное окно делает администратор). Больше Apache, публикация 1С и SQL Server не затрагиваются.
    2. Остановка и удаление служб OptomstroyWorker, OptomstroyApi, OptomstroyBackup (sc.exe delete).
    3. Остановка PostgreSQL и снятие службы OptomstroyPostgres (stop-postgres.ps1 -Unregister; каталог данных остаётся).
    4. Правила брандмауэра Optomstroy-Block-In-TCP-*.
    5. Ссылка current и папки releases (программа) — только если шаги 1–4 прошли без ошибок.
    6. С -KeepData:$false (по умолчанию $true) — ещё и данные: data (база, фото, спул WAL), config, secrets, state,
       logs, incoming — вся папка установки. Требуется ввести УДАЛИТЬ (или -Force). Папка резервных копий
       (BackupRoot) НЕ удаляется никогда — только вручную, после переноса копий.
       С -KeepData (по умолчанию) — с оставшихся InstallRoot и BackupRoot снимаются права NT SERVICE\Optomstroy* и
       posdeploy (icacls /remove /T): остаются Administrators и SYSTEM.
  Журнал: <InstallRoot>\logs (с -KeepData) или %TEMP%\optomstroy-uninstall; копия — <BackupRoot>\logs.
  Запускайте из распакованного пакета (например C:\Users\admin\setup\Optomstroy-Server-<версия>\scripts), а не из
  D:\Optomstroy\current\scripts: шаг 5 удаляет эту папку.
  -DevTest: без прав администратора; останавливает процессы OptomstroySvc.exe --console и pg_ctl stop.

.EXAMPLE
  .\uninstall.ps1                                  # программа удалена, данные и копии остаются
  .\uninstall.ps1 -KeepData:$false -ApacheDir C:\Apache24
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    # [object]: через powershell.exe -File значение приходит строкой ("False", "$false", "0").
    [object]$KeepData = $true,
    [string]$PgBin = '',
    [string]$ApacheDir = '',
    [string]$ApacheServiceName = '',
    [switch]$Force,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')

$kd = ([string]$KeepData).Trim().TrimStart('$').ToLowerInvariant()
if (@('true', '1', 'yes') -contains $kd) { $KeepData = $true }
elseif (@('false', '0', 'no') -contains $kd) { $KeepData = $false }
else { Write-Host "-KeepData: `$true или `$false, а не $KeepData"; exit 2 }

if ($PgBin) { $PgBin = Resolve-OpsPath $PgBin }
if ($ApacheDir) { $ApacheDir = Resolve-OpsPath $ApacheDir }
$L = Get-OpsLayout $InstallRoot
$ij = Read-OpsJson $L.InstallJson
if ($null -ne $ij -and [bool]$ij.devTest -ne [bool]$DevTest) { Write-Host 'запускайте uninstall.ps1 с тем же -DevTest, что и install.ps1'; exit 2 }
if (-not $DevTest -and -not (Test-OpsAdmin)) { Write-Host 'нужен PowerShell «от имени администратора»'; exit 2 }
if ($null -ne $ij) {
    if (-not $PgBin) { $PgBin = [string]$ij.pgBin }
    if (-not $ApacheDir -and $ij.PSObject.Properties['apacheDir']) { $ApacheDir = [string]$ij.apacheDir }
    if (-not $ApacheServiceName -and $ij.PSObject.Properties['apacheServiceName']) { $ApacheServiceName = [string]$ij.apacheServiceName }
    $L = Get-OpsLayout $InstallRoot ([string]$ij.backupRoot)
}
# Журнал: при сохранении данных — в <InstallRoot>\logs (папка остаётся); при полном удалении — в %TEMP%.
$logDir = Join-Path $env:TEMP 'optomstroy-uninstall'
if ($KeepData -and (Test-Path -LiteralPath $L.Logs -PathType Container)) { $logDir = $L.Logs }
$null = Initialize-OpsLog $logDir 'uninstall'
Write-OpsLog ("uninstall.ps1: {0}; данные {1}{2}" -f $L.Root, $(if ($KeepData) { 'сохраняются' } else { 'УДАЛЯЮТСЯ' }), $(if ($DevTest) { '; DevTest' } else { '' }))
if (-not $KeepData -and -not $Force) {
    Write-Host "Будут удалены база, фото, секреты и настройки в $($L.Root). Резервные копии ($($L.BackupRoot)) не удаляются."
    $ans = Read-Host 'Введите УДАЛИТЬ для подтверждения'
    if ($ans -ne 'УДАЛИТЬ') { Write-OpsLog 'не подтверждено — ничего не удалено' 'WARN'; exit 1 }
}
$errors = 0
function Invoke-Safe([string]$What, [scriptblock]$Body) {
    try { & $Body } catch { $script:errors++; Write-OpsLog "$What`: $($_.Exception.Message)" 'ERROR' }
}

Write-OpsLog '1. Apache' 'STEP'
Invoke-Safe 'Apache' {
    if (-not $ApacheDir) { Write-OpsLog 'Apache не указан (-ApacheDir) — пропуск; если хост подключали, отключите: apache\disable-apache-site.ps1'; return }
    $bkRoot = Join-Path $ApacheDir 'conf\optomstroy-backup'
    $enabled = @()
    if (Test-Path -LiteralPath $bkRoot) {
        foreach ($d in @(Get-ChildItem -LiteralPath $bkRoot -Directory | Where-Object { $_.Name -like '*-enable-*' })) {
            $mp = Join-Path $d.FullName 'manifest.json'
            $m = Read-OpsJson $mp
            if ($null -ne $m -and $m.status -eq 'enabled') { $enabled += $mp }
        }
    }
    if ($enabled.Count -eq 0) { Write-OpsLog 'наш хост в Apache не подключён (нет manifest.json со статусом enabled) — Apache не меняется'; return }
    $dis = Join-Path (Split-Path -Parent $PSScriptRoot) 'apache\disable-apache-site.ps1'
    if (-not (Test-Path -LiteralPath $dis)) { $dis = Join-Path $L.Current 'apache\disable-apache-site.ps1' }
    if (-not (Test-Path -LiteralPath $dis)) { throw "нет $dis — отключите хост вручную по README" }
    foreach ($mp in $enabled) {
        $p = @{ Manifest = $mp; Apply = $true }
        if ($ApacheServiceName) { $p.ServiceName = $ApacheServiceName }
        $code = Invoke-OpsScript $dis $p
        if ($code -ne 0) { throw "disable-apache-site.ps1 ($mp): код $code — httpd.conf см. вывод выше; Apache не перезапускать" }
    }
    Write-OpsLog 'хост API отключён в конфигурации Apache; перезапуск Apache — в согласованное окно (затрагивает 1С), затем проверить 1С' 'WARN'
}

Write-OpsLog '2. Службы API, фоновых задач и резервного копирования' 'STEP'
Invoke-Safe 'службы' {
    Stop-OpsAppServices $L @('OptomstroyWorker', 'OptomstroyApi', 'OptomstroyBackup') -DevTest:$DevTest
    if (-not $DevTest) {
        foreach ($n in @('OptomstroyWorker', 'OptomstroyApi', 'OptomstroyBackup')) {
            if ((Get-OpsServiceState $n) -eq 'Missing') { continue }
            $o = & sc.exe delete $n 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe delete $n`: код $LASTEXITCODE $o" }
            Write-OpsLog "служба $n удалена" 'OK'
        }
    }
}

Write-OpsLog '3. PostgreSQL' 'STEP'
Invoke-Safe 'PostgreSQL' {
    if (-not $PgBin) { throw 'неизвестен -PgBin (нет config\install.json)' }
    $stop = Join-Path (Split-Path -Parent $PSScriptRoot) 'postgres\stop-postgres.ps1'   # комплект, из которого запущен скрипт
    $curT = Get-OpsJunctionTarget $L.Current
    if (-not (Test-Path -LiteralPath $stop) -and $null -ne $curT) { $stop = Join-Path $curT 'postgres\stop-postgres.ps1' }
    if (-not (Test-Path -LiteralPath $stop)) { throw "нет $stop" }
    $p = @{ PgBin = $PgBin; InstallRoot = $L.Root }
    if ($DevTest) { $p.DevTest = $true } else { $p.Unregister = $true }
    $code = Invoke-OpsScript $stop $p
    if ($code -ne 0) { throw "stop-postgres.ps1: код $code" }
}

Write-OpsLog '4. Брандмауэр' 'STEP'
Invoke-Safe 'брандмауэр' {
    if ($DevTest) { Write-OpsLog 'DevTest: правил нет (их создаёт только установка с правами администратора)'; return }
    $rules = @(Get-NetFirewallRule -Name 'Optomstroy-Block-In-TCP-*' -ErrorAction SilentlyContinue)
    foreach ($r in $rules) { Remove-NetFirewallRule -Name $r.Name; Write-OpsLog "правило $($r.Name) удалено" 'OK' }
    if ($rules.Count -eq 0) { Write-OpsLog 'правил Optomstroy-Block-In-TCP-* нет' }
}

Write-OpsLog '5. Программа (current, releases)' 'STEP'
Invoke-Safe 'программа' {
    # Службы или PostgreSQL не остановлены/не сняты: программа не удаляется (иначе зарегистрированные или ещё
    # работающие службы остались бы с наполовину удалёнными файлами).
    if ($errors -gt 0) { throw 'были ошибки на шагах 1–4 — current и releases НЕ удаляются (разберитесь и повторите uninstall.ps1)' }
    # Текущая папка не должна быть внутри удаляемой (запуск из D:\Optomstroy\current\scripts).
    Set-Location -LiteralPath $env:TEMP
    if (-not $DevTest) {
        try { if ([System.Diagnostics.EventLog]::SourceExists('OptomstroySvc')) { Remove-EventLog -Source OptomstroySvc; Write-OpsLog 'источник журнала событий OptomstroySvc снят' 'OK' } } catch { Write-OpsLog "источник журнала событий: $($_.Exception.Message)" 'WARN' }
    }
    if (Test-Path -LiteralPath $L.Current) {
        $null = Get-OpsJunctionTarget $L.Current
        [System.IO.Directory]::Delete($L.Current, $false)
        Write-OpsLog 'ссылка current удалена' 'OK'
    }
    if (Test-Path -LiteralPath $L.Releases) {
        Remove-Item -LiteralPath $L.Releases -Recurse -Force
        Write-OpsLog "папка $($L.Releases) удалена" 'OK'
    }
}

if (-not $KeepData) {
    Write-OpsLog '6. Данные и настройки' 'STEP'
    Invoke-Safe 'данные' {
        if ($errors -gt 0) { throw 'были ошибки на предыдущих шагах — данные НЕ удаляются (разберитесь и повторите)' }
        if (Test-OpsPortListening ([int]$(if ($null -ne $ij) { $ij.pgPort } else { 5433 }))) { throw 'PostgreSQL ещё слушает порт — данные НЕ удаляются' }
        if (Test-Path -LiteralPath $L.Root) { Remove-Item -LiteralPath $L.Root -Recurse -Force; Write-OpsLog "папка $($L.Root) удалена" 'OK' }
        if ($DevTest) {
            $keyDir = Join-Path (Split-Path -Parent $L.Root) 'devtest-backup-key'
            if (Test-Path -LiteralPath $keyDir) { Remove-Item -LiteralPath $keyDir -Recurse -Force; Write-OpsLog "DevTest: тестовые ключи $keyDir удалены" 'OK' }
        }
    }
} else {
    Write-OpsLog "данные сохранены: $($L.Data), $($L.Config), $($L.Secrets), $($L.State), $($L.Logs)"
    if (Test-Path -LiteralPath $L.State) { try { Add-OpsReleasesLog $L 'uninstall (данные сохранены)' } catch { } }
    Write-OpsLog '6. Права удалённых служб и posdeploy на оставшихся папках' 'STEP'
    Invoke-Safe 'права' {
        if ($DevTest) { Write-OpsLog 'DevTest: права NTFS не выдавались — снимать нечего'; return }
        if ($errors -gt 0) { throw 'были ошибки на предыдущих шагах — права не снимаются' }
        # SID служб вычисляются (служб уже нет); posdeploy — по имени из install.json.
        $sids = @($script:OpsServiceNames | ForEach-Object { Get-OpsServiceSid $_ })
        $du = 'posdeploy'
        if ($null -ne $ij -and $ij.PSObject.Properties['deployUser'] -and $ij.deployUser) { $du = [string]$ij.deployUser }
        try { $sids += (New-Object Security.Principal.NTAccount($du)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { Write-OpsLog "учётной записи $du нет — её права снимать не нужно" }
        foreach ($root in @($L.Root, $L.BackupRoot)) {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
            foreach ($s in $sids) {
                $o = & icacls.exe $root /remove:g "*$s" /T /C /Q 2>&1
                if ($LASTEXITCODE -ne 0) { throw "icacls $root /remove:g *${s}: код $LASTEXITCODE $o" }
            }
            Write-OpsLog "$root`: права NT SERVICE\Optomstroy* и $du сняты (остались Administrators и SYSTEM)" 'OK'
        }
    }
}
Write-OpsLog "резервные копии не удалялись: $($L.BackupRoot)"
if (-not $DevTest) { Write-OpsLog 'учётных записей удалять не нужно: NT SERVICE\Optomstroy* исчезли вместе со службами. Права posdeploy на службы — тоже.' }
Write-OpsLog ("итог: {0}; журнал {1}" -f $(if ($errors -eq 0) { 'готово' } else { "ошибок: $errors" }), $script:OpsLogFile) $(if ($errors -eq 0) { 'OK' } else { 'ERROR' })
# Копия журнала удаления — в папку копий (её uninstall не удаляет): %TEMP% профиля администратора легко потерять.
if ($L.BackupRoot -and (Test-Path -LiteralPath $L.BackupRoot) -and $script:OpsLogFile -and (Test-Path -LiteralPath $script:OpsLogFile)) {
    try {
        $bl = Join-Path $L.BackupRoot 'logs'
        New-Item -ItemType Directory -Force -Path $bl | Out-Null
        Copy-Item -LiteralPath $script:OpsLogFile -Destination $bl -Force
        Write-Host "  копия журнала: $(Join-Path $bl (Split-Path -Leaf $script:OpsLogFile))"
    } catch { Write-Host "  копия журнала в $($L.BackupRoot)\logs не сделана: $($_.Exception.Message)" }
}
if ($errors -gt 0) { exit 1 }
exit 0
