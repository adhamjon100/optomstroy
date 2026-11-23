<#
.SYNOPSIS
    Подключает виртуальный хост API Оптомстрой к существующему Apache (рядом с публикацией 1С). Для администратора.

.DESCRIPTION
    По умолчанию — только проверка и план (ничего не меняется). Изменения — только с ключом -Apply.
    Apache НЕ перезапускается: перезапуск выполняет администратор в согласованное окно (перезапуск затрагивает 1С).

    Проверки до изменений (любая не пройдена — стоп, файлы не меняются):
      1. httpd -v — Apache 2.4 не старше 2.4.42; openssl version — не старше 1.1.1. httpd -t — «Syntax OK».
      2. httpd -t -D DUMP_INCLUDES — Apache читает именно указанный -ConfigFile.
      3. httpd -S — для *:<порт> есть именованный VirtualHost (публикация 1С) и он хост по умолчанию;
         других записей для этого порта (по IP-адресу, _default_) нет; имя API ещё нигде не объявлено
         и не подходит под маску (ServerAlias *.<домен>) хоста этого порта.
      4. httpd -M — нужные модули загружены; если нет — в httpd.conf есть закомментированная строка LoadModule
         и файл модуля существует (её раскомментируют); блоки <IfModule> этих модулей в конфигурации — стоп,
         если не указан -AcceptIfModuleBlocks (загрузка модуля включила бы их и для 1С).
      5. То, чего не видит httpd -t (иначе «Syntax OK», а перезапуск падает вместе с 1С): файлы сертификата, ключа,
         rotatelogs и папка журналов существуют, в папку журналов можно писать; bin\openssl.exe — сертификат
         соответствует ключу, ключ без пароля, срок не истёк, имя есть в subjectAltName; пробный запуск —
         отдельный httpd.exe -X только с хостом API на свободном порту 127.0.0.1 и запрос к нему по HTTPS
         (работающий Apache не затрагивается; журналы пробы — *.trial.log, удаляются). -SkipTrialStart — без него.

    Изменения (-Apply):
      - копия httpd.conf (байт в байт) и файл manifest.json — в <BackupRoot>\<дата-время>-enable-<имя файла>;
      - файл хоста копируется в <TargetDir> (по умолчанию <ApacheDir>\conf\extra);
      - в httpd.conf раскомментируются нужные строки LoadModule (если требуется) и в конец добавляется
        одна строка Include (перед ней — перевод строки CRLF);
      - httpd -t и httpd -S по новой конфигурации: 1С осталась хостом по умолчанию, хост API добавлен;
        иначе httpd.conf восстанавливается из копии, файл хоста убирается, код выхода не 0.

    Откат — disable-apache-site.ps1 (по manifest.json).

    Коды выхода: 0 — успех (или проверка без -Apply прошла); 1 — стоп по условию; 2 — неверные параметры;
    3 — текущая конфигурация Apache не проходит httpd -t; 4 — новая конфигурация не прошла httpd -t (восстановлено);
    5 — после изменения 1С перестала быть хостом по умолчанию или хост API не появился (восстановлено);
    6 — ВОССТАНОВЛЕНИЕ НЕ УДАЛОСЬ (вернуть httpd.conf из копии вручную, Apache не перезапускать).

.PARAMETER ApacheDir
    Папка Apache (ServerRoot), например C:\Apache24.
.PARAMETER SiteConf
    Готовый файл хоста (результат render-apache-conf.ps1), например .\optomstroy-pos.conf.
.PARAMETER ServiceName
    Имя службы Apache (Get-Service). Скрипт проверяет, что служба запускает этот httpd.exe с этим httpd.conf,
    и выполняет проверки httpd с ключом -n <служба> (с её параметрами ConfigArgs). Без него — проверки с -d/-f.
.PARAMETER ConfigFile
    Основной файл конфигурации. По умолчанию <ApacheDir>\conf\httpd.conf.
.PARAMETER ListenPort
    Порт HTTPS, на котором работает 1С. По умолчанию 443.
