<#
.SYNOPSIS
  Состояние сервера Optomstroy POS: службы, версии, готовность API, резервные копии, диск. Только чтение.

.DESCRIPTION
  Запускается без прав администратора, в том числе под posdeploy: читает только то, что posdeploy доступно
  (logs\deploy-state.json, журналы logs\*, состояние служб, http://127.0.0.1:<порт>/health). Секреты не читает.
  Сам скрипт posdeploy запускает из current\scripts (install.ps1 выдаёт posdeploy чтение releases\).
  Под администратором дополнительно показывает итог pos-backup.mjs status (без подключения к базе).
  Код выхода: 0 — всё в порядке; 1 — есть проблемы (список в конце); 2 — установка не найдена.
  -Json — вывод одной строкой JSON (для мониторинга).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Optomstroy\current\scripts\status.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
# -Json: stdout — только одна строка JSON (служебные строки «запуск: …» не печатаются).
if ($Json) { $script:OpsLogQuiet = $true }

$L = Get-OpsLayout $InstallRoot
$problems = New-Object System.Collections.ArrayList
$report = [ordered]@{ checkedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); installRoot = $L.Root }

$ds = $null
try { $ds = Read-OpsJson $L.PublicStateFile } catch { $ds = $null }
if ($null -eq $ds) {
    if ($Json) { Write-Output (@{ ok = $false; problems = @("нет $($L.PublicStateFile)") } | ConvertTo-Json -Compress) } else { Write-Host "нет $($L.PublicStateFile) (установки нет или нет прав на logs)" }
    exit 2
}
$apiPort = 3000; $pgPort = 5433
if ($ds.PSObject.Properties['apiPort'] -and $ds.apiPort) { $apiPort = [int]$ds.apiPort }
if ($ds.PSObject.Properties['pgPort'] -and $ds.pgPort) { $pgPort = [int]$ds.pgPort }
$devTest = [bool]$ds.devTest
$report.version = [ordered]@{ current = $ds.currentVersion; previous = $ds.previousVersion; installedUtc = $ds.installedUtc; updatedUtc = $ds.updatedUtc; lastOperation = $ds.lastOperation; lastOperationStatus = $ds.lastOperationStatus }
if ([string]$ds.lastOperationStatus -ne 'ok') { [void]$problems.Add("последняя операция $($ds.lastOperation): $($ds.lastOperationStatus)") }

# Службы
$svc = [ordered]@{}
foreach ($n in @($script:OpsPgServiceName) + $script:OpsServiceNames) {
    if ($devTest) {
        $st = 'n/a (DevTest)'
        if ($n -ne $script:OpsPgServiceName) { try { $st = Get-OpsAppServiceState $L $n -DevTest } catch { $st = 'нет доступа' } }
    } else {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($null -eq $s) { $st = 'Missing' } else { $st = "$($s.Status)" }
    }
    $svc[$n] = $st
    if ($st -ne 'Running' -and $st -ne 'n/a (DevTest)') { [void]$problems.Add("служба $n`: $st") }
}
$report.services = $svc

# Порты и готовность
$apiListen = @(Get-OpsListenAddresses $apiPort)
$pgListen = @(Get-OpsListenAddresses $pgPort)
$report.listen = [ordered]@{ api = $apiListen; postgres = $pgListen }
foreach ($a in @($apiListen + $pgListen)) { if ($a -ne '127.0.0.1') { [void]$problems.Add("порт слушает не только 127.0.0.1: $a") } }
if ($pgListen.Count -eq 0) { [void]$problems.Add("PostgreSQL не слушает $pgPort") }
$h = Get-OpsHttp "http://127.0.0.1:$apiPort/health" 3000
$r = Get-OpsHttp "http://127.0.0.1:$apiPort/health/ready" 5000
$readyStatus = ''
try { $readyStatus = [string](($r.Body | ConvertFrom-Json).status) } catch { }
$report.health = [ordered]@{ health = $h.Code; ready = $r.Code; readyStatus = $readyStatus }
if ($h.Code -ne 200) { [void]$problems.Add("/health: $($h.Code)") }
if ($r.Code -ne 200) { [void]$problems.Add("/health/ready: $($r.Code) $readyStatus") }

