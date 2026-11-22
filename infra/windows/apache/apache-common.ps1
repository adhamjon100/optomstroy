<#
    Общие функции enable-apache-site.ps1 и disable-apache-site.ps1 (подключается через dot-source).
    Только чтение конфигурации и запуск httpd.exe с ключами проверки (-t, -S, -M, -D DUMP_INCLUDES):
    работающий Apache эти команды не останавливают и не перезапускают.
#>

Set-StrictMode -Version 2.0

# Обязательные модули хоста API (README.md, раздел «Модули»).
$script:OptomstroyRequiredModules = @(
    'ssl_module', 'proxy_module', 'proxy_http_module', 'headers_module', 'rewrite_module',
    'alias_module', 'mime_module', 'log_config_module', 'authz_core_module'
)
# Необязательные: сжатие JSON (как encode у Caddy). Включаются ключом -WithCompression.
$script:OptomstroyCompressionModules = @('deflate_module', 'filter_module')

# Кодировка «байт в символ» (ISO-8859-1): чтение и запись httpd.conf без изменения ни одного байта,
# в какой бы кодировке файл ни был (в комментариях публикации 1С бывает кириллица в cp1251 или UTF-8).
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Write-Step([string]$Message) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) }

function ConvertTo-NormPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $p = $Path.Trim().Trim('"') -replace '\\', '/'
    return $p.ToLowerInvariant()
}

function Get-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-ProcessArg([string]$Arg) {
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Запуск httpd.exe: код выхода и весь вывод (stdout + stderr). Сообщения Windows в выводе — в кодировке ANSI.
function Invoke-Httpd([string]$Exe, [string[]]$BaseArgs, [string[]]$Extra, [int]$TimeoutSec = 120) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($BaseArgs) + @($Extra) | ForEach-Object { ConvertTo-ProcessArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Default
    $psi.StandardErrorEncoding = [System.Text.Encoding]::Default
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Code = -1; Text = "httpd.exe не завершился за $TimeoutSec с"; Args = $psi.Arguments }
    }
    $p.WaitForExit()
    $err = $errTask.Result
    return [pscustomobject]@{ Code = $p.ExitCode; Text = ($out + $err).TrimEnd(); Args = $psi.Arguments }
}

# Разбор вывода httpd -S (раздел «VirtualHost configuration»). Каждая запись — адрес:порт и его хосты.
function Get-HttpdVhostTable([string]$Text) {
    $entries = New-Object System.Collections.ArrayList
    $cur = $null
    $inSection = $false
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^VirtualHost configuration:') { $inSection = $true; continue }
        if (-not $inSection) { continue }
        if ($line -match '^(?<addr>\S+):(?<port>\d+|\*)\s+is a NameVirtualHost$') {
            $cur = [pscustomobject]@{ Addr = $Matches.addr; Port = $Matches.port; Default = $null; Hosts = (New-Object System.Collections.ArrayList) }
            [void]$entries.Add($cur); continue
        }
        if ($line -match '^(?<addr>\S+):(?<port>\d+|\*)\s+(?<name>\S+) \((?<file>.+):(?<ln>\d+)\)$') {
            $h = [pscustomobject]@{ Name = $Matches.name; File = $Matches.file; Line = [int]$Matches.ln; Aliases = (New-Object System.Collections.ArrayList) }
            $cur = [pscustomobject]@{ Addr = $Matches.addr; Port = $Matches.port; Default = $h; Hosts = (New-Object System.Collections.ArrayList) }
            [void]$cur.Hosts.Add($h)
            [void]$entries.Add($cur); continue
        }
        if ($null -ne $cur -and $line -match '^\s+default server (?<name>\S+) \((?<file>.+):(?<ln>\d+)\)$') {
            $cur.Default = [pscustomobject]@{ Name = $Matches.name; File = $Matches.file; Line = [int]$Matches.ln; Aliases = $null }; continue
        }
        if ($null -ne $cur -and $line -match '^\s+port (?<port>\S+) namevhost (?<name>\S+) \((?<file>.+):(?<ln>\d+)\)$') {
            [void]$cur.Hosts.Add([pscustomobject]@{ Name = $Matches.name; File = $Matches.file; Line = [int]$Matches.ln; Aliases = (New-Object System.Collections.ArrayList) }); continue
        }
        if ($null -ne $cur -and $line -match '^\s+(wild )?alias (?<name>\S+)$') {
            if ($cur.Hosts.Count -gt 0) { [void]$cur.Hosts[$cur.Hosts.Count - 1].Aliases.Add($Matches.name) }
            continue
        }
        if ($line -match '^\S') { $inSection = $false; $cur = $null }
    }
    return , $entries
}