.PARAMETER OpenSslExe
    openssl.exe для проверки сертификата. По умолчанию <ApacheDir>\bin\openssl.exe; нет файла — проверка пропускается
    (несовпадение ключа всё равно поймает пробный запуск).
.PARAMETER SkipTrialStart
    Не выполнять пробный запуск (например, файл модуля не найден по строке LoadModule). Тогда успешные проверки
    не гарантируют, что перезапуск Apache пройдёт: держать наготове команду отката.
.PARAMETER Apply
    Выполнить изменения. Без ключа — только проверки и план.

.EXAMPLE
    .\enable-apache-site.ps1 -ApacheDir C:\Apache24 -ServiceName Apache2.4 -SiteConf .\optomstroy-pos.conf
    .\enable-apache-site.ps1 -ApacheDir C:\Apache24 -ServiceName Apache2.4 -SiteConf .\optomstroy-pos.conf -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApacheDir,
    [Parameter(Mandatory = $true)][string]$SiteConf,
    [string]$ServiceName = '',
    [string]$ConfigFile = '',
    [string]$TargetDir = '',
    [string]$BackupRoot = '',
    [string]$HttpdExe = '',
    [ValidateRange(1, 65535)][int]$ListenPort = 443,
    [string]$OpenSslExe = '',
    [switch]$WithCompression,
    [switch]$AcceptIfModuleBlocks,
    [switch]$SkipTrialStart,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'apache-common.ps1')

function Stop-Enable([int]$Code, [string]$Message) {
    Write-Output "СТОП: $Message"
    Write-Output 'httpd.conf не изменён, Apache не перезапускался.'
    exit $Code
}

# ---------- Параметры ----------
if (-not (Test-Path -LiteralPath $ApacheDir -PathType Container)) { Stop-Enable 2 "нет папки Apache: $ApacheDir" }
$ApacheDir = (Get-FullPath $ApacheDir).TrimEnd('\')
if (-not $ConfigFile) { $ConfigFile = Join-Path $ApacheDir 'conf\httpd.conf' }
if (-not $TargetDir) { $TargetDir = Join-Path $ApacheDir 'conf\extra' }
if (-not $BackupRoot) { $BackupRoot = Join-Path $ApacheDir 'conf\optomstroy-backup' }
if (-not $HttpdExe) { $HttpdExe = Join-Path $ApacheDir 'bin\httpd.exe' }
if (-not $OpenSslExe) { $OpenSslExe = Join-Path $ApacheDir 'bin\openssl.exe' }
$ConfigFile = Get-FullPath $ConfigFile; $TargetDir = Get-FullPath $TargetDir
$BackupRoot = Get-FullPath $BackupRoot; $HttpdExe = Get-FullPath $HttpdExe
foreach ($f in @($ConfigFile, $HttpdExe, $SiteConf)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Stop-Enable 2 "нет файла: $f" }
}
if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) { Stop-Enable 2 "нет папки для файла хоста: $TargetDir" }
$SiteConf = Get-FullPath $SiteConf
$siteBytes = [System.IO.File]::ReadAllBytes($SiteConf)
$siteText = $script:Latin1.GetString($siteBytes)
if ($siteText -notmatch '(?m)^\s*ServerName\s+(?<n>\S+)\s*$') { Stop-Enable 2 "в $SiteConf нет строки ServerName" }
$serverName = $Matches.n.ToLowerInvariant()
if ($siteText -notmatch '(?m)^\s*<VirtualHost\s+\*:(?<p>\d+)>\s*$') { Stop-Enable 2 "в $SiteConf нет <VirtualHost *:порт>" }
if ([int]$Matches.p -ne $ListenPort) { Stop-Enable 2 "файл хоста для порта $($Matches.p), а -ListenPort $ListenPort" }
if ($siteText -match '@@[A-Z_]+@@') { Stop-Enable 2 "в $SiteConf остались незаполненные метки шаблона" }
$targetPath = Join-Path $TargetDir (Split-Path -Leaf $SiteConf)
if ((ConvertTo-NormPath $targetPath) -eq (ConvertTo-NormPath $SiteConf)) { Stop-Enable 2 'SiteConf уже лежит в TargetDir: укажите файл вне папки Apache (скрипт копирует его сам)' }
$includeLine = Get-IncludeLine $targetPath
$baseArgs = if ($ServiceName) { @('-n', $ServiceName) } else { @('-d', ($ApacheDir -replace '\\', '/'), '-f', ($ConfigFile -replace '\\', '/')) }
$required = @($script:OptomstroyRequiredModules)
if ($WithCompression) { $required += $script:OptomstroyCompressionModules }

