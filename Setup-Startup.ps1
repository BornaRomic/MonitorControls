<#
.SYNOPSIS
    Registers a Windows scheduled task that starts the MonitorControls hotkeys
    at logon - pointing at AutoHotkey.exe, which is the part that matters.

.DESCRIPTION
    Task Scheduler's "Program/script" box runs CreateProcess, which only starts
    real executables. It does NOT follow file associations the way a double-click
    does, so putting MonitorControls.ahk in that box silently launches nothing
    and the task sits at "Ready" with Last Run Result 0x2.

    The fix is to run the AutoHotkey interpreter and pass the script as an
    argument. This script finds AutoHotkey v2, builds the task correctly, and
    verifies it.

    Two other things this gets right that are easy to miss:
      * The trigger is AT LOGON, not at startup. A task triggered "at system
        startup" runs in session 0 before anyone logs in - there is no desktop
        and no input queue, so global hotkeys cannot work.
      * The execution time limit is removed. The default is 3 days, after which
        Task Scheduler would kill a permanently-running script.

.PARAMETER Elevated
    Register the task to run with highest privileges, so the hotkeys keep
    working while an administrator window has focus. Requires running this
    script as administrator.

.PARAMETER DelaySeconds
    Wait this long after logon before starting (default 15). Gives the display
    drivers time to bring the monitors up before the script reads config.

.PARAMETER Remove
    Delete the task.

.PARAMETER AhkPath
    Full path to AutoHotkey64.exe, if auto-detection fails.

.EXAMPLE
    .\Setup-Startup.ps1
.EXAMPLE
    .\Setup-Startup.ps1 -Elevated        # run this one as administrator
.EXAMPLE
    .\Setup-Startup.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Elevated,
    [int]$DelaySeconds = 15,
    [switch]$Remove,
    [string]$AhkPath,
    [string]$TaskName = 'MonitorControls Hotkeys'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$ScriptFile = Join-Path $PSScriptRoot 'MonitorControls.ahk'

# ---------------------------------------------------------------------------
if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Warn2 ("No scheduled task named '{0}' exists." -f $TaskName)
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Good ("Removed scheduled task '{0}'." -f $TaskName)
    return
}

Write-Head '=== 1. Checking the script ==='
if (-not (Test-Path -LiteralPath $ScriptFile)) {
    Write-Bad ("MonitorControls.ahk not found next to this script ({0})." -f $PSScriptRoot)
    exit 1
}
Write-Good ("Found: {0}" -f $ScriptFile)

# ---------------------------------------------------------------------------
Write-Head '=== 2. Locating AutoHotkey v2 ==='

function Find-AutoHotkey {
    param([string]$Configured)

    $candidates = New-Object System.Collections.ArrayList
    if ($Configured) { [void]$candidates.Add($Configured) }

    foreach ($p in @(
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey32.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey32.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey32.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\AutoHotkey64.exe"
    )) { [void]$candidates.Add($p) }

    # Whatever the shell uses to open .ahk files
    try {
        $cmd = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\AutoHotkeyScript\Shell\Open\Command' -ErrorAction Stop).'(default)'
        if ($cmd -match '"([^"]+\.exe)"') { [void]$candidates.Add($Matches[1]) }
    } catch { }

    try {
        $dir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\AutoHotkey' -ErrorAction Stop).InstallDir
        if ($dir) {
            foreach ($p in @("$dir\v2\AutoHotkey64.exe", "$dir\AutoHotkey64.exe", "$dir\v2\AutoHotkey32.exe")) {
                [void]$candidates.Add($p)
            }
        }
    } catch { }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

$ahk = Find-AutoHotkey -Configured $AhkPath
if (-not $ahk) {
    Write-Bad 'Could not find AutoHotkey.'
    Write-Info ''
    Write-Info 'Install AutoHotkey v2 from https://www.autohotkey.com/ , or if it is'
    Write-Info 'already installed somewhere unusual, pass the path:'
    Write-Info '   .\Setup-Startup.ps1 -AhkPath "C:\path\to\AutoHotkey64.exe"'
    exit 1
}

$ver = ''
try { $ver = (Get-Item -LiteralPath $ahk).VersionInfo.FileVersion } catch { }
Write-Good ("Found: {0}" -f $ahk)
if ($ver) { Write-Info ("Version: {0}" -f $ver) }

if ($ver -and $ver -notmatch '^\s*2\.') {
    Write-Warn2 ''
    Write-Warn2 'That looks like AutoHotkey v1, but MonitorControls.ahk is a v2 script.'
    Write-Warn2 'It will fail to start. Install v2 and re-run, or pass -AhkPath pointing'
    Write-Warn2 'at the v2 interpreter (v1 and v2 can be installed side by side).'
}

# ---------------------------------------------------------------------------
Write-Head '=== 3. Registering the task ==='

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Elevated -and -not $isAdmin) {
    Write-Bad '-Elevated needs this window to be running as administrator.'
    Write-Info 'Right-click PowerShell, "Run as administrator", then run this again.'
    exit 1
}

$action = New-ScheduledTaskAction -Execute $ahk -Argument ('"{0}"' -f $ScriptFile) -WorkingDirectory $PSScriptRoot

# At logon, NOT at startup: a startup task runs in session 0 with no desktop,
# where global hotkeys cannot exist.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
if ($DelaySeconds -gt 0) { $trigger.Delay = ('PT{0}S' -f $DelaySeconds) }

# ExecutionTimeLimit 0 = never kill it. The default 3-day limit would stop a
# script that is meant to run forever.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
    -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive `
    -RunLevel $(if ($Elevated) { 'Highest' } else { 'Limited' })

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force `
        -Description 'Starts the MonitorControls AutoHotkey hotkeys at logon.' | Out-Null
} catch {
    Write-Bad ("Could not register the task: {0}" -f $_.Exception.Message)
    Write-Info 'If this says access denied, run PowerShell as administrator and try again.'
    exit 1
}

Write-Good ("Registered '{0}'." -f $TaskName)
Write-Info ''
Write-Info ("  Program/script : {0}" -f $ahk)
Write-Info ("  Arguments      : `"{0}`"" -f $ScriptFile)
Write-Info ("  Start in       : {0}" -f $PSScriptRoot)
Write-Info ("  Trigger        : At log on of {0}\{1}, delayed {2}s" -f $env:USERDOMAIN, $env:USERNAME, $DelaySeconds)
Write-Info ("  Run level      : {0}" -f $(if ($Elevated) { 'Highest (works over admin windows)' } else { 'Normal' }))

# ---------------------------------------------------------------------------
Write-Head '=== 4. Testing it now ==='
try {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $proc = Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Good ("AutoHotkey is running (PID {0}). Look for the tray icon." -f ($proc.Id -join ', '))
        Write-Info 'Try Ctrl+Alt+1 to confirm the hotkeys are live.'
    } else {
        Write-Warn2 'The task ran but no AutoHotkey process is visible.'
        Write-Warn2 'Open the script by double-clicking MonitorControls.ahk to see any error it reports.'
    }
} catch {
    Write-Warn2 ("Could not start the task for testing: {0}" -f $_.Exception.Message)
}

Write-Info ''
Write-Info 'To undo:  .\Setup-Startup.ps1 -Remove'