# Журналы служб: последние ошибки (pino: "level":50 и выше; хост: [ERROR])
$logs = [ordered]@{}
foreach ($p in @(@('api', 'OptomstroyApi'), @('worker', 'OptomstroyWorker'), @('backup', 'OptomstroyBackup'))) {
    $entry = [ordered]@{ lastWriteUtc = $null; lastError = $null }
    foreach ($f in @("$($p[1]).out.log", "$($p[1]).svc.log", "$($p[1]).err.log")) {
        $fp = Join-Path $L.Logs "$($p[0])\$f"
        if (-not (Test-Path -LiteralPath $fp)) { continue }
        try {
            $fi = Get-Item -LiteralPath $fp
            if ($null -eq $entry.lastWriteUtc -or $fi.LastWriteTimeUtc -gt [datetime]$entry.lastWriteUtc) { $entry.lastWriteUtc = $fi.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
            $err = Get-Content -LiteralPath $fp -Tail 300 -Encoding UTF8 | Where-Object { $_ -match '"level":(50|60)|"level":"(error|fatal)"|\[ERROR\]|ОШИБКА' } | Select-Object -Last 1
            if ($err) { $entry.lastError = ($err.Substring(0, [math]::Min(300, $err.Length))) }
        } catch { }
    }
    $logs[$p[1]] = $entry
}
$report.logs = $logs

# Резервные копии: под администратором — pos-backup status (без базы); иначе только журнал службы.
$bk = [ordered]@{ source = 'logs'; ok = $null; problems = @() }
$bkCfg = Join-Path $L.Config 'backup.json'
$canRead = $false
try { $null = [System.IO.File]::ReadAllText($bkCfg); $canRead = $true } catch { $canRead = $false }
if ($canRead) {
    try {
        $node = Join-Path $L.Current 'node\node.exe'
        $res = Invoke-OpsProcess -FilePath $node -ArgumentList @((Join-Path $L.Current 'backup\pos-backup.mjs'), 'status', '--config', $bkCfg, '--no-db') -CleanEnvironment -QuietStdout -TimeoutSec 120
        $sj = $null
        try { $sj = (($res.Out -join "`n") | ConvertFrom-Json) } catch { $sj = ConvertFrom-OpsJsonLine $res.Out }
        $bk.source = 'pos-backup status --no-db'
        $bk.ok = ($res.Code -eq 0)
        if ($null -ne $sj -and $sj.PSObject.Properties['problems']) { $bk.problems = @($sj.problems) }
        if ($null -ne $sj -and $sj.PSObject.Properties['lastDump']) { $bk.lastDump = $sj.lastDump }
    } catch { $bk.ok = $false; $bk.problems = @("status не выполнен: $($_.Exception.Message)") }
} else {
    $fp = Join-Path $L.Logs 'backup\OptomstroyBackup.out.log'
    if (Test-Path -LiteralPath $fp) {
        $tail = Get-Content -LiteralPath $fp -Tail 500 -Encoding UTF8
        $bk.lastDumpLine = ($tail | Where-Object { $_ -match 'dump' -and $_ -match '"level":"info"' } | Select-Object -Last 1)
        $bk.lastErrorLine = ($tail | Where-Object { $_ -match '"level":"error"' } | Select-Object -Last 1)
        $bk.ok = (-not $bk.lastErrorLine)
    }
}
$report.backup = $bk
if ($bk.ok -eq $false) { [void]$problems.Add('резервное копирование: ' + ((@($bk.problems) + @($bk['lastErrorLine'])) -join '; ')) }

# Диск
$disks = @()
$roots = @([System.IO.Path]::GetPathRoot($L.Root))
if ($ds.PSObject.Properties['backupRoot'] -and $ds.backupRoot) { $roots += [System.IO.Path]::GetPathRoot([string]$ds.backupRoot) }
foreach ($q in ($roots | Sort-Object -Unique)) {
    $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $q.TrimEnd('\'))
    if ($null -eq $d) { continue }
    $used = [math]::Round(100 * (1 - $d.FreeSpace / $d.Size))
    $disks += [ordered]@{ volume = $q; freeGB = [math]::Round($d.FreeSpace / 1GB, 1); sizeGB = [math]::Round($d.Size / 1GB, 1); usedPercent = $used }
    if ($used -gt 70) { [void]$problems.Add("том $q занят на $used % (порог 70 %)") }
}
$report.disks = $disks
$report.ok = ($problems.Count -eq 0)
$report.problems = @($problems)

if ($Json) {
    Write-Output ($report | ConvertTo-Json -Depth 6 -Compress)
} else {
    Write-Host "Optomstroy POS — состояние ($($report.checkedUtc))" -ForegroundColor Cyan
    Write-Host ("  версия: {0} (прежняя: {1}); последняя операция: {2} — {3}" -f $ds.currentVersion, $ds.previousVersion, $ds.lastOperation, $ds.lastOperationStatus)
    foreach ($k in $svc.Keys) { Write-Host ("  служба {0,-20} {1}" -f $k, $svc[$k]) }
    Write-Host ("  API 127.0.0.1:{0}: /health {1}, /health/ready {2} {3}; слушает: {4}" -f $apiPort, $h.Code, $r.Code, $readyStatus, ($apiListen -join ', '))
    Write-Host ("  PostgreSQL 127.0.0.1:{0}: слушает: {1}" -f $pgPort, ($pgListen -join ', '))
    Write-Host ("  резервные копии ({0}): {1}" -f $bk.source, $(if ($bk.ok -eq $true) { 'норма' } elseif ($bk.ok -eq $false) { 'ПРОБЛЕМЫ' } else { 'нет данных' }))
    foreach ($d in $disks) { Write-Host ("  том {0} свободно {1} ГБ из {2} ГБ (занято {3} %)" -f $d.volume, $d.freeGB, $d.sizeGB, $d.usedPercent) }
    if ($problems.Count -eq 0) { Write-Host '  итог: норма' -ForegroundColor Green }
    else { Write-Host '  итог: есть проблемы' -ForegroundColor Yellow; foreach ($p in $problems) { Write-Host "   - $p" -ForegroundColor Yellow } }
}
if ($problems.Count -eq 0) { exit 0 }
exit 1
