# OptomstroyCommon.ps1 — общие функции скриптов установки Optomstroy POS под Windows Server 2022
# (install.ps1, update.ps1, rollback.ps1, status.ps1, uninstall.ps1). Подключается через dot-source.
# Только Windows PowerShell 5.1: без операторов PS 7 (?:, ??, &&, ||), без -AsHashtable.
# Значения секретов этими функциями не печатаются и в журнал не пишутся.

Set-StrictMode -Version 2.0

$script:OpsServiceNames = @('OptomstroyApi', 'OptomstroyWorker', 'OptomstroyBackup')
$script:OpsPgServiceName = 'OptomstroyPostgres'
$script:OpsSidAdministrators = 'S-1-5-32-544'
$script:OpsSidSystem = 'S-1-5-18'
$script:OpsLogFile = $null
$script:OpsLogQuiet = $false
$script:OpsSecretPattern = '(?i)(password|passwd|secret|token|pepper|private)\s*[=:]\s*\S+'

# ---------- журнал ----------
function Initialize-OpsLog([string]$LogDir, [string]$Name) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $script:OpsLogFile = Join-Path $LogDir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch { }
    Write-OpsLog "журнал: $script:OpsLogFile"
    return $script:OpsLogFile
}

# Строка в журнал и на экран. Строки, похожие на «пароль=значение», маскируются (вывод дочерних программ).
function Write-OpsLog {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message, [Parameter(Position = 1)][ValidateSet('INFO', 'STEP', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $safe = [regex]::Replace($Message, $script:OpsSecretPattern, { param($m) ($m.Value -replace '([=:]\s*)\S+$', '$1***') })
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $safe
    if ($script:OpsLogFile) {
        try { [System.IO.File]::AppendAllText($script:OpsLogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    # status.ps1 -Json: на экран (stdout) — только JSON; строки журнала туда не попадают.
    if ($script:OpsLogQuiet) { return }
    switch ($Level) {
        'STEP' { Write-Host ''; Write-Host "== $safe" -ForegroundColor Cyan }
        'WARN' { Write-Host "ВНИМАНИЕ: $safe" -ForegroundColor Yellow }
        'ERROR' { Write-Host "ОШИБКА: $safe" -ForegroundColor Red }
        'OK' { Write-Host "  ok: $safe" -ForegroundColor Green }
        default { Write-Host "  $safe" }
    }
}

# Запуск дочернего .ps1 в этом же процессе; весь его вывод (Write-Host, предупреждения, ошибки) — в журнал.
# Код возврата: $LASTEXITCODE скрипта (exit N) или 0; исключение скрипта пробрасывается дальше.
function Invoke-OpsScript([string]$Path, [hashtable]$Params) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "нет скрипта: $Path" }
    $shown = @()
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($v -is [bool] -or $v -is [System.Management.Automation.SwitchParameter]) { if ($v) { $shown += "-$k" } }
        else { $shown += "-$k $v" }
    }
    Write-OpsLog ("запуск: {0} {1}" -f $Path, ($shown -join ' '))
    $global:LASTEXITCODE = 0
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Path @Params *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-OpsLog ([string]$_) 'ERROR' }
            elseif ($_ -is [System.Management.Automation.WarningRecord]) { Write-OpsLog ([string]$_.Message) 'WARN' }
            else { Write-OpsLog ([string]$_) }
        }
    } finally {
        $ErrorActionPreference = $eap
    }
    return [int]$LASTEXITCODE
}

# Минимальное окружение Windows для дочерних процессов node.exe (как inheritEnvironment=false у OptomstroySvc.exe):
# системная переменная с тем же именем (DATABASE_URL, NODE_OPTIONS, HTTPS_PROXY…) не перекроет файл настроек.
function Get-OpsBaseEnvironment {
    $names = @('SystemRoot', 'windir', 'SystemDrive', 'ComSpec', 'PATHEXT', 'Path', 'TEMP', 'TMP', 'USERPROFILE', 'ProgramData',
        'ProgramFiles', 'ProgramFiles(x86)', 'CommonProgramFiles', 'COMPUTERNAME', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE',
        'OS', 'APPDATA', 'LOCALAPPDATA', 'HOMEDRIVE', 'HOMEPATH', 'USERNAME', 'USERDOMAIN')
    $env = @{}
    foreach ($n in $names) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($null -ne $v -and $v -ne '') { $env[$n] = $v }
    }
    return $env
}

# Запуск программы с перехватом stdout/stderr (UTF-8) в журнал. -CleanEnvironment — только базовое окружение и -Environment.
# Возвращает @{ Code; Out (строки stdout) }.
function Invoke-OpsProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{},
        [switch]$CleanEnvironment,
        [int]$TimeoutSec = 1800,
        [switch]$QuietStdout
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-OpsCmdArg $_ }) -join ' ')
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($CleanEnvironment) {
        $psi.EnvironmentVariables.Clear()
        $base = Get-OpsBaseEnvironment
        foreach ($k in $base.Keys) { $psi.EnvironmentVariables[$k] = $base[$k] }
    }
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    Write-OpsLog ("запуск: {0} {1}" -f $FilePath, $psi.Arguments)
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "$FilePath не завершился за $TimeoutSec с"
    }
    $p.WaitForExit()
    $outLines = @(($so.Result -split "`r?`n") | Where-Object { $_ -ne '' })
    $errLines = @(($se.Result -split "`r?`n") | Where-Object { $_ -ne '' })
    if (-not $QuietStdout) { foreach ($ln in $outLines) { Write-OpsLog "  | $ln" } }
    foreach ($ln in $errLines) { Write-OpsLog "  ! $ln" }
    return @{ Code = $p.ExitCode; Out = $outLines; Err = $errLines }
}

