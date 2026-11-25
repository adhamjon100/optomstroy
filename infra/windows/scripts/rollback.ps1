<#
.SYNOPSIS
  Ручной откат сервера Optomstroy POS на прежнюю версию (после обновления, которое прошло проверки, но оказалось
  неудачным). [Администратор]

.DESCRIPTION
  Миграции базы применяются только вперёд. Поэтому:
    - если в базе нет миграций, которых не знает прежняя версия (и схема pg-boss не менялась), — откатывается только
      программа: остановка API и фоновых задач, current → прежняя версия, migrate прежней версии (подтверждает
      журнал), запуск, проверка;
    - если миграции были — откат программы отклоняется. Варианты:
        -RestoreSnapshot  вернуть базу из копии, сделанной update.ps1 -KeepSnapshot (ВСЕ изменения данных после
                          обновления теряются; изменённая база сохраняется как <база>_failed_<время>);
        -CodeOnly         откатить только программу, база остаётся новой (только если миграции лишь расширяли схему —
                          решает разработчик); migrate прежней версии не запускается;
        иначе             восстановление из дампа перед обновлением: backup\restore.ps1 (нужен держатель ключа).
  -DropSnapshot — только удалить сохранённую копию базы (освободить место).
  Стенд с 1С через ОС_API (ONEC_MODE=os_api в config\api.env или worker.env, ADR-126): откат на версию, которая этого
  режима не знает, отклоняется до остановки служб — с ним API и фоновые задачи прежней версии не стартуют. Сначала
  install.ps1 -Stand -StandOnecOsApi fixtures (или ONEC_MODE=fixtures в обоих файлах), затем rollback.ps1.
  -DevTest — установка install.ps1 -DevTest, без прав администратора.

.EXAMPLE
  .\rollback.ps1                      # на версию до последнего обновления (state\install-state.json)
  .\rollback.ps1 -ToVersion 0.1.0-abc -CodeOnly
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$ToVersion = '',
    [switch]$CodeOnly,
    [switch]$RestoreSnapshot,
    [switch]$DropSnapshot,
    [switch]$Force,
    [ValidateRange(30, 1800)][int]$HealthTimeoutSec = 180,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')
if ($CodeOnly -and $RestoreSnapshot) { Write-Host '-CodeOnly и -RestoreSnapshot вместе не используются'; exit 2 }

$L = Get-OpsLayout $InstallRoot
$ij = Read-OpsJson $L.InstallJson
if ($null -eq $ij) { Write-Host "нет $($L.InstallJson) — установки нет"; exit 2 }
if ([bool]$ij.devTest -ne [bool]$DevTest) { Write-Host 'запускайте rollback.ps1 с тем же -DevTest, что и install.ps1'; exit 2 }
$L = Get-OpsLayout $InstallRoot ([string]$ij.backupRoot)
$null = Initialize-OpsLog $L.Logs 'rollback'
$PgPort = [int]$ij.pgPort; $ApiPort = [int]$ij.apiPort; $DbName = [string]$ij.dbName; $PgBin = [string]$ij.pgBin; $appEnv = [string]$ij.appEnv
$state = ConvertTo-OpsHashtable (Read-OpsState $L)
$lu = $null
if ($state.ContainsKey('lastUpdate')) { $lu = $state.lastUpdate }
$result = 'failed'
$curVer = $null; $target = $null

