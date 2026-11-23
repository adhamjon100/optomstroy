<#
.SYNOPSIS
  Остановка PostgreSQL Optomstroy и (по -Unregister) снятие службы OptomstroyPostgres. Данные НЕ удаляются.

.DESCRIPTION
  Без -DevTest (администратор): Stop-Service (служба останавливает сервер режимом fast — с контрольной точкой),
  с -Unregister — затем pg_ctl unregister. Перед остановкой PostgreSQL останавливаются службы, которые от него
  зависят (OptomstroyApi, OptomstroyWorker, OptomstroyBackup) — Stop-Service -Force делает это сам.
  С -DevTest: pg_ctl stop -m fast по -DataDir (сервер, запущенный init-postgres.ps1 -DevTest).
  Каталог данных, журналы и архив WAL остаются на месте; удаление — только вручную и только после проверенной
  резервной копии (README, раздел «Откат»).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgBin,
    [string]$InstallRoot = 'D:\Optomstroy',
    [string]$DataDir = '',
    [string]$ServiceName = 'OptomstroyPostgres',
    [switch]$Unregister,
    [switch]$DevTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pg-common.ps1')
if ($DataDir -eq '') { $DataDir = Join-Path $InstallRoot 'data\pg' }
$pgctl = Join-Path $PgBin 'pg_ctl.exe'
if (-not (Test-Path -LiteralPath $pgctl)) { throw "Нет pg_ctl.exe в $PgBin" }
$tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ('optomstroy-pgstop-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    if ($DevTest) {
        if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'postmaster.pid'))) {
            Write-PgStep "DevTest: сервер не запущен ($DataDir)"
        } else {
            Write-PgStep "DevTest: pg_ctl stop -m fast ($DataDir)"
            $code = Invoke-PgNative -FilePath $pgctl -OutDir $tmpOut -ArgumentList @('stop', '-D', $DataDir, '-m', 'fast', '-w', '-t', '90')
            if ($code -ne 0) { throw "pg_ctl stop завершился с кодом $code" }
        }
        return
    }
    if (-not (Test-IsAdministrator)) { throw 'Нужны права администратора (или -DevTest)' }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-PgStep "Службы $ServiceName нет"
        return
    }
    if ($svc.Status -ne 'Stopped') {
        Write-PgStep "Stop-Service $ServiceName (и зависимые службы)"
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
    }
    if ($Unregister) {
        Write-PgStep "pg_ctl unregister -N $ServiceName (данные остаются в $DataDir)"
        $code = Invoke-PgNative -FilePath $pgctl -OutDir $tmpOut -ArgumentList @('unregister', '-N', $ServiceName)
        if ($code -ne 0) { throw "pg_ctl unregister завершился с кодом $code" }
    }
} finally {
    Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
}
Write-PgStep 'Готово.'