function ConvertTo-OpsCmdArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\', 2 * $bs + 1); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\', 2 * $bs) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Последняя строка JSON из вывода ops-tool / pos-backup.
function ConvertFrom-OpsJsonLine([string[]]$Lines) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $ln = $Lines[$i].Trim()
        if ($ln.StartsWith('{')) { try { return ($ln | ConvertFrom-Json) } catch { } }
    }
    return $null
}

# ---------- раскладка ----------
# Полный путь относительно текущей папки PowerShell (не .NET): относительные пути параметров работают как ожидается.
function Resolve-OpsPath([string]$Path) {
    if (-not $Path) { return $Path }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).ProviderPath $Path }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-OpsLayout([string]$InstallRoot, [string]$BackupRoot = '') {
    $r = Resolve-OpsPath $InstallRoot
    $L = [ordered]@{
        Root = $r
        Releases = Join-Path $r 'releases'
        Current = Join-Path $r 'current'
        Config = Join-Path $r 'config'
        Secrets = Join-Path $r 'secrets'   # check-secrets: allow — путь к папке секретов, не значение
        Data = Join-Path $r 'data'
        PgData = Join-Path $r 'data\pg'
        Media = Join-Path $r 'data\media'
        AuditAnchors = Join-Path $r 'data\audit-anchors'
        WalSpool = Join-Path $r 'data\walspool'
        Logs = Join-Path $r 'logs'
        State = Join-Path $r 'state'
        Incoming = Join-Path $r 'incoming'
        StateFile = Join-Path $r 'state\install-state.json'
        PublicStateFile = Join-Path $r 'logs\deploy-state.json'
        ReleasesLog = Join-Path $r 'state\releases.log'
        InstallJson = Join-Path $r 'config\install.json'
        BackupRoot = ''
    }
    if ($BackupRoot) { $L.BackupRoot = Resolve-OpsPath $BackupRoot }
    return $L
}

# Отметка «папка принадлежит Optomstroy»: install.ps1 пишет её в InstallRoot и BackupRoot до смены прав NTFS.
$script:OpsRootMarker = '.optomstroy-root'
$script:OpsKnownRootEntries = @{
    install = @('releases', 'current', 'config', 'secrets', 'data', 'logs', 'state', 'incoming', '.optomstroy-root')
    backup = @('dumps', 'pitr', 'media', 'state', 'wal', 'logs', '.optomstroy-root')
}

# Проверка до смены прав: icacls /inheritance:r /grant:r снимает все прежние права с папки и всего, что в ней лежит.
# Допускается: папки нет; пустая папка; наша папка (есть отметка .optomstroy-root или в ней только наши имена).
# Не допускается: корень тома (D:\) и чужая непустая папка (например, общая папка копий SQL Server или 1С).
# Возвращает текст причины отказа или $null.
function Test-OpsDedicatedRoot([string]$Path, [ValidateSet('install', 'backup')][string]$Kind) {
    $full = Resolve-OpsPath $Path
    if ($full.Length -le 3 -or [System.IO.Path]::GetPathRoot($full).TrimEnd('\') -eq $full.TrimEnd('\')) {
        return "$full — корень тома: нужна отдельная папка (например $($full.TrimEnd('\'))\Optomstroy)"
    }
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return "$full — файл, а не папка" }
    if (Test-Path -LiteralPath (Join-Path $full $script:OpsRootMarker)) { return $null }
    $entries = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop | ForEach-Object { $_.Name })
    if ($entries.Count -eq 0) { return $null }
    $known = $script:OpsKnownRootEntries[$Kind]
    $foreign = @($entries | Where-Object { $known -notcontains $_.ToLowerInvariant() })
    if ($foreign.Count -eq 0) { return $null }
    $shown = ($foreign | Select-Object -First 5) -join ', '
    return "$full — уже существующая непустая папка не Optomstroy (в ней: $shown): установка сняла бы с неё и всего содержимого прежние права NTFS (например, у служб SQL Server или 1С). Нужна отдельная новая папка"
}

function Set-OpsRootMarker([string]$Path, [string]$Kind) {
    $f = Join-Path $Path $script:OpsRootMarker
    if (-not (Test-Path -LiteralPath $f)) { Write-OpsUtf8 $f ("optomstroy {0} root; created {1}`n" -f $Kind, (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) }
}

# SID службы NT SERVICE\<имя> без обращения к SCM (служба уже может быть удалена): S-1-5-80- и SHA-1 имени службы
# в верхнем регистре (UTF-16LE), пять 32-битных чисел little-endian — так Windows вычисляет SID служб.
function Get-OpsServiceSid([string]$Name) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $h = $sha.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($Name.ToUpperInvariant())) } finally { $sha.Dispose() }
    $parts = @()
    for ($i = 0; $i -lt 20; $i += 4) { $parts += [string][System.BitConverter]::ToUInt32($h, $i) }
    return 'S-1-5-80-' + ($parts -join '-')
}

