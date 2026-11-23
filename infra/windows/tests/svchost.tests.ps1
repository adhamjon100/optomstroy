<#
.SYNOPSIS
  Проверки хоста служб OptomstroySvc.exe в режиме --console (без прав администратора).

.DESCRIPTION
  Собирает OptomstroySvc.exe (build-svchost.ps1), запускает его с тестовыми настройками, в которых дочерний
  процесс — node.exe с test-fixtures\child.mjs, и проверяет по-настоящему:
    * --version, --check-config, ошибки аргументов и файла настроек (код 2);
    * аргументы с пробелами и кавычками, переменные окружения (задать и удалить), рабочую папку;
    * Ctrl+C -> закрытие stdin -> штатный выход дочернего процесса (код 0) в пределах stopTimeoutSeconds;
    * процесс, игнорирующий stdin, завершается вместе с «внуком» после stopTimeoutSeconds (код 5);
    * повторный Ctrl+C — немедленное принудительное завершение;
    * shutdownViaStdin=false — сразу завершение дерева процессов;
    * «внук», переживший штатный выход дочернего процесса, тоже завершается;
    * неожиданный выход дочернего процесса — ненулевой код хоста (4);
    * если хост убит (Stop-Process -Force), задание с KILL_ON_JOB_CLOSE завершает дочерний процесс и «внука»;
    * ротацию журналов по размеру на границе строк, UTF-8 и непрерывность строк;
    * ошибку запуска (не исполняемый файл) — код 3;
    * класс службы без SCM (--service-test): OnStart, OnStop, OnShutdown, PRESHUTDOWN, неожиданный выход (4),
      ошибка журнала и файла настроек в OnStart -> ExitCode 1067 для SCM, без ложной «внутренней ошибки»;
    * jobMemoryLimitMB (процесс упирается в лимит -> код 4 и пометка в журнале), cpuRatePercent (жёсткий потолок ЦП);
    * inheritEnvironment=false и предупреждение о переменной Windows, перекрывающей --env-file;
    * отказ открыть журнал после ротации: вывод теряется, открытие повторяется, журнал снова пишется.
  Регистрация службы Windows (sc.exe) требует прав администратора и здесь не выполняется
  (см. infra\windows\svchost\rehearse-service.ps1 — репетиция для администратора).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\svchost.tests.ps1
#>
[CmdletBinding()]
param(
  [string]$WorkDir,
  [string]$Node,
  [switch]$Keep,
  # Дополнительно запустить настоящий pos-api\dist\main.js (нужна готовая сборка pos-api, база не нужна)
  [switch]$RealApi
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$svcDir = Join-Path $repo 'infra\windows\svchost'
if (-not $WorkDir) { $WorkDir = Join-Path $repo '.tmp\wn-svchost\test' }
if (-not $Node) { $Node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source }
if (-not (Test-Path -LiteralPath $Node)) { throw "Не найден node.exe: $Node" }

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

$script:results = New-Object System.Collections.Generic.List[object]
function Assert-That([string]$name, [bool]$ok, [string]$detail = '') {
  $script:results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("  [{0}] {1}{2}" -f $tag, $name, $(if ($detail) { " — $detail" } else { '' }))
}

# ---------------------------------------------------------------- сборка
Write-Host "== Сборка"
$bin = Join-Path $WorkDir 'bin'
$build = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $svcDir 'build-svchost.ps1') -OutDir $bin
$build | Where-Object { $_ -is [string] } | ForEach-Object { Write-Host "  $_" }
$exe = Join-Path $bin 'OptomstroySvc.exe'
Assert-That 'сборка OptomstroySvc.exe' (Test-Path -LiteralPath $exe)
$bin2 = Join-Path $WorkDir 'bin2'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $svcDir 'build-svchost.ps1') -OutDir $bin2 | Out-Null
$h1 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath (Join-Path $bin2 'OptomstroySvc.exe') -Algorithm SHA256).Hash
Assert-That 'повторная сборка даёт тот же SHA256' ($h1 -eq $h2) "$h1 / $h2"

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$ctrlc = Join-Path $bin 'SendCtrlC.exe'
& $csc /nologo /codepage:65001 /target:exe "/out:$ctrlc" (Join-Path $svcDir 'test-fixtures\SendCtrlC.cs') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Не удалось собрать SendCtrlC.exe' }
$child = Join-Path $svcDir 'test-fixtures\child.mjs'

