<#
.SYNOPSIS
  Перенос учётных данных шлюза (1С и SMSPro) в secrets Optomstroy POS для тестового стенда (ADR-126, «живой» стенд). [Администратор]

.DESCRIPTION
  Шлюз заказчика ходит в HTTP-сервис 1С «ОС_API» (публикация uk_main_fr, /hs/os/api/v1) под пользователем из
  переменных среды Windows ONEC_API_USER и ONEC_API_PASSWORD, а SMS отправляет через SMSPro с SMSPRO_LOGIN,
  SMSPRO_PASSWORD и именем отправителя SMSPRO_SENDER. Этот скрипт читает их из реестра — переменные среды системы
  (HKLM), текущего пользователя (HKCU) и всех загруженных профилей (HKU\<SID>) — и записывает в
      <InstallRoot>\secrets\onec_user         (пользователь 1С)
      <InstallRoot>\secrets\onec_password     (пароль)
      <InstallRoot>\secrets\smspro_login      (логин SMSPro; если SMSPRO_LOGIN/SMSPRO_PASSWORD у шлюза есть)
      <InstallRoot>\secrets\smspro_password   (пароль SMSPro)
      <InstallRoot>\config\smspro-sender.txt  (имя отправителя — не секрет; нет SMSPRO_SENDER — значение шлюза по
                                               умолчанию OptStroy.KG)
  Права на файлы секретов: полный доступ — только Administrators и SYSTEM; чтение — NT SERVICE\OptomstroyApi и
  NT SERVICE\OptomstroyWorker (как у остальных секретов). Значения на экран и в журнал НЕ выводятся — только имена
  файлов и место, откуда они взяты. Чужие файлы не переписываются: если файл уже есть и отличается — отказ (замена
  только с -Force). Если у шлюза задана SMSPRO_TEST (SMSPro проверяет запрос, но SMS не отправляет) — об этом
  предупреждение (только имя переменной): у POS тестовый флаг свой (SMSPRO_TEST_FLAG), «живой» стенд ставит false.
  После скрипта — install.ps1 -Stand -StandOnecOsApi <адрес публикации> (ONEC_MODE=os_api) и, для «живого» стенда,
  -StandLive (настоящие SMS, заказы в 1С черновиками).

  SMSPro без -SmsPro: переносится, если у шлюза есть SMSPRO_LOGIN и SMSPRO_PASSWORD; нет — предупреждение (для
  -StandLive они нужны). С -SmsPro их отсутствие — отказ.

  Скрипт нужен только на тестовом стенде (install.ps1 -Stand). В рабочем контуре 1С подключается через HTTP-сервис
  расширения Optomstroy POS (ONEC_MODE=extension, секреты onec_hs_*), а SMSPro вводит человек заказчика при установке.

.PARAMETER Source
  Если переменные заданы в нескольких местах по-разному — часть имени нужного места
  (например HKLM, HKCU или SID / имя учётной записи из сообщения об отказе).

.PARAMETER SmsPro
  SMSPRO_LOGIN и SMSPRO_PASSWORD шлюза обязательны (без них — отказ).

.PARAMETER DevTest
  Проверочный прогон на ПК разработчика: без прав администратора, права NTFS не меняются (в журнал пишется, что
  пропущено). Только вместе с -SourceRegistryPath (тестовый ключ реестра вместо переменных среды Windows).

