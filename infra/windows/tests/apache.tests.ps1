<#
.SYNOPSIS
    Проверка комплекта infra/windows/apache на настоящем Apache 2.4 (локально, без службы и без прав администратора).

.DESCRIPTION
    Поднимает в рабочей папке «конфигурацию заказчика» (именованный хост 1С первым на *:18443 и *:18080, часть
    модулей закомментирована), подключает к ней хосты API скриптом enable-apache-site.ps1, запускает httpd.exe
    консольным процессом (ServerRoot — через -d) и заглушку API (node, 127.0.0.1:3320), проверяет curl.exe --resolve:
      - 1С отвечает и остаётся хостом по умолчанию (по IP, по чужому имени, на 18080);
      - маршруты API проксируются, X-Forwarded-* выставляет Apache (клиентским не доверяет);
      - заголовки безопасности — по одному разу, без X-Powered-By;
      - тело больше 1 МБ — 413 (до API не доходит); неизвестные пути — 404; /health/ready — 404 с неразрешённых адресов;
      - фото отдаются из папки, на отсутствующее — 404 без кэша; long-poll 25 с не обрывается, 32 с — 504;
      - API остановлен — 503 без problem+json; после запуска API запросы идут сразу (retry=0);
      - стоп-условия enable (1С без VirtualHost, хост по IP, сломанная конфигурация, <IfModule>), восстановление при
        синтаксической ошибке и при смене хоста по умолчанию; точный и частичный откат disable-apache-site.ps1.
    В конце httpd и заглушка останавливаются, закрытые ключи тестовых сертификатов удаляются.

    Порты: 18443, 18080 (Apache), 3320 (заглушка). Только 127.0.0.1.

.PARAMETER ApacheDir
    Apache 2.4 для Windows (ServerRoot). По умолчанию <репозиторий>\.tmp\tools\apache\Apache24.
.PARAMETER WorkDir
    Рабочая папка (пересоздаётся). По умолчанию <репозиторий>\.tmp\wn-apache\run.
.PARAMETER SkipLongPoll
    Пропустить проверки ожидания 25/32 с (экономит ~35 с).
.PARAMETER KeepWork
    Не удалять рабочую папку (закрытые ключи тестовых сертификатов удаляются всегда).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\apache.tests.ps1
#>
[CmdletBinding()]
param(
    [string]$ApacheDir = '',
    [string]$WorkDir = '',
    [string]$Node = 'node',
    [switch]$SkipLongPoll,
    [switch]$KeepWork
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..\..')).ProviderPath
$kit = Join-Path $repo 'infra\windows\apache'
if (-not $ApacheDir) { $ApacheDir = Join-Path $repo '.tmp\tools\apache\Apache24' }
if (-not $WorkDir) { $WorkDir = Join-Path $repo '.tmp\wn-apache\run' }
$ApacheDir = (Resolve-Path $ApacheDir).ProviderPath
$httpd = Join-Path $ApacheDir 'bin\httpd.exe'
$openssl = Join-Path $ApacheDir 'bin\openssl.exe'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$HTTPS = 18443; $HTTP = 18080; $UP = 3320
$fw = { param($p) $p -replace '\\', '/' }

# ---------- Итоги ----------
$script:results = New-Object System.Collections.ArrayList
$logFile = Join-Path (Split-Path -Parent $WorkDir) 'apache-tests.log'
function Write-Log([string]$s) { Write-Output $s; Add-Content -LiteralPath $logFile -Value $s -Encoding UTF8 }
function Assert([string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$script:results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    Write-Log ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { "  [$Detail]" } else { '' }))
}