# ---------------------------------------------------------------- помощники
function New-Case([string]$name, [string]$mode, [hashtable]$over = @{}, [string[]]$extraArgs = @()) {
  $dir = Join-Path $WorkDir ("case $name")      # пробел в пути — проверка кавычек
  $markers = Join-Path $dir 'markers'
  $logs = Join-Path $dir 'logs'
  New-Item -ItemType Directory -Force -Path $markers | Out-Null
  $cfg = [ordered]@{
    _comment           = 'тестовые настройки svchost.tests.ps1'
    name               = "Test$($name -replace '[^A-Za-z0-9]', '')"
    executable         = $Node
    arguments          = @($child, $mode, $markers) + $extraArgs
    workingDirectory   = $dir
    environment        = [ordered]@{ SVC_TEST_VAR = 'значение 1'; SVC_TEST_REMOVE = $null }
    logDirectory       = $logs
    logMaxBytes        = 1048576
    logKeepFiles       = 3
    stopTimeoutSeconds = 10
    shutdownViaStdin   = $true
  }
  foreach ($k in $over.Keys) { $cfg[$k] = $over[$k] }
  $path = Join-Path $dir 'test.svc.json'
  [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))
  [pscustomobject]@{ Dir = $dir; Markers = $markers; Logs = $logs; Config = $path; Name = $cfg.name }
}

function Start-SvcHost($case, [string[]]$modeArgs = @('--console')) {
  # Отдельная скрытая консоль: в неё SendCtrlC.exe посылает Ctrl+C, не задевая сам тест.
  $p = Start-Process -FilePath $exe -ArgumentList ($modeArgs + @('--config', ('"{0}"' -f $case.Config))) -WindowStyle Hidden -PassThru
  $null = $p.Handle   # чтобы ExitCode был доступен после выхода
  $p
}

function Wait-File([string]$path, [int]$sec = 15) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) {
    if (Test-Path -LiteralPath $path) { Start-Sleep -Milliseconds 100; return $true }
    Start-Sleep -Milliseconds 100
  }
  $false
}

function Send-CtrlC([int]$hostPid, [string]$kind = '') {
  $a = @("$hostPid"); if ($kind) { $a += $kind }
  $p = Start-Process -FilePath $ctrlc -ArgumentList $a -WindowStyle Hidden -PassThru -Wait
  $p.ExitCode
}

function Wait-Exit($p, [int]$sec) {
  if (-not $p.WaitForExit($sec * 1000)) { try { $p.Kill() } catch { }; return $null }
  $p.ExitCode
}

function Test-Alive([int]$id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }

function Wait-Dead([int]$id, [int]$sec = 5) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) { if (-not (Test-Alive $id)) { return $true }; Start-Sleep -Milliseconds 100 }
  -not (Test-Alive $id)
}

function Read-Utf8([string]$path) { [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding $false, $true)) }
function Read-Ready($case) { Read-Utf8 (Join-Path $case.Markers 'ready.json') | ConvertFrom-Json }
function Get-SvcLog($case) { Read-Utf8 (Join-Path $case.Logs ($case.Name + '.svc.log')) }

function Invoke-Exe([string[]]$a) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($a | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $pr = [System.Diagnostics.Process]::Start($psi)
  $o = $pr.StandardOutput.ReadToEndAsync(); $e = $pr.StandardError.ReadToEnd()
  $pr.WaitForExit()
  [pscustomobject]@{ Code = $pr.ExitCode; Out = $o.Result; Err = $e }
}

# ---------------------------------------------------------------- 1. аргументы и настройки
Write-Host "== Аргументы и файл настроек"
$r = Invoke-Exe @('--version')
Assert-That '--version' ($r.Code -eq 0 -and $r.Out.Trim() -match '^OptomstroySvc \d+\.\d+\.\d+$') $r.Out.Trim()
$r = Invoke-Exe @()
Assert-That 'без аргументов -> код 2' ($r.Code -eq 2) ("код $($r.Code)")
$r = Invoke-Exe @('--bogus')
Assert-That 'неизвестный аргумент -> код 2' ($r.Code -eq 2 -and $r.Err -match 'неизвестный') ("код $($r.Code)")

