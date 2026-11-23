<#
.SYNOPSIS
  Репетиция режима службы OptomstroySvc.exe на настоящем диспетчере служб (SCM). Выполняет администратор,
  один раз, на сервере или его копии, до регистрации рабочих служб.

.DESCRIPTION
  Скрипт создаёт временную службу с тестовым именем (по умолчанию OptomstroySvcRehearsal) под виртуальной
  учётной записью NT SERVICE\<имя>, с той же схемой, что и рабочие службы, и проверяет по-настоящему:
    1. служба запускается, node.exe работает под NT SERVICE\<имя>, лимиты задания применены;
    2. Stop-Service -> закрытие stdin -> штатная остановка (Graceful), WIN32_EXIT_CODE 0;
    3. Stop-Process дочернего node.exe -> событие 7031/7034 в журнале System -> SCM перезапускает службу;
    4. ошибка файла настроек -> запуск не удался, WIN32_EXIT_CODE 1067, запись в журнале Application;
    5. значение PreshutdownTimeout записано (сам PRESHUTDOWN проверяется только при плановой перезагрузке:
       после неё в <WorkDir>\logs\<имя>.svc.log должна быть строка «выключение Windows (PRESHUTDOWN)»).
  В конце служба удаляется (sc.exe delete), папка <WorkDir> удаляется (если не указан -KeepWorkDir).
  Рабочие службы OptomstroyApi/Worker/Backup и порты 80/443 не затрагиваются. Hyper-V не нужен.

  -CheckAfterReboot: обязательная приёмка перед запуском в работу. Выполняется после одной плановой перезагрузки
  сервера с рабочими службами; ничего не создаёт и не меняет, только читает журналы <InstallRoot>\logs. Проверяет
  для OptomstroyApi/Worker/Backup: «выключение Windows (PRESHUTDOWN)», за ним «остановлено (Graceful)», и что все
  три остановились раньше, чем PostgreSQL записал «database system is shut down» (<InstallRoot>\logs\pg или -PgLogDir).

  -DevTest: без прав администратора и без SCM. Создаёт те же файлы, проверяет настройки и прогоняет класс
  службы через «OptomstroySvc.exe --service-test» (запуск, неожиданный выход -> код 4, ошибка настроек -> 1067).

.PARAMETER SvcExe
  OptomstroySvc.exe из релиза. По умолчанию — рядом со скриптом.

.PARAMETER Node
  node.exe из релиза (releases\<версия>\node\node.exe). По умолчанию — ..\node\node.exe относительно скрипта или node.exe из PATH.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Optomstroy\current\svchost\rehearse-service.ps1 -Node D:\Optomstroy\current\node\node.exe
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Optomstroy\current\svchost\rehearse-service.ps1 -CheckAfterReboot -InstallRoot D:\Optomstroy
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\svchost\rehearse-service.ps1 -DevTest -SvcExe .tmp\wn-svchost\bin\OptomstroySvc.exe
#>
[CmdletBinding()]
param(
  [string]$SvcExe,
  [string]$Node,
  [string]$WorkDir,
  [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')]
  [string]$ServiceName = 'OptomstroySvcRehearsal',
  [switch]$DevTest,
  [switch]$KeepWorkDir,
  [switch]$CheckAfterReboot,
  [string]$InstallRoot = 'D:\Optomstroy',
  [string]$PgLogDir
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:results = New-Object System.Collections.Generic.List[object]
function Assert-That([string]$name, [bool]$ok, [string]$detail = '') {
  $script:results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("  [{0}] {1}{2}" -f $tag, $name, $(if ($detail) { " — $detail" } else { '' }))
}
function Wait-Until([scriptblock]$cond, [int]$sec) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 250 }
  [bool](& $cond)
}
function Read-Text([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  # Файл открыт хостом на запись с FILE_SHARE_READ|WRITE — читаем с теми же правами
  $fs = New-Object System.IO.FileStream($path, 'Open', 'Read', 'ReadWrite, Delete')
  try { (New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding $false))).ReadToEnd() } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- -CheckAfterReboot: приёмка выключения Windows