Write-Step "Apache: $HttpdExe; конфигурация: $ConfigFile"
Write-Step "Хост API: $serverName (*:$ListenPort); файл: $SiteConf -> $targetPath"
if (-not $Apply) { Write-Step 'Режим проверки: ничего не меняется (для изменений нужен ключ -Apply).' }

# ---------- 0. Служба ----------
if ($ServiceName) {
    $svcErr = Test-ApacheService $ServiceName $HttpdExe $ConfigFile $ApacheDir
    if ($svcErr) { Stop-Enable 1 $svcErr }
    Write-Step "Служба '$ServiceName' запускает этот httpd.exe — ок."
} else {
    Write-Step 'ВНИМАНИЕ: -ServiceName не указан — служба не проверена, проверки httpd идут с -d/-f.'
}

# ---------- 1. Версия и текущая конфигурация ----------
$v0 = Invoke-Httpd $HttpdExe @() @('-v')
$apacheVer = Get-ApacheVersion $v0.Text
Write-Step ('httpd -v: ' + ((($v0.Text -split "`r?`n") | Where-Object { $_ }) -join '; '))
if ($null -eq $apacheVer) { Stop-Enable 1 "не удалось определить версию Apache (httpd -v):`n$($v0.Text)" }
if ($apacheVer -lt $script:ApacheMinVersion -or $apacheVer.Major -ne 2 -or $apacheVer.Minor -ne 4) {
    Stop-Enable 1 "Apache ${apacheVer}: нужен Apache 2.4 не старше $($script:ApacheMinVersion) (README, «Требования»). Обновление Apache — отдельное согласованное изменение (затрагивает 1С)."
}
if (Test-Path -LiteralPath $OpenSslExe -PathType Leaf) {
    $ov = Invoke-Httpd $OpenSslExe @() @('version')
    Write-Step "openssl version: $($ov.Text)"
    if ($ov.Text -match 'OpenSSL (?<v>\d+\.\d+\.\d+)') {
        if ([version]$Matches.v -lt $script:OpenSslMinVersion) { Stop-Enable 1 "OpenSSL $($Matches.v) в комплекте Apache: нужен не старше $($script:OpenSslMinVersion) (TLS 1.3)" }
    }
} else {
    Write-Step "ВНИМАНИЕ: нет $OpenSslExe — версия OpenSSL, сертификат и ключ не проверены заранее (их проверит пробный запуск)."
}

$t0 = Invoke-Httpd $HttpdExe $baseArgs @('-t')
if ($t0.Code -ne 0) { Stop-Enable 3 ("текущая конфигурация Apache не проходит httpd -t:`n" + $t0.Text) }
Write-Step 'httpd -t (сейчас): Syntax OK.'

$inc = Invoke-Httpd $HttpdExe $baseArgs @('-t', '-D', 'DUMP_INCLUDES')
$incInfo = Get-HttpdIncludes $inc.Text
if ($inc.Code -ne 0 -or -not $incInfo.Root) { Stop-Enable 1 ("не удалось получить список файлов конфигурации (httpd -t -D DUMP_INCLUDES):`n" + $inc.Text) }
if ((ConvertTo-NormPath $incInfo.Root) -ne (ConvertTo-NormPath $ConfigFile)) {
    Stop-Enable 1 "Apache читает другой основной файл: $($incInfo.Root) (указан $ConfigFile)"
}
foreach ($f in $incInfo.Files) {
    if ((ConvertTo-NormPath $f) -eq (ConvertTo-NormPath $targetPath)) { Stop-Enable 1 "файл $targetPath уже подключён к конфигурации (сначала disable-apache-site.ps1)" }
}