# Все имена (ServerName и ServerAlias), объявленные в выводе httpd -S.
function Get-HttpdDeclaredNames($Table) {
    $names = @()
    foreach ($e in $Table) {
        foreach ($h in $e.Hosts) {
            $names += $h.Name.ToLowerInvariant()
            if ($null -ne $h.Aliases) { foreach ($a in $h.Aliases) { $names += $a.ToLowerInvariant() } }
        }
    }
    return $names
}

# Псевдонимы из самих файлов конфигурации: httpd -S не печатает ServerAlias, когда на адресе:порту один хост.
# Читается блок <VirtualHost> от строки, указанной в httpd -S, до </VirtualHost>.
function Add-VhostAliasesFromConfig($Table) {
    $cache = @{}
    foreach ($e in $Table) {
        foreach ($h in $e.Hosts) {
            if ($null -eq $h.Aliases -or -not (Test-Path -LiteralPath $h.File -PathType Leaf)) { continue }
            if (-not $cache.ContainsKey($h.File)) { $cache[$h.File] = [System.IO.File]::ReadAllLines($h.File, $script:Latin1) }
            $lines = $cache[$h.File]
            for ($i = [Math]::Max(0, $h.Line - 1); $i -lt $lines.Count; $i++) {
                if ($i -gt $h.Line - 1 -and $lines[$i] -match '^\s*</VirtualHost\s*>') { break }
                if ($lines[$i] -match '^\s*ServerAlias\s+(?<a>.+?)\s*$') {
                    foreach ($a in ($Matches.a -split '\s+')) {
                        if ($a -and -not ($h.Aliases -contains $a)) { [void]$h.Aliases.Add($a) }
                    }
                }
            }
        }
    }
}

# Совпадает ли имя с ServerName/ServerAlias Apache (точно или по маске * и ?, без учёта регистра — как у Apache).
function Test-ApacheNameMatch([string]$Pattern, [string]$Name) {
    $p = $Pattern.ToLowerInvariant(); $n = $Name.ToLowerInvariant()
    if ($p -notmatch '[*?]') { return ($p -eq $n) }
    $rx = '^' + ([regex]::Escape($p) -replace '\\\*', '.*' -replace '\\\?', '.') + '$'
    return ($n -match $rx)
}

# Хосты списка (в порядке httpd -S = порядок выбора по имени), которые стоят раньше хоста из файла OwnFile
# (или все, если его нет) и чьё имя или псевдоним (в том числе маска *.домен) совпадает с Name:
# такой хост забирает запросы на Name себе, наш хост их не получит.
function Get-ShadowingHosts($HostList, [string]$Name, [string]$OwnFile = '') {
    $res = @()
    foreach ($h in $HostList) {
        if ($OwnFile -and (ConvertTo-NormPath $h.File) -eq (ConvertTo-NormPath $OwnFile) -and $h.Name.ToLowerInvariant() -eq $Name.ToLowerInvariant()) { break }
        $pats = @($h.Name); if ($null -ne $h.Aliases) { $pats += @($h.Aliases) }
        foreach ($p in $pats) {
            if (Test-ApacheNameMatch $p $Name) { $res += "$($h.Name) ($($h.File):$($h.Line)) — имя/псевдоним $p"; break }
        }
    }
    return , $res
}

# Версия Apache из вывода httpd -v («Server version: Apache/2.4.71 (Win64)»).
function Get-ApacheVersion([string]$Text) {
    if ($Text -match 'Apache/(?<v>\d+\.\d+\.\d+)') { return [version]$Matches.v }
    return $null
}

# Путь из директивы Apache: относительный — от ServerRoot; ${VAR} — по строкам Define (если заданы).
function Resolve-ApachePath([string]$ApacheDir, [string]$Path, [hashtable]$Defines = @{}) {
    $p = $Path.Trim().Trim('"')
    foreach ($k in $Defines.Keys) { $p = $p.Replace('${' + $k + '}', $Defines[$k]) }
    if ($p -match '\$\{') { return $null }
    $p = $p -replace '/', '\'
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $ApacheDir $p }
    return [System.IO.Path]::GetFullPath($p)
}