# Выполняется после плановой перезагрузки сервера с рабочими службами. Ничего не меняет, только читает журналы.
# Для каждой службы ищет последнее «выключение Windows (PRESHUTDOWN)» до времени загрузки и следующее за ним
# «остановлено (Graceful)», затем сверяет: все три службы остановлены раньше, чем PostgreSQL записал
# «database system is shut down» (журнал PostgreSQL в UTC, lc_messages=C).
if ($CheckAfterReboot) {
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $boot = [DateTimeOffset](Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  if (-not $PgLogDir) { $PgLogDir = Join-Path $InstallRoot 'logs\pg' }
  Write-Host "== Приёмка выключения Windows: загрузка $($boot.ToString('yyyy-MM-dd HH:mm:ss zzz', $inv)), журналы $InstallRoot\logs"
  $svcStops = @{}
  foreach ($s in @(@{ N = 'OptomstroyApi'; D = 'api' }, @{ N = 'OptomstroyWorker'; D = 'worker' }, @{ N = 'OptomstroyBackup'; D = 'backup' })) {
    $dir = Join-Path $InstallRoot "logs\$($s.D)"
    $files = @(Get-ChildItem -LiteralPath $dir -Filter "$($s.N).svc*.log" -ErrorAction SilentlyContinue)
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
      foreach ($ln in ((Read-Text $f.FullName) -split "`r?`n")) {
        if ($ln.Length -lt 29) { continue }
        $t = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParseExact($ln.Substring(0, 29), "yyyy-MM-dd'T'HH:mm:ss.fffzzz", $inv, 'None', [ref]$t) -and $t -lt $boot) {
          $lines.Add([pscustomobject]@{ T = $t; L = $ln })
        }
      }
    }
    $sorted = @($lines | Sort-Object T)
    $pre = @($sorted | Where-Object { $_.L -match 'выключение Windows \(PRESHUTDOWN\)' } | Select-Object -Last 1)
    $shut = @($sorted | Where-Object { $_.L -match 'выключение Windows \(SHUTDOWN\)' } | Select-Object -Last 1)
    $preOk = $pre.Count -eq 1 -and -not ($shut.Count -eq 1 -and $shut[0].T -gt $pre[0].T)
    Assert-That "$($s.N): при выключении получен PRESHUTDOWN" $preOk $(if ($pre.Count) { $pre[0].L } elseif ($shut.Count) { 'только SHUTDOWN: ' + $shut[0].L } else { "нет записи в $dir" })
    if ($pre.Count -eq 1) {
      $done = @($sorted | Where-Object { $_.T -ge $pre[0].T -and $_.L -match 'остановлено \(' } | Select-Object -First 1)
      $ok = $done.Count -eq 1 -and $done[0].L -match 'остановлено \(Graceful\)'
      Assert-That "$($s.N): остановлено (Graceful) после PRESHUTDOWN" $ok $(if ($done.Count) { $done[0].L } else { 'нет строки «остановлено»' })
      if ($ok) { $svcStops[$s.N] = $done[0].T }
    }
  }
  # Журнал PostgreSQL: «2026-11-22 04:00:01.234 UTC [1234] LOG:  database system is shut down»
  $pgDown = $null
  foreach ($f in @(Get-ChildItem -LiteralPath $PgLogDir -Filter 'postgresql-*.log' -ErrorAction SilentlyContinue)) {
    foreach ($ln in ((Read-Text $f.FullName) -split "`r?`n")) {
      if ($ln -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) UTC .*database system is shut down') { continue }
      $t = [DateTimeOffset]::ParseExact($Matches[1] + ' +00:00', 'yyyy-MM-dd HH:mm:ss.fff zzz', $inv)
      if ($t -lt $boot -and ($null -eq $pgDown -or $t -gt $pgDown)) { $pgDown = $t }
    }
  }
  Assert-That 'PostgreSQL: «database system is shut down» перед загрузкой' ($null -ne $pgDown) $(if ($pgDown) { $pgDown.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff zzz', $inv) } else { "нет записи в $PgLogDir" })
  if ($null -ne $pgDown) {
    foreach ($n in @($svcStops.Keys | Sort-Object)) {
      Assert-That "$n остановлена раньше OptomstroyPostgres" ($svcStops[$n] -le $pgDown) ("{0} ≤ {1}" -f $svcStops[$n].ToLocalTime().ToString('HH:mm:ss.fff', $inv), $pgDown.ToLocalTime().ToString('HH:mm:ss.fff', $inv))
    }
  }
  $failed = @($script:results | Where-Object { -not $_.Ok })
  Write-Host ''
  Write-Host ("Итог приёмки выключения: {0} проверок, ошибок: {1}" -f $script:results.Count, $failed.Count)
  if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
}

# ---------------------------------------------------------------- проверки перед началом
# В Windows PowerShell 5.1 $PSScriptRoot в значении по умолчанию параметра пуст — вычисляем здесь
if (-not $SvcExe) { $SvcExe = Join-Path $PSScriptRoot 'OptomstroySvc.exe' }
if (-not (Test-Path -LiteralPath $SvcExe)) { throw "Не найден OptomstroySvc.exe: $SvcExe (укажите -SvcExe)" }
$SvcExe = (Resolve-Path -LiteralPath $SvcExe).Path
if (-not $Node) {
  $cand = Join-Path $PSScriptRoot '..\node\node.exe'
  if (Test-Path -LiteralPath $cand) { $Node = $cand } else { $Node = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
}
$Node = (Resolve-Path -LiteralPath $Node).Path
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DevTest -and -not $isAdmin) { throw 'Нужны права администратора (или параметр -DevTest для проверки без SCM).' }
if (-not $WorkDir) {
  if ($DevTest) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "OptomstroySvcRehearsal-$PID" }
  else { $WorkDir = Join-Path $env:ProgramData 'OptomstroySvcRehearsal' }
}
# В .svc.json нужны полные пути
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
if (-not $DevTest -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
  throw "Служба $ServiceName уже существует. Удалите её (sc.exe delete $ServiceName) или укажите другое -ServiceName."
}
if (Test-Path -LiteralPath $WorkDir) { throw "Папка $WorkDir уже существует — укажите пустую -WorkDir." }

