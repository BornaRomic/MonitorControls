@echo off
rem ---------------------------------------------------------------------------
rem  Diagnostics. Run this when a hotkey seems to do nothing - it shows the
rem  errors that the hidden hotkey windows swallow.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"
echo ============================================================
echo  DISPLAYS AND ORIENTATION
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Orientation.ps1" -List
echo.
echo ============================================================
echo  PROFILES AND CURRENT BRIGHTNESS
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Profile.ps1" -List
echo.
echo ============================================================
echo  CONFIGURED INPUTS
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Input.ps1"
echo.
echo ============================================================
echo  ROTATION TEST (toggle, then toggle back)
echo ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Orientation.ps1" -Orientation Toggle
echo   exit code: %errorlevel%
echo.
echo Press a key to rotate back to landscape...
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Orientation.ps1" -Orientation Landscape
echo   exit code: %errorlevel%
echo.
pause