$cfgBytes = [System.IO.File]::ReadAllBytes($ConfigFile)
$cfgLines = Split-ConfigLines ($script:Latin1.GetString($cfgBytes))
if (@(Find-IncludeLines $cfgLines $targetPath).Count -gt 0) { Stop-Enable 1 "в $ConfigFile уже есть Include $targetPath" }

# ---------- 2. Виртуальные хосты ----------
$s0 = Invoke-Httpd $HttpdExe $baseArgs @('-S')
if ($s0.Code -ne 0) { Stop-Enable 3 ("httpd -S завершился с ошибкой:`n" + $s0.Text) }
$table0 = Get-HttpdVhostTable $s0.Text
$portEntries = @($table0 | Where-Object { $_.Port -eq [string]$ListenPort })
$star0 = @($portEntries | Where-Object { $_.Addr -eq '*' })
$other0 = @($portEntries | Where-Object { $_.Addr -ne '*' })
if ($other0.Count -gt 0) {
    Stop-Enable 1 ("для порта $ListenPort есть хосты по IP-адресу или _default_: " + (($other0 | ForEach-Object { "$($_.Addr):$($_.Port)" }) -join ', ') +
        ". Для запросов на эти адреса хост *:$ListenPort не используется (API не ответит) — схема требует решения администратора.`n" + $s0.Text)
}
if ($star0.Count -ne 1 -or $null -eq $star0[0].Default -or $star0[0].Hosts.Count -lt 1) {
    Stop-Enable 1 ("для *:$ListenPort нет именованного <VirtualHost *:$ListenPort> (публикация 1С описана в основной конфигурации, " +
        "через _default_ или по IP-адресу). Новый хост стал бы хостом по умолчанию и перехватил бы запросы 1С. " +
        "Сначала администратор оформляет публикацию 1С явным <VirtualHost *:$ListenPort> (отдельное согласованное изменение).`n" + $s0.Text)
}
$def0 = $star0[0].Default
Add-VhostAliasesFromConfig $table0
if ((Get-HttpdDeclaredNames $table0) -contains $serverName) { Stop-Enable 1 "имя $serverName уже объявлено в конфигурации Apache (ServerName/ServerAlias)" }
# Маска (ServerAlias *.<домен>) у хоста этого порта: он стоит раньше нашего (Include — в конце) и забрал бы имя API.
$shadow0 = Get-ShadowingHosts $star0[0].Hosts $serverName
if ($shadow0.Count -gt 0) {
    Stop-Enable 1 ("имя $serverName уже подходит под имя или маску другого хоста *:${ListenPort}: " + ($shadow0 -join '; ') +
        ". Apache отдаст запросы на $serverName ему, хост API их не получит. Нужно решение администратора (убрать маску или вынести имя API).")
}
Write-Step ("Хост по умолчанию для *:{0}: {1} ({2}:{3}); именованных хостов: {4}." -f $ListenPort, $def0.Name, $def0.File, $def0.Line, $star0[0].Hosts.Count)

