# Оптомстрой POS — запуск демо на этом компьютере.
# Поднимает локальный сервер (pos-api + pos-worker + встроенная PostgreSQL 17 + имитатор 1С на тестовых данных)
# и открывает приложение для Windows. Данные демо создаются заново при каждом запуске.
# Реальной 1С, SMS и оплаты нет: всё работает на тестовых данных.
param(
  [int]$Sku = 500,
  [ValidateSet('onec', 'none')][string]$QrProvider = 'onec',
  [switch]$NoApp
)
$ErrorActionPreference = 'Stop'
$demo = $PSScriptRoot
$root = Split-Path $demo -Parent
$api = Join-Path $root 'pos-api'
$app = Join-Path $demo 'app\optomstroy.exe'
$tmp = Join-Path $demo '.tmp'
$logs = Join-Path $demo 'logs'
New-Item -ItemType Directory -Force $tmp, $logs, (Join-Path $demo 'data') | Out-Null

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

Say ''
Say '  ОПТОМСТРОЙ POS — демо' 'DarkYellow'
Say '  Тестовые данные, без реальной 1С, SMS и оплаты.' 'Gray'
Say ''

# 1. Проверки
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Say 'Не найден Node.js 24 — установите его с nodejs.org и запустите снова.' 'Red'; exit 1 }
if (-not (Test-Path (Join-Path $api 'node_modules'))) { Say 'Нет зависимостей сервера (pos-api\node_modules). Выполните в pos-api: npm ci' 'Red'; exit 1 }
if (-not (Test-Path (Join-Path $api 'dist\main.js'))) {
  Say 'Сборка сервера отсутствует — собираю (npm run build)...' 'Yellow'
  Push-Location $api; try { npm run build | Out-File -Encoding utf8 (Join-Path $logs 'build.log') } finally { Pop-Location }
}
if (-not $NoApp -and -not (Test-Path $app)) { Say "Нет приложения: $app. Соберите демо: demo\build-demo.ps1" 'Red'; exit 1 }

# 2. Сервер
$env:TEMP = $tmp; $env:TMP = $tmp
$ready = Join-Path $tmp 'stack.ready'
Remove-Item $ready -ErrorAction SilentlyContinue
$stackLog = Join-Path $logs 'server.log'
$stackErr = Join-Path $logs 'server.err.log'
Say "1/2  Запускаю сервер и загружаю демо-данные ($Sku товаров, клиенты, долги)... это 1–3 минуты" 'Cyan'
$stack = Start-Process -FilePath $node.Source -WorkingDirectory $api -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $stackLog -RedirectStandardError $stackErr `
  -ArgumentList @('scripts/local-stack.mjs', 'serve', '--cashier-fixtures', "--catalog-fixtures=$Sku", '--qr-provider', $QrProvider, '--qr-paid-after-polls', '4', '--ready-file', $ready)

$deadline = (Get-Date).AddMinutes(8)
while (-not (Test-Path $ready)) {
  if ($stack.HasExited) { Say "Сервер остановился с ошибкой (код $($stack.ExitCode)). Журнал: $stackErr" 'Red'; exit 1 }
  if ((Get-Date) -gt $deadline) { Say "Сервер не поднялся за 8 минут. Журнал: $stackLog" 'Red'; Stop-Process -Id $stack.Id -Force; exit 1 }
  Start-Sleep -Seconds 2
  Write-Host '.' -NoNewline
}
Say ''
Say '     Сервер готов: http://127.0.0.1:8080/api/v1' 'Green'

function Stop-Stack {
  if ($stack -and -not $stack.HasExited) {
    # останавливаем дерево процессов стека (api, worker, имитатор 1С, postgres)
    & taskkill.exe /PID $stack.Id /T /F 2>$null | Out-Null
  }
}

Say ''
Say '  Вход в приложение: номер телефона, затем код из SMS — всегда 246810 (тестовый режим).' 'White'
Say '    +996 777 000 901  администратор (PIN не нужен при первом входе)' 'Gray'
Say '    +996 777 000 906  кассир            +996 777 000 907  старший продавец' 'Gray'
Say '    +996 777 000 902  продавец (приглашение)   +996 777 000 909  руководитель' 'Gray'
Say '    +996 777 000 905  покупатель        +996 700 123 456  покупатель с карточкой 1С' 'Gray'
Say '  Сотрудник при первом входе задаёт PIN (любой, например 1357).' 'Gray'
Say '  Оплата по QR в демо подтверждается имитатором 1С сама примерно через 20 секунд.' 'Gray'
Say ''

try {
  if ($NoApp) {
    Say 'Режим без приложения: сервер работает, нажмите Enter для остановки.' 'Yellow'
    [void][Console]::ReadLine()
  } else {
    Say '2/2  Открываю приложение. Закройте окно приложения, чтобы остановить демо.' 'Cyan'
    $p = Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -PassThru
    $p.WaitForExit()
  }
} finally {
  Say 'Останавливаю сервер...' 'Gray'
  Stop-Stack
  Say 'Демо остановлено.' 'Green'
}
