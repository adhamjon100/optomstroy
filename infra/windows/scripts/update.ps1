<#
.SYNOPSIS
  Обновление сервера Optomstroy POS на Windows Server 2022 до новой версии пакета. [Администратор]

.DESCRIPTION
  Порядок:
    1. Проверки: права администратора, установка есть (config\install.json, current), PostgreSQL работает.
    2. Пакет: копия zip сверяется с SHA256 (-Sha256 из отдельного канала или -Sha256Sums / SHA256SUMS.txt рядом с
       пакетом, но не из папки установки: в incoming пишет posdeploy), распаковка в releases\<версия>, сверка
       SHA256SUMS.txt всех файлов, проверка config\*.svc.json новым OptomstroySvc.exe --check-config. Службы работают.
    3. План: журнал миграций базы (pos_meta.schema_migrations) и версия схемы pg-boss сравниваются с новой
       версией. Если в базе есть миграции, которых новая версия не знает, — стоп (это не обновление).
    4. Остановка OptomstroyApi и OptomstroyWorker (OptomstroyBackup продолжает работать: архив WAL не прерывается;
       замки state\*.lock не дают дампу и ежедневному прогону выполняться одновременно).
    5. Копия перед обновлением: pos-backup.mjs dump-only (зашифрованный дамп; код 0 — дамп опубликован). Нет копии —
       обновление прекращается, прежняя версия запускается снова.
    6. Если новая версия меняет схему (новые миграции или новая схема pg-boss): копия базы в самом PostgreSQL
       (CREATE DATABASE <база>_preupd_<время> TEMPLATE <база>). Она нужна для автоматического отката: закрытого
       ключа расшифровки дампа на сервере нет (он у держателя ключа). -NoDbSnapshot — без неё (места мало).
    7. config\api.env и worker.env: дописываются только новые имена несекретных настроек из шаблонов новой версии
       (как env_merge_template Linux-комплекта; прежние файлы — в state\update-env-<время>, при откате возвращаются).
       Новые секреты (*_FILE) так не добавляются — их строки администратор дописывает по примечаниям к выпуску.
       current → новая версия; migrate --seed новой версии; перезапуск OptomstroyBackup (новый инструмент);
       запуск API и фоновых задач; проверка /health, /health/ready и фоновых задач.
    8. Успех: state\install-state.json (текущая и прежняя версии), state\releases.log; копия базы удаляется
       (оставить: -KeepSnapshot — тогда rollback.ps1 -RestoreSnapshot сможет вернуть базу).
  Сбой на шагах 5–7 — автоматический откат: службы останавливаются, current возвращается на прежнюю версию; если
  миграции уже запускались (а копия шага 6 есть) — база возвращается из копии шага 6, даже если журнал миграций не
  изменился (migrate --seed и миграции без транзакции меняют базу без строки журнала); изменённая сохраняется как
  <база>_failed_<время> для разбора (если сбой после запуска новой версии — в ней могут быть новые заказы и записи
  очереди в 1С: сверить с 1С), права базы восстанавливает apply-roles.ps1; прежняя версия запускается и проверяется. Если копии
  шага 6 нет, а база изменена, — службы НЕ запускаются: восстановление из дампа шага 5 (restore.ps1, нужен держатель
  ключа), порядок — в сообщении и README.
  Коды выхода: 0 — обновлено; 1 — не обновлено (прежняя версия работает или см. сообщение); 2 — неверные параметры.
  -DevTest: без прав администратора, на установке install.ps1 -DevTest. -DevTestFailAt — проверка отката
  (искусственный сбой после указанного шага; только с -DevTest).

.EXAMPLE
  .\update.ps1 -Zip C:\Users\admin\setup\Optomstroy-Server-0.2.0-win-x64.zip -Sha256 <SHA256 из письма>
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Sha256 = '',
    [string]$Sha256Sums = '',
    [string]$InstallRoot = 'D:\Optomstroy',
    [switch]$KeepSnapshot,
    [switch]$NoDbSnapshot,
    [ValidateRange(30, 1800)][int]$HealthTimeoutSec = 180,
    [switch]$DevTest,
    [ValidateSet('', 'dump', 'migrate', 'health')][string]$DevTestFailAt = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')
if ($DevTestFailAt -and -not $DevTest) { Write-Host '-DevTestFailAt — только с -DevTest'; exit 2 }