# ---------- 3. Модули ----------
$m0 = Invoke-Httpd $HttpdExe $baseArgs @('-M')
if ($m0.Code -ne 0) { Stop-Enable 3 ("httpd -M завершился с ошибкой:`n" + $m0.Text) }
$loaded = Get-HttpdModules $m0.Text
$missing = @($required | Where-Object { $loaded -notcontains $_ })
$uncomment = @()
foreach ($mod in $missing) {
    $found = $false
    for ($i = 0; $i -lt $cfgLines.Count; $i++) {
        $l = $cfgLines[$i].Text
        if ($l -match ('^(?<ws>\s*)#\s*LoadModule\s+' + [regex]::Escape($mod) + '\s+(?<file>"[^"]+"|\S+)\s*$')) {
            $file = $Matches.file.Trim('"')
            $full = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $ApacheDir $file }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-Enable 1 "модуль $mod не загружен, а файла $full нет" }
            $uncomment += [pscustomobject]@{ Module = $mod; Index = $i; Before = $l; After = ($Matches.ws + 'LoadModule ' + $mod + ' ' + $Matches.file) }
            $found = $true; break
        }
    }
    if (-not $found) { Stop-Enable 1 "модуль $mod не загружен и в $ConfigFile нет закомментированной строки LoadModule $mod — добавьте её вручную" }
}
# mod_remoteip с RemoteIPHeader подменяет IP клиента значением заголовка: тогда и X-Forwarded-For для API, и
# проверка адреса /health/ready зависят от его настроек доверенных прокси. Не стоп — предупреждение администратору.
if ($loaded -contains 'remoteip_module') {
    foreach ($f in $incInfo.Files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $n = 0
        foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Latin1)) {
            $n++
            if ($l -match '^\s*RemoteIPHeader\s') {
                Write-Step "ВНИМАНИЕ: ${f}:$n  $($l.Trim()) — проверьте RemoteIPInternalProxy/RemoteIPTrustedProxy: без них IP клиента можно подделать заголовком (README, раздел «mod_remoteip»)."
            }
        }
    }
}
if ($missing.Count -eq 0) { Write-Step 'Модули: все нужные уже загружены.' }
else { Write-Step ('Модули: будут включены (раскомментированы в httpd.conf): ' + ($missing -join ', ')) }

# Блоки <IfModule> включаемых модулей в существующей конфигурации — загрузка модуля изменила бы и её.
$dormant = @()
foreach ($u in $uncomment) {
    $short = $u.Module -replace '_module$', ''
    $pat = '^\s*<IfModule\s+!?\s*"?(' + [regex]::Escape($u.Module) + '|mod_' + [regex]::Escape($short) + '\.c)"?\s*>'
    foreach ($f in $incInfo.Files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $n = 0
        foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Latin1)) {
            $n++
            if ($l -match $pat) { $dormant += "${f}:$n  $($l.Trim())" }
        }
    }
}
if ($dormant.Count -gt 0) {
    $msg = "в конфигурации есть блоки <IfModule> включаемых модулей — после загрузки модуля они начнут действовать (в том числе для 1С):`n  " + ($dormant -join "`n  ")
    if (-not $AcceptIfModuleBlocks) { Stop-Enable 1 ($msg + "`nПроверьте их; если изменение допустимо — повторите с -AcceptIfModuleBlocks.") }
    Write-Step ('ВНИМАНИЕ (-AcceptIfModuleBlocks): ' + $msg)
}