# ---------- Процессы ----------
function Stop-TestProcesses {
    $wd = (& $fw $WorkDir).ToLowerInvariant()
    $wdb = $WorkDir.ToLowerInvariant()
    Get-CimInstance Win32_Process | Where-Object {
        $cl = [string]$_.CommandLine
        $cll = $cl.ToLowerInvariant()
        (($_.Name -in @('httpd.exe', 'rotatelogs.exe')) -and ($cll.Contains($wd) -or $cll.Contains($wdb))) -or
        ($_.Name -eq 'node.exe' -and $cll.Contains('stub-upstream.mjs') -and $cll.Contains(" $UP"))
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Stub {
    $out = Join-Path $WorkDir ("stub-{0}.out" -f (Get-Date -Format 'HHmmssfff'))
    $p = Start-Process -FilePath $Node -ArgumentList @("`"$(Join-Path $kit 'tests\stub-upstream.mjs')`"", "$UP") -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
    $script:stubOut = $out
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        if ((Test-Path $out) -and (Get-Content $out -Raw -ErrorAction SilentlyContinue) -match 'listening') { return $p }
    }
    throw 'заглушка API не запустилась'
}
function Get-StubRequests { if (Test-Path $script:stubOut) { return @(Get-Content $script:stubOut | Where-Object { $_ -like 'REQ *' }) } else { return @() } }

function Start-Httpd([string]$Conf) {
    $p = Start-Process -FilePath $httpd -ArgumentList @('-d', "`"$(& $fw $ApacheDir)`"", '-f', "`"$(& $fw $Conf)`"") -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        if ($p.HasExited) { throw "httpd завершился сразу (код $($p.ExitCode)); см. $WorkDir\logs\error.log" }
        if (Get-NetTCPConnection -State Listen -LocalPort $HTTPS -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500; return $p }
    }
    throw 'httpd не начал слушать порт'
}
function Stop-Httpd([string]$Conf) {
    $r = Invoke-Native $httpd @('-d', (& $fw $ApacheDir), '-f', (& $fw $Conf), '-k', 'shutdown')
    for ($i = 0; $i -lt 50; $i++) {
        if (-not (Get-NetTCPConnection -State Listen -LocalPort $HTTPS -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    Stop-TestProcesses
    Start-Sleep -Milliseconds 300
    return $r
}

function Invoke-Native([string]$Exe, [string[]]$ArgList, [System.Text.Encoding]$Encoding = $null) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ArgList | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($Encoding) { $psi.StandardOutputEncoding = $Encoding; $psi.StandardErrorEncoding = $Encoding }
    $p = [System.Diagnostics.Process]::Start($psi)
    $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = ($o + $e.Result) }
}

function Invoke-Script([string]$Script, [string[]]$ArgList) {
    # Вывод дочернего powershell.exe без консоли — в OEM-кодировке (cp866 для русской Windows).
    $oem = [System.Text.Encoding]::GetEncoding([int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP)
    $r = Invoke-Native $ps (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ArgList) $oem
    Add-Content -LiteralPath (Join-Path $WorkDir 'scripts.log') -Value ("==== {0} {1}`r`n{2}`r`nexit={3}" -f (Split-Path -Leaf $Script), ($ArgList -join ' '), $r.Out, $r.Code) -Encoding UTF8
    return $r
}

# curl с подстановкой имён на 127.0.0.1. Возвращает код, заголовки (массив строк), тело.
function Invoke-Curl([string]$Url, [string[]]$Extra = @(), [int]$MaxTime = 60) {
    $h = Join-Path $WorkDir 'curl.h'; $b = Join-Path $WorkDir 'curl.b'
    Remove-Item $h, $b -ErrorAction SilentlyContinue
    $resolve = @()
    foreach ($n in @('api.test.local', 'api-test.test.local', '1c.test.local', 'other.test.local')) { $resolve += @('--resolve', "${n}:${HTTPS}:127.0.0.1", '--resolve', "${n}:${HTTP}:127.0.0.1") }
    $args2 = @('-k', '-s', '-m', "$MaxTime", '-D', $h, '-o', $b, '-w', '%{http_code}') + $resolve + $Extra + @($Url)
    $r = Invoke-Native $curl $args2
    $code = 0; [void][int]::TryParse(($r.Out.Trim() -split '\s+')[-1], [ref]$code)
    $hdr = if (Test-Path $h) { @(Get-Content $h | Where-Object { $_ -ne '' }) } else { @() }
    $body = if (Test-Path $b) { [System.IO.File]::ReadAllText($b) } else { '' }
    return [pscustomobject]@{ Code = $code; Headers = $hdr; Body = $body }
}
function Get-HeaderValues($Resp, [string]$Name) {
    return , @($Resp.Headers | Where-Object { $_ -match ('^' + [regex]::Escape($Name) + ':\s*(.*)$') } | ForEach-Object { ($_ -replace ('^' + [regex]::Escape($Name) + ':\s*'), '').Trim() })
}
function Get-Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

# ---------- Подготовка ----------
Stop-TestProcesses
foreach ($port in @($HTTPS, $HTTP, $UP)) {
    if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw "порт $port занят — тест не запускается" }
}
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Content -LiteralPath $logFile -Value ("apache.tests.ps1 {0}; Apache: {1}" -f (Get-Date -Format s), ((Invoke-Native $httpd @('-v')).Out -split "`r?`n")[0]) -Encoding UTF8
foreach ($d in @('ssl', 'logs', 'onec', 'conf\extra', 'backup', 'root\data\media\images', 'root-test\data\media\images')) { New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir $d) | Out-Null }
$W = & $fw $WorkDir

$env:OPENSSL_CONF = Join-Path $ApacheDir 'conf\openssl.cnf'
foreach ($n in @('api.test.local', 'api-test.test.local', '1c.test.local', 'api-x.test.local')) {
    $r = Invoke-Native $openssl @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2', '-subj', "/CN=$n",
        '-addext', "subjectAltName=DNS:$n", '-addext', 'basicConstraints=critical,CA:FALSE',
        '-keyout', (Join-Path $WorkDir "ssl\$n.key"), '-out', (Join-Path $WorkDir "ssl\$n.crt"))
    if ($r.Code -ne 0) { throw "openssl: $($r.Out)" }
}
Set-Content -LiteralPath (Join-Path $WorkDir 'onec\index.html') -Value '<html><body>ONEC-MARKER</body></html>' -Encoding ASCII
$sha = ('ab' * 32)
New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir "root\data\media\images\$sha") | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $WorkDir "root\data\media\images\$sha\thumb.webp"), [byte[]](0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x57, 0x45, 0x42, 0x50))

# «Конфигурация заказчика»: 1С — именованный хост первым; proxy/proxy_http/rewrite закомментированы (как в типовом httpd.conf).
$customer = @"
# Имитация httpd.conf заказчика (публикация 1С). ServerRoot задаётся ключом -d.
Listen 127.0.0.1:$HTTP
Listen 127.0.0.1:$HTTPS
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule alias_module modules/mod_alias.so
LoadModule dir_module modules/mod_dir.so
LoadModule headers_module modules/mod_headers.so
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
#LoadModule proxy_module modules/mod_proxy.so
#LoadModule proxy_http_module modules/mod_proxy_http.so
# LoadModule rewrite_module modules/mod_rewrite.so
ServerName 1c.test.local
PidFile "$W/logs/httpd.pid"
ErrorLog "$W/logs/error.log"
LogLevel warn
TypesConfig conf/mime.types
DocumentRoot "$W/onec"
<Directory "$W/onec">
    Require all granted
</Directory>
SSLSessionCache "shmcb:$W/logs/ssl_scache(512000)"
<VirtualHost *:$HTTP>
    ServerName 1c.test.local
    DocumentRoot "$W/onec"
</VirtualHost>
<VirtualHost *:$HTTPS>
    ServerName 1c.test.local
    SSLEngine on
    SSLCertificateFile "$W/ssl/1c.test.local.crt"
    SSLCertificateKeyFile "$W/ssl/1c.test.local.key"
    DocumentRoot "$W/onec"
</VirtualHost>
"@
$customer = ($customer -replace "`r`n", "`n") -replace "`n", "`r`n"
$conf = Join-Path $WorkDir 'conf\httpd.conf'
[System.IO.File]::WriteAllText($conf, $customer, (New-Object System.Text.UTF8Encoding($false)))
$origHash = Get-Sha $conf
$origBytes = [System.IO.File]::ReadAllBytes($conf)

# ---------- 1. render ----------
$render = Join-Path $kit 'render-apache-conf.ps1'
$enable = Join-Path $kit 'enable-apache-site.ps1'
$disable = Join-Path $kit 'disable-apache-site.ps1'
$prodConf = Join-Path $WorkDir 'optomstroy-pos.conf'
$testConf = Join-Path $WorkDir 'optomstroy-pos-test.conf'
$r = Invoke-Script $render @('-ServerName', 'api.test.local', '-CertFile', "$WorkDir\ssl\api.test.local.crt", '-KeyFile', "$WorkDir\ssl\api.test.local.key",
    '-InstallRoot', "$WorkDir\root", '-ApiPort', "$UP", '-ListenPort', "$HTTPS", '-LogDir', "$W/logs", '-OutFile', $prodConf)
Assert 'render: рабочий хост сформирован' ($r.Code -eq 0 -and (Test-Path $prodConf)) "код $($r.Code)"
$r = Invoke-Script $render @('-ServerName', 'api-test.test.local', '-CertFile', "$WorkDir\ssl\api-test.test.local.crt", '-KeyFile', "$WorkDir\ssl\api-test.test.local.key",
    '-InstallRoot', "$WorkDir\root-test", '-ApiPort', "$UP", '-ListenPort', "$HTTPS", '-SiteId', 'pos-test', '-ReadyAllowCidrs', '10.0.0.0/8',
    '-LogDir', "$W/logs", '-OutFile', $testConf)
