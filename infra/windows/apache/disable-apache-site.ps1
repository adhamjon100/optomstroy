<#
.SYNOPSIS
    Отключает виртуальный хост API Оптомстрой от Apache — откат enable-apache-site.ps1. Для администратора.

.DESCRIPTION
    По умолчанию — только проверка и план. Изменения — только с ключом -Apply. Apache НЕ перезапускается.

    Источник данных — manifest.json, записанный enable-apache-site.ps1 (папка <ApacheDir>\conf\optomstroy-backup\
    <дата-время>-enable-<файл>). Без -Manifest берётся самый новый манифест в -BackupRoot со статусом enabled.

    Точный откат: если httpd.conf с момента подключения не менялся (SHA-256 совпадает с записанным), он
    восстанавливается из копии байт в байт — вместе со строками LoadModule.
    Если httpd.conf после подключения правили: удаляется только наша строка Include (и перевод строки перед ней),
    раскомментированные нами строки LoadModule снова комментируются, если они не изменились и модуль больше никому
    не нужен: если подключён другой хост Оптомстрой (манифест enabled для того же httpd.conf) или в конфигурации
    есть блок <IfModule> этого модуля — модуль остаётся загруженным (в выводе — почему). Остальное не трогается.
    Поэтому порядок отключения двух хостов (рабочий/тестовый) любой.

    Файл хоста в conf\extra удаляется (если до подключения там был другой файл с тем же именем — он возвращается).
    Если файл хоста изменили после подключения — он не удаляется, а переносится в папку копии.
    Перед изменениями текущий httpd.conf копируется в <BackupRoot>\<дата-время>-disable-<файл>.
    После изменений — httpd -t; при ошибке всё возвращается к состоянию до запуска скрипта.

    Коды выхода: 0 — успех/проверка прошла; 1 — стоп по условию; 2 — неверные параметры;
    4 — новая конфигурация не прошла httpd -t (возвращено как было); 6 — ВОЗВРАТ НЕ УДАЛСЯ (вручную, Apache не перезапускать).

.EXAMPLE
    .\disable-apache-site.ps1 -Manifest 'C:\Apache24\conf\optomstroy-backup\20261121-120000-enable-optomstroy-pos.conf\manifest.json' -ServiceName Apache2.4
    .\disable-apache-site.ps1 -Manifest '...\manifest.json' -ServiceName Apache2.4 -Apply
#>
[CmdletBinding()]
param(
    [string]$Manifest = '',
    [string]$ApacheDir = '',
    [string]$BackupRoot = '',
    [string]$SiteConfName = 'optomstroy-pos.conf',
    [string]$ServiceName = '',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'apache-common.ps1')

function Stop-Disable([int]$Code, [string]$Message) {
    Write-Output "СТОП: $Message"
    Write-Output 'httpd.conf не изменён, Apache не перезапускался.'
    exit $Code
}

# ---------- Манифест ----------
if (-not $Manifest) {
    if (-not $BackupRoot) {
        if (-not $ApacheDir) { Stop-Disable 2 'укажите -Manifest или -ApacheDir (тогда манифест ищется в <ApacheDir>\conf\optomstroy-backup)' }
        $BackupRoot = Join-Path $ApacheDir 'conf\optomstroy-backup'
    }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { Stop-Disable 2 "нет папки копий: $BackupRoot" }
    $cands = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object { $_.Name -like "*-enable-$SiteConfName" } | Sort-Object Name -Descending)
    foreach ($c in $cands) {
        $mp = Join-Path $c.FullName 'manifest.json'
        if ((Test-Path -LiteralPath $mp) -and ((Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json).status -eq 'enabled')) { $Manifest = $mp; break }
    }
    if (-not $Manifest) { Stop-Disable 1 "в $BackupRoot нет манифеста подключения $SiteConfName со статусом enabled" }
}
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Stop-Disable 2 "нет файла манифеста: $Manifest" }
$Manifest = Get-FullPath $Manifest
$m = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($m.kind -ne 'optomstroy-apache-enable') { Stop-Disable 2 "это не манифест enable-apache-site.ps1: $Manifest" }
if ($m.status -ne 'enabled') { Stop-Disable 1 "статус манифеста '$($m.status)', а не enabled — откатывать нечего или он уже выполнен" }
if ($ApacheDir -and (ConvertTo-NormPath (Get-FullPath $ApacheDir).TrimEnd('\')) -ne (ConvertTo-NormPath $m.apacheDir)) {
    Stop-Disable 2 "манифест для другого Apache: $($m.apacheDir)"
}
$ApacheDir = $m.apacheDir; $ConfigFile = $m.configFile; $HttpdExe = $m.httpdExe; $targetPath = $m.targetPath
if (-not $ServiceName) { $ServiceName = [string]$m.serviceName }
foreach ($f in @($ConfigFile, $HttpdExe, $m.configBackup)) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Stop-Disable 2 "нет файла: $f" }
}
if ((Get-Sha256Hex ([System.IO.File]::ReadAllBytes($m.configBackup))) -ne $m.originalSha256) { Stop-Disable 1 "копия $($m.configBackup) повреждена (SHA-256 не совпадает)" }
$baseArgs = if ($ServiceName) { @('-n', $ServiceName) } else { @('-d', ($ApacheDir -replace '\\', '/'), '-f', ($ConfigFile -replace '\\', '/')) }

