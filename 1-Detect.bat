@echo off
rem ---------------------------------------------------------------------------
rem  Step 1: detect monitors and generate config.ini
rem  Double-click this file. No admin rights needed.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Detect-Monitors.ps1" %*
echo.
pause
