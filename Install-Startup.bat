@echo off
rem ---------------------------------------------------------------------------
rem  Adds MonitorControls.ahk to your Windows startup folder so the hotkeys
rem  are live after every login. Run again to refresh; delete the shortcut in
rem  shell:startup to undo.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "$startup=[Environment]::GetFolderPath('Startup');" ^
 "$lnk=Join-Path $startup 'MonitorControls.lnk';" ^
 "$w=New-Object -ComObject WScript.Shell;" ^
 "$s=$w.CreateShortcut($lnk);" ^
 "$s.TargetPath=(Join-Path '%~dp0' 'MonitorControls.ahk');" ^
 "$s.WorkingDirectory='%~dp0';" ^
 "$s.Description='MonitorControls hotkeys';" ^
 "$s.Save();" ^
 "Write-Host ('Created: ' + $lnk) -ForegroundColor Green"
echo.
pause
