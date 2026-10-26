# Оптомстрой POS — запуск демо на этом компьютере.
# Поднимает локальный сервер (pos-api + pos-worker + встроенная PostgreSQL 17 + имитатор 1С на тестовых данных)
# и открывает приложение для Windows. Данные демо создаются заново при каждом запуске.
# Реальной 1С, SMS и оплаты нет: всё работает на тестовых данных.
#
#   start-demo.cmd                  — обычный запуск (закройте окно приложения, чтобы остановить демо)
#   start-demo.cmd -NoApp           — только сервер (Enter — остановка)
#   start-demo.cmd -Smoke           — самопроверка: сервер, вход кассира, каталог, запуск приложения, снимок экрана
#   start-demo.cmd -KeepAppData     — не очищать данные приложения (demo\data) перед запуском
param(
  [int]$Sku = 500,
  [ValidateSet('onec', 'none')][string]$QrProvider = 'onec',
  [switch]$NoApp,
  [switch]$Smoke,
  [switch]$KeepAppData,
  [int]$SmokeAppSeconds = 25
)
$ErrorActionPreference = 'Stop'
$demo = $PSScriptRoot
$root = Split-Path $demo -Parent
. (Join-Path $demo 'demo-common.ps1')
Initialize-DemoConsole

$api = Join-Path $root 'pos-api'
$app = Join-Path $demo 'app\optomstroy.exe'
$tmp = Join-Path $demo '.tmp'
$logs = Join-Path $demo 'logs'
$dataDir = Join-Path $demo 'data'
$proxy = 'http://127.0.0.1:8080'
$apiBase = "$proxy/api/v1"
New-Item -ItemType Directory -Force $tmp, $logs, $dataDir | Out-Null
$runLog = Join-Path $logs $(if ($Smoke) { 'smoke.log' } else { 'start-demo.log' })
Set-Content -LiteralPath $runLog -Value "Оптомстрой POS — демо, запуск $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8

function Say([string]$text, [string]$color = 'Gray', [switch]$NoNewline) {
  Write-Host $text -ForegroundColor $color -NoNewline:$NoNewline
  if (-not $NoNewline) { Add-Content -LiteralPath $runLog -Value $text -Encoding UTF8 }
}

# Выход до запуска стека; в режиме -Smoke — с итогом SMOKE FAIL.
function Exit-Early([int]$code = 1) {
  if ($Smoke) { Say "SMOKE FAIL (запуск не начат). Журнал: $runLog" 'Red' }
  exit $code
}

Say ''
Say '  ОПТОМСТРОЙ POS — демо' 'DarkYellow'
Say '  Тестовые данные, без реальной 1С, SMS и оплаты.' 'Gray'
Say ''

# ---------------------------------------------------------------------------------------------------------------
# 1. Проверки
# ---------------------------------------------------------------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Say 'Не найден Node.js 24 — установите его с nodejs.org и запустите снова.' 'Red'; Exit-Early }
$nodeVersion = [string](& $node.Source --version)
if ($nodeVersion -match '^v(\d+)\.' -and [int]$Matches[1] -lt 24) {
  Say "Нужен Node.js 24, установлен $nodeVersion — обновите его с nodejs.org." 'Red'; Exit-Early
}
if (-not (Test-Path (Join-Path $api 'node_modules'))) { Say 'Нет зависимостей сервера (pos-api\node_modules). Выполните в pos-api: npm ci' 'Red'; Exit-Early }
if (-not (Test-Path (Join-Path $api 'dist\main.js'))) {
  Say 'Сборка сервера отсутствует — собираю (npm run build)...' 'Yellow'
  Push-Location $api
  try { $code = Invoke-Native { npm run build *>&1 | Out-File -Encoding utf8 (Join-Path $logs 'build.log') } } finally { Pop-Location }
  if ($code -ne 0) { Say "Сборка сервера не удалась. Журнал: $(Join-Path $logs 'build.log')" 'Red'; Exit-Early }
}
if (-not $NoApp -and -not (Test-Path $app)) { Say "Нет приложения: $app. Соберите демо: demo\build-demo.ps1" 'Red'; Exit-Early }

