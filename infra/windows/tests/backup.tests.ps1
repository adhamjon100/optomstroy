<#
.SYNOPSIS
  Проверки комплекта резервного копирования для Windows (infra/windows/backup).

.DESCRIPTION
  1. Скрипты .ps1: разбор парсером PowerShell без ошибок; UTF-8 с BOM у файлов с кириллицей.
  2. Примеры backup.example.json и OptomstroyBackup.svc.example.json: JSON читается, backup.json проходит
     проверку схемы pos-backup.
  3. node --test tests/optbk.test.mjs — формат OPTBK1, wal-archive, tar, конвейер шифрования, очистка, decrypt-pipe;
     node --test tests/jobs.test.mjs — замок, wal-ship после обрыва, wal-unpack (дыра, повреждение), окно WAL вне
     сервера, ежедневный прогон при сбое pg_dump (поддельные программы, csc.exe), Healthchecks, пороги status.
  3а. set-backup-acl.ps1 -DevTest: закрытые папки на временных папках, проверка, обнаружение лишнего права.
  4. node --test tests/integration.test.mjs — настоящий PostgreSQL 17 (порты 55441–55443): archive_command,
     wal-ship, служба daemon, restore-pitr.ps1 -DevTest (момент между вставками и -Latest).
  4а. node --test tests/drill.test.mjs — настоящий PostgreSQL 17 (порты 55445–55446), psql и pg_restore — подмена fakepg:
     restore-drill.ps1 -DevTest (успех и провал, уборка, итог в status), restore.ps1 -DevTest с apply-roles.ps1 (SCRAM,
     без открытых паролей в журнале сервера, локаль, фото и audit-anchors). -SkipIntegration — пропуск 4 и 4а.
  Временные данные — .tmp\wn-backup (удаляются тестами).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\backup.tests.ps1
#>
[CmdletBinding()]
param(
    [string]$NodeExe,
    [string]$PgBin,
    [switch]$SkipIntegration
)

$ErrorActionPreference = 'Stop'
$kit = Join-Path (Split-Path $PSScriptRoot -Parent) 'backup'
$failed = 0

function Report([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Host "  ok   $Text" -ForegroundColor Green } else { Write-Host "  FAIL $Text" -ForegroundColor Red; $script:failed++ }
}

if (-not $NodeExe) {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { Write-Host 'node.exe не найден (укажите -NodeExe)' -ForegroundColor Red; exit 1 }
    $NodeExe = $cmd.Source
}
if ($PgBin) { $env:WN_PG_BIN = $PgBin }

Write-Host '== 1. Скрипты PowerShell'
$scripts = @(Get-ChildItem -LiteralPath $kit -Filter '*.ps1') + @(Get-Item -LiteralPath $PSCommandPath)
foreach ($f in $scripts) {
    $tokens = $null
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    Report ($errs.Count -eq 0) "парсер: $($f.Name)$(if ($errs.Count) { ' — ' + (($errs | ForEach-Object { "строка $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') })"
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasCyr = [Text.Encoding]::UTF8.GetString($bytes) -match '[Ѐ-ӿ]'
    Report ((-not $hasCyr) -or $hasBom) "UTF-8 с BOM (кириллица): $($f.Name)"
}

Write-Host '== 2. Примеры настроек'
foreach ($j in @('backup.example.json', 'OptomstroyBackup.svc.example.json')) {
    $ok = $true
    try { [void]([IO.File]::ReadAllText((Join-Path $kit $j)) | ConvertFrom-Json) } catch { $ok = $false }
    Report $ok "JSON читается: $j"
}
$probe = "import('file:///" + ((Join-Path $kit 'lib\common.mjs') -replace '\\', '/') + "').then(m => { m.loadConfig(process.argv[1]); console.log('ok') }).catch(e => { console.error(e.message); process.exit(1) })"
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = & $NodeExe -e $probe (Join-Path $kit 'backup.example.json') 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = $old
Report ($code -eq 0) "backup.example.json проходит проверку схемы ($out)"

function Invoke-NodeTest([string]$File) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8   # вывод node — UTF-8
    try {
        & $NodeExe --test --test-concurrency=1 $File 2>&1 | ForEach-Object {
            $l = "$_"
            if ($l -match '^(✔|✖|ℹ (tests|pass|fail))') { Write-Host "     $l" }
        }
        return $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prevEnc
        $ErrorActionPreference = $old
    }
}

Write-Host '== 3. Модульные проверки (node --test)'
Push-Location $kit
try {
    $code = Invoke-NodeTest 'tests/optbk.test.mjs'
    Report ($code -eq 0) 'tests/optbk.test.mjs'
    $code = Invoke-NodeTest 'tests/jobs.test.mjs'
    Report ($code -eq 0) 'tests/jobs.test.mjs'

    Write-Host '== 3а. Права закрытых папок (set-backup-acl.ps1 -DevTest на временных папках)'
    $aclTmp = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) '.tmp\wn-backup\acl'
    Remove-Item -LiteralPath $aclTmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $aclTmp 'inst\config'), (Join-Path $aclTmp 'inst\data\media') | Out-Null
    [IO.File]::WriteAllText((Join-Path $aclTmp 'inst\config\backup.json'), '{}')
    $aclScript = Join-Path $kit 'set-backup-acl.ps1'
    $aclCommon = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $aclScript, '-DevTest', '-InstallRoot', (Join-Path $aclTmp 'inst'), '-BackupRoot', (Join-Path $aclTmp 'bk'))
    & powershell.exe @aclCommon | Out-Null
    Report ($LASTEXITCODE -eq 0) 'set-backup-acl.ps1 -DevTest: права выставлены и проверены'
    & powershell.exe @($aclCommon + '-CheckOnly') | Out-Null
    Report ($LASTEXITCODE -eq 0) 'set-backup-acl.ps1 -CheckOnly: закрытые папки в порядке'
    $acl = Get-Acl -LiteralPath (Join-Path $aclTmp 'bk')
    Report ($acl.AreAccessRulesProtected) 'корень копий: наследование отключено'
    & icacls.exe (Join-Path $aclTmp 'bk') /grant '*S-1-5-11:(OI)(CI)M' | Out-Null   # «Прошедшие проверку» — как на томе D:
    & powershell.exe @($aclCommon + '-CheckOnly') | Out-Null
    Report ($LASTEXITCODE -eq 1) 'set-backup-acl.ps1 -CheckOnly: лишнее право «Прошедшие проверку» обнаружено (код 1)'
    Remove-Item -LiteralPath $aclTmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($SkipIntegration) {
        Write-Host '== 4. Интеграционная проверка — пропущена (-SkipIntegration)'
    } else {
        Write-Host '== 4. Интеграционная проверка на PostgreSQL 17 (несколько минут)'
        $code = Invoke-NodeTest 'tests/integration.test.mjs'
        Report ($code -eq 0) 'tests/integration.test.mjs'
        Write-Host '== 4а. restore-drill.ps1 и restore.ps1 на PostgreSQL 17 (fakepg вместо psql и pg_restore)'
        $code = Invoke-NodeTest 'tests/drill.test.mjs'
        Report ($code -eq 0) 'tests/drill.test.mjs'
    }
} finally {
    Pop-Location
}

Write-Host ''
if ($failed) { Write-Host "Провалено проверок: $failed" -ForegroundColor Red; exit 1 }
Write-Host 'Все проверки пройдены' -ForegroundColor Green
exit 0
