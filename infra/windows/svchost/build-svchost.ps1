<#
.SYNOPSIS
  Собирает OptomstroySvc.exe из исходника встроенным компилятором .NET Framework 4.x и печатает SHA256.

.DESCRIPTION
  Сторонние программы не нужны: используется C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe,
  который есть в каждой Windows Server 2022 (.NET Framework 4.8).

  Встроенный csc (C# 5) не поддерживает /deterministic: в каждый результат он записывает время сборки
  (поле TimeDateStamp заголовка PE) и случайный идентификатор модуля (MVID). Скрипт заменяет оба поля
  значениями, вычисленными из SHA256 исходника, параметров сборки и версии csc.exe. Поэтому одинаковый исходник
  на той же сборке csc.exe (строка «Компилятор» в выводе) и тех же сборках .NET Framework даёт побайтно одинаковый
  OptomstroySvc.exe. Проверено только на одном ПК; на другой сборке компилятора SHA256 будет другим.

.PARAMETER OutDir
  Папка для OptomstroySvc.exe. По умолчанию: в рабочей копии git — <репозиторий>\.tmp\wn-svchost\bin
  (папка .tmp не попадает в git); вне git (например, исходник из релиза на сервере) — bin рядом со скриптом.

.PARAMETER Csc
  Путь к csc.exe. По умолчанию — csc.exe из .NET Framework 4.x (64 бит).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-svchost.ps1 -OutDir D:\Optomstroy\releases\1.2.0\svchost
#>
[CmdletBinding()]
param(
  [string]$OutDir,
  [string]$Csc = (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
  # Не оставлять собранный .exe внутри отслеживаемых git папок
  $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
  if (Test-Path -LiteralPath (Join-Path $repoRoot '.git')) { $OutDir = Join-Path $repoRoot '.tmp\wn-svchost\bin' }
  else { $OutDir = Join-Path $PSScriptRoot 'bin' }
}

$src = Join-Path $PSScriptRoot 'OptomstroySvc.cs'
if (-not (Test-Path -LiteralPath $Csc)) { throw "Не найден компилятор: $Csc" }
if (-not (Test-Path -LiteralPath $src)) { throw "Не найден исходник: $src" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$exe = Join-Path $OutDir 'OptomstroySvc.exe'
$tmp = Join-Path $OutDir 'OptomstroySvc.build.tmp.exe'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

$fwDir = Split-Path -Parent $Csc
$cscArgs = @(
  '/nologo', '/noconfig', '/target:exe', '/platform:x64', '/optimize+', '/debug-', '/warnaserror+',
  '/codepage:65001', '/langversion:5', '/utf8output', '/filealign:512', '/highentropyva+', '/subsystemversion:6.00',
  "/reference:$(Join-Path $fwDir 'System.dll')",
  "/reference:$(Join-Path $fwDir 'System.ServiceProcess.dll')",
  "/out:$tmp",
  $src
)
$out = & $Csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  $out | ForEach-Object { Write-Host $_ }
  throw "csc.exe завершился с кодом $LASTEXITCODE"
}

# ---- Детерминизация: TimeDateStamp и MVID получают значения из SHA256(исходник + параметры + версия csc)
$sha = [System.Security.Cryptography.SHA256]::Create()
$cscVer = (Get-Item -LiteralPath $Csc).VersionInfo.FileVersion
$seedText = ([System.IO.File]::ReadAllText($src)) + "`n" + ($cscArgs[0..12] -join ' ') + "`n" + $cscVer
$seed = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedText))

$b = [System.IO.File]::ReadAllBytes($tmp)
function Get-U16([byte[]]$a, [int]$o) { [int][BitConverter]::ToUInt16($a, $o) }
function Get-U32([byte[]]$a, [int]$o) { [long][BitConverter]::ToUInt32($a, $o) }

$pe = [int](Get-U32 $b 0x3C)
if ((Get-U32 $b $pe) -ne 0x00004550) { throw 'Не PE-файл' }
$coff = $pe + 4
$numSections = Get-U16 $b ($coff + 2)
$optSize = Get-U16 $b ($coff + 16)
$opt = $coff + 20
$magic = Get-U16 $b $opt
if ($magic -ne 0x20B) { throw "Ожидался PE32+ (x64), magic=0x{0:X}" -f $magic }
# TimeDateStamp: фиксированное значение из хэша (старший бит сброшен)
$ts = [BitConverter]::ToUInt32($seed, 0) -band 0x7FFFFFFF
[Array]::Copy([BitConverter]::GetBytes([uint32]$ts), 0, $b, $coff + 4, 4)
# CheckSum в необязательном заголовке csc оставляет 0; проверяем, чтобы не испортить
if ((Get-U32 $b ($opt + 64)) -ne 0) { throw 'CheckSum PE не нулевой — детерминизация не поддержана' }
# Каталог отладки (6) должен отсутствовать (/debug-), иначе в нём тоже время и GUID
$dataDir = $opt + 112
if ((Get-U32 $b ($dataDir + 6 * 8)) -ne 0) { throw 'Есть каталог отладки — соберите с /debug-' }

