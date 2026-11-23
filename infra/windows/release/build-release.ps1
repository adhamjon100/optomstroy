<#
.SYNOPSIS
  Собирает пакет сервера Optomstroy POS для Windows Server 2022: Optomstroy-Server-<версия>-win-x64.zip.
  Запускается на ПК разработчика (Windows, Node.js 24 x64, npm, git). Права администратора не нужны, сеть не нужна.

.DESCRIPTION
  Порядок (как образ optomstroy/api, infra/docker/api/Dockerfile, но для win32-x64):
    1. Копия pos-api (исходники, package*.json, tsconfig, scripts, migrations, seeds, assets, node_modules) в папку
       сборки — рабочая папка pos-api не меняется.
    2. npm run build в копии; затем npm prune --omit=dev --ignore-scripts --offline (только рабочие зависимости).
    3. Проверка машинных модулей win32-x64: @node-rs/argon2 (хеш и проверка) и sharp (кодирование WebP) загружаются
       и работают на node.exe пакета.
    4. Состав пакета:
         node\node.exe             Node.js с ПК разработчика (версия и SHA256 — в release.json)
         api\                      dist, node_modules, package.json, migrations, seeds, assets
         svchost\                  OptomstroySvc.exe (собран из исходника встроенным csc.exe) + исходник и скрипты
         backup\, postgres\, apache\   скрипты пакетов infra\windows\* (без тестов)
         scripts\                  install / update / rollback / status / uninstall, ops-tool.mjs, шаблоны .env
         README.md, release.json, SHA256SUMS.txt
    5. Поиск секретов в пакете (блоки закрытых ключей PEM, URL с паролем, запрещённые имена файлов); находка — стоп.
    6. Zip; рядом — SHA256SUMS.txt со строкой пакета (её сверяют install.ps1 / update.ps1). Печатает размер и SHA256.
  Старые пакеты Optomstroy-Server-*-win-x64.zip в -OutDir удаляются (место на диске), папка сборки — тоже
  (оставить: -KeepStage).

.PARAMETER Version
  Версия пакета. По умолчанию <версия pos-api>-<git describe --always --dirty>.
.PARAMETER OutDir
  Куда положить пакет. По умолчанию <репозиторий>\.tmp\wn-release.
