<#
.SYNOPSIS
  Проверки скриптов установки для Windows (infra/windows/scripts, infra/windows/release) без прав администратора.

.DESCRIPTION
  1. Скрипты .ps1: разбор парсером PowerShell без ошибок; UTF-8 с BOM у файлов с кириллицей; node --check ops-tool.mjs.
  2. SHA256 пакета: SHA256SUMS.txt из папки установки (incoming) не принимается; -Sha256 и файл вне папки — да.
  3. InstallRoot/BackupRoot: корень тома и чужая непустая папка — отказ; новая, пустая, наша (имена, отметка) — да.
  4. SID служб NT SERVICE\Optomstroy* (Get-OpsServiceSid) совпадает с sc.exe showsid.
  5. ops-tool: gen-secrets --no-new-peppers (код 3), secrets-export (OPTBK1, повтор без изменений — без новой копии),
     расшифровка pos-backup.mjs decrypt тестовым ключом, secrets-import (совпадение, конфликт — код 1).
  6. New-ReleaseZip.ps1: имена записей через «/», пустая папка, распаковка .NET даёт те же файлы.
  7. Новые имена настроек: Get-OpsEnvTemplatePairs + Write-OpsEnvFile дописывают только отсутствующие имена.
     7a. Профиль тестового стенда (stand.env.example, -Stand; ADR-125); OTP_HMAC_SECRET_FILE у api и worker (ADR-124).
     7b. Стенд с 1С через ОС_API шлюза (ADR-126): адрес публикации, api.env (os_api), повторный запуск, отказ без
         -Stand, install.ps1 -WhatIf, import-onec-credentials.ps1 (тестовый ключ HKCU\Software\OptomstroyTests,
         значения не на экране и не в журнале); откат при os_api на версию без режима — отказ (rollback.ps1).
  8. Статические проверки прав: data\audit-anchors пишет только OptomstroyWorker; sc sdset posdeploy — только Api и
     Worker; update.ps1 возвращает базу из копии, если migrate запускался; uninstall.ps1 не удаляет программу после ошибок.
  Временные данные — .tmp\wn-scripts (удаляются).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\scripts.tests.ps1
#>
[CmdletBinding()]
param([string]$NodeExe)

$ErrorActionPreference = 'Stop'
$win = Split-Path $PSScriptRoot -Parent
$repo = Split-Path (Split-Path $win -Parent) -Parent
$failed = 0
function Report([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Host "  ok   $Text" -ForegroundColor Green } else { Write-Host "  FAIL $Text" -ForegroundColor Red; $script:failed++ }
}
if (-not $NodeExe) {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { Write-Host 'node.exe не найден (укажите -NodeExe)' -ForegroundColor Red; exit 1 }
    $NodeExe = $cmd.Source
}
function Invoke-Node([string[]]$NodeArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $o = & $NodeExe @NodeArgs 2>&1 | ForEach-Object { "$_" }
        return @{ Code = $LASTEXITCODE; Out = @($o) }
    } finally { $ErrorActionPreference = $old }
}
function Get-LastJson($Lines) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) { if ($Lines[$i].Trim().StartsWith('{')) { return ($Lines[$i] | ConvertFrom-Json) } }
    return $null
}

$tmp = Join-Path $repo '.tmp\wn-scripts\t'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$opsTool = Join-Path $win 'scripts\ops-tool.mjs'