function Test-OpsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-OpsUtf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-OpsJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $t = [System.IO.File]::ReadAllText($Path)
    if ($t.Length -gt 0 -and [int]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
    return ($t | ConvertFrom-Json)
}

function Write-OpsJson([string]$Path, $Object) {
    $tmp = "$Path.tmp"
    Write-OpsUtf8 $tmp (($Object | ConvertTo-Json -Depth 8) + "`n")
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---------- состояние установки ----------
# state\install-state.json (только администраторы) и его копия без секретов logs\deploy-state.json (читает posdeploy).
function Read-OpsState($L) {
    $s = Read-OpsJson $L.StateFile
    if ($null -eq $s) { return $null }
    return $s
}

function Save-OpsState($L, [hashtable]$State) {
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-OpsJson $L.StateFile $State
    $public = [ordered]@{
        currentVersion = $State.currentVersion
        previousVersion = $State.previousVersion
        installedUtc = $State.installedUtc
        updatedUtc = $State.updatedUtc
        lastOperation = $State.lastOperation
        lastOperationStatus = $State.lastOperationStatus
        devTest = $State.devTest
        apiPort = $null
        pgPort = $null
        backupRoot = $null
    }
    $ij = Read-OpsJson $L.InstallJson
    if ($null -ne $ij) { $public.apiPort = $ij.apiPort; $public.pgPort = $ij.pgPort; $public.backupRoot = $ij.backupRoot }
    try { Write-OpsJson $L.PublicStateFile $public } catch { Write-OpsLog "не записан $($L.PublicStateFile): $($_.Exception.Message)" 'WARN' }
}

function ConvertTo-OpsHashtable($Obj) {
    $h = @{}
    if ($null -eq $Obj) { return $h }
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Add-OpsReleasesLog($L, [string]$Text) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Text
    [System.IO.File]::AppendAllText($L.ReleasesLog, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- junction current ----------
function Get-OpsJunctionTarget([string]$Link) {
    if (-not (Test-Path -LiteralPath $Link)) { return $null }
    $item = Get-Item -LiteralPath $Link -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "$Link — обычная папка, а не ссылка (junction); разберитесь вручную" }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    if ($null -eq $t) { return $null }
    return [System.IO.Path]::GetFullPath([string]$t)
}

function Set-OpsJunction([string]$Link, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw "нет папки релиза $Target" }
    if (Test-Path -LiteralPath $Link) {
        $null = Get-OpsJunctionTarget $Link   # проверка: это ссылка, а не папка с данными
        # Удаляется только сама ссылка (не содержимое релиза).
        [System.IO.Directory]::Delete($Link, $false)
    }
    $out = & cmd.exe /c mklink /J "$Link" "$Target" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink /J $Link -> ${Target}: $out" }
    $now = Get-OpsJunctionTarget $Link
    if ($now -ne [System.IO.Path]::GetFullPath($Target)) { throw "ссылка $Link указывает на $now, ожидалось $Target" }
    Write-OpsLog "current -> $Target" 'OK'
}

# ---------- релиз ----------
function Get-OpsReleaseInfo([string]$Dir) {
    $j = Read-OpsJson (Join-Path $Dir 'release.json')
    if ($null -eq $j) { throw "нет release.json в $Dir" }
    if ($j.kind -ne 'optomstroy-server-win-x64') { throw "release.json в $Dir — не пакет сервера Optomstroy под Windows" }
    return $j
}

function Get-OpsReleaseMigrations([string]$ReleaseDir) {
    $dir = Join-Path $ReleaseDir 'api\migrations'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.sql' | Where-Object { $_.Name -match '^\d{4}_' } |
            ForEach-Object { $_.Name.Substring(0, 4) } | Sort-Object -Unique)
}

function Get-OpsReleasePgBossVersion([string]$ReleaseDir) {
    $j = Read-OpsJson (Join-Path $ReleaseDir 'api\node_modules\pg-boss\package.json')
    if ($null -eq $j) { return '' }
    return [string]$j.version
}

