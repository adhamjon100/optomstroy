<#
.SYNOPSIS
    Заполняет шаблон optomstroy-pos.conf.template и пишет готовый файл виртуального хоста Apache для API Оптомстрой.

.DESCRIPTION
    Только формирует файл: Apache не трогает, прав администратора не требует. Подключает файл к Apache
    администратор скриптом enable-apache-site.ps1.

    Рабочий контур:   -ServerName api.<домен>      -InstallRoot D:\Optomstroy       -ApiPort 3000 -SiteId pos
    Тестовый контур:  -ServerName api-test.<домен> -InstallRoot D:\Optomstroy-test  -ApiPort 3001 -SiteId pos-test
    (у теста своя папка установки: отметки журнала аудита пишутся рядом с папкой фото, общая папка смешала бы их).

.PARAMETER ServerName
    Имя сайта API (DNS-запись A на IP сервера), например api.example.kg. Только строчные буквы, цифры, точки и дефисы.
.PARAMETER CertFile
    Полный путь к сертификату для ServerName (с цепочкой, PEM).
.PARAMETER KeyFile
    Полный путь к закрытому ключу сертификата (PEM).
.PARAMETER InstallRoot
    Папка установки Оптомстрой (фото — <InstallRoot>\data\media\images). По умолчанию D:\Optomstroy.
.PARAMETER ApiPort
    Порт API на 127.0.0.1. По умолчанию 3000.
.PARAMETER ListenPort
    Порт HTTPS Apache, на котором уже обслуживается 1С (<VirtualHost *:порт>). По умолчанию 443.
.PARAMETER SiteId
    Короткое имя сайта для журналов (optomstroy-<SiteId>-access.log) и имени файла: pos, pos-test.
.PARAMETER ReadyAllowCidrs
    Адреса, с которых доступен /health/ready (остальным — 404). По умолчанию — частные сети и loopback (как private_ranges у Caddy).
.PARAMETER LogDir
    Папка журналов хоста. По умолчанию logs (относительно ServerRoot Apache). Без пробелов.
.PARAMETER RotateLogs
    Путь к rotatelogs.exe. По умолчанию bin/rotatelogs.exe (относительно ServerRoot Apache). Без пробелов.
.PARAMETER OutFile
    Куда записать готовый файл (например .\optomstroy-pos.conf). Существующий файл перезаписывается.

.EXAMPLE
    .\render-apache-conf.ps1 -ServerName api.example.kg -CertFile 'C:\Apache24\conf\ssl\api.example.kg.crt' `
        -KeyFile 'C:\Apache24\conf\ssl\api.example.kg.key' -OutFile .\optomstroy-pos.conf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerName,
    [Parameter(Mandatory = $true)][string]$CertFile,
    [Parameter(Mandatory = $true)][string]$KeyFile,
    [string]$InstallRoot = 'D:\Optomstroy',
    [ValidateRange(1, 65535)][int]$ApiPort = 3000,
    [ValidateRange(1, 65535)][int]$ListenPort = 443,
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')][string]$SiteId = 'pos',
    [string[]]$ReadyAllowCidrs = @('127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '::1/128', 'fd00::/8'),
    [string]$LogDir = 'logs',
    [string]$RotateLogs = 'bin/rotatelogs.exe',
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$TemplatePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $TemplatePath) { $TemplatePath = Join-Path $here 'optomstroy-pos.conf.template' }

function Stop-Render([string]$Message) {
    Write-Error -Message "render-apache-conf: $Message" -ErrorAction Continue
    exit 2
}

# Путь для директивы Apache: полный, прямые косые черты, без кавычек и подстановок ${...}.
function ConvertTo-ApachePath([string]$Path, [string]$What, [switch]$AllowRelative, [switch]$NoSpaces) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Stop-Render "$What не задан" }
    if ($Path -match '["$%\r\n]') { Stop-Render "$What содержит недопустимые символы (кавычка, `$, %, перевод строки): $Path" }
    if ($NoSpaces -and $Path -match '\s') { Stop-Render "$What не должен содержать пробелов (строка конвейера журнала): $Path" }
    $isAbs = $Path -match '^[A-Za-z]:[\\/]'
    if (-not $isAbs -and -not $AllowRelative) { Stop-Render "$What должен быть полным путём с буквой диска: $Path" }
    $p = $Path -replace '\\', '/'
    if ($p.Length -gt 3) { $p = $p.TrimEnd('/') }
    return $p
}

