@echo off
rem Optomstroy POS demo launcher (double-click). Arguments go to start-demo.ps1, e.g.: start-demo.cmd -Smoke
setlocal
chcp 65001 >nul
title Optomstroy POS demo
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-demo.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
