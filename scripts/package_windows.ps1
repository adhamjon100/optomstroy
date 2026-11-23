<#
  Упаковка release-сборки pos-app для Windows в zip-архив для администратора ПК заказчика (13 RM-H-007, 16 §10.7,
  12 T-BUILD-005, T-BIO-032). Windows PowerShell 5.1 и PowerShell 7. Запуск из корня репозитория:

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_windows.ps1 -EnvFile env/prod.json
    ... -EnvFile env/staging.json -OutDir D:\release -Incremental -CleanAfter
    ... -EnvFile env/prod.json -PreflightOnly            # только шаги 0–1: можно ли собрать без сети
    ... -SkipBuild [-BundleDir <каталог>] [-NoZip]       # проверить (и упаковать) уже собранный пакет

  Шаги:
    0. Предусловия: версия из pos-app/pubspec.yaml; профили -EnvFile (пути — от pos-app; несколько — через запятую,
       как у --dart-define-from-file: следующий перекрывает предыдущий); ENV=prod — только с https-адресом API;
       место на диске сборки ≥ -MinFreeGB (2,5 ГБ); pos-app не занят другим flutter/dart; артефакты движка Flutter
       windows-x64 и windows-x64-release уже в кэше Flutter.
    1. Сторонние архивы чистой сборки. В чистом build/windows плагины при конфигурации CMake берут из сети:
       printing — PDFium (github.com/bblanchon/pdfium-binaries, pdfium-win-x64.tgz, chromium/<PDFIUM_VERSION>),
       sqlite3_flutter_libs — SQLite (sqlite.org, sqlite-autoconf-<версия>.tar.gz), local_auth_windows — nuget.exe
       (если его нет в PATH) и пакеты NuGet WIL и CppWinRT. Версии и имена скрипт читает из CMakeLists.txt плагинов
       (пути — из pos-app/.dart_tool/package_config.json). Без -AllowDownload (по умолчанию) сеть не нужна:
         - PDFium и SQLite — из кэша -CacheDir (по умолчанию %OPTOMSTROY_WIN_CACHE% или
           %LOCALAPPDATA%\Optomstroy\win-build-cache): pdfium\chromium-<версия>\pdfium-win-x64.tgz и
           sqlite\<имя архива>. В пути кэша не должно быть пробелов, «;» и кавычек — иначе выход с кодом 2 в шаге 0,
           до сборки (если они есть в имени пользователя, задайте -CacheDir или %OPTOMSTROY_WIN_CACHE%; с -SkipBuild
           кэш не используется). Путь передаётся CMake переменными окружения OPTOMSTROY_PDFIUM_ARCHIVE и
           OPTOMSTROY_SQLITE_ARCHIVE (pos-app/windows/CMakeLists.txt, «Offline third-party archives»). Файл
           <архив>.sha256 рядом — хэш, записанный при наполнении кэша; CMake сверяет его (OPTOMSTROY_*_SHA256);
         - NuGet — из глобальной папки пакетов (%NUGET_PACKAGES% или %USERPROFILE%\.nuget\packages): в
           build/windows/x64 кладётся NuGet.Config без источников, и nuget.exe ставит пакеты из этой папки;
         - rive_native — библиотеки уже в pub-кэше (метка windows/rive_marker_windows_setup_complete);
         - процессу сборки HTTP_PROXY/HTTPS_PROXY/ALL_PROXY указывают на закрытый порт 127.0.0.1:9 — случайное
           обращение в сеть сразу падает (страховка, не гарантия).
       Чего-то нет — выход с кодом 2 и перечнем. Наполнить кэш: один раз собрать с -AllowDownload на машине с
       интернетом — скачанные плагинами архивы сами копируются в кэш (с .sha256); или положить файлы вручную (скрипт
       покажет их SHA-256 — запишите его в <архив>.sha256 после сверки с источником). Архив из прежней сборки с сетью
       (build/windows) копируется в кэш до чистки.
    2. Чистка: build/flutter_assets (устаревший kernel_blob.bin от debug-сборки или `flutter test -d windows`, +121 МБ)
       и весь build/windows; с -Incremental — вместо build/windows только каталог пакета
       build/windows/x64/runner/Release (в нём не остаются файлы прежних установок).
    3. flutter build windows --release --no-pub --dart-define-from-file=<каждый -EnvFile>
       [--obfuscate --split-debug-info=<OutDir>\<имя>-symbols — путь абсолютный, символы лежат рядом с архивом и в
       него не входят].
    4. Проверка пакета build/windows/x64/runner/Release (или -BundleDir):
       - есть <BINARY_NAME>.exe, flutter_windows.dll, data/app.so, data/icudtl.dat, data/flutter_assets/AssetManifest.bin,
         FontManifest.json, NOTICES.Z и DLL Visual C++ msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll;
       - нет kernel_blob.bin, vm_snapshot_data, isolate_snapshot_data и файлов *.lib, *.exp, *.pdb, *.ilk, *.iobj,
         *.ipdb, *.obj;
       - каждый .exe и .dll — x64; его импорты, в том числе отложенные, читаются из PE-заголовка (как
         `dumpbin /dependents`). DLL должна быть в пакете или быть системной (api-ms-win-*, ext-ms-win-*, файл есть в
         %SystemRoot%\System32). DLL Visual C++ — только из пакета: Redistributable на ПК может не быть. Отладочная
         среда (vcruntime140d.dll и т. п.) — ошибка. jvm.dll у dartjni.dll (JNI нужен только на Android, на Windows
         библиотека не загружается) — предупреждение;
       - ProductVersion и FileVersion exe равны версии pubspec (12 T-BUILD-005);
       - отчёт: число файлов, размер, 10 самых больших, версии DLL Visual C++.
    5. Архив <OutDir>\optomstroy-pos-windows-<версия>[-<ENV>].zip (суффикс — у ENV не prod: такой архив владельцу не
       передаётся): файлы пакета — в корне архива (16 §10.7 шаг 5), имена через «/». Архив перечитывается, SHA-256
       каждого файла сверяется с пакетом. Рядом: SHA256SUMS («<sha256>  <имя zip>», 16 §10.7 шаг 1), <имя>.files.tsv
       (путь, байты, SHA-256) и <имя>.package.json (версия, ENV, Flutter, архивы, время шагов, размеры).
    6. -CleanAfter: удалить build/windows и .dart_tool/flutter_build (на диске сборки мало места).
  OutDir по умолчанию — <репозиторий>\.tmp\win-release (вне git). Относительные -OutDir, -CacheDir и -BundleDir
  берутся от каталога запуска (текущего каталога PowerShell), а не от pos-app, как -EnvFile: «-OutDir dist\<версия>»
  из корня репозитория — это <репозиторий>\dist\<версия>, и символы -Obfuscate лежат там же, рядом с архивом.
  Скрипт не запускает приложение и не вызывает Windows Hello.
  Коды выхода: 0 — готово; 1 — пакет не прошёл проверку; 2 — предусловия; 3 — ошибка сборки; 4 — ошибка архива.