# ---------- 3a. Файлы хоста, сертификат, пробный запуск ----------
# httpd -t их не проверяет: несовпадение сертификата и ключа, ключ с паролем, нет rotatelogs или папки журналов —
# «Syntax OK», а перезапуск Apache падает (вместе с 1С). Поэтому — проверка до изменений.
$refs = Get-SiteFileRefs $siteText
$defines = Get-HttpdDefines $incInfo.Files
$fileErrors = @()
foreach ($pair in @(@('сертификат', $refs.Cert), @('ключ', $refs.Key))) {
    if (-not $pair[1]) { $fileErrors += "в $SiteConf нет пути: $($pair[0])"; continue }
    $full = Resolve-ApachePath $ApacheDir $pair[1] $defines
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { $fileErrors += "нет файла ($($pair[0])): $($pair[1])" }
}
$logDirs = @()
foreach ($pp in $refs.Pipes) {
    $exe = Resolve-ApachePath $ApacheDir $pp.Exe $defines
    if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { $fileErrors += "нет программы ротации журналов: $($pp.Exe) (от ServerRoot $ApacheDir)" }
    $log = Resolve-ApachePath $ApacheDir $pp.Log $defines
    $dir = if ($log) { Split-Path -Parent $log } else { $null }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { $fileErrors += "нет папки журналов: $($pp.Log)" }
    elseif ($logDirs -notcontains $dir) { $logDirs += $dir }
}
if ($fileErrors.Count -gt 0) { Stop-Enable 1 ("файл хоста ссылается на отсутствующие файлы — Apache не запустится:`n  " + ($fileErrors -join "`n  ")) }
foreach ($d in $logDirs) {
    $probe = Join-Path $d ('optomstroy-write-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    try { [System.IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force }
    catch { Stop-Enable 1 "нет права записи в папку журналов $d (у текущего пользователя): $($_.Exception.Message)" }
}
Write-Step ('Файлы хоста на месте: сертификат, ключ, rotatelogs; папки журналов доступны на запись: ' + ($logDirs -join ', '))
if ($ServiceName) {
    $acct = Get-ApacheServiceAccount $ServiceName
    Write-Step "Служба Apache работает от имени: $acct. Ей нужны: запись в папку журналов, чтение ключа и сертификата, чтение папки фото (README, «Права NTFS для службы Apache»)."
}
if (Test-Path -LiteralPath $OpenSslExe -PathType Leaf) {
    $certFull = Resolve-ApachePath $ApacheDir $refs.Cert $defines
    $keyFull = Resolve-ApachePath $ApacheDir $refs.Key $defines
    $cc = Test-SiteCertificate $OpenSslExe $certFull $keyFull $serverName
    foreach ($w in $cc.Warnings) { Write-Step "ВНИМАНИЕ: $w" }
    if ($cc.Errors.Count -gt 0) { Stop-Enable 1 ("сертификат или ключ не подходят:`n  " + ($cc.Errors -join "`n  ")) }
    Write-Step "Сертификат: соответствует ключу, ключ без пароля, срок не истёк, имя $serverName есть в subjectAltName."
}
if ($SkipTrialStart) {
    Write-Step 'ВНИМАНИЕ (-SkipTrialStart): пробный запуск пропущен — успешный httpd -t НЕ доказывает, что перезапуск Apache пройдёт.'
} else {
    $kinds = Get-HttpdModuleKinds $m0.Text
    $trialMods = @($required) + @($loaded | Where-Object { @('deflate_module', 'filter_module') -contains $_ })
    $ml = Get-TrialModuleLines $ApacheDir $trialMods $incInfo.Files $uncomment $kinds
    if ($ml.Unresolved.Count -gt 0) {
        Stop-Enable 1 ("пробный запуск: не найден файл модуля для " + ($ml.Unresolved -join ', ') +
            ". Проверьте строки LoadModule или повторите с -SkipTrialStart (тогда перезапуск — с готовой командой отката).")
    }
    $trial = Invoke-TrialStart $HttpdExe $ApacheDir $siteBytes $ListenPort $ml.Lines $serverName
    if (-not $trial.Ok) { Stop-Enable 1 ("пробный запуск хоста API (отдельный httpd.exe на 127.0.0.1) не удался — с этим файлом хоста перезапуск Apache упал бы:`n" + $trial.Detail) }
    Write-Step "Пробный запуск хоста API (отдельный httpd.exe -X): $($trial.Detail)."
}

# ---------- 4. План ----------
$targetExists = Test-Path -LiteralPath $targetPath -PathType Leaf
Write-Step 'План изменений:'
Write-Output "  - копия $ConfigFile -> $BackupRoot\<дата-время>-enable-$(Split-Path -Leaf $SiteConf)\httpd.conf.bak"
Write-Output "  - копировать $SiteConf -> $targetPath$(if ($targetExists) { ' (существующий файл сохраняется в копию)' })"
foreach ($u in $uncomment) { Write-Output "  - строка $($u.Index + 1): '$($u.Before.Trim())' -> '$($u.After.Trim())'" }
Write-Output "  - в конец httpd.conf: CRLF + $includeLine"
Write-Output '  - httpd -t и httpd -S по новой конфигурации; при ошибке — восстановление из копии'
if (-not $Apply) {
    Write-Step 'Проверка пройдена. Изменения не выполнялись (нет ключа -Apply).'
    exit 0
}

# ---------- 5. Изменения ----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakDir = Join-Path $BackupRoot ("$stamp-enable-" + (Split-Path -Leaf $SiteConf))
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
$bakConfig = Join-Path $bakDir 'httpd.conf.bak'
[System.IO.File]::WriteAllBytes($bakConfig, $cfgBytes)
if (-not (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($bakConfig))).Equals((Get-Sha256Hex $cfgBytes))) { Stop-Enable 1 "копия $bakConfig не совпала с оригиналом" }
$prevTarget = $null
if ($targetExists) {
    $prevTarget = Join-Path $bakDir ((Split-Path -Leaf $targetPath) + '.prev')
    Copy-Item -LiteralPath $targetPath -Destination $prevTarget -Force
}
Write-Step "Копия: $bakConfig"

