<#
.SYNOPSIS
  Установка сервера Optomstroy POS на Windows Server 2022 (без Docker, WSL и Hyper-V). [Администратор]

.DESCRIPTION
  Шаги (каждый повторяемый: повторный запуск продолжает с того места, где остановился, ничего не пересоздаёт):
     1. Проверки: Windows Server 2022, Windows PowerShell 5.1, права администратора, свободное место, свободные
        порты API и PostgreSQL, httpd -S действующего Apache (только чтение), память SQL Server (только чтение).
     2. Папки и права NTFS: наследование от диска отключено, полный доступ только Administrators и SYSTEM;
        posdeploy — запись только в incoming, чтение журналов (logs) и программы (releases: scripts\status.ps1).
        InstallRoot и BackupRoot — только новые, пустые или уже наши папки (отметка .optomstroy-root), не корень тома:
        иначе стоп на шаге 1 (смена прав сняла бы прежние права, например у SQL Server или 1С); -AllowForeignRoot —
        только осознанно.
     3. Брандмауэр: правила блокировки входящих TCP на порт API и порт PostgreSQL с любых адресов.
     4. Пакет релиза: копия zip сверяется с SHA256, распаковка в releases\<версия>, сверка SHA256SUMS.txt всех
        файлов, ссылка current (junction).
     5. Секреты (значения не выводятся): как install.sh Linux-комплекта — пароли PostgreSQL и ролей, database_url,
        otp_pepper, pin_pepper, ключ JWT ES256 и jwt_public.json, pgpass_backup.conf; логин и пароль SMSPro
        (рабочий контур) и учётные данные HTTP-сервиса 1С (onec_hs_user, onec_hs_token, при наличии
        onec_hs_password) вводит человек заказчика (ввод скрыт). Обмен с 1С — онлайн (ONEC_MODE=extension):
        -OnecBaseUrl и -OnecHsPath обязательны, без них API не запускается. Если в BackupRoot уже есть копии базы
        (восстановление на новом сервере), новые pin_pepper/otp_pepper не создаются — сначала secrets из защищённой
        копии (-AllowNewPeppers — только осознанно). Стенд с -StandOnecOsApi (ADR-126): 1С — HTTP-сервис ОС_API
        шлюза, только чтение (ONEC_MODE=os_api); secrets\onec_user и onec_password не вводятся — их заранее кладёт
        import-onec-credentials.ps1 (или администратор), без них — стоп на шаге 1.
     6. Файлы настроек: config\api.env, worker.env, migrate.env (из шаблона prod.env.example Linux-комплекта; секреты —
        только путями *_FILE), api.svc.json, worker.svc.json, backup.svc.json, backup.json, backup-public.pem,
        install.json. Существующие файлы не переписываются (в .env дописываются только новые имена).
        Защищённая копия папки secrets — ops-tool secrets-export (OPTBK1, открытый ключ копий) в <BackupRoot>\dumps\secrets.
     7. PostgreSQL 17: init-postgres.ps1 (служба OptomstroyPostgres, 127.0.0.1:<порт>, архивирование WAL).
     8. Роли, база, стоп-проверка локали lower('ЁЯ'), проверка архивирования WAL: apply-roles.ps1.
     9. Миграции: node dist\migrate.js --seed (роль pos_migrate).
    10. Службы OptomstroyApi, OptomstroyWorker, OptomstroyBackup: sc.exe create (виртуальные учётные записи
        NT SERVICE\<служба>, отложенный автозапуск, зависимость от OptomstroyPostgres, перезапуск при сбое),
        права NTFS по файлам секретов, права posdeploy на запуск/остановку/опрос OptomstroyApi и OptomstroyWorker
        (sc sdset, прежние права — в state).
    11. Запуск и проверка: /health и /health/ready на 127.0.0.1, API и PostgreSQL слушают только 127.0.0.1,
        фоновые задачи работают, служба резервного копирования запущена. Уже работающая служба перезапускается
        (штатно), если с её запуска изменились релиз, её файлы настроек или секреты (state\service-config.json) —
        например, при повторном запуске с -TestPhones; иначе не трогается.
    12. Apache: готовый файл виртуального хоста в config\apache (подключает администратор отдельно:
        enable-apache-site.ps1 — порты 80/443 и хосты 1С не меняются). -CertFile, -KeyFile, -ApacheListenPort
        запоминаются в install.json; существующий файл, отличающийся от нового, без этих параметров не
        перезаписывается (новый вариант — рядом, *.conf.new).
    13. Первый администратор системы (если заданы -AdminPhone и -AdminName).
  Журнал без секретов: <InstallRoot>\logs\install-<время>.log.

  -DevTest (ПК разработчика, без прав администратора): пропускаются только шаги, которым нужны права
  администратора (права NTFS, брандмауэр, sc.exe, права posdeploy) — в журнал пишется, что пропущено. PostgreSQL
  запускается pg_ctl, службы — OptomstroySvc.exe --console в фоне (скрытые консоли). -InstallRoot обязателен.
  -WhatIf: только проверки шага 1 и план; ничего не меняется.

.EXAMPLE
  # Администратор, PowerShell «от имени администратора», рабочий контур:
  .\install.ps1 -Zip C:\Users\admin\setup\Optomstroy-Server-0.1.0-abc-win-x64.zip -Sha256 <SHA256 из письма> `
      -PgBin 'C:\Program Files\PostgreSQL\17\bin' -PublicBaseUrl https://api.example.kg `
      -OnecBaseUrl https://1c.example.kg/ut11 -OnecHsPath hs/optomstroy-pos `
      -BackupPublicKey C:\Users\admin\setup\backup-public.pem -ApacheDir C:\Apache24 -ApacheServiceName Apache2.4
.EXAMPLE
  # Администратор, тестовый стенд optomstroy-test (ADR-125; профиль scripts\templates\stand.env.example):
  # APP_ENV=staging, 1С — фикстуры (адрес и секреты 1С не нужны), QR — песочница банка (QR_PROVIDER=bank,
  # BANK_QR_ADAPTER=sandbox), SMS не отправляются (SMS_PROVIDER=fake, вход — тестовые номера +99670000000x с
  # кодом AUTH_OTP_TEST_CODE из config\api.env), адрес по умолчанию https://api-test.37.114.51.144.sslip.io:
  .\install.ps1 -Stand -Zip C:\Users\admin\setup\Optomstroy-Server-0.1.0-abc-win-x64.zip -Sha256 <SHA256 из письма> `
      -PgBin 'C:\Program Files\PostgreSQL\17\bin' -BackupPublicKey C:\Users\admin\setup\backup-public.pem `
      -ApacheDir C:\Apache24 -ApacheServiceName Apache2.4 -AdminPhone +996700000001 -AdminName "Тестовый Администратор"
.EXAMPLE
  # Стенд: 1С вместо фикстур — HTTP-сервис ОС_API шлюза, только чтение (каталог, цены, остатки; ADR-126).
  # Сначала учётные данные шлюза в secrets (значения не выводятся): import-onec-credentials.ps1; затем повторный
  # запуск установки стенда с адресом публикации 1С (корень публикации, без hs/...). Режим запоминается в
  # install.json: следующий запуск без -StandOnecOsApi его не выключает; обратно на фикстуры — -StandOnecOsApi fixtures.
  .\import-onec-credentials.ps1
  .\install.ps1 -Stand -StandOnecOsApi http://localhost/uk_main_fr <остальные параметры установки стенда>
.EXAMPLE
  # «Живой» стенд (решение владельца 2026-11-25; только со стендом на ОС_API): настоящие SMS через SMSPro
  # (SMS_PROVIDER=smspro, secrets\smspro_login и smspro_password, отправитель — config\smspro-sender.txt; всё кладёт
  # import-onec-credentials.ps1 из SMSPRO_LOGIN/SMSPRO_PASSWORD/SMSPRO_SENDER шлюза), без тестовых номеров и кода
  # (AUTH_OTP_TEST_* очищаются), без песочницы QR (QR_PROVIDER=none), заказы — в 1С черновиками
  # (ONEC_OSAPI_WRITE_ORDERS=true). APP_ENV остаётся staging: настоящая SMS уходит только номерам -StandSmsPhones
  # (SMS_STAGING_ALLOWED_PHONES), остальным — <test>1</test>. Режим запоминается в install.json (standLive);
  # обратно — -StandLive:$false. -TestPhones с «живым» стендом — отказ.
  .\install.ps1 -Stand -StandLive -StandSmsPhones +996555000001,+996555000002 <остальные параметры установки стенда>
.EXAMPLE
  # Стенд с чистой базой (данные стенда удаляются!): службы стоп, зашифрованная копия (dump-only), DROP DATABASE,
  # фото и отметки аудита — в state\stand-reset-<время>, база заново (roles, migrate --seed: только строки по
  # умолчанию), службы запускаются. Затем первый администратор — scripts\first-admin.ps1. Только с -Stand.
  .\install.ps1 -Stand -ResetStandData -ConfirmResetDb optomstroy <остальные параметры установки стенда>
.EXAMPLE
  # ПК разработчика:
  .\install.ps1 -DevTest -Zip .tmp\wn-release\Optomstroy-Server-X-win-x64.zip -InstallRoot .tmp\wn-install\root `
      -BackupRoot .tmp\wn-install\backups -PgBin pos-api\node_modules\@embedded-postgres\windows-x64\native\bin -ApiPort 3330 -PgPort 55450
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Sha256 = '',
    [string]$Sha256Sums = '',
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$BackupRoot = 'D:\OptomstroyBackups',
    [string]$PgBin = 'C:\Program Files\PostgreSQL\17\bin',
    [ValidateSet('prod', 'test')][string]$Contour = 'prod',
    [string]$PublicBaseUrl = '',
    [string]$MinAppVersion = '',
    [string]$BackupPublicKey = '',
    [string]$OnecBaseUrl = '',
    [string]$OnecHsPath = '',
    [ValidateRange(1024, 65535)][int]$ApiPort = 3000,
    [ValidateRange(1024, 65535)][int]$PgPort = 5433,
    [ValidatePattern('^[a-z_][a-z0-9_]{0,62}$')][string]$DbName = 'optomstroy',
    [ValidatePattern('^\d+(MB|GB)$')][string]$SharedBuffers = '1GB',
    [string]$ApacheDir = '',
    [string]$ApacheServiceName = '',
    [string]$ApacheServiceAccount = '',
    [string]$PgServiceAccount = 'NT AUTHORITY\NetworkService',
    [switch]$AcceptSharedServiceAccount,
    [string]$CertFile = '',
    [string]$KeyFile = '',
    [ValidateRange(1, 65535)][int]$ApacheListenPort = 443,
    [string]$DeployUser = 'posdeploy',
    [string]$TestPhones = '',
    [string]$AdminPhone = '',
    [string]$AdminName = '',
    [ValidateRange(0, 30)][int]$AdminDays = 0,
    [switch]$SkipApacheCheck,
    [switch]$AllowSameVolume,
    [switch]$AllowForeignRoot,
    [switch]$AllowNewPeppers,
    [switch]$AllowOtherOs,
    [switch]$NonInteractive,
    [switch]$Stand,
    [string]$StandOnecOsApi = '',
    [switch]$StandLive,
    [string]$StandSmsPhones = '',
    [switch]$ResetStandData,
    [string]$ConfirmResetDb = '',
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OptomstroyCommon.ps1')

# Тестовый стенд (ADR-125): только контур test; профиль — scripts\templates\stand.env.example поверх test.env.example.
if ($Stand) {
    if ($PSBoundParameters.ContainsKey('Contour') -and $Contour -ne 'test') { throw '-Stand: тестовый стенд — только -Contour test (APP_ENV=staging, ADR-125)' }
    $Contour = 'test'
}
# 1С через ОС_API шлюза на стенде (ADR-126): только вместе с -Stand; рабочий контур — HTTP-сервис расширения (extension).
if ($StandOnecOsApi -and -not $Stand) { throw '-StandOnecOsApi: только вместе с -Stand (1С через ОС_API шлюза — режим тестового стенда, ADR-126; рабочий контур — -OnecBaseUrl/-OnecHsPath)' }
# «Живой» стенд (решение владельца 2026-11-25): настоящие SMS (SMSPro), без тестовых номеров и кода, без песочницы QR,
# заказы — в 1С черновиками. Только стенд с ОС_API; проверка режима 1С и секретов SMSPro — на шаге 1.
if ($PSBoundParameters.ContainsKey('StandLive') -and -not $Stand) { throw '-StandLive: только вместе с -Stand («живой» тестовый стенд; рабочий контур — без -Stand)' }
if ($StandLive -and $TestPhones) { throw '-StandLive и -TestPhones несовместимы: на «живом» стенде вход только по настоящей SMS, тестовых номеров и кода нет' }
if ($StandSmsPhones -and -not $Stand) { throw '-StandSmsPhones: только вместе с -Stand -StandLive' }
# Чистая база стенда (-ResetStandData): только стенд и только с явным подтверждением именем базы.
if ($ResetStandData -and -not $Stand) { throw '-ResetStandData: только вместе с -Stand (очистка базы — только на тестовом стенде; рабочий контур так не очищается никогда)' }
if ($ResetStandData -and $ConfirmResetDb -cne $DbName) { throw "-ResetStandData: все данные базы стенда будут удалены — подтвердите именем базы: -ConfirmResetDb $DbName" }
if ($ConfirmResetDb -and -not $ResetStandData) { throw '-ConfirmResetDb: только вместе с -ResetStandData' }

if ($DevTest -and -not $PSBoundParameters.ContainsKey('InstallRoot')) { throw '-DevTest: укажите -InstallRoot (тестовая папка), путь по умолчанию D:\Optomstroy в проверочном прогоне не используется' }
if ($DevTest -and -not $PSBoundParameters.ContainsKey('Contour')) { $Contour = 'test' }
if ($DevTest -and -not $PSBoundParameters.ContainsKey('BackupRoot')) { $BackupRoot = Join-Path $InstallRoot '..\backups' }
foreach ($pn in @('Zip', 'Sha256Sums', 'InstallRoot', 'BackupRoot', 'PgBin', 'BackupPublicKey', 'ApacheDir', 'CertFile', 'KeyFile')) {
    $pv = Get-Variable -Name $pn -ValueOnly
    if ($pv) { Set-Variable -Name $pn -Value (Resolve-OpsPath $pv) }
}
$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false   # -WhatIf: только проверки шага 1; служебные команды (журнал) выполняются по-настоящему
$L = Get-OpsLayout $InstallRoot $BackupRoot
$PgBin = $PgBin.TrimEnd('\')
$appEnv = 'prod'
if ($Contour -eq 'test') { $appEnv = 'staging' }
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$timings = [ordered]@{}
$summary = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
$stepNo = 0
$curStep = ''
$swStep = $null
function Start-Step([string]$Title) {
    if ($null -ne $script:swStep) { $script:timings[$script:curStep] = [math]::Round($script:swStep.Elapsed.TotalSeconds, 1) }
    $script:stepNo++
    $script:curStep = "$($script:stepNo). $Title"
    $script:swStep = [Diagnostics.Stopwatch]::StartNew()
    Write-OpsLog "$($script:stepNo)/13 $Title" 'STEP'
}
function Skip-Admin([string]$What) {
    [void]$script:skipped.Add($What)
    Write-OpsLog "DevTest: пропущено (нужны права администратора): $What" 'WARN'
}
function Invoke-Icacls([string[]]$IcaclsArgs) {
    $o = & icacls.exe @IcaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("icacls " + ($IcaclsArgs -join ' ') + ": код $LASTEXITCODE`n" + ($o | Out-String)) }
}
function Resolve-Sid([string]$Account) {
    return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
}