#>
param(
  [string[]]$EnvFile = @(),
  [string]$OutDir = '',
  [string]$CacheDir = '',
  [switch]$Incremental,
  [switch]$AllowDownload,
  [switch]$Obfuscate,
  [switch]$CleanAfter,
  [switch]$PreflightOnly,
  [switch]$SkipBuild,
  [string]$BundleDir = '',
  [switch]$NoZip,
  [double]$MinFreeGB = 2.5
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$App = Join-Path $Root 'pos-app'
$BuildWin = Join-Path $App 'build\windows'
$BuildX64 = Join-Path $BuildWin 'x64'
$DefaultBundle = Join-Path $BuildX64 'runner\Release'
if (-not $OutDir) { $OutDir = Join-Path $Root '.tmp\win-release' }
if (-not $CacheDir) {
  if ($env:OPTOMSTROY_WIN_CACHE) { $CacheDir = $env:OPTOMSTROY_WIN_CACHE }
  else { $CacheDir = Join-Path $env:LOCALAPPDATA 'Optomstroy\win-build-cache' }
}
# -File передаёт «a,b» одной строкой — делим сами.
$EnvFile = @($EnvFile | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$VcRuntimeRequired = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$VcRuntimePattern = '^(msvcp140(_[a-z0-9_]+)?|vcruntime140(_[a-z0-9]+)?|concrt140|vccorlib140|vcomp140|vcamp140|mfcm?140u?)\.dll$'
$DebugCrtPattern = '^(msvcp140d|msvcp140d_[a-z0-9_]+|vcruntime140d|vcruntime140_1d|concrt140d|ucrtbased)\.dll$'
$OptionalImports = @{ 'dartjni.dll|jvm.dll' = 'JNI нужен только на Android; на Windows dartjni.dll не загружается' }
$ForbiddenNames = @('kernel_blob.bin', 'vm_snapshot_data', 'isolate_snapshot_data')
$ForbiddenExt = @('.lib', '.exp', '.pdb', '.ilk', '.iobj', '.ipdb', '.obj')
$DeadProxy = 'http://127.0.0.1:9'
$NuGetConfigMarker = 'written by scripts/package_windows.ps1'

$Errors = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$Timings = [ordered]@{}
$Report = [ordered]@{}

function Step([string]$t) { Write-Host "`n=== $t" -ForegroundColor Cyan }
function Info([string]$t) { Write-Host "  $t" }
function Warn([string]$t) { $script:Warnings.Add($t); Write-Host "  ПРЕДУПРЕЖДЕНИЕ: $t" -ForegroundColor Yellow }
function Fail([string]$t) { $script:Errors.Add($t); Write-Host "  ОШИБКА: $t" -ForegroundColor Red }
function Stop-With([int]$code, [string]$t) { Write-Host "`n$t" -ForegroundColor Red; exit $code }
function Format-Bytes([long]$n) { '{0:N0} байт ({1:N1} МиБ)' -f $n, ($n / 1MB) }
function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
function Measure-Step([string]$name, [scriptblock]$body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { & $body } finally { $script:Timings[$name] = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
function Remove-Under([string]$path, [string]$base) {
  # Удаляет только внутри $base (pos-app\build или pos-app\.dart_tool).
  $full = [IO.Path]::GetFullPath($path)
  $b = [IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
  if (-not $full.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { throw "отказ удалять вне ${b}: $full" }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force; Info "удалено: $full" }
}

# ------------------------------------------------------------------- PE: архитектура и импорты (dumpbin /dependents)
function Read-PeInfo([string]$Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  if ($b.Length -lt 64 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "не PE-файл: $Path" }
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  if ([BitConverter]::ToUInt32($b, $pe) -ne 0x00004550) { throw "нет сигнатуры PE: $Path" }
  $machine = [BitConverter]::ToUInt16($b, $pe + 4)
  $nSec = [BitConverter]::ToUInt16($b, $pe + 6)
  $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
  $opt = $pe + 24
  $magic = [BitConverter]::ToUInt16($b, $opt)
  if ($magic -eq 0x20B) { $dd = $opt + 112; $imageBase = [BitConverter]::ToUInt64($b, $opt + 24); $nDirs = [BitConverter]::ToUInt32($b, $opt + 108) }
  elseif ($magic -eq 0x10B) { $dd = $opt + 96; $imageBase = [uint64][BitConverter]::ToUInt32($b, $opt + 28); $nDirs = [BitConverter]::ToUInt32($b, $opt + 92) }
  else { throw ('неизвестный формат заголовка PE (0x{0:X}): {1}' -f $magic, $Path) }
  $secs = @()
  for ($i = 0; $i -lt $nSec; $i++) {
    $s = $opt + $optSize + 40 * $i
    $secs += [pscustomobject]@{
      VA = [long][BitConverter]::ToUInt32($b, $s + 12); VSize = [long][BitConverter]::ToUInt32($b, $s + 8)
      RawSize = [long][BitConverter]::ToUInt32($b, $s + 16); RawPtr = [long][BitConverter]::ToUInt32($b, $s + 20)
    }
  }
  $toOff = {
    param([long]$rva)
    foreach ($s in $secs) {
      $size = [Math]::Max($s.VSize, $s.RawSize)
      if ($rva -ge $s.VA -and $rva -lt $s.VA + $size) { return [int]($rva - $s.VA + $s.RawPtr) }
    }
    return -1
  }
  $readStr = {
    param([int]$off)
    $e = $off
    while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }
    [Text.Encoding]::ASCII.GetString($b, $off, $e - $off)
  }
  $imports = @(); $delay = @()
  if ($nDirs -gt 1) {
    $rva = [long][BitConverter]::ToUInt32($b, $dd + 8)
    $off = if ($rva) { & $toOff $rva } else { -1 }
    while ($off -ge 0 -and $off + 20 -le $b.Length) {
      $nameRva = [long][BitConverter]::ToUInt32($b, $off + 12)
      if ($nameRva -eq 0 -and [BitConverter]::ToUInt32($b, $off + 16) -eq 0) { break }
      $no = & $toOff $nameRva
      if ($no -ge 0) { $imports += (& $readStr $no) }
      $off += 20
    }
  }
  if ($nDirs -gt 13) {
    $rva = [long][BitConverter]::ToUInt32($b, $dd + 13 * 8)
    $off = if ($rva) { & $toOff $rva } else { -1 }
    while ($off -ge 0 -and $off + 32 -le $b.Length) {
      $attr = [BitConverter]::ToUInt32($b, $off)
      $nameRva = [long][BitConverter]::ToUInt32($b, $off + 4)
      if ($nameRva -eq 0) { break }
      if (($attr -band 1) -eq 0) { $nameRva = [long]([uint64]$nameRva - $imageBase) }
      $no = & $toOff $nameRva
      if ($no -ge 0) { $delay += (& $readStr $no) }
      $off += 32
    }
  }
  [pscustomobject]@{ Machine = $machine; Imports = $imports; DelayImports = $delay }
}

# ------------------------------------------------------------------- проверка пакета (шаг 4)
function Test-Bundle([string]$Dir, [string]$BinaryName, [string]$Version) {
  $Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { Fail "нет каталога пакета: $Dir"; return $null }
  $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | ForEach-Object {
      [pscustomobject]@{ Rel = $_.FullName.Substring($Dir.Length + 1).Replace('\', '/'); Full = $_.FullName; Length = $_.Length }
    } | Sort-Object Rel)
  $rels = @{}; foreach ($f in $files) { $rels[$f.Rel.ToLowerInvariant()] = $f }
  $rootDlls = @{}; foreach ($f in $files) { if ($f.Rel -notmatch '/' ) { $rootDlls[$f.Rel.ToLowerInvariant()] = $true } }

  $required = @("$BinaryName.exe", 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat',
    'data/flutter_assets/AssetManifest.bin', 'data/flutter_assets/FontManifest.json', 'data/flutter_assets/NOTICES.Z') + $VcRuntimeRequired
  foreach ($r in $required) { if (-not $rels.ContainsKey($r.ToLowerInvariant())) { Fail "в пакете нет $r" } }

  foreach ($f in $files) {
    $name = [IO.Path]::GetFileName($f.Rel).ToLowerInvariant()
    if ($ForbiddenNames -contains $name) { Fail "в пакете лишний $($f.Rel) ($(Format-Bytes $f.Length)) — артефакт debug-сборки" }
    if ($ForbiddenExt -contains [IO.Path]::GetExtension($name)) { Fail "в пакете лишний $($f.Rel) ($(Format-Bytes $f.Length)) — файл сборки, не для раздачи" }
  }

  $system32 = Join-Path $env:SystemRoot 'System32'
  $deps = [ordered]@{}
  # Ненайденные импорты: «вид|dll» → кто импортирует (одно сообщение на DLL).
  $unresolved = [ordered]@{}
  foreach ($f in $files) {
    if ($f.Rel -notmatch '\.(exe|dll)$') { continue }
    try { $pe = Read-PeInfo $f.Full } catch { Fail $_.Exception.Message; continue }
    if ($pe.Machine -ne 0x8664) { Fail ('{0}: архитектура 0x{1:X4}, нужна x64 (0x8664)' -f $f.Rel, $pe.Machine) }
    $importer = [IO.Path]::GetFileName($f.Rel).ToLowerInvariant()
    $all = @($pe.Imports | ForEach-Object { [pscustomobject]@{ Name = $_; Delay = $false } }) +
      @($pe.DelayImports | ForEach-Object { [pscustomobject]@{ Name = $_; Delay = $true } })
    $deps[$f.Rel] = @($all | ForEach-Object { if ($_.Delay) { "$($_.Name) (отложенно)" } else { $_.Name } })
    foreach ($imp in $all) {
      $n = $imp.Name.ToLowerInvariant()
      if ($rootDlls.ContainsKey($n) -and $n -notmatch $DebugCrtPattern) { continue }
      if ($n -match '^(api|ext)-ms-win-') { continue }
      if ($n -match $DebugCrtPattern) { $kind = 'debug' }
      elseif ($n -match $VcRuntimePattern) { $kind = 'vc' }
      elseif (Test-Path -LiteralPath (Join-Path $system32 $imp.Name)) { continue }
      elseif ($OptionalImports.ContainsKey("$importer|$n")) { $kind = 'optional' }
      elseif ($imp.Delay) { $kind = 'delay' }
      else { $kind = 'missing' }
      $key = "$kind|$n"
      if (-not $unresolved.Contains($key)) { $unresolved[$key] = New-Object System.Collections.Generic.List[string] }
      $unresolved[$key].Add($f.Rel)
    }
  }
  foreach ($key in $unresolved.Keys) {
    $kind, $n = $key -split '\|', 2
    $who = $unresolved[$key] -join ', '
    switch ($kind) {
      'debug' { Fail "$n — отладочная среда Visual C++: пакет собран не в Release (импортируют: $who)" }
      'vc' { Fail "$n — DLL Visual C++, её нет в пакете (импортируют: $who); список — OPTOMSTROY_VC_RUNTIME_DLLS в pos-app/windows/CMakeLists.txt" }
      'optional' {
        $why = ($OptionalImports.GetEnumerator() | Where-Object { $_.Key.EndsWith("|$n") } | Select-Object -First 1).Value
        Warn "$n не найден (импортирует: $who) — $why"
      }
      'delay' { Warn "$n (отложенный импорт) не найден ни в пакете, ни в System32 (импортируют: $who)" }
      default { Fail "$n не найден ни в пакете, ни в System32 (импортируют: $who)" }
    }
  }

  $exe = Join-Path $Dir "$BinaryName.exe"
  $exeVersion = $null
  if (Test-Path -LiteralPath $exe) {
    $vi = (Get-Item -LiteralPath $exe).VersionInfo
    $exeVersion = [ordered]@{ ProductVersion = $vi.ProductVersion; FileVersion = $vi.FileVersion }
    if ($Version -and ($vi.ProductVersion -ne $Version -or $vi.FileVersion -ne $Version)) {
      Fail "$BinaryName.exe: ProductVersion «$($vi.ProductVersion)», FileVersion «$($vi.FileVersion)», а в pubspec «$Version» (12 T-BUILD-005)"
    }
  }
  $vc = [ordered]@{}
  foreach ($d in $VcRuntimeRequired) {
    $p = Join-Path $Dir $d
    if (Test-Path -LiteralPath $p) { $vc[$d] = (Get-Item -LiteralPath $p).VersionInfo.FileVersion }
  }
  $total = 0L; foreach ($f in $files) { $total += $f.Length }
  [pscustomobject]@{ Dir = $Dir; Files = $files; Total = $total; Deps = $deps; ExeVersion = $exeVersion; VcRuntime = $vc }
}

# ------------------------------------------------------------------- шаг 0: предусловия
Step '0. Предусловия'
# Относительные пути параметров — от каталога запуска (текущего каталога PowerShell). Абсолютными они становятся до
# любой работы с файлами: flutter работает из pos-app (Push-Location; tool_backend делает pos-app текущим каталогом) и
# разрешил бы --split-debug-info от pos-app, а вызовы .NET (журнал, zip, SHA256SUMS, .files.tsv, .package.json) —
# от текущего каталога процесса, который Set-Location не меняет. Каталог может ещё не существовать.
function Resolve-ParamPath([string]$name, [string]$path) {
  $provider = $null; $drive = $null
  try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path, [ref]$provider, [ref]$drive) }
  catch {
    $ex = $_.Exception; if ($ex.InnerException) { $ex = $ex.InnerException }
    Stop-With 2 "-${name}: путь «$path» не разобран ($($ex.Message))"
  }
  if ($provider.Name -ne 'FileSystem') { Stop-With 2 "-${name}: «$path» — не путь файловой системы (провайдер $($provider.Name)); укажите путь на диске" }
  return $full
}
$OutDir = Resolve-ParamPath 'OutDir' $OutDir
$CacheDir = Resolve-ParamPath 'CacheDir' $CacheDir
if ($BundleDir) { $BundleDir = Resolve-ParamPath 'BundleDir' $BundleDir }
Info "OutDir: $OutDir"
# Путь кэша уходит в CMake (OPTOMSTROY_*_ARCHIVE) и в PATH (nuget.exe). Проверка — до сборки: с -AllowDownload кэш
# наполняется после неё, и остановка там оставила бы build/windows без проверки, архива и -CleanAfter.
if (-not $SkipBuild -and $CacheDir -match '[ ;"]') {
  Stop-With 2 "путь кэша не должен содержать пробелов, «;» и кавычек ($CacheDir) — задайте -CacheDir или %OPTOMSTROY_WIN_CACHE%"
}
$pubspec =Get-Content -LiteralPath (Join-Path $App 'pubspec.yaml') -Raw -Encoding UTF8
$m = [regex]::Match($pubspec, '(?m)^version:\s*([^\s#]+)')
if (-not $m.Success) { Stop-With 2 'нет version в pos-app/pubspec.yaml' }
$Version = $m.Groups[1].Value
$cm = Get-Content -LiteralPath (Join-Path $App 'windows\CMakeLists.txt') -Raw
$m = [regex]::Match($cm, 'set\(BINARY_NAME\s+"([^"]+)"\)')
if (-not $m.Success) { Stop-With 2 'нет BINARY_NAME в pos-app/windows/CMakeLists.txt' }
$BinaryName = $m.Groups[1].Value
Info "версия pubspec: $Version; exe: $BinaryName.exe"

$envValues = [ordered]@{}
$envPaths = @()
foreach ($e in $EnvFile) {
  $p = if ([IO.Path]::IsPathRooted($e)) { $e } else { Join-Path $App $e }
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-With 2 "нет файла профиля: $p" }
  $p = (Resolve-Path -LiteralPath $p).Path
  $envPaths += $p
  $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($prop in $json.PSObject.Properties) { $envValues[$prop.Name] = [string]$prop.Value }
}
if (-not $SkipBuild -and $envPaths.Count -eq 0) {
  Stop-With 2 'укажите -EnvFile: env/prod.json — архив владельцу; env/staging.json или env/dev.json — только для проверок (pos-app/env/README.md)'
}
$EnvName = ''
if ($envValues.Contains('ENV')) { $EnvName = $envValues['ENV'] } elseif ($envValues.Contains('ENVIRONMENT')) { $EnvName = $envValues['ENVIRONMENT'] }
$EnvName = $EnvName.Trim().ToLowerInvariant()
if (-not $EnvName) { $EnvName = 'unknown' }
if ($EnvName -eq 'prod') {
  $api = ''; if ($envValues.Contains('API_BASE_URL')) { $api = $envValues['API_BASE_URL'] }
  if ($api -notmatch '^https://') { Stop-With 2 "ENV=prod: API_BASE_URL должен быть https:// (06 §6.9), сейчас «$api»" }
  if ($envValues.Contains('APP_DATA_DIR') -and $envValues['APP_DATA_DIR']) { Warn 'ENV=prod: APP_DATA_DIR в prod игнорируется приложением — уберите его из профиля' }
} else {
  if (-not $SkipBuild) { Warn "ENV=$EnvName — архив только для проверок, владельцу не передаётся (в имени архива суффикс -$EnvName)" }
}
$BaseName = "optomstroy-pos-windows-$Version"
if ($EnvName -ne 'prod') { $BaseName += "-$EnvName" }
Info "профили: $(if ($envPaths) { $envPaths -join '; ' } else { '—' }); ENV=$EnvName; архив: $BaseName.zip"
$Report['version'] = $Version; $Report['env'] = $EnvName; $Report['env_files'] = $envPaths

$flutterCmd = $null
if (-not $SkipBuild) {
  $drive = $App.Substring(0, 1)
  $freeGB = [math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 2)
  Info "свободно на ${drive}: $freeGB ГБ (нужно ≥ $MinFreeGB)"
  if ($freeGB -lt $MinFreeGB) { Stop-With 2 "мало места на ${drive}: $freeGB ГБ, release-сборке нужно ≥ $MinFreeGB ГБ" }
  $busy = Get-CimInstance Win32_Process -Filter "Name='dart.exe' OR Name='flutter.exe' OR Name='dartaotruntime.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'pos-app' }
  if ($busy) { Stop-With 2 "pos-app занят другим процессом flutter/dart (PID $(@($busy.ProcessId) -join ', ')): дождитесь его окончания" }
  $flutterCmd = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -match '\.(bat|cmd|exe)$' } | Select-Object -First 1
  if (-not $flutterCmd) { Stop-With 2 'flutter не найден в PATH' }
  $FlutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCmd.Source)
  $engine = Join-Path $FlutterRoot 'bin\cache\artifacts\engine'
  foreach ($a in @('windows-x64\cpp_client_wrapper', 'windows-x64-release\flutter_windows.dll', 'windows-x64-release\gen_snapshot.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $engine $a))) {
      if ($AllowDownload) { Warn "нет артефакта движка Flutter $a — flutter скачает его (-AllowDownload)" }
      else { Stop-With 2 "нет артефакта движка Flutter $a (нужен ``flutter precache --windows`` с сетью)" }
    }
  }
  $fv = Join-Path $FlutterRoot 'bin\cache\flutter.version.json'
  if (Test-Path -LiteralPath $fv) {
    $fvj = Get-Content -LiteralPath $fv -Raw | ConvertFrom-Json
    $Report['flutter'] = "$($fvj.frameworkVersion) (engine $($fvj.engineRevision))"
    Info "Flutter $($Report['flutter'])"
  }
}
if ($SkipBuild -and -not $BundleDir) { $BundleDir = $DefaultBundle }

