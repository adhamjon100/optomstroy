# Запуск pos-app на Windows с профилем dev (RM-C-009). Перед запуском поднимите pos-api:
#   cd ..\pos-api; npm run build; node scripts/local-stack.mjs serve
param([string]$Profile = 'dev', [string]$Device = 'windows')
Set-Location (Join-Path $PSScriptRoot '..')
# env/local.json (вне git) — значения машины разработки, например APP_DATA_DIR (env/README.md).
$Defines = @("--dart-define-from-file=env/$Profile.json")
if (Test-Path 'env/local.json') { $Defines += '--dart-define-from-file=env/local.json' }
flutter run -d $Device @Defines
