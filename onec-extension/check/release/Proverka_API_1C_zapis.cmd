@echo off
rem Proverka API 1C s ZAPISYU (--allow-write): tolko na TESTOVOJ kopii bazy.
rem Programma poprosit podtverzhdenie (imya publikacii) pered pervym zaprosom POST.
setlocal DisableDelayedExpansion
rem Nastrojki Node.js etogo kompyutera ne dolzhny menyat rabotu programmy.
set "NODE_OPTIONS="
set "NODE_TLS_REJECT_UNAUTHORIZED="
set "NODE_DEBUG="
set "NODE_EXTRA_CA_CERTS="
if not exist "%~dp0runtime\node.exe" goto net_fajlov
if not exist "%~dp0programma\main.mjs" goto net_fajlov
set "OLDCP="
for /f "tokens=2 delims=:." %%a in ('chcp') do set "OLDCP=%%a"
chcp 65001 >nul
"%~dp0runtime\node.exe" --use-system-ca "%~dp0programma\main.mjs" --allow-write %*
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
if defined OLDCP chcp %OLDCP% >nul
endlocal & exit /b %RC%

:net_fajlov
echo OSHIBKA: ryadom s etim fajlom net papok runtime i programma.
echo Raspakujte VES arhiv v obychnuyu papku: pravyj shchelchok po arhivu - "Izvlech vse".
echo Zatem zapustite Proverka_API_1C_zapis.cmd iz raspakovannoj papki. Iz okna arhiva programma ne rabotaet.
if "%~1"=="" pause
endlocal & exit /b 2