# ------------------------------------------------------------------- шаг 1: сторонние архивы
$Deps = @()
$buildEnv = [ordered]@{}
if (-not $SkipBuild) {
  Step "1. Сторонние архивы чистой сборки (кэш: $CacheDir; сеть: $(if ($AllowDownload) { 'разрешена (-AllowDownload)' } else { 'не используется' }))"
  $pkgCfgPath = Join-Path $App '.dart_tool\package_config.json'
  if (-not (Test-Path -LiteralPath $pkgCfgPath)) { Stop-With 2 'нет pos-app/.dart_tool/package_config.json — выполните flutter pub get' }
  $pkgCfg = Get-Content -LiteralPath $pkgCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  function Get-PackageDir([string]$name) {
    $p = $pkgCfg.packages | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $p) { return $null }
    $uri = [string]$p.rootUri
    if ($uri -match '^file:') { return ([Uri]$uri).LocalPath }
    return [IO.Path]::GetFullPath((Join-Path (Join-Path $App '.dart_tool') $uri))
  }
  $missing = @()

  function Find-InBuildTree([string]$fileName) {
    if (-not (Test-Path -LiteralPath $BuildX64)) { return $null }
    Get-ChildItem -LiteralPath $BuildX64 -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\(pdfium-src|_deps\\sqlite3-src)\\' } | Select-Object -First 1
  }
  function Use-CachedArchive([string]$label, [string]$cachePath, [string]$envVar, [scriptblock]$seedCheck) {
    # $CacheDir проверен в шаге 0; остаток пути — из CMakeLists.txt плагина (версия PDFium, имя архива SQLite). Шаг 1
    # вызывает функцию для тех же путей до сборки, поэтому после сборки (наполнение кэша) проверка уже не сработает.
    if ($cachePath -match '[ ;"]') { Stop-With 2 "${label}: путь кэша не должен содержать пробелов, «;» и кавычек ($cachePath) — задайте -CacheDir" }
    if (-not (Test-Path -LiteralPath $cachePath)) {
      $seed = Find-InBuildTree ([IO.Path]::GetFileName($cachePath))
      if ($seed -and (& $seedCheck $seed)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $cachePath) | Out-Null
        Copy-Item -LiteralPath $seed.FullName -Destination $cachePath
        $h = Get-Sha256 $cachePath
        [IO.File]::WriteAllText("$cachePath.sha256", "$h  $([IO.Path]::GetFileName($cachePath))`n", (New-Object Text.UTF8Encoding($false)))
        Info "$label — в кэш из прежней сборки: $($seed.FullName) → $cachePath (SHA-256 $h)"
      }
    }
    if (Test-Path -LiteralPath $cachePath) {
      $h = Get-Sha256 $cachePath
      $side = "$cachePath.sha256"
      $recorded = ''
      if (Test-Path -LiteralPath $side) { $recorded = ((Get-Content -LiteralPath $side -Raw).Trim() -split '\s+')[0].ToLowerInvariant() }
      if ($recorded) {
        if ($recorded -ne $h) { Stop-With 2 "${label}: SHA-256 архива $h не совпадает с записанным в $side ($recorded)" }
        $script:buildEnv[$envVar.Replace('_ARCHIVE', '_SHA256')] = $recorded
      } else {
        Warn "${label}: у $cachePath нет файла .sha256 — сверьте SHA-256 $h с источником и запишите его в $side"
      }
      $script:buildEnv[$envVar] = $cachePath
      Info "$label — из кэша: $cachePath (SHA-256 $h)"
      return [ordered]@{ name = $label; source = 'cache'; path = $cachePath; sha256 = $h; recorded_sha256 = [bool]$recorded }
    }
    return $null
  }

  # PDFium (printing)
  $printing = Get-PackageDir 'printing'
  if ($printing) {
    $pcm = Get-Content -LiteralPath (Join-Path $printing 'windows\CMakeLists.txt') -Raw
    $pv = [regex]::Match($pcm, 'set\(PDFIUM_VERSION\s+"([^"]+)"').Groups[1].Value
    $pdfName = 'pdfium-win-x64.tgz'
    if (-not $pv -or $pv -eq 'latest') {
      $missing += "PDFium: в $printing\windows\CMakeLists.txt версия «$pv» — без закреплённой версии кэш не используется"
    } else {
      $pdfCache = Join-Path $CacheDir "pdfium\chromium-$pv\$pdfName"
      $ver = $pv
      $r = Use-CachedArchive "PDFium chromium/$pv" $pdfCache 'OPTOMSTROY_PDFIUM_ARCHIVE' {
        param($seed)
        # Скачанный архив проверяется по адресу, с которым его скачал ExternalProject.
        $info = Get-ChildItem -LiteralPath (Join-Path $BuildX64 'pdfium-download') -Recurse -File -Filter '*urlinfo.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $info) { return $false }
        return [bool]((Get-Content -LiteralPath $info.FullName -Raw) -match [regex]::Escape("/chromium/$ver/$pdfName"))
      }
      if ($r) { $Deps += $r } else { $missing += "PDFium: нет $pdfCache (https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/$pv/$pdfName)" }
    }
  }
  # SQLite (sqlite3_flutter_libs)
  $sq = Get-PackageDir 'sqlite3_flutter_libs'
  if ($sq) {
    $scm = Get-Content -LiteralPath (Join-Path $sq 'windows\CMakeLists.txt') -Raw
    $url = [regex]::Match($scm, '(?m)^\s*URL\s+(\S+)').Groups[1].Value
    if (-not $url) { $missing += "SQLite: адрес архива не найден в $sq\windows\CMakeLists.txt" }
    else {
      $sqCache = Join-Path $CacheDir ('sqlite\' + [IO.Path]::GetFileName($url))
      $r = Use-CachedArchive "SQLite $([IO.Path]::GetFileName($url))" $sqCache 'OPTOMSTROY_SQLITE_ARCHIVE' { param($seed) $true }
      if ($r) { $Deps += $r } else { $missing += "SQLite: нет $sqCache ($url)" }
    }
  }
  # NuGet (local_auth_windows)
  $la = Get-PackageDir 'local_auth_windows'
  $useNuGetGuard = $false
  if ($la) {
    $lcm = Get-Content -LiteralPath (Join-Path $la 'windows\CMakeLists.txt') -Raw
    $nugetExe = Get-Command nuget -ErrorAction SilentlyContinue
    if (-not $nugetExe) {
      $cachedNuget = Join-Path $CacheDir 'nuget\nuget.exe'
      if (Test-Path -LiteralPath $cachedNuget) { $buildEnv['PATH'] = (Split-Path -Parent $cachedNuget) + ';' + $env:PATH; Info "nuget.exe — из кэша: $cachedNuget" }
      else { $missing += "nuget.exe: нет в PATH и в $cachedNuget (иначе плагин local_auth_windows скачает его с dist.nuget.org)" }
    } else { Info "nuget.exe: $($nugetExe.Source)" }
    $gp = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
    foreach ($pair in @(@('WIL_VERSION', 'Microsoft.Windows.ImplementationLibrary'), @('CPPWINRT_VERSION', 'Microsoft.Windows.CppWinRT'))) {
      $v = [regex]::Match($lcm, "set\($($pair[0])\s+`"([^`"]+)`"\)").Groups[1].Value
      $dir = Join-Path $gp ($pair[1].ToLowerInvariant() + '\' + $v)
      if ($v -and (Test-Path -LiteralPath (Join-Path $dir ($pair[1].ToLowerInvariant() + ".$v.nupkg")))) {
        Info "NuGet $($pair[1]) $v — из глобальной папки пакетов $gp"
        $Deps += [ordered]@{ name = "NuGet $($pair[1]) $v"; source = 'nuget-global-packages'; path = $dir }
      } else { $missing += "NuGet: нет $($pair[1]) $v в $gp" }
    }
    $useNuGetGuard = $true
  }
  # rive_native: библиотеки в pub-кэше
  $rv = Get-PackageDir 'rive_native'
  if ($rv) {
    $marker = (Test-Path -LiteralPath (Join-Path $rv 'windows\rive_marker_windows_setup_complete')) -or (Test-Path -LiteralPath (Join-Path $rv 'windows\rive_marker_windows_development'))
    if ($marker -and (Test-Path -LiteralPath (Join-Path $rv 'windows\bin\lib\release\rive_native.dll'))) { Info "rive_native: библиотеки в pub-кэше ($rv)" }
    else { $missing += "rive_native: нет библиотек в $rv\windows\bin (их скачивает «dart run rive_native:setup»)" }
  }

  $Report['third_party'] = $Deps
  if ($missing.Count -gt 0) {
    if ($AllowDownload) { foreach ($x in $missing) { Warn "$x — плагин скачает при сборке (-AllowDownload)" } }
    else {
      foreach ($x in $missing) { Fail $x }
      Stop-With 2 ("Сборка без сети невозможна: нет $($missing.Count) из нужных файлов (выше). Наполните кэш: один раз соберите с " +
        "-AllowDownload на машине с интернетом (скачанные архивы скрипт сам положит в $CacheDir), или положите файлы " +
        'вручную и запишите их SHA-256 в <архив>.sha256. Подробности — в шапке скрипта, шаг 1.')
    }
  }
  if ($PreflightOnly) { Write-Host "`nПредусловия выполнены: сборку можно запускать$(if (-not $AllowDownload) { ' без сети' })." -ForegroundColor Green; exit 0 }
}

# ------------------------------------------------------------------- шаги 2–3: чистка и сборка
$SymbolsDir = $null
if (-not $SkipBuild) {
  Step "2. Чистка$(if ($Incremental) { ' (-Incremental: build/windows сохраняется)' })"
  $buildRoot = Join-Path $App 'build'
  Remove-Under (Join-Path $buildRoot 'flutter_assets') $buildRoot
  if ($Incremental) { Remove-Under $DefaultBundle $buildRoot } else { Remove-Under $BuildWin $buildRoot }
  $nugetConfig = Join-Path $BuildX64 'NuGet.Config'
  if ($useNuGetGuard -and -not $AllowDownload) {
    New-Item -ItemType Directory -Force $BuildX64 | Out-Null
    $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<!-- $NuGetConfigMarker`: no package sources, nuget installs from the global packages folder -->`n<configuration>`n  <packageSources>`n    <clear />`n  </packageSources>`n</configuration>`n"
    [IO.File]::WriteAllText($nugetConfig, $xml, (New-Object Text.UTF8Encoding($false)))
    Info "NuGet.Config без источников: $nugetConfig"
  } elseif ((Test-Path -LiteralPath $nugetConfig) -and ((Get-Content -LiteralPath $nugetConfig -Raw) -match [regex]::Escape($NuGetConfigMarker))) {
    Remove-Item -LiteralPath $nugetConfig -Force
  }

  Step '3. flutter build windows --release'
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  $flutterArgs = @('build', 'windows', '--release', '--no-pub')
  foreach ($p in $envPaths) { $flutterArgs += "--dart-define-from-file=$p" }
  if ($Obfuscate) {
    $SymbolsDir = Join-Path $OutDir "$BaseName-symbols"
    $flutterArgs += @('--obfuscate', "--split-debug-info=$SymbolsDir")
  }
  $log = Join-Path $OutDir "$BaseName.build.log"
  Info "flutter $($flutterArgs -join ' ')"
  Info "журнал: $log"
  if ($SymbolsDir) { Info "символы --split-debug-info: $SymbolsDir" }
  $saved = @{}
  $setEnv = [ordered]@{}
  foreach ($k in $buildEnv.Keys) { $setEnv[$k] = $buildEnv[$k] }
  if (-not $AllowDownload) { foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') { $setEnv[$k] = $DeadProxy }; $setEnv['NO_PROXY'] = ''; $setEnv['no_proxy'] = '' }
  $tmp = Join-Path $Root '.tmp'
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $setEnv['TEMP'] = $tmp; $setEnv['TMP'] = $tmp
  foreach ($k in $setEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $setEnv[$k], 'Process') }
  $code = 0
  try {
    Measure-Step 'build' {
      Push-Location $App
      $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      # Tee-Object в PowerShell 5.1 пишет UTF-16 — журнал пишется сам, в UTF-8.
      $w = New-Object IO.StreamWriter($log, $false, (New-Object Text.UTF8Encoding($false)))
      try {
        & $flutterCmd.Source @flutterArgs 2>&1 | ForEach-Object { $line = "$_"; $w.WriteLine($line); $line }
        $script:code = $LASTEXITCODE
      } finally { $w.Dispose(); $ErrorActionPreference = $eap; Pop-Location }
    }
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
  Info "flutter build: код $code, $($Timings['build']) с"
  $Report['build_command'] = "flutter $($flutterArgs -join ' ')"
  $Report['build_exit_code'] = $code
  if ($AllowDownload) {
    # Наполнить кэш тем, что плагины скачали в этой сборке.
    if ($printing -and $pv -and $pv -ne 'latest') { $null = Use-CachedArchive "PDFium chromium/$pv" $pdfCache 'OPTOMSTROY_PDFIUM_ARCHIVE' { param($seed) $true } }
    if ($sq -and $url) { $null = Use-CachedArchive "SQLite $([IO.Path]::GetFileName($url))" $sqCache 'OPTOMSTROY_SQLITE_ARCHIVE' { param($seed) $true } }
  }
  if ($code -ne 0) { Stop-With 3 "flutter build windows --release: код $code (журнал $log)$(if ($CleanAfter) { '; -CleanAfter не выполнялся: build/windows оставлен для разбора' })" }
  $BundleDir = $DefaultBundle
}

# ------------------------------------------------------------------- шаг 4: проверка пакета
Step "4. Проверка пакета: $BundleDir"
$bundle = $null
Measure-Step 'verify' { $script:bundle = Test-Bundle $BundleDir $BinaryName $Version }
if ($bundle) {
  Info ("файлов: {0}; размер: {1}" -f $bundle.Files.Count, (Format-Bytes $bundle.Total))
  Info 'самые большие:'
  $bundle.Files | Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object { Info ('  {0,14:N0}  {1}' -f $_.Length, $_.Rel) }
  Info "DLL Visual C++: $(($bundle.VcRuntime.Keys | ForEach-Object { "$_ $($bundle.VcRuntime[$_])" }) -join '; ')"
  if ($bundle.ExeVersion) { Info "$BinaryName.exe: ProductVersion $($bundle.ExeVersion.ProductVersion), FileVersion $($bundle.ExeVersion.FileVersion)" }
  Info 'зависимости (импорты PE):'
  foreach ($k in $bundle.Deps.Keys) { Info "  ${k}: $($bundle.Deps[$k] -join ', ')" }
  $Report['bundle'] = [ordered]@{
    dir = $bundle.Dir; files = $bundle.Files.Count; bytes = $bundle.Total; exe_version = $bundle.ExeVersion
    vc_runtime = $bundle.VcRuntime; imports = $bundle.Deps
  }
}
if ($Errors.Count -gt 0) {
  Write-Host "`nПакет не прошёл проверку: ошибок $($Errors.Count), предупреждений $($Warnings.Count)." -ForegroundColor Red
  $Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  if ($CleanAfter -and -not $SkipBuild) { Write-Host '  -CleanAfter не выполнялся: build/windows оставлен для разбора, удалите его после' -ForegroundColor Yellow }
  exit 1
}
Write-Host "  пакет прошёл проверку (предупреждений: $($Warnings.Count))" -ForegroundColor Green

# ------------------------------------------------------------------- шаг 5: архив
if (-not $NoZip) {
  Step "5. Архив $BaseName.zip"
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  $zip = Join-Path $OutDir "$BaseName.zip"
  try {
    Measure-Step 'zip' {
      Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
      if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
      $hashes = @{}
      $fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
      try {
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
          foreach ($f in $bundle.Files) {
            $hashes[$f.Rel] = Get-Sha256 $f.Full
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.Full, $f.Rel, [IO.Compression.CompressionLevel]::Optimal)
          }
        } finally { $za.Dispose() }
      } finally { $fs.Dispose() }
      # Перечитать архив и сверить каждый файл.
      $sha = [Security.Cryptography.SHA256]::Create()
      $zr = [IO.Compression.ZipFile]::OpenRead($zip)
      try {
        if ($zr.Entries.Count -ne $bundle.Files.Count) { throw "в архиве $($zr.Entries.Count) записей, в пакете $($bundle.Files.Count) файлов" }
        foreach ($en in $zr.Entries) {
          if ($en.FullName -match '\\') { throw "запись с «\»: $($en.FullName)" }
          if (-not $hashes.ContainsKey($en.FullName)) { throw "лишняя запись: $($en.FullName)" }
          $st = $en.Open()
          try { $h = ([BitConverter]::ToString($sha.ComputeHash($st)) -replace '-', '').ToLowerInvariant() } finally { $st.Dispose() }
          if ($h -ne $hashes[$en.FullName]) { throw "SHA-256 записи $($en.FullName) не совпадает с файлом пакета" }
        }
      } finally { $zr.Dispose(); $sha.Dispose() }
      $script:zipHash = Get-Sha256 $zip
      $script:zipLen = (Get-Item -LiteralPath $zip).Length
      $utf8 = New-Object Text.UTF8Encoding($false)
      $sums = Join-Path $OutDir 'SHA256SUMS'
      $lines = @()
      if (Test-Path -LiteralPath $sums) { $lines = @(Get-Content -LiteralPath $sums | Where-Object { $_ -and $_ -notmatch "\s\*?$([regex]::Escape("$BaseName.zip"))$" }) }
      $lines += "$zipHash  $BaseName.zip"
      [IO.File]::WriteAllText($sums, (($lines -join "`n") + "`n"), $utf8)
      $tsv = @("path`tbytes`tsha256") + @($bundle.Files | ForEach-Object { "$($_.Rel)`t$($_.Length)`t$($hashes[$_.Rel])" })
      [IO.File]::WriteAllText((Join-Path $OutDir "$BaseName.files.tsv"), (($tsv -join "`n") + "`n"), $utf8)
    }
  } catch {
    Stop-With 4 "архив: $($_.Exception.Message)"
  }
  Info "архив: $zip — $(Format-Bytes $zipLen) (пакет $(Format-Bytes $bundle.Total)), $($Timings['zip']) с"
  Info "SHA-256: $zipHash (записан в $(Join-Path $OutDir 'SHA256SUMS'))"
  $Report['zip'] = [ordered]@{ path = $zip; bytes = $zipLen; sha256 = $zipHash }
  if ($SymbolsDir) { $Report['split_debug_info'] = $SymbolsDir; Info "символы --split-debug-info: $SymbolsDir (в архив не входят, хранить у исполнителя)" }
}

# ------------------------------------------------------------------- шаг 6: чистка после
if ($CleanAfter -and -not $SkipBuild) {
  Step '6. Чистка после сборки (-CleanAfter)'
  Remove-Under $BuildWin (Join-Path $App 'build')
  Remove-Under (Join-Path $App '.dart_tool\flutter_build') (Join-Path $App '.dart_tool')
}

$Report['timings_s'] = $Timings
$Report['warnings'] = @($Warnings)
if (-not $NoZip) {
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $OutDir "$BaseName.package.json"), ($Report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
Write-Host "`nГотово. Время, с: $(($Timings.Keys | ForEach-Object { "$_ $($Timings[$_])" }) -join '; '). Предупреждений: $($Warnings.Count)." -ForegroundColor Green
exit 0