Write-Host "== Подготовка папки $WorkDir"
$app = Join-Path $WorkDir 'app'
$logs = Join-Path $WorkDir 'logs'
$markers = Join-Path $WorkDir 'markers'
foreach ($d in $app, $logs, $markers) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
# Свои копии node.exe и OptomstroySvc.exe: права выдаются только на папку репетиции, релиз не трогается
Copy-Item -LiteralPath $SvcExe -Destination (Join-Path $app 'OptomstroySvc.exe')
Copy-Item -LiteralPath $Node -Destination (Join-Path $app 'node.exe')
$childJs = @'
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const dir = process.argv[2];
const log = (m) => process.stdout.write(new Date().toISOString() + ' ' + m + '\n');
writeFileSync(join(dir, 'ready-' + process.pid + '.txt'), String(process.pid));
log('репетиция: старт, PID ' + process.pid + ', TEST_VAR=' + (process.env.REHEARSAL_VAR ?? '-'));
const t = setInterval(() => log('работаю'), 2000);
process.stdin.on('data', () => {});
process.stdin.on('end', () => { log('stdin-eof: штатная остановка'); clearInterval(t); writeFileSync(join(dir, 'stdin-eof.txt'), 'ok'); setTimeout(() => process.exit(0), 200); });
'@
[System.IO.File]::WriteAllText((Join-Path $app 'child.mjs'), $childJs, (New-Object System.Text.UTF8Encoding $false))
$cfgPath = Join-Path $WorkDir "$ServiceName.svc.json"
$cfg = [ordered]@{
  _comment           = 'репетиция службы, создано rehearse-service.ps1'
  name               = $ServiceName
  executable         = (Join-Path $app 'node.exe')
  arguments          = @('--max-old-space-size=192', (Join-Path $app 'child.mjs'), $markers)
  workingDirectory   = $app
  environment        = [ordered]@{ REHEARSAL_VAR = 'ok' }
  inheritEnvironment = $false
  jobMemoryLimitMB   = 256
  cpuRatePercent     = 50
  logDirectory       = $logs
  logMaxBytes        = 1048576
  logKeepFiles       = 2
  stopTimeoutSeconds = 20
  shutdownViaStdin   = $true
}
[System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
$badCfgPath = Join-Path $WorkDir 'broken.svc.json'
[System.IO.File]::WriteAllText($badCfgPath, '{"name":"broken","unknownKey":1}', (New-Object System.Text.UTF8Encoding $false))
$hostExe = Join-Path $app 'OptomstroySvc.exe'
$svcLog = Join-Path $logs "$ServiceName.svc.log"

& $hostExe --check-config --config $cfgPath | Out-Host
Assert-That 'файл настроек репетиции проходит --check-config' ($LASTEXITCODE -eq 0)

function Get-ChildPidFromLog {
  $m = [regex]::Matches((Read-Text $svcLog), 'процесс запущен, PID (\d+)')
  if ($m.Count -eq 0) { return 0 }
  [int]$m[$m.Count - 1].Groups[1].Value
}

if ($DevTest) {
  # ---------------------------------------------------------------- без SCM
  Write-Host '== -DevTest: класс службы через --service-test (без SCM)'
  $p = Start-Process -FilePath $hostExe -ArgumentList @('--service-test', 'stop', '--config', ('"{0}"' -f $cfgPath)) -WindowStyle Hidden -PassThru
  $null = $p.Handle
  $childPid = 0
  $up = Wait-Until { $script:childPid = Get-ChildPidFromLog; $script:childPid -gt 0 -and (Test-Path -LiteralPath (Join-Path $markers "ready-$($script:childPid).txt")) } 20
  Assert-That 'OnStart запустил node.exe' $up "PID $childPid"
  if ($up) { Stop-Process -Id $childPid -Force }
  $exited = $p.WaitForExit(20000)
  Assert-That 'неожиданный выход node.exe -> хост завершился с кодом 4' ($exited -and $p.ExitCode -eq 4) $(if ($exited) { "код $($p.ExitCode)" } else { 'не завершился' })
  if (-not $exited) { try { $p.Kill() } catch { } }
  Assert-That 'журнал хоста: «SCM применит действия восстановления»' ((Read-Text $svcLog) -match 'SCM применит действия восстановления')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $hostExe
  $psi.Arguments = '--service-test stop --config "' + $badCfgPath + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardError = $true
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $pr = [System.Diagnostics.Process]::Start($psi)
  $err = $pr.StandardError.ReadToEnd(); $pr.WaitForExit()
  Assert-That 'ошибка настроек -> ExitCode 1067 для SCM' ($pr.ExitCode -eq 2 -and $err -match 'ExitCode для SCM 1067') "код $($pr.ExitCode)"
}
else {
  # ---------------------------------------------------------------- настоящий SCM (администратор)
  $acct = "NT SERVICE\$ServiceName"
  $t0 = Get-Date
  try {
    Write-Host "== Регистрация временной службы $ServiceName"
    $bin = '\"' + $hostExe + '\" --config \"' + $cfgPath + '\"'
    sc.exe create $ServiceName binPath= $bin start= demand obj= $acct DisplayName= "Optomstroy POS репетиция службы" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "sc create: код $LASTEXITCODE" }
    sc.exe sidtype $ServiceName unrestricted | Out-Null
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    sc.exe failureflag $ServiceName 1 | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name PreshutdownTimeout -Value 60000 -Type DWord
    # Права NTFS для виртуальной учётной записи — после sc create
    icacls $app /grant "${acct}:(OI)(CI)RX" | Out-Null
    icacls $logs /grant "${acct}:(OI)(CI)M" | Out-Null
    icacls $markers /grant "${acct}:(OI)(CI)M" | Out-Null
    icacls $WorkDir /grant "${acct}:RX" | Out-Null
    icacls $cfgPath /grant "${acct}:R" | Out-Null
    icacls $badCfgPath /grant "${acct}:R" | Out-Null
    Assert-That 'PreshutdownTimeout = 60000 мс записан' ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName").PreshutdownTimeout -eq 60000)

    Write-Host '== 1. Запуск'
    Start-Service -Name $ServiceName
    $running = Wait-Until { (Get-Service $ServiceName).Status -eq 'Running' } 30
    $childPid = 0
    $up = Wait-Until { $script:childPid = Get-ChildPidFromLog; $script:childPid -gt 0 -and (Test-Path -LiteralPath (Join-Path $markers "ready-$($script:childPid).txt")) } 30
    Assert-That 'служба Running, node.exe запущен' ($running -and $up) "PID $childPid"
    $owner = ''
    if ($up) { $o = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId=$childPid") -MethodName GetOwner; $owner = "$($o.Domain)\$($o.User)" }
    Assert-That "node.exe работает под $acct" ($owner -eq $acct) $owner
    $svcText = Read-Text $svcLog
    Assert-That 'журнал хоста: режим службы, лимиты применены, PRESHUTDOWN включён' ($svcText -match '\(служба\)' -and $svcText -match 'jobMemoryLimitMB=256' -and $svcText -notmatch 'PRESHUTDOWN недоступен')

    Write-Host '== 2. Штатная остановка'
    Stop-Service -Name $ServiceName
    $stoppedOk = Wait-Until { (Get-Service $ServiceName).Status -eq 'Stopped' } 40
    $q = (sc.exe query $ServiceName) -join "`n"
    Assert-That 'Stop-Service -> Stopped, WIN32_EXIT_CODE 0' ($stoppedOk -and $q -match 'WIN32_EXIT_CODE\s+:\s+0\s') ($q -replace '\s+', ' ')
    Assert-That 'журнал хоста: остановлено (Graceful), node.exe получил EOF stdin' ((Read-Text $svcLog) -match 'остановлено \(Graceful\)' -and (Test-Path -LiteralPath (Join-Path $markers 'stdin-eof.txt')))

    Write-Host '== 3. Сбой процесса и перезапуск SCM'
    Start-Service -Name $ServiceName
    $up = Wait-Until { $script:childPid = Get-ChildPidFromLog; $script:childPid -gt 0 -and (Test-Path -LiteralPath (Join-Path $markers "ready-$($script:childPid).txt")) } 30
    $first = $childPid
    $tCrash = Get-Date
    if ($up) { Stop-Process -Id $first -Force }
    $restarted = Wait-Until { $script:childPid = Get-ChildPidFromLog; $script:childPid -ne $first -and $script:childPid -gt 0 -and (Get-Service $ServiceName).Status -eq 'Running' } 60
    Assert-That 'после Stop-Process node.exe служба перезапущена SCM' $restarted "было PID $first, стало PID $childPid"
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $tCrash } -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'репетиция' -or $_.Message -match $ServiceName })
    Assert-That 'событие 7031/7034 в журнале System' ($ev.Count -gt 0) $(if ($ev.Count) { "Id $($ev[0].Id)" } else { 'нет' })
    Stop-Service -Name $ServiceName
    $null = Wait-Until { (Get-Service $ServiceName).Status -eq 'Stopped' } 40

    Write-Host '== 4. Ошибка файла настроек'
    sc.exe failure $ServiceName reset= 86400 actions= restart/600000 | Out-Null   # перезапуск не раньше чем через 10 мин — не мешает проверке
    $bad = '\"' + $hostExe + '\" --config \"' + $badCfgPath + '\"'
    sc.exe config $ServiceName binPath= $bad | Out-Null
    $tBad = Get-Date
    try { Start-Service -Name $ServiceName } catch { }
    $null = Wait-Until { (Get-Service $ServiceName).Status -eq 'Stopped' } 20
    $q = (sc.exe query $ServiceName) -join "`n"
    Assert-That 'ошибка настроек -> WIN32_EXIT_CODE 1067' ($q -match 'WIN32_EXIT_CODE\s+:\s+1067') ($q -replace '\s+', ' ')
    $app1 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'OptomstroySvc'; StartTime = $tBad } -ErrorAction SilentlyContinue)
    Assert-That 'журнал Application: одна запись «ошибка файла настроек», без «внутренней ошибки»' (@($app1 | Where-Object { $_.Message -match 'ошибка файла настроек' }).Count -ge 1 -and @($app1 | Where-Object { $_.Message -match 'внутренняя ошибка' }).Count -eq 0) "записей: $($app1.Count)"
  }
  finally {
    Write-Host "== Удаление временной службы $ServiceName"
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
      Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
      sc.exe delete $ServiceName | Out-Host
    }
  }
}

$failed = @($script:results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("Итог репетиции: {0} проверок, ошибок: {1}. Журналы: {2}" -f $script:results.Count, $failed.Count, $logs)
if (-not $KeepWorkDir) {
  Start-Sleep -Seconds 1
  Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
