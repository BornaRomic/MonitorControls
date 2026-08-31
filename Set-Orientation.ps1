<#
.SYNOPSIS
    Rotates one monitor between landscape and portrait.

.DESCRIPTION
    Screen rotation is a Windows display setting, not a monitor setting, so this
    script does not go through ControlMyMonitor - it calls the Windows display
    API directly. Nothing extra to install, no admin rights.

    By default it targets whichever monitor is named in [Options] RotateTarget
    in config.ini (set to Right out of the box).

.PARAMETER Orientation
    Landscape (default), Portrait, LandscapeFlipped, PortraitFlipped, or Toggle
    to flip between landscape and portrait.

.PARAMETER Only
    A monitor name from config.ini, e.g. Left or Right. Overrides RotateTarget.

.PARAMETER Device
    A raw Windows display name such as "\\.\DISPLAY2", bypassing config.ini.

.EXAMPLE
    .\Set-Orientation.ps1
    Puts the configured monitor back into landscape.

.EXAMPLE
    .\Set-Orientation.ps1 -Orientation Portrait
.EXAMPLE
    .\Set-Orientation.ps1 -Orientation Toggle -Only Left
.EXAMPLE
    .\Set-Orientation.ps1 -List
    Shows every display, its current orientation, and which config entry it maps
    to - use this to work out which one Windows thinks is on the right.
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply', Position = 0)]
    [ValidateSet('Landscape', 'Portrait', 'LandscapeFlipped', 'PortraitFlipped', 'Toggle')]
    [string]$Orientation = 'Landscape',

    [Parameter(ParameterSetName = 'Apply')]
    [string]$Only,

    [Parameter(ParameterSetName = 'Apply')]
    [string]$Device,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Display.ps1')

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini

# Map each configured monitor to whatever \\.\DISPLAYn it is on RIGHT NOW.
# Resolved every run from the panel's EDID hardware id, because Windows
# renumbers \\.\DISPLAYn across reboots.
$byDevice = @{}
foreach ($m in $plan) {
    if ($m.Type -eq 'Internal' -and -not $m.Key) { continue }
    $dev = Resolve-DisplayDevice -Key $m.Key -FallbackId $m.Id
    if ($dev) { $byDevice[$dev] = $m }
}

if ($List) {
    try { $displays = Get-DisplayList }
    catch {
        Write-Bad ("Could not query the Windows display API: {0}" -f $_.Exception.Message)
        exit 1
    }
    Write-Head 'Attached displays'
    foreach ($d in $displays) {
        $cfg = if ($byDevice.ContainsKey($d.DeviceName)) { $byDevice[$d.DeviceName] } else { $null }
        Write-Info ''
        Write-Info ("  {0}{1}" -f $d.DeviceName, $(if ($d.IsPrimary) { '   [primary]' } else { '' }))
        Write-Info ("     adapter     : {0}" -f $d.Description)
        Write-Info ("     monitor     : {0}" -f $(if ($d.MonitorName) { $d.MonitorName } else { 'unknown' }))
        Write-Info ("     hardware id : {0}   <- stable across reboots" -f $d.MonitorKey)
        Write-Info ("     resolution  : {0} x {1}" -f $d.Width, $d.Height)
        Write-Info ("     orientation : {0}" -f (Get-OrientationName $d.Orientation))
        Write-Info ("     desktop pos : x={0}, y={1}" -f $d.PositionX, $d.PositionY)
        if ($cfg) {
            Write-Good ("     config entry: {0}  ({1})" -f $cfg.Name, $cfg.Label)
        } else {
            Write-Warn2  '     config entry: none - not listed in config.ini'
            Write-Warn2 ("                   add  MonitorKey={0}  to a [Monitor.*] section" -f $d.MonitorKey)
        }
    }
    Write-Info ''
    Write-Info 'The display with the largest desktop pos x is your right-hand screen.'
    Write-Info 'Config entries are bound to the hardware id, not to \\.\DISPLAYn, so these'
    Write-Info 'mappings stay correct even when Windows renumbers the displays at boot.'
    return
}

# --- Work out which display to rotate -------------------------------------
$targetDevice = $null
$targetLabel  = $null