# Каталог данных вшит в сборку приложения (demo_env.json → APP_DATA_DIR): папку демо перенесли — нужна пересборка.
$envFile = Join-Path $demo 'demo_env.json'
if (-not $NoApp -and (Test-Path $envFile)) {
  try {
    $built = ((Get-Content -LiteralPath $envFile -Raw -Encoding UTF8 | ConvertFrom-Json).APP_DATA_DIR) -replace '/', '\'
    if ($built -and ($built.TrimEnd('\') -ine ([IO.Path]::GetFullPath($dataDir)).TrimEnd('\'))) {
      Say "Внимание: приложение собрано для папки данных $built, а демо лежит в $demo. Пересоберите: demo\build-demo.ps1" 'Yellow'
    }
  } catch { }
}

# Остатки прошлого запуска (аварийное завершение, закрытое окно консоли) — освобождаем порты 3000/8080/8091/8092.
$left = Clear-DemoLeftovers $demo $app
if ($left.Killed -gt 0) { Say "     Остановлены процессы прошлого запуска демо: $($left.Killed)" 'Yellow' }
if ($left.Foreign.Count -gt 0) {
  foreach ($f in $left.Foreign) { Say "Порт занят другой программой: $f" 'Red' }
  Say 'Закройте эту программу (или перезагрузите компьютер) и запустите демо снова.' 'Red'
  Exit-Early
}

# Сервер создаёт данные заново — локальные данные приложения прошлого запуска (сессия, кэш, очередь) уже не нужны.
if (-not $KeepAppData -and -not $NoApp) {
  Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------------------------
# 2. Сервер
# ---------------------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Net.Http
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(30)

function Invoke-Api([string]$Method, [string]$Url, $Body = $null, [string]$Token = '', [string]$DeviceId = '') {
  $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod $Method), $Url
  [void]$req.Headers.TryAddWithoutValidation('X-App-Version', $script:appVersion)
  [void]$req.Headers.TryAddWithoutValidation('X-Platform', 'windows')
  [void]$req.Headers.TryAddWithoutValidation('Accept-Language', 'ru')
  if ($DeviceId) { [void]$req.Headers.TryAddWithoutValidation('X-Device-Id', $DeviceId) }
  if ($Token) { $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue -ArgumentList 'Bearer', $Token }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $req.Content = New-Object System.Net.Http.StringContent -ArgumentList $json, ([Text.Encoding]::UTF8), 'application/json'
  }
  try {
    $res = $script:http.SendAsync($req).GetAwaiter().GetResult()
    $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $obj = $null
    if ($text) { try { $obj = $text | ConvertFrom-Json } catch { } }
    return [pscustomobject]@{ Status = [int]$res.StatusCode; Body = $obj; Text = $text }
  } catch {
    return [pscustomobject]@{ Status = 0; Body = $null; Text = $_.Exception.GetBaseException().Message }
  } finally { $req.Dispose() }
}

# Минимальная версия приложения на сервере = версия собранного приложения (иначе вход блокируется 426
# «Обновите приложение»: версия демо-сборки 0.x ниже серверного значения по умолчанию 1.0.0).
$script:appVersion = '0.1.0'
if (Test-Path $app) {
  $pv = [string](Get-Item -LiteralPath $app).VersionInfo.ProductVersion
  if ($pv -match '^(\d+\.\d+\.\d+)') { $script:appVersion = $Matches[1] }
}
$env:LOCAL_STACK_MIN_APP_VERSION = "android=$($script:appVersion),windows=$($script:appVersion)"

$env:TEMP = $tmp; $env:TMP = $tmp
# Журналы API, воркера и фейка 1С копируются сюда при штатной остановке стека.
$env:LOCAL_STACK_LOG_DIR = Join-Path $logs 'stack'
$ready = Join-Path $tmp 'stack.ready'
Remove-Item $ready -ErrorAction SilentlyContinue
$stackLog = Join-Path $logs 'server.log'
$stackErr = Join-Path $logs 'server.err.log'
$script:stack = $null

function Start-Stack {
  # stdin стека — канал этого окна (--exit-on-stdin-end): закрытие канала или окна консоли = штатная остановка
  # API, воркера, фейка 1С, прокси и PostgreSQL. Вывод — в demo\logs через cmd.exe.
  $nodeArgs = @('scripts/local-stack.mjs', 'serve', '--cashier-fixtures', "--catalog-fixtures=$Sku",
    '--qr-provider', $QrProvider, '--qr-paid-after-polls', '4', '--ready-file', "`"$ready`"", '--exit-on-stdin-end', '--otp-any-phone')
  $cmdLine = "`"$($node.Source)`" $($nodeArgs -join ' ') 1>`"$stackLog`" 2>`"$stackErr`""
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = "/d /s /c `"$cmdLine`""
  $psi.WorkingDirectory = $api
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $script:stack = [System.Diagnostics.Process]::Start($psi)
}

function Stop-Stack {
  $s = $script:stack
  $script:stack = $null
  if ($s -and -not $s.HasExited) {
    $graceful = $false
    if (Test-Path $ready) {
      try { $s.StandardInput.Close() } catch { }
      $graceful = $s.WaitForExit(60000)
    }
    if (-not $graceful) { Stop-ProcessTree $s.Id }
  }
  # Добиваем то, что могло остаться (например, после принудительной остановки).
  [void](Clear-DemoLeftovers $demo $(if ($script:appStarted) { $app } else { '' }))
  Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
}

function Show-StackError {
  foreach ($f in @($stackErr, $stackLog)) {
    if (Test-Path $f) {
      $tail = @(Get-Content -LiteralPath $f -Tail 15 -Encoding UTF8 -ErrorAction SilentlyContinue)
      if ($tail.Count -gt 0) { Say "--- $f (последние строки) ---" 'DarkGray'; foreach ($l in $tail) { Say "  $l" 'DarkGray' } }
    }
  }
}

function Wait-StackReady {
  $deadline = (Get-Date).AddMinutes(10)
  $started = Get-Date
  $shownMinute = 0
  while ($true) {
    if (Test-Path $ready) {
      $h = Invoke-Api 'GET' "$proxy/health/ready"
      if ($h.Status -eq 200) { Say ''; return $true }
    }
    if ($script:stack.HasExited) {
      Say ''; Say "Сервер остановился с ошибкой (код $($script:stack.ExitCode)). Журнал: $stackErr" 'Red'; Show-StackError; return $false
    }
    if ((Get-Date) -gt $deadline) { Say ''; Say "Сервер не поднялся за 10 минут. Журнал: $stackLog" 'Red'; Show-StackError; return $false }
    Start-Sleep -Seconds 2
    Say '.' 'Gray' -NoNewline
    $minute = [int][Math]::Floor(((Get-Date) - $started).TotalMinutes)
    if ($minute -gt $shownMinute) { $shownMinute = $minute; Say " $minute мин " 'DarkGray' -NoNewline }
  }
}

# ---------------------------------------------------------------------------------------------------------------
# 3. Самопроверка (-Smoke)
# ---------------------------------------------------------------------------------------------------------------
$script:checks = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail) {
  $script:checks.Add([pscustomobject]@{ Name = $name; Ok = $ok })
  Say ("  {0}  {1} — {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail) $(if ($ok) { 'Green' } else { 'Red' })
}
function Short([string]$text) { if (-not $text) { return '' }; $t = $text -replace '\s+', ' '; if ($t.Length -gt 200) { $t.Substring(0, 200) + '…' } else { $t } }

function Invoke-ApiSmoke {
  $h = Invoke-Api 'GET' "$proxy/health/ready"
  Check 'GET /health/ready (мини-прокси :8080)' ($h.Status -eq 200) "HTTP $($h.Status)"

  $phone = '+996777000906'   # кассир (тестовые данные, local-stack AUTH_FIXTURES.cashier)
  $dev = [guid]::NewGuid().ToString()
  $r = Invoke-Api 'POST' "$apiBase/auth/otp/request" @{ phone = $phone; purpose = 'login_or_register'; locale = 'ru' } -DeviceId $dev
  $challenge = if ($r.Body) { [string]$r.Body.challengeId } else { '' }
  Check 'POST /auth/otp/request (кассир +996777000906)' ($r.Status -eq 202 -and $challenge) "HTTP $($r.Status)$(if ($r.Status -ne 202) { ' ' + (Short $r.Text) })"
  if (-not $challenge) { return }

  $device = @{ name = 'Демо: самопроверка'; platform = 'windows'; appVersion = $script:appVersion; biometricClass = 'none' }
  $v = Invoke-Api 'POST' "$apiBase/auth/otp/verify" @{ challengeId = $challenge; code = '246810'; device = $device } -DeviceId $dev
  $token = if ($v.Body) { [string]$v.Body.accessToken } else { '' }
  $roles = if ($v.Body -and $v.Body.user) { (@($v.Body.user.roles) -join ',') } else { '' }
  Check 'POST /auth/otp/verify (код 246810)' ($v.Status -eq 200 -and $v.Body.status -eq 'authenticated' -and $token) "HTTP $($v.Status) status=$(if ($v.Body) { $v.Body.status }) roles=$roles nextStep=$(if ($v.Body) { $v.Body.nextStep })$(if ($v.Status -ne 200) { ' ' + (Short $v.Text) })"
  if (-not $token) { return }

  $c = Invoke-Api 'GET' "$apiBase/catalog/products?limit=20" -Token $token -DeviceId $dev
  if ($c.Status -eq 403) {
    # Сотрудник без PIN: до установки PIN сессия ограничена (ядро §24.2) — задаём тестовый PIN и повторяем.
    $pin = Invoke-Api 'POST' "$apiBase/me/pin" @{ newPin = '715382' } -Token $token -DeviceId $dev
    Check 'POST /me/pin (первый вход сотрудника, тестовый PIN)' ($pin.Status -eq 204) "HTTP $($pin.Status)$(if ($pin.Status -ne 204) { ' ' + (Short $pin.Text) })"
    $c = Invoke-Api 'GET' "$apiBase/catalog/products?limit=20" -Token $token -DeviceId $dev
  }
  $items = if ($c.Body -and $c.Body.items) { @($c.Body.items) } else { @() }
  $first = if ($items.Count -gt 0) { " первый: «$($items[0].name)»" } else { '' }
  Check 'GET /catalog/products?limit=20 (с токеном кассира)' ($c.Status -eq 200 -and $items.Count -gt 0) "HTTP $($c.Status), товаров на странице: $($items.Count)$first$(if ($c.Status -ne 200) { ' ' + (Short $c.Text) })"
}

$script:winApiLoaded = $false
function Initialize-WinApi {
  if ($script:winApiLoaded) { return }
  Add-Type -AssemblyName System.Drawing
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DemoWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
}
'@
  [void][DemoWin]::SetProcessDPIAware()
  $script:winApiLoaded = $true
}

function Test-BitmapHasContent([System.Drawing.Bitmap]$bmp) {
  # Чёрный/однотонный снимок (окно не отрисовано) — неудача; сравниваем точки сетки 8×8.
  $first = $bmp.GetPixel(0, 0).ToArgb()
  for ($i = 1; $i -le 8; $i++) {
    for ($j = 1; $j -le 8; $j++) {
      $x = [int](($bmp.Width - 1) * $i / 9); $y = [int](($bmp.Height - 1) * $j / 9)
      if ($bmp.GetPixel($x, $y).ToArgb() -ne $first) { return $true }
    }
  }
  return $false
}

# Снимок окна приложения в $path: PrintWindow по MainWindowHandle → снимок области окна с экрана → весь экран.
function Save-AppScreenshot([System.Diagnostics.Process]$p, [string]$path) {
  Initialize-WinApi
  $p.Refresh()
  $h = $p.MainWindowHandle
  if ($h -ne [IntPtr]::Zero) {
    if ([DemoWin]::IsIconic($h)) { [void][DemoWin]::ShowWindow($h, 9) }
    [void][DemoWin]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 800
    # Видимая рамка окна (DWM) без невидимых полей изменения размера; PrintWindow рисует от угла GetWindowRect.
    $wr = New-Object DemoWin+RECT
    [void][DemoWin]::GetWindowRect($h, [ref]$wr)
    $r = New-Object DemoWin+RECT
    if ([DemoWin]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { $r = $wr }
    $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
    $fw = $wr.Right - $wr.Left; $fh = $wr.Bottom - $wr.Top
    if ($w -gt 50 -and $hh -gt 50 -and $fw -ge $w -and $fh -ge $hh) {
      $crop = New-Object System.Drawing.Rectangle ($r.Left - $wr.Left), ($r.Top - $wr.Top), $w, $hh
      $full = New-Object System.Drawing.Bitmap $fw, $fh
      $g = [System.Drawing.Graphics]::FromImage($full)
      try {
        $hdc = $g.GetHdc()
        $ok = [DemoWin]::PrintWindow($h, $hdc, 2)   # PW_RENDERFULLCONTENT: окно целиком, даже если перекрыто
        $g.ReleaseHdc($hdc)
        if ($ok) {
          $bmp = $full.Clone($crop, $full.PixelFormat)
          try {
            if (Test-BitmapHasContent $bmp) { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); return "окно приложения ${w}×${hh} (PrintWindow)" }
          } finally { $bmp.Dispose() }
        }
        $bmp = New-Object System.Drawing.Bitmap $w, $hh
        $g2 = [System.Drawing.Graphics]::FromImage($bmp)
        try {
          $g2.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hh))
          if (Test-BitmapHasContent $bmp) { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); return "окно приложения ${w}×${hh} (область экрана)" }
        } finally { $g2.Dispose(); $bmp.Dispose() }
      } catch { } finally { $g.Dispose(); $full.Dispose() }
    }
  }
  # Запасной путь — весь виртуальный экран (все мониторы).
  $x = [DemoWin]::GetSystemMetrics(76); $y = [DemoWin]::GetSystemMetrics(77)
  $w = [DemoWin]::GetSystemMetrics(78); $hh = [DemoWin]::GetSystemMetrics(79)
  $bmp = New-Object System.Drawing.Bitmap $w, $hh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $hh))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    return "весь экран ${w}×${hh} (окно не найдено или не отрисовано)"
  } finally { $g.Dispose(); $bmp.Dispose() }
}