# Строки Define NAME value из файлов конфигурации.
function Get-HttpdDefines([string[]]$Files) {
    $d = @{}
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Latin1)) {
            if ($l -match '^\s*Define\s+(?<n>\w+)\s+(?<v>"[^"]*"|\S+)\s*$') { $d[$Matches.n] = $Matches.v.Trim('"') }
        }
    }
    return $d
}

# Файлы из директив хоста: сертификат, ключ, программа ротации журналов и путь журнала (CustomLog/ErrorLog "|… ").
function Get-SiteFileRefs([string]$SiteText) {
    $cert = $null; $key = $null; $pipes = @()
    if ($SiteText -match '(?m)^\s*SSLCertificateFile\s+(?<f>"[^"]+"|\S+)') { $cert = $Matches.f.Trim('"') }
    if ($SiteText -match '(?m)^\s*SSLCertificateKeyFile\s+(?<f>"[^"]+"|\S+)') { $key = $Matches.f.Trim('"') }
    foreach ($m in [regex]::Matches($SiteText, '(?m)^\s*(?:CustomLog|ErrorLog)\s+"\|(?<exe>\S+)\s+(?:-\S+\s+(?:\d+\s+)?)*(?<log>[^\s"]+)\s+\S+"')) {
        $pipes += [pscustomobject]@{ Exe = $m.Groups['exe'].Value; Log = $m.Groups['log'].Value }
    }
    return [pscustomobject]@{ Cert = $cert; Key = $key; Pipes = $pipes }
}

# Проверка сертификата и ключа через openssl.exe из комплекта Apache (только чтение файлов).
# Возвращает ошибки (стоп) и предупреждения.
function Test-SiteCertificate([string]$OpenSsl, [string]$CertFile, [string]$KeyFile, [string]$ServerName) {
    $errors = @(); $warnings = @()
    $c = Invoke-Httpd $OpenSsl @() @('x509', '-in', $CertFile, '-noout', '-pubkey')
    if ($c.Code -ne 0) { return [pscustomobject]@{ Errors = @("сертификат $CertFile не читается как PEM X.509:`n$($c.Text)"); Warnings = @() } }
    # Пустой пароль: незашифрованный ключ читается, зашифрованный — нет (Apache под службой не сможет спросить пароль).
    $k = Invoke-Httpd $OpenSsl @() @('pkey', '-in', $KeyFile, '-pubout', '-passin', 'pass:')  # check-secrets: allow — пустой пароль, проверка «ключ не зашифрован»
    if ($k.Code -ne 0) {
        $errors += "ключ $KeyFile не читается без пароля (зашифрован или не PEM). Apache-служба не сможет его загрузить: нужен ключ без пароля, доступный только учётной записи Apache и администраторам.`n$($k.Text)"
    } else {
        $norm = { param($t) (($t -split "`r?`n" | Where-Object { $_ -match '^[A-Za-z0-9+/=]+$' }) -join '') }
        if ((& $norm $c.Text) -ne (& $norm $k.Text) -or -not (& $norm $c.Text)) {
            $errors += "сертификат $CertFile и ключ $KeyFile не соответствуют друг другу (разные открытые ключи) — Apache не запустится (AH02565)"
        }
    }
    $e0 = Invoke-Httpd $OpenSsl @() @('x509', '-in', $CertFile, '-noout', '-checkend', '0')
    if ($e0.Code -ne 0) { $errors += "срок действия сертификата $CertFile истёк" }
    else {
        $e14 = Invoke-Httpd $OpenSsl @() @('x509', '-in', $CertFile, '-noout', '-checkend', '1209600')
        if ($e14.Code -ne 0) { $warnings += "сертификат $CertFile истекает в ближайшие 14 дней" }
    }
    $t = Invoke-Httpd $OpenSsl @() @('x509', '-in', $CertFile, '-noout', '-text')
    $dns = @([regex]::Matches($t.Text, 'DNS:(?<n>[^,\s]+)') | ForEach-Object { $_.Groups['n'].Value.ToLowerInvariant() })
    $ok = $false
    foreach ($d in $dns) {
        if ($d -eq $ServerName) { $ok = $true; break }
        # Маска сертификата *.домен покрывает ровно одну метку слева.
        if ($d.StartsWith('*.') -and $ServerName.EndsWith($d.Substring(1)) -and $ServerName.Substring(0, $ServerName.Length - $d.Length + 1) -notmatch '\.') { $ok = $true; break }
    }
    if (-not $ok) { $errors += "имени $ServerName нет в subjectAltName сертификата $CertFile (есть: $(if ($dns.Count) { $dns -join ', ' } else { 'нет SAN' })) — приложения не примут сертификат" }
    return [pscustomobject]@{ Errors = $errors; Warnings = $warnings }
}