# $true, если $Path — сама папка $Dir или лежит внутри неё (сравнение полных путей без учёта регистра).
function Test-OpsPathUnder([string]$Path, [string]$Dir) {
    if (-not $Path -or -not $Dir) { return $false }
    $p = (Resolve-OpsPath $Path).TrimEnd('\') + '\'
    $d = (Resolve-OpsPath $Dir).TrimEnd('\') + '\'
    return $p.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)
}

# SHA256 файла пакета: из -Sha256 или из файла SHA256SUMS (строка «<hex>  <имя zip>»): явного -Sha256Sums или рядом с
# пакетом. Файл SHA256SUMS внутри папки установки не принимается: в incoming пишет posdeploy, и тот, кто может
# подложить zip, подложил бы и «совпадающий» SHA256SUMS.txt — проверка была бы пустой (ожидаемое значение должно
# прийти отдельным каналом: -Sha256 из письма или файл из папки администратора).
function Get-OpsExpectedZipHash([string]$Zip, [string]$Sha256, [string]$SumsFile, [string]$InstallRoot = '') {
    if ($Sha256) {
        if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw '-Sha256: ожидается 64 шестнадцатеричных символа' }
        return $Sha256.ToLowerInvariant()
    }
    if (-not $SumsFile) { $SumsFile = Join-Path (Split-Path -Parent $Zip) 'SHA256SUMS.txt' }
    if ($InstallRoot -and (Test-OpsPathUnder $SumsFile $InstallRoot)) {
        throw "SHA256 пакета нельзя брать из $SumsFile (внутри $InstallRoot, в incoming пишет posdeploy): укажите -Sha256 <значение, полученное отдельным каналом> или -Sha256Sums <файл из папки администратора>"
    }
    if (-not (Test-Path -LiteralPath $SumsFile)) { throw "нет SHA256 пакета: укажите -Sha256 (значение, полученное отдельным каналом) или -Sha256Sums (нет $SumsFile)" }
    $name = Split-Path -Leaf $Zip
    foreach ($line in [System.IO.File]::ReadAllLines($SumsFile)) {
        if ($line -match '^([0-9A-Fa-f]{64}) [ *](.+)$' -and $Matches[2].Trim() -eq $name) { return $Matches[1].ToLowerInvariant() }
    }
    throw "в $SumsFile нет строки для $name"
}