Write-Step "Манифест: $Manifest"
Write-Step "Хост API: $($m.serverName); файл хоста: $targetPath; конфигурация: $ConfigFile"
if (-not $Apply) { Write-Step 'Режим проверки: ничего не меняется (для изменений нужен ключ -Apply).' }
if ($ServiceName) {
    $svcErr = Test-ApacheService $ServiceName $HttpdExe $ConfigFile $ApacheDir
    if ($svcErr) { Stop-Disable 1 $svcErr }
}

# ---------- План для httpd.conf ----------
$curBytes = [System.IO.File]::ReadAllBytes($ConfigFile)
$curHash = Get-Sha256Hex $curBytes
$exact = ($curHash -eq $m.modifiedSha256)
$newBytes = $null
$notes = @()
$handover = @()
if ($exact) {
    $newBytes = [System.IO.File]::ReadAllBytes($m.configBackup)
    Write-Step 'httpd.conf не менялся после подключения — будет восстановлен из копии байт в байт.'
} else {
    Write-Step 'ВНИМАНИЕ: httpd.conf изменён после подключения — удаляются только наши строки, остальное сохраняется.'
    $text = $script:Latin1.GetString($curBytes)
    $added = "`r`n" + $m.includeLine + "`r`n"
    # Наша строка всё ещё последняя — убирается вместе с CRLF перед ней (как было до подключения).
    # Иначе после неё дописаны строки — удаляется только сама строка Include с её переводом строки
    # (CRLF перед ней теперь завершает предыдущую строку, его убирать нельзя).
    if ($text.EndsWith($added, [System.StringComparison]::Ordinal)) {
        $text = $text.Substring(0, $text.Length - $added.Length)
    } else {
        $lines = Split-ConfigLines $text
        $idx = @(Find-IncludeLines $lines $targetPath)
        if ($idx.Count -eq 0) { $notes += "строки Include для $targetPath нет — уже удалена" }
        else {
            $keep = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($idx -notcontains $i) { [void]$keep.Add($lines[$i]) } }
            $text = Join-ConfigLines $keep
        }
    }
    $lines = Split-ConfigLines $text
    # Модуль, который нужен ещё кому-то, не выключается: другому подключённому хосту Оптомстрой (манифест со
    # статусом enabled для того же httpd.conf) или блоку <IfModule> этого модуля в текущей конфигурации (его могли
    # добавить после подключения — выключение молча отключило бы блок, httpd -t этого не заметит).
    $otherEnabled = @()
    foreach ($d in @(Get-ChildItem -LiteralPath (Split-Path -Parent (Split-Path -Parent $Manifest)) -Directory -ErrorAction SilentlyContinue)) {
        $mp = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp -PathType Leaf) -or (ConvertTo-NormPath $mp) -eq (ConvertTo-NormPath $Manifest)) { continue }
        try { $om = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($om.kind -eq 'optomstroy-apache-enable' -and $om.status -eq 'enabled' -and (ConvertTo-NormPath $om.configFile) -eq (ConvertTo-NormPath $ConfigFile)) {
            $otherEnabled += [pscustomobject]@{ Path = $mp; Target = [string]$om.targetPath }
        }
    }
    $incNow = Get-HttpdIncludes (Invoke-Httpd $HttpdExe $baseArgs @('-t', '-D', 'DUMP_INCLUDES')).Text
    $scanFiles = @($incNow.Files | Where-Object { (ConvertTo-NormPath $_) -ne (ConvertTo-NormPath $targetPath) -and (ConvertTo-NormPath $_) -ne (ConvertTo-NormPath $ConfigFile) })
    function Get-ModuleUsers([string]$Module) {
        $short = $Module -replace '_module$', ''
        $pat = '^\s*<IfModule\s+!?\s*"?(' + [regex]::Escape($Module) + '|mod_' + [regex]::Escape($short) + '\.c)"?\s*>'
        $users = @()
        foreach ($o in $otherEnabled) {
            # Модули, нужные хосту Оптомстрой, — общий список (у второго хоста те же директивы).
            if (@($script:OptomstroyRequiredModules + $script:OptomstroyCompressionModules) -contains $Module) { $users += "подключённый хост $($o.Target) ($($o.Path))" }
        }
        $n = 0
        foreach ($l in $lines) { $n++; if ($l.Text -match $pat) { $users += "${ConfigFile}:$n  $($l.Text.Trim())" } }
        foreach ($f in $scanFiles) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            $n = 0
            foreach ($l in [System.IO.File]::ReadAllLines($f, $script:Latin1)) { $n++; if ($l -match $pat) { $users += "${f}:$n  $($l.Trim())" } }
        }
        return , $users
    }
    foreach ($u in @($m.uncommented)) {
        $users = Get-ModuleUsers ([string]$u.module)
        if ($users.Count -gt 0) {
            $notes += "LoadModule $($u.module) оставлен загруженным — он нужен: " + ($users -join '; ')
            # Строку снова закомментирует откат того хоста: запись передаётся в его манифест.
            if ($otherEnabled.Count -gt 0) {
                $handover += [pscustomobject]@{ Manifest = $otherEnabled[0].Path; Entry = $u }
                $notes += "  (строку закомментирует откат хоста $($otherEnabled[0].Target))"
            }
            continue
        }
        $i = [int]$u.line - 1
        $hit = $null
        if ($i -ge 0 -and $i -lt $lines.Count -and $lines[$i].Text -eq $u.after) { $hit = $i }
        else {
            $same = @(); for ($j = 0; $j -lt $lines.Count; $j++) { if ($lines[$j].Text -eq $u.after) { $same += $j } }
            if ($same.Count -eq 1) { $hit = $same[0] }
        }
        if ($null -ne $hit) { $lines[$hit].Text = $u.before; $notes += "LoadModule $($u.module) снова закомментирован (строка $($hit + 1))" }
        else { $notes += "LoadModule $($u.module): строка изменена после подключения — оставлена как есть (модуль остаётся загруженным)" }
    }
    $newBytes = $script:Latin1.GetBytes((Join-ConfigLines $lines))
}
foreach ($n in $notes) { Write-Output "  - $n" }