$Zip = Resolve-OpsPath $Zip
if ($Sha256Sums) { $Sha256Sums = Resolve-OpsPath $Sha256Sums }
$planOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false   # -WhatIf: только план (ниже); служебные команды (копия пакета, журнал) выполняются по-настоящему
$L = Get-OpsLayout $InstallRoot
$ij = Read-OpsJson $L.InstallJson
if ($null -eq $ij) { Write-Host "нет $($L.InstallJson) — установки нет (install.ps1)"; exit 2 }
if ([bool]$ij.devTest -ne [bool]$DevTest) { Write-Host "установка сделана $(if ($ij.devTest) { 'с' } else { 'без' }) -DevTest — запускайте update.ps1 так же"; exit 2 }
$L = Get-OpsLayout $InstallRoot ([string]$ij.backupRoot)
$null = Initialize-OpsLog $L.Logs 'update'
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$PgPort = [int]$ij.pgPort; $ApiPort = [int]$ij.apiPort; $DbName = [string]$ij.dbName; $PgBin = [string]$ij.pgBin; $appEnv = [string]$ij.appEnv
$state = ConvertTo-OpsHashtable (Read-OpsState $L)
$phase = 'pre'
$oldDir = $null; $oldVer = $null; $new = $null; $dbBefore = $null; $snapshot = $null; $dump = $null; $envBackup = $null
$result = 'failed'

