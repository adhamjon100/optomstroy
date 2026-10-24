# Оптомстрой POS — общие функции демо (подключаются из build-demo.ps1 и start-demo.ps1 через «. demo-common.ps1»).
# Файл сохранён в UTF-8 с BOM: Windows PowerShell 5.1 без BOM читает скрипт в кодировке ANSI и портит русский текст.

# Порты локального стека (pos-api/scripts/local-stack.mjs): API, мини-прокси (фото + API), фейк 1С, управление стендом.
# PostgreSQL получает свободный порт при каждом запуске и опознаётся по каталогу данных в demo\.tmp.
$script:DemoPorts = @(3000, 8080, 8091, 8092)

function Initialize-DemoConsole {
  # Русский текст в консоли и в перенаправленном выводе (журналы, планировщик): вывод в UTF-8.
  $utf8 = New-Object System.Text.UTF8Encoding $false
  try { [Console]::OutputEncoding = $utf8 } catch { }
  $global:OutputEncoding = $utf8
}

# Запуск внешней программы без превращения её stderr в ошибку PowerShell 5.1 (NativeCommandError при
# $ErrorActionPreference = 'Stop'); результат — код выхода.
function Invoke-Native([scriptblock]$Command) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command | Out-Host; return $LASTEXITCODE } finally { $ErrorActionPreference = $old }
}

function Stop-ProcessTree([int]$Id) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try { & taskkill.exe /PID $Id /T /F 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
}

# PID процессов, слушающих TCP-порт (Get-NetTCPConnection, запасной путь — netstat).
function Get-PortOwners([int]$Port) {
  $ids = @()
  try {
    $ids = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | ForEach-Object { [int]$_.OwningProcess })
  } catch {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { $lines = & netstat.exe -ano -p tcp 2>$null } finally { $ErrorActionPreference = $old }
    foreach ($l in $lines) {
      if ($l -match "^\s*TCP\s+\S+:$Port\s+(0\.0\.0\.0:0|\[::\]:0)\s+\S+\s+(\d+)\s*$") { $ids += [int]$Matches[2] }
    }
  }
  return @($ids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
}

function Test-DemoScriptProcess($p) {
  # Процессы стека запускаются из pos-api относительными путями: node scripts/local-stack.mjs, node dist/main.js, …
  return ($p.Name -ieq 'node.exe') -and ([string]$p.CommandLine -match 'local-stack\.mjs|pos_fake_onec|load_catalog_fixtures|dist[\\/](main|worker|migrate)\.js')
}

# Остатки прошлого запуска (аварийное завершение, закрытое окно консоли): процессы стека на портах демо, осиротевшие
# процессы стека, PostgreSQL с данными в demo\.tmp, запущенное приложение демо; затем — временные каталоги стека.
# Возвращает список занятых чужими программами портов (их демо не трогает).
function Clear-DemoLeftovers([string]$DemoDir, [string]$AppExe) {
  $tmp = [IO.Path]::GetFullPath((Join-Path $DemoDir '.tmp')).TrimEnd('\').ToLowerInvariant()
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $byId = @{}
  foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
  $kill = @{}
  $foreign = @()

  foreach ($port in $script:DemoPorts) {
    foreach ($id in (Get-PortOwners $port)) {
      $p = $byId[[int]$id]
      if ($p -and (Test-DemoScriptProcess $p)) { $kill[[int]$id] = "порт $port" }
      elseif ($p) { $foreign += "порт $port занят программой $($p.Name) (PID $id)" }
      else { $foreign += "порт $port занят (PID $id)" }
    }
  }
  foreach ($p in $all) {
    $id = [int]$p.ProcessId
    if ($kill.ContainsKey($id)) { continue }
    $cl = ([string]$p.CommandLine).Replace('/', '\').ToLowerInvariant()
    if ($p.Name -ieq 'postgres.exe' -and $cl.Contains($tmp)) { $kill[$id] = 'PostgreSQL демо'; continue }
    if ($AppExe -and $p.ExecutablePath -and ($p.ExecutablePath -ieq $AppExe)) { $kill[$id] = 'приложение демо'; continue }
    if (Test-DemoScriptProcess $p) {
      # осиротевший процесс стека: родителя нет (или PID родителя уже занят более новым процессом)
      $parent = $byId[[int]$p.ParentProcessId]
      if (-not $parent -or ($parent.CreationDate -gt $p.CreationDate)) { $kill[$id] = 'осиротевший процесс стека' }
    }
  }
  foreach ($id in $kill.Keys) { Stop-ProcessTree $id }
  if ($kill.Count -gt 0) {
    $deadline = (Get-Date).AddSeconds(15)
    do {
      Start-Sleep -Milliseconds 500
      $still = @($script:DemoPorts | Where-Object { @(Get-PortOwners $_ | Where-Object { $kill.ContainsKey([int]$_) }).Count -gt 0 })
    } while ($still.Count -gt 0 -and (Get-Date) -lt $deadline)
  }
  $tmpDir = Join-Path $DemoDir '.tmp'
  if (Test-Path $tmpDir) {
    Get-ChildItem -LiteralPath $tmpDir -Directory -Filter 'pos-local-stack-*' -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return [pscustomobject]@{ Killed = $kill.Count; Foreign = $foreign }
}