Assert 'render: тестовый хост (свой InstallRoot, /health/ready только 10.0.0.0/8)' ($r.Code -eq 0 -and (Test-Path $testConf)) "код $($r.Code)"
$pt = [System.IO.File]::ReadAllText($prodConf)
Assert 'render: метки заполнены, строки CRLF, без BOM' (($pt -notmatch '@@') -and ($pt -notmatch "[^\r]`n") -and ([System.IO.File]::ReadAllBytes($prodConf)[0] -ne 0xEF))
$r = Invoke-Script $render @('-ServerName', 'API_Bad', '-CertFile', 'C:\x.crt', '-KeyFile', 'C:\x.key', '-OutFile', (Join-Path $WorkDir 'bad.conf'))
Assert 'render: неверное имя — код 2, файл не создан' ($r.Code -eq 2 -and -not (Test-Path (Join-Path $WorkDir 'bad.conf'))) "код $($r.Code)"
$r = Invoke-Script $render @('-ServerName', 'api.test.local', '-CertFile', 'C:\x.crt', '-KeyFile', 'C:\x.key', '-ReadyAllowCidrs', '10', '-OutFile', (Join-Path $WorkDir 'bad.conf'))
Assert 'render: неверный CIDR — код 2' ($r.Code -eq 2) "код $($r.Code)"

$common = @('-ApacheDir', $ApacheDir, '-ConfigFile', $conf, '-TargetDir', "$WorkDir\conf\extra", '-BackupRoot', "$WorkDir\backup", '-ListenPort', "$HTTPS")