foreach ($u in $uncomment) { $cfgLines[$u.Index].Text = $u.After }
$newText = (Join-ConfigLines $cfgLines) + "`r`n" + $includeLine + "`r`n"
$newBytes = $script:Latin1.GetBytes($newText)

$manifest = [ordered]@{
    kind               = 'optomstroy-apache-enable'
    version            = 1
    created            = (Get-Date).ToString('o')
    apacheDir          = $ApacheDir
    configFile         = $ConfigFile
    httpdExe           = $HttpdExe
    serviceName        = $ServiceName
    listenPort         = $ListenPort
    serverName         = $serverName
    siteConfSource     = $SiteConf
    targetPath         = $targetPath
    targetPreexisting  = [bool]$targetExists
    targetPrevBackup   = $prevTarget
    siteConfSha256     = (Get-Sha256Hex $siteBytes)
    includeLine        = $includeLine
    uncommented        = @($uncomment | ForEach-Object { [ordered]@{ module = $_.Module; line = $_.Index + 1; before = $_.Before; after = $_.After } })
    configBackup       = $bakConfig
    originalSha256     = (Get-Sha256Hex $cfgBytes)
    modifiedSha256     = (Get-Sha256Hex $newBytes)
    defaultServer      = [ordered]@{ name = $def0.Name; file = $def0.File; line = $def0.Line }
    status             = 'applying'
}
$manifestPath = Join-Path $bakDir 'manifest.json'
function Save-Manifest { [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false))) }
Save-Manifest

function Restore-Original([int]$Code, [string]$Reason) {
    Write-Output "ОШИБКА: $Reason"
    Write-Step 'Восстановление httpd.conf из копии…'
    $ok = $true
    try {
        [System.IO.File]::WriteAllBytes($ConfigFile, [System.IO.File]::ReadAllBytes($bakConfig))
        if ($prevTarget) { Copy-Item -LiteralPath $prevTarget -Destination $targetPath -Force }
        elseif (Test-Path -LiteralPath $targetPath) { Remove-Item -LiteralPath $targetPath -Force }
    } catch { $ok = $false; Write-Output "  ошибка восстановления: $($_.Exception.Message)" }
    $sameHash = $ok -and ((Get-Sha256Hex ([System.IO.File]::ReadAllBytes($ConfigFile))) -eq $manifest.originalSha256)
    $tR = Invoke-Httpd $HttpdExe $baseArgs @('-t')
    if (-not $sameHash -or $tR.Code -ne 0) {
        $manifest.status = 'restore-failed'; Save-Manifest
        Write-Output "КРИТИЧНО: восстановление не подтверждено (совпадение с копией: $sameHash; httpd -t: код $($tR.Code))."
        Write-Output "Apache НЕ перезапускать. Вернуть вручную: Copy-Item '$bakConfig' '$ConfigFile' -Force"
        exit 6
    }
    $manifest.status = 'rolled-back'; Save-Manifest
    Write-Step 'httpd.conf восстановлен байт в байт, httpd -t: Syntax OK. Apache не перезапускался.'
    exit $Code
}

try {
    Copy-Item -LiteralPath $SiteConf -Destination $targetPath -Force
    [System.IO.File]::WriteAllBytes($ConfigFile, $newBytes)
} catch {
    Restore-Original 4 "запись файлов: $($_.Exception.Message)"
}
Write-Step "httpd.conf изменён; файл хоста: $targetPath"

$t1 = Invoke-Httpd $HttpdExe $baseArgs @('-t')
if ($t1.Code -ne 0) { Restore-Original 4 ("новая конфигурация не проходит httpd -t:`n" + $t1.Text) }
Write-Step 'httpd -t (новая): Syntax OK.'