# Копия пакета в закрытую папку releases, сверка SHA256 копии, распаковка во временную папку, сверка SHA256SUMS
# всех файлов, переименование в releases\<версия>. Возвращает @{ Version; Dir; Reused }.
function Install-OpsReleaseZip {
    param([Parameter(Mandatory = $true)]$L, [Parameter(Mandatory = $true)][string]$Zip, [string]$Sha256 = '', [string]$SumsFile = '')
    if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "нет пакета $Zip" }
    $expected = Get-OpsExpectedZipHash $Zip $Sha256 $SumsFile $L.Root
    if (-not (Test-Path -LiteralPath $L.Releases)) { New-Item -ItemType Directory -Force -Path $L.Releases | Out-Null }
    $tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $copy = Join-Path $L.Releases ".incoming-$tag.zip"
    $partial = Join-Path $L.Releases ".partial-$tag"
    try {
        # Сверяется КОПИЯ: файл в incoming может изменить тот, у кого есть право записи туда (posdeploy).
        Copy-Item -LiteralPath $Zip -Destination $copy
        $actual = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA256 пакета не совпадает: ожидалось $expected, у файла $actual — пакет не используется" }
        Write-OpsLog "SHA256 пакета совпадает: $actual" 'OK'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($copy, $partial)
        $info = Get-OpsReleaseInfo $partial
        $ver = [string]$info.version
        if ($ver -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,40}$') { throw "недопустимая версия в release.json: $ver" }
        $sum = Invoke-OpsProcess -FilePath (Join-Path $partial 'node\node.exe') -ArgumentList @((Join-Path $partial 'scripts\ops-tool.mjs'), 'sums-verify', '--dir', $partial) -CleanEnvironment
        if ($sum.Code -ne 0) { throw "файлы пакета не совпадают с SHA256SUMS.txt (подробности выше) — пакет не используется" }
        Write-OpsLog "SHA256SUMS.txt: все файлы пакета совпадают" 'OK'
        $dest = Join-Path $L.Releases $ver
        $reused = $false
        if (Test-Path -LiteralPath $dest) {
            $chk = Invoke-OpsProcess -FilePath (Join-Path $partial 'node\node.exe') -ArgumentList @((Join-Path $partial 'scripts\ops-tool.mjs'), 'sums-verify', '--dir', $dest) -CleanEnvironment -QuietStdout
            if ($chk.Code -ne 0) { throw "папка $dest уже есть и отличается от пакета — удалите её вручную (если это не активный релиз) и повторите" }
            Write-OpsLog "релиз $ver уже распакован в $dest и совпадает с пакетом" 'OK'
            $reused = $true
        } else {
            Move-Item -LiteralPath $partial -Destination $dest
            Write-OpsLog "релиз $ver распакован в $dest" 'OK'
        }
        return @{ Version = $ver; Dir = $dest; Reused = $reused; ZipSha256 = $actual }
    } finally {
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------- ops-tool ----------
function Invoke-OpsTool($L, [string]$ReleaseDir, [string[]]$Arguments, [switch]$Quiet) {
    $node = Join-Path $ReleaseDir 'node\node.exe'
    $tool = Join-Path $ReleaseDir 'scripts\ops-tool.mjs'
    $r = Invoke-OpsProcess -FilePath $node -ArgumentList (@($tool) + $Arguments) -CleanEnvironment -QuietStdout:$Quiet
    $r.Json = ConvertFrom-OpsJsonLine $r.Out
    return $r
}

function Get-OpsDbState($L, [string]$ReleaseDir, [int]$PgPort, [string]$DbName) {
    $r = Invoke-OpsTool $L $ReleaseDir @('db', 'state', '--modules', (Join-Path $ReleaseDir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName) -Quiet
    if ($r.Code -ne 0 -or $null -eq $r.Json) { throw "не удалось прочитать журнал миграций базы $DbName (код $($r.Code))" }
    return $r.Json
}

# ---------- конфигурация ----------
# Разбор шаблона .env (как env_get в infra/scripts/lib.sh): ИМЯ=значение, значение в кавычках или до « #».
function Read-OpsEnvTemplate([string]$Path) {
    $pairs = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($raw -match '^\s*#' -or $raw -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $k = $Matches[1]; $v = $Matches[2].TrimStart()
        if ($v.StartsWith('"') -or $v.StartsWith("'")) {
            $q = $v.Substring(0, 1); $v = $v.Substring(1); $i = $v.IndexOf($q)
            if ($i -ge 0) { $v = $v.Substring(0, $i) }
        } else {
            $i = $v.IndexOf(' #'); if ($i -ge 0) { $v = $v.Substring(0, $i) }
            $v = $v.TrimEnd()
        }
        $pairs[$k] = $v
    }
    return $pairs
}

# Несекретные настройки из шаблонов релиза (scripts\templates\prod.env.example, для тестового контура поверх —
# test.env.example) без имён уровня compose/резервного копирования Linux (программа их не читает) и без пустых
# значений (пустое = «не задано»). Общая часть install.ps1 (шаг 6) и update.ps1 (новые имена новой версии).
function Get-OpsEnvTemplatePairs([string]$ReleaseDir, [string]$Contour) {
    $tpl = Read-OpsEnvTemplate (Join-Path $ReleaseDir 'scripts\templates\prod.env.example')
    if ($Contour -eq 'test') {
        $t2 = Read-OpsEnvTemplate (Join-Path $ReleaseDir 'scripts\templates\test.env.example')
        foreach ($k in $t2.Keys) { $tpl[$k] = $t2[$k] }
    }
    foreach ($k in @('API_TAG', 'BACKUP_TAG', 'POSTGRES_USER', 'POSTGRES_DB', 'BACKUP_KEEP_DAYS', 'BACKUP_REMOTE', 'BACKUP_SCHEDULE',
            'BACKUP_AGE_RECIPIENT', 'BACKUP_PITR', 'CADDY_SITE_ADDRESS', 'CADDY_TLS', 'CADDY_TEST_SITE_ADDRESS', 'PG_SHARED_BUFFERS',
            'PG_MEM_LIMIT', 'API_MEM_LIMIT', 'WORKER_MEM_LIMIT')) { if ($tpl.Contains($k)) { $tpl.Remove($k) } }
    return $tpl
}

# Строка для node --env-file: значение с пробелом или # — в двойных кавычках.
function Format-OpsEnvLine([string]$Key, [string]$Value) {
    if ($Value -match '[\r\n"]') { throw "значение $Key содержит перевод строки или кавычку" }
    if ($Value -match '[\s#'']') { return "$Key=`"$Value`"" }
    return "$Key=$Value"
}

# Новый файл — целиком; существующий не переписывается: в конец добавляются только имена, которых в нём нет
# (как env_merge_template в Linux-комплекте). Возвращает список добавленных имён.
function Write-OpsEnvFile([string]$Path, [string]$Header, $Pairs) {
    if (-not (Test-Path -LiteralPath $Path)) {
        $lines = @($Header.Split("`n") | ForEach-Object { '# ' + $_.TrimEnd() })
        foreach ($k in $Pairs.Keys) { $lines += (Format-OpsEnvLine $k ([string]$Pairs[$k])) }
        Write-OpsUtf8 $Path (($lines -join "`r`n") + "`r`n")
        return @($Pairs.Keys)
    }
    $existing = @{}
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) { if ($raw -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $existing[$Matches[1]] = $true } }
    $add = @()
    foreach ($k in $Pairs.Keys) { if (-not $existing.ContainsKey($k)) { $add += (Format-OpsEnvLine $k ([string]$Pairs[$k])) } }
    if ($add.Count -gt 0) {
        $text = "`r`n# --- добавлено $(Get-Date -Format 'yyyy-MM-dd') ---`r`n" + ($add -join "`r`n") + "`r`n"
        [System.IO.File]::AppendAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    return @($add | ForEach-Object { ($_ -split '=', 2)[0] })
}

# Замена значения одного имени в существующем .env (явно заданный параметр install.ps1, например -TestPhones).
# Возвращает $true, если файл изменён.
function Set-OpsEnvValue([string]$Path, [string]$Key, [string]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $new = Format-OpsEnvLine $Key $Value
    $lines = [System.IO.File]::ReadAllLines($Path)
    $changed = $false; $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^' + [regex]::Escape($Key) + '=')) {
            $found = $true
            if ($lines[$i] -ne $new) { $lines[$i] = $new; $changed = $true }
        }
    }
    if (-not $found) { $lines += $new; $changed = $true }
    if ($changed) { Write-OpsUtf8 $Path (($lines -join "`r`n") + "`r`n") }
    return $changed
}