.PARAMETER NodeExe
  node.exe, который войдёт в пакет (Node.js 24 x64). По умолчанию — node из PATH.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\release\build-release.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$OutDir = '',
    [string]$NodeExe = '',
    [switch]$KeepStage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$total = [Diagnostics.Stopwatch]::StartNew()
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$win = Join-Path $repo 'infra\windows'
$posApi = Join-Path $repo 'pos-api'
if (-not $OutDir) { $OutDir = Join-Path $repo '.tmp\wn-release' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$timings = [ordered]@{}
function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Measure-Phase([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Body
    $timings[$Name] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkDir) {
    Push-Location $WorkDir
    try {
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $File @Arguments 2>&1 | ForEach-Object { Write-Host "  | $_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $eap
    } finally { Pop-Location }
    if ($code -ne 0) { throw "$File $($Arguments -join ' '): код $code" }
}
function Copy-Tree([string]$From, [string]$To, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
    $a = @($From, $To, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1', '/MT:16')
    if ($ExcludeDirs.Count -gt 0) { $a += '/XD'; $a += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $a += '/XF'; $a += $ExcludeFiles }
    & robocopy.exe @a | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> ${To}: код $LASTEXITCODE" }
}

# ---------- 0. исходные данные ----------
Step '0. Исходные данные'
if (-not $NodeExe) { $NodeExe = (Get-Command node.exe -ErrorAction Stop).Source }
$nodeVer = (& $NodeExe --version).Trim()
if ($nodeVer -notmatch '^v24\.') { throw "нужен Node.js 24, а $NodeExe — $nodeVer" }
$nodeArch = (& $NodeExe -p 'process.arch').Trim()
if ($nodeArch -ne 'x64') { throw "нужен node.exe x64, а $NodeExe — $nodeArch" }
$pkg = Get-Content -LiteralPath (Join-Path $posApi 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$gitDescribe = ''
$gitCommit = ''
try {
    $gitDescribe = (& git -C $repo describe --tags --always --dirty 2>$null | Out-String).Trim()
    $gitCommit = (& git -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
} catch { }
if (-not $Version) {
    $Version = $pkg.version
    if ($gitDescribe) { $Version = "$($pkg.version)-$gitDescribe" }
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,40}$') { throw "недопустимая версия: $Version (латиница, цифры, . _ -; до 41 символа)" }
$zipName = "Optomstroy-Server-$Version-win-x64.zip"
Write-Host "  версия пакета: $Version"
Write-Host "  git: $gitDescribe ($gitCommit)"
Write-Host "  node: $NodeExe $nodeVer $nodeArch"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stage = Join-Path $OutDir 'stage'
$build = Join-Path $stage 'b'
$rel = Join-Path $stage 'r'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $build, $rel | Out-Null

# ---------- 1. копия pos-api ----------
Step '1. Копия pos-api в папку сборки'
Measure-Phase 'copy-pos-api' {
    foreach ($f in @('package.json', 'package-lock.json', 'tsconfig.json', 'tsconfig.build.json')) {
        Copy-Item -LiteralPath (Join-Path $posApi $f) -Destination $build
    }
    foreach ($d in @('src', 'scripts', 'migrations', 'seeds', 'assets')) {
        Copy-Tree (Join-Path $posApi $d) (Join-Path $build $d)
    }
    Copy-Tree (Join-Path $posApi 'node_modules') (Join-Path $build 'node_modules') @('.cache', '.vite', '.vitest')
}

# ---------- 2. сборка и рабочие зависимости ----------
Step '2. npm run build; npm prune --omit=dev (offline)'
$npm = (Get-Command npm.cmd -ErrorAction Stop).Source
Measure-Phase 'npm-build' { Invoke-Checked $npm @('run', 'build') $build }
Measure-Phase 'npm-prune' { Invoke-Checked $npm @('prune', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund', '--offline') $build }
foreach ($e in @('dist\main.js', 'dist\worker.js', 'dist\migrate.js', 'dist\admin\bootstrap\first-admin.cli.js')) {
    if (-not (Test-Path -LiteralPath (Join-Path $build $e))) { throw "после сборки нет $e" }
}
# typescript остаётся законно: его тянет рабочая зависимость @nestjs/swagger (npm ls typescript --omit=dev).
foreach ($d in @('node_modules\vitest', 'node_modules\eslint', 'node_modules\prettier')) {
    if (Test-Path -LiteralPath (Join-Path $build $d)) { throw "после prune остался dev-пакет $d" }
}

# ---------- 3. машинные модули win32-x64 ----------
Step '3. Машинные модули win32-x64'
$native = @()
foreach ($d in @('node_modules\@node-rs\argon2-win32-x64-msvc', 'node_modules\@img\sharp-win32-x64')) {
    $p = Join-Path $build $d
    if (-not (Test-Path -LiteralPath $p)) { throw "нет $d — машинный модуль под win32-x64 не установлен" }
    $j = Get-Content -LiteralPath (Join-Path $p 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $native += [ordered]@{ name = $j.name; version = $j.version }
    Write-Host "  $($j.name) $($j.version)"
}
$probe = @'
const a = await import('@node-rs/argon2');
const h = await a.hash('optomstroy-probe');
if (!(await a.verify(h, 'optomstroy-probe'))) throw new Error('argon2 verify');
const sharp = (await import('sharp')).default;
const buf = await sharp({ create: { width: 2, height: 2, channels: 3, background: '#336699' } }).webp().toBuffer();
if (buf.length < 10) throw new Error('sharp webp');
console.log('native-ok argon2 sharp ' + sharp.versions.vips);
'@
Measure-Phase 'native-probe' { Invoke-Checked $NodeExe @('--input-type=module', '-e', $probe) $build }

# ---------- 4. состав пакета ----------
Step '4. Состав пакета'
Measure-Phase 'assemble' {
    New-Item -ItemType Directory -Force -Path (Join-Path $rel 'node'), (Join-Path $rel 'api') | Out-Null
    Copy-Item -LiteralPath $NodeExe -Destination (Join-Path $rel 'node\node.exe')
    $nodeLicense = Join-Path (Split-Path -Parent $NodeExe) 'LICENSE'
    if (Test-Path -LiteralPath $nodeLicense) { Copy-Item -LiteralPath $nodeLicense -Destination (Join-Path $rel 'node\LICENSE') }
    Copy-Tree (Join-Path $build 'dist') (Join-Path $rel 'api\dist') @() @('*.tsbuildinfo')
    Copy-Tree (Join-Path $build 'node_modules') (Join-Path $rel 'api\node_modules') @('.cache')
    foreach ($d in @('migrations', 'seeds', 'assets')) { Copy-Tree (Join-Path $posApi $d) (Join-Path $rel "api\$d") }
    Copy-Item -LiteralPath (Join-Path $posApi 'package.json') -Destination (Join-Path $rel 'api\package.json')

    # OptomstroySvc.exe — из исходника, встроенным компилятором.
    $svcOut = Join-Path $rel 'svchost'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $win 'svchost\build-svchost.ps1') -OutDir $svcOut | ForEach-Object { Write-Host "  | $_" }
    if ($LASTEXITCODE -ne 0) { throw "build-svchost.ps1: код $LASTEXITCODE" }
    foreach ($f in @('OptomstroySvc.cs', 'build-svchost.ps1', 'rehearse-service.ps1', 'README.md')) { Copy-Item -LiteralPath (Join-Path $win "svchost\$f") -Destination $svcOut }

    Copy-Tree (Join-Path $win 'backup') (Join-Path $rel 'backup') @('tests')
    Copy-Tree (Join-Path $win 'postgres') (Join-Path $rel 'postgres') @('test', 'tests')
    Copy-Tree (Join-Path $win 'apache') (Join-Path $rel 'apache') @('tests')
    Copy-Tree (Join-Path $win 'scripts') (Join-Path $rel 'scripts')
    New-Item -ItemType Directory -Force -Path (Join-Path $rel 'scripts\templates') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'infra\env\prod.env.example') -Destination (Join-Path $rel 'scripts\templates\prod.env.example')
    Copy-Item -LiteralPath (Join-Path $repo 'infra\env\test.env.example') -Destination (Join-Path $rel 'scripts\templates\test.env.example')
    Copy-Item -LiteralPath (Join-Path $win 'README.md') -Destination (Join-Path $rel 'README.md')
}

$svcExe = Join-Path $rel 'svchost\OptomstroySvc.exe'
$svcSha = (Get-FileHash -LiteralPath $svcExe -Algorithm SHA256).Hash.ToLowerInvariant()
$svcVer = (& $svcExe --version 2>&1 | Out-String).Trim()
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$cscVer = (Get-Item -LiteralPath $csc).VersionInfo.FileVersion
$nodeSha = (Get-FileHash -LiteralPath (Join-Path $rel 'node\node.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
$migs = @(Get-ChildItem -LiteralPath (Join-Path $rel 'api\migrations') -Filter '*.sql' | ForEach-Object { $_.Name } | Sort-Object)
$boss = Get-Content -LiteralPath (Join-Path $rel 'api\node_modules\pg-boss\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# Версия приложения для MIN_APP_VERSION по умолчанию (как install.sh: pos-app/pubspec.yaml).
$appVer = ''
$pub = Join-Path $repo 'pos-app\pubspec.yaml'
if (Test-Path -LiteralPath $pub) {
    $m = Select-String -LiteralPath $pub -Pattern '^version:\s*([0-9][0-9.]*)' | Select-Object -First 1
    if ($m) { $appVer = $m.Matches[0].Groups[1].Value }
}
$info = [ordered]@{
    kind = 'optomstroy-server-win-x64'
    version = $Version
    builtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git = [ordered]@{ describe = $gitDescribe; commit = $gitCommit }
    posApi = [ordered]@{ version = $pkg.version; pgBoss = $boss.version; migrations = $migs.Count; lastMigration = $(if ($migs.Count) { $migs[-1] } else { '' }) }
    node = [ordered]@{ version = $nodeVer; sha256 = $nodeSha; source = 'ПК разработчика' }
    svchost = [ordered]@{ version = $svcVer; sha256 = $svcSha; compiler = "csc.exe $cscVer" }
    posApp = [ordered]@{ version = $appVer }
    nativeModules = $native
    postgresTested = '17.10'
}
[System.IO.File]::WriteAllText((Join-Path $rel 'release.json'), (($info | ConvertTo-Json -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---------- 5. поиск секретов ----------
Step '5. Поиск секретов в пакете'
Measure-Phase 'secret-scan' {
    $scan = @'
import fs from 'node:fs'; import path from 'node:path';
const root = process.argv[2];
// Настоящий блок ключа: заголовок и за ним строки base64 (в коде сторонних пакетов встречается только заголовок).
const pem = /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\r?\n[A-Za-z0-9+\/=]{40,}\r?\n/;
// URL вида scheme://user:password@ в сторонних пакетах (api/node_modules) — примеры из документации и тестов
// (validator, pg-pool, pino…): считаются отдельно и не останавливают сборку; в нашем коде — стоп.
const thirdParty = (rel) => rel.split(/[\\/]/).includes('node_modules');
const info = [];
const urlPw = /\b(?:postgres(?:ql)?|mysql|mongodb|redis|amqp|https?):\/\/[A-Za-z0-9._%-]+:[^@\s'"<>{}$\/]{6,}@/;
const badName = /^(?:\.env(?:\..*)?|.*\.(?:pfx|p12|key|jks|keystore)|id_rsa|id_ed25519|pg_password|database_url|db_migrator_password|db_backup_password|otp_pepper|pin_pepper|jwt_private\.pem|pgpass_backup\.conf|backup-private\.pem)$/i;
const okName = /\.env\.example$/i;
const hits = []; let files = 0;
const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name);
  if (e.isDirectory()) { walk(p); continue; } files++;
  const rel = path.relative(root, p);
  if (badName.test(e.name) && !okName.test(e.name)) hits.push(`имя файла: ${rel}`);
  const st = fs.statSync(p); if (st.size > 8 * 1024 * 1024) continue;
  const t = fs.readFileSync(p).toString('latin1');
  if (pem.test(t)) hits.push(`закрытый ключ PEM: ${rel}`);
  const m = urlPw.exec(t); if (m && !/user:pass(word)?@|:\*+@|:<|example|localhost:5432\/postgres/.test(m[0])) (thirdParty(rel) ? info : hits).push(`URL с паролем: ${rel}: ${m[0].replace(/:[^:@]+@$/, ':***@')}`);
} };
walk(root);
console.log(JSON.stringify({ files, hits, thirdPartyExamples: info.length }));
'@
    # Через файл: Windows PowerShell 5.1 портит кавычки внутри аргумента -e.
    $scanFile = Join-Path $stage 'secret-scan.mjs'
    [System.IO.File]::WriteAllText($scanFile, $scan, (New-Object System.Text.UTF8Encoding($false)))
    $out = & $NodeExe $scanFile $rel
    if ($LASTEXITCODE -ne 0) { throw "поиск секретов: код $LASTEXITCODE" }
    $res = $out | ConvertFrom-Json
    Write-Host "  проверено файлов: $($res.files); примеров URL с паролем в сторонних пакетах (не секреты): $($res.thirdPartyExamples)"
    if (@($res.hits).Count -gt 0) {
        $res.hits | ForEach-Object { Write-Host "  НАХОДКА: $_" -ForegroundColor Red }
        throw "в пакете найдены похожие на секреты данные ($(@($res.hits).Count)) — пакет не собран"
    }
    Write-Host '  находок нет' -ForegroundColor Green
}

# ---------- 6. SHA256SUMS и zip ----------
Step '6. SHA256SUMS.txt и zip'
Measure-Phase 'sums' {
    # node.exe с ПК разработчика — тот же файл, что в пакете (node\node.exe), его SHA256 записан в release.json.
    $sums = & $NodeExe (Join-Path $rel 'scripts\ops-tool.mjs') sums-write --dir $rel --out (Join-Path $rel 'SHA256SUMS.txt')
    if ($LASTEXITCODE -ne 0) { throw 'ops-tool sums-write' }
    Write-Host "  $sums"
}
foreach ($old in @(Get-ChildItem -LiteralPath $OutDir -Filter 'Optomstroy-Server-*-win-x64.zip')) {
    Remove-Item -LiteralPath $old.FullName -Force
    Write-Host "  удалён старый пакет: $($old.Name)"
}
$zip = Join-Path $OutDir $zipName
Measure-Phase 'zip' {
    # Имена записей через «/» (ZipFile.CreateFromDirectory в PowerShell 5.1 пишет «\» — не по спецификации ZIP).
    $zipFiles = & (Join-Path $PSScriptRoot 'New-ReleaseZip.ps1') -SourceDir $rel -ZipPath $zip
    Write-Host "  записей-файлов в zip: $zipFiles"
}
$zipSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS.txt'), "$zipSha  $zipName`n", (New-Object System.Text.UTF8Encoding($false)))

$relBytes = (Get-ChildItem -LiteralPath $rel -Recurse -File -Force | Measure-Object Length -Sum).Sum
$relFiles = (Get-ChildItem -LiteralPath $rel -Recurse -File -Force | Measure-Object).Count
$zipBytes = (Get-Item -LiteralPath $zip).Length
if (-not $KeepStage) { Remove-Item -LiteralPath $stage -Recurse -Force }

Step 'Готово'
Write-Host ("  пакет:      {0}" -f $zip)
Write-Host ("  размер zip: {0:N1} МБ ({1} байт)" -f ($zipBytes / 1MB), $zipBytes)
Write-Host ("  распакован: {0:N1} МБ, файлов {1}" -f ($relBytes / 1MB), $relFiles)
Write-Host ("  SHA256:     {0}" -f $zipSha)
Write-Host ("  node.exe:   {0} SHA256 {1}" -f $nodeVer, $nodeSha)
Write-Host ("  svchost:    {0} SHA256 {1} (csc.exe {2})" -f $svcVer, $svcSha, $cscVer)
Write-Host ("  SHA256SUMS: {0}" -f (Join-Path $OutDir 'SHA256SUMS.txt'))
$timings['total'] = [math]::Round($total.Elapsed.TotalSeconds, 1)
Write-Host ('  время, с:   ' + (($timings.Keys | ForEach-Object { "$_=$($timings[$_])" }) -join ', '))
