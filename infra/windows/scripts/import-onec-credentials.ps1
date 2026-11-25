<#
.SYNOPSIS
  Перенос учётных данных 1С шлюза в secrets Optomstroy POS для режима ОС_API на тестовом стенде (ADR-126). [Администратор]

.DESCRIPTION
  Шлюз заказчика ходит в HTTP-сервис 1С «ОС_API» (публикация uk_main_fr, /hs/os/api/v1) под пользователем из
  переменных среды Windows ONEC_API_USER и ONEC_API_PASSWORD. Этот скрипт читает их из реестра — переменные среды
  системы (HKLM), текущего пользователя (HKCU) и всех загруженных профилей (HKU\<SID>) — и записывает в
      <InstallRoot>\secrets\onec_user       (пользователь 1С)
      <InstallRoot>\secrets\onec_password   (пароль)
  Права на эти файлы: полный доступ — только Administrators и SYSTEM; чтение — NT SERVICE\OptomstroyApi и
  NT SERVICE\OptomstroyWorker (как у остальных секретов). Значения на экран и в журнал НЕ выводятся — только имена
  файлов и место, откуда они взяты. Чужие файлы не переписываются: если файл уже есть и отличается — отказ (замена
  только с -Force).
  После скрипта — install.ps1 -Stand -StandOnecOsApi <адрес публикации> (включает ONEC_MODE=os_api и перезапускает
  службы). В 1С ничего не пишется: режим os_api только читает каталог, цены и остатки.

  Скрипт нужен только на тестовом стенде (install.ps1 -Stand). В рабочем контуре 1С подключается через HTTP-сервис
  расширения Optomstroy POS (ONEC_MODE=extension, секреты onec_hs_*), этот скрипт там не используется.

.PARAMETER Source
  Если ONEC_API_USER / ONEC_API_PASSWORD заданы в нескольких местах по-разному — часть имени нужного места
  (например HKLM, HKCU или SID / имя учётной записи из сообщения об отказе).

.PARAMETER DevTest
  Проверочный прогон на ПК разработчика: без прав администратора, права NTFS не меняются (в журнал пишется, что
  пропущено). Только вместе с -SourceRegistryPath (тестовый ключ реестра вместо переменных среды Windows).

.EXAMPLE
  # PowerShell «от имени администратора» на сервере, где установлены шлюз и стенд:
  D:\Optomstroy\current\scripts\import-onec-credentials.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$Source = '',
    [switch]$Force,
    [switch]$DevTest,
    [string]$SourceRegistryPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }   # и отказы до журнала — в UTF-8

if ($SourceRegistryPath -and -not $DevTest) { throw '-SourceRegistryPath — только для проверочного прогона (-DevTest)' }
if ($DevTest -and -not $SourceRegistryPath) { throw '-DevTest: укажите -SourceRegistryPath (тестовый ключ реестра); переменные среды Windows в проверочном прогоне не читаются' }
if (-not $DevTest -and -not (Test-OpsAdmin)) { throw 'нужен PowerShell «от имени администратора» (запись в secrets и права NTFS)' }

$L = Get-OpsLayout $InstallRoot
if (-not (Test-Path -LiteralPath $L.Secrets -PathType Container)) {
    throw "нет папки $($L.Secrets): сначала установка стенда install.ps1 -Stand (без -StandOnecOsApi), затем этот скрипт"
}
$ij = Read-OpsJson $L.InstallJson
if ($null -ne $ij -and -not (($null -ne $ij.PSObject.Properties['stand']) -and [bool]$ij.stand)) {
    throw "в $($L.InstallJson) не тестовый стенд (stand = false): учётные данные шлюза — только для стенда (ADR-126); рабочий контур — onec_hs_* (README, «Секреты»)"
}
$null = Initialize-OpsLog $L.Logs 'import-onec-credentials'
$failed = $true
try {
    if ($DevTest) { $sources = @([pscustomobject]@{ Name = "DevTest: $SourceRegistryPath"; Path = $SourceRegistryPath }) }
    else { $sources = @(Get-OpsEnvRegistrySources) }
    if ($Source) {
        $sources = @($sources | Where-Object { $_.Name -like "*$Source*" })
        if ($sources.Count -eq 0) { throw "-Source $Source`: такого места нет (места: HKLM, HKCU, HKU\<SID>)" }
    }
    Write-OpsLog ('где ищем ONEC_API_USER / ONEC_API_PASSWORD шлюза: ' + (@($sources | ForEach-Object { $_.Name }) -join '; '))
    $cred = Find-OpsOnecApiCredentials $sources
    Write-OpsLog ('найдены в: ' + ($cred.Sources -join '; ')) 'OK'

    $values = @{ onec_user = $cred.User; onec_password = $cred.Password }   # check-secrets: allow — в память, не в вывод
    $cred = $null
    $sidApi = Get-OpsServiceSid 'OptomstroyApi'
    $sidWorker = Get-OpsServiceSid 'OptomstroyWorker'
    foreach ($name in $script:OpsOnecCredentialFiles) {
        $f = Join-Path $L.Secrets $name
        $res = Write-OpsSecretValue $f $values[$name] -Force:$Force
        $values[$name] = $null
        switch ($res) {
            'created' { Write-OpsLog "secrets\$name`: записан" 'OK' }
            'replaced' { Write-OpsLog "secrets\$name`: заменён (-Force)" 'WARN' }
            default { Write-OpsLog "secrets\$name`: уже совпадает со значением шлюза — без изменений" 'OK' }
        }
        if ($DevTest) { Write-OpsLog "DevTest: права NTFS secrets\$name не меняются" 'WARN'; continue }
        $o = & icacls.exe $f '/inheritance:r' '/grant:r' "*$($script:OpsSidAdministrators):(F)" "*$($script:OpsSidSystem):(F)" "*${sidApi}:(R)" "*${sidWorker}:(R)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw ("icacls secrets\$name`: код $LASTEXITCODE`n" + ($o | Out-String)) }
        Write-OpsLog "secrets\$name`: права — Administrators и SYSTEM (полный доступ), NT SERVICE\OptomstroyApi и \OptomstroyWorker (чтение)" 'OK'
    }
    $failed = $false
    Write-OpsLog 'готово. Дальше: install.ps1 -Stand -StandOnecOsApi <адрес публикации 1С> (те же параметры, что при установке стенда) — включит ONEC_MODE=os_api и перезапустит службы' 'OK'
} catch {
    Write-OpsLog $_.Exception.Message 'ERROR'
} finally {
    $values = $null
}
if ($failed) { exit 1 }
exit 0
