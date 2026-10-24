# Сборка демо: сервер (pos-api/dist) и приложение Windows (release, профиль dev через мини-прокси, данные — в demo\data).
$ErrorActionPreference = 'Stop'
$demo = $PSScriptRoot
$root = Split-Path $demo -Parent
$tmp = Join-Path $demo '.tmp'
New-Item -ItemType Directory -Force $tmp, (Join-Path $demo 'data') | Out-Null
$env:TEMP = $tmp; $env:TMP = $tmp

# Профиль данных демо: каталог данных приложения внутри demo\data (только dev-сборка; в prod игнорируется)
$dataDir = (Join-Path $demo 'data') -replace '\\', '/'
@{ APP_DATA_DIR = $dataDir } | ConvertTo-Json | Out-File -Encoding ascii (Join-Path $demo 'demo_env.json')

Push-Location (Join-Path $root 'pos-api')
try { npm run build; if ($LASTEXITCODE) { throw 'npm run build failed' } } finally { Pop-Location }

Push-Location (Join-Path $root 'pos-app')
try {
  flutter build windows --release --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=../demo/demo_env.json
  if ($LASTEXITCODE) { throw 'flutter build windows failed' }
} finally { Pop-Location }

$out = Join-Path $demo 'app'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Copy-Item (Join-Path $root 'pos-app\build\windows\x64\runner\Release') $out -Recurse
Write-Host "Готово: $out\optomstroy.exe" -ForegroundColor Green