function Test-Cidr([string]$Cidr) {
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    # TryParse принимает и «10» как 0.0.0.10 — IPv4 только в виде четырёх чисел через точку.
    if ($parts[0] -notmatch ':' -and $parts[0] -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { return $false }
    $bits = 0
    if (-not [int]::TryParse($parts[1], [ref]$bits)) { return $false }
    $max = if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { 128 } else { 32 }
    return ($bits -ge 0 -and $bits -le $max)
}

$name = $ServerName.Trim()
if ($name -cnotmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$') {
    Stop-Render "ServerName должен быть полным DNS-именем строчными буквами (например api.example.kg): $ServerName"
}
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { Stop-Render "нет шаблона: $TemplatePath" }
if ($ApiPort -eq $ListenPort) { Stop-Render 'ApiPort и ListenPort совпадают' }

$cert = ConvertTo-ApachePath $CertFile 'CertFile'
$key = ConvertTo-ApachePath $KeyFile 'KeyFile'
$root = ConvertTo-ApachePath $InstallRoot 'InstallRoot'
$logs = ConvertTo-ApachePath $LogDir 'LogDir' -AllowRelative -NoSpaces
$rotate = ConvertTo-ApachePath $RotateLogs 'RotateLogs' -AllowRelative -NoSpaces

if ($null -eq $ReadyAllowCidrs -or $ReadyAllowCidrs.Count -eq 0) { Stop-Render 'ReadyAllowCidrs пуст' }
$conds = @()
foreach ($c in $ReadyAllowCidrs) {
    $c = $c.Trim()
    if (-not (Test-Cidr $c)) { Stop-Render "ReadyAllowCidrs: не адрес/префикс: $c" }
    $conds += "! -R '$c'"
}
$denyExpr = $conds -join ' && '

$map = [ordered]@{
    '@@SERVER_NAME@@'     = $name
    '@@CERT_FILE@@'       = $cert
    '@@KEY_FILE@@'        = $key
    '@@INSTALL_ROOT@@'    = $root
    '@@API_PORT@@'        = [string]$ApiPort
    '@@LISTEN_PORT@@'     = [string]$ListenPort
    '@@SITE_ID@@'         = $SiteId
    '@@SITE_KEY@@'        = ($SiteId -replace '-', '_')
    '@@READY_DENY_EXPR@@' = $denyExpr
    '@@LOG_DIR@@'         = $logs
    '@@ROTATELOGS@@'      = $rotate
}

$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $TemplatePath).ProviderPath, (New-Object System.Text.UTF8Encoding($false)))
foreach ($k in $map.Keys) { $text = $text.Replace($k, $map[$k]) }
$left = [regex]::Matches($text, '@@[A-Z_]+@@')
if ($left.Count -gt 0) { Stop-Render ("в шаблоне остались незаполненные метки: " + (($left | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', ')) }

# Строки — CRLF (Windows), кодировка UTF-8 без BOM (BOM в начале файла конфигурации Apache не нужен).
$text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
$outFull = [System.IO.Path]::GetFullPath($(if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).ProviderPath $OutFile }))
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { Stop-Render "нет папки для результата: $outDir" }
[System.IO.File]::WriteAllText($outFull, $text, (New-Object System.Text.UTF8Encoding($false)))

foreach ($f in @($CertFile, $KeyFile)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Warning "файл пока не найден (Apache не пройдёт проверку httpd -t, пока его нет): $f" }
}
if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'data\media\images') -PathType Container)) {
    Write-Warning "папка фото пока не найдена: $(Join-Path $InstallRoot 'data\media\images') (на запросы фото будет 404)"
}
Write-Output "render-apache-conf: готово: $outFull (сайт $name, API 127.0.0.1:$ApiPort, *:$ListenPort)"
exit 0