if ($Device) {
    $targetDevice = $Device
    $targetLabel  = $Device
} else {
    $name = if ($Only) { $Only } else { Get-Ini $ini 'Options' 'RotateTarget' 'Right' }
    $m = $plan | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $m) {
        Write-Bad ("No monitor named '{0}' in config.ini. Configured names: {1}" -f $name, (($plan | ForEach-Object { $_.Name }) -join ', '))
        exit 1
    }
    if ($m.Type -eq 'Internal') {
        Write-Bad ("'{0}' is the built-in laptop panel. Rotating it works, but it is not what you asked for - pass -Only <name> or -Device to pick another." -f $name)
        exit 1
    }
    $targetDevice = Resolve-DisplayDevice -Key $m.Key -FallbackId $m.Id
    $targetLabel  = ("{0} ({1})" -f $m.Name, $m.Label)
    if (-not $targetDevice) {
        Write-Bad ("'{0}' is not attached right now, or cannot be identified." -f $name)
        Write-Info ("Config file    : {0}" -f (Get-ConfigPath))
        Write-Info ("Looking for    : MonitorKey '{0}'" -f $m.Key)
        Write-Info ("Stale fallback : Id '{0}'" -f $m.Id)
        Write-Info ''
        Write-Info 'Hardware ids that ARE attached right now:'
        try {
            foreach ($d in (Get-DisplayList)) {
                Write-Info ("  {0,-10} {1,-22} {2} x {3}  at x={4}{5}" -f `
                    $d.MonitorKey, $(if ($d.MonitorName) { $d.MonitorName } else { $d.Description }), `
                    $d.Width, $d.Height, $d.PositionX, $(if ($d.IsPrimary) { '  [primary]' } else { '' }))
            }
        } catch {
            Write-Warn2 ("  (could not enumerate displays: {0})" -f $_.Exception.Message)
        }
        Write-Info ''
        Write-Info 'If the monitor is listed above, set MonitorKey= to its id.'
        Write-Info 'If it is NOT listed, Windows does not currently see it: check the cable,'
        Write-Info 'and check the monitor is showing THIS machine on its input selector -'
        Write-Info 'a monitor switched to another input often drops off the GPU entirely.'
        Write-Info ''
        Write-Info 'Moved this folder between machines? Run 1-Detect.bat here to generate'
        Write-Info ("a config for this machine ({0}); the scripts prefer it automatically." -f $env:COMPUTERNAME)
        exit 1
    }
}

try { $current = [MonitorControls.Display]::GetOrientation($targetDevice) }
catch {
    Write-Bad ("Could not query the Windows display API: {0}" -f $_.Exception.Message)
    exit 1
}
if ($current -lt 0) {
    Write-Bad ("Could not read the current settings for {0}." -f $targetDevice)
    Write-Info 'Run  .\Set-Orientation.ps1 -List  to see which display names actually exist.'
    exit 1
}

$wanted = if ($Orientation -eq 'Toggle') {
    if (($current % 2) -eq 0) { 1 } else { 0 }
} else {
    $script:Orientations[$Orientation]
}

if ($current -eq $wanted) {
    Write-Info ("{0} is already {1} - nothing to do." -f $targetLabel, (Get-OrientationName $wanted))
    return
}

try { $code = [MonitorControls.Display]::SetOrientation($targetDevice, $wanted) }
catch {
    Write-Bad ("The rotation call failed: {0}" -f $_.Exception.Message)
    exit 1
}

if ($code -eq 0) {
    Write-Good ("{0} [{1}]: {2} -> {3}" -f $targetLabel, $targetDevice, (Get-OrientationName $current), (Get-OrientationName $wanted))
} elseif ($code -eq 1) {
    Write-Warn2 ("{0}: {1}" -f $targetLabel, (Get-DispChangeMessage $code))
} else {
    Write-Bad ("{0}: {1}" -f $targetLabel, (Get-DispChangeMessage $code))
    if ($code -eq -2) {
        Write-Info 'This usually means the display is running a mode that has no rotated equivalent.'
        Write-Info 'Try setting the resolution back to the recommended one and run this again.'
    }
    exit 1
}