# ---------- 2. enable: стоп-условия (на копиях конфигурации) ----------
function New-ConfCopy([string]$Name, [string]$Text) {
    $p = Join-Path $WorkDir "conf\$Name"
    [System.IO.File]::WriteAllText($p, (($Text -replace "`r`n", "`n") -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}
function Invoke-EnableOn([string]$Conf, [string]$Site, [string[]]$More = @()) {
    return Invoke-Script $enable (@('-ApacheDir', $ApacheDir, '-ConfigFile', $Conf, '-TargetDir', "$WorkDir\conf\extra", '-BackupRoot', "$WorkDir\backup", '-ListenPort', "$HTTPS", '-SiteConf', $Site) + $More)
}

# 2a. 1С в основной конфигурации без VirtualHost *:443
$noVhost = [regex]::Replace($customer, '(?s)<VirtualHost \*:' + $HTTPS + '>.*?</VirtualHost>(\r\n)?', '')
$noVhost = $noVhost -replace '(?m)^DocumentRoot .*$', ("SSLEngine on`r`nSSLCertificateFile `"$W/ssl/1c.test.local.crt`"`r`nSSLCertificateKeyFile `"$W/ssl/1c.test.local.key`"`r`n" + '$0')
$c = New-ConfCopy 'case-novhost.conf' $noVhost; $h0 = Get-Sha $c
$r = Invoke-EnableOn $c $prodConf @('-Apply')
Assert 'enable: 1С без <VirtualHost *:порт> — стоп (код 1), файл не изменён' ($r.Code -eq 1 -and (Get-Sha $c) -eq $h0 -and $r.Out -match 'нет именованного') "код $($r.Code)"

# 2b. 1С — хост по IP-адресу
$c = New-ConfCopy 'case-ipvhost.conf' ($customer -replace "<VirtualHost \*:$HTTPS>", "<VirtualHost 127.0.0.1:$HTTPS>"); $h0 = Get-Sha $c
$r = Invoke-EnableOn $c $prodConf @('-Apply')
Assert 'enable: 1С — хост по IP — стоп (код 1), файл не изменён' ($r.Code -eq 1 -and (Get-Sha $c) -eq $h0) "код $($r.Code)"

# 2c. Текущая конфигурация уже сломана
$c = New-ConfCopy 'case-broken.conf' ($customer + "`r`nNoSuchDirective on`r`n"); $h0 = Get-Sha $c
$r = Invoke-EnableOn $c $prodConf @('-Apply')
Assert 'enable: текущая конфигурация не проходит httpd -t — код 3, файл не изменён' ($r.Code -eq 3 -and (Get-Sha $c) -eq $h0) "код $($r.Code)"

# 2d. Блок <IfModule> включаемого модуля
$c = New-ConfCopy 'case-ifmodule.conf' ($customer + "`r`n<IfModule mod_rewrite.c>`r`n    RewriteEngine On`r`n</IfModule>`r`n"); $h0 = Get-Sha $c
$r = Invoke-EnableOn $c $prodConf @('-Apply')
Assert 'enable: <IfModule> включаемого модуля — стоп без -AcceptIfModuleBlocks' ($r.Code -eq 1 -and (Get-Sha $c) -eq $h0 -and $r.Out -match 'IfModule') "код $($r.Code)"

# 2e. Режим проверки (без -Apply) ничего не меняет
$r = Invoke-Script $enable ($common + @('-SiteConf', $prodConf))
Assert 'enable без -Apply: код 0, httpd.conf и conf\extra не изменены' ($r.Code -eq 0 -and (Get-Sha $conf) -eq $origHash -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos.conf") -and $r.Out -match 'proxy_module') "код $($r.Code)"
Assert 'enable: версия Apache выведена (httpd -v) и проверена' ($r.Out -match 'httpd -v: Server version: Apache/2\.4\.\d+')
Assert 'enable: сертификат проверен openssl, пробный запуск хоста API прошёл (HTTPS-запрос к пробному httpd)' (($r.Out -match 'Сертификат: соответствует ключу') -and ($r.Out -match 'Пробный запуск хоста API \(отдельный httpd\.exe -X\): порт 127\.0\.0\.1:\d+, https://api\.test\.local/health через пробный хост . HTTP \d{3}'))
Assert 'enable: после пробного запуска нет процессов и файлов *.trial.log' ((@(Get-ChildItem "$WorkDir\logs" -Filter '*.trial.log*' -ErrorAction SilentlyContinue).Count -eq 0) -and (@(Get-CimInstance Win32_Process -Filter "Name='rotatelogs.exe'" | Where-Object { ([string]$_.CommandLine).Contains('.trial.log') }).Count -eq 0))

# 2h. Маска ServerAlias *.<домен> у хоста 1С забрала бы имя API (APACHE-R3)
$c = New-ConfCopy 'case-wildalias.conf' ($customer.Replace("    ServerName 1c.test.local`r`n    SSLEngine on", "    ServerName 1c.test.local`r`n    ServerAlias *.test.local`r`n    SSLEngine on")); $h0 = Get-Sha $c
$wildOk = ([System.IO.File]::ReadAllText($c) -match 'ServerAlias \*\.test\.local')
$r = Invoke-EnableOn $c $prodConf @('-Apply')
Assert 'enable: ServerAlias *.test.local у 1С — стоп (код 1), файл не изменён' ($wildOk -and $r.Code -eq 1 -and (Get-Sha $c) -eq $h0 -and $r.Out -match 'маску') "код $($r.Code)"

# 2i–2m. То, чего не видит httpd -t (APACHE-R2): стоп до изменений
function New-RenderedSite([string]$Name, [string[]]$More) {
    $out = Join-Path $WorkDir "r2\$Name\optomstroy-pos.conf"
    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
    $p = [ordered]@{ '-ServerName' = 'api.test.local'; '-CertFile' = "$WorkDir\ssl\api.test.local.crt"; '-KeyFile' = "$WorkDir\ssl\api.test.local.key"
        '-InstallRoot' = "$WorkDir\root"; '-ApiPort' = "$UP"; '-ListenPort' = "$HTTPS"; '-LogDir' = "$W/logs"; '-OutFile' = $out }
    for ($i = 0; $i -lt $More.Count; $i += 2) { $p[$More[$i]] = $More[$i + 1] }
    $al = @(); foreach ($k in $p.Keys) { $al += @($k, $p[$k]) }
    $rr = Invoke-Script $render $al
    if ($rr.Code -ne 0) { throw "render ${Name}: $($rr.Out)" }
    return $out
}
$encKey = Join-Path $WorkDir 'ssl\api-enc.key'
$null = Invoke-Native $openssl @('pkey', '-in', (Join-Path $WorkDir 'ssl\api.test.local.key'), '-aes256', '-passout', 'pass:test-only', '-out', $encKey)  # check-secrets: allow — пароль тестового ключа, ключ удаляется в конце теста
$cases = @(
    @('mismatch', @('-KeyFile', "$WorkDir\ssl\1c.test.local.key"), 'не соответствуют друг другу'),
    @('enckey', @('-KeyFile', $encKey), 'не читается без пароля'),
    @('san', @('-ServerName', 'api-x.test.local'), 'subjectAltName'),
    @('rotatelogs', @('-RotateLogs', 'bin/no-such-rotatelogs.exe'), 'нет программы ротации'),
    @('logdir', @('-LogDir', "$W/no-such-logs"), 'нет папки журналов')
)
foreach ($cs in $cases) {
    $site = New-RenderedSite $cs[0] $cs[1]
    $r = Invoke-Script $enable ($common + @('-SiteConf', $site, '-Apply'))
    Assert "enable: $($cs[0]) — стоп до изменений (код 1, httpd.conf не изменён)" ($r.Code -eq 1 -and (Get-Sha $conf) -eq $origHash -and $r.Out -match [regex]::Escape($cs[2]) -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos.conf")) "код $($r.Code)"
}
# Пробный запуск сам по себе ловит несовпадение ключа (как перезапуск Apache, AH02565) — без проверки openssl.
$site = New-RenderedSite 'trial-direct' @('-KeyFile', "$WorkDir\ssl\1c.test.local.key")
$r = Invoke-Script $enable ($common + @('-SiteConf', $site, '-OpenSslExe', "$WorkDir\no-openssl.exe"))
Assert 'enable без openssl: пробный запуск ловит несовпадение сертификата и ключа (AH02565), код 1' ($r.Code -eq 1 -and $r.Out -match 'пробный запуск хоста API' -and $r.Out -match 'AH02565') "код $($r.Code)"
$r = Invoke-Script $enable ($common + @('-SiteConf', $site, '-OpenSslExe', "$WorkDir\no-openssl.exe", '-SkipTrialStart'))
Assert 'enable -SkipTrialStart: предупреждение «httpd -t не доказывает», код 0' ($r.Code -eq 0 -and $r.Out -match 'SkipTrialStart') "код $($r.Code)"

# 2e'. mod_remoteip с RemoteIPHeader — предупреждение (не стоп)
$c = New-ConfCopy 'case-remoteip.conf' ($customer + "`r`nLoadModule remoteip_module modules/mod_remoteip.so`r`nRemoteIPHeader X-Forwarded-For`r`n"); $h0 = Get-Sha $c
$r = Invoke-EnableOn $c $prodConf
Assert 'enable без -Apply: mod_remoteip с RemoteIPHeader — предупреждение, код 0, файл не изменён' ($r.Code -eq 0 -and (Get-Sha $c) -eq $h0 -and $r.Out -match 'RemoteIPHeader X-Forwarded-For') "код $($r.Code)"

# 2f. Синтаксическая ошибка в файле хоста — восстановление
$badSite = Join-Path $WorkDir 'syntax\optomstroy-pos.conf'
New-Item -ItemType Directory -Force (Split-Path $badSite) | Out-Null
[System.IO.File]::WriteAllText($badSite, ($pt -replace 'ServerSignature Off', "ServerSignature Off`r`n    BogusDirective on"))
# Пробный запуск поймал бы ошибку до изменений (код 1) — здесь он выключен, чтобы проверить восстановление.
$r0 = Invoke-Script $enable ($common + @('-SiteConf', $badSite))
Assert 'enable: синтаксическая ошибка в файле хоста — пробный запуск ловит её до изменений (код 1)' ($r0.Code -eq 1 -and $r0.Out -match 'BogusDirective' -and (Get-Sha $conf) -eq $origHash) "код $($r0.Code)"
$r = Invoke-Script $enable ($common + @('-SiteConf', $badSite, '-SkipTrialStart', '-Apply'))
$mf = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Sort-Object LastWriteTime -Descending)
$mfStatus = if ($mf.Count -gt 0) { (Get-Content $mf[0].FullName -Raw | ConvertFrom-Json).status } else { '' }
Assert 'enable: ошибка httpd -t после изменения — код 4, httpd.conf восстановлен байт в байт, файл хоста убран' `
    ($r.Code -eq 4 -and (Get-Sha $conf) -eq $origHash -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos.conf") -and $mfStatus -eq 'rolled-back') "код $($r.Code), манифест $mfStatus"

# 2g. Файл хоста меняет хост по умолчанию (лишний VirtualHost по IP) — восстановление по проверке httpd -S
$ipSite = Join-Path $WorkDir 'ipvhost\optomstroy-pos.conf'
New-Item -ItemType Directory -Force (Split-Path $ipSite) | Out-Null
[System.IO.File]::WriteAllText($ipSite, ($pt + "`r`n<VirtualHost 127.0.0.1:$HTTPS>`r`n    ServerName sneaky.test.local`r`n    SSLEngine on`r`n    SSLCertificateFile `"$W/ssl/api.test.local.crt`"`r`n    SSLCertificateKeyFile `"$W/ssl/api.test.local.key`"`r`n</VirtualHost>`r`n"))
$r = Invoke-Script $enable ($common + @('-SiteConf', $ipSite, '-Apply'))
Assert 'enable: после изменения httpd -S показал чужой хост для порта — код 5, восстановлено' `
    ($r.Code -eq 5 -and (Get-Sha $conf) -eq $origHash -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos.conf")) "код $($r.Code)"

# ---------- 3. enable: подключение рабочего и тестового хостов ----------
$r = Invoke-Script $enable ($common + @('-SiteConf', $prodConf, '-Apply'))
$after1 = [System.IO.File]::ReadAllText($conf)
$incProd = 'Include "' + "$W/conf/extra/optomstroy-pos.conf" + '"'
$expected1 = $customer.Replace('#LoadModule proxy_module', 'LoadModule proxy_module').Replace('#LoadModule proxy_http_module', 'LoadModule proxy_http_module').Replace('# LoadModule rewrite_module', 'LoadModule rewrite_module') + "`r`n" + $incProd + "`r`n"
Assert 'enable -Apply (рабочий): код 0' ($r.Code -eq 0) "код $($r.Code)"
Assert 'enable: httpd.conf = исходный + 3 раскомментированных LoadModule + CRLF + одна строка Include' ($after1 -ceq $expected1)
Assert 'enable: файл хоста скопирован в conf\extra' ((Get-Sha "$WorkDir\conf\extra\optomstroy-pos.conf") -eq (Get-Sha $prodConf))
$prodManifest = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
$h1 = Get-Sha $conf
$r = Invoke-Script $enable ($common + @('-SiteConf', $testConf, '-Apply'))
Assert 'enable -Apply (тестовый хост вторым): код 0' ($r.Code -eq 0) "код $($r.Code)"
$h2 = Get-Sha $conf
$testManifest = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { $_.Directory.Name -like '*-enable-optomstroy-pos-test.conf' -and (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
$r = Invoke-Script $enable ($common + @('-SiteConf', $prodConf, '-Apply'))
Assert 'enable повторно: стоп (уже подключено), файл не изменён' ($r.Code -eq 1 -and (Get-Sha $conf) -eq $h2 -and $r.Out -match 'уже') "код $($r.Code)"
$sOut = (Invoke-Native $httpd @('-d', (& $fw $ApacheDir), '-f', (& $fw $conf), '-S')).Out
Add-Content -LiteralPath $logFile -Value ("--- httpd -S после подключения:`r`n" + (($sOut -split "`r?`n" | Select-Object -First 8) -join "`r`n")) -Encoding UTF8
Assert 'httpd -S: default server *:18443 — 1c.test.local' ($sOut -match "(?m)^\*:$HTTPS\s+is a NameVirtualHost\s*\r?\n\s+default server 1c\.test\.local ")

# ---------- 4. Работа через Apache ----------
$stub = Start-Stub
$hp = Start-Httpd $conf
try {
    $x = Invoke-Curl "https://1c.test.local:$HTTPS/"
    Assert '1С по имени: 200 и страница 1С' ($x.Code -eq 200 -and $x.Body -match 'ONEC-MARKER') "код $($x.Code)"
    $x = Invoke-Curl "https://127.0.0.1:$HTTPS/"
    Assert '1С по IP без имени (хост по умолчанию): страница 1С' ($x.Code -eq 200 -and $x.Body -match 'ONEC-MARKER') "код $($x.Code)"
    $x = Invoke-Curl "https://other.test.local:$HTTPS/"
    Assert 'чужое имя: отвечает 1С (хост по умолчанию)' ($x.Code -eq 200 -and $x.Body -match 'ONEC-MARKER') "код $($x.Code)"
    $x = Invoke-Curl "http://api.test.local:$HTTP/"
    Assert 'порт 80-аналог (18080) не изменён: имя API там отдаёт 1С' ($x.Code -eq 200 -and $x.Body -match 'ONEC-MARKER') "код $($x.Code)"

    $before = @(Get-StubRequests).Count
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping?a=1" @('-H', 'X-Forwarded-For: 6.6.6.6', '-H', 'X-Forwarded-Host: evil.example', '-H', 'X-Forwarded-Proto: http', '-H', 'X-Forwarded-Server: evil')
    $j = $null; try { $j = $x.Body | ConvertFrom-Json } catch { }
    Assert '/api/* проксируется в API (метод, путь, запрос)' ($x.Code -eq 200 -and $null -ne $j -and $j.stub -and $j.method -eq 'GET' -and $j.url -eq '/api/v1/ping?a=1') "код $($x.Code)"
    if ($null -ne $j) {
        Assert 'X-Forwarded-For = IP клиента (подделка клиента отброшена)' ($j.headers.'x-forwarded-for' -eq '127.0.0.1') $j.headers.'x-forwarded-for'
        Assert 'X-Forwarded-Proto = https (клиентское значение заменено)' ($j.headers.'x-forwarded-proto' -eq 'https') $j.headers.'x-forwarded-proto'
        Assert 'X-Forwarded-Host = имя сайта (подделка отброшена)' ($j.headers.'x-forwarded-host' -eq "api.test.local:$HTTPS") $j.headers.'x-forwarded-host'
        Assert 'Host сохранён (ProxyPreserveHost)' ($j.headers.host -eq "api.test.local:$HTTPS") $j.headers.host
        Assert 'API видит соединение с loopback (trust proxy loopback)' ($j.remote -eq '127.0.0.1') $j.remote
    }
    $okHdr = $true; $det = @()
    foreach ($pair in @(@('Strict-Transport-Security', 'max-age=63072000; includeSubDomains'), @('X-Content-Type-Options', 'nosniff'), @('X-Frame-Options', 'DENY'),
            @('Content-Security-Policy', "frame-ancestors 'none'"), @('Referrer-Policy', 'strict-origin-when-cross-origin'))) {
        $v = Get-HeaderValues $x $pair[0]
        if ($v.Count -ne 1 -or $v[0] -ne $pair[1]) { $okHdr = $false; $det += "$($pair[0])=$($v -join ' | ')" }
    }
    Assert 'заголовки безопасности: каждый ровно один раз, значения как у Caddy' $okHdr ($det -join '; ')
    Assert 'X-Powered-By убран; Cache-Control: no-store от API сохранён; X-Request-Id от API' (((Get-HeaderValues $x 'X-Powered-By').Count -eq 0) -and ((Get-HeaderValues $x 'Cache-Control') -contains 'no-store') -and ((Get-HeaderValues $x 'X-Request-Id').Count -eq 1))
    $rid = '0195a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b'
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping" @('-H', "X-Request-Id: $rid")
    Assert 'X-Request-Id клиента доходит до API и возвращается' (((Get-HeaderValues $x 'X-Request-Id') -contains $rid)) ((Get-HeaderValues $x 'X-Request-Id') -join ',')
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/orders" @('-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', '{"a":1}')
    Assert 'POST /api/* с телом проксируется' ($x.Code -eq 200 -and $x.Body -match '"method":"POST"' -and $x.Body -match '"bodyLength":7') "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/integrations/onec/ping"
    Assert '/api/v1/integrations/* проксируется' ($x.Code -eq 200 -and $x.Body -match 'integrations') "код $($x.Code)"

    $x = Invoke-Curl "https://api.test.local:$HTTPS/health"
    Assert '/health — проксируется (200)' ($x.Code -eq 200 -and $x.Body -match '"url":"/health"') "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/health/ready"
    Assert '/health/ready с разрешённого адреса (127.0.0.1) — проксируется' ($x.Code -eq 200 -and $x.Body -match '"url":"/health/ready"') "код $($x.Code)"
    $n0 = @(Get-StubRequests).Count
    $x = Invoke-Curl "https://api-test.test.local:$HTTPS/health/ready"
    $x2 = Invoke-Curl "https://api-test.test.local:$HTTPS/health/ready/deep"
    Assert '/health/ready с неразрешённого адреса — 404, в API не передаётся' ($x.Code -eq 404 -and $x2.Code -eq 404 -and @(Get-StubRequests).Count -eq $n0) "коды $($x.Code)/$($x2.Code)"
    # Express сравнивает пути без учёта регистра — другой регистр не должен обходить запрет (APACHE-R1).
    $codes = @(); foreach ($u in @('/health/READY', '/health/Ready/', '/health/rEaDy/deep', '/HEALTH/ready')) { $codes += "$u=$((Invoke-Curl "https://api-test.test.local:$HTTPS$u").Code)" }
    Assert '/health/READY, /health/Ready/ … с неразрешённого адреса — 404, в API не передаётся' ((@($codes | Where-Object { $_ -notmatch '=404$' }).Count -eq 0) -and @(Get-StubRequests).Count -eq $n0) ($codes -join ' ')
    $x = Invoke-Curl "https://api.test.local:$HTTPS/health/READY"
    Assert '/health/READY с разрешённого адреса — проксируется' ($x.Code -eq 200 -and $x.Body -match '"url":"/health/READY"') "код $($x.Code)"
    $x = Invoke-Curl "https://api-test.test.local:$HTTPS/api/v1/ping"
    Assert 'тестовый хост api-test проксирует /api/*' ($x.Code -eq 200 -and $x.Body -match 'api-test\.test\.local') "код $($x.Code)"

    $n0 = @(Get-StubRequests).Count
    $bad = @('/', '/index.html', '/openapi.json', '/api', '/apix/v1', '/healthx', '/images/abc', "/images/$sha/huge", "/images/$($sha.ToUpper())/thumb", '/server-status', '/.env')
    $codes = @(); foreach ($u in $bad) { $codes += "$u=$((Invoke-Curl "https://api.test.local:$HTTPS$u").Code)" }
    Assert 'неизвестные пути — 404 и до API не доходят' ((@($codes | Where-Object { $_ -notmatch '=404$' }).Count -eq 0) -and @(Get-StubRequests).Count -eq $n0) ($codes -join ' ')
    $x = Invoke-Curl "https://api.test.local:$HTTPS/nope"
    Assert '404 — страница Apache без версии (ServerSignature Off), заголовки безопасности на месте' (($x.Body -notmatch 'Apache/2') -and ((Get-HeaderValues $x 'X-Frame-Options').Count -eq 1))

    $big = Join-Path $WorkDir 'body-1m1.bin'; $ok1 = Join-Path $WorkDir 'body-1m.bin'
    [System.IO.File]::WriteAllBytes($big, (New-Object byte[] 1048577)); [System.IO.File]::WriteAllBytes($ok1, (New-Object byte[] 1048576))
    $n0 = @(Get-StubRequests).Count
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/orders" @('-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', "@$big")
    Assert 'тело 1 МБ + 1 байт — 413, до API не дошло' ($x.Code -eq 413 -and @(Get-StubRequests).Count -eq $n0) "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/health" @('-X', 'POST', '--data-binary', "@$big")
    Assert 'тело 1 МБ + 1 байт на /health — 413' ($x.Code -eq 413) "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/orders" @('-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', "@$ok1")
    Assert 'тело ровно 1 МБ — проходит в API целиком' ($x.Code -eq 200 -and $x.Body -match '"bodyLength":1048576') "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/orders" @('-X', 'POST', '-H', 'Transfer-Encoding: chunked', '--data-binary', "@$big")
    Assert 'chunked без Content-Length (1 МБ + 1) — Apache пропускает, предел держит API (известное ограничение)' ($x.Code -eq 200 -and $x.Body -match '"bodyLength":1048577') "код $($x.Code)"

    $x = Invoke-Curl "https://api.test.local:$HTTPS/images/$sha/thumb"
    Assert 'фото: 200, image/webp, байты файла' ($x.Code -eq 200 -and ((Get-HeaderValues $x 'Content-Type') -contains 'image/webp') -and $x.Body.StartsWith('RIFF')) "код $($x.Code)"
    Assert 'фото: Cache-Control public, max-age=31536000, immutable (ровно один)' (((Get-HeaderValues $x 'Cache-Control') -join '|') -eq 'public, max-age=31536000, immutable') ((Get-HeaderValues $x 'Cache-Control') -join '|')
    $x = Invoke-Curl "https://api.test.local:$HTTPS/images/$sha/thumb.webp"
    Assert 'фото с суффиксом .webp — 200' ($x.Code -eq 200) "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/images/$sha/thumb" @('-I')
    Assert 'фото HEAD — 200' ($x.Code -eq 200) "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/images/$sha/card"
    Assert 'отсутствующее фото — 404 без Cache-Control' ($x.Code -eq 404 -and (Get-HeaderValues $x 'Cache-Control').Count -eq 0) "код $($x.Code)"
    $x = Invoke-Curl "https://api.test.local:$HTTPS/images/$sha/thumb" @('-X', 'POST', '--data-binary', 'x')
    Assert 'фото POST — 404' ($x.Code -eq 404) "код $($x.Code)"
    $x = Invoke-Curl "https://api-test.test.local:$HTTPS/images/$sha/thumb"
    Assert 'тестовый хост берёт фото из своей папки (рабочего фото там нет — 404)' ($x.Code -eq 404) "код $($x.Code)"

    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping" @('-H', 'Accept-Encoding: gzip')
    Assert 'сжатие: без mod_deflate ответ без Content-Encoding (необязательный модуль)' ((Get-HeaderValues $x 'Content-Encoding').Count -eq 0)

    if (-not $SkipLongPoll) {
        # Два ожидания параллельно: 25 с (long-poll оплаты) и 32 с (дольше таймаута 30 с).
        $lp = @()
        foreach ($lpWait in @(25, 32)) {
            $o = Join-Path $WorkDir "lp$lpWait.txt"
            $lp += [pscustomobject]@{ W = $lpWait; Out = $o; P = (Start-Process -FilePath $curl -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -ArgumentList @(
                        '-k', '-s', '-m', '60', '-o', 'NUL', '-w', '%{http_code}:%{time_total}', '--resolve', "api.test.local:${HTTPS}:127.0.0.1",
                        "https://api.test.local:$HTTPS/api/v1/payments/p1?wait=$lpWait")) }
        }
        foreach ($l in $lp) { $l.P.WaitForExit() }
        $o25 = (Get-Content $lp[0].Out -Raw).Trim() -split ':'; $o32 = (Get-Content $lp[1].Out -Raw).Trim() -split ':'
        Assert 'long-poll 25 с — ответ 200 через ~25 с (не обрывается)' ($o25[0] -eq '200' -and [double]::Parse($o25[1], [Globalization.CultureInfo]::InvariantCulture) -ge 24.9) ($o25 -join ' ')
        Assert 'ожидание 32 с — 502/504 около 30 с (таймаут как read_timeout Caddy)' ($o32[0] -in @('502', '504') -and [double]::Parse($o32[1], [Globalization.CultureInfo]::InvariantCulture) -lt 31.5 -and [double]::Parse($o32[1], [Globalization.CultureInfo]::InvariantCulture) -ge 29.5) ($o32 -join ' ')
    }

    # API остановлен → 503 без problem+json; после запуска — сразу 200 (retry=0).
    Stop-Process -Id $stub.Id -Force; Start-Sleep -Milliseconds 300
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping"
    Assert 'API остановлен — 503, тело не problem+json (приложение считает сервер недоступным)' ($x.Code -eq 503 -and $x.Body -notmatch '"code"' -and ((Get-HeaderValues $x 'Content-Type') -join '') -notmatch 'problem') "код $($x.Code)"
    $stub = Start-Stub
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping"
    Assert 'API снова запущен — первый же запрос 200 (без паузы retry)' ($x.Code -eq 200) "код $($x.Code)"
    Start-Sleep -Milliseconds 5600
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping"
    Assert 'запрос после 5,6 с простоя (Node закрыл keep-alive) — 200 (ttl=4)' ($x.Code -eq 200) "код $($x.Code)"

    # Управляющие байты и кавычка в пути (APACHE-R5): строка журнала всё равно JSON.
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/%01%0b%22x%5c"
    $acc = Join-Path $WorkDir 'logs\optomstroy-pos-access.log'
    Start-Sleep -Milliseconds 300
    $lines = @(if (Test-Path $acc) { Get-Content $acc } else { @() })
    $parsed = 0; $tzOk = 0; $ctl = $null
    foreach ($l in $lines) {
        try { $o = $l | ConvertFrom-Json; $parsed++; if ($o.t -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$') { $tzOk++ }; if ($o.r -like '*%01%0b%22x%5c*') { $ctl = $o.r } } catch { }
    }
    Assert 'журнал доступа хоста — JSON-строки в отдельном файле (rotatelogs)' ($lines.Count -gt 5 -and $parsed -eq $lines.Count -and (Test-Path (Join-Path $WorkDir 'logs\optomstroy-pos-test-access.log'))) "строк $($lines.Count), JSON $parsed"
    Assert 'журнал: запрос с %01%0b%22 записан JSON-строкой (поле r не раскодировано), время со смещением UTC' ($null -ne $ctl -and $tzOk -eq $lines.Count) "r=$ctl; со смещением $tzOk из $($lines.Count); пример: $(if ($lines.Count) { $lines[-1] })"

    # Пробный запуск enable рядом с работающим Apache (свободный порт, свой PidFile) — работающий не затронут.
    $xConf = Join-Path $WorkDir 'r2\x\optomstroy-pos-x.conf'
    New-Item -ItemType Directory -Force (Split-Path $xConf) | Out-Null
    $null = Invoke-Script $render @('-ServerName', 'api-x.test.local', '-CertFile', "$WorkDir\ssl\api-x.test.local.crt", '-KeyFile', "$WorkDir\ssl\api-x.test.local.key",
        '-InstallRoot', "$WorkDir\root", '-ApiPort', "$UP", '-ListenPort', "$HTTPS", '-SiteId', 'pos-x', '-LogDir', "$W/logs", '-OutFile', $xConf)
    $h3 = Get-Sha $conf
    $r = Invoke-Script $enable ($common + @('-SiteConf', $xConf))
    $x = Invoke-Curl "https://1c.test.local:$HTTPS/"
    Assert 'enable (проверка) при работающем Apache: пробный запуск прошёл, httpd.conf не изменён, 1С отвечает' ($r.Code -eq 0 -and $r.Out -match 'Пробный запуск хоста API' -and (Get-Sha $conf) -eq $h3 -and $x.Code -eq 200 -and -not $hp.HasExited) "код $($r.Code), 1С $($x.Code)"
} finally {
    $stopR = Stop-Httpd $conf
    if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue }
}
Assert 'httpd остановлен (порт 18443 свободен)' (-not (Get-NetTCPConnection -State Listen -LocalPort $HTTPS -ErrorAction SilentlyContinue))

# ---------- 5. disable: точный откат ----------
$r = Invoke-Script $disable @('-Manifest', $testManifest)
Assert 'disable без -Apply: код 0, ничего не изменено' ($r.Code -eq 0 -and (Test-Path "$WorkDir\conf\extra\optomstroy-pos-test.conf")) "код $($r.Code)"
$r = Invoke-Script $disable @('-Manifest', $testManifest, '-Apply')
Assert 'disable тестового хоста: код 0, httpd.conf = состояние после подключения рабочего (байт в байт)' ($r.Code -eq 0 -and (Get-Sha $conf) -eq $h1 -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos-test.conf")) "код $($r.Code)"
$r = Invoke-Script $disable @('-ApacheDir', $ApacheDir, '-BackupRoot', "$WorkDir\backup", '-Apply')
Assert 'disable рабочего (манифест найден сам): httpd.conf = исходный байт в байт, файл хоста удалён' ($r.Code -eq 0 -and (Get-Sha $conf) -eq $origHash -and -not (Test-Path "$WorkDir\conf\extra\optomstroy-pos.conf")) "код $($r.Code)"
$r = Invoke-Script $disable @('-Manifest', $prodManifest, '-Apply')
Assert 'disable повторно — стоп (уже отключено)' ($r.Code -eq 1) "код $($r.Code)"

# ---------- 6. disable: httpd.conf правили после подключения ----------
$r = Invoke-Script $enable ($common + @('-SiteConf', $prodConf, '-Apply'))
$m2 = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
$edited = [System.IO.File]::ReadAllText($conf) + "# правка администратора после подключения`r`nServerAdmin admin@test.local`r`n"
[System.IO.File]::WriteAllText($conf, $edited, (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Script $disable @('-Manifest', $m2, '-Apply')
$expected2 = $customer + "`r`n# правка администратора после подключения`r`nServerAdmin admin@test.local`r`n"
Assert 'disable после правки httpd.conf: убраны только Include и LoadModule, правка сохранена' ($r.Code -eq 0 -and ([System.IO.File]::ReadAllText($conf) -ceq $expected2)) "код $($r.Code)"
$t = Invoke-Native $httpd @('-d', (& $fw $ApacheDir), '-f', (& $fw $conf), '-t')
Assert 'после частичного отката httpd -t: Syntax OK' ($t.Code -eq 0)
[System.IO.File]::WriteAllBytes($conf, $origBytes)

# 6b. Два хоста, правка httpd.conf, отключение рабочего первым (APACHE-R4): модули остаются для тестового,
#     их выключает откат тестового.
$r1 = Invoke-Script $enable ($common + @('-SiteConf', $prodConf, '-Apply'))
$mp = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { $_.Directory.Name -like '*-enable-optomstroy-pos.conf' -and (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
$r2 = Invoke-Script $enable ($common + @('-SiteConf', $testConf, '-Apply'))
$mt = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { $_.Directory.Name -like '*-enable-optomstroy-pos-test.conf' -and (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
[System.IO.File]::WriteAllText($conf, ([System.IO.File]::ReadAllText($conf) + "# правка администратора после подключения`r`nServerAdmin admin@test.local`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Script $disable @('-Manifest', $mp, '-Apply')
$txt = [System.IO.File]::ReadAllText($conf)
$t = Invoke-Native $httpd @('-d', (& $fw $ApacheDir), '-f', (& $fw $conf), '-t')
Assert 'два хоста: отключение рабочего первым — код 0, модули оставлены для тестового, httpd -t OK' ($r1.Code -eq 0 -and $r2.Code -eq 0 -and $r.Code -eq 0 -and $t.Code -eq 0 -and $r.Out -match 'оставлен загруженным' -and
    $txt -match '(?m)^LoadModule proxy_module' -and $txt -notmatch [regex]::Escape($incProd) -and $txt -match 'optomstroy-pos-test\.conf') "коды $($r1.Code)/$($r2.Code)/$($r.Code), -t $($t.Code)"
$r = Invoke-Script $disable @('-Manifest', $mt, '-Apply')
# Пустая строка между хостами (CRLF перед Include тестового) остаётся: частичный откат удаляет только строки Include.
$expected2b = $customer + "`r`n`r`n# правка администратора после подключения`r`nServerAdmin admin@test.local`r`n"
Assert 'два хоста: затем отключение тестового — код 0, httpd.conf = исходный + правка (модули снова закомментированы)' ($r.Code -eq 0 -and ([System.IO.File]::ReadAllText($conf) -ceq $expected2b)) "код $($r.Code)"
[System.IO.File]::WriteAllBytes($conf, $origBytes)

# 6c. Администратор добавил <IfModule proxy_module> после подключения — модуль при частичном откате не выключается.
$r1 = Invoke-Script $enable ($common + @('-SiteConf', $prodConf, '-Apply'))
$mp = @(Get-ChildItem "$WorkDir\backup" -Recurse -Filter manifest.json | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -eq 'enabled' })[0].FullName
[System.IO.File]::WriteAllText($conf, ([System.IO.File]::ReadAllText($conf) + "<IfModule proxy_module>`r`n    ProxyTimeout 60`r`n</IfModule>`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Script $disable @('-Manifest', $mp, '-Apply')
$txt = [System.IO.File]::ReadAllText($conf)
Assert '<IfModule proxy_module> после подключения: proxy_module оставлен, proxy_http/rewrite закомментированы, Include убран' ($r1.Code -eq 0 -and $r.Code -eq 0 -and
    $txt -match '(?m)^LoadModule proxy_module' -and $txt -match '(?m)^#LoadModule proxy_http_module' -and $txt -match '(?m)^# LoadModule rewrite_module' -and $txt -notmatch [regex]::Escape($incProd)) "коды $($r1.Code)/$($r.Code)"
[System.IO.File]::WriteAllBytes($conf, $origBytes)

# ---------- 7. После отката: имя API уходит на 1С ----------
$stub = Start-Stub
$hp = Start-Httpd $conf
try {
    $x = Invoke-Curl "https://api.test.local:$HTTPS/api/v1/ping"
    Assert 'после отката и перезапуска: имя API обслуживает 1С (хоста API нет), 1С работает' ($x.Code -eq 404 -or $x.Body -match 'ONEC') "код $($x.Code)"
    $x = Invoke-Curl "https://1c.test.local:$HTTPS/"
    Assert 'после отката: 1С — 200' ($x.Code -eq 200 -and $x.Body -match 'ONEC-MARKER') "код $($x.Code)"
} finally {
    $null = Stop-Httpd $conf
    if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue }
}

# ---------- Итог и уборка ----------
Stop-TestProcesses
Remove-Item (Join-Path $WorkDir 'ssl\*.key') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $WorkDir 'body-*.bin'), (Join-Path $WorkDir 'curl.*') -Force -ErrorAction SilentlyContinue
$fail = @($script:results | Where-Object { -not $_.Ok })
Write-Log ("ИТОГ: {0} проверок, провалено {1}" -f $script:results.Count, $fail.Count)
if (-not $KeepWork) { Copy-Item (Join-Path $WorkDir 'scripts.log') (Join-Path (Split-Path -Parent $WorkDir) 'apache-tests.scripts.log') -Force -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
if ($fail.Count -gt 0) { exit 1 }
exit 0