# ---------- План для файла хоста ----------
$targetAction = 'none'
if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    $tHash = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($targetPath))
    if ($tHash -ne $m.siteConfSha256) { $targetAction = 'move-aside' }
    elseif ($m.targetPreexisting -and $m.targetPrevBackup) { $targetAction = 'restore-prev' }
    else { $targetAction = 'remove' }
}
switch ($targetAction) {
    'remove' { Write-Output "  - удалить $targetPath" }
    'restore-prev' { Write-Output "  - вернуть прежний $targetPath из $($m.targetPrevBackup)" }
    'move-aside' { Write-Output "  - $targetPath изменён после подключения — перенести в папку копии (не удалять)" }
    default { Write-Output "  - файла $targetPath нет" }
}
Write-Output '  - httpd -t по новой конфигурации; при ошибке — вернуть как было до запуска'
if (-not $Apply) {
    Write-Step 'Проверка пройдена. Изменения не выполнялись (нет ключа -Apply).'
    exit 0
}

# ---------- Изменения ----------
$bakDir = Join-Path (Split-Path -Parent (Split-Path -Parent $Manifest)) ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-disable-' + (Split-Path -Leaf $targetPath))
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
$bakNow = Join-Path $bakDir 'httpd.conf.before-disable'
[System.IO.File]::WriteAllBytes($bakNow, $curBytes)
$targetNow = $null
if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    $targetNow = Join-Path $bakDir ((Split-Path -Leaf $targetPath) + '.before-disable')
    Copy-Item -LiteralPath $targetPath -Destination $targetNow -Force
}
Write-Step "Копия текущего состояния: $bakDir"