$logDir = $L.Logs
if ($whatIf) { $logDir = Join-Path $env:TEMP 'optomstroy-install-whatif' }
$null = Initialize-OpsLog $logDir 'install'
Write-OpsLog ("install.ps1: InstallRoot={0} BackupRoot={1} контур={2} (APP_ENV={3}) API 127.0.0.1:{4} PostgreSQL 127.0.0.1:{5} база {6}{7}{8}" -f $L.Root, $L.BackupRoot, $Contour, $appEnv, $ApiPort, $PgPort, $DbName, $(if ($Stand) { ' стенд (ADR-125)' } else { '' }), $(if ($DevTest) { ' DevTest' } else { '' }))

$state = ConvertTo-OpsHashtable (Read-OpsState $L)
$failed = $true
try {
    # =========================================================================================================
    Start-Step 'Проверки до установки (только чтение)'
    $os = Get-CimInstance Win32_OperatingSystem
    Write-OpsLog "ОС: $($os.Caption) $($os.Version); память $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) ГБ, свободно $([math]::Round($os.FreePhysicalMemory / 1MB, 1)) ГБ"
    if ($os.Caption -notmatch 'Windows Server 2022') {
        if ($DevTest -or $AllowOtherOs) { Write-OpsLog "ОС не Windows Server 2022 ($($os.Caption)) — допускается только для проверки" 'WARN' }
        else { throw "нужна Windows Server 2022, а здесь $($os.Caption) (для проверки: -AllowOtherOs)" }
    }
    if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') { throw "запускайте в Windows PowerShell 5.1 (powershell.exe), а не в PowerShell $($PSVersionTable.PSVersion)" }
    Write-OpsLog "Windows PowerShell $($PSVersionTable.PSVersion)" 'OK'
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $logical = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    Write-OpsLog "процессор: $($cpu.Name.Trim()); логических процессоров: $logical"
    if (-not (Test-OpsAdmin)) {
        if ($DevTest) { Write-OpsLog 'нет прав администратора — DevTest: шаги администратора пропускаются' 'WARN' }
        else { throw 'нужен PowerShell «от имени администратора»' }
    } elseif (-not $DevTest) { Write-OpsLog 'права администратора есть' 'OK' }

    $minFreeGb = 20
    if ($DevTest) { $minFreeGb = 2 }
    $rootQual = [System.IO.Path]::GetPathRoot($L.Root)
    $bkQual = [System.IO.Path]::GetPathRoot($L.BackupRoot)
    foreach ($q in @($rootQual, $bkQual) | Sort-Object -Unique) {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $q.TrimEnd('\'))
        if ($null -eq $disk) { throw "нет тома $q" }
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
        $usedPct = [math]::Round(100 * (1 - $disk.FreeSpace / $disk.Size))
        Write-OpsLog "том $q`: свободно $freeGb ГБ из $([math]::Round($disk.Size / 1GB, 1)) ГБ (занято $usedPct %)"
        if ($freeGb -lt $minFreeGb) { throw "на томе $q меньше $minFreeGb ГБ свободного места" }
        if ($usedPct -gt 70) { Write-OpsLog "том $q занят больше чем на 70 % (правило комплекта 16 §5)" 'WARN' }
    }
    if ($rootQual -eq $bkQual) {
        if ($DevTest -or $AllowSameVolume) { Write-OpsLog "резервные копии на том же томе $rootQual, что и данные" 'WARN' }
        else { throw "BackupRoot ($($L.BackupRoot)) на том же томе, что и InstallRoot: нужен отдельный том (или -AllowSameVolume после согласования)" }
    }

    # Шаг 2 снимает с InstallRoot и BackupRoot все прежние права NTFS (вместе с содержимым): только отдельные папки.
    foreach ($rp in @(@($L.Root, 'install', 'InstallRoot'), @($L.BackupRoot, 'backup', 'BackupRoot'))) {
        $why = Test-OpsDedicatedRoot $rp[0] $rp[1]
        if ($null -eq $why) { Write-OpsLog "-$($rp[2]) $($rp[0]): новая, пустая или папка Optomstroy" 'OK'; continue }
        $isVolumeRoot = ([System.IO.Path]::GetPathRoot($rp[0]).TrimEnd('\') -eq $rp[0].TrimEnd('\'))
        if ($AllowForeignRoot -and -not $isVolumeRoot) { Write-OpsLog "-$($rp[2]): $why — продолжаю по -AllowForeignRoot" 'WARN' }
        else { throw "-$($rp[2]): $why" }
    }

    $installJson = Read-OpsJson $L.InstallJson
    $ours = $false
    if ($null -ne $installJson) {
        foreach ($p in @(@('apiPort', $ApiPort), @('pgPort', $PgPort), @('dbName', $DbName), @('contour', $Contour))) {
            if ([string]$installJson.($p[0]) -ne [string]$p[1]) { throw "в $($L.InstallJson) $($p[0]) = $($installJson.($p[0])), а задано $($p[1]): смена после установки — только вручную" }
        }
        $prevStand = ($null -ne $installJson.PSObject.Properties['stand']) -and [bool]$installJson.stand
        if ($prevStand -ne [bool]$Stand) { throw "в $($L.InstallJson) stand = $prevStand, а задано -Stand:$([bool]$Stand): смена профиля стенда после установки — только вручную" }
        $ours = $true
        Write-OpsLog "повторный запуск: $($L.InstallJson) найден, параметры совпадают"
    }
    foreach ($port in @($ApiPort, $PgPort)) {
        $addr = @(Get-OpsListenAddresses $port)
        if ($addr.Count -gt 0) {
            if ($ours) { Write-OpsLog "порт $port уже слушает ($($addr -join ', ')) — повторный запуск, ожидается наша служба" 'WARN' }
            else { throw "порт $port занят ($($addr -join ', ')): Get-NetTCPConnection -State Listen -LocalPort $port" }
        } else { Write-OpsLog "порт $port свободен" 'OK' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $PgBin 'postgres.exe'))) { throw "в -PgBin нет postgres.exe: $PgBin" }
    $pgv = (& (Join-Path $PgBin 'postgres.exe') --version | Out-String).Trim()
    Write-OpsLog "PostgreSQL: $pgv ($PgBin)"
    if ($pgv -notmatch ' 17\.') { throw 'нужен PostgreSQL 17 (комплект проверен на 17.10)' }
    if (-not (Test-Path -LiteralPath (Join-Path $PgBin 'pg_dump.exe'))) {
        if ($DevTest) { Write-OpsLog "в $PgBin нет pg_dump.exe — DevTest: резервное копирование работать не будет" 'WARN' }
        else { throw "в $PgBin нет pg_dump.exe (нужна полная сборка PostgreSQL 17 для Windows)" }
    }

    # Apache (только чтение): httpd -v и -S действующей конфигурации.
    if ($ApacheDir) {
        $httpd = Join-Path $ApacheDir 'bin\httpd.exe'
        if (-not (Test-Path -LiteralPath $httpd)) { throw "нет $httpd" }
        $hArgs = @('-d', ($ApacheDir -replace '\\', '/'), '-f', ((Join-Path $ApacheDir 'conf\httpd.conf') -replace '\\', '/'))
        if ($ApacheServiceName) { $hArgs = @('-n', $ApacheServiceName) }
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $hv = (& $httpd @hArgs -v 2>&1 | Out-String).Trim()
        $hs = & $httpd @hArgs -S 2>&1 | ForEach-Object { [string]$_ }
        $hsCode = $LASTEXITCODE
        $ErrorActionPreference = $eap
        Write-OpsLog "Apache: $(($hv -split "`n")[0])"
        foreach ($hl in $hs) { Write-OpsLog "  httpd -S | $hl" }
        if ($hsCode -ne 0) {
            if ($DevTest -or $SkipApacheCheck) { Write-OpsLog "httpd -S завершился с кодом $hsCode" 'WARN' }
            else { throw "httpd -S завершился с кодом $hsCode — конфигурация Apache не читается (стоп-условие плана, раздел 8 шаг 0)" }
        } else { Write-OpsLog 'httpd -S прочитан; условие для 1С (именованный VirtualHost по умолчанию для *:443) проверяет enable-apache-site.ps1' 'OK' }
    } elseif ($DevTest -or $SkipApacheCheck) {
        Write-OpsLog 'Apache не указан (-ApacheDir) — проверка httpd -S пропущена' 'WARN'
    } else { throw 'укажите -ApacheDir (и -ApacheServiceName): нужна проверка httpd -S (или -SkipApacheCheck)' }

    # SQL Server: max server memory (только чтение).
    $sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($null -ne $sqlcmd) {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $mem = & $sqlcmd.Source -S localhost -E -l 5 -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = N'max server memory (MB)'" 2>&1 | Out-String
        $ErrorActionPreference = $eap
        $mem = $mem.Trim()
        if ($mem -match '^\d+$') {
            if ([int64]$mem -ge 2147483647) { Write-OpsLog "SQL Server: max server memory не ограничен ($mem МБ) — SQL Server может занять всю память; ограничение — решение вашего администратора (план, раздел 3)" 'WARN' }
            else { Write-OpsLog "SQL Server: max server memory = $mem МБ" 'OK' }
        } else { Write-OpsLog "SQL Server: max server memory не прочитан ($mem)" 'WARN' }
    } else { Write-OpsLog 'sqlcmd.exe не найден — память SQL Server проверьте вручную (план, раздел 3)' 'WARN' }

    if (-not $PublicBaseUrl -and $Stand -and -not ($null -ne $installJson -and $installJson.publicBaseUrl)) {
        # Адрес стенда по умолчанию — PUBLIC_BASE_URL профиля (в пакете — рядом со скриптом; в репозитории — infra\env);
        # при повторном запуске — адрес из install.json (ниже).
        foreach ($sp in @((Join-Path $PSScriptRoot 'templates\stand.env.example'), (Join-Path $PSScriptRoot '..\..\env\stand.env.example'))) {
            if (-not $PublicBaseUrl -and (Test-Path -LiteralPath $sp)) { $PublicBaseUrl = [string](Read-OpsEnvTemplate $sp)['PUBLIC_BASE_URL'] }
        }
        if ($PublicBaseUrl) { Write-OpsLog "стенд: адрес из профиля stand.env.example — $PublicBaseUrl" }
    }
    if (-not $PublicBaseUrl) {
        if ($DevTest) { $PublicBaseUrl = 'https://api-test.devtest.invalid' }
        elseif ($null -ne $installJson) { $PublicBaseUrl = [string]$installJson.publicBaseUrl }
        else { throw 'укажите -PublicBaseUrl https://api.<домен> (PUBLIC_BASE_URL обязательна при APP_ENV=prod/staging)' }
    }
    if ($PublicBaseUrl -notmatch '^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]/?$') { throw "-PublicBaseUrl: https://<имя>, строчными буквами: $PublicBaseUrl" }
    $PublicBaseUrl = $PublicBaseUrl.TrimEnd('/')
    $serverName = ([Uri]$PublicBaseUrl).Host
    # 1С (обмен онлайн через HTTP-сервис расширения «OptomstroyPOS», ONEC_MODE=extension): без адреса, пути и
    # секретов onec_hs_* API не запускается (onec-adapters.ts → ConfigError при старте).
    # Тестовый стенд (-Stand, ADR-125): 1С — фикстуры (ONEC_MODE=fixtures из stand.env.example), адрес и секреты 1С
    # не задаются; рабочая 1С к стенду не подключается никогда.
    # Стенд с -StandOnecOsApi (ADR-126): 1С — HTTP-сервис ОС_API шлюза, только чтение (ONEC_MODE=os_api, ONEC_BASE_URL =
    # корень публикации, ONEC_OSAPI_PATH=hs/os/api/v1), вход — secrets\onec_user и onec_password (кладёт
    # import-onec-credentials.ps1 или администратор; здесь не спрашиваются). Адрес запоминается в install.json
    # (onecOsApiBaseUrl): повторный запуск без параметра режим не откатывает; -StandOnecOsApi fixtures — обратно.
    $osApiUrl = ''
    $osApiOff = $false
    if ($Stand) {
        if ($OnecBaseUrl -or $OnecHsPath) { throw '-Stand: 1С на стенде — фикстуры или ОС_API шлюза (-StandOnecOsApi, ADR-126); -OnecBaseUrl и -OnecHsPath не задаются' }
        if ($StandOnecOsApi -eq 'fixtures') { $osApiOff = $true }
        elseif ($StandOnecOsApi) { $osApiUrl = ConvertTo-OpsOsApiBaseUrl $StandOnecOsApi }
        elseif ($null -ne $installJson -and $installJson.PSObject.Properties['onecOsApiBaseUrl'] -and $installJson.onecOsApiBaseUrl) {
            $osApiUrl = ConvertTo-OpsOsApiBaseUrl ([string]$installJson.onecOsApiBaseUrl)
            Write-OpsLog "1С: режим ОС_API из install.json (прошлый запуск с -StandOnecOsApi)"
        }
        if ($osApiUrl) {
            Write-OpsLog "1С: ОС_API шлюза, только чтение — $osApiUrl/$($script:OpsOsApiDefaultPath) (ONEC_MODE=os_api, тестовый стенд ADR-126)"
            if (-not $DevTest) {
                foreach ($s in $script:OpsOnecCredentialFiles) {
                    $f = Join-Path $L.Secrets $s
                    if (-not ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0)) {
                        throw "-StandOnecOsApi: нет secrets\$s — сначала import-onec-credentials.ps1 (переносит ONEC_API_USER/ONEC_API_PASSWORD шлюза, значения не выводит) или положите файлы secrets\onec_user и secrets\onec_password сами (WINDOWS_SERVER_INSTALL.md, раздел 8а)"
                    }
                }
            }
        } else {
            Write-OpsLog '1С: фикстуры (ONEC_MODE=fixtures, тестовый стенд ADR-125) — адрес и секреты 1С не нужны'
        }
    }
    # «Живой» стенд: заданный явно (-StandLive / -StandLive:$false) > запомненный в install.json (standLive).
    $liveMode = $false
    $liveModeOff = $false
    $standSender = ''
    $wasLive = $Stand -and $null -ne $installJson -and $installJson.PSObject.Properties['standLive'] -and [bool]$installJson.standLive
    # Номера тестового входа до перехода на «живой» стенд (install.json standTestPhonesBeforeLive): при -StandLive:$false
    # возвращаются они, а не номера профиля пакета.
    $phonesBeforeLive = ''
    if ($wasLive -and $installJson.PSObject.Properties['standTestPhonesBeforeLive'] -and $installJson.standTestPhonesBeforeLive) {
        $phonesBeforeLive = [string]$installJson.standTestPhonesBeforeLive
    }
    if ($PSBoundParameters.ContainsKey('StandLive')) {
        $liveMode = [bool]$StandLive
        # -StandLive:$false переписывает профиль, только если стенд был «живым»; иначе свои значения (-TestPhones
        # прошлых запусков) не трогаются.
        $liveModeOff = (-not $liveMode) -and $wasLive
        if ((-not $liveMode) -and $Stand -and -not $wasLive) {
            Write-OpsLog 'стенд: -StandLive:$false — стенд и так не «живой» (standLive в install.json не задан): профиль в config\*.env не переписывается'
        }
    } elseif ($Stand -and $null -ne $installJson -and $installJson.PSObject.Properties['standLive'] -and [bool]$installJson.standLive) {
        $liveMode = $true
        Write-OpsLog 'стенд: «живой» режим из install.json (прошлый запуск с -StandLive; выключить — -StandLive:$false)'
    }
    if ($StandSmsPhones -and -not $liveMode) { throw '-StandSmsPhones: только для «живого» стенда (-StandLive): со SMS_PROVIDER=fake список не действует' }
    if ($StandSmsPhones) { $StandSmsPhones = ConvertTo-OpsPhoneList $StandSmsPhones '-StandSmsPhones' }
    if ($liveMode) {
        if ($TestPhones) { throw '-TestPhones: стенд «живой» (standLive в install.json) — тестовых номеров нет; обратно на тестовый вход — -StandLive:$false' }
        if (-not $osApiUrl) { throw '-StandLive: только со стендом на ОС_API (-StandOnecOsApi <адрес публикации 1С> или режим ОС_API из install.json) — заказы пишутся в 1С черновиками через ОС_API; на фикстурах «живого» стенда нет' }
        foreach ($s in $script:OpsSmsProCredentialFiles) {
            $f = Join-Path $L.Secrets $s
            if (-not ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0)) {
                throw "-StandLive: нет secrets\$s — сначала import-onec-credentials.ps1 (переносит SMSPRO_LOGIN/SMSPRO_PASSWORD/SMSPRO_SENDER шлюза, значения не выводит) или положите secrets\smspro_login и secrets\smspro_password сами"
            }
        }
        $senderFile = Join-Path $L.Config $script:OpsSmsProSenderFile
        if (Test-Path -LiteralPath $senderFile) { $standSender = ([System.IO.File]::ReadAllText($senderFile, [System.Text.Encoding]::UTF8)).Trim([char]0xFEFF, ' ', "`r", "`n", "`t") }
        if (-not $standSender) { throw "-StandLive: нет имени отправителя SMS (config\$($script:OpsSmsProSenderFile)) — сначала import-onec-credentials.ps1 (берёт SMSPRO_SENDER шлюза)" }
        if ($standSender -match '[\s#"''=]') { throw "-StandLive: имя отправителя в config\$($script:OpsSmsProSenderFile) — без пробелов, кавычек, # и =" }
        Write-OpsLog "стенд «живой»: SMS — SMSPro (отправитель $standSender), без тестовых номеров и кода; QR — нет (QR_PROVIDER=none); заказы — в 1С черновиками (ONEC_OSAPI_WRITE_ORDERS=true); APP_ENV=staging" 'WARN'
        if (-not $wasLive) {
            # Переход на «живой» стенд: запомнить номера тестового входа (api.env), чтобы -StandLive:$false их вернул.
            $apiEnvPrev = Join-Path $L.Config 'api.env'
            if (Test-Path -LiteralPath $apiEnvPrev) { $ae = Read-OpsEnvTemplate $apiEnvPrev; if ($ae.Contains('AUTH_OTP_TEST_PHONES')) { $phonesBeforeLive = [string]$ae['AUTH_OTP_TEST_PHONES'] } }
            if ($null -ne $installJson -and -not $ResetStandData) {
                # Хвост заказов: order/create, ждавшие отправки дольше OUTBOX_MAX_AGE_HOURS, сами в 1С не уйдут.
                Write-OpsLog 'стенд «живой» без -ResetStandData: заказы, накопленные до включения записи в 1С и ждущие дольше OUTBOX_MAX_AGE_HOURS (24 ч), в 1С сами не уйдут — они паркуются «ждёт оформления в 1С»; отправить — «Повторить» в очереди «в 1С», не нужны — отмените заказ (или установите с -ResetStandData -ConfirmResetDb)' 'WARN'
            }
        }
    } elseif ($liveModeOff -and $Stand) {
        Write-OpsLog 'стенд: -StandLive:$false — обратно на профиль стенда (SMS fake, тестовые номера, песочница QR, без записи заказов в 1С)'
    }
    if ($ResetStandData) {
        if ($null -eq $installJson) { throw '-ResetStandData: установки ещё нет (нет config\install.json) — очищать нечего; первая установка и так создаёт пустую базу' }
        Write-OpsLog "ВНИМАНИЕ: -ResetStandData — база $DbName стенда будет удалена и создана заново (перед этим — зашифрованная копия pos-backup dump-only); фото и отметки аудита — в state\stand-reset-<время>" 'WARN'
    }
    if (-not $Stand) {
    if (-not $OnecBaseUrl -and $null -ne $installJson -and $installJson.PSObject.Properties['onecBaseUrl']) { $OnecBaseUrl = [string]$installJson.onecBaseUrl }
    if (-not $OnecHsPath -and $null -ne $installJson -and $installJson.PSObject.Properties['onecHsPath']) { $OnecHsPath = [string]$installJson.onecHsPath }
    if ($DevTest) {
        # Проверочный прогон: адрес 1С на 127.0.0.1 без слушателя — API стартует, вызовы 1С получают отказ соединения.
        if (-not $OnecBaseUrl) { $OnecBaseUrl = 'https://127.0.0.1:9/devtest-1c' }
        if (-not $OnecHsPath) { $OnecHsPath = 'hs/optomstroy-pos' }
    }
    if (-not $OnecBaseUrl) { throw 'укажите -OnecBaseUrl https://<адрес публикации 1С>/<база> (обмен с 1С онлайн, ONEC_MODE=extension; для тестовой копии — только тестовая копия базы 1С)' }
    if (-not $OnecHsPath) { throw 'укажите -OnecHsPath hs/<имя HTTP-сервиса расширения> (05_ONEC_INTEGRATION, 18_ONEC_API_REQUEST)' }
    if ($OnecBaseUrl -notmatch '^https://[^\s/?#]+(/[^\s?#]*)?$') { throw "-OnecBaseUrl: только https:// (05 ONEC-081): $OnecBaseUrl" }
    $OnecBaseUrl = $OnecBaseUrl.TrimEnd('/')
    if ($OnecHsPath -notmatch '^[A-Za-z0-9._~/-]+$') { throw "-OnecHsPath: путь без пробелов и параметров, например hs/optomstroy-pos: $OnecHsPath" }
    $OnecHsPath = $OnecHsPath.Trim('/')
    Write-OpsLog "1С: $OnecBaseUrl/$OnecHsPath (ONEC_MODE=extension, обмен онлайн)"
    }
    if ($BackupPublicKey -and -not (Test-Path -LiteralPath $BackupPublicKey)) { throw "нет файла -BackupPublicKey $BackupPublicKey" }
    if (-not $BackupPublicKey -and -not (Test-Path -LiteralPath (Join-Path $L.Config 'backup-public.pem')) -and -not $DevTest) {
        throw 'укажите -BackupPublicKey <backup-public.pem> (открытый ключ держателя ключа, keygen.ps1 на его ПК)'
    }

    if ($whatIf) {
        Write-OpsLog '-WhatIf: проверки пройдены; дальше выполнились бы шаги 2–13 (см. справку). Ничего не изменено.' 'OK'
        $failed = $false
        return
    }

    # =========================================================================================================
    Start-Step 'Папки и права NTFS'
    $dirs = @($L.Root, $L.Releases, $L.Config, (Join-Path $L.Config 'apache'), $L.Secrets, $L.Data, (Join-Path $L.Media 'images'), $L.AuditAnchors,
        $L.WalSpool, $L.Logs, (Join-Path $L.Logs 'api'), (Join-Path $L.Logs 'worker'), (Join-Path $L.Logs 'backup'), $L.State, $L.Incoming, $L.BackupRoot)
    foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    Set-OpsRootMarker $L.Root 'install'
    Set-OpsRootMarker $L.BackupRoot 'backup'
    Write-OpsLog "папки созданы в $($L.Root) и $($L.BackupRoot) (отметка $script:OpsRootMarker)" 'OK'
    if ($DevTest) {
        Skip-Admin "icacls $($L.Root) /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F; posdeploy: RX корня (только папка), RX releases, M incoming, RX logs"
    } else {
        foreach ($p in @($L.Root, $L.BackupRoot)) {
            Invoke-Icacls @($p, '/inheritance:r', '/grant:r', "*$($script:OpsSidAdministrators):(OI)(CI)F", "*$($script:OpsSidSystem):(OI)(CI)F")
        }
        Write-OpsLog "$($L.Root), $($L.BackupRoot): наследование отключено; полный доступ — Administrators, SYSTEM" 'OK'
        $deploySid = $null
        if ($DeployUser) { try { $deploySid = Resolve-Sid $DeployUser } catch { Write-OpsLog "учётной записи $DeployUser нет — права posdeploy не выданы (выдать позже: повторный запуск install.ps1)" 'WARN' } }
        if ($deploySid) {
            Invoke-Icacls @($L.Root, '/grant', "*${deploySid}:(RX)")
            # releases — чтение: scripts\status.ps1 запускается из current\scripts (в релизах секретов нет, пакет
            # posdeploy и так загружает сам).
            Invoke-Icacls @($L.Releases, '/grant', "*${deploySid}:(OI)(CI)RX")
            Invoke-Icacls @($L.Incoming, '/grant', "*${deploySid}:(OI)(CI)M")
            Invoke-Icacls @($L.Logs, '/grant', "*${deploySid}:(OI)(CI)RX")
            Write-OpsLog "$DeployUser`: чтение корня (только папка) и releases, запись в incoming, чтение logs; к config, secrets, data, state доступа нет" 'OK'
        }
    }

    # =========================================================================================================
    Start-Step 'Брандмауэр: блокировка входящих на порты API и PostgreSQL'
    if ($DevTest) {
        Skip-Admin "New-NetFirewallRule -Direction Inbound -Protocol TCP -LocalPort $ApiPort / $PgPort -Action Block"
    } else {
        foreach ($fw in @(@($ApiPort, 'API'), @($PgPort, 'PostgreSQL'))) {
            $name = "Optomstroy-Block-In-TCP-$($fw[0])"
            if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Write-OpsLog "правило $name уже есть"; continue }
            New-NetFirewallRule -Name $name -DisplayName "Optomstroy: block inbound TCP $($fw[0]) ($($fw[1]), 127.0.0.1 only)" `
                -Direction Inbound -Protocol TCP -LocalPort $fw[0] -Action Block -Profile Any -RemoteAddress Any | Out-Null
            Write-OpsLog "правило $name создано" 'OK'
        }
    }

    # =========================================================================================================
    Start-Step 'Пакет релиза'
    $rel = Install-OpsReleaseZip -L $L -Zip $Zip -Sha256 $Sha256 -SumsFile $Sha256Sums
    $info = Get-OpsReleaseInfo $rel.Dir
    $cur = Get-OpsJunctionTarget $L.Current
    if ($null -eq $cur) {
        Set-OpsJunction $L.Current $rel.Dir
    } elseif ($cur -ne [System.IO.Path]::GetFullPath($rel.Dir)) {
        throw "current указывает на $cur, а пакет — $($rel.Version): установленную программу обновляет update.ps1"
    } else { Write-OpsLog "current уже указывает на $($rel.Version)" }
    Write-OpsLog ("релиз {0}: node {1}, OptomstroySvc {2}, миграций {3}" -f $info.version, $info.node.version, $info.svchost.version, $info.posApi.migrations)

    # =========================================================================================================
    Start-Step 'Секреты (значения не выводятся)'
    $jwtKid = ''
    if ($null -ne $installJson) { $jwtKid = [string]$installJson.jwtKeyId }
    if (-not $jwtKid) { $jwtKid = '{0}-{1}' -f $Contour, (Get-Date -Format 'yyyyMMdd') }
    $clusterExists = Test-Path -LiteralPath (Join-Path $L.PgData 'PG_VERSION')
    $gArgs = @('gen-secrets', '--dir', $L.Secrets, '--kid', $jwtKid, '--db', $DbName, '--port', [string]$PgPort)
    if ($clusterExists) { $gArgs += '--cluster-exists' }
    # Восстановление на новом сервере: в BackupRoot уже есть копии базы — значит, хэши PIN сотрудников и аварийных
    # кодов планшетов посчитаны со СТАРЫМИ pin_pepper/otp_pepper. Новые перцы сделали бы их непроверяемыми после
    # восстановления, поэтому без -AllowNewPeppers они не создаются: сначала secrets из защищённой копии (README, «Секреты»).
    $oldBackups = @()
    foreach ($bd in @((Join-Path $L.BackupRoot 'dumps'), (Join-Path $L.BackupRoot 'pitr'))) {
        if (Test-Path -LiteralPath $bd) { $oldBackups += @(Get-ChildItem -LiteralPath $bd -Recurse -File -Filter '*.optbk' -ErrorAction SilentlyContinue | Select-Object -First 1) }
    }
    if ($oldBackups.Count -gt 0 -and -not $AllowNewPeppers) { $gArgs += '--no-new-peppers' }
    $g = Invoke-OpsTool $L $rel.Dir $gArgs
    if ($g.Code -eq 3 -and $oldBackups.Count -gt 0) { throw "в $($L.BackupRoot) уже есть резервные копии ($($oldBackups[0].FullName)), а в secrets нет pin_pepper/otp_pepper или паролей базы — восстановите secrets из защищённой копии (README, «Секреты»: secrets-import). Новые перцы — только осознанно: -AllowNewPeppers (PIN сотрудников и аварийные коды планшетов из копий перестанут проверяться)" }
    if ($g.Code -eq 3) { throw 'кластер PostgreSQL уже создан, а секретов нет — восстановите их из защищённой копии (новые не создаются)' }
    if ($g.Code -ne 0) { throw "gen-secrets: код $($g.Code)" }
    $created = @($g.Json.created)
    if ($created.Count -gt 0) { Write-OpsLog ("созданы: " + ($created -join ', ')) 'OK' } else { Write-OpsLog 'все секреты уже есть' }
    # Вводит человек заказчика: SMSPro (рабочий контур) и учётные данные HTTP-сервиса 1С (pos_hs и ключ
    # X-POS-Client-Key; пароль pos_hs — если задан в 1С). Ввод скрыт; значения в журнал не попадают.
    $askSecrets = New-Object System.Collections.ArrayList   # check-secrets: allow — список имён, не значение
    if ($appEnv -eq 'prod') {
        [void]$askSecrets.Add(@('smspro_login', 'Логин SMSPro', $true))
        [void]$askSecrets.Add(@('smspro_password', 'Пароль SMSPro', $true))
    }
    # Тестовый стенд (-Stand): ни SMSPro (SMS не отправляются, ADR-124), ни 1С (фикстуры) — ничего не вводится.
    if (-not $Stand) {
        [void]$askSecrets.Add(@('onec_hs_user', 'Пользователь 1С для HTTP-сервиса (pos_hs)', $true))
        [void]$askSecrets.Add(@('onec_hs_token', 'Ключ клиента X-POS-Client-Key HTTP-сервиса 1С', $true))
        [void]$askSecrets.Add(@('onec_hs_password', 'Пароль pos_hs в 1С (Enter — без пароля)', $false))
    }
    if ($DevTest -and -not $Stand) {
        # Проверочный прогон: тестовые значения 1С создаются здесь (в тестовой папке), а не вводятся.
        foreach ($s in @('onec_hs_user', 'onec_hs_token')) {
            $f = Join-Path $L.Secrets $s
            if (-not (Test-Path -LiteralPath $f)) {
                $v = 'devtest-' + [Guid]::NewGuid().ToString('N')
                if ($s -eq 'onec_hs_user') { $v = 'pos_hs_devtest' }
                [System.IO.File]::WriteAllText($f, $v, (New-Object System.Text.UTF8Encoding($false)))
                Write-OpsLog "DevTest: тестовый секрет secrets\$s создан" 'WARN'
            }
        }
        $askSecrets.Clear()
    }
    if ($DevTest -and $osApiUrl) {
        # Проверочный прогон стенда с ОС_API: тестовые onec_user/onec_password (в тестовой папке; 1С не вызывается).
        foreach ($s in $script:OpsOnecCredentialFiles) {
            $f = Join-Path $L.Secrets $s
            if (-not (Test-Path -LiteralPath $f)) {
                $v = 'devtest-' + [Guid]::NewGuid().ToString('N')
                if ($s -eq 'onec_user') { $v = 'api_devtest' }
                [System.IO.File]::WriteAllText($f, $v, (New-Object System.Text.UTF8Encoding($false)))
                Write-OpsLog "DevTest: тестовый секрет secrets\$s создан" 'WARN'
            }
        }
    }
    if ($osApiUrl) {
        # Вход в ОС_API — Basic пользователя шлюза; файлы кладёт import-onec-credentials.ps1 (проверено на шаге 1).
        foreach ($s in $script:OpsOnecCredentialFiles) {
            $f = Join-Path $L.Secrets $s
            if (-not ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0)) { throw "нет secrets\$s — без него режим ОС_API не запускается (import-onec-credentials.ps1)" }
        }
        Write-OpsLog 'секреты 1С для ОС_API: secrets\onec_user, secrets\onec_password есть (значения не выводятся)' 'OK'
    }
    $onecPwdAsked = Join-Path $L.State 'onec_hs_password.asked'   # check-secrets: allow — путь к файлу-отметке, не значение
    foreach ($item in $askSecrets) {
        $s = $item[0]
        $f = Join-Path $L.Secrets $s
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0) { continue }
        if (-not $item[2] -and (Test-Path -LiteralPath $onecPwdAsked)) { continue }
        if ($NonInteractive) {
            if (-not $item[2]) { continue }
            throw "нет secrets\$s — его создаёт человек заказчика (README, «Секреты») или вводит при запуске без -NonInteractive"
        }
        $prompt = "$($item[1]) — вводит человек заказчика (ввод скрыт)"
        $sec = Read-Host -AsSecureString $prompt
        if (-not $item[2]) {
            [System.IO.File]::WriteAllText($onecPwdAsked, (Get-Date).ToString('s'))
            if ($sec.Length -eq 0) { Write-OpsLog "secrets\$s не задан (без пароля)"; continue }
        }
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            $v = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
            if (-not $v) { throw "пустое значение $s" }
            if ($v -match '[\r\n]') { throw "значение $s содержит перевод строки" }
            [System.IO.File]::WriteAllText($f, $v, (New-Object System.Text.UTF8Encoding($false)))
            $v = $null
        } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
        Write-OpsLog "секрет записан: secrets\$s" 'OK'
    }
    foreach ($s in @('onec_hs_user', 'onec_hs_token')) {
        if ($Stand) { break }   # стенд: 1С — фикстуры
        $f = Join-Path $L.Secrets $s
        if (-not ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0)) { throw "нет secrets\$s — без него API не запускается (обмен с 1С онлайн, ONEC_MODE=extension)" }
    }
    $chk = Invoke-OpsTool $L $rel.Dir @('check-secrets', '--dir', $L.Secrets, '--db', $DbName, '--port', [string]$PgPort)
    if ($chk.Code -ne 0) { throw 'секреты не согласованы (подробности выше)' }
    Write-OpsLog 'секреты согласованы (database_url, pgpass_backup.conf, jwt_public.json)' 'OK'

    # =========================================================================================================
    Start-Step 'Файлы настроек'
    # Шаблоны релиза без имён уровня compose/резервного копирования Linux (программа их не читает).
    $tpl = Get-OpsEnvTemplatePairs $rel.Dir $Contour -Stand:$Stand
    if (-not $MinAppVersion) {
        if ($null -ne $installJson -and $installJson.minAppVersion) { $MinAppVersion = [string]$installJson.minAppVersion }
        elseif ($info.PSObject.Properties['posApp'] -and $info.posApp.version) { $MinAppVersion = "android=$($info.posApp.version),windows=$($info.posApp.version)" }
        else { throw 'укажите -MinAppVersion android=X.Y.Z,windows=X.Y.Z' }
    }
    $tpl['APP_ENV'] = $appEnv
    $tpl['PUBLIC_BASE_URL'] = $PublicBaseUrl
    $tpl['MIN_APP_VERSION'] = $MinAppVersion
    $tpl['JWT_KEY_ID'] = $jwtKid
    $tpl['MEDIA_DIR'] = $L.Media
    $tpl['API_HOST'] = '127.0.0.1'
    $tpl['API_PORT'] = [string]$ApiPort
    $tpl['POS_SHUTDOWN_ON_STDIN_EOF'] = '1'
    if (-not $Stand) {
        $tpl['ONEC_MODE'] = 'extension'
        $tpl['ONEC_BASE_URL'] = $OnecBaseUrl
        $tpl['ONEC_HS_PATH'] = $OnecHsPath
    } elseif ($tpl['ONEC_MODE'] -ne 'fixtures' -or $tpl['SMS_PROVIDER'] -ne 'fake' -or $tpl['QR_PROVIDER'] -ne 'bank') {
        # Проверяется сам шаблон пакета (до режимов ОС_API и «живого» стенда, которые кладутся поверх него ниже).
        throw 'stand.env.example: профиль стенда — ONEC_MODE=fixtures, SMS_PROVIDER=fake, QR_PROVIDER=bank (ADR-125); шаблон пакета изменён'
    }
    $standTpl = $null
    if ($Stand) { $standTpl = [ordered]@{}; foreach ($k in $tpl.Keys) { $standTpl[$k] = $tpl[$k] } }   # профиль стенда как в пакете (для -StandLive:$false)
    $osApiPairs = $null
    if ($Stand -and $osApiUrl) {
        # Стенд с ОС_API шлюза (ADR-126): поверх профиля (ONEC_MODE=fixtures) — режим чтения из 1С. Виды цен, склады и
        # период перечитки (ONEC_OSAPI_PRICE_TYPES, ONEC_OSAPI_WAREHOUSES, ONEC_OSAPI_POLL_SECONDS) — по умолчанию
        # программы; менять — администратор в config\api.env и worker.env.
        $osApiPairs = Get-OpsOsApiEnvPairs $osApiUrl
        foreach ($k in $osApiPairs.Keys) { $tpl[$k] = $osApiPairs[$k] }
    }
    $livePairs = $null
    if ($Stand -and $liveMode) {
        # «Живой» стенд поверх профиля: SMSPro, без тестового входа, без QR, заказы в 1С (Get-OpsStandLiveEnvPairs).
        $livePairs = Get-OpsStandLiveEnvPairs $standSender $StandSmsPhones
        foreach ($k in $livePairs.Keys) { $tpl[$k] = $livePairs[$k] }
        $smsList = $StandSmsPhones
        $apiEnvPath = Join-Path $L.Config 'api.env'
        if (-not $smsList -and (Test-Path -LiteralPath $apiEnvPath)) { $ae = Read-OpsEnvTemplate $apiEnvPath; if ($ae.Contains('SMS_STAGING_ALLOWED_PHONES')) { $smsList = [string]$ae['SMS_STAGING_ALLOWED_PHONES'] } }
        if (-not $smsList) {
            Write-OpsLog 'стенд «живой» без -StandSmsPhones: при APP_ENV=staging SMSPro отправляет настоящую SMS только номерам из SMS_STAGING_ALLOWED_PHONES, остальным — <test>1</test> (SMS не уходит, войти нельзя). Задайте -StandSmsPhones +996…,+996… (номер первого администратора — тоже)' 'WARN'
        }
        if ($AdminPhone -and @(([string]$smsList).Split(',') | ForEach-Object { $_.Trim() }) -notcontains $AdminPhone) {
            Write-OpsLog "стенд «живой»: номера первого администратора $AdminPhone нет в SMS_STAGING_ALLOWED_PHONES (-StandSmsPhones) — SMS ему не придёт" 'WARN'
        }
    } elseif ($Contour -eq 'test') {
        if ($TestPhones) { $tpl['AUTH_OTP_TEST_PHONES'] = $TestPhones }
        # Шесть случайных цифр; общеизвестный код демо 246810 при APP_ENV=staging API не принимает (ADR-124).
        while (-not $tpl['AUTH_OTP_TEST_CODE'] -or $tpl['AUTH_OTP_TEST_CODE'] -eq '246810') { $tpl['AUTH_OTP_TEST_CODE'] = '{0:D6}' -f (Get-Random -Minimum 0 -Maximum 1000000) }
        # SMS_PROVIDER=fake в схеме staging (без dev_outbox): запрос кода на нетестовый номер — CONFIG_ERROR, и
        # выключатель SMS закрывает выдачу кодов всем, в том числе тестовым номерам. В тесте — 1 мин вместо 5.
        $tpl['SMSPRO_CB_OPEN_MINUTES'] = '1'
        $tpExisting = ''
        $apiEnvPath = Join-Path $L.Config 'api.env'
        if (Test-Path -LiteralPath $apiEnvPath) { $ae = Read-OpsEnvTemplate $apiEnvPath; if ($ae.Contains('AUTH_OTP_TEST_PHONES')) { $tpExisting = [string]$ae['AUTH_OTP_TEST_PHONES'] } }
        if (-not $tpExisting) { $tpExisting = [string]$tpl['AUTH_OTP_TEST_PHONES'] }   # стенд: номера профиля +99670000000x
        if (-not $TestPhones -and -not $tpExisting) {
            Write-OpsLog 'тестовый контур без -TestPhones: войти нельзя никому (SMS не отправляются), а запрос кода на любой номер на минуту закрывает выдачу кодов. Задайте -TestPhones +996…,+996… (номер первого администратора — тоже)' 'WARN'
        }
        if ($AdminPhone -and @(($TestPhones + ',' + $tpExisting).Split(',') | ForEach-Object { $_.Trim() }) -notcontains $AdminPhone) {
            Write-OpsLog "тестовый контур: номера первого администратора $AdminPhone нет в -TestPhones — он не сможет войти" 'WARN'
        }
    }
    $empty = @($tpl.Keys | Where-Object { [string]$tpl[$_] -eq '' })
    foreach ($k in $empty) { $tpl.Remove($k) }   # пустое значение = «не задано» (как в Linux .env)
    $sec = { param($n) Join-Path $L.Secrets $n }
    $hasSecret = { param($n) $f = Join-Path $L.Secrets $n; (Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0 }
    $common = [ordered]@{ DATABASE_URL_FILE = (& $sec 'database_url'); JWT_PUBLIC_KEY_FILE = (& $sec 'jwt_public.json'); OTP_HMAC_SECRET_FILE = (& $sec 'otp_pepper') }
    foreach ($p in @(@('SMSPRO_LOGIN_FILE', 'smspro_login'), @('SMSPRO_PASSWORD_FILE', 'smspro_password'), @('ONEC_HS_USER_FILE', 'onec_hs_user'),
            @('ONEC_HS_PASSWORD_FILE', 'onec_hs_password'), @('ONEC_HS_TOKEN_FILE', 'onec_hs_token'), @('ONEC_USER_FILE', 'onec_user'),
            @('ONEC_PASSWORD_FILE', 'onec_password'), @('ONEC_CA_CERT_FILE', 'onec_ca.pem'))) {
        if (& $hasSecret $p[1]) { $common[$p[0]] = (& $sec $p[1]) }
    }
    $apiPairs = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in $tpl.Keys) { $apiPairs[$k] = $tpl[$k] }
    $apiPairs['WORKERS_ENABLED'] = 'false'
    foreach ($k in $common.Keys) { $apiPairs[$k] = $common[$k] }
    $apiPairs['JWT_PRIVATE_KEY_FILE'] = (& $sec 'jwt_private.pem')
    $apiPairs['PIN_PEPPER_FILE'] = (& $sec 'pin_pepper')
    $workerPairs = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in $tpl.Keys) { $workerPairs[$k] = $tpl[$k] }
    $workerPairs['WORKERS_ENABLED'] = 'true'
    foreach ($k in $common.Keys) { $workerPairs[$k] = $common[$k] }
    # Как в compose.prod.yml (с 2026-11-24 pin_pepper и у worker): CryptoModule глобальный (ADR-115, хэш аварийного кода
    # планшета), и dist\worker.js без PIN_PEPPER при APP_ENV=prod/staging завершается (SecretConfigError, проверено).
    $workerPairs['PIN_PEPPER_FILE'] = (& $sec 'pin_pepper')
    if (& $hasSecret 'healthchecks_url') { $workerPairs['HEALTHCHECKS_PING_URL_FILE'] = (& $sec 'healthchecks_url') }
    $migPairs = [ordered]@{ APP_ENV = $appEnv; LOG_LEVEL = 'info'; DATABASE_URL_FILE = (& $sec 'database_url'); DB_MIGRATOR_PASSWORD_FILE = (& $sec 'db_migrator_password') }
    if ($tpl.Contains('RECEIVABLES_MAX_AGE_MIN')) { $migPairs['RECEIVABLES_MAX_AGE_MIN'] = $tpl['RECEIVABLES_MAX_AGE_MIN'] }
    $hdr = "Optomstroy POS: настройки {0} (install.ps1 {1}). Только несекретные значения; секреты — файлы по путям *_FILE.`nМеняет только администратор: через этот файл можно задать NODE_OPTIONS, то есть запустить любой код.`nПустое значение = «не задано». Применение: перезапуск службы."
    foreach ($e in @(@('api.env', $apiPairs, 'OptomstroyApi'), @('worker.env', $workerPairs, 'OptomstroyWorker'), @('migrate.env', $migPairs, 'migrate (dist\migrate.js)'))) {
        $added = Write-OpsEnvFile (Join-Path $L.Config $e[0]) ($hdr -f $e[2], (Get-Date -Format 'yyyy-MM-dd')) $e[1]
        Write-OpsLog ("config\{0}: {1}" -f $e[0], $(if (@($added).Count -eq @($e[1].Keys).Count) { 'создан' } elseif (@($added).Count -gt 0) { 'добавлены имена: ' + ($added -join ', ') } else { 'без изменений' })) 'OK'
    }
    # Явно заданный -TestPhones заменяет прежний список (остальные имена существующих файлов не переписываются).
    if ($Contour -eq 'test' -and $TestPhones) {
        foreach ($f in @('api.env', 'worker.env')) {
            if (Set-OpsEnvValue (Join-Path $L.Config $f) 'AUTH_OTP_TEST_PHONES' $TestPhones) { Write-OpsLog "config\${f}: AUTH_OTP_TEST_PHONES = $TestPhones" 'OK' }
        }
    }
    # Стенд: режим 1С в уже существующих api.env и worker.env (ADR-126). Включённый ОС_API (явно или из install.json)
    # не откатывается повторным запуском; путь сервиса, если администратор его поменял, не переписывается.
    if ($Stand -and ($null -ne $osApiPairs -or $osApiOff)) {
        foreach ($f in @('api.env', 'worker.env')) {
            $fp = Join-Path $L.Config $f
            if ($osApiOff) {
                if (Set-OpsEnvValue $fp 'ONEC_MODE' 'fixtures') { Write-OpsLog "config\${f}: ONEC_MODE = fixtures (-StandOnecOsApi fixtures)" 'OK' }
                continue
            }
            foreach ($k in @('ONEC_MODE', 'ONEC_BASE_URL')) {
                if (Set-OpsEnvValue $fp $k ([string]$osApiPairs[$k])) { Write-OpsLog "config\${f}: $k = $($osApiPairs[$k])" 'OK' }
            }
        }
    }
    # «Живой» стенд в api.env и worker.env (новых и существующих): тестовые имена не удаляются, а очищаются (ИМЯ=,
    # «не задано») — иначе повторный install.ps1 или update.ps1 дописал бы их из профиля стенда (AUTH_OTP_TEST_MODE=true,
    # BANK_QR_ADAPTER=sandbox), и API не запустился бы (env.schema.ts: тестовый код запрещён при SMS_PROVIDER=smspro).
    # -StandLive:$false — обратно на значения профиля стенда (тестовый код — прежний, если он ещё есть, иначе новый).
    if ($Stand -and ($null -ne $livePairs -or $liveModeOff)) {
        $setPairs = $livePairs
        if ($liveModeOff) {
            $setPairs = Get-OpsStandProfileRestorePairs $standTpl
            # Номера тестового входа: -TestPhones > запомненные до «живого» стенда > профиль пакета.
            $setPairs['AUTH_OTP_TEST_PHONES'] = Select-OpsStandRestorePhones $TestPhones $phonesBeforeLive ([string]$setPairs['AUTH_OTP_TEST_PHONES'])
            $otpCode = ''
            $apiEnvPath = Join-Path $L.Config 'api.env'
            if (Test-Path -LiteralPath $apiEnvPath) { $ae = Read-OpsEnvTemplate $apiEnvPath; if ($ae.Contains('AUTH_OTP_TEST_CODE')) { $otpCode = [string]$ae['AUTH_OTP_TEST_CODE'] } }
            while (-not $otpCode -or $otpCode -eq '246810') { $otpCode = '{0:D6}' -f (Get-Random -Minimum 0 -Maximum 1000000) }
            $setPairs['AUTH_OTP_TEST_CODE'] = $otpCode
        } else {
            $setPairs = [ordered]@{}
            foreach ($k in $livePairs.Keys) { $setPairs[$k] = $livePairs[$k] }
            foreach ($p in @(@('SMSPRO_LOGIN_FILE', 'smspro_login'), @('SMSPRO_PASSWORD_FILE', 'smspro_password'))) { $setPairs[$p[0]] = (& $sec $p[1]) }
        }
        foreach ($f in @('api.env', 'worker.env')) {
            $fp = Join-Path $L.Config $f
            $changed = @()
            foreach ($k in $setPairs.Keys) { if (Set-OpsEnvValue $fp $k ([string]$setPairs[$k])) { $changed += $k } }
            # Значения не печатаются: тестовый код и пути — только имена.
            if ($changed.Count -gt 0) { Write-OpsLog ("config\{0}: {1} — {2}" -f $f, $(if ($liveModeOff) { 'профиль стенда' } else { '«живой» стенд' }), ($changed -join ', ')) 'OK' }
            else { Write-OpsLog "config\${f}: $(if ($liveModeOff) { 'профиль стенда' } else { '«живой» стенд' }) — без изменений" }
        }
    }

    $nodeCur = Join-Path $L.Current 'node\node.exe'
    $svcDefs = @(
        @{ Name = 'OptomstroyApi'; File = 'api.svc.json'; Args = @('--max-old-space-size=768', "--env-file=$(Join-Path $L.Config 'api.env')", 'dist\main.js'); Wd = (Join-Path $L.Current 'api');
            Env = [ordered]@{ APP_ENV = $appEnv; API_HOST = '127.0.0.1'; API_PORT = [string]$ApiPort; POS_SHUTDOWN_ON_STDIN_EOF = '1' }; Mem = 1024; Cpus = 1.5; Log = 'api'; Stop = 30 },
        @{ Name = 'OptomstroyWorker'; File = 'worker.svc.json'; Args = @('--max-old-space-size=768', "--env-file=$(Join-Path $L.Config 'worker.env')", 'dist\worker.js'); Wd = (Join-Path $L.Current 'api');
            Env = [ordered]@{ APP_ENV = $appEnv; POS_SHUTDOWN_ON_STDIN_EOF = '1' }; Mem = 1024; Cpus = 1.0; Log = 'worker'; Stop = 45 },
        @{ Name = 'OptomstroyBackup'; File = 'backup.svc.json'; Args = @('--max-old-space-size=256', (Join-Path $L.Current 'backup\pos-backup.mjs'), 'daemon', '--config', (Join-Path $L.Config 'backup.json')); Wd = (Join-Path $L.Current 'backup');
            Env = [ordered]@{ POS_SHUTDOWN_ON_STDIN_EOF = '1' }; Mem = 512; Cpus = 0.5; Log = 'backup'; Stop = 60 }
    )
    foreach ($d in $svcDefs) {
        $path = Join-Path $L.Config $d.File
        if (Test-Path -LiteralPath $path) { Write-OpsLog "config\$($d.File): уже есть (не переписывается)"; continue }
        $o = [ordered]@{
            name = $d.Name; executable = $nodeCur; arguments = $d.Args; workingDirectory = $d.Wd
            inheritEnvironment = $false; environment = $d.Env
            jobMemoryLimitMB = $d.Mem; cpuRatePercent = (Get-OpsCpuRatePercent $d.Cpus)
            logDirectory = (Join-Path $L.Logs $d.Log); logMaxBytes = 20971520; logKeepFiles = 10
            stopTimeoutSeconds = $d.Stop; shutdownViaStdin = $true
        }
        Write-OpsJson $path $o
        Write-OpsLog "config\$($d.File): создан (память $($d.Mem) МБ, процессор $($o.cpuRatePercent) % машины)" 'OK'
    }

    $bkPub = Join-Path $L.Config 'backup-public.pem'
    if ($BackupPublicKey) {
        $txt = [System.IO.File]::ReadAllText($BackupPublicKey)
        if ($txt -match 'PRIVATE KEY') { throw "$BackupPublicKey — закрытый ключ! На сервер передаётся только открытый (backup-public.pem)" }
        if ($txt -notmatch '-----BEGIN PUBLIC KEY-----') { throw "$BackupPublicKey — не открытый ключ PEM" }
        if ((Test-Path -LiteralPath $bkPub) -and ([System.IO.File]::ReadAllText($bkPub) -ne $txt)) { throw "config\backup-public.pem уже есть и отличается — смена ключа вручную (README, резервное копирование)" }
        Write-OpsUtf8 $bkPub $txt
    } elseif (-not (Test-Path -LiteralPath $bkPub) -and $DevTest) {
        # DevTest: «держатель ключа» — папка рядом с тестовой установкой (закрытый ключ вне InstallRoot).
        $keyDir = Join-Path (Split-Path -Parent $L.Root) 'devtest-backup-key'
        if (-not (Test-Path -LiteralPath (Join-Path $keyDir 'backup-public.pem'))) {
            $k = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList @((Join-Path $L.Current 'backup\pos-backup.mjs'), 'keygen', '--out', $keyDir, '--no-passphrase') -CleanEnvironment
            if ($k.Code -ne 0) { throw "keygen: код $($k.Code)" }
        }
        Copy-Item -LiteralPath (Join-Path $keyDir 'backup-public.pem') -Destination $bkPub
        Write-OpsLog "DevTest: тестовая пара ключей резервных копий в $keyDir (закрытый ключ — вне InstallRoot)" 'WARN'
    }
    $bkJson = Join-Path $L.Config 'backup.json'
    if (-not (Test-Path -LiteralPath $bkJson)) {
        $b = [ordered]@{
            backupRoot = $L.BackupRoot; pgBin = $PgBin
            pg = [ordered]@{ host = '127.0.0.1'; port = $PgPort; user = 'pos_backup'; database = $DbName; credentialFile = (& $sec 'pgpass_backup.conf') }
            publicKeyFile = $bkPub; walSpoolDir = $L.WalSpool; timeZone = 'Asia/Bishkek'; dailyAt = '05:30'
            keepDays = 30; monthlyExtraDays = 93; globalsKeepDays = 90; globalsWeekday = 0
            pitr = $true; walShipEverySeconds = 20; walOffsiteEverySeconds = 300; retryMinutes = 30
            chunkSize = 1048576; gzipLevel = 3
            mediaDirs = @([ordered]@{ name = 'media'; path = $L.Media }, [ordered]@{ name = 'audit-anchors'; path = $L.AuditAnchors })
            offsite = $null; healthchecksUrlFile = $null; statusCheckEveryMinutes = 10
        }
        if ($Contour -eq 'test') { $b.keepDays = 7; $b.dailyAt = '05:45' }
        if (& $hasSecret 'healthchecks_url') { $b.healthchecksUrlFile = (& $sec 'healthchecks_url') }
        Write-OpsJson $bkJson $b
        Write-OpsLog 'config\backup.json: создан (offsite = null: копия вне сервера не настроена — README)' 'OK'
    } else { Write-OpsLog 'config\backup.json: уже есть (не переписывается)' }

    # Защищённая копия secrets (16 §8.2, RUNBOOK §2 шаг 6): без pin_pepper/otp_pepper после потери сервера PIN
    # сотрудников и аварийные коды планшетов из восстановленной базы не проверяются. Шифруется открытым ключом копий
    # (OPTBK1) в <BackupRoot>\dumps\secrets — оттуда служба копий уносит её вне сервера вместе с дампами.
    $secExportDir = Join-Path $L.BackupRoot 'dumps\secrets'
    if (Test-Path -LiteralPath $bkPub) {
        $se = Invoke-OpsTool $L $rel.Dir @('secrets-export', '--dir', $L.Secrets, '--public', $bkPub, '--out-dir', $secExportDir)
        if ($se.Code -ne 0 -or $null -eq $se.Json) { throw "защищённая копия secrets не создана (secrets-export, код $($se.Code))" }
        if ($se.Json.unchanged) { Write-OpsLog "защищённая копия secrets актуальна: $($se.Json.file)" 'OK' }
        else { Write-OpsLog "защищённая копия secrets: $($se.Json.exported) ($($se.Json.files) файлов, ключ $($se.Json.keyId.Substring(0, 16))…)" 'OK' }
        [void]$summary.Add("секреты: зашифрованная копия в $secExportDir (уходит вне сервера с дампами). Держатель ключа один раз проверяет её расшифровку и хранит офлайн-копию (README, «Секреты»). После ручной замены файла в secrets — повторный запуск install.ps1 (новая копия)")
    } else { Write-OpsLog 'нет config\backup-public.pem — защищённая копия secrets НЕ создана' 'WARN' }

    # Параметры файла сайта Apache: заданные явно > запомненные в install.json прошлым запуском > по умолчанию.
    # (Повторный запуск без -CertFile/-KeyFile/-ApacheListenPort не возвращает пути по умолчанию.)
    $ijPrev = { param($n) if ($null -ne $installJson -and $installJson.PSObject.Properties[$n] -and $installJson.$n) { return $installJson.$n }; return $null }
    $apacheExplicit = $PSBoundParameters.ContainsKey('CertFile') -or $PSBoundParameters.ContainsKey('KeyFile') -or $PSBoundParameters.ContainsKey('ApacheListenPort')
    if (-not $ApacheDir -and (& $ijPrev 'apacheDir')) { $ApacheDir = [string](& $ijPrev 'apacheDir') }
    $apacheDirEff = $ApacheDir
    if (-not $apacheDirEff) { $apacheDirEff = 'C:\Apache24' }
    if (-not $PSBoundParameters.ContainsKey('CertFile') -and (& $ijPrev 'apacheCertFile')) { $CertFile = [string](& $ijPrev 'apacheCertFile') }
    if (-not $PSBoundParameters.ContainsKey('KeyFile') -and (& $ijPrev 'apacheKeyFile')) { $KeyFile = [string](& $ijPrev 'apacheKeyFile') }
    if (-not $PSBoundParameters.ContainsKey('ApacheListenPort') -and (& $ijPrev 'apacheListenPort')) { $ApacheListenPort = [int](& $ijPrev 'apacheListenPort') }
    if (-not $CertFile) { $CertFile = Join-Path $apacheDirEff "conf\ssl\$serverName.fullchain.crt" }
    if (-not $KeyFile) { $KeyFile = Join-Path $apacheDirEff "conf\ssl\$serverName.key" }

    $ij = [ordered]@{
        contour = $Contour; appEnv = $appEnv; publicBaseUrl = $PublicBaseUrl; serverName = $serverName; minAppVersion = $MinAppVersion
        apiPort = $ApiPort; pgPort = $PgPort; dbName = $DbName; pgBin = $PgBin; backupRoot = $L.BackupRoot; jwtKeyId = $jwtKid
        onecBaseUrl = $OnecBaseUrl; onecHsPath = $OnecHsPath; stand = [bool]$Stand; onecOsApiBaseUrl = $osApiUrl; standLive = [bool]($Stand -and $liveMode)
        standTestPhonesBeforeLive = $(if ($Stand -and $liveMode -and $phonesBeforeLive) { $phonesBeforeLive } else { $null })
        deployUser = $DeployUser; apacheDir = $ApacheDir; apacheServiceName = $ApacheServiceName; devTest = [bool]$DevTest
        apacheCertFile = $CertFile; apacheKeyFile = $KeyFile; apacheListenPort = $ApacheListenPort
        pgServiceAccount = $PgServiceAccount
    }
    Write-OpsJson $L.InstallJson $ij
    Write-OpsLog 'config\install.json: параметры установки (для update/rollback/status/uninstall)' 'OK'

    # =========================================================================================================
    Start-Step 'PostgreSQL 17 (кластер и служба OptomstroyPostgres)'
    # Скрипты и программы — по настоящему пути релиза, а не через current: pg-tool.mjs и dist\migrate.js сравнивают
    # process.argv[1] с import.meta.url (настоящий путь) и через junction молча ничего не делают (код 0).
    $relReal = Get-OpsJunctionTarget $L.Current
    $pgDir = Join-Path $relReal 'postgres'
    if (-not $clusterExists) {
        $ip = @{ PgBin = $PgBin; InstallRoot = $L.Root; Port = $PgPort; SharedBuffers = $SharedBuffers; BackupConfig = $bkJson; ServiceAccount = $PgServiceAccount }
        if ($AcceptSharedServiceAccount) { $ip.AcceptSharedServiceAccount = $true }
        if ($DevTest) { $ip.DevTest = $true; $ip.SharedBuffers = '128MB'; $ip.EffectiveCacheSize = '512MB' }
        $code = Invoke-OpsScript (Join-Path $pgDir 'init-postgres.ps1') $ip
        if ($code -ne 0) { throw "init-postgres.ps1: код $code" }
        if ($DevTest) {
            # init-postgres.ps1 -DevTest запускает сервер дочерним процессом (наследует канал вывода этого скрипта) —
            # перезапуск отдельно (Start-OpsDetachedPgCtl), иначе вызывающий не дождётся конца вывода install.ps1.
            $code = Invoke-OpsScript (Join-Path $pgDir 'stop-postgres.ps1') @{ PgBin = $PgBin; InstallRoot = $L.Root; DevTest = $true }
            if ($code -ne 0) { throw "stop-postgres.ps1 -DevTest: код $code" }
            Start-OpsPostgres $L $PgBin $PgPort -DevTest
        }
    } else {
        Write-OpsLog "кластер уже есть ($($L.PgData)) — initdb не выполняется"
        if (-not $DevTest -and (Get-OpsServiceState $script:OpsPgServiceName) -eq 'Missing') {
            $code = Invoke-OpsScript (Join-Path $pgDir 'init-postgres.ps1') @{ PgBin = $PgBin; InstallRoot = $L.Root; Port = $PgPort; SharedBuffers = $SharedBuffers; BackupConfig = $bkJson; Resume = $true }
            if ($code -ne 0) { throw "init-postgres.ps1 -Resume: код $code" }
        }
        Start-OpsPostgres $L $PgBin $PgPort -DevTest:$DevTest
    }
    $pgListen = Get-OpsListenAddresses $PgPort
    foreach ($a in $pgListen) { if ($a -ne '127.0.0.1') { throw "PostgreSQL слушает не только 127.0.0.1: $a" } }
    Write-OpsLog "PostgreSQL слушает только 127.0.0.1:$PgPort" 'OK'

    # =========================================================================================================
    Start-Step 'Роли, база, стоп-проверка локали, архивирование WAL'
    if ($ResetStandData) {
        # Чистая база стенда (-Stand -ResetStandData -ConfirmResetDb <база>): службы стоп → зашифрованная копия
        # (pos-backup dump-only, как перед обновлением) → DROP DATABASE → фото и отметки аудита прежней базы — в
        # state\stand-reset-<время>. Базу заново создаёт apply-roles.ps1 (ниже), migrate --seed кладёт только строки по
        # умолчанию (seeds/0001_defaults.sql), службы запускает шаг 11. Повтор после сбоя безопасен (базы нет — без копии).
        Stop-OpsAppServices $L @('OptomstroyWorker', 'OptomstroyApi', 'OptomstroyBackup') -DevTest:$DevTest
        $pgToolArgs = @((Join-Path $pgDir 'pg-tool.mjs'), '--modules', (Join-Path $relReal 'api'), '--secrets', $L.Secrets, '--port', [string]$PgPort, '--db', $DbName)
        $ex = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList (@($pgToolArgs[0], 'db-exists') + $pgToolArgs[1..($pgToolArgs.Count - 1)]) -CleanEnvironment -QuietStdout
        $exJ = ConvertFrom-OpsJsonLine $ex.Out
        if ($ex.Code -ne 0 -or $null -eq $exJ) { throw "pg-tool db-exists: код $($ex.Code)" }
        if ($exJ.exists) {
            $bkCfg = Read-OpsJson (Join-Path $L.Config 'backup.json')
            if ($DevTest -and -not (Test-Path -LiteralPath (Join-Path ([string]$bkCfg.pgBin) 'pg_dump.exe'))) {
                Write-OpsLog "DevTest: в $($bkCfg.pgBin) нет pg_dump.exe — копия перед очисткой ПРОПУЩЕНА (на сервере это стоп)" 'WARN'
            } else {
                $d = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList @((Join-Path $L.Current 'backup\pos-backup.mjs'), 'dump-only', '--config', (Join-Path $L.Config 'backup.json')) -CleanEnvironment -TimeoutSec 7200
                $dj = ConvertFrom-OpsJsonLine $d.Out
                if ($d.Code -ne 0 -or $null -eq $dj -or -not $dj.PSObject.Properties['dump']) { throw "копия базы перед очисткой не создана (pos-backup dump-only, код $($d.Code)) — база не удалялась; службы запустит повторный install.ps1 без -ResetStandData" }
                Write-OpsLog ("копия прежней базы: {0} ({1:N1} МБ) — восстановление: backup\restore.ps1 -DumpFile <файл> (держатель ключа)" -f $dj.dump, ([double]$dj.size / 1MB)) 'OK'
                [void]$summary.Add("копия базы стенда до очистки: $($dj.dump)")
            }
            $dr = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList (@($pgToolArgs[0], 'drop-db') + $pgToolArgs[1..($pgToolArgs.Count - 1)] + @('--confirm', $DbName)) -CleanEnvironment
            if ($dr.Code -ne 0) { throw "pg-tool drop-db: код $($dr.Code)" }
        } else { Write-OpsLog "базы $DbName нет (повторный запуск после очистки) — копия и удаление не нужны" }
        $resetDir = Join-Path $L.State ('stand-reset-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($src in @(@((Join-Path $L.Media 'images'), 'media-images'), @($L.AuditAnchors, 'audit-anchors'))) {
            $items = @(Get-ChildItem -LiteralPath $src[0] -Force -ErrorAction SilentlyContinue)
            if ($items.Count -eq 0) { continue }
            $dst = Join-Path $resetDir $src[1]
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            foreach ($it in $items) { Move-Item -LiteralPath $it.FullName -Destination $dst }
            Write-OpsLog "$($src[0]): $($items.Count) шт. перенесено в $dst (данные прежней базы)" 'OK'
        }
        Write-OpsLog "база $DbName стенда будет создана заново (apply-roles.ps1, migrate --seed); первый администратор — scripts\first-admin.ps1" 'OK'
    }
    $code = Invoke-OpsScript (Join-Path $pgDir 'apply-roles.ps1') @{ InstallRoot = $L.Root; Port = $PgPort }
    if ($code -ne 0) { throw "apply-roles.ps1: код $code" }

    # =========================================================================================================
    Start-Step 'Миграции и строки по умолчанию (migrate --seed)'
    $m = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList @("--env-file=$(Join-Path $L.Config 'migrate.env')", 'dist\migrate.js', '--seed') -WorkingDirectory (Join-Path $relReal 'api') -CleanEnvironment -Environment @{ APP_ENV = $appEnv }
    if ($m.Code -ne 0) { throw "migrate завершился с кодом $($m.Code) — службы не запускались" }
    $dbs = Get-OpsDbState $L $rel.Dir $PgPort $DbName
    $missing = @(Get-OpsReleaseMigrations $rel.Dir | Where-Object { @($dbs.migrations) -notcontains $_ })
    if ($missing.Count -gt 0) { throw ("после migrate в журнале нет миграций: " + ($missing -join ', ')) }
    Write-OpsLog ("журнал миграций: {0} шт., последняя {1}; pg-boss схема {2}" -f @($dbs.migrations).Count, @($dbs.migrations)[-1], $dbs.pgboss) 'OK'

    # =========================================================================================================
    Start-Step 'Службы Windows и права учётных записей служб'
    $svcExe = Join-Path $L.Current 'svchost\OptomstroySvc.exe'
    foreach ($d in $svcDefs) {
        $ck = Invoke-OpsProcess -FilePath (Join-Path $rel.Dir 'svchost\OptomstroySvc.exe') -ArgumentList @('--check-config', '--config', (Join-Path $L.Config $d.File))
        if ($ck.Code -ne 0) { throw "OptomstroySvc --check-config $($d.File): код $($ck.Code)" }
    }
    Write-OpsLog 'описания служб (*.svc.json) проверены OptomstroySvc.exe --check-config' 'OK'
    if ($DevTest) {
        Skip-Admin 'sc.exe create OptomstroyApi/OptomstroyWorker/OptomstroyBackup (NT SERVICE\<служба>, delayed-auto, depend= OptomstroyPostgres), sc failure/failureflag/sidtype, PreshutdownTimeout'
        Skip-Admin 'icacls для NT SERVICE\Optomstroy* (releases RX, config и секреты по файлам R, logs\<служба> M, data\media M, data\audit-anchors M — только Worker), set-backup-acl.ps1, sc sdset для posdeploy (только Api и Worker)'
    } else {
        if (-not [System.Diagnostics.EventLog]::SourceExists('OptomstroySvc')) { New-EventLog -LogName Application -Source OptomstroySvc; Write-OpsLog 'источник журнала событий OptomstroySvc зарегистрирован' 'OK' }
        $displays = @{ OptomstroyApi = 'Optomstroy POS API'; OptomstroyWorker = 'Optomstroy POS worker'; OptomstroyBackup = 'Optomstroy POS backup' }
        foreach ($d in $svcDefs) {
            $bin = '"' + $svcExe + '" --config "' + (Join-Path $L.Config $d.File) + '"'
            $scBin = $bin.Replace('"', '\"')
            if ((Get-OpsServiceState $d.Name) -eq 'Missing') {
                $o = & sc.exe create $d.Name binPath= $scBin start= delayed-auto obj= "NT SERVICE\$($d.Name)" DisplayName= $displays[$d.Name] depend= $script:OpsPgServiceName 2>&1
                if ($LASTEXITCODE -ne 0) { throw "sc.exe create $($d.Name): код $LASTEXITCODE $o" }
                Write-OpsLog "служба $($d.Name) создана (NT SERVICE\$($d.Name))" 'OK'
            } else {
                $o = & sc.exe config $d.Name binPath= $scBin start= delayed-auto obj= "NT SERVICE\$($d.Name)" depend= $script:OpsPgServiceName 2>&1
                if ($LASTEXITCODE -ne 0) { throw "sc.exe config $($d.Name): код $LASTEXITCODE $o" }
                Write-OpsLog "служба $($d.Name) уже есть — параметры приведены к эталону"
            }
            foreach ($scArgs in @(@('description', $d.Name, 'Optomstroy POS (OptomstroySvc.exe). Config: ' + $L.Config), @('sidtype', $d.Name, 'unrestricted'),
                    @('failure', $d.Name, 'reset=', '86400', 'actions=', 'restart/10000/restart/10000/restart/60000'), @('failureflag', $d.Name, '1'))) {
                $o = & sc.exe @scArgs 2>&1
                if ($LASTEXITCODE -ne 0) { throw "sc.exe $($scArgs -join ' '): код $LASTEXITCODE $o" }
            }
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($d.Name)" -Name PreshutdownTimeout -Value 90000 -Type DWord
        }
        $sid = @{}
        foreach ($n in $script:OpsServiceNames) { $sid[$n] = Resolve-Sid "NT SERVICE\$n" }
        foreach ($n in @('OptomstroyApi', 'OptomstroyWorker')) {
            $s = $sid[$n]
            Invoke-Icacls @($L.Root, '/grant', "*${s}:(RX)")
            Invoke-Icacls @($L.Releases, '/grant', "*${s}:(OI)(CI)RX")
            Invoke-Icacls @($L.Config, '/grant', "*${s}:(RX)")
            Invoke-Icacls @($L.Data, '/grant', "*${s}:(RX)")
            Invoke-Icacls @($L.Media, '/grant', "*${s}:(OI)(CI)M")
            Invoke-Icacls @($L.Logs, '/grant', "*${s}:(RX)")
        }
        # Отметки журнала аудита пишет только задача audit.anchor фоновых задач (audit-jobs.bridge.ts, WORKERS_ENABLED);
        # API к ним доступа не получает: взломанный процесс API не перепишет отметки (защита от подмены).
        Invoke-Icacls @($L.AuditAnchors, '/grant', "*$($sid.OptomstroyWorker):(OI)(CI)M")
        # Повторный запуск поверх установки прежней версии комплекта: право API на отметки снимается.
        Invoke-Icacls @($L.AuditAnchors, '/remove:g', "*$($sid.OptomstroyApi)", '/T', '/C')
        Invoke-Icacls @((Join-Path $L.Logs 'api'), '/grant', "*$($sid.OptomstroyApi):(OI)(CI)M", '/T')
        Invoke-Icacls @((Join-Path $L.Logs 'worker'), '/grant', "*$($sid.OptomstroyWorker):(OI)(CI)M", '/T')
        foreach ($f in @('api.env', 'api.svc.json')) { Invoke-Icacls @((Join-Path $L.Config $f), '/grant', "*$($sid.OptomstroyApi):(R)") }
        foreach ($f in @('worker.env', 'worker.svc.json')) { Invoke-Icacls @((Join-Path $L.Config $f), '/grant', "*$($sid.OptomstroyWorker):(R)") }
        Invoke-Icacls @((Join-Path $L.Config 'backup.svc.json'), '/grant', "*$($sid.OptomstroyBackup):(R)")
        # Секреты — по таблице плана (раздел 8, шаг 2): фоновым задачам ключ подписи JWT не выдаётся; pin_pepper
        # выдаётся (отличие от плана: без него dist\worker.js не стартует, см. шаг 6).
        $apiSecrets = @('database_url', 'jwt_private.pem', 'jwt_public.json', 'otp_pepper', 'pin_pepper', 'smspro_login', 'smspro_password', 'onec_hs_user', 'onec_hs_password', 'onec_hs_token', 'onec_user', 'onec_password', 'onec_ca.pem')
        $workerSecrets = @('database_url', 'jwt_public.json', 'otp_pepper', 'pin_pepper', 'smspro_login', 'smspro_password', 'onec_hs_user', 'onec_hs_password', 'onec_hs_token', 'onec_user', 'onec_password', 'onec_ca.pem', 'healthchecks_url')
        foreach ($p in @(@('OptomstroyApi', $apiSecrets), @('OptomstroyWorker', $workerSecrets))) {
            foreach ($f in $p[1]) {
                $fp = Join-Path $L.Secrets $f
                if (Test-Path -LiteralPath $fp) { Invoke-Icacls @($fp, '/grant', "*$($sid[$p[0]]):(R)") }
            }
        }
        Write-OpsLog 'права NT SERVICE\OptomstroyApi и \OptomstroyWorker выданы (секреты — по файлам)' 'OK'
        Grant-OpsJunctionAccess $L.Current   # права служб на саму ссылку current (выданы на InstallRoot выше)
        $code = Invoke-OpsScript (Join-Path $L.Current 'backup\set-backup-acl.ps1') @{ InstallRoot = $L.Root; BackupRoot = $L.BackupRoot; WalSpoolDir = $L.WalSpool; MediaDirs = @($L.Media, $L.AuditAnchors); PgServiceAccount = $PgServiceAccount }
        if ($code -ne 0) { throw "set-backup-acl.ps1: код $code" }
        if ($ApacheServiceAccount) {
            $as = Resolve-Sid $ApacheServiceAccount
            Invoke-Icacls @($L.Root, '/grant', "*${as}:(RX)")
            Invoke-Icacls @($L.Data, '/grant', "*${as}:(RX)")
            Invoke-Icacls @($L.Media, '/grant', "*${as}:(OI)(CI)RX")
            Write-OpsLog "Apache ($ApacheServiceAccount): чтение data\media (фото)" 'OK'
        } else { Write-OpsLog 'учётная запись службы Apache не указана (-ApacheServiceAccount) — право чтения фото выдайте по README (раздел Apache)' 'WARN' }
        # posdeploy: опрос, запуск, остановка только OptomstroyApi и OptomstroyWorker (sc sdset; прежние права — в state).
        # OptomstroyPostgres и OptomstroyBackup — только опрос состояния (CC, LC, RC; без запуска и остановки): остановка
        # базы или копий не нужна роли выкладки (README §12), а без опроса status.ps1 под posdeploy по SSH (сетевой
        # вход, нет группы INTERACTIVE из стандартных прав службы) видит «нет доступа». Право запуска и остановки,
        # выданное прежней версией комплекта, снимается.
        $deploySid = $null
        if ($DeployUser) { try { $deploySid = Resolve-Sid $DeployUser } catch { $deploySid = $null } }
        if ($deploySid) {
            $ace = "(A;;CCLCRPWPLORC;;;$deploySid)"
            $queryAce = "(A;;CCLCRC;;;$deploySid)"
            $deployServices = @('OptomstroyApi', 'OptomstroyWorker')
            foreach ($n in @($script:OpsServiceNames + $script:OpsPgServiceName)) {
                if ((Get-OpsServiceState $n) -eq 'Missing') { continue }
                $old = ((& sc.exe sdshow $n) | Where-Object { $_ -match 'D:' } | Select-Object -First 1)
                if (-not $old) { throw "sc.exe sdshow ${n}: нет DACL" }
                $old = $old.Trim()
                if ($deployServices -contains $n) { $want = $ace; $drop = $queryAce } else { $want = $queryAce; $drop = $ace }
                $new = Update-OpsSddlAce $old $want $drop
                if ($new -eq $old) { continue }
                $bak = Join-Path $L.State "$n.sddl.backup"
                if (-not (Test-Path -LiteralPath $bak)) { Write-OpsUtf8 $bak $old }
                $o = & sc.exe sdset $n $new 2>&1
                if ($LASTEXITCODE -ne 0) { & sc.exe sdset $n $old | Out-Null; throw "sc.exe sdset ${n}: код $LASTEXITCODE $o (прежние права восстановлены)" }
                if ($old.Contains($ace) -and $want -eq $queryAce) { Write-OpsLog "${n}: право $DeployUser на запуск и остановку снято (оставлен только опрос)" 'OK' }
            }
            Write-OpsLog "$DeployUser`: опрос, запуск и остановка OptomstroyApi и OptomstroyWorker; PostgreSQL и копии — только опрос состояния (sc sdset; прежние права — state\*.sddl.backup)" 'OK'
        }
    }

    # =========================================================================================================
    Start-Step 'Запуск служб и проверка готовности'
    # Повторный запуск install.ps1 с новыми параметрами (например -TestPhones) меняет config\*.env: работающие
    # службы с изменившимися настройками перезапускаются, иначе новые значения не действуют.
    Start-OpsAppServices $L @('OptomstroyBackup', 'OptomstroyApi', 'OptomstroyWorker') -DevTest:$DevTest -RestartIfChanged
    $h = Wait-OpsApiHealthy $ApiPort 180
    Write-OpsLog ("/health: {0}; /health/ready: {1} ({2}); ожидание {3} с" -f $h.Health, $h.Ready, $h.ReadyStatus, $h.Seconds)
    if (-not $h.Ok) { throw "API не готов: /health $($h.Health), /health/ready $($h.Ready) — журнал $($L.Logs)\api" }
    if ($h.ReadyStatus -eq 'degraded') { Write-OpsLog '/health/ready: degraded — данных синхронизации с 1С ещё нет (ожидаемо, пока 1С не подключена)' 'WARN' }
    $apiListen = Get-OpsListenAddresses $ApiPort
    foreach ($a in $apiListen) { if ($a -ne '127.0.0.1') { throw "API слушает не только 127.0.0.1: $a" } }
    Write-OpsLog "API слушает только 127.0.0.1:$ApiPort" 'OK'
    $w = Test-OpsWorkerAlive $L 20 -DevTest:$DevTest
    if (-not $w.Ok) { throw "фоновые задачи (OptomstroyWorker): $($w.Reason) — журнал $($L.Logs)\worker" }
    Write-OpsLog "фоновые задачи: $($w.Reason)" 'OK'
    if ((Get-OpsAppServiceState $L 'OptomstroyBackup' -DevTest:$DevTest) -ne 'Running') { throw 'OptomstroyBackup не работает — журнал logs\backup' }
    Write-OpsLog 'OptomstroyBackup: работает (первая полная копия начинается сразу после запуска)' 'OK'

    # =========================================================================================================
    Start-Step 'Apache: файл виртуального хоста (подключение — отдельный шаг администратора)'
    $apacheOut = Join-Path $L.Config 'apache\optomstroy-pos.conf'
    $ad = $apacheDirEff
    $siteId = 'pos'
    if ($Contour -eq 'test') { $siteId = 'pos-test' }
    # Сначала во временный файл: уже существующий файл сайта (его мог сформировать администратор вручную
    # render-apache-conf.ps1 со своими путями сертификата и портом) без явных параметров не перезаписывается.
    $apacheNew = "$apacheOut.new"
    $code = Invoke-OpsScript (Join-Path $L.Current 'apache\render-apache-conf.ps1') @{ ServerName = $serverName; CertFile = $CertFile; KeyFile = $KeyFile; InstallRoot = $L.Root; ApiPort = $ApiPort; ListenPort = $ApacheListenPort; SiteId = $siteId; OutFile = $apacheNew }
    if ($code -ne 0) { throw "render-apache-conf.ps1: код $code" }
    if (-not (Test-Path -LiteralPath $apacheOut)) {
        Move-Item -LiteralPath $apacheNew -Destination $apacheOut -Force
        Write-OpsLog "config\apache\optomstroy-pos.conf: создан (*:$ApacheListenPort, сертификат $CertFile)" 'OK'
    } elseif ([System.IO.File]::ReadAllText($apacheOut) -eq [System.IO.File]::ReadAllText($apacheNew)) {
        Remove-Item -LiteralPath $apacheNew -Force
        Write-OpsLog 'config\apache\optomstroy-pos.conf: без изменений'
    } elseif ($apacheExplicit) {
        Move-Item -LiteralPath $apacheNew -Destination $apacheOut -Force
        Write-OpsLog "config\apache\optomstroy-pos.conf: заменён по заданным -CertFile/-KeyFile/-ApacheListenPort (*:$ApacheListenPort). Подключённая в Apache копия прежняя — подключите заново (enable-apache-site.ps1, ниже)" 'WARN'
    } else {
        Write-OpsLog "config\apache\optomstroy-pos.conf отличается от того, что дал бы этот запуск, — оставлен как есть (вариант этого запуска: $apacheNew). Заменить: install.ps1 с -CertFile/-KeyFile/-ApacheListenPort или render-apache-conf.ps1" 'WARN'
    }
    $enableCmd = "& '$($L.Current)\apache\enable-apache-site.ps1' -ApacheDir '$ad' -SiteConf '$apacheOut'"
    if ($ApacheServiceName) { $enableCmd += " -ServiceName '$ApacheServiceName'" }
    [void]$summary.Add("Apache (администратор, в согласованное окно): проверка — $enableCmd ; затем то же с -Apply и перезапуск Apache (README, раздел «Apache»)")

    # =========================================================================================================
    Start-Step 'Первый администратор системы'
    if ($AdminPhone -and $AdminName) {
        $fa = @("--env-file=$(Join-Path $L.Config 'api.env')", 'dist\admin\bootstrap\first-admin.cli.js', '--phone', $AdminPhone, '--name', $AdminName)
        if ($AdminDays -gt 0) { $fa += @('--days', [string]$AdminDays) }
        $r = Invoke-OpsProcess -FilePath $nodeCur -ArgumentList $fa -WorkingDirectory (Join-Path $relReal 'api') -CleanEnvironment -Environment @{ APP_ENV = $appEnv; API_HOST = '127.0.0.1'; API_PORT = [string]$ApiPort }
        switch ($r.Code) {
            0 { Write-OpsLog 'приглашение администратора создано (вход — по SMS-коду, затем PIN)' 'OK' }
            3 { Write-OpsLog 'приглашение отклонено: номер занят или есть приглашение на другой номер (docs/ops/first_admin.md §6)' 'WARN' }
            2 { Write-OpsLog 'неверные данные приглашения (номер КР, ФИО 2…150 символов, срок 1…30)' 'WARN' }
            default { Write-OpsLog "ошибка создания приглашения (код $($r.Code)); повтор безопасен" 'WARN' }
        }
    } else {
        Write-OpsLog 'приглашение не создавалось; позже: scripts\first-admin.ps1 -Phone +996… -Name "…"'
    }

    $failed = $false
} catch {
    Write-OpsLog ("шаг «{0}»: {1}" -f $curStep, $_.Exception.Message) 'ERROR'
    Write-OpsLog 'установка остановлена; после исправления запустите install.ps1 с теми же параметрами — выполненные шаги не повторяются' 'ERROR'
} finally {
    if ($null -ne $swStep) { $timings[$curStep] = [math]::Round($swStep.Elapsed.TotalSeconds, 1) }
    if (-not $whatIf -and (Test-Path -LiteralPath $L.State)) {
        $cv = $null
        try { $cv = (Get-OpsReleaseInfo (Get-OpsJunctionTarget $L.Current)).version } catch { $cv = $null }
        if ($null -eq $state) { $state = @{} }
        if (-not $state.ContainsKey('installedUtc') -or -not $state.installedUtc) { $state.installedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        if (-not $state.ContainsKey('previousVersion')) { $state.previousVersion = $null }
        $state.currentVersion = $cv
        $state.devTest = [bool]$DevTest
        $state.lastOperation = 'install'
        $state.lastOperationStatus = $(if ($failed) { "failed: $curStep" } else { 'ok' })
        try {
            Save-OpsState $L $state
            Add-OpsReleasesLog $L ("install {0} {1} {2}" -f $Contour, $cv, $state.lastOperationStatus)
        } catch { Write-OpsLog "состояние не записано: $($_.Exception.Message)" 'WARN' }
    }
    Write-OpsLog 'Итог' 'STEP'
    foreach ($k in $timings.Keys) { Write-OpsLog ("{0}: {1} с" -f $k, $timings[$k]) }
    Write-OpsLog ("всего: {0} с" -f [math]::Round($swTotal.Elapsed.TotalSeconds, 1))
    foreach ($s in $skipped) { Write-OpsLog "пропущено (DevTest): $s" }
    if (-not $failed -and -not $whatIf) {
        Write-OpsLog "установлена версия $($state.currentVersion); API http://127.0.0.1:$ApiPort (только локально), PostgreSQL 127.0.0.1:$PgPort" 'OK'
        foreach ($s in $summary) { Write-OpsLog "дальше: $s" }
        Write-OpsLog 'дальше: состояние — scripts\status.ps1; резервные копии — infra\windows\backup\README.md (keygen у держателя ключа, проверка восстановления)'
    }
    Write-OpsLog "журнал: $script:OpsLogFile"
}
if ($failed) { exit 1 }
exit 0