function Get-OpsCpuRatePercent([double]$Cpus) {
    $logical = 0
    try { $logical = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors } catch { $logical = [Environment]::ProcessorCount }
    if ($logical -lt 1) { $logical = [Environment]::ProcessorCount }
    $v = [int][math]::Round($Cpus * 100.0 / $logical)
    if ($v -lt 1) { $v = 1 }
    if ($v -gt 100) { $v = 100 }
    return $v
}

# ---------- службы ----------
function Get-OpsServiceState([string]$Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return 'Missing' }
    return [string]$s.Status
}

# Исходник SendCtrlC.exe (только -DevTest): Ctrl+C в консоль OptomstroySvc.exe --console = штатная остановка.
$script:OpsSendCtrlCSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
internal static class SendCtrlC
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    private static int Main(string[] args)
    {
        uint pid = uint.Parse(args[0]);
        FreeConsole();
        if (!AttachConsole(pid)) return 10;
        SetConsoleCtrlHandler(IntPtr.Zero, true);
        bool ok = GenerateConsoleCtrlEvent(0, 0);
        Thread.Sleep(300);
        FreeConsole();
        return ok ? 0 : 11;
    }
}
'@

function Get-OpsSendCtrlC($L) {
    $dir = Join-Path $L.State 'devtest'
    $exe = Join-Path $dir 'SendCtrlC.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $src = Join-Path $dir 'SendCtrlC.cs'
    Write-OpsUtf8 $src $script:OpsSendCtrlCSource
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $o = & $csc /nologo /target:exe "/out:$exe" $src 2>&1
    if ($LASTEXITCODE -ne 0) { throw "csc SendCtrlC: $o" }
    return $exe
}

function Get-OpsDevTestProcs($L) {
    $f = Join-Path $L.State 'devtest\processes.json'
    $o = Read-OpsJson $f
    return (ConvertTo-OpsHashtable $o)
}

function Save-OpsDevTestProcs($L, [hashtable]$Procs) {
    $dir = Join-Path $L.State 'devtest'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-OpsJson (Join-Path $dir 'processes.json') $Procs
}

function Get-OpsDevTestProcess($L, [string]$Name) {
    $procs = Get-OpsDevTestProcs $L
    if (-not $procs.ContainsKey($Name)) { return $null }
    $rec = $procs[$Name]
    $p = Get-Process -Id ([int]$rec.pid) -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    try { if ($p.StartTime.ToUniversalTime().ToString('o') -ne [string]$rec.startUtc) { return $null } } catch { return $null }
    return $p
}

function Get-OpsAppServiceState($L, [string]$Name, [switch]$DevTest) {
    if ($DevTest) {
        if ($null -ne (Get-OpsDevTestProcess $L $Name)) { return 'Running' }
        return 'Stopped'
    }
    return (Get-OpsServiceState $Name)
}

function Get-OpsSvcConfigPath($L, [string]$Name) {
    switch ($Name) {
        'OptomstroyApi' { return (Join-Path $L.Config 'api.svc.json') }
        'OptomstroyWorker' { return (Join-Path $L.Config 'worker.svc.json') }
        'OptomstroyBackup' { return (Join-Path $L.Config 'backup.svc.json') }
    }
    throw "неизвестная служба $Name"
}

# Запуск служб: на сервере — Start-Service; -DevTest — OptomstroySvc.exe --console в скрытой консоли (фоном).
$script:OpsLogOffsets = @{}
function Get-OpsOutLogPath($L, [string]$Name) {
    $sub = @{ OptomstroyApi = 'api'; OptomstroyWorker = 'worker'; OptomstroyBackup = 'backup' }[$Name]
    return (Join-Path $L.Logs "$sub\$Name.out.log")
}

# Отпечаток того, что служба читает только при запуске: релиз (цель current), её файлы настроек и состав
# папки секретов. Файлы настроек — SHA256 содержимого (секретов в них нет); секреты — только имя, размер и время
# изменения (их содержимое и производные от него в state не попадают).
function Get-OpsServiceFingerprint($L, [string]$Name) {
    $files = @{
        OptomstroyApi = @('api.env', 'api.svc.json')
        OptomstroyWorker = @('worker.env', 'worker.svc.json')
        OptomstroyBackup = @('backup.svc.json', 'backup.json', 'backup-public.pem')
    }[$Name]
    $parts = New-Object System.Collections.ArrayList
    $cur = $null
    try { $cur = Get-OpsJunctionTarget $L.Current } catch { $cur = '?' }
    [void]$parts.Add("current=$cur")
    foreach ($f in $files) {
        $fp = Join-Path $L.Config $f
        $h = '-'
        if (Test-Path -LiteralPath $fp) { try { $h = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash } catch { $h = '?' } }
        [void]$parts.Add("$f=$h")
    }
    try {
        foreach ($s in @(Get-ChildItem -LiteralPath $L.Secrets -File -ErrorAction Stop | Sort-Object Name)) {
            [void]$parts.Add(('secret {0}:{1}:{2}' -f $s.Name, $s.Length, $s.LastWriteTimeUtc.Ticks))
        }
    } catch { [void]$parts.Add('secrets=?') }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '')
}

function Get-OpsStartedFingerprints($L) {
    $o = $null
    try { $o = Read-OpsJson (Join-Path $L.State 'service-config.json') } catch { $o = $null }
    return (ConvertTo-OpsHashtable $o)
}