$ok = New-Case 'cfg' 'graceful'
$r = Invoke-Exe @('--check-config', '--config', $ok.Config)
Assert-That '--check-config: верный файл -> 0' ($r.Code -eq 0) $r.Out.Trim()

$bad = Join-Path $WorkDir 'bad1.svc.json'
[System.IO.File]::WriteAllText($bad, '{"name":"X","executable":"' + ($Node -replace '\\', '\\') + '","arguments":[],"workingDirectory":"C:\\","logDirectory":"C:\\x","logMaxBytes":2048,"logKeepFiles":2,"stopTimeoutSecond":5,"shutdownViaStdin":"yes"}')
$r = Invoke-Exe @('--check-config', '--config', $bad)
Assert-That 'опечатка в ключе и неверный тип -> код 2 с понятным текстом' ($r.Code -eq 2 -and $r.Err -match 'неизвестный ключ "stopTimeoutSecond"' -and $r.Err -match 'нет обязательного ключа "stopTimeoutSeconds"' -and $r.Err -match 'shutdownViaStdin') $r.Err.Trim()

$bad2 = Join-Path $WorkDir 'bad2.svc.json'
[System.IO.File]::WriteAllText($bad2, "{`n  `"name`": `"A`",`n  `"name`": `"B`"`n}")
$r = Invoke-Exe @('--check-config', '--config', $bad2)
Assert-That 'повтор ключа -> код 2 с номером строки' ($r.Code -eq 2 -and $r.Err -match 'повторяется' -and $r.Err -match 'строка 3') $r.Err.Trim()

$bad3 = Join-Path $WorkDir 'bad3.svc.json'
$j = Get-Content -LiteralPath $ok.Config -Raw -Encoding UTF8 | ConvertFrom-Json
$j.workingDirectory = 'relative\dir'; $j.logMaxBytes = 10; $j.arguments = @('a', 5)
[System.IO.File]::WriteAllText($bad3, ($j | ConvertTo-Json -Depth 5))
$r = Invoke-Exe @('--check-config', '--config', $bad3)
Assert-That 'относительный путь, малый logMaxBytes, не строка в arguments -> код 2' ($r.Code -eq 2 -and $r.Err -match 'полным путём' -and $r.Err -match 'logMaxBytes' -and $r.Err -match 'arguments"\[1\]') $r.Err.Trim()

$r = Invoke-Exe @('--config', $ok.Config)
Assert-That 'режим службы вне SCM -> код 2 с подсказкой' ($r.Code -eq 2 -and $r.Err -match '--console') ("код $($r.Code)")