function Get-LuValue([string]$Name) {
    if ($null -eq $script:lu) { return $null }
    if ($script:lu -is [System.Collections.IDictionary]) { return $script:lu[$Name] }
    $p = $script:lu.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

try {
    if (-not $DevTest -and -not (Test-OpsAdmin)) { throw 'нужен PowerShell «от имени администратора»' }
    $curDir = Get-OpsJunctionTarget $L.Current
    if ($null -eq $curDir) { throw 'нет ссылки current' }
    $curVer = [string](Get-OpsReleaseInfo $curDir).version
    Start-OpsPostgres $L $PgBin $PgPort -DevTest:$DevTest

    if ($DropSnapshot) {
        $snap = Get-LuValue 'snapshot'
        if (-not $snap) { Write-OpsLog 'сохранённой копии базы нет'; $result = 'ok'; return }
        $r = Invoke-OpsTool $L $curDir @('db', 'snapshot-drop', '--name', [string]$snap, '--modules', (Join-Path $curDir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        if ($r.Code -ne 0) { throw "snapshot-drop: код $($r.Code)" }
        $lu2 = ConvertTo-OpsHashtable $lu; $lu2.snapshot = $null; $state.lastUpdate = $lu2
        Save-OpsState $L $state
        Write-OpsLog "копия базы $snap удалена" 'OK'
        $result = 'ok'
        return
    }

    if (-not $ToVersion) { $ToVersion = [string]$state.previousVersion }
    if (-not $ToVersion) { throw 'прежняя версия неизвестна — укажите -ToVersion (папки: releases\)' }
    if ($ToVersion -eq $curVer) { throw "версия $ToVersion уже текущая" }
    $target = Join-Path $L.Releases $ToVersion
    if (-not (Test-Path -LiteralPath $target)) { throw "нет папки $target" }
    Write-OpsLog "откат $curVer → $ToVersion" 'STEP'
    $v = Invoke-OpsTool $L $target @('sums-verify', '--dir', $target) -Quiet
    if ($v.Code -ne 0) { throw "файлы $target не совпадают с SHA256SUMS.txt — откат на неё невозможен" }
    Write-OpsLog "файлы $ToVersion совпадают с SHA256SUMS.txt" 'OK'
    $osApiEnv = Get-OpsOsApiEnvFiles $L
    if ($osApiEnv.Count -gt 0 -and -not (Test-OpsReleaseSupportsOsApi $target)) {
        Write-OpsLog ("в config\{0} стоит ONEC_MODE=os_api (1С через ОС_API, ADR-126), а версия {1} этого режима не знает — API и фоновые задачи с ним не стартуют; откат отклонён, службы не останавливались" -f ($osApiEnv -join ', config\'), $ToVersion) 'ERROR'
        Write-OpsLog 'сначала верните стенд на фикстуры: install.ps1 -Stand -StandOnecOsApi fixtures (с теми же параметрами, что при установке) или ONEC_MODE=fixtures в config\api.env и config\worker.env; затем rollback.ps1' 'ERROR'
        $result = 'refused'
        return
    }

    $db = Get-OpsDbState $L $curDir $PgPort $DbName
    $targetMigs = Get-OpsReleaseMigrations $target
    $unknown = @(@($db.migrations) | Where-Object { $targetMigs -notcontains $_ })
    $bossChanged = $false
    if ((Get-LuValue 'from') -eq $ToVersion -and (Get-LuValue 'to') -eq $curVer -and $null -ne (Get-LuValue 'pgbossBefore')) {
        $bossChanged = ([string]$db.pgboss -ne [string](Get-LuValue 'pgbossBefore'))
    }
    $newer = ($unknown.Count -gt 0) -or $bossChanged
    Write-OpsLog ("миграций, неизвестных {0}: {1}{2}; схема pg-boss изменена: {3}" -f $ToVersion, $unknown.Count, $(if ($unknown.Count) { ' (' + ($unknown -join ', ') + ')' } else { '' }), $bossChanged)
    if ($newer -and -not $CodeOnly -and -not $RestoreSnapshot) {
        $dump = Get-LuValue 'dump'
        Write-OpsLog 'база новее прежней версии — откат только программы отклонён' 'ERROR'
        Write-OpsLog ("варианты: (1) восстановление из дампа перед обновлением: {0}\backup\restore.ps1 -DumpFile {1} -KeyFile <backup-private.pem> (держатель ключа), затем rollback.ps1; (2) -CodeOnly — если миграции лишь расширяли схему (решает разработчик); (3) -RestoreSnapshot — если обновление делалось с -KeepSnapshot" -f $L.Current, $(if ($dump) { $dump } else { '<дамп из dumps\>' })) 'ERROR'
        $result = 'refused'
        return
    }
    if ($RestoreSnapshot) {
        $snap = Get-LuValue 'snapshot'
        if (-not $snap -or (Get-LuValue 'from') -ne $ToVersion) { throw "копии базы для отката на $ToVersion нет (update.ps1 -KeepSnapshot)" }
        Write-OpsLog "база вернётся к копии $snap (сделана перед обновлением $(Get-LuValue 'startedUtc')): все изменения данных после неё будут потеряны" 'WARN'
        if (-not $Force) {
            $ans = Read-Host 'Введите ОТКАТ для подтверждения'
            if ($ans -ne 'ОТКАТ') { throw 'не подтверждено' }
        }
    }
    if ($CodeOnly -and $newer) { Write-OpsLog '-CodeOnly: база остаётся новой; migrate прежней версии не запускается (он не знает новых миграций)' 'WARN' }

    Stop-OpsAppServices $L @('OptomstroyWorker', 'OptomstroyApi') -DevTest:$DevTest
    Set-OpsJunction $L.Current $target
    if ($RestoreSnapshot) {
        Stop-OpsAppServices $L @('OptomstroyBackup') -DevTest:$DevTest
        $failedName = '{0}_failed_{1}' -f $DbName, (Get-Date -Format 'yyyyMMddHHmmss')
        $sw = Invoke-OpsTool $L $target @('db', 'snapshot-swap', '--name', [string](Get-LuValue 'snapshot'), '--failed-name', $failedName, '--modules', (Join-Path $target 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        if ($sw.Code -ne 0) { throw "возврат копии базы: код $($sw.Code) — службы не запускаются" }
        Write-OpsLog "база возвращена из копии; прежняя сохранена как $failedName" 'OK'
        $code = Invoke-OpsScript (Join-Path $target 'postgres\apply-roles.ps1') @{ InstallRoot = $L.Root; Port = $PgPort; SkipArchiveCheck = $true }
        if ($code -ne 0) { throw "apply-roles.ps1: код $code" }
        $lu2 = ConvertTo-OpsHashtable $lu; $lu2.snapshot = $null; $state.lastUpdate = $lu2
    }
    if (-not ($CodeOnly -and $newer)) {
        $m = Invoke-OpsProcess -FilePath (Join-Path $L.Current 'node\node.exe') -ArgumentList @("--env-file=$(Join-Path $L.Config 'migrate.env')", 'dist\migrate.js', '--seed') -WorkingDirectory (Join-Path $target 'api') -CleanEnvironment -Environment @{ APP_ENV = $appEnv }
        if ($m.Code -ne 0) { throw "migrate версии $ToVersion`: код $($m.Code) — службы не запускались" }
    }
    Stop-OpsAppServices $L @('OptomstroyBackup') -DevTest:$DevTest
    Start-OpsAppServices $L @('OptomstroyBackup', 'OptomstroyApi', 'OptomstroyWorker') -DevTest:$DevTest
    $h = Wait-OpsApiHealthy $ApiPort $HealthTimeoutSec
    $w = Test-OpsWorkerAlive $L 15 -DevTest:$DevTest
    Write-OpsLog ("/health {0}; /health/ready {1} ({2}); фоновые задачи — {3}" -f $h.Health, $h.Ready, $h.ReadyStatus, $w.Reason)
    if (-not ($h.Ok -and $w.Ok)) { throw "версия $ToVersion запущена, но проверка не прошла" }
    $state.previousVersion = $curVer
    $state.currentVersion = $ToVersion
    $result = 'ok'
} catch {
    Write-OpsLog $_.Exception.Message 'ERROR'
} finally {
    if ($result -ne 'refused' -and -not $DropSnapshot) {
        $state.lastOperation = 'rollback'
        $state.lastOperationStatus = $result
        try { $state.currentVersion = [string](Get-OpsReleaseInfo (Get-OpsJunctionTarget $L.Current)).version } catch { }
        try { Save-OpsState $L $state; Add-OpsReleasesLog $L ("rollback {0} -> {1} {2}" -f $curVer, $ToVersion, $result) } catch { Write-OpsLog "состояние не записано: $($_.Exception.Message)" 'WARN' }
    }
    Write-OpsLog "итог: $result; журнал $script:OpsLogFile" $(if ($result -eq 'ok') { 'OK' } else { 'WARN' })
}
if ($result -eq 'ok') { exit 0 }
exit 1
