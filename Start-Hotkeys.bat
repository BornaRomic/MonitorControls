@echo off
rem ---------------------------------------------------------------------------
rem  Silent launcher for the MonitorControls hotkeys.
rem
rem  Starts AutoHotkey with MonitorControls.ahk and exits immediately - no
rem  pause, no window left behind. Safe to use as a Startup-folder item or as
rem  a scheduled-task action.
rem
rem  NOTE: this is the file to run at every logon. 4-Startup-Task.bat is a
rem  ONE-TIME setup that registers the scheduled task; it does not need to run
rem  again at boot.
rem
rem  A .bat always shows a brief console flash. For zero flash, use the
rem  scheduled task (4-Startup-Task.bat, run once) which launches AutoHotkey
rem  directly with no console at all.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

rem Parentheses in this variable's NAME break a parenthesised FOR block,
rem so copy it out first.
set "PFX86=%ProgramFiles(x86)%"
set "AHK="

for %%P in (
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
  "%ProgramFiles%\AutoHotkey\v2\AutoHotkey32.exe"
  "%PFX86%\AutoHotkey\v2\AutoHotkey64.exe"
  "%PFX86%\AutoHotkey\v2\AutoHotkey32.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\v2\AutoHotkey32.exe"
  "%ProgramFiles%\AutoHotkey\AutoHotkey64.exe"
  "%LOCALAPPDATA%\Programs\AutoHotkey\AutoHotkey64.exe"
) do if not defined AHK if exist %%P set "AHK=%%~P"

if defined AHK (
    start "" "%AHK%" "%~dp0MonitorControls.ahk"
) else (
    rem No known install path - fall back to the file association, which is
    rem what a double-click uses.
    start "" "%~dp0MonitorControls.ahk"
)

exit /b 0