# ---------------------------------------------------------------- 2. штатная остановка через stdin
Write-Host "== Ctrl+C -> закрытие stdin -> штатный выход"
$env:SVC_TEST_REMOVE = 'унаследовано'   # хост должен удалить её (значение null в environment)
$env:SVC_TEST_INHERIT = 'из Windows'    # по умолчанию (inheritEnvironment не задан) наследуется
$c = New-Case 'graceful' 'graceful' @{} @('арг с пробелом', 'кавычка"внутри', 'C:\путь с пробелом\', '')
$p = Start-SvcHost $c
$ready = Wait-File (Join-Path $c.Markers 'ready.json')
Assert-That 'дочерний процесс запущен' $ready
$info = Read-Ready $c
$expectArgs = @('graceful', $c.Markers, 'арг с пробелом', 'кавычка"внутри', 'C:\путь с пробелом\', '')
Assert-That 'аргументы переданы без искажений' ((($info.argv | ForEach-Object { "[$_]" }) -join '') -eq (($expectArgs | ForEach-Object { "[$_]" }) -join '')) (($info.argv | ForEach-Object { "[$_]" }) -join '')
Assert-That 'переменная окружения из настроек' ($info.envSet -eq 'значение 1') "$($info.envSet)"
Assert-That 'переменная со значением null удалена' ($null -eq $info.envRemoved) "$($info.envRemoved)"
Assert-That 'рабочая папка' ($info.cwd -eq $c.Dir) $info.cwd
Assert-That 'по умолчанию окружение Windows наследуется' ($info.envInherited -eq 'из Windows') "$($info.envInherited)"
Start-Sleep -Milliseconds 700
$sw = [Diagnostics.Stopwatch]::StartNew()
$sc = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
$el = $sw.Elapsed.TotalSeconds
Assert-That 'Ctrl+C доставлен' ($sc -eq 0) "SendCtrlC код $sc"
Assert-That 'код хоста 0' ($code -eq 0) "код $code, $([math]::Round($el,2)) с"
Assert-That 'остановка быстрее stopTimeoutSeconds (10 с)' ($el -lt 10) "$([math]::Round($el,2)) с"
Assert-That 'дочерний процесс получил EOF stdin' (Test-Path -LiteralPath (Join-Path $c.Markers 'stdin-eof.txt'))
Assert-That 'дочерний процесс завершён' (Wait-Dead $info.pid)
$svc = Get-SvcLog $c
Assert-That 'журнал хоста: закрытие stdin и код 0' ($svc -match 'stdin дочернего процесса закрыт' -and $svc -match 'завершился с кодом 0' -and $svc -match 'Graceful')
$out = Read-Utf8 (Join-Path $c.Logs ($c.Name + '.out.log'))
$err = Read-Utf8 (Join-Path $c.Logs ($c.Name + '.err.log'))
Assert-That 'stdout в .out.log (UTF-8)' ($out -match 'stdin-eof: штатная остановка')
Assert-That 'stderr в .err.log (UTF-8)' ($err -match 'stderr: Проверка вывода ошибок')
Assert-That 'журнал хоста не пишет значения переменных' ($svc -notmatch 'значение 1' -and $svc -match 'SVC_TEST_VAR')

# повторный запуск дописывает журнал, а не затирает
Remove-Item -LiteralPath (Join-Path $c.Markers 'ready.json')
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
Start-Sleep -Milliseconds 300
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
$out = Read-Utf8 (Join-Path $c.Logs ($c.Name + '.out.log'))
Assert-That 'повторный запуск дописывает журнал' ($code -eq 0 -and ([regex]::Matches($out, 'старт graceful')).Count -eq 2) "код $code"
Remove-Item Env:\SVC_TEST_REMOVE

# ---------------------------------------------------------------- 3. «внук» после штатного выхода
Write-Host "== Оставшийся «внук» после штатного выхода"
$c = New-Case 'orphan' 'graceful-orphan'
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
Assert-That '«внук» запущен' (Test-Alive $info.grandchild) "PID $($info.grandchild)"
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
Assert-That 'код хоста 0' ($code -eq 0) "код $code"
Assert-That '«внук» завершён хостом' (Wait-Dead $info.grandchild)
Assert-That 'журнал: остались процессы, завершены' ((Get-SvcLog $c) -match 'в задании остались процессы \(1\)')

# ---------------------------------------------------------------- 4. ненулевой код при остановке
Write-Host "== Ненулевой код при штатной остановке"
$c = New-Case 'eofnz' 'eof-nonzero'
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
Assert-That 'код хоста 6' ($code -eq 6) "код $code"

# ---------------------------------------------------------------- 5. процесс игнорирует stdin
Write-Host "== Процесс игнорирует stdin: завершение дерева после тайм-аута"
$c = New-Case 'ignore' 'ignore-stdin' @{ stopTimeoutSeconds = 3 }
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
Assert-That 'дочерний процесс и «внук» запущены' ((Test-Alive $info.pid) -and (Test-Alive $info.grandchild)) "PID $($info.pid), внук $($info.grandchild)"
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 40
$el = $sw.Elapsed.TotalSeconds
Assert-That 'код хоста 5 (принудительно)' ($code -eq 5) "код $code"
Assert-That 'ожидание не меньше stopTimeoutSeconds и без лишней задержки' ($el -ge 2.8 -and $el -lt 12) "$([math]::Round($el,2)) с"
Assert-That 'дочерний процесс завершён' (Wait-Dead $info.pid)
Assert-That '«внук» (detached) завершён' (Wait-Dead $info.grandchild)
Assert-That 'журнал: не завершился за 3 с' ((Get-SvcLog $c) -match 'не завершился за 3 с')

# ---------------------------------------------------------------- 6. повторный Ctrl+C
Write-Host "== Повторный Ctrl+C"
$c = New-Case 'double' 'ignore-stdin' @{ stopTimeoutSeconds = 120 }
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = Send-CtrlC $p.Id
Start-Sleep -Milliseconds 800
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
$el = $sw.Elapsed.TotalSeconds
Assert-That 'второй Ctrl+C завершает сразу (код 5)' ($code -eq 5 -and $el -lt 10) "код $code, $([math]::Round($el,2)) с"
Assert-That 'дерево процессов завершено' ((Wait-Dead $info.pid) -and (Wait-Dead $info.grandchild))

# ---------------------------------------------------------------- 7. shutdownViaStdin=false
Write-Host "== shutdownViaStdin=false"
$c = New-Case 'nostdin' 'ignore-stdin' @{ shutdownViaStdin = $false; stopTimeoutSeconds = 30 }
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
$el = $sw.Elapsed.TotalSeconds
Assert-That 'сразу завершение дерева, код 0' ($code -eq 0 -and $el -lt 5) "код $code, $([math]::Round($el,2)) с"
Assert-That 'дочерний процесс и «внук» завершены' ((Wait-Dead $info.pid) -and (Wait-Dead $info.grandchild))

# ---------------------------------------------------------------- 8. неожиданный выход
Write-Host "== Неожиданный выход дочернего процесса"
$c = New-Case 'crash' 'crash'
$p = Start-SvcHost $c
$code = Wait-Exit $p 20
Assert-That 'код хоста 4' ($code -eq 4) "код $code"
$svc = Get-SvcLog $c
Assert-That 'журнал хоста: неожиданно, код 7' ($svc -match 'неожиданно завершился с кодом 7')
Assert-That 'stderr дочернего процесса сохранён' ((Read-Utf8 (Join-Path $c.Logs ($c.Name + '.err.log'))) -match 'сбой: выход с кодом 7')

# ---------------------------------------------------------------- 9. хост убит
Write-Host "== Хост убит: KILL_ON_JOB_CLOSE"
$c = New-Case 'hostkill' 'graceful-orphan'
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
Stop-Process -Id $p.Id -Force
$null = Wait-Exit $p 10
Assert-That 'дочерний процесс завершён вместе с хостом' (Wait-Dead $info.pid)
Assert-That '«внук» завершён вместе с хостом' (Wait-Dead $info.grandchild)

# ---------------------------------------------------------------- 10. ротация
Write-Host "== Ротация журналов"
$max = 8192
$c = New-Case 'rotate' 'spam' @{ logMaxBytes = $max; logKeepFiles = 3 } @('3000')
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
Start-Sleep -Milliseconds 500
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
Assert-That 'код хоста 0' ($code -eq 0) "код $code"
$base = Join-Path $c.Logs ($c.Name + '.out')
$files = @("$base.3.log", "$base.2.log", "$base.1.log", "$base.log")
Assert-That 'есть текущий и 3 старых файла' (@($files | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 4)
Assert-That 'четвёртого старого файла нет (logKeepFiles=3)' (-not (Test-Path -LiteralPath "$base.4.log"))
$allLines = New-Object System.Collections.Generic.List[string]
$sizesOk = $true; $boundOk = $true; $utfOk = $true
foreach ($f in $files) {
  $len = (Get-Item -LiteralPath $f).Length
  if ($len -gt $max + 200) { $sizesOk = $false }
  try { $t = Read-Utf8 $f } catch { $utfOk = $false; continue }
  if ($f -ne "$base.log" -and -not $t.EndsWith("`n")) { $boundOk = $false }
  foreach ($l in ($t -split "`n")) { if ($l -match '^line (\d{6}) ') { $allLines.Add($Matches[1]) } elseif ($l -ne '' -and $l -notmatch '^\{') { $boundOk = $false } }
}
Assert-That 'размер файлов не больше logMaxBytes + 1 строка' $sizesOk
Assert-That 'ротация на границе строк' $boundOk
Assert-That 'журналы — корректный UTF-8, кириллица цела' ($utfOk -and ((Read-Utf8 "$base.1.log") -match 'Проверка UTF-8 ёЁ'))
$seqOk = $allLines.Count -gt 0
for ($k = 1; $k -lt $allLines.Count; $k++) { if ([int]$allLines[$k] -ne [int]$allLines[$k - 1] + 1) { $seqOk = $false; break } }
Assert-That 'строки идут подряд без пропусков (в пределах хранимых файлов)' ($seqOk -and [int]$allLines[$allLines.Count - 1] -eq 2999) ("строк: $($allLines.Count), последняя: $(if ($allLines.Count) { $allLines[$allLines.Count - 1] })")

# ---------------------------------------------------------------- 11. ошибка запуска
Write-Host "== Ошибка запуска"
$notExe = Join-Path $WorkDir 'not-an-exe.txt'
[System.IO.File]::WriteAllText($notExe, 'это не программа')
$c = New-Case 'badexe' 'graceful' @{ executable = $notExe }
$p = Start-SvcHost $c
$code = Wait-Exit $p 20
Assert-That 'не исполняемый файл -> код 3' ($code -eq 3) "код $code"
Assert-That 'журнал хоста: CreateProcess' ((Get-SvcLog $c) -match 'CreateProcess')

# ---------------------------------------------------------------- 13. класс службы без SCM (--service-test)
Write-Host "== Класс службы без SCM: OnStart / OnStop / OnShutdown / PRESHUTDOWN"
foreach ($kind in 'stop', 'shutdown', 'preshutdown') {
  $c = New-Case "svc$kind" 'graceful'
  $p = Start-SvcHost $c @('--service-test', $kind)
  $started = Wait-File (Join-Path $c.Markers 'ready.json')
  Start-Sleep -Milliseconds 300
  $null = Send-CtrlC $p.Id
  $code = Wait-Exit $p 30
  $svc = Get-SvcLog $c
  $why = @{ stop = 'остановка по запросу SCM'; shutdown = 'выключение Windows \(SHUTDOWN\)'; preshutdown = 'выключение Windows \(PRESHUTDOWN\)' }[$kind]
  Assert-That "service-test ${kind}: OnStart запустил процесс, остановка штатная, код 0" ($started -and $code -eq 0 -and $svc -match '\(служба\)' -and $svc -match $why -and $svc -match 'остановлено \(Graceful\)') "код $code"
  Assert-That "service-test ${kind}: дочерний процесс получил EOF stdin" (Test-Path -LiteralPath (Join-Path $c.Markers 'stdin-eof.txt'))
}
Assert-That 'service-test: PRESHUTDOWN включён (поле acceptedCommands найдено)' ((Get-SvcLog $c) -notmatch 'PRESHUTDOWN недоступен')

$c = New-Case 'svccrash' 'crash'
$p = Start-SvcHost $c @('--service-test', 'stop')
$code = Wait-Exit $p 20
Assert-That 'service-test: неожиданный выход -> код 4 через поток наблюдения службы' ($code -eq 4 -and (Get-SvcLog $c) -match 'SCM применит действия восстановления') "код $code"

$c = New-Case 'svclogfile' 'graceful'
$blocker = Join-Path $c.Dir 'logs-is-a-file'
[System.IO.File]::WriteAllText($blocker, 'не папка')
$j = Get-Content -LiteralPath $c.Config -Raw -Encoding UTF8 | ConvertFrom-Json
$j.logDirectory = $blocker
[System.IO.File]::WriteAllText($c.Config, ($j | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))
$r = Invoke-Exe @('--service-test', 'stop', '--config', $c.Config)
Assert-That 'service-test: журнал не открывается -> ExitCode 1067 для SCM, код 2, понятный текст' ($r.Code -eq 2 -and $r.Err -match 'ExitCode для SCM 1067' -and $r.Err -match 'не удалось открыть журнал хоста' -and $r.Err -notmatch 'внутренняя ошибка') ($r.Err.Trim() -replace '\s+', ' ')
Assert-That 'service-test: дочерний процесс не запускался' (-not (Test-Path -LiteralPath (Join-Path $c.Markers 'ready.json')))

$r = Invoke-Exe @('--service-test', 'stop', '--config', $bad)
Assert-That 'service-test: ошибка настроек -> 1067, одно сообщение, без «внутренней ошибки»' ($r.Code -eq 2 -and $r.Err -match 'ExitCode для SCM 1067' -and ([regex]::Matches($r.Err, 'ошибка файла настроек')).Count -eq 1 -and $r.Err -notmatch 'внутренняя ошибка') ("код $($r.Code)")
$r = Invoke-Exe @('--service-test', 'bogus', '--config', $ok.Config)
Assert-That 'service-test с неизвестным видом остановки -> код 2' ($r.Code -eq 2)

# ---------------------------------------------------------------- 14. лимиты памяти и процессора
Write-Host "== jobMemoryLimitMB и cpuRatePercent"
$c = New-Case 'memlimit' 'alloc' @{ jobMemoryLimitMB = 256 }
$p = Start-SvcHost $c
$code = Wait-Exit $p 60
$svc = Get-SvcLog $c
Assert-That 'процесс упёрся в jobMemoryLimitMB=256 -> код хоста 4' ($code -eq 4) "код $code"
Assert-That 'журнал хоста: пик памяти и пометка о лимите' ($svc -match 'jobMemoryLimitMB=256' -and $svc -match 'достигнут лимит памяти') (([regex]::Match($svc, 'неожиданно[^\r\n]*')).Value)
$r = Invoke-Exe @('--check-config', '--config', (New-Case 'memlimitbad' 'graceful' @{ jobMemoryLimitMB = 10; cpuRatePercent = 0; inheritEnvironment = 'no' }).Config)
Assert-That 'неверные jobMemoryLimitMB/cpuRatePercent/inheritEnvironment -> код 2' ($r.Code -eq 2 -and $r.Err -match 'jobMemoryLimitMB' -and $r.Err -match 'cpuRatePercent' -and $r.Err -match 'inheritEnvironment') ($r.Err.Trim())

$cpuMs = @{}
foreach ($rate in 1, 0) {
  $over = @{}; if ($rate) { $over.cpuRatePercent = $rate }
  $c = New-Case "cpu$rate" 'burn' $over
  $p = Start-SvcHost $c
  $null = Wait-File (Join-Path $c.Markers 'cpu.json') 40
  $cpuMs[$rate] = [int]((Read-Utf8 (Join-Path $c.Markers 'cpu.json')) | ConvertFrom-Json).cpuMs
  $null = Send-CtrlC $p.Id
  $null = Wait-Exit $p 30
}
Assert-That 'cpuRatePercent=1 ограничивает время ЦП (меньше 60 % от свободного запуска)' ($cpuMs[1] -lt 0.6 * $cpuMs[0]) ("с лимитом $($cpuMs[1]) мс, без лимита $($cpuMs[0]) мс за 2 с, логических ЦП $([Environment]::ProcessorCount)")

# ---------------------------------------------------------------- 15. окружение
Write-Host "== inheritEnvironment и --env-file"
$envFile = Join-Path $WorkDir 'test.env'
[System.IO.File]::WriteAllText($envFile, "# тестовый файл`nSVC_TEST_INHERIT=из файла`n")
$env:SVC_TEST_INHERIT = 'из Windows'
$c = New-Case 'envinherit' 'graceful'
$j = Get-Content -LiteralPath $c.Config -Raw -Encoding UTF8 | ConvertFrom-Json
$j.arguments = @("--env-file=$envFile") + @($j.arguments)
[System.IO.File]::WriteAllText($c.Config, ($j | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
$null = Send-CtrlC $p.Id; $null = Wait-Exit $p 30
Assert-That 'наследование: переменная Windows перекрывает --env-file (поведение node)' ($info.envInherited -eq 'из Windows') "$($info.envInherited)"
Assert-That 'журнал хоста предупреждает о перекрытии' ((Get-SvcLog $c) -match 'переменная SVC_TEST_INHERIT задана в окружении Windows')

$c = New-Case 'envclean' 'graceful' @{ inheritEnvironment = $false }
$j = Get-Content -LiteralPath $c.Config -Raw -Encoding UTF8 | ConvertFrom-Json
$j.arguments = @("--env-file=$envFile") + @($j.arguments)
[System.IO.File]::WriteAllText($c.Config, ($j | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))
$p = Start-SvcHost $c
$null = Wait-File (Join-Path $c.Markers 'ready.json')
$info = Read-Ready $c
$null = Send-CtrlC $p.Id; $code = Wait-Exit $p 30
Assert-That 'inheritEnvironment=false: значение из --env-file, системные переменные есть' ($code -eq 0 -and $info.envInherited -eq 'из файла' -and $info.systemRoot -and $info.hasPath -and $info.envSet -eq 'значение 1') "код $code, $($info.envInherited), SystemRoot=$($info.systemRoot)"
Assert-That 'inheritEnvironment=false: предупреждения нет' ((Get-SvcLog $c) -notmatch 'задана в окружении Windows')
Remove-Item Env:\SVC_TEST_INHERIT

# ---------------------------------------------------------------- 16. отказ открыть журнал после ротации
Write-Host "== Отказ открыть журнал после ротации"
$env:OPTOMSTROYSVC_TEST_FAIL_REOPEN = '1'
$c = New-Case 'reopen' 'spam' @{ logMaxBytes = 8192; logKeepFiles = 2 } @('500')
$p = Start-SvcHost $c
Remove-Item Env:\OPTOMSTROYSVC_TEST_FAIL_REOPEN
$null = Wait-File (Join-Path $c.Markers 'ready.json')
Start-Sleep -Seconds 7
$null = Send-CtrlC $p.Id
$code = Wait-Exit $p 30
$svc = Get-SvcLog $c
$outNow = Read-Utf8 (Join-Path $c.Logs ($c.Name + '.out.log'))
Assert-That 'код хоста 0' ($code -eq 0) "код $code"
Assert-That 'журнал хоста: не удалось открыть после ротации' ($svc -match 'после ротации не удалось открыть')
Assert-That 'журнал хоста: снова открыт, указано сколько потеряно' ($svc -match 'снова открыт; потеряно байт вывода: [1-9]')
Assert-That 'после повторного открытия вывод снова пишется' ($outNow -match 'работаю' -and $outNow -match 'stdin-eof')

# ---------------------------------------------------------------- 12. настоящий API (необязательно, -RealApi)
if ($RealApi) {
  Write-Host "== Настоящий pos-api\dist\main.js под хостом (база недоступна намеренно)"
  $api = Join-Path $repo 'pos-api'
  if (-not (Test-Path -LiteralPath (Join-Path $api 'dist\main.js'))) {
    Assert-That 'pos-api\dist\main.js собран' $false 'сначала соберите pos-api'
  } else {
    $port = 3311
    $c = New-Case 'realapi' 'graceful'
    $j = Get-Content -LiteralPath $c.Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $j.arguments = @('dist\main.js')
    $j.workingDirectory = $api
    $j.stopTimeoutSeconds = 30
    $j | Add-Member -NotePropertyName inheritEnvironment -NotePropertyValue $false
    $j | Add-Member -NotePropertyName jobMemoryLimitMB -NotePropertyValue 1024
    $j.arguments = @('--max-old-space-size=768', 'dist\main.js')
    $j.environment = [ordered]@{
      APP_ENV = 'dev'; LOG_LEVEL = 'info'; MIN_APP_VERSION = 'android=1.2.0,windows=1.2.0'
      DATABASE_URL = 'postgres://test:test@127.0.0.1:1/none'   # check-secrets: allow — заведомо недоступный адрес теста
      API_HOST = '127.0.0.1'; API_PORT = "$port"; POS_SHUTDOWN_ON_STDIN_EOF = '1'
    }
    [System.IO.File]::WriteAllText($c.Config, ($j | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $true))
    $p = Start-SvcHost $c
    $up = $false
    for ($k = 0; $k -lt 60 -and -not $up; $k++) {
      try { $null = Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2; $up = $true } catch { Start-Sleep -Milliseconds 500 }
    }
    Assert-That "API отвечает на 127.0.0.1:$port/health" $up
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress })
    Assert-That 'API слушает только 127.0.0.1' (($listen -join ',') -eq '127.0.0.1') ($listen -join ',')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Send-CtrlC $p.Id
    $code = Wait-Exit $p 60
    Assert-That 'API штатно остановлен по EOF stdin, код хоста 0' ($code -eq 0) ("код $code, $([math]::Round($sw.Elapsed.TotalSeconds,2)) с")
    $out = Read-Utf8 (Join-Path $c.Logs ($c.Name + '.out.log')) + (Read-Utf8 (Join-Path $c.Logs ($c.Name + '.err.log')))
    Assert-That 'в журнале API строка штатной остановки' ($out -match 'stdin-eof')
    Assert-That "порт $port закрыт" (@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count -eq 0)
  }
}

# ---------------------------------------------------------------- итог
$failed = @($script:results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("Итог: {0} проверок, ошибок: {1}" -f $script:results.Count, $failed.Count)
if (-not $Keep) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
