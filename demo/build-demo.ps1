# Оптомстрой POS — сборка демо: сервер (pos-api\dist) и приложение Windows (release, профиль dev через мини-прокси
# http://127.0.0.1:8080/api/v1, данные приложения — в demo\data). Результат: demo\app\optomstroy.exe.
# Нужны: Node.js 24, Flutter (stable) с поддержкой Windows (Visual Studio с «Разработка классических приложений на C++»).
param(
  # Не удалять кэш сборки Flutter (pos-app\.dart_tool\flutter_build) после сборки — следующая сборка будет быстрее.
  [switch]$KeepFlutterBuildCache
)
$ErrorActionPreference = 'Stop'
$demo = $PSScriptRoot
$root = Split-Path $demo -Parent
. (Join-Path $demo 'demo-common.ps1')
Initialize-DemoConsole

$api = Join-Path $root 'pos-api'
$posApp = Join-Path $root 'pos-app'
$appExe = Join-Path $demo 'app\optomstroy.exe'
$tmp = Join-Path $demo '.tmp'
$dataDir = Join-Path $demo 'data'
$flutterBuildCache = Join-Path $posApp '.dart_tool\flutter_build'
New-Item -ItemType Directory -Force $tmp, $dataDir | Out-Null
$env:TEMP = $tmp; $env:TMP = $tmp

function Fail([string]$text) { Write-Host $text -ForegroundColor Red; exit 1 }

Write-Host 'Оптомстрой POS — сборка демо' -ForegroundColor DarkYellow
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'Не найден Node.js 24 (nodejs.org).' }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Fail 'Не найден Flutter (flutter.dev) — нужен для сборки приложения.' }

# Запущенное демо держит pos-api\dist и demo\app — останавливаем остатки прошлого запуска.
$left = Clear-DemoLeftovers $demo $appExe
if ($left.Killed -gt 0) { Write-Host "Остановлены процессы прошлого запуска демо: $($left.Killed)" -ForegroundColor Yellow }

# Место на диске: кэш сборки Flutter занимает гигабайты.
$drive = Get-PSDrive -Name ((Split-Path -Qualifier $root).TrimEnd(':'))
if ($drive.Free -lt 2GB -and (Test-Path $flutterBuildCache)) {
  Write-Host 'Свободно меньше 2 ГБ — удаляю кэш сборки Flutter (pos-app\.dart_tool\flutter_build)...' -ForegroundColor Yellow
  Remove-Item -LiteralPath $flutterBuildCache -Recurse -Force
}

# Профиль данных демо: каталог данных приложения внутри demo\data (только dev-сборка; в prod игнорируется).
# Путь абсолютный и вшивается в сборку: если папку демо перенести, сборку нужно повторить.
# UTF-8 без BOM — так --dart-define-from-file читает JSON и с путём на русском.
$envFile = Join-Path $demo 'demo_env.json'
$json = (@{ APP_DATA_DIR = ([IO.Path]::GetFullPath($dataDir) -replace '\\', '/') } | ConvertTo-Json)
[IO.File]::WriteAllText($envFile, $json, (New-Object System.Text.UTF8Encoding $false))

Write-Host '1/3  Сервер: npm run build (pos-api)' -ForegroundColor Cyan
Push-Location $api
try {
  if (-not (Test-Path 'node_modules')) {
    if ((Invoke-Native { npm ci }) -ne 0) { Fail 'npm ci завершился с ошибкой' }
  }
  if ((Invoke-Native { npm run build }) -ne 0) { Fail 'npm run build завершился с ошибкой' }
} finally { Pop-Location }

Write-Host '2/3  Приложение: flutter build windows --release (это 5–15 минут)' -ForegroundColor Cyan
Push-Location $posApp
try {
  $code = Invoke-Native { flutter build windows --release --dart-define-from-file=env/dev_proxy.json "--dart-define-from-file=$envFile" }
  if ($code -ne 0) { Fail 'flutter build windows завершился с ошибкой' }
} finally { Pop-Location }

Write-Host '3/3  Копирую приложение в demo\app' -ForegroundColor Cyan
$release = Join-Path $posApp 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'optomstroy.exe'))) { Fail "Нет результата сборки: $release\optomstroy.exe" }
$out = Join-Path $demo 'app'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Copy-Item $release $out -Recurse

if (-not $KeepFlutterBuildCache -and (Test-Path $flutterBuildCache)) {
  Remove-Item -LiteralPath $flutterBuildCache -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Готово: $out\optomstroy.exe" -ForegroundColor Green
Write-Host 'Запуск демо: двойной щелчок по demo\start-demo.cmd' -ForegroundColor Green
exit 0
