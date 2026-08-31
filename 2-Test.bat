@echo off
rem ---------------------------------------------------------------------------
rem  Step 2: show every profile, every configured input, and the live values.
rem  Good sanity check after editing config.ini.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Profile.ps1" -List
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Input.ps1"
echo.
pause