$s1 = Invoke-Httpd $HttpdExe $baseArgs @('-S')
if ($s1.Code -ne 0) { Restore-Original 5 ("httpd -S по новой конфигурации:`n" + $s1.Text) }
$table1 = Get-HttpdVhostTable $s1.Text
Add-VhostAliasesFromConfig $table1
$star1 = @($table1 | Where-Object { $_.Port -eq [string]$ListenPort -and $_.Addr -eq '*' })
$other1 = @($table1 | Where-Object { $_.Port -eq [string]$ListenPort -and $_.Addr -ne '*' })
$problems = @()
if ($star1.Count -ne 1 -or $null -eq $star1[0].Default) { $problems += "нет записи *:$ListenPort" }
else {
    $d1 = $star1[0].Default
    if ($d1.Name -ne $def0.Name -or (ConvertTo-NormPath $d1.File) -ne (ConvertTo-NormPath $def0.File) -or $d1.Line -ne $def0.Line) {
        $problems += "хост по умолчанию изменился: было $($def0.Name) ($($def0.File):$($def0.Line)), стало $($d1.Name) ($($d1.File):$($d1.Line))"
    }
    $ours = @($star1[0].Hosts | Where-Object { $_.Name.ToLowerInvariant() -eq $serverName -and (ConvertTo-NormPath $_.File) -eq (ConvertTo-NormPath $targetPath) })
    if ($ours.Count -ne 1) { $problems += "хост $serverName из $targetPath не найден в *:$ListenPort" }
    if ($star1[0].Hosts.Count -ne $star0[0].Hosts.Count + 1) { $problems += "число хостов *:${ListenPort}: было $($star0[0].Hosts.Count), стало $($star1[0].Hosts.Count) (ожидалось +1)" }
    $shadow1 = Get-ShadowingHosts $star1[0].Hosts $serverName $targetPath
    if ($shadow1.Count -gt 0) { $problems += "запросы на $serverName заберёт хост, стоящий раньше: " + ($shadow1 -join '; ') }
}
if ($other1.Count -gt 0) { $problems += 'появились хосты по IP-адресу/_default_ для порта' }
if ($problems.Count -gt 0) { Restore-Original 5 (($problems -join '; ') + "`n" + $s1.Text) }
Write-Step ("httpd -S (новая): хост по умолчанию для *:{0} — по-прежнему {1}; добавлен {2}." -f $ListenPort, $def0.Name, $serverName)

$manifest.status = 'enabled'; Save-Manifest
Write-Step "Готово. Манифест для отката: $manifestPath"
Write-Output ''
$svcShown = if ($ServiceName) { $ServiceName } else { '<ИмяСлужбыApache>' }
$disableCmd = ".\disable-apache-site.ps1 -Manifest '$manifestPath'$(if ($ServiceName) { " -ServiceName '$ServiceName'" }) -Apply"
Write-Output 'Apache НЕ перезапущен. Перезапуск — в согласованное окно (перезапуск затрагивает и 1С):'
Write-Output "  & '$HttpdExe' -n '$svcShown' -t"
Write-Output "  & '$HttpdExe' -n '$svcShown' -k restart"
Write-Output "  Get-Service '$svcShown'    # должно быть Running"
Write-Output '«Syntax OK» не доказывает, что перезапуск пройдёт; пробный запуск выше это проверил, но если служба не поднялась'
Write-Output '(Get-Service — Stopped; причина — в журнале ошибок Apache и в журнале событий Windows), сразу откат и запуск:'
Write-Output "  $disableCmd"
Write-Output "  Start-Service '$svcShown'"
Write-Output 'Сразу после перезапуска проверить 1С (код ответа как до изменения) и API (работает, если Apache слушает 443 на 0.0.0.0 или 127.0.0.1 — см. Listen в httpd.conf):'
Write-Output "  curl.exe -s -o NUL -w `"%{http_code}`" --resolve ${serverName}:${ListenPort}:127.0.0.1 https://${serverName}:${ListenPort}/health"
Write-Output 'Откат в любой момент:'
Write-Output "  $disableCmd"
exit 0
