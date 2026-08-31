@echo off
rem ---------------------------------------------------------------------------
rem  Registers a scheduled task that starts the hotkeys at logon, pointing at
rem  AutoHotkey.exe with the script as an argument (which is what Task
rem  Scheduler needs - it cannot launch a .ahk file directly).
rem
rem  Run this normally. To let the hotkeys work while an administrator window
rem  has focus, right-click this file and "Run as administrator" instead - it
rem  detects elevation and registers the task at highest privileges.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel%==0 (
    echo Running elevated - task will be registered with highest privileges.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Startup.ps1" -Elevated
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Startup.ps1"
)

rem Only hold the window open if something went wrong, so that an accidental
rem run at logon does not sit there waiting for a keypress.
if errorlevel 1 (
    echo.
    echo Setup reported a problem - see the messages above.
    pause
)
exit /b 0
