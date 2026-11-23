# Общие функции скриптов резервного копирования (restore.ps1, restore-pitr.ps1, backup.ps1, keygen.ps1).
# Windows PowerShell 5.1. Подключается точкой: . (Join-Path $PSScriptRoot 'BackupCommon.ps1')

Set-StrictMode -Version 2.0

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-Note([string]$Text) {
    Write-Host "   $Text"
}

function Stop-WithError([string]$Text) {
    Write-Host ''
    Write-Host "ОШИБКА: $Text" -ForegroundColor Red
    exit 1
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Путь к node.exe: из релиза (current\node\node.exe); в режиме -DevTest — node из PATH, если релиза нет.
function Resolve-NodeExe([string]$NodeExe, [string]$InstallRoot, [switch]$DevTest) {
    if ($NodeExe) {
        if (-not (Test-Path -LiteralPath $NodeExe)) { Stop-WithError "node.exe не найден: $NodeExe" }
        return (Resolve-Path -LiteralPath $NodeExe).Path
    }
    $candidate = Join-Path $InstallRoot 'current\node\node.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    if ($DevTest) {
        $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    Stop-WithError "node.exe не найден ($candidate). Укажите -NodeExe."
}

# Запуск программы с выводом в консоль. Возвращает код выхода. Поток ошибок не прерывает скрипт (PowerShell 5.1
# оборачивает stderr программ в ErrorRecord) — решение принимается только по коду выхода.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$Quiet)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) {
            & $Exe @Arguments 2>&1 | Out-Null
        } else {
            & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "   $_" }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
}

# Запуск pg_ctl start. Через «& pg_ctl … | …» нельзя: pg_ctl запускает postgres через cmd.exe, и тот наследует
# канал вывода PowerShell — конвейер (и вызывающая программа) ждёт, пока сервер не остановится. Поэтому pg_ctl
# запускается отдельным скрытым процессом без наследования описателей; вывод сервера — в журнал (-l).
function Invoke-PgCtlStart([string]$PgCtl, [string[]]$Arguments) {
    $line = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' '
    $p = Start-Process -FilePath $PgCtl -ArgumentList $line -WindowStyle Hidden -PassThru
    $null = $p.Handle   # PowerShell 5.1: без этого ExitCode после завершения пустой
    $p.WaitForExit()
    return $p.ExitCode
}

# Запуск программы с захватом stdout (короткие запросы). Возвращает объект {Code, Out}.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>$null
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out | ForEach-Object { "$_" }) -join "`n").Trim() }
    } finally {
        $ErrorActionPreference = $old
    }
}

# Парольная фраза закрытого ключа: один раз спрашивается и передаётся pos-backup.mjs через переменную окружения
# процесса (не через командную строку). После работы переменная очищается (Clear-KeyPassphrase).
function Request-KeyPassphrase([string]$KeyFile) {
    if (-not (Test-Path -LiteralPath $KeyFile)) { Stop-WithError "закрытый ключ не найден: $KeyFile" }
    $pem = [IO.File]::ReadAllText($KeyFile)
    if ($pem -match 'ENCRYPTED' -and -not $env:POS_BACKUP_KEY_PASSPHRASE) {
        $sec = Read-Host -AsSecureString 'Парольная фраза закрытого ключа'
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            $env:POS_BACKUP_KEY_PASSPHRASE = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Clear-KeyPassphrase {
    Remove-Item Env:\POS_BACKUP_KEY_PASSPHRASE -ErrorAction SilentlyContinue
}

# Чтение файла, открытого другим процессом на запись (журнал сервера PostgreSQL).
function Read-SharedText([string]$Path) {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default)
        return $sr.ReadToEnd()
    } finally {
        $fs.Dispose()
    }
}

# Запись текста в UTF-8 без BOM (файлы настроек PostgreSQL BOM не понимают).
function Add-TextNoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, $Text, $enc)
}

function Read-JsonFile([string]$Path) {
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

# Строка для postgresql.conf: обратная косая черта и апостроф экранируются.
function ConvertTo-PgConfString([string]$Value) {
    return "'" + ($Value.Replace('\', '\\').Replace("'", "''")) + "'"
}

# ---------- права NTFS (как infra/windows/postgres/pg-common.ps1; своя копия — пакет не зависит от раскладки
# скриптов PostgreSQL в релизе) ----------
# Учётные записи задаются SID (icacls «*SID»): имена групп на русской Windows локализованы («Администраторы»).
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidSystem = 'S-1-5-18'
$script:SidNetworkService = 'S-1-5-20'

function Resolve-AccountSid([string]$Account) {
    if ($Account -match '^S-1-[0-9-]+$') { return $Account }
    try {
        return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Учётная запись «$Account» не найдена (для NT SERVICE\<имя> служба должна быть уже зарегистрирована)"
    }
}

function Invoke-Icacls([string[]]$IcaclsArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & icacls.exe @IcaclsArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { throw ("icacls " + ($IcaclsArgs -join ' ') + " завершился с кодом $code`n" + ($out | Out-String)) }
}

# Закрытая папка: наследование от родителя отключается (на томе данных у «Прошедших проверку» по умолчанию есть
# изменение вложенных папок), явные права — только перечисленным SID (F — полный доступ, M — изменение,
# RX — чтение и выполнение); права вложенных файлов Windows пересчитывает сама.
function Set-PrivateAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$FullSids,
        [string[]]$ModifySids = @(),
        [string[]]$ReadSids = @()
    )
    $grants = @($FullSids | ForEach-Object { "*${_}:(OI)(CI)F" }) + @($ModifySids | ForEach-Object { "*${_}:(OI)(CI)M" }) + @($ReadSids | ForEach-Object { "*${_}:(OI)(CI)RX" })
    Invoke-Icacls (@($Path, '/inheritance:r', '/grant:r') + $grants)
}

# Проверка закрытой папки: наследование отключено, разрешений нет никому, кроме -AllowedSids.
# Возвращает список нарушений (пустой — всё в порядке).
function Test-PrivateAcl([string]$Path, [string[]]$AllowedSids) {
    $problems = @()
    if (-not (Test-Path -LiteralPath $Path)) { return ,@("${Path}: папки нет") }
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

$script:AppServices = @('OptomstroyApi', 'OptomstroyWorker', 'OptomstroyBackup')

function Stop-AppServices {
    foreach ($s in $script:AppServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svc) { Write-Note "служба $s не найдена — пропуск"; continue }
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $s -ErrorAction Stop
            Write-Note "служба $s остановлена"
        } else {
            Write-Note "служба $s уже остановлена"
        }
    }
}

function Start-AppServices {
    foreach ($s in @('OptomstroyApi', 'OptomstroyWorker', 'OptomstroyBackup')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svc) { Write-Note "служба $s не найдена — пропуск"; continue }
        Start-Service -Name $s -ErrorAction Stop
        Write-Note "служба $s запущена"
    }
}