function Save-OpsStartedFingerprint($L, [string]$Name, [string]$Fingerprint) {
    try {
        $all = Get-OpsStartedFingerprints $L
        $all[$Name] = $Fingerprint
        Write-OpsJson (Join-Path $L.State 'service-config.json') $all
    } catch { Write-OpsLog "не записан state\service-config.json: $($_.Exception.Message)" 'WARN' }
}

# Запуск служб. Уже работающая служба не перезапускается, если её релиз, файлы настроек и секреты не менялись
# с её запуска этими скриптами. Если менялись: с -RestartIfChanged — штатная остановка и запуск (install.ps1:
# повторный запуск с новыми параметрами, например -TestPhones); без него — предупреждение в журнале.
# (Start-Service для работающей службы ничего не делает — новые настройки иначе не применились бы.)
function Start-OpsAppServices($L, [string[]]$Names, [switch]$DevTest, [switch]$RestartIfChanged) {
    foreach ($n in $Names) {
        $ol = Get-OpsOutLogPath $L $n
        $script:OpsLogOffsets[$n] = 0
        if (Test-Path -LiteralPath $ol) { $script:OpsLogOffsets[$n] = (Get-Item -LiteralPath $ol).Length }
        $fp = Get-OpsServiceFingerprint $L $n
        $running = $false
        if ($DevTest) { $running = ($null -ne (Get-OpsDevTestProcess $L $n)) }
        else { $running = ((Get-OpsServiceState $n) -eq 'Running') }
        if ($running) {
            $started = Get-OpsStartedFingerprints $L
            $old = $null
            if ($started.ContainsKey($n)) { $old = [string]$started[$n] }
            if ($old -eq $fp) { Write-OpsLog "$n уже запущена; релиз, настройки и секреты не менялись — без перезапуска"; continue }
            $why = 'релиз, настройки или секреты изменились после её запуска'
            if ($null -eq $old) { $why = 'нет отметки о настройках, с которыми она запущена' }
            if (-not $RestartIfChanged) {
                Write-OpsLog "$n уже запущена, но $why — изменения применятся только после перезапуска службы (Restart-Service $n)" 'WARN'
                continue
            }
            Write-OpsLog "$n уже запущена, но $why — перезапуск (штатная остановка, затем запуск)" 'WARN'
            Stop-OpsAppServices $L @($n) -DevTest:$DevTest
        }
        # Проверки после запуска читают журнал только с этого места (старые строки прошлых запусков не в счёт).
        if (Test-Path -LiteralPath $ol) { $script:OpsLogOffsets[$n] = (Get-Item -LiteralPath $ol).Length }
        if ($DevTest) {
            $exe = Join-Path $L.Current 'svchost\OptomstroySvc.exe'
            $cfg = Get-OpsSvcConfigPath $L $n
            $p = Start-Process -FilePath $exe -ArgumentList @('--console', '--config', ('"{0}"' -f $cfg)) -WindowStyle Hidden -PassThru
            $procs = Get-OpsDevTestProcs $L
            $procs[$n] = [ordered]@{ pid = $p.Id; startUtc = $p.StartTime.ToUniversalTime().ToString('o'); config = $cfg }
            Save-OpsDevTestProcs $L $procs
            Write-OpsLog "$n запущена (DevTest: OptomstroySvc.exe --console, PID $($p.Id))" 'OK'
        } else {
            if ((Get-OpsServiceState $n) -eq 'Missing') { throw "служба $n не зарегистрирована" }
            Start-Service -Name $n
            (Get-Service -Name $n).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
            Write-OpsLog "${n}: Running" 'OK'
        }
        Save-OpsStartedFingerprint $L $n $fp
    }
}

function Stop-OpsAppServices($L, [string[]]$Names, [switch]$DevTest) {
    foreach ($n in $Names) {
        if ($DevTest) {
            $p = Get-OpsDevTestProcess $L $n
            if ($null -eq $p) { Write-OpsLog "$n не запущена (DevTest)"; continue }
            $ctrl = Get-OpsSendCtrlC $L
            $c = Start-Process -FilePath $ctrl -ArgumentList @([string]$p.Id) -WindowStyle Hidden -PassThru -Wait
            $limit = 75
            if (-not $p.WaitForExit($limit * 1000)) {
                Write-OpsLog "$n не остановилась за $limit с после Ctrl+C — завершение процесса (задание KILL_ON_JOB_CLOSE завершит node.exe)" 'WARN'
                try { $p.Kill() } catch { }
                $p.WaitForExit(10000) | Out-Null
            }
            $procs = Get-OpsDevTestProcs $L
            $procs.Remove($n)
            Save-OpsDevTestProcs $L $procs
            Write-OpsLog "$n остановлена (DevTest, Ctrl+C: код $($c.ExitCode))" 'OK'
        } else {
            $st = Get-OpsServiceState $n
            if ($st -eq 'Missing' -or $st -eq 'Stopped') { Write-OpsLog "${n}: $st"; continue }
            Stop-Service -Name $n
            (Get-Service -Name $n).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
            Write-OpsLog "${n}: Stopped" 'OK'
        }
    }
}