# Строки LoadModule для пробного запуска: файл модуля для каждого нужного модуля.
# Uncomment — модули, которые enable раскомментирует (их файл известен). Возвращает строки и список неразрешённых.
function Get-TrialModuleLines([string]$ApacheDir, [string[]]$Modules, [string[]]$ConfigFiles, $Uncomment, [hashtable]$Kinds) {
    $defines = Get-HttpdDefines $ConfigFiles
    $active = @{}
    foreach ($f in $ConfigFiles) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Latin1)) {
            if ($l -match '^\s*LoadModule\s+(?<m>\w+)\s+(?<f>"[^"]+"|\S+)\s*$' -and -not $active.ContainsKey($Matches.m)) { $active[$Matches.m] = $Matches.f }
        }
    }
    foreach ($u in @($Uncomment)) { if ($u.After -match '^\s*LoadModule\s+(?<m>\w+)\s+(?<f>"[^"]+"|\S+)') { $active[$Matches.m] = $Matches.f } }
    $lines = @(); $unresolved = @()
    foreach ($m in $Modules) {
        if ($Kinds.ContainsKey($m) -and $Kinds[$m] -eq 'static') { continue }
        if (-not $active.ContainsKey($m)) { $unresolved += "$m (строка LoadModule не найдена)"; continue }
        $full = Resolve-ApachePath $ApacheDir $active[$m] $defines
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { $unresolved += "$m ($($active[$m]))"; continue }
        $lines += ('LoadModule {0} "{1}"' -f $m, ($full -replace '\\', '/'))
    }
    return [pscustomobject]@{ Lines = $lines; Unresolved = $unresolved }
}

# Разбор httpd -M с видом модуля: имя → static/shared.
function Get-HttpdModuleKinds([string]$Text) {
    $k = @{}
    foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw -match '^\s+(?<m>[a-z0-9_]+_module)\s+\((?<k>static|shared)\)') { $k[$Matches.m] = $Matches.k }
    }
    return $k
}

function Get-FreeLoopbackPort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Stop-ProcessTree([int]$ProcessId) {
    foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)) { Stop-ProcessTree ([int]$c.ProcessId) }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