function Undo-Disable([int]$Code, [string]$Reason) {
    Write-Output "ОШИБКА: $Reason"
    Write-Step 'Возврат к состоянию до запуска…'
    $ok = $true
    try {
        [System.IO.File]::WriteAllBytes($ConfigFile, $curBytes)
        if ($targetNow) { Copy-Item -LiteralPath $targetNow -Destination $targetPath -Force }
    } catch { $ok = $false; Write-Output "  ошибка: $($_.Exception.Message)" }
    $tR = Invoke-Httpd $HttpdExe $baseArgs @('-t')
    if (-not $ok -or (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($ConfigFile))) -ne $curHash) {
        Write-Output "КРИТИЧНО: возврат не подтверждён. Apache НЕ перезапускать. Вручную: Copy-Item '$bakNow' '$ConfigFile' -Force"
        exit 6
    }
    Write-Step "Возвращено как было (httpd -t: код $($tR.Code)). Apache не перезапускался."
    exit $Code
}

try {
    [System.IO.File]::WriteAllBytes($ConfigFile, $newBytes)
    switch ($targetAction) {
        'remove' { Remove-Item -LiteralPath $targetPath -Force }
        'restore-prev' { Copy-Item -LiteralPath $m.targetPrevBackup -Destination $targetPath -Force }
        'move-aside' { Move-Item -LiteralPath $targetPath -Destination (Join-Path $bakDir ((Split-Path -Leaf $targetPath) + '.changed')) -Force }
    }
} catch {
    Undo-Disable 4 "запись файлов: $($_.Exception.Message)"
}

$t1 = Invoke-Httpd $HttpdExe $baseArgs @('-t')
if ($t1.Code -ne 0) { Undo-Disable 4 ("конфигурация после отката не проходит httpd -t:`n" + $t1.Text) }
Write-Step 'httpd -t: Syntax OK.'
$s1 = Invoke-Httpd $HttpdExe $baseArgs @('-S')
$table1 = Get-HttpdVhostTable $s1.Text
if ((Get-HttpdDeclaredNames $table1) -contains ([string]$m.serverName).ToLowerInvariant()) {
    Undo-Disable 4 "хост $($m.serverName) всё ещё объявлен в конфигурации (подключён другим способом?)"
}
$star1 = @($table1 | Where-Object { $_.Port -eq [string]$m.listenPort -and $_.Addr -eq '*' })
if ($star1.Count -eq 1 -and $null -ne $star1[0].Default) {
    Write-Step ("Хост по умолчанию для *:{0}: {1} ({2}:{3}); при подключении был {4}." -f $m.listenPort, $star1[0].Default.Name, $star1[0].Default.File, $star1[0].Default.Line, $m.defaultServer.name)
}
if ($exact -and (Get-Sha256Hex ([System.IO.File]::ReadAllBytes($ConfigFile))) -ne $m.originalSha256) { Undo-Disable 4 'httpd.conf после восстановления не совпал с копией' }

foreach ($h in $handover) {
    try {
        $om = Get-Content -LiteralPath $h.Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = @($om.uncommented | Where-Object { $null -ne $_ })
        if (@($list | Where-Object { $_.module -eq $h.Entry.module }).Count -eq 0) {
            $om.uncommented = @($list + $h.Entry)
            [System.IO.File]::WriteAllText($h.Manifest, ($om | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Step "LoadModule $($h.Entry.module): записан в манифест $($h.Manifest) — его откат закомментирует строку."
    } catch { Write-Output "  ВНИМАНИЕ: не удалось записать $($h.Entry.module) в $($h.Manifest): $($_.Exception.Message) — строку LoadModule при откате того хоста закомментировать вручную." }
}

$m.status = 'disabled'
$m | Add-Member -NotePropertyName disabled -NotePropertyValue ((Get-Date).ToString('o')) -Force
$m | Add-Member -NotePropertyName disableBackup -NotePropertyValue $bakDir -Force
[System.IO.File]::WriteAllText($Manifest, ($m | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

Write-Step "Готово$(if ($exact) { ': httpd.conf совпадает с копией до подключения байт в байт' })."
Write-Output 'Apache НЕ перезапущен. Перезапуск — в согласованное окно:'
Write-Output "  & '$HttpdExe' -n '$(if ($ServiceName) { $ServiceName } else { '<ИмяСлужбыApache>' })' -k restart"
Write-Output 'После перезапуска проверить 1С (код ответа как до подключения).'
exit 0