# ---------- PostgreSQL ----------
function Test-OpsPortListening([int]$Port) {
    return ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue))
}

function Get-OpsListenAddresses([int]$Port) {
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
}

# Только -DevTest: pg_ctl start через WMI (Win32_Process.Create), а не дочерним процессом. Дочерний postgres.exe
# унаследовал бы дескрипторы этого процесса (в том числе канал stdout вызывающей программы) и держал бы его
# открытым до остановки сервера: вызывающий «install.ps1 ... | Out-File» не дождался бы конца вывода (проверено).
function Start-OpsDetachedPgCtl($L, [string]$PgBin) {
    $pgctl = Join-Path $PgBin 'pg_ctl.exe'
    $cmd = '"{0}" start -D "{1}" -l "{2}" -w -t 90' -f $pgctl, $L.PgData, (Join-Path $L.Logs 'pg\pg_ctl.log')
    Write-OpsLog "запуск (отдельно от этого процесса): $cmd"
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $PgBin }
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create pg_ctl: код $($r.ReturnValue)" }
    $deadline = (Get-Date).AddSeconds(100)
    while ($null -ne (Get-Process -Id ([int]$r.ProcessId) -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
}

# PostgreSQL должен работать: служба (сервер) или pg_ctl start (-DevTest).
function Start-OpsPostgres($L, [string]$PgBin, [int]$PgPort, [switch]$DevTest) {
    if ($DevTest) {
        if (Test-OpsPortListening $PgPort) { Write-OpsLog "PostgreSQL слушает $PgPort"; return }
        Start-OpsDetachedPgCtl $L $PgBin
    } else {
        $st = Get-OpsServiceState $script:OpsPgServiceName
        if ($st -eq 'Missing') { throw "служба $script:OpsPgServiceName не зарегистрирована" }
        if ($st -ne 'Running') {
            Start-Service -Name $script:OpsPgServiceName
            (Get-Service -Name $script:OpsPgServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
        }
    }
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-OpsPortListening $PgPort) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-OpsPortListening $PgPort)) { throw "PostgreSQL не слушает порт $PgPort" }
    Write-OpsLog "PostgreSQL слушает 127.0.0.1:$PgPort" 'OK'
}

# ---------- проверка готовности ----------
function Get-OpsHttp([string]$Url, [int]$TimeoutMs = 5000) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Proxy = $null
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($null -ne $ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($null -ne $ex -and $null -ne $ex.Response) { $resp = $ex.Response } else { return @{ Code = 0; Body = '' } }
    }
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd()
        $sr.Close()
        return @{ Code = [int]$resp.StatusCode; Body = $body }
    } finally {
        $resp.Close()
    }
}

# Ждёт /health = 200 и /health/ready = 200 (ok|degraded). Возвращает @{ Ok; Health; Ready; ReadyStatus; Seconds }.
function Wait-OpsApiHealthy([int]$Port, [int]$TimeoutSec = 180) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h = @{ Code = 0; Body = '' }; $r = @{ Code = 0; Body = '' }; $status = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $h = Get-OpsHttp "http://127.0.0.1:$Port/health"
        if ($h.Code -eq 200) {
            $r = Get-OpsHttp "http://127.0.0.1:$Port/health/ready"
            $status = ''
            try { $status = [string](($r.Body | ConvertFrom-Json).status) } catch { }
            if ($r.Code -eq 200) { break }
        }
        Start-Sleep -Seconds 2
    }
    return @{ Ok = ($h.Code -eq 200 -and $r.Code -eq 200); Health = $h.Code; Ready = $r.Code; ReadyStatus = $status; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

# Фоновые задачи HTTP-порта не имеют (как в Linux: проверяется, что процесс жив). Ждём $HoldSec секунд: процесс не
# должен завершиться, в журнале — нет worker.start_failed / nest_context_failed.
function Test-OpsWorkerAlive($L, [int]$HoldSec = 20, [switch]$DevTest) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $HoldSec) {
        if ((Get-OpsAppServiceState $L 'OptomstroyWorker' -DevTest:$DevTest) -ne 'Running') { return @{ Ok = $false; Reason = 'служба/процесс не работает' } }
        Start-Sleep -Seconds 2
    }
    $log = Get-OpsOutLogPath $L 'OptomstroyWorker'
    $bad = @()
    if (Test-Path -LiteralPath $log) {
        $off = [int64]0
        if ($script:OpsLogOffsets.ContainsKey('OptomstroyWorker')) { $off = [int64]$script:OpsLogOffsets['OptomstroyWorker'] }
        $fs = New-Object System.IO.FileStream($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
        try {
            if ($off -gt $fs.Length) { $off = 0 }   # журнал повернулся
            [void]$fs.Seek($off, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
        $bad = @(($text -split "`r?`n") | Where-Object { $_ -match 'worker\.start_failed|worker\.nest_context_failed' })
    }
    if ($bad.Count -gt 0) {
        $b = [string]$bad[-1]
        if ($b.Length -gt 400) { $b = $b.Substring(0, 400) + '…' }
        return @{ Ok = $false; Reason = "в журнале: $b" }
    }
    return @{ Ok = $true; Reason = "работает $HoldSec с" }
}