function Invoke-AppSmoke {
  $shot = Join-Path $logs 'smoke.png'
  Remove-Item $shot -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -PassThru
  $script:appStarted = $true
  Say "  ...  приложение запущено (PID $($p.Id)), жду $SmokeAppSeconds с" 'Gray'
  Start-Sleep -Seconds $SmokeAppSeconds
  $alive = -not $p.HasExited
  Check "приложение работает через $SmokeAppSeconds с" $alive $(if ($alive) { "PID $($p.Id), окно «$($p.MainWindowTitle)»" } else { "завершилось с кодом $($p.ExitCode)" })
  if ($alive) {
    try {
      $how = Save-AppScreenshot $p $shot
      Check 'снимок экрана demo\logs\smoke.png' (Test-Path $shot) $how
    } catch { Check 'снимок экрана demo\logs\smoke.png' $false $_.Exception.Message }
    [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(15000)) { Stop-ProcessTree $p.Id; [void]$p.WaitForExit(5000) }
    Check 'приложение закрыто' $p.HasExited $(if ($p.HasExited) { 'окно закрыто' } else { 'не закрылось' })
  }
}

# ---------------------------------------------------------------------------------------------------------------
# 4. Запуск
# ---------------------------------------------------------------------------------------------------------------
$script:appStarted = $false
$script:exitCode = 0
function Invoke-Demo {
  Say "1/2  Запускаю сервер и загружаю демо-данные ($Sku товаров, клиенты, долги)... это 1–3 минуты" 'Cyan'
  Start-Stack
  if (-not (Wait-StackReady)) { $script:exitCode = 1; return }
  Say "     Сервер готов: $apiBase (версия приложения $($script:appVersion))" 'Green'

  if ($Smoke) {
    Say ''
    Say 'САМОПРОВЕРКА' 'Cyan'
    Invoke-ApiSmoke
    if (-not $NoApp) { Invoke-AppSmoke }
    return
  }

  Say ''
  Say '  Вход в приложение: ЛЮБОЙ номер +996, затем код из SMS — всегда 246810 (демо-режим, SMS не отправляются).' 'White'
  Say '  Свой номер = новый покупатель (регистрация). Готовые роли сотрудников:' 'White'
  Say '    +996 777 000 901  администратор        +996 777 000 909  руководитель' 'Gray'
  Say '    +996 777 000 906  кассир               +996 777 000 907  старший продавец' 'Gray'
  Say '    +996 777 000 902  продавец (по приглашению)' 'Gray'
  Say '    +996 777 000 905  новый покупатель (регистрация)' 'Gray'
  Say '  Сотрудник при первом входе задаёт PIN из 6 цифр (не 111111 и не 123456), например 715382.' 'Gray'
  Say '  Оплата по QR в демо подтверждается имитатором 1С сама примерно через 10–20 секунд.' 'Gray'
  Say "  Подробнее — demo\README.md. Журналы — $logs" 'Gray'
  Say ''

  if ($NoApp) {
    Say 'Режим без приложения: сервер работает, нажмите Enter для остановки.' 'Yellow'
    [void][Console]::ReadLine()
  } else {
    Say '2/2  Открываю приложение. Закройте окно приложения, чтобы остановить демо.' 'Cyan'
    $p = Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -PassThru
    $script:appStarted = $true
    while (-not $p.HasExited) {
      if ($script:stack.HasExited) { Say 'Сервер неожиданно остановился — см. журналы в demo\logs.' 'Red'; Show-StackError; $script:exitCode = 1; break }
      Start-Sleep -Seconds 1
    }
  }
}

try {
  Invoke-Demo
} finally {
  Say 'Останавливаю сервер...' 'Gray'
  Stop-Stack
  $busy = @($script:DemoPorts | Where-Object { (Get-PortOwners $_).Count -gt 0 })
  if ($Smoke) {
    Check 'стек остановлен, порты 3000/8080/8091/8092 свободны' ($busy.Count -eq 0) $(if ($busy.Count -eq 0) { 'свободны' } else { "заняты: $($busy -join ', ')" })
    $failed = @($script:checks | Where-Object { -not $_.Ok }).Count
    if ($script:exitCode -ne 0 -or $failed -gt 0 -or $script:checks.Count -eq 0) {
      Say "SMOKE FAIL (не прошло проверок: $failed из $($script:checks.Count)). Журнал: $runLog" 'Red'
      $script:exitCode = 1
    } else {
      Say "SMOKE OK (проверок: $($script:checks.Count)). Снимок: $(Join-Path $logs 'smoke.png')" 'Green'
    }
  } else {
    Say 'Демо остановлено.' 'Green'
  }
  $script:http.Dispose()
}
exit $script:exitCode