# Пробный запуск: отдельный httpd.exe -X только с хостом API на свободном порту 127.0.0.1 (ServerRoot тот же,
# работающий Apache и 1С не затрагиваются). Ловит то, чего не видит httpd -t: несовпадение сертификата и ключа,
# ключ с паролем, недоступный rotatelogs или папку журналов. Журналы хоста пишутся в файлы *.trial.log
# (рядом с настоящими) и удаляются. Возвращает Ok и текст ошибки.
function Invoke-TrialStart([string]$HttpdExe, [string]$ApacheDir, [byte[]]$SiteBytes, [int]$ListenPort, [string[]]$ModuleLines, [string]$ServerName, [int]$TimeoutSec = 20) {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('optomstroy-apache-trial-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'docroot') | Out-Null
    $port = Get-FreeLoopbackPort
    $fw = { param($p) $p -replace '\\', '/' }
    $siteText = $script:Latin1.GetString($SiteBytes)
    $siteText = $siteText -replace ('(?m)^(\s*)<VirtualHost\s+\*:' + $ListenPort + '>'), ('$1<VirtualHost *:' + $port + '>')
    # Журналы хоста — в *.trial.log той же папки той же программой ротации.
    $trialLogs = @()
    $siteText = [regex]::Replace($siteText, '(?m)^(?<pre>\s*(?:CustomLog|ErrorLog)\s+"\|\S+\s+(?:-\S+\s+(?:\d+\s+)?)*)(?<log>[^\s"]+?)\.log(?<post>\s)', {
            param($m) $m.Groups['pre'].Value + $m.Groups['log'].Value + '.trial.log' + $m.Groups['post'].Value })
    foreach ($r in (Get-SiteFileRefs $siteText).Pipes) { $trialLogs += (Resolve-ApachePath $ApacheDir $r.Log) }
    $head = @(
        '# Пробный запуск enable-apache-site.ps1 (временный файл).'
        ('ServerRoot "{0}"' -f (& $fw $ApacheDir))
        ('Listen 127.0.0.1:{0}' -f $port)
    ) + $ModuleLines + @(
        'ServerName localhost'
        ('PidFile "{0}/httpd.pid"' -f (& $fw $work))
        ('ErrorLog "{0}/error.log"' -f (& $fw $work))
        'LogLevel warn'
        ('TypesConfig "{0}/mime.types"' -f (& $fw $work))
        ('DocumentRoot "{0}/docroot"' -f (& $fw $work))
        ''
    )
    [System.IO.File]::WriteAllText((Join-Path $work 'mime.types'), '')
    [System.IO.File]::WriteAllText((Join-Path $work 'stdin.txt'), '')
    $confPath = Join-Path $work 'trial.conf'
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($head -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllBytes($confPath, $bytes + $script:Latin1.GetBytes($siteText))

    $ok = $false; $detail = ''
    $p = $null
    try {
        # stdin — пустой файл: запрос пароля ключа не повиснет, а завершится ошибкой.
        $p = Start-Process -FilePath $HttpdExe -ArgumentList @('-X', '-d', ('"{0}"' -f (& $fw $ApacheDir)), '-f', ('"{0}"' -f (& $fw $confPath))) -PassThru -WindowStyle Hidden `
            -RedirectStandardInput (Join-Path $work 'stdin.txt') -RedirectStandardOutput (Join-Path $work 'stdout.txt') -RedirectStandardError (Join-Path $work 'stderr.txt')
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $listening = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            if ($p.HasExited) { break }
            $tc = New-Object System.Net.Sockets.TcpClient
            try { $tc.Connect('127.0.0.1', $port); $listening = $true } catch { } finally { $tc.Close() }
            if ($listening) { break }
        }
        if ($listening) {
            Start-Sleep -Milliseconds 700
            if ($p.HasExited) { $listening = $false }
        }
        if ($listening) {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path -LiteralPath $curl) {
                $cr = Invoke-Httpd $curl @() @('-k', '-s', '-o', 'NUL', '-m', '15', '-w', '%{http_code}', '--resolve', "${ServerName}:${port}:127.0.0.1", "https://${ServerName}:${port}/health")
                $code = ($cr.Text.Trim() -split '\s+')[-1]
                if ($code -match '^[1-5]\d\d$') { $ok = $true; $detail = "порт 127.0.0.1:$port, https://$ServerName/health через пробный хост — HTTP $code" }
                else { $detail = "TLS-запрос к пробному хосту не прошёл (curl: код $($cr.Code), ответ '$($cr.Text)')" }
            } else { $ok = $true; $detail = "порт 127.0.0.1:$port слушается (curl.exe нет — запрос не выполнялся)" }
        } elseif ($p.HasExited) { $detail = "httpd.exe завершился при запуске (код $($p.ExitCode))" }
        else { $detail = "httpd.exe не начал слушать 127.0.0.1:$port за $TimeoutSec с" }
    } catch {
        $detail = "пробный запуск не выполнен: $($_.Exception.Message)"
    } finally {
        if ($null -ne $p -and -not $p.HasExited) { Stop-ProcessTree $p.Id }
        Start-Sleep -Milliseconds 500
        # Программы ротации пробного запуска (их родитель уже остановлен).
        Get-CimInstance Win32_Process -Filter "Name='rotatelogs.exe'" -ErrorAction SilentlyContinue |
            Where-Object { ([string]$_.CommandLine).Contains('.trial.log') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ok) {
        $logs = @()
        foreach ($f in @((Join-Path $work 'stderr.txt'), (Join-Path $work 'stdout.txt'), (Join-Path $work 'error.log')) + $trialLogs) {
            if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) {
                $txt = ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::Default)).Trim()
                if ($txt) { $logs += "--- $(Split-Path -Leaf $f):`n" + (($txt -split "`r?`n" | Select-Object -Last 15) -join "`n") }
            }
        }
        if ($logs.Count) { $detail += "`n" + ($logs -join "`n") }
    }
    foreach ($f in $trialLogs) {
        if ($f) { Get-ChildItem -Path ($f + '*') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Ok = $ok; Detail = $detail; Port = $port }
}

# Разбор httpd -t -D DUMP_INCLUDES: корневой файл конфигурации и все подключённые файлы.
function Get-HttpdIncludes([string]$Text) {
    $root = $null
    $files = @()
    foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw -match '^\s*\(\*\)\s+(?<f>.+?)\s*$') { $root = $Matches.f; $files += $Matches.f; continue }
        if ($raw -match '^\s*\(\d+\)\s+(?<f>.+?)\s*$') { $files += $Matches.f }
    }
    return [pscustomobject]@{ Root = $root; Files = $files }
}

# Разбор httpd -M: имена загруженных модулей.
function Get-HttpdModules([string]$Text) {
    $mods = @()
    foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw -match '^\s+(?<m>[a-z0-9_]+_module)\s+\((static|shared)\)') { $mods += $Matches.m }
    }
    return $mods
}

# Строки файла с сохранением их окончаний (байт в байт): массив пар Text/Eol.
function Split-ConfigLines([string]$Text) {
    $list = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '(?<t>[^\r\n]*)(?<e>\r\n|\n|\r|$)')) {
        if ($m.Length -eq 0 -and $m.Index -ge $Text.Length) { break }
        [void]$list.Add([pscustomobject]@{ Text = $m.Groups['t'].Value; Eol = $m.Groups['e'].Value })
    }
    return , $list
}

function Join-ConfigLines($Lines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $Lines) { [void]$sb.Append($l.Text).Append($l.Eol) }
    return $sb.ToString()
}

# Строка Include для файла хоста: полный путь с прямыми косыми чертами в кавычках.
function Get-IncludeLine([string]$TargetPath) {
    return 'Include "' + ($TargetPath -replace '\\', '/') + '"'
}

# Есть ли в тексте httpd.conf активная (не закомментированная) строка Include/IncludeOptional нашего файла.
function Find-IncludeLines($Lines, [string]$TargetPath) {
    $want = ConvertTo-NormPath $TargetPath
    $idx = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Text -match '^\s*Include(Optional)?\s+(?<p>"[^"]+"|\S+)\s*$') {
            if ((ConvertTo-NormPath $Matches.p) -eq $want) { $idx += $i }
        }
    }
    return $idx
}

# Минимальные версии: SSLProtocol с TLSv1.3 у отдельного хоста под SNI, expr -R, ttl/retry у ProxyPass.
$script:ApacheMinVersion = [version]'2.4.42'
$script:OpenSslMinVersion = [version]'1.1.1'

# Учётная запись службы Apache (StartName) — ей нужны права чтения на папку фото (README, «Права NTFS»).
function Get-ApacheServiceAccount([string]$ServiceName) {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ($ServiceName -replace "'", "''")) -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $null }
    return [string]$svc.StartName
}

# Проверка службы Apache (только чтение): та же программа httpd.exe и тот же файл конфигурации.
function Test-ApacheService([string]$ServiceName, [string]$HttpdExe, [string]$ConfigFile, [string]$ApacheDir) {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ($ServiceName -replace "'", "''")) -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return "служба '$ServiceName' не найдена" }
    $path = [string]$svc.PathName
    if ((ConvertTo-NormPath $path).IndexOf((ConvertTo-NormPath $HttpdExe)) -lt 0) {
        return "служба '$ServiceName' запускает другую программу: $path (ожидалась $HttpdExe)"
    }
    $argsAll = $path
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters"
    $ca = (Get-ItemProperty -Path $reg -Name ConfigArgs -ErrorAction SilentlyContinue)
    if ($null -ne $ca) { $argsAll += ' ' + (@($ca.ConfigArgs) -join ' ') }
    if ($argsAll -match '(?:^|\s)-f\s+("[^"]+"|\S+)') {
        $f = $Matches[1].Trim('"')
        if (-not [System.IO.Path]::IsPathRooted($f)) { $f = Join-Path $ApacheDir $f }
        if ((ConvertTo-NormPath ([System.IO.Path]::GetFullPath($f))) -ne (ConvertTo-NormPath $ConfigFile)) {
            return "служба '$ServiceName' использует другой файл конфигурации: $f (указан $ConfigFile)"
        }
    }
    return $null
}
