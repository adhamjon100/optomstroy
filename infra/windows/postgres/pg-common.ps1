# Общие функции комплекта PostgreSQL для Windows Server (подключается через точку: . "$PSScriptRoot\pg-common.ps1").
# Windows PowerShell 5.1 (Windows Server 2022). Файл в UTF-8 с BOM.

Set-StrictMode -Version 2.0

function Write-PgStep([string]$Message) {
    Write-Host "[postgres] $Message"
}

# Запись текстового файла в UTF-8 БЕЗ BOM: PostgreSQL читает postgresql.conf/pg_hba.conf побайтно, BOM в первой
# строке ломает разбор. Set-Content/Out-File в PowerShell 5.1 пишут BOM — поэтому .NET напрямую.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# Строковое значение для postgresql.conf: одинарные кавычки удваиваются, обратная косая черта удваивается
# (разбор конфигурации понимает \b \f \n \r \t, восьмеричные коды и «\x» → «x», поэтому «D:\0...» без удвоения
# испортится).
function ConvertTo-PgConfString([string]$Value) {
    return "'" + $Value.Replace('\', '\\').Replace("'", "''") + "'"
}

# Аргумент командной строки Windows по правилам MSVCRT (CommandLineToArgvW): кавычки, если есть пробел/табуляция/
# кавычка; обратные косые перед кавычкой удваиваются.
function ConvertTo-CmdArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\', 2 * $bs + 1)
            [void]$sb.Append('"')
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs) }
            [void]$sb.Append($ch)
        }
        $bs = 0
    }
    if ($bs -gt 0) { [void]$sb.Append('\', 2 * $bs) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Запуск внешней программы с выводом во временные файлы (а не в канал): pg_ctl start наследует дескрипторы
# порождённому postgres.exe, и канал PowerShell не закрылся бы до остановки сервера. Возвращает код выхода.
# Вывод печатается после завершения (без секретов: пароли программам передаются только файлами).
function Invoke-PgNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$OutDir,
        [switch]$Quiet,
        [hashtable]$Environment = @{}
    )
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $out = Join-Path $OutDir ("native-$stamp.out")
    $err = Join-Path $OutDir ("native-$stamp.err")
    $cmdLine = ($ArgumentList | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
    $saved = @{}
    foreach ($k in $Environment.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$Environment[$k], 'Process')
    }
    try {
        # Без -Wait: в PowerShell 5.1 -Wait ждёт и потомков (postgres.exe после pg_ctl start) — ждём только сам процесс.
        $spArgs = @{ FilePath = $FilePath; NoNewWindow = $true; PassThru = $true
                     RedirectStandardOutput = $out; RedirectStandardError = $err }
        if ($cmdLine -ne '') { $spArgs['ArgumentList'] = $cmdLine }
        $p = Start-Process @spArgs
        $null = $p.Handle   # иначе ExitCode у процесса из Start-Process бывает пустым
        $p.WaitForExit()
        $code = $p.ExitCode
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    foreach ($f in @($out, $err)) {
        if (Test-Path -LiteralPath $f) {
            if (-not $Quiet) {
                $text = $null
                try {
                    $fs = [System.IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
                    try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
                } catch { $text = $null }
                if ($text) { $text.TrimEnd() -split "`r?`n" | ForEach-Object { Write-Host "    $_" } }
            }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    return $code
}

function Assert-PgBin([string]$PgBin) {
    foreach ($exe in @('initdb.exe', 'pg_ctl.exe', 'postgres.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PgBin $exe))) { throw "В -PgBin нет $exe ($PgBin)" }
    }
}

# Версия сервера: «postgres (PostgreSQL) 17.10» → [version] 17.10
function Get-PgServerVersion([string]$PgBin, [string]$TmpDir) {
    $exe = Join-Path $PgBin 'postgres.exe'
    $tmp = Join-Path $TmpDir ('pgver-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $p = Start-Process -FilePath $exe -ArgumentList '--version' -NoNewWindow -PassThru -RedirectStandardOutput $tmp
    $null = $p.Handle
    $p.WaitForExit()
    $text = Get-Content -LiteralPath $tmp -Raw
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -or $text -notmatch 'PostgreSQL\)\s+(\d+)\.(\d+)') { throw "Не удалось определить версию PostgreSQL ($exe)" }
    return New-Object System.Version([int]$Matches[1], [int]$Matches[2])
}

function Test-PortListening([int]$Port) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return ($null -ne $c)
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Секрет (пароль суперпользователя) для initdb --pwfile: initdb берёт ПЕРВУЮ строку как есть, а pg-tool.mjs
# удаляет все CR/LF и склеивает строки — поэтому допускается ровно одна строка (один перевод строки в конце можно),
# без BOM и не-ASCII: иначе пароль initdb и пароль pg-tool разойдутся. Значение не выводится.
function Assert-PasswordFile([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Нет файла секрета $Name ($Path)" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Секрет $Name записан с BOM — перезапишите без BOM (одна строка ASCII)"
    }
    foreach ($b in $bytes) { if ($b -gt 0x7E -or ($b -lt 0x21 -and $b -ne 0x0D -and $b -ne 0x0A)) { throw "Секрет ${Name}: только печатные ASCII-символы без пробелов" } }
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($text.EndsWith("`r`n")) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    if ($text -match "[`r`n]") { throw "Секрет ${Name}: должна быть ровно одна строка (допускается один перевод строки в конце)" }
    if ($text.Length -lt 16) { throw "Секрет ${Name}: пароль короче 16 символов" }
}

# ---------- права NTFS ----------
# Учётные записи задаются SID (icacls «*SID»): имена групп на русской Windows локализованы («Администраторы»).
$script:PgSidAdministrators = 'S-1-5-32-544'
$script:PgSidSystem = 'S-1-5-18'

function Get-PgCurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Resolve-PgSid([string]$Account) {
    if ($Account -match '^S-1-[0-9-]+$') { return $Account }
    try {
        return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Учётная запись «$Account» не найдена (для NT SERVICE\<имя> служба должна быть уже зарегистрирована)"
    }
}

function Invoke-PgIcacls([string[]]$IcaclsArgs) {
    $out = & icacls.exe @IcaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("icacls " + ($IcaclsArgs -join ' ') + " завершился с кодом $LASTEXITCODE`n" + ($out | Out-String)) }
}

# Закрытая папка: наследование от родителя отключается (на томе данных у «Прошедших проверку» по умолчанию есть
# изменение вложенных папок), явные права — только перечисленным SID; права вложенных файлов пересчитываются
# Windows автоматически. -RemoveSids — снять явные права (например, временное право администратора на время initdb).
function Set-PgPrivateAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$FullSids,
        [string[]]$ModifySids = @(),
        [string[]]$RemoveSids = @()
    )
    $grants = @($FullSids | ForEach-Object { "*${_}:(OI)(CI)F" }) + @($ModifySids | ForEach-Object { "*${_}:(OI)(CI)M" })
    Invoke-PgIcacls (@($Path, '/inheritance:r', '/grant:r') + $grants)
    foreach ($sid in $RemoveSids) { Invoke-PgIcacls @($Path, '/remove:g', "*$sid") }
}

# Проверка закрытой папки: нет унаследованных записей и нет разрешений кому-либо кроме -AllowedSids.
# Возвращает список нарушений (пустой — всё в порядке).
function Test-PgPrivateAcl([string]$Path, [string[]]$AllowedSids) {
    $problems = @()
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { $problems += "${Path}: наследование прав от родительской папки не отключено" }
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $r.IdentityReference.Value
        if ($r.IsInherited) { $problems += "${Path}: унаследованное право $sid ($($r.FileSystemRights))" }
        elseif ($r.AccessControlType -eq 'Allow' -and ($AllowedSids -notcontains $sid)) {
            $problems += "${Path}: лишнее право $sid ($($r.FileSystemRights))"
        }
    }
    return ,$problems
}

# ---------- проверка общей учётной записи службы ----------
# Исполняемый файл из командной строки службы (Win32_Service.PathName): "C:\a b\x.exe" -k …, C:\Windows\x.exe -k …,
# без кавычек с пробелами (C:\Program Files\x.exe -arg), %SystemRoot%\…, \SystemRoot\…, system32\….
function Get-PgServiceExePath([string]$PathName, [string]$SystemRoot = $env:SystemRoot) {
    if (-not $PathName) { return '' }
    $p = $PathName.Trim()
    if ($p.StartsWith('"')) {
        $end = $p.IndexOf('"', 1)
        $exe = if ($end -gt 0) { $p.Substring(1, $end - 1) } else { $p.Substring(1) }
    } else {
        $i = $p.IndexOf('.exe', [StringComparison]::OrdinalIgnoreCase)
        $exe = if ($i -ge 0) { $p.Substring(0, $i + 4) } else { ($p -split '\s+')[0] }
    }
    $exe = [Environment]::ExpandEnvironmentVariables($exe)
    if ($exe -match '^\\SystemRoot\\') { $exe = $SystemRoot.TrimEnd('\') + $exe.Substring('\SystemRoot'.Length) }
    elseif ($exe -match '^(?i)system32\\') { $exe = Join-Path $SystemRoot $exe }
    return $exe
}

# Обязательная проверка перед установкой (SEC-02): какие ещё службы работают под той же учётной записью, что и
# PostgreSQL. У этих служб те же права, что у PostgreSQL: изменение data\pg (pg_hba.conf → trust) и спула WAL
# (подложенный сегмент pos-backup зашифрует, а PITR потом применит). «Компонент Windows» — исполняемый файл внутри
# %SystemRoot%; всё остальное (в том числе программы Microsoft вне папки Windows, например SQL Server) считается
# сторонним: его процесс — дополнительная поверхность атаки на базу.
# Виртуальная учётная запись NT SERVICE\<имя> принадлежит одной службе — проверять нечего.
# -Services — список для проверочного прогона (объекты с Name, DisplayName, State, StartName, PathName).
function Get-PgServiceAccountPrecheck {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceAccount,
        [string]$ServiceName = '',
        [object[]]$Services = $null,
        [string]$SystemRoot = $env:SystemRoot
    )
    $r = [pscustomobject]@{ Account = $ServiceAccount; Sid = ''; Virtual = $false; Others = @(); ThirdParty = @(); Lines = @() }
    if ($ServiceAccount -match '^(?i)NT SERVICE\\') {
        $r.Virtual = $true
        $r.Lines = @("учётная запись службы $ServiceAccount — виртуальная (только служба $ServiceName): общих прав с другими службами нет")
        return $r
    }
    $r.Sid = Resolve-PgSid $ServiceAccount
    if ($null -eq $Services) { $Services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) }
    $root = [System.IO.Path]::GetFullPath($SystemRoot).TrimEnd('\') + '\'
    $sidCache = @{}
    $others = @()
    foreach ($s in $Services) {
        $start = [string]$s.StartName
        if (-not $start) { continue }
        if ($ServiceName -and $s.Name -eq $ServiceName) { continue }
        if (-not $sidCache.ContainsKey($start)) {
            $v = ''
            try { $v = Resolve-PgSid $start } catch { $v = '' }   # LocalSystem и т. п. — не переводятся, не совпадают
            $sidCache[$start] = $v
        }
        if ($sidCache[$start] -ne $r.Sid) { continue }
        $exe = Get-PgServiceExePath ([string]$s.PathName) $SystemRoot
        $isWindows = $false
        if ($exe) { try { $isWindows = [System.IO.Path]::GetFullPath($exe).StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $isWindows = $false } }
        $others += [pscustomobject]@{
            Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; State = [string]$s.State
            PathName = [string]$s.PathName; Exe = $exe; ThirdParty = (-not $isWindows)
        }
    }
    $r.Others = @($others)
    $r.ThirdParty = @($others | Where-Object { $_.ThirdParty })
    $lines = @("учётная запись службы $ServiceAccount ($($r.Sid)): других служб под ней — $($r.Others.Count), из них не компонентов Windows — $($r.ThirdParty.Count)")
    foreach ($o in $r.Others) {
        $kind = if ($o.ThirdParty) { 'СТОРОННЯЯ' } else { 'Windows' }
        $lines += "  [$kind] $($o.Name) ($($o.DisplayName)), $($o.State): $($o.PathName)"
    }
    $r.Lines = $lines
    return $r
}

# Права учётной записи службы PostgreSQL для стандартной archive_command (node.exe и pos-backup.mjs активного
# релиза через junction current, config\backup.json, спул WAL из walSpoolDir). Без них каждый вызов
# archive_command завершается ошибкой, сегменты WAL копятся в pg_wal, а PITR молча перестаёт работать.
function Grant-PgArchiveAccess {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$BackupConfig,
        [Parameter(Mandatory = $true)][string]$Sid
    )
    if (-not (Test-Path -LiteralPath $BackupConfig)) {
        throw "Нет $BackupConfig — сначала конфигурация пакета резервного копирования (walSpoolDir), затем init-postgres.ps1"
    }
    $spool = $null
    try { $spool = (Get-Content -LiteralPath $BackupConfig -Raw -Encoding UTF8 | ConvertFrom-Json).walSpoolDir } catch { $spool = $null }
    if (-not $spool) { throw "В $BackupConfig нет walSpoolDir (каталог спула WAL для archive_command)" }
    $releases = Join-Path $InstallRoot 'releases'
    foreach ($d in @($releases, $spool)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    Invoke-PgIcacls @($InstallRoot, '/grant', "*${Sid}:(RX)")              # только сама папка: переход к current
    Invoke-PgIcacls @($releases, '/grant', "*${Sid}:(OI)(CI)RX")           # node.exe и pos-backup.mjs любого релиза
    Invoke-PgIcacls @($BackupConfig, '/grant', "*${Sid}:(R)")              # backup.json (секретов не содержит)
    Invoke-PgIcacls @($spool, '/grant', "*${Sid}:(OI)(CI)M")               # запись сегментов WAL
    return @{ Releases = $releases; Spool = $spool }
}