try {
    Write-Host '== 1. Скрипты'
    $files = @(Get-ChildItem -LiteralPath (Join-Path $win 'scripts') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $win 'release') -Filter '*.ps1') + @(Get-Item -LiteralPath $PSCommandPath)
    foreach ($f in $files) {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        Report ($errs.Count -eq 0) "парсер: $($f.Name)$(if ($errs.Count) { ' — ' + (($errs | ForEach-Object { "строка $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') })"
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasCyr = [Text.Encoding]::UTF8.GetString($bytes) -match '[Ѐ-ӿ]'
        Report ((-not $hasCyr) -or $hasBom) "UTF-8 с BOM (кириллица): $($f.Name)"
    }
    $r = Invoke-Node @('--check', $opsTool)
    Report ($r.Code -eq 0) 'node --check ops-tool.mjs'

    . (Join-Path $win 'scripts\OptomstroyCommon.ps1')

    Write-Host '== 2. SHA256 пакета'
    $inst = Join-Path $tmp 'root'
    New-Item -ItemType Directory -Force -Path (Join-Path $inst 'incoming'), (Join-Path $tmp 'admin') | Out-Null
    $hex = 'ab' * 32
    foreach ($d in @((Join-Path $inst 'incoming'), (Join-Path $tmp 'admin'))) {
        [IO.File]::WriteAllText((Join-Path $d 'pkg.zip'), 'x')
        [IO.File]::WriteAllText((Join-Path $d 'SHA256SUMS.txt'), "$hex  pkg.zip`n")
    }
    $msg = ''
    try { $null = Get-OpsExpectedZipHash (Join-Path $inst 'incoming\pkg.zip') '' '' $inst } catch { $msg = $_.Exception.Message }
    Report ($msg -match 'нельзя брать') 'SHA256SUMS.txt рядом с пакетом в incoming — отказ'
    $msg = ''
    try { $null = Get-OpsExpectedZipHash (Join-Path $tmp 'admin\pkg.zip') '' (Join-Path $inst 'incoming\SHA256SUMS.txt') $inst } catch { $msg = $_.Exception.Message }
    Report ($msg -match 'нельзя брать') '-Sha256Sums из папки установки — отказ'
    Report ((Get-OpsExpectedZipHash (Join-Path $inst 'incoming\pkg.zip') ('CD' * 32) '' $inst) -eq ('cd' * 32)) '-Sha256 для пакета из incoming — принимается'
    Report ((Get-OpsExpectedZipHash (Join-Path $tmp 'admin\pkg.zip') '' '' $inst) -eq $hex) 'SHA256SUMS.txt рядом с пакетом вне папки установки — принимается'
    Report ((Get-OpsExpectedZipHash (Join-Path $inst 'INCOMING\pkg.zip') ('cd' * 32) '' $inst.ToUpperInvariant()) -eq ('cd' * 32)) 'регистр пути не мешает -Sha256'
    $msg = ''
    try { $null = Get-OpsExpectedZipHash (Join-Path $inst 'INCOMING\pkg.zip') '' '' $inst.ToUpperInvariant() } catch { $msg = $_.Exception.Message }
    Report ($msg -match 'нельзя брать') 'другой регистр пути incoming — тоже отказ'

    Write-Host '== 3. Отдельные папки InstallRoot / BackupRoot'
    $drive = [IO.Path]::GetPathRoot($tmp)
    Report ($null -ne (Test-OpsDedicatedRoot $drive 'backup')) "корень тома $drive — отказ"
    Report ($null -eq (Test-OpsDedicatedRoot (Join-Path $tmp 'nope') 'install')) 'несуществующая папка — да'
    $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Force -Path $empty | Out-Null
    Report ($null -eq (Test-OpsDedicatedRoot $empty 'backup')) 'пустая папка — да'
    $shared = Join-Path $tmp 'shared'; New-Item -ItemType Directory -Force -Path (Join-Path $shared 'dumps') | Out-Null
    [IO.File]::WriteAllText((Join-Path $shared 'UT11_backup_2026.bak'), 'x')
    $why = Test-OpsDedicatedRoot $shared 'backup'
    Report ($null -ne $why -and $why -match 'UT11_backup_2026.bak') 'чужая непустая папка (файл копии 1С) — отказ с именем файла'
    $ours = Join-Path $tmp 'ours'; foreach ($n in 'releases', 'config', 'logs', 'incoming') { New-Item -ItemType Directory -Force -Path (Join-Path $ours $n) | Out-Null }
    Report ($null -eq (Test-OpsDedicatedRoot $ours 'install')) 'папка только с нашими именами — да'
    Set-OpsRootMarker $shared 'backup'
    Report ($null -eq (Test-OpsDedicatedRoot $shared 'backup')) 'папка с отметкой .optomstroy-root — да'
    Report ((Test-OpsPathUnder (Join-Path $inst 'incoming\a.txt') $inst) -and -not (Test-OpsPathUnder "$inst-other\a.txt" $inst)) 'Test-OpsPathUnder: соседняя папка с тем же префиксом не считается вложенной'

    Write-Host '== 4. SID служб'
    foreach ($n in $script:OpsServiceNames) {
        # Имена полей sc.exe переводятся (в русской консоли не «SERVICE SID») — берём сам SID службы.
        $sc = (& sc.exe showsid $n | Select-String 'S-1-5-80-[\d-]+' | ForEach-Object { $_.Matches[0].Value } | Select-Object -First 1)
        Report ((Get-OpsServiceSid $n) -eq $sc) "Get-OpsServiceSid $n = sc showsid"
    }

    Write-Host '== 5. Секреты: перцы при восстановлении, защищённая копия'
    $sec = Join-Path $tmp 'secrets'; New-Item -ItemType Directory -Force -Path $sec | Out-Null
    $g = Invoke-Node @($opsTool, 'gen-secrets', '--dir', $sec, '--kid', 'test-1', '--db', 'optomstroy', '--port', '55449', '--no-new-peppers')
    Report ($g.Code -eq 3 -and -not (Test-Path (Join-Path $sec 'pin_pepper'))) 'gen-secrets --no-new-peppers без перцев — код 3, ничего не создано'
    $g = Invoke-Node @($opsTool, 'gen-secrets', '--dir', $sec, '--kid', 'test-1', '--db', 'optomstroy', '--port', '55449')
    Report ($g.Code -eq 0 -and (Test-Path (Join-Path $sec 'pin_pepper'))) 'gen-secrets — код 0, секреты созданы'
    $g = Invoke-Node @($opsTool, 'gen-secrets', '--dir', $sec, '--kid', 'test-1', '--db', 'optomstroy', '--port', '55449', '--no-new-peppers')
    Report ($g.Code -eq 0) 'gen-secrets --no-new-peppers при имеющихся перцах — код 0'
    $keyDir = Join-Path $tmp 'key'
    $k = Invoke-Node @((Join-Path $win 'backup\pos-backup.mjs'), 'keygen', '--out', $keyDir, '--no-passphrase')
    Report ($k.Code -eq 0) 'тестовая пара ключей (keygen --no-passphrase)'
    $exp = Join-Path $tmp 'bk\dumps\secrets'
    $e1 = Invoke-Node @($opsTool, 'secrets-export', '--dir', $sec, '--public', (Join-Path $keyDir 'backup-public.pem'), '--out-dir', $exp)
    $j1 = Get-LastJson $e1.Out
    Report ($e1.Code -eq 0 -and $null -ne $j1 -and $j1.exported -and (Test-Path -LiteralPath $j1.exported)) 'secrets-export — копия OPTBK1 создана'
    $plainLeak = $false
    $pin = [IO.File]::ReadAllText((Join-Path $sec 'pin_pepper')).Trim()
    if ($j1 -and $j1.exported) { $plainLeak = ([IO.File]::ReadAllText($j1.exported, [Text.Encoding]::GetEncoding(28591)) -match [regex]::Escape($pin)) }
    Report (-not $plainLeak) 'в копии нет открытого значения pin_pepper'
    Report (-not (@($e1.Out) -join "`n").Contains($pin)) 'вывод secrets-export без значений секретов'
    $e2 = Invoke-Node @($opsTool, 'secrets-export', '--dir', $sec, '--public', (Join-Path $keyDir 'backup-public.pem'), '--out-dir', $exp)
    $j2 = Get-LastJson $e2.Out
    Report ($e2.Code -eq 0 -and $j2.unchanged -eq $true -and @(Get-ChildItem -LiteralPath $exp -Filter '*.optbk').Count -eq 1) 'повтор без изменений — новой копии нет'
    $mark = [IO.File]::ReadAllText((Join-Path $exp 'last-export.json'))
    Report (-not $mark.Contains($pin)) 'last-export.json без значений секретов'
    $dec = Join-Path $tmp 'secrets.json'
    $d = Invoke-Node @((Join-Path $win 'backup\pos-backup.mjs'), 'decrypt', '--key', (Join-Path $keyDir 'backup-private.pem'), $j1.exported, $dec)
    Report ($d.Code -eq 0 -and (Test-Path -LiteralPath $dec)) 'расшифровка копии закрытым ключом (pos-backup.mjs decrypt)'
    $sec2 = Join-Path $tmp 'secrets2'; New-Item -ItemType Directory -Force -Path $sec2 | Out-Null
    $i1 = Invoke-Node @($opsTool, 'secrets-import', '--in', $dec, '--dir', $sec2)
    $same = $true
    foreach ($f in @(Get-ChildItem -LiteralPath $sec -File)) {
        $p2 = Join-Path $sec2 $f.Name
        if (-not (Test-Path -LiteralPath $p2) -or (Get-FileHash -LiteralPath $p2).Hash -ne (Get-FileHash -LiteralPath $f.FullName).Hash) { $same = $false }
    }
    Report ($i1.Code -eq 0 -and $same) 'secrets-import в пустую папку — все файлы побайтно совпадают'
    $i2 = Invoke-Node @($opsTool, 'secrets-import', '--in', $dec, '--dir', $sec2)
    Report ($i2.Code -eq 0 -and @((Get-LastJson $i2.Out).written).Count -eq 0) 'повторный secrets-import — ничего не переписано'
    [IO.File]::WriteAllText((Join-Path $sec2 'pin_pepper'), 'другое значение')
    $i3 = Invoke-Node @($opsTool, 'secrets-import', '--in', $dec, '--dir', $sec2)
    Report ($i3.Code -eq 1 -and [IO.File]::ReadAllText((Join-Path $sec2 'pin_pepper')) -eq 'другое значение') 'конфликт без --overwrite — код 1, файл не заменён'
    [IO.File]::WriteAllText((Join-Path $sec 'smspro_login'), 'login-test')   # check-secrets: allow — тестовое значение
    (Get-Item -LiteralPath (Join-Path $sec 'smspro_login')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
    Start-Sleep -Seconds 1
    $e3 = Invoke-Node @($opsTool, 'secrets-export', '--dir', $sec, '--public', (Join-Path $keyDir 'backup-public.pem'), '--out-dir', $exp)
    Report ($e3.Code -eq 0 -and -not (Get-LastJson $e3.Out).unchanged -and @(Get-ChildItem -LiteralPath $exp -Filter '*.optbk').Count -eq 2) 'новый файл в secrets — новая копия, прежняя остаётся'

    Write-Host '== 6. Zip пакета (New-ReleaseZip.ps1)'
    $src = Join-Path $tmp 'zsrc'
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'apache'), (Join-Path $src 'api\dist\admin'), (Join-Path $src 'empty\inner') | Out-Null
    [IO.File]::WriteAllText((Join-Path $src 'release.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $src 'apache\apache-common.ps1'), '# a')
    [IO.File]::WriteAllText((Join-Path $src 'api\dist\admin\admin.module.js'), 'x')
    $zip = Join-Path $tmp 'p.zip'
    $n = & (Join-Path $win 'release\New-ReleaseZip.ps1') -SourceDir $src -ZipPath $zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $names = @($za.Entries | ForEach-Object { $_.FullName }) } finally { $za.Dispose() }
    Report ([int]$n -eq 3) "записей-файлов 3 ($n)"
    Report (@($names | Where-Object { $_.Contains('\') }).Count -eq 0) 'в именах записей нет «\»'
    Report ($names -contains 'apache/apache-common.ps1' -and $names -contains 'api/dist/admin/admin.module.js' -and $names -contains 'empty/inner/') "имена через «/», пустая папка — запись «empty/inner/» ($($names -join ', '))"
    $ext = Join-Path $tmp 'zext'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ext)
    Report ((Test-Path (Join-Path $ext 'api\dist\admin\admin.module.js')) -and (Test-Path (Join-Path $ext 'empty\inner') -PathType Container)) 'распаковка .NET (как install.ps1) — та же раскладка'

    Write-Host '== 7. Новые имена настроек при обновлении'
    $fakeRel = Join-Path $tmp 'rel'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeRel 'scripts\templates') | Out-Null
    Copy-Item (Join-Path $repo 'infra\env\prod.env.example') (Join-Path $fakeRel 'scripts\templates\prod.env.example')
    Copy-Item (Join-Path $repo 'infra\env\test.env.example') (Join-Path $fakeRel 'scripts\templates\test.env.example')
    $tpl = Get-OpsEnvTemplatePairs $fakeRel 'prod'
    Report ((-not $tpl.Contains('API_TAG')) -and (-not $tpl.Contains('POSTGRES_DB')) -and $tpl.Contains('LOG_LEVEL')) 'шаблон без имён compose (API_TAG, POSTGRES_DB), с LOG_LEVEL'
    $envFile = Join-Path $tmp 'api.env'
    [IO.File]::WriteAllText($envFile, "LOG_LEVEL=warn`r`nAPP_ENV=prod`r`n")
    $pairs = New-Object System.Collections.Specialized.OrderedDictionary
    $have = Read-OpsEnvTemplate $envFile
    foreach ($k in $tpl.Keys) { if ([string]$tpl[$k] -ne '' -and -not $have.Contains($k)) { $pairs[$k] = $tpl[$k] } }
    $added = Write-OpsEnvFile $envFile '' $pairs
    $after = Read-OpsEnvTemplate $envFile
    Report ($after['LOG_LEVEL'] -eq 'warn' -and @($added) -notcontains 'LOG_LEVEL' -and @($added) -contains 'TZ') 'существующее значение не переписано, новое имя (TZ) дописано'
    Report (-not $after.Contains('PUBLIC_BASE_URL')) 'пустые значения шаблона не дописываются'

    Write-Host '== 7a. Профиль тестового стенда (install.ps1 -Stand, ADR-125) и секрет OTP у api и worker (ADR-124)'
    Copy-Item (Join-Path $repo 'infra\env\stand.env.example') (Join-Path $fakeRel 'scripts\templates\stand.env.example')
    $st = Get-OpsEnvTemplatePairs $fakeRel 'test' -Stand
    Report ($st['APP_ENV'] -eq 'staging' -and $st['ONEC_MODE'] -eq 'fixtures' -and $st['QR_PROVIDER'] -eq 'bank' -and $st['BANK_QR_ADAPTER'] -eq 'sandbox') "стенд: APP_ENV=staging, ONEC_MODE=fixtures, QR_PROVIDER=bank, BANK_QR_ADAPTER=sandbox"
    Report ($st['SMS_PROVIDER'] -eq 'fake' -and $st['AUTH_OTP_TEST_MODE'] -eq 'true' -and -not [string]$st['AUTH_OTP_TEST_CODE'] -and -not [string]$st['ONEC_BASE_URL'] -and $st['SMSPRO_TEST_FLAG'] -eq 'true')'стенд: SMS_PROVIDER=fake, тестовый режим; код не в шаблоне (создаёт install.ps1), адреса 1С нет'
    $stPhones = @(([string]$st['AUTH_OTP_TEST_PHONES']).Split(',') | ForEach-Object { $_.Trim() })
    Report ($stPhones.Count -gt 0 -and @($stPhones | Where-Object { $_ -notmatch '^\+99670000000\d$' }).Count -eq 0) "стенд: только вымышленные номера +99670000000x ($($stPhones -join ','))"
    Report ($st['PUBLIC_BASE_URL'] -eq 'https://api-test.37.114.51.144.sslip.io') 'стенд: адрес https://api-test.37.114.51.144.sslip.io'
    Report (@($st.Keys | Where-Object { $_ -like '*_FILE' -or $_ -like 'SMSPRO_LOGIN*' -or $_ -like 'SMSPRO_PASSWORD*' }).Count -eq 0) 'стенд: в шаблоне нет секретов и указателей *_FILE'
    $threw = $false; try { $null = Get-OpsEnvTemplatePairs $fakeRel 'prod' -Stand } catch { $threw = $true }
    Report $threw 'стенд в контуре prod — отказ'
    $inst3 = [IO.File]::ReadAllText((Join-Path $win 'scripts\install.ps1'))
    Report ($inst3.Contains("`$common = [ordered]@{ DATABASE_URL_FILE = (& `$sec 'database_url'); JWT_PUBLIC_KEY_FILE = (& `$sec 'jwt_public.json'); OTP_HMAC_SECRET_FILE = (& `$sec 'otp_pepper') }")) 'install.ps1: OTP_HMAC_SECRET_FILE — общий для api.env и worker.env, один файл secrets\otp_pepper (EQ-AUTH-08)'
    Report ($inst3 -match "\`$apiSecrets = @\([^)]*'otp_pepper'" -and $inst3 -match "\`$workerSecrets = @\([^)]*'otp_pepper'") 'install.ps1: чтение otp_pepper — у OptomstroyApi и OptomstroyWorker'
    Report ($inst3.Contains("-eq '246810'")) 'install.ps1: случайный тестовый код стенда не равен коду демо 246810'
    $br = [IO.File]::ReadAllText((Join-Path $win 'release\build-release.ps1'))
    Report ($br.Contains("infra\env\stand.env.example") -and $br.Contains("'contracts\onec\fixtures'")) 'build-release.ps1: в пакете профиль стенда и фикстуры 1С (ONEC_MODE=fixtures)'

    Write-Host '== 7b. Стенд: 1С через ОС_API шлюза (install.ps1 -StandOnecOsApi, import-onec-credentials.ps1; ADR-126)'
    Report ((ConvertTo-OpsOsApiBaseUrl 'http://localhost/uk_main_fr/') -eq 'http://localhost/uk_main_fr') 'адрес публикации http://localhost/uk_main_fr/ — без «/» в конце'
    Report ((ConvertTo-OpsOsApiBaseUrl 'https://1c.example.kg/ut') -eq 'https://1c.example.kg/ut' -and (ConvertTo-OpsOsApiBaseUrl 'http://127.0.0.1:8080/uk') -eq 'http://127.0.0.1:8080/uk') 'https:// — любой сервер; http:// — 127.0.0.1 с портом'
    foreach ($bad in @('http://10.0.0.5/uk_main_fr', 'http://localhost/uk_main_fr/hs/os/api/v1', 'http://localhost', 'http://u:p@localhost/uk', 'http://localhost/uk?x=1', 'ftp://localhost/uk')) {
        $threw = $false; try { $null = ConvertTo-OpsOsApiBaseUrl $bad } catch { $threw = $true }
        Report $threw "адрес $bad — отказ"
    }
    $oa = Get-OpsOsApiEnvPairs 'http://localhost/uk_main_fr'
    $stOs = Get-OpsEnvTemplatePairs $fakeRel 'test' -Stand
    foreach ($k in $oa.Keys) { $stOs[$k] = $oa[$k] }
    foreach ($k in @($stOs.Keys | Where-Object { [string]$stOs[$_] -eq '' })) { $stOs.Remove($k) }
    $osEnv = Join-Path $tmp 'osapi-api.env'
    $null = Write-OpsEnvFile $osEnv 'тест' $stOs
    $osR = Read-OpsEnvTemplate $osEnv
    Report ($osR['ONEC_MODE'] -eq 'os_api' -and $osR['ONEC_BASE_URL'] -eq 'http://localhost/uk_main_fr' -and $osR['ONEC_OSAPI_PATH'] -eq 'hs/os/api/v1') 'новый api.env: ONEC_MODE=os_api, ONEC_BASE_URL=корень публикации, ONEC_OSAPI_PATH=hs/os/api/v1'
    Report ($osR['APP_ENV'] -eq 'staging' -and $osR['SMS_PROVIDER'] -eq 'fake' -and $osR['QR_PROVIDER'] -eq 'bank' -and $osR['ONEC_INBOUND_ENABLED'] -eq 'false') 'остальной профиль стенда не меняется (staging, SMS fake, QR песочница, без входящих из 1С)'
    Report (-not $osR.Contains('ONEC_HS_PATH') -and -not $osR.Contains('ONEC_USER') -and -not $osR.Contains('ONEC_PASSWORD')) 'в api.env нет значений входа в 1С (только *_FILE пишет install.ps1)'
    # Откат при os_api (rollback.ps1): файлы с ONEC_MODE=os_api и признак поддержки режима в релизе.
    $rbRoot = Join-Path $tmp 'rb-osapi'
    $rbL = @{ Config = (Join-Path $rbRoot 'config') }
    New-Item -ItemType Directory -Force -Path $rbL.Config | Out-Null
    [IO.File]::WriteAllText((Join-Path $rbL.Config 'api.env'), "ONEC_MODE=os_api`r`nONEC_BASE_URL=http://localhost/uk`r`n")
    [IO.File]::WriteAllText((Join-Path $rbL.Config 'worker.env'), "ONEC_MODE=fixtures`r`n")
    $rbHit = Get-OpsOsApiEnvFiles $rbL
    Report ($rbHit.Count -eq 1 -and $rbHit[0] -eq 'api.env') 'Get-OpsOsApiEnvFiles: os_api найден только в api.env'
    [IO.File]::WriteAllText((Join-Path $rbL.Config 'api.env'), "# ONEC_MODE=os_api`r`nONEC_MODE=fixtures`r`n")
    Report ((Get-OpsOsApiEnvFiles $rbL).Count -eq 0) 'Get-OpsOsApiEnvFiles: комментарий и fixtures — не os_api'
    $relOld = Join-Path $rbRoot 'rel-old'; $relNew = Join-Path $rbRoot 'rel-new'
    New-Item -ItemType Directory -Force -Path (Join-Path $relOld 'api\dist\common\config'), (Join-Path $relNew 'api\dist\common\config') | Out-Null
    [IO.File]::WriteAllText((Join-Path $relOld 'api\dist\common\config\env.schema.js'), "ONEC_MODE: z.enum(['extension', 'odata_only', 'fixtures'])")
    [IO.File]::WriteAllText((Join-Path $relNew 'api\dist\common\config\env.schema.js'), "ONEC_MODE: z.enum(['extension', 'odata_only', 'fixtures', 'os_api'])")
    Report (-not (Test-OpsReleaseSupportsOsApi $relOld) -and (Test-OpsReleaseSupportsOsApi $relNew)) 'Test-OpsReleaseSupportsOsApi: релиз до ADR-126 — нет, с os_api в схеме — да'
    $rb = [IO.File]::ReadAllText((Join-Path $win 'scripts\rollback.ps1'))
    $rbGuard = $rb.IndexOf('Test-OpsReleaseSupportsOsApi $target'); $rbStop = $rb.IndexOf("Stop-OpsAppServices `$L @('OptomstroyWorker', 'OptomstroyApi')")
    Report ($rbGuard -gt 0 -and $rbStop -gt $rbGuard -and $rb.Contains('-StandOnecOsApi fixtures')) 'rollback.ps1: откат на версию без os_api отклоняется до остановки служб, с подсказкой -StandOnecOsApi fixtures'
    # Повторный запуск поверх стенда с фикстурами: существующий файл, Set-OpsEnvValue (как install.ps1).
    $oldEnv = Join-Path $tmp 'osapi-old.env'
    [IO.File]::WriteAllText($oldEnv, "ONEC_MODE=fixtures`r`nONEC_INBOUND_ENABLED=false`r`n")
    $null = Write-OpsEnvFile $oldEnv '' ([ordered]@{ ONEC_MODE = 'os_api'; ONEC_OSAPI_PATH = 'hs/os/api/v1' })
    Report ((Read-OpsEnvTemplate $oldEnv)['ONEC_MODE'] -eq 'fixtures') 'Write-OpsEnvFile не переписывает ONEC_MODE (поэтому install.ps1 ставит режим через Set-OpsEnvValue)'
    $ch1 = $false; foreach ($k in @('ONEC_MODE', 'ONEC_BASE_URL')) { if (Set-OpsEnvValue $oldEnv $k ([string]$oa[$k])) { $ch1 = $true } }
    $ch2 = $false; foreach ($k in @('ONEC_MODE', 'ONEC_BASE_URL')) { if (Set-OpsEnvValue $oldEnv $k ([string]$oa[$k])) { $ch2 = $true } }
    $oldR = Read-OpsEnvTemplate $oldEnv
    Report ($ch1 -and -not $ch2 -and $oldR['ONEC_MODE'] -eq 'os_api' -and $oldR['ONEC_BASE_URL'] -eq 'http://localhost/uk_main_fr' -and $oldR['ONEC_OSAPI_PATH'] -eq 'hs/os/api/v1') 'существующий api.env стенда: fixtures → os_api; повтор — без изменений'

    $inst4 = [IO.File]::ReadAllText((Join-Path $win 'scripts\install.ps1'))
    Report ($inst4.Contains('onecOsApiBaseUrl = $osApiUrl') -and $inst4.Contains("`$installJson.PSObject.Properties['onecOsApiBaseUrl']")) 'install.ps1: адрес ОС_API запоминается в install.json и берётся оттуда при повторном запуске'
    Report ($inst4.Contains("foreach (`$k in @('ONEC_MODE', 'ONEC_BASE_URL')) {") -and $inst4.Contains("Set-OpsEnvValue `$fp 'ONEC_MODE' 'fixtures'")) 'install.ps1: режим ставится в существующие api.env и worker.env; обратно — -StandOnecOsApi fixtures'
    Report (-not ($inst4 -match "askSecrets\.Add\(@\('onec_(user|password)'")) 'install.ps1: onec_user и onec_password не спрашиваются (Read-Host) — их кладёт import-onec-credentials.ps1'
    Report ($inst4.Contains('-StandOnecOsApi: нет secrets\$s')) 'install.ps1: без secrets\onec_user и onec_password — стоп на шаге 1 (кроме DevTest)'

    # Отказ без -Stand: до журнала и папок (InstallRoot не создаётся).
    $noStandRoot = Join-Path $tmp 'nostand'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $win 'scripts\install.ps1') -Zip (Join-Path $tmp 'none.zip') -DevTest -InstallRoot $noStandRoot -StandOnecOsApi 'http://localhost/uk_main_fr' 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    Report ($code -ne 0 -and (($o -join "`n") -match 'только вместе с -Stand') -and -not (Test-Path -LiteralPath $noStandRoot)) "-StandOnecOsApi без -Stand — отказ (код $code), ничего не создано"

    # install.ps1 -DevTest -Stand -WhatIf: проверки шага 1 (адрес, режим из install.json), без изменений.
    $pgBinT = Join-Path $repo 'pos-api\node_modules\@embedded-postgres\windows-x64\native\bin'
    if (Test-Path -LiteralPath (Join-Path $pgBinT 'postgres.exe')) {
        $wiRoot = Join-Path $tmp 'wi\root'
        $wiTemp = Join-Path $tmp 'wi\temp'
        New-Item -ItemType Directory -Force -Path $wiTemp | Out-Null
        $ports = @()
        foreach ($i in 1..2) { $ls = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $ls.Start(); $ports += ([System.Net.IPEndPoint]$ls.LocalEndpoint).Port; $ls.Stop() }
        $runWi = {
            param([string[]]$Extra)
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $oldTemp = $env:TEMP; $env:TEMP = $wiTemp
            $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)   # журнал install.ps1 — UTF-8
            try {
                Get-ChildItem -LiteralPath $wiTemp -Recurse -Filter 'install-*.log' -ErrorAction SilentlyContinue | Remove-Item -Force
                $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $win 'scripts\install.ps1'), '-Zip', (Join-Path $tmp 'none.zip'), '-DevTest', '-Stand', '-WhatIf',
                    '-InstallRoot', $wiRoot, '-BackupRoot', (Join-Path $tmp 'wi\bk'), '-PgBin', $pgBinT, '-ApiPort', [string]$ports[0], '-PgPort', [string]$ports[1]) + $Extra
                $o = @(& powershell.exe @a 2>&1 | ForEach-Object { "$_" })
                return @{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
            } finally { $ErrorActionPreference = $old; $env:TEMP = $oldTemp; [Console]::OutputEncoding = $oldEnc }
        }
        $w1 = & $runWi @('-StandOnecOsApi', 'http://localhost/uk_main_fr/')
        Report ($w1.Code -eq 0 -and $w1.Out.Contains('ОС_API шлюза, только чтение — http://localhost/uk_main_fr/hs/os/api/v1')) "-WhatIf -Stand -StandOnecOsApi: режим os_api в плане (код $($w1.Code))$(if ($w1.Code -ne 0) { ': ' + $w1.Out })"
        $w2 = & $runWi @('-StandOnecOsApi', 'http://10.0.0.5/uk_main_fr')
        Report ($w2.Code -ne 0 -and $w2.Out.Contains('http:// — только для публикации на этом же сервере')) '-StandOnecOsApi с http:// на другой сервер — отказ'
        New-Item -ItemType Directory -Force -Path (Join-Path $wiRoot 'config') | Out-Null
        [IO.File]::WriteAllText((Join-Path $wiRoot 'config\install.json'), ([ordered]@{ contour = 'test'; apiPort = $ports[0]; pgPort = $ports[1]; dbName = 'optomstroy'; stand = $true; publicBaseUrl = 'https://api-test.devtest.invalid'; onecOsApiBaseUrl = 'http://localhost/uk_main_fr' } | ConvertTo-Json))
        $w3 = & $runWi @()
        Report ($w3.Code -eq 0 -and $w3.Out.Contains('режим ОС_API из install.json') -and $w3.Out.Contains('ONEC_MODE=os_api')) 'повторный запуск без -StandOnecOsApi: режим os_api из install.json (не откатывается)'
        $w4 = & $runWi @('-StandOnecOsApi', 'fixtures')
        Report ($w4.Code -eq 0 -and $w4.Out.Contains('1С: фикстуры (ONEC_MODE=fixtures')) '-StandOnecOsApi fixtures — обратно на фикстуры'
    } else { Report $false "нет $pgBinT (npm ci в pos-api) — проверки install.ps1 -WhatIf пропущены" }

    # Учётные данные шлюза: тестовые ключи реестра HKCU:\Software\OptomstroyTests\<guid> (переменные среды не трогаются).
    $regBase = 'HKCU:\Software\OptomstroyTests\' + [Guid]::NewGuid().ToString('N')
    $credUser = 'api_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $credPass = 'P' + [Guid]::NewGuid().ToString('N')   # check-secrets: allow — случайное тестовое значение
    try {
        foreach ($n in 'A', 'B', 'C', 'D') { New-Item -Path "$regBase\$n" -Force | Out-Null }
        foreach ($n in 'A', 'B') { New-ItemProperty -Path "$regBase\$n" -Name 'ONEC_API_USER' -Value $credUser -Force | Out-Null; New-ItemProperty -Path "$regBase\$n" -Name 'ONEC_API_PASSWORD' -Value $credPass -Force | Out-Null }
        New-ItemProperty -Path "$regBase\C" -Name 'ONEC_API_USER' -Value $credUser -Force | Out-Null
        New-ItemProperty -Path "$regBase\C" -Name 'ONEC_API_PASSWORD' -Value ($credPass + 'x') -Force | Out-Null
        $src = { param([string[]]$Names) @($Names | ForEach-Object { [pscustomobject]@{ Name = "тест $_"; Path = "$regBase\$_" } }) }
        $fc = Find-OpsOnecApiCredentials (& $src @('A', 'B', 'D'))
        Report ($fc.User -ceq $credUser -and $fc.Password -ceq $credPass -and @($fc.Sources).Count -eq 2) 'одинаковые значения в двух местах (HKCU и HKU\<свой SID>) — одна пара'
        $msg = ''; try { $null = Find-OpsOnecApiCredentials (& $src @('A', 'C')) } catch { $msg = $_.Exception.Message }
        Report ($msg -match 'по-разному' -and -not $msg.Contains($credPass) -and -not $msg.Contains($credUser)) 'разные значения в двух местах — отказ, в сообщении нет значений'
        $msg = ''; try { $null = Find-OpsOnecApiCredentials (& $src @('D')) } catch { $msg = $_.Exception.Message }
        Report ($msg -match 'не найдены') 'нигде нет — отказ'
        Report (@(Get-OpsEnvRegistrySources | Where-Object { $_.Path -like '*Session Manager\Environment' -or $_.Path -eq 'Registry::HKEY_CURRENT_USER\Environment' }).Count -eq 2) 'места поиска: HKLM (система) и HKCU, плюс загруженные профили HKU'

        $imp = Join-Path $tmp 'imp'
        New-Item -ItemType Directory -Force -Path (Join-Path $imp 'secrets'), (Join-Path $imp 'config') | Out-Null
        [IO.File]::WriteAllText((Join-Path $imp 'config\install.json'), '{ "contour": "test", "stand": true }')
        $runImp = {
            param([string[]]$Extra)
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            try {
                $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $win 'scripts\import-onec-credentials.ps1'), '-InstallRoot', $imp, '-DevTest') + $Extra
                $o = @(& powershell.exe @a 2>&1 | ForEach-Object { "$_" })
                return @{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
            } finally { $ErrorActionPreference = $old; [Console]::OutputEncoding = $oldEnc }
        }
        $r1 = & $runImp @('-SourceRegistryPath', "$regBase\A")
        $fu = Join-Path $imp 'secrets\onec_user'; $fp = Join-Path $imp 'secrets\onec_password'
        Report ($r1.Code -eq 0 -and (Test-Path $fu) -and [IO.File]::ReadAllText($fu) -ceq $credUser -and [IO.File]::ReadAllText($fp) -ceq $credPass) "import-onec-credentials.ps1: secrets\onec_user и onec_password записаны (код $($r1.Code))$(if ($r1.Code -ne 0) { ': ' + $r1.Out })"
        $bytes = [IO.File]::ReadAllBytes($fp)
        Report ($bytes.Length -gt 0 -and $bytes[0] -ne 0xEF -and $bytes[$bytes.Length - 1] -ne 10) 'файл секрета — UTF-8 без BOM и без перевода строки'
        $logs = (@(Get-ChildItem -LiteralPath (Join-Path $imp 'logs') -Filter 'import-onec-credentials-*.log') | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        Report (-not $r1.Out.Contains($credPass) -and -not $r1.Out.Contains($credUser) -and -not $logs.Contains($credPass) -and -not $logs.Contains($credUser) -and $logs.Length -gt 0) 'значения не попали ни на экран, ни в журнал (logs\import-onec-credentials-*.log)'
        $r2 = & $runImp @('-SourceRegistryPath', "$regBase\A")
        Report ($r2.Code -eq 0 -and $r2.Out.Contains('без изменений')) 'повторный запуск — без изменений'
        $r3 = & $runImp @('-SourceRegistryPath', "$regBase\C")
        Report ($r3.Code -ne 0 -and [IO.File]::ReadAllText($fp) -ceq $credPass -and -not $r3.Out.Contains($credPass)) 'другое значение без -Force — отказ, файл не заменён'
        $r4 = & $runImp @('-SourceRegistryPath', "$regBase\C", '-Force')
        Report ($r4.Code -eq 0 -and [IO.File]::ReadAllText($fp) -ceq ($credPass + 'x')) '-Force — файл заменён'
        $r5 = & $runImp @('-SourceRegistryPath', "$regBase\D")
        Report ($r5.Code -ne 0 -and $r5.Out.Contains('не найдены')) 'в источнике нет ONEC_API_USER/ONEC_API_PASSWORD — отказ'
        [IO.File]::WriteAllText((Join-Path $imp 'config\install.json'), '{ "contour": "prod", "stand": false }')
        $r6 = & $runImp @('-SourceRegistryPath', "$regBase\A")
        Report ($r6.Code -ne 0 -and $r6.Out.Contains('не тестовый стенд')) 'рабочая установка (stand = false) — отказ'
    } finally { Remove-Item -LiteralPath $regBase -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath 'HKCU:\Software\OptomstroyTests' -Force -ErrorAction SilentlyContinue }
    $impText = [IO.File]::ReadAllText((Join-Path $win 'scripts\import-onec-credentials.ps1'))
    Report ($impText.Contains('"*$($script:OpsSidAdministrators):(F)" "*$($script:OpsSidSystem):(F)" "*${sidApi}:(R)" "*${sidWorker}:(R)"') -and $impText.Contains("'/inheritance:r'")) 'import-onec-credentials.ps1: права — Administrators/SYSTEM (полный), OptomstroyApi/Worker (чтение), без наследования'

    Write-Host '== 8. Статические проверки прав и отката'
    $inst = [IO.File]::ReadAllText((Join-Path $win 'scripts\install.ps1'))
    Report (-not $inst.Contains('$L.AuditAnchors, ''/grant'', "*${s}:')) 'install.ps1: API не получает запись в data\audit-anchors (нет общей выдачи Api+Worker)'
    Report ($inst.Contains('$L.AuditAnchors, ''/grant'', "*$($sid.OptomstroyWorker):(OI)(CI)M"')) 'install.ps1: запись в data\audit-anchors — только OptomstroyWorker'
    Report ($inst.Contains('$deployServices = @(''OptomstroyApi'', ''OptomstroyWorker'')')) 'install.ps1: sc sdset posdeploy — только Api и Worker'
    Report ($inst.Contains('Invoke-Icacls @($L.Releases, ''/grant'', "*${deploySid}:(OI)(CI)RX")')) 'install.ps1: posdeploy читает releases (status.ps1 из current\scripts)'
    Report ($inst -match 'Test-OpsDedicatedRoot' -and $inst.IndexOf('Test-OpsDedicatedRoot') -lt $inst.IndexOf("'/inheritance:r'")) 'install.ps1: проверка отдельных папок раньше icacls /inheritance:r'
    $upd = [IO.File]::ReadAllText((Join-Path $win 'scripts\update.ps1'))
    Report ($upd.Contains('$migrateRan = @(''switched'', ''migrated'', ''started'')') -and $upd.Contains('snapshot-drop')) 'update.ps1: возврат из копии, если migrate запускался; ненужная копия удаляется'
    $un = [IO.File]::ReadAllText((Join-Path $win 'scripts\uninstall.ps1'))
    $i5 = $un.IndexOf("Write-OpsLog '5.")
    Report ($i5 -gt 0 -and $un.IndexOf('if ($errors -gt 0)', $i5) -gt $i5 -and $un.IndexOf('if ($errors -gt 0)', $i5) -lt $un.IndexOf('[System.IO.Directory]::Delete($L.Current', $i5)) 'uninstall.ps1: шаг 5 не удаляет программу после ошибок'

    $full = '(A;;CCLCRPWPLORC;;;S-1-5-21-1-2-3-1001)'; $q = '(A;;CCLCRC;;;S-1-5-21-1-2-3-1001)'
    $def = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCLCSWLOCRRC;;;IU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)'
    Report ((Update-OpsSddlAce $def $q $full) -eq 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCLCSWLOCRRC;;;IU)' + $q + 'S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)') 'Postgres/Backup: posdeploy получает только опрос, запись — до SACL'
    $prev = $def.Replace('S:', $full + 'S:')
    $r1 = Update-OpsSddlAce $prev $q $full
    Report ((-not $r1.Contains($full)) -and $r1.Contains($q)) 'Postgres/Backup: право запуска и остановки прежней версии снимается, опрос остаётся'
    Report ((Update-OpsSddlAce $r1 $q $full) -eq $r1) 'повторный запуск ничего не меняет'
    $r2 = Update-OpsSddlAce ($def.Replace('S:', $q + 'S:')) $full $q
    Report ($r2.Contains($full) -and -not $r2.Contains($q)) 'Api/Worker: полный набор (опрос, запуск, остановка), запись «только опрос» убирается'
    Report ((Update-OpsSddlAce 'D:(A;;CC;;;SY)' $q $full) -eq ('D:(A;;CC;;;SY)' + $q)) 'SDDL без SACL — запись в конец'
    $inst2 = [IO.File]::ReadAllText((Join-Path $win 'scripts\install.ps1'))
    Report ($inst2.Contains('$queryAce = "(A;;CCLCRC;;;$deploySid)"') -and $inst2.Contains('Update-OpsSddlAce $old $want $drop')) 'install.ps1: опрос Postgres/Backup для posdeploy — без RP/WP (запуска и остановки)'

    Write-Host '== 9. Состояние без WMI (как posdeploy по SSH)'
    $lis = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $lis.Start()
    $lp = ([System.Net.IPEndPoint]$lis.LocalEndpoint).Port
    try {
        $a = @(Get-OpsListenAddresses $lp)
        $ref = @(Get-NetTCPConnection -State Listen -LocalPort $lp -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
        Report ($a.Count -eq 1 -and $a[0] -eq '127.0.0.1' -and ($ref -join ',') -eq ($a -join ',')) "Get-OpsListenAddresses без WMI: порт $lp — 127.0.0.1, как у Get-NetTCPConnection"
        Report (Test-OpsPortListening $lp) 'Test-OpsPortListening: порт занят'
        $any = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Any, 0)
        $any.Start(); $ap = ([System.Net.IPEndPoint]$any.LocalEndpoint).Port
        try { Report (@(Get-OpsListenAddresses $ap) -contains '::') "адрес :: (все адреса IPv6) виден как '::' — status.ps1 считает его проблемой" } finally { $any.Stop() }
    } finally { $lis.Stop() }
    Report (-not (Test-OpsPortListening $lp)) 'Test-OpsPortListening: после остановки порт свободен'
    Report ((Get-OpsServiceStateSc 'EventLog') -eq 'Running' -and (Get-OpsServiceState 'EventLog') -eq 'Running') 'служба EventLog: Running (Get-Service и sc.exe query)'
    Report ((Get-OpsServiceStateSc 'OptomstroyNoSuchSvc') -eq 'Missing' -and (Get-OpsServiceState 'OptomstroyNoSuchSvc') -eq 'Missing') 'нет службы: Missing (Get-Service и sc.exe query)'
    function global:sc.exe { $global:LASTEXITCODE = 5; '[SC] OpenService FAILED 5: Access is denied.' }
    try { $den = Get-OpsServiceStateSc 'OptomstroyApi' } finally { Remove-Item function:\sc.exe -ErrorAction SilentlyContinue }
    Report ($den -eq 'нет доступа') "sc.exe query код 5 — «нет доступа», не Missing (получено: $den)"
    $vs = Get-OpsVolumeSpace $repo
    $di = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($repo))
    Report ($null -ne $vs -and $vs.SizeBytes -eq [double]$di.TotalSize -and $vs.FreeBytes -gt 0) "Get-OpsVolumeSpace: том $($vs.Volume) без WMI"
    $stText = [IO.File]::ReadAllText((Join-Path $win 'scripts\status.ps1'))
    $stCode = (($stText -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Report (-not ($stCode -match 'Get-CimInstance|Get-WmiObject|Get-NetTCPConnection|Get-Volume'))'status.ps1: нет вызовов WMI (Get-CimInstance, Get-NetTCPConnection, Get-Volume)'

    # Отказ WMI и Get-Service, как под posdeploy по SSH: подменяем команды функциями, которые бросают «Access denied».
    $fr = Join-Path $tmp 'fake-root'
    New-Item -ItemType Directory -Force -Path (Join-Path $fr 'current\scripts'), (Join-Path $fr 'logs') | Out-Null
    Copy-Item (Join-Path $win 'scripts\status.ps1'), (Join-Path $win 'scripts\OptomstroyCommon.ps1') (Join-Path $fr 'current\scripts')
    $pg = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $pg.Start()
    try {
        $pgp = ([System.Net.IPEndPoint]$pg.LocalEndpoint).Port
        $dsj = [ordered]@{ currentVersion = 't'; previousVersion = ''; installedUtc = '2026-11-22T00:00:00Z'; updatedUtc = $null; lastOperation = 'install'; lastOperationStatus = 'ok'; apiPort = 1; pgPort = $pgp; devTest = $false; backupRoot = $tmp }
        [IO.File]::WriteAllText((Join-Path $fr 'logs\deploy-state.json'), ($dsj | ConvertTo-Json))
        $deny = "function global:Get-CimInstance { throw 'Access denied' }; function global:Get-WmiObject { throw 'Access denied' }; function global:Get-NetTCPConnection { throw 'Cannot connect to CIM server. Access denied' }; function global:Get-Service { throw 'Cannot open Service Control Manager' }; & '$(Join-Path $fr 'current\scripts\status.ps1')' -Json; exit `$LASTEXITCODE"
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $deny 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
        $j = Get-LastJson $o
        Report ($null -ne $j) "status.ps1 -Json выдал отчёт при отказе WMI и Get-Service$(if ($null -eq $j) { ': ' + ($o -join ' | ') })"
        if ($null -ne $j) {
            Report ($code -eq 1) "код выхода 1 (есть проблемы: службы и API тестового стенда), получено $code"
            Report ($j.installRoot -eq (Resolve-Path $fr).Path) "папка установки найдена по расположению скрипта без -InstallRoot: $($j.installRoot)"
            Report (@($j.listen.postgres) -contains '127.0.0.1' -and -not (@($j.problems) -match 'PostgreSQL не слушает')) 'порт PostgreSQL виден без Get-NetTCPConnection'
            Report (@($j.disks).Count -ge 1 -and $j.disks[0].sizeGB -gt 0) 'место на томе — без Get-CimInstance'
            Report ($j.services.OptomstroyApi -eq 'Missing') "служба без Get-Service (sc.exe query): $($j.services.OptomstroyApi)"
        }
    } finally { $pg.Stop() }
} finally {
    Remove-Item -LiteralPath (Join-Path $repo '.tmp\wn-scripts') -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) { Write-Host "Провалено проверок: $failed" -ForegroundColor Red; exit 1 }
Write-Host 'Все проверки пройдены' -ForegroundColor Green
exit 0
