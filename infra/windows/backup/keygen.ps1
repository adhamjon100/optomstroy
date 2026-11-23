<#
.SYNOPSIS
  Создание пары ключей резервных копий (RSA-4096) на компьютере держателя ключа — НЕ на сервере.

.DESCRIPTION
  Нужен только node.exe (Node 24; можно взять из пакета релиза: releases\<версия>\node\node.exe).
  Создаёт в -OutDir:
    backup-public.pem   открытый ключ — передаётся администратору сервера (config\backup-public.pem)
    backup-private.pem  закрытый ключ, защищён парольной фразой — хранить офлайн (съёмный носитель), сделать
                        вторую копию в другом месте; без него копии не расшифровать
    key-id.txt          отпечаток ключа (keyId): по нему сверяется, что сервер шифрует нужным ключом
  Парольная фраза вводится с клавиатуры (не короче 12 символов) и нигде не сохраняется.
  Без консоли (сценарий) — -PassphraseFile <файл, фраза в первой строке>; файл держите на носителе держателя
  ключа и после создания ключей удалите (или храните как саму фразу). Без -PassphraseFile и без интерактивной
  консоли скрипт сразу завершается с ошибкой, а не ждёт ввода.

.EXAMPLE
  .\keygen.ps1 -OutDir E:\optomstroy-key -NodeExe .\node\node.exe
.EXAMPLE
  .\keygen.ps1 -OutDir E:\optomstroy-key -NodeExe .\node\node.exe -PassphraseFile E:\phrase.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$NodeExe,
    [string]$PassphraseFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackupCommon.ps1')

if (-not $NodeExe) {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { Stop-WithError 'node.exe не найден: укажите -NodeExe (например, node\node.exe из пакета релиза)' }
    $NodeExe = $cmd.Source
}
$tool = Join-Path $PSScriptRoot 'pos-backup.mjs'

if ($PassphraseFile) {
    if (-not (Test-Path -LiteralPath $PassphraseFile -PathType Leaf)) { Stop-WithError "нет файла парольной фразы: $PassphraseFile" }
    $code = Invoke-Native $NodeExe @($tool, 'keygen', '--out', $OutDir, '--passphrase-file', $PassphraseFile)
} else {
    $interactive = [Environment]::UserInteractive
    try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { }
    if (-not $interactive) { Stop-WithError 'нет интерактивной консоли для ввода парольной фразы: запустите в окне PowerShell или укажите -PassphraseFile' }
    $p1 = Read-Host -AsSecureString 'Парольная фраза для закрытого ключа (не короче 12 символов)'
    $p2 = Read-Host -AsSecureString 'Повторите парольную фразу'
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
    try {
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
        if ($s1 -ne $s2) { Stop-WithError 'парольные фразы не совпадают' }
        $env:POS_BACKUP_KEY_PASSPHRASE = $s1
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    }
    try {
        $code = Invoke-Native $NodeExe @($tool, 'keygen', '--out', $OutDir)
    } finally {
        Clear-KeyPassphrase
    }
}
if ($code -ne 0) { Stop-WithError "ключи не созданы (код $code)" }
Write-Host ''
Write-Host 'Передайте администратору сервера ТОЛЬКО backup-public.pem и key-id.txt.' -ForegroundColor Yellow
exit 0