.EXAMPLE
  # PowerShell «от имени администратора» на сервере, где установлены шлюз и стенд:
  C:\OptomstroyPOS\current\scripts\import-onec-credentials.ps1 -InstallRoot C:\OptomstroyPOS -SmsPro
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$Source = '',
    [switch]$SmsPro,
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
    throw "в $($L.InstallJson) не тестовый стенд (stand = false): учётные данные шлюза — только для стенда (ADR-126); рабочий контур — onec_hs_* и SMSPro при установке (README, «Секреты»)"
}
$null = Initialize-OpsLog $L.Logs 'import-onec-credentials'
$failed = $true
$values = $null
try {
    if ($DevTest) { $sources = @([pscustomobject]@{ Name = "DevTest: $SourceRegistryPath"; Path = $SourceRegistryPath }) }
    else { $sources = @(Get-OpsEnvRegistrySources) }
    if ($Source) {
        $sources = @($sources | Where-Object { $_.Name -like "*$Source*" })
        if ($sources.Count -eq 0) { throw "-Source $Source`: такого места нет (места: HKLM, HKCU, HKU\<SID>)" }
    }
    Write-OpsLog ('где ищем переменные шлюза (ONEC_API_*, SMSPRO_*): ' + (@($sources | ForEach-Object { $_.Name }) -join '; '))
    $cred = Find-OpsOnecApiCredentials $sources
    Write-OpsLog ('ONEC_API_USER / ONEC_API_PASSWORD найдены в: ' + ($cred.Sources -join '; ')) 'OK'
    $values = [ordered]@{ onec_user = $cred.User; onec_password = $cred.Password }   # check-secrets: allow — в память, не в вывод
    $cred = $null

    # SMSPro шлюза (для «живого» стенда, install.ps1 -StandLive). Необязательная часть: без -SmsPro любой сбой здесь
    # (значения в разных местах реестра расходятся, недопустимое имя отправителя) — предупреждение и пропуск
    # smspro_* и smspro-sender.txt; перенос onec_user / onec_password от SMSPro не зависит.
    $sender = $null
    try {
        $sms = $null
        try { $sms = Find-OpsOnecApiCredentials $sources 'SMSPRO_LOGIN' 'SMSPRO_PASSWORD' }
        catch {
            if ($SmsPro -or $_.Exception.Message -match 'по-разному|только одна') { throw }
            Write-OpsLog 'SMSPRO_LOGIN / SMSPRO_PASSWORD шлюза не найдены — secrets\smspro_* не записаны (для install.ps1 -StandLive они нужны; обязательность — -SmsPro)' 'WARN'
        }
        if ($null -ne $sms) {
            Write-OpsLog ('SMSPRO_LOGIN / SMSPRO_PASSWORD найдены в: ' + ($sms.Sources -join '; ')) 'OK'
            $values['smspro_login'] = $sms.User
            $values['smspro_password'] = $sms.Password
            $sms = $null
            $snd = Find-OpsEnvRegistryValue $sources 'SMSPRO_SENDER'
            if ($null -ne $snd) {
                $sender = $snd.Value.Trim()
                Write-OpsLog ('SMSPRO_SENDER найдена в: ' + ($snd.Sources -join '; ')) 'OK'
            } else {
                $sender = $script:OpsSmsProGatewayDefaultSender
                Write-OpsLog "SMSPRO_SENDER у шлюза не задана — отправитель по умолчанию шлюза $sender" 'WARN'
            }
            if (-not $sender -or $sender -match '[\s#"''=]') { throw 'SMSPRO_SENDER шлюза: имя отправителя без пробелов, кавычек, # и = (так его не принять в config\api.env)' }
            # SMSPRO_TEST читается только ради предупреждения: расхождение мест — тоже лишь предупреждение.
            try {
                $tst = Find-OpsEnvRegistryValue $sources 'SMSPRO_TEST'
                if ($null -ne $tst) {
                    Write-OpsLog ('у шлюза задана SMSPRO_TEST (' + ($tst.Sources -join '; ') + '): при 1 шлюз SMS не отправляет — проверьте, что это не мешает; POS на «живом» стенде отправляет по-настоящему (SMSPRO_TEST_FLAG=false)') 'WARN'
                }
            } catch {
                Write-OpsLog ('SMSPRO_TEST шлюза: ' + $_.Exception.Message + ' — на перенос не влияет (POS эту переменную не читает)') 'WARN'
            }
        }
    } catch {
        if ($SmsPro) { throw }
        $values.Remove('smspro_login'); $values.Remove('smspro_password'); $sender = $null; $sms = $null
        Write-OpsLog ('SMSPro шлюза пропущен: ' + $_.Exception.Message + ' — secrets\smspro_* и config\' + $script:OpsSmsProSenderFile + ' не записаны; onec_user / onec_password переносятся (для install.ps1 -StandLive SMSPro нужен: исправьте и запустите с -SmsPro)') 'WARN'
    }

    $sidApi = $null; $sidWorker = $null
    if (-not $DevTest) { $sidApi = Get-OpsServiceSid 'OptomstroyApi'; $sidWorker = Get-OpsServiceSid 'OptomstroyWorker' }
    foreach ($name in @($values.Keys)) {
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
    if ($null -ne $sender) {
        $sf = Join-Path $L.Config $script:OpsSmsProSenderFile
        if (-not (Test-Path -LiteralPath $L.Config)) { New-Item -ItemType Directory -Force -Path $L.Config | Out-Null }
        $old = $null
        if (Test-Path -LiteralPath $sf) { $old = ([System.IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8)).Trim([char]0xFEFF, ' ', "`r", "`n", "`t") }
        if ($old -ceq $sender) { Write-OpsLog "config\$($script:OpsSmsProSenderFile): без изменений ($sender)" 'OK' }
        else {
            [System.IO.File]::WriteAllText($sf, $sender, (New-Object System.Text.UTF8Encoding($false)))
            Write-OpsLog "config\$($script:OpsSmsProSenderFile): отправитель SMS $sender (не секрет; install.ps1 -StandLive пишет его в SMSPRO_SENDER)" 'OK'
        }
    }
    $failed = $false
    $next = 'install.ps1 -Stand -StandOnecOsApi <адрес публикации 1С> (те же параметры, что при установке стенда) — включит ONEC_MODE=os_api и перезапустит службы'
    if ($null -ne $sender) { $next += '; «живой» стенд — ещё -StandLive -StandSmsPhones <номера>' }
    Write-OpsLog "готово. Дальше: $next" 'OK'
} catch {
    Write-OpsLog $_.Exception.Message 'ERROR'
} finally {
    $values = $null
}
if ($failed) { exit 1 }
exit 0