$secTable = $opt + $optSize
function Convert-RvaToOffset([long]$rva) {
  for ($k = 0; $k -lt $numSections; $k++) {
    $s = $secTable + 40 * $k
    $va = Get-U32 $b ($s + 12); $vsize = Get-U32 $b ($s + 8); $raw = Get-U32 $b ($s + 20)
    if ($rva -ge $va -and $rva -lt ($va + [Math]::Max($vsize, (Get-U32 $b ($s + 16))))) { return [int]($rva - $va + $raw) }
  }
  throw "RVA 0x{0:X} вне секций" -f $rva
}
# Заголовок CLI (каталог 14) -> метаданные -> поток #GUID; MVID — первый GUID (строка Module, Mvid = 1)
$cliRva = Get-U32 $b ($dataDir + 14 * 8)
$cli = Convert-RvaToOffset $cliRva
$md = Convert-RvaToOffset (Get-U32 $b ($cli + 8))
if ((Get-U32 $b $md) -ne 0x424A5342) { throw 'Нет подписи метаданных BSJB' }
$verLen = [int](Get-U32 $b ($md + 12))
$p = $md + 16 + $verLen
$streams = Get-U16 $b ($p + 2)
$p += 4
$guidOff = -1; $tblOff = -1
for ($k = 0; $k -lt $streams; $k++) {
  $off = [int](Get-U32 $b $p); $p += 8
  $nameStart = $p
  while ($b[$p] -ne 0) { $p++ }
  $name = [System.Text.Encoding]::ASCII.GetString($b, $nameStart, $p - $nameStart)
  $p = $nameStart + ((($p - $nameStart) + 4) -band -4)
  if ($name -eq '#GUID') { $guidOff = $md + $off }
  if ($name -eq '#~') { $tblOff = $md + $off }
}
if ($guidOff -lt 0 -or $tblOff -lt 0) { throw 'Нет потока #GUID или #~' }
# Проверка: в таблице Module (первая строка) индекс Mvid равен 1
$heapSizes = $b[$tblOff + 6]
$strIdx = if ($heapSizes -band 1) { 4 } else { 2 }
$guidIdxSize = if ($heapSizes -band 2) { 4 } else { 2 }
$valid = [BitConverter]::ToUInt64($b, $tblOff + 8)
$nTables = 0; for ($t = 0; $t -lt 64; $t++) { if ($valid -band ([uint64]1 -shl $t)) { $nTables++ } }
$moduleRow = $tblOff + 24 + 4 * $nTables
$mvidIdx = if ($guidIdxSize -eq 2) { Get-U16 $b ($moduleRow + 2 + $strIdx) } else { Get-U32 $b ($moduleRow + 2 + $strIdx) }
if ($mvidIdx -ne 1) { throw "Неожиданный индекс MVID: $mvidIdx" }
[Array]::Copy($seed, 8, $b, $guidOff, 16)
# Имя служебного типа "<PrivateImplementationDetails>{GUID}" (инициализаторы массивов) тоже содержит случайный GUID
$ascii = [System.Text.Encoding]::GetEncoding(28591)   # 1 байт = 1 символ
$text = $ascii.GetString($b)
$marker = '<PrivateImplementationDetails>{'
$fixedGuid = (New-Object guid (,([byte[]]$seed[16..31]))).ToString('D').ToUpperInvariant()
$from = 0
while (($at = $text.IndexOf($marker, $from, [StringComparison]::Ordinal)) -ge 0) {
  $gStart = $at + $marker.Length
  if ($text[$gStart + 36] -ne '}') { throw 'Неожиданный формат имени PrivateImplementationDetails' }
  $gb = [System.Text.Encoding]::ASCII.GetBytes($fixedGuid)
  [Array]::Copy($gb, 0, $b, $gStart, 36)
  $from = $gStart + 37
}

[System.IO.File]::WriteAllBytes($tmp, $b)
Move-Item -LiteralPath $tmp -Destination $exe -Force

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$ver = & $exe --version
if ($LASTEXITCODE -ne 0) { throw "OptomstroySvc.exe --version завершился с кодом $LASTEXITCODE" }
Write-Host "Собран: $exe"
Write-Host "Версия: $ver"
Write-Host "Компилятор: $Csc ($cscVer)"
Write-Host "SHA256: $hash"
[pscustomobject]@{ Path = $exe; Version = $ver; Sha256 = $hash }
