<#
  Сборка веб-демо «Оптомстрой POS» для Netlify (plan WP-N1; review fixes). Только Windows PowerShell:
  Git Bash портит аргумент --base-href / у flutter build web.

    powershell -ExecutionPolicy Bypass -File demo/web/build-web-demo.ps1 [-SkipFlutter] [-SkipBackend] [-SkipTsc]

  Шаги:
    0. TEMP/TMP на D:\optomstroy\.tmp; проверка места; проверка, что pos-app не занят другим процессом flutter/dart.
    1. node demo/web/backend/build-backend.mjs — pos-api (tsc рабочего дерева) → backend.js, PGlite, снимок, фото,
       лицензии (в site/ — только если все проверки сборки пройдены).
    2. flutter build web (демо-точка входа) → demo/web/.build/flutter; dart compile js drift_worker.js;
       sqlite3.wasm из pub-кэша drift. Пропускается с -SkipFlutter (берётся уже собранное в .build).
    3. node demo/web/tools/assemble-site.mjs — сайт: Flutter + страница + бэкенд, demo/build.json, _headers, _redirects.
    4. node demo/web/tools/check-site.mjs — проверки публикации (секреты, ПДн, пути, sourceMappingURL, заголовки,
       лицензии, размеры). Код выхода скрипта — код выхода check-site.
    5. Удаление pos-app/.dart_tool/flutter_build (гигиена, ~68 МБ).
  Выкладку (netlify deploy) скрипт НЕ делает — это действие пользователя (plan §6, WP-D1).
#>
param(
  [switch]$SkipFlutter,
  [switch]$SkipBackend,
  [switch]$SkipTsc
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Web = Join-Path $Root 'demo\web'
$Build = Join-Path $Web '.build'
$env:TEMP = 'D:\optomstroy\.tmp'
$env:TMP = 'D:\optomstroy\.tmp'
$env:PYTHONIOENCODING = 'utf-8'
New-Item -ItemType Directory -Force $env:TEMP | Out-Null

function Step($t) { Write-Host "`n=== $t" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 0. предусловия
$drive = Get-PSDrive -Name ($Root.Substring(0, 1))
$freeMB = [math]::Round($drive.Free / 1MB)
if ($freeMB -lt 800) { throw "мало места на $($drive.Name): ($freeMB МБ, нужно ≥ 800)" }
if (-not $SkipFlutter) {
  $busy = Get-CimInstance Win32_Process -Filter "Name='dart.exe' OR Name='flutter.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pos-app' }
  if ($busy) { throw "pos-app занят другим процессом flutter/dart (PID $($busy.ProcessId -join ', ')): дождитесь его окончания" }
}

# ---------------------------------------------------------------- 1. бэкенд
if (-not $SkipBackend) {
  Step 'Бэкенд: build-backend.mjs'
  $a = @("$Web\backend\build-backend.mjs")
  if ($SkipTsc) { $a += '--skip-tsc' }
  & node @a
  if ($LASTEXITCODE -ne 0) { throw "build-backend.mjs: код $LASTEXITCODE" }
}

# ---------------------------------------------------------------- 2. Flutter, drift, sqlite3
if (-not $SkipFlutter) {
  Step 'Flutter: flutter build web (main_web_demo.dart)'
  $next = Join-Path $Build 'flutter.next'
  if (Test-Path $next) { Remove-Item -Recurse -Force $next }
  Push-Location (Join-Path $Root 'pos-app')
  try {
    & flutter build web --release -t lib/app/demo/main_web_demo.dart --base-href / --no-web-resources-cdn --pwa-strategy=none --dart-define-from-file=env/web_demo.json -o $next
    if ($LASTEXITCODE -ne 0) { throw "flutter build web: код $LASTEXITCODE" }
  } finally { Pop-Location }
  $cur = Join-Path $Build 'flutter'
  if (Test-Path $cur) { Remove-Item -Recurse -Force $cur }
  Move-Item $next $cur

  Step 'drift_worker.js (dart compile js) и sqlite3.wasm'
  $pub = if ($env:PUB_CACHE) { Join-Path $env:PUB_CACHE 'hosted\pub.dev' } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev' }
  $lock = Get-Content (Join-Path $Root 'pos-app\pubspec.lock') -Raw
  $driftVer = [regex]::Match($lock, '(?m)^  drift:\r?\n(?:    .*\r?\n)*?    version: "([^"]+)"').Groups[1].Value
  if (-not $driftVer) { throw 'версия drift не найдена в pos-app/pubspec.lock' }
  $driftDir = Join-Path $pub "drift-$driftVer"
  & dart compile js -O2 --no-source-maps "--packages=$Root\pos-app\.dart_tool\package_config.json" -o (Join-Path $Build 'drift_worker.js') (Join-Path $driftDir 'web\drift_worker.dart')
  if ($LASTEXITCODE -ne 0) { throw "dart compile js: код $LASTEXITCODE" }
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Build 'drift_worker.js.deps'), (Join-Path $Build 'drift_worker.js.map')
  Copy-Item -Force (Join-Path $driftDir 'extension\devtools\build\sqlite3.wasm') (Join-Path $Build 'sqlite3.wasm')
}

# ---------------------------------------------------------------- 3. сайт
Step 'Сайт: assemble-site.mjs'
& node "$Web\tools\assemble-site.mjs"
if ($LASTEXITCODE -ne 0) { throw "assemble-site.mjs: код $LASTEXITCODE" }

# ---------------------------------------------------------------- 4. проверки публикации
Step 'Проверки: check-site.mjs'
& node "$Web\tools\check-site.mjs"
$check = $LASTEXITCODE

# ---------------------------------------------------------------- 5. гигиена
$fb = Join-Path $Root 'pos-app\.dart_tool\flutter_build'
if (-not $SkipFlutter -and (Test-Path $fb)) { Remove-Item -Recurse -Force $fb }

if ($check -ne 0) { Write-Host "`ncheck-site: ЕСТЬ ОШИБКИ — не выкладывать" -ForegroundColor Red; exit $check }
Write-Host "`nГотово: demo/web/site. Выкладка (пользователь): cd demo/web; netlify deploy --no-build --dir site" -ForegroundColor Green