function Invoke-Recovery {
    Write-OpsLog 'Автоматический откат' 'STEP'
    try { Stop-OpsAppServices $L @('OptomstroyWorker', 'OptomstroyApi') -DevTest:$DevTest } catch { Write-OpsLog "остановка: $($_.Exception.Message)" 'WARN' }
    if ($script:phase -ne 'stopped') { Set-OpsJunction $L.Current $script:oldDir }
    if ($script:envBackup) {
        foreach ($f in @('api.env', 'worker.env')) {
            $b = Join-Path $script:envBackup $f
            # Перезапись содержимого (не замена файла): права NTFS файла (чтение NT SERVICE\Optomstroy*) сохраняются.
            if (Test-Path -LiteralPath $b) { [System.IO.File]::WriteAllBytes((Join-Path $L.Config $f), [System.IO.File]::ReadAllBytes($b)) }
        }
        Write-OpsLog "config\api.env, worker.env возвращены из $($script:envBackup)" 'OK'
    }
    $changed = $true
    try {
        $now = Get-OpsDbState $L $script:oldDir $PgPort $DbName
        $changed = ((@($now.migrations) -join ',') -ne (@($script:dbBefore.migrations) -join ',')) -or ([string]$now.pgboss -ne [string]$script:dbBefore.pgboss)
    } catch { Write-OpsLog "журнал миграций не прочитан — считаем, что база изменена: $($_.Exception.Message)" 'WARN' }
    # migrate --seed пишет строки по умолчанию, а миграции без транзакции (CREATE INDEX CONCURRENTLY: 0005, 0024)
    # могут изменить схему без строки журнала: если migrate новой версии запускался и копия есть — база возвращается.
    $migrateRan = @('switched', 'migrated', 'started') -contains $script:phase
    if (-not $changed -and $migrateRan -and $script:snapshot) {
        Write-OpsLog 'журнал миграций не изменился, но migrate новой версии запускался (строки по умолчанию, миграции без транзакции) — база возвращается из копии' 'WARN'
        $changed = $true
    }
    if ($changed -and $script:phase -eq 'started') {
        Write-OpsLog 'сбой после запуска новой версии: заказы и записи очереди обмена с 1С, созданные ею, останутся только в базе <база>_failed_* — сверьте с 1С (журнал обмена) перед её удалением' 'WARN'
    }
    if ($changed) {
        if (-not $script:snapshot) {
            Write-OpsLog 'база уже изменена миграциями новой версии, а копии базы (шаг 6) нет — прежняя версия с этой базой не запускается' 'ERROR'
            $dumpHint = '<дамп перед обновлением>'
            if ($script:dump) { $dumpHint = $script:dump }
            Write-OpsLog "восстановление (администратор и держатель ключа): $($L.Current)\backup\restore.ps1 -DumpFile $dumpHint -KeyFile <backup-private.pem> -InstallRoot $($L.Root); затем Start-Service OptomstroyApi, OptomstroyWorker" 'ERROR'
            $script:result = 'failed-restore-needed'
            return
        }
        $failedName = '{0}_failed_{1}' -f $DbName, (Get-Date -Format 'yyyyMMddHHmmss')
        Stop-OpsAppServices $L @('OptomstroyBackup') -DevTest:$DevTest
        $sw = Invoke-OpsTool $L $script:oldDir @('db', 'snapshot-swap', '--name', $script:snapshot, '--failed-name', $failedName, '--modules', (Join-Path $script:oldDir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        if ($sw.Code -ne 0) { $script:result = 'failed-restore-needed'; throw "возврат копии базы не выполнен (код $($sw.Code)) — службы не запускаются" }
        Write-OpsLog "база возвращена из копии $($script:snapshot); изменённая сохранена как $failedName (удалить после разбора)" 'OK'
        $script:snapshot = $null
        if ($script:state.ContainsKey('lastUpdate') -and $null -ne $script:state.lastUpdate) { $script:state.lastUpdate.snapshot = $null; $script:state.lastUpdate.failedDb = $failedName }
        $code = Invoke-OpsScript (Join-Path $script:oldDir 'postgres\apply-roles.ps1') @{ InstallRoot = $L.Root; Port = $PgPort; SkipArchiveCheck = $true }
        if ($code -ne 0) { $script:result = 'failed-restore-needed'; throw "apply-roles.ps1 после возврата базы: код $code" }
    } else {
        Write-OpsLog 'база не изменялась (migrate новой версии не запускался) — возвращается только программа' 'OK'
        if ($script:snapshot) {
            # Копия больше не нужна: без удаления в кластере осталась бы полная копия базы, а state указывал бы на неё.
            $dr = Invoke-OpsTool $L $script:oldDir @('db', 'snapshot-drop', '--name', $script:snapshot, '--modules', (Join-Path $script:oldDir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
            if ($dr.Code -eq 0) {
                Write-OpsLog "копия базы $($script:snapshot) не понадобилась и удалена" 'OK'
                $script:snapshot = $null
                if ($script:state.ContainsKey('lastUpdate') -and $null -ne $script:state.lastUpdate) { $script:state.lastUpdate.snapshot = $null }
            } else { Write-OpsLog "копия базы $($script:snapshot) не удалена (код $($dr.Code)) — удалите: rollback.ps1 -DropSnapshot" 'WARN' }
        }
    }
    Stop-OpsAppServices $L @('OptomstroyBackup') -DevTest:$DevTest
    Start-OpsAppServices $L @('OptomstroyBackup', 'OptomstroyApi', 'OptomstroyWorker') -DevTest:$DevTest
    $h = Wait-OpsApiHealthy $ApiPort $HealthTimeoutSec
    $w = Test-OpsWorkerAlive $L 15 -DevTest:$DevTest
    if ($h.Ok -and $w.Ok) {
        Write-OpsLog "прежняя версия $($script:oldVer) работает: /health/ready $($h.Ready) ($($h.ReadyStatus)), фоновые задачи — $($w.Reason)" 'OK'
        $script:result = 'rolled-back'
    } else {
        Write-OpsLog "прежняя версия запущена, но проверка не прошла: /health $($h.Health), /health/ready $($h.Ready); фоновые задачи — $($w.Reason)" 'ERROR'
        $script:result = 'rolled-back-unhealthy'
    }
}

try {
    Write-OpsLog 'Проверки' 'STEP'
    if (-not $DevTest -and -not (Test-OpsAdmin)) { throw 'нужен PowerShell «от имени администратора»' }
    $oldDir = Get-OpsJunctionTarget $L.Current
    if ($null -eq $oldDir) { throw 'нет ссылки current — установка не завершена (install.ps1)' }
    $oldVer = [string](Get-OpsReleaseInfo $oldDir).version
    Write-OpsLog "текущая версия: $oldVer ($oldDir)"
    Start-OpsPostgres $L $PgBin $PgPort -DevTest:$DevTest

    Write-OpsLog 'Пакет новой версии' 'STEP'
    $new = Install-OpsReleaseZip -L $L -Zip $Zip -Sha256 $Sha256 -SumsFile $Sha256Sums
    if ($new.Version -eq $oldVer) { throw "версия $oldVer уже установлена" }
    # Описания служб (config\*.svc.json install.ps1) — понимает ли их OptomstroySvc.exe новой версии (до остановки служб).
    foreach ($sf in @('api.svc.json', 'worker.svc.json', 'backup.svc.json')) {
        $ck = Invoke-OpsProcess -FilePath (Join-Path $new.Dir 'svchost\OptomstroySvc.exe') -ArgumentList @('--check-config', '--config', (Join-Path $L.Config $sf))
        if ($ck.Code -ne 0) { throw "OptomstroySvc.exe версии $($new.Version) не принимает config\$sf (код $($ck.Code)) — нужен install.ps1 по примечаниям к выпуску; службы не останавливались" }
    }
    # Новые имена несекретных настроек из шаблонов новой версии (дописываются при переключении, ниже).
    $tplNew = Get-OpsEnvTemplatePairs $new.Dir ([string]$ij.contour)
    $envAdd = [ordered]@{}
    foreach ($f in @('api.env', 'worker.env')) {
        $fp = Join-Path $L.Config $f
        $have = Read-OpsEnvTemplate $fp
        $pairs = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in $tplNew.Keys) { if ([string]$tplNew[$k] -ne '' -and -not $have.Contains($k)) { $pairs[$k] = $tplNew[$k] } }
        $envAdd[$f] = $pairs
        if ($pairs.Count -gt 0) { Write-OpsLog ("config\{0}: будут дописаны новые имена версии {1}: {2}" -f $f, $new.Version, (@($pairs.Keys) -join ', ')) }
    }

    Write-OpsLog 'План' 'STEP'
    $dbBefore = Get-OpsDbState $L $oldDir $PgPort $DbName
    $newMigs = Get-OpsReleaseMigrations $new.Dir
    $applied = @($dbBefore.migrations)
    $unknown = @($applied | Where-Object { $newMigs -notcontains $_ })
    if ($unknown.Count -gt 0) { throw ("в базе есть миграции, которых нет в версии $($new.Version): " + ($unknown -join ', ') + ' — это не обновление (откат программы — rollback.ps1)') }
    $pending = @($newMigs | Where-Object { $applied -notcontains $_ })
    $bossOld = Get-OpsReleasePgBossVersion $oldDir
    $bossNew = Get-OpsReleasePgBossVersion $new.Dir
    $schemaChange = ($pending.Count -gt 0) -or ($bossOld -ne $bossNew)
    Write-OpsLog ("{0} → {1}; новых миграций: {2}{3}; pg-boss {4} → {5}; база {6:N0} МБ" -f $oldVer, $new.Version, $pending.Count, $(if ($pending.Count) { ' (' + ($pending -join ', ') + ')' } else { '' }), $bossOld, $bossNew, ([double]$dbBefore.sizeBytes / 1MB))
    if ($planOnly) { Write-OpsLog '-WhatIf: дальше — остановка API и фоновых задач, копия, миграции, запуск. Ничего не изменено (кроме распаковки пакета в releases).' 'OK'; $result = 'whatif'; return }

    Write-OpsLog 'Остановка API и фоновых задач' 'STEP'
    $state.lastUpdate = [ordered]@{ from = $oldVer; to = $new.Version; startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); migrationsBefore = $applied; pgbossBefore = $dbBefore.pgboss; dump = $null; snapshot = $null; status = 'running' }
    $state.lastOperation = 'update'; $state.lastOperationStatus = 'running'
    Save-OpsState $L $state
    $phase = 'stopped'
    Stop-OpsAppServices $L @('OptomstroyWorker', 'OptomstroyApi') -DevTest:$DevTest

    Write-OpsLog 'Копия перед обновлением (зашифрованный дамп)' 'STEP'
    $bkCfg = Read-OpsJson (Join-Path $L.Config 'backup.json')
    if ($DevTest -and -not (Test-Path -LiteralPath (Join-Path ([string]$bkCfg.pgBin) 'pg_dump.exe'))) {
        Write-OpsLog "DevTest: в $($bkCfg.pgBin) нет pg_dump.exe — копия перед обновлением ПРОПУЩЕНА (на сервере это стоп)" 'WARN'
    } else {
        $d = Invoke-OpsProcess -FilePath (Join-Path $oldDir 'node\node.exe') -ArgumentList @((Join-Path $oldDir 'backup\pos-backup.mjs'), 'dump-only', '--config', (Join-Path $L.Config 'backup.json')) -CleanEnvironment -TimeoutSec 7200
        $dj = ConvertFrom-OpsJsonLine $d.Out
        if ($d.Code -ne 0 -or $null -eq $dj -or -not $dj.PSObject.Properties['dump']) { throw "копия перед обновлением не создана (pos-backup dump-only, код $($d.Code)) — обновление прекращено" }
        $dump = [string]$dj.dump
        Write-OpsLog ("дамп: {0} ({1:N1} МБ, SHA256 {2})" -f $dump, ([double]$dj.size / 1MB), $dj.sha256) 'OK'
        $state.lastUpdate.dump = $dump
    }
    if ($DevTestFailAt -eq 'dump') { throw 'DevTest: искусственный сбой после копии' }

    if ($schemaChange -and -not $NoDbSnapshot) {
        Write-OpsLog 'Копия базы для автоматического отката' 'STEP'
        $pgDrive = [System.IO.Path]::GetPathRoot($L.PgData).TrimEnd('\')
        $free = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$pgDrive'").FreeSpace
        $needBytes = [double]$dbBefore.sizeBytes * 1.2 + 1GB
        if ($free -lt $needBytes) { throw ("для копии базы нужно {0:N1} ГБ на {1}, свободно {2:N1} ГБ (без копии: -NoDbSnapshot — тогда откат только через restore.ps1)" -f ($needBytes / 1GB), $pgDrive, ($free / 1GB)) }
        $snapName = '{0}_preupd_{1}' -f $DbName, (Get-Date -Format 'yyyyMMddHHmmss')
        $sw0 = [Diagnostics.Stopwatch]::StartNew()
        $s = Invoke-OpsTool $L $oldDir @('db', 'snapshot-create', '--name', $snapName, '--modules', (Join-Path $oldDir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        if ($s.Code -ne 0) { throw "копия базы не создана (код $($s.Code)) — обновление прекращено" }
        $snapshot = $snapName
        $state.lastUpdate.snapshot = $snapName
        Write-OpsLog "копия базы $snapName создана за $([math]::Round($sw0.Elapsed.TotalSeconds, 1)) с" 'OK'
    } elseif ($schemaChange) {
        Write-OpsLog '-NoDbSnapshot: копии базы нет — при сбое миграций откат только через restore.ps1 (держатель ключа)' 'WARN'
    } else { Write-OpsLog 'схема базы не меняется — копия базы не нужна' }
    Save-OpsState $L $state

    Write-OpsLog 'Переключение на новую версию и миграции' 'STEP'
    $phase = 'switched'
    if (@($envAdd.Values | Where-Object { $_.Count -gt 0 }).Count -gt 0) {
        $envBackup = Join-Path $L.State ('update-env-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $envBackup | Out-Null
        foreach ($f in @('api.env', 'worker.env')) { Copy-Item -LiteralPath (Join-Path $L.Config $f) -Destination (Join-Path $envBackup $f) }
        foreach ($f in @('api.env', 'worker.env')) {
            if ($envAdd[$f].Count -eq 0) { continue }
            $added = Write-OpsEnvFile (Join-Path $L.Config $f) '' $envAdd[$f]
            Write-OpsLog ("config\{0}: дописаны {1} (прежний файл — {2})" -f $f, (@($added) -join ', '), $envBackup) 'OK'
        }
    } else { Write-OpsLog 'config\api.env, worker.env: новых имён настроек в новой версии нет' }
    Set-OpsJunction $L.Current $new.Dir
    $m = Invoke-OpsProcess -FilePath (Join-Path $L.Current 'node\node.exe') -ArgumentList @("--env-file=$(Join-Path $L.Config 'migrate.env')", 'dist\migrate.js', '--seed') -WorkingDirectory (Join-Path $new.Dir 'api') -CleanEnvironment -Environment @{ APP_ENV = $appEnv }
    if ($m.Code -ne 0) { throw "migrate новой версии: код $($m.Code)" }
    $mid = Get-OpsDbState $L $new.Dir $PgPort $DbName
    $missing = @($newMigs | Where-Object { @($mid.migrations) -notcontains $_ })
    if ($missing.Count -gt 0) { throw ("после migrate в журнале нет миграций: " + ($missing -join ', ')) }
    if ($DevTestFailAt -eq 'migrate') { throw 'DevTest: искусственный сбой после миграций' }
    $phase = 'migrated'

    Write-OpsLog 'Запуск новой версии' 'STEP'
    Stop-OpsAppServices $L @('OptomstroyBackup') -DevTest:$DevTest
    $phase = 'started'
    Start-OpsAppServices $L @('OptomstroyBackup', 'OptomstroyApi', 'OptomstroyWorker') -DevTest:$DevTest
    $h = Wait-OpsApiHealthy $ApiPort $HealthTimeoutSec
    Write-OpsLog ("/health {0}; /health/ready {1} ({2}); {3} с" -f $h.Health, $h.Ready, $h.ReadyStatus, $h.Seconds)
    if (-not $h.Ok) { throw 'новая версия API не прошла проверку готовности' }
    foreach ($a in (Get-OpsListenAddresses $ApiPort)) { if ($a -ne '127.0.0.1') { throw "API слушает не только 127.0.0.1: $a" } }
    $w = Test-OpsWorkerAlive $L 20 -DevTest:$DevTest
    if (-not $w.Ok) { throw "фоновые задачи новой версии: $($w.Reason)" }
    if ($DevTestFailAt -eq 'health') { throw 'DevTest: искусственный сбой после запуска' }
    Write-OpsLog "API готов, фоновые задачи: $($w.Reason)" 'OK'

    $after = Get-OpsDbState $L $new.Dir $PgPort $DbName
    $state.previousVersion = $oldVer
    $state.currentVersion = $new.Version
    $state.lastUpdate.migrationsAfter = @($after.migrations)
    $state.lastUpdate.pgbossAfter = $after.pgboss
    $state.lastUpdate.finishedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($snapshot -and -not $KeepSnapshot) {
        $dr = Invoke-OpsTool $L $new.Dir @('db', 'snapshot-drop', '--name', $snapshot, '--modules', (Join-Path $new.Dir 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        if ($dr.Code -eq 0) { Write-OpsLog "копия базы $snapshot удалена (откат после этого — rollback.ps1, при изменённой схеме — через дамп)" 'OK'; $state.lastUpdate.snapshot = $null }
        else { Write-OpsLog "копия базы $snapshot не удалена (код $($dr.Code)) — удалите вручную" 'WARN' }
    } elseif ($snapshot) { Write-OpsLog "копия базы $snapshot сохранена (-KeepSnapshot): занимает место; удалить — rollback.ps1 -DropSnapshot" 'WARN' }
    $result = 'ok'
} catch {
    Write-OpsLog ("{0}" -f $_.Exception.Message) 'ERROR'
    if ($phase -ne 'pre' -and $null -ne $oldDir) {
        try { Invoke-Recovery } catch { Write-OpsLog "откат не завершён: $($_.Exception.Message)" 'ERROR'; if ($result -eq 'failed') { $result = 'failed-recovery' } }
    }
} finally {
    if ($state.ContainsKey('lastUpdate') -and $null -ne $state.lastUpdate -and $result -ne 'whatif') {
        if ($state.lastUpdate -is [hashtable] -or $state.lastUpdate -is [System.Collections.Specialized.OrderedDictionary]) { $state.lastUpdate.status = $result }
        $state.lastOperation = 'update'
        $state.lastOperationStatus = $result
        if ($result -ne 'ok') { try { $state.currentVersion = [string](Get-OpsReleaseInfo (Get-OpsJunctionTarget $L.Current)).version } catch { } }
        try { Save-OpsState $L $state; Add-OpsReleasesLog $L ("update {0} -> {1} {2}" -f $oldVer, $(if ($null -ne $new) { $new.Version } else { '?' }), $result) } catch { Write-OpsLog "состояние не записано: $($_.Exception.Message)" 'WARN' }
    }
    Write-OpsLog ("итог: {0}; всего {1} с; журнал {2}" -f $result, [math]::Round($swTotal.Elapsed.TotalSeconds, 1), $script:OpsLogFile) $(if ($result -eq 'ok') { 'OK' } else { 'WARN' })
}
if ($result -eq 'ok' -or $result -eq 'whatif') { exit 0 }
exit 1
