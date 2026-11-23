<#
.SYNOPSIS
  Приглашение первому администратору системы (dist\admin\bootstrap\first-admin.cli.js). [Администратор]

.DESCRIPTION
  Команда читает полную конфигурацию API (config\api.env и секреты), поэтому её выполняет администратор сервера.
  Окружение процесса — только системные переменные и api.env (как у службы OptomstroyApi).
  Коды выхода: 0 — приглашение создано; 2 — неверные данные; 3 — номер занят / есть другое приглашение; иначе — ошибка.

.EXAMPLE
  .\first-admin.ps1 -Phone +996555000000 -Name "Фамилия Имя Отчество"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Phone,
    [Parameter(Mandatory = $true)][string]$Name,
    [ValidateRange(0, 30)][int]$Days = 0,
    [string]$InstallRoot = 'D:\Optomstroy',
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')
$L = Get-OpsLayout $InstallRoot
$ij = Read-OpsJson $L.InstallJson
if ($null -eq $ij) { Write-Host "нет $($L.InstallJson)"; exit 2 }
if (-not $DevTest -and -not (Test-OpsAdmin)) { Write-Host 'нужен PowerShell «от имени администратора»'; exit 2 }
$null = Initialize-OpsLog $L.Logs 'first-admin'
# Тестовый контур (SMS_PROVIDER=fake, AUTH_OTP_TEST_MODE=true): входят только номера AUTH_OTP_TEST_PHONES.
# Запрос кода на другой номер не проходит (в схеме staging нет dev_outbox) и на SMSPRO_CB_OPEN_MINUTES закрывает
# выдачу кодов всем, в том числе тестовым номерам (503 SMS_PROVIDER_ERROR).
if ([string]$ij.contour -eq 'test') {
    $tp = ''
    try { $envApi = Read-OpsEnvTemplate (Join-Path $L.Config 'api.env'); if ($envApi.Contains('AUTH_OTP_TEST_PHONES')) { $tp = [string]$envApi['AUTH_OTP_TEST_PHONES'] } } catch { $tp = '' }
    $list = @($tp.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list -notcontains $Phone) {
        Write-OpsLog "тестовый контур: номера $Phone нет в AUTH_OTP_TEST_PHONES (config\api.env) — войти с ним нельзя, а запрос кода на него на SMSPRO_CB_OPEN_MINUTES мин закроет вход всем. Добавьте: install.ps1 с теми же параметрами и -TestPhones '$(@($list + $Phone) -join ',')' (службы перезапустятся сами)" 'WARN'
    }
}
$a = @("--env-file=$(Join-Path $L.Config 'api.env')", 'dist\admin\bootstrap\first-admin.cli.js', '--phone', $Phone, '--name', $Name)
if ($Days -gt 0) { $a += @('--days', [string]$Days) }
$r = Invoke-OpsProcess -FilePath (Join-Path $L.Current 'node\node.exe') -ArgumentList $a -WorkingDirectory (Join-Path (Get-OpsJunctionTarget $L.Current) 'api') -CleanEnvironment -Environment @{ APP_ENV = [string]$ij.appEnv }
switch ($r.Code) {
    0 { Write-OpsLog 'приглашение создано: вход — по SMS-коду на этот номер, затем установка PIN' 'OK' }
    2 { Write-OpsLog 'неверные данные (номер КР +996…, ФИО 2…150 символов, срок 1…30 дней)' 'WARN' }
    3 { Write-OpsLog 'отклонено: номер занят или действует приглашение на другой номер' 'WARN' }
    default { Write-OpsLog "ошибка (код $($r.Code)); повтор безопасен" 'ERROR' }
}
exit $r.Code
