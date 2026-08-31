<#
.SYNOPSIS
    Dims a monitor BELOW its hardware minimum, using the GPU's gamma ramp.

.DESCRIPTION
    DDC/CI can only go down to the panel's own brightness 0. On monitors with a
    high backlight floor - the Philips Evnia is a well-known example - that is
    still too bright for a dark room. This attenuates the signal on the GPU
    instead, which is the same thing the NVIDIA Control Panel's brightness and
    gamma sliders do, except it is a plain Windows API and needs no vendor
    software.

    Stacks on top of the monitor's own brightness: set the panel to 0 first,
    then take the rest off here.

.PARAMETER Level
    Output level, 0.05 to 1.0. 1.0 is untouched, 0.45 is a good dark-room
    starting point once the monitor itself is already at 0.

.PARAMETER Gamma
    Above 1.0 lifts midtones, so text stays legible while whites dim. 1.1 - 1.2
    pairs well with a low Level for reading code.

.PARAMETER Warmth
    0 to 1. Pulls blue down - like Night Light, but it does not fight with the
    brightness setting. 0.3 - 0.4 is a mild, non-orange warm.

.PARAMETER Only
    Monitor names from config.ini. Default: every configured external monitor.

.PARAMETER Reset
    Put the ramp back to normal.

.PARAMETER Status
    Show what the ramps currently look like, and whether Windows is clamping.

.PARAMETER EnableDeepDim
    Raise the Windows gamma clamp so very dark ramps are allowed. Writes
    HKLM\...\ICM\GdiIcmGammaRange = 256. Needs an admin window, and a sign-out
    to take effect.

.EXAMPLE
    .\Set-SoftDim.ps1 -Level 0.45 -Gamma 1.15 -Warmth 0.35
.EXAMPLE
    .\Set-SoftDim.ps1 -Reset
.EXAMPLE
    .\Set-SoftDim.ps1 -Status
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply', Position = 0)]
    [ValidateRange(0.05, 1.0)]
    [double]$Level = 0.45,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0.3, 3.0)]
    [double]$Gamma = 1.0,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0.0, 1.0)]
    [double]$Warmth = 0.0,

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$Only,

    [Parameter(ParameterSetName = 'Reset')]
    [switch]$Reset,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Enable')]
    [switch]$EnableDeepDim
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Display.ps1')
. (Join-Path $PSScriptRoot 'lib\Gamma.ps1')

if ($EnableDeepDim) {
    Write-Head 'Raising the Windows gamma clamp'
    Write-Info 'Windows limits how far a gamma ramp may deviate, so a program cannot'
    Write-Info 'black out the screen. That limit is what stops very dark settings.'
    Write-Info ''
    try {
        $v = Enable-DeepDim
        Write-Good ("Set HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM\GdiIcmGammaRange = {0}" -f $v)
        Write-Warn2 'Sign out and back in for this to take effect.'
    } catch {
        Write-Bad $_.Exception.Message
        exit 1
    }
    return
}

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini

$targets = @()
foreach ($m in $plan) {
    if ($m.Type -eq 'Internal' -and -not $m.Key) { continue }
    if ($Only -and ($Only -notcontains $m.Name)) { continue }
    $dev = Resolve-DisplayDevice -Key $m.Key -FallbackId $m.Id
    if ($dev) { $targets += [pscustomobject]@{ Name = $m.Name; Label = $m.Label; Device = $dev } }
}

if ($targets.Count -eq 0) {
    Write-Warn2 'No configured monitors are attached right now.'
    exit 1
}

if ($Status) {
    Write-Head 'Current gamma ramps'
    foreach ($t in $targets) {
        $r = [MonitorControls.Gamma]::Read($t.Device)
        if (-not $r) { Write-Warn2 ("  {0}: could not read" -f $t.Name); continue }
        $white = $r[255] / 65535.0
        Write-Info ("  {0,-8} {1,-22} output at white: {2:P0}{3}" -f `
            $t.Name, $t.Label, $white, $(if ($white -gt 0.98) { '   (normal)' } else { '   (dimmed)' }))
    }
    $limit = Get-GammaRangeLimit
    Write-Info ''
    if ($null -eq $limit) {
        Write-Info 'Gamma clamp   : Windows default (deep dimming may be refused).'
        Write-Info '                Run  .\Set-SoftDim.ps1 -EnableDeepDim  from an admin'
        Write-Info '                window if a low -Level does not go as dark as asked.'
    } else {
        Write-Info ("Gamma clamp   : GdiIcmGammaRange = {0}{1}" -f $limit, $(if ($limit -ge 256) { ' (unrestricted)' } else { ' (still limited)' }))
    }
    return
}

foreach ($t in $targets) {
    if ($Reset) {
        $res = Reset-GammaRamp -DeviceName $t.Device
        if ($res.Applied) { Write-Good ("{0}: back to normal" -f $t.Name) }
        else              { Write-Bad  ("{0}: {1}" -f $t.Name, $res.Reason) }
        continue
    }

    $ramp = New-GammaRamp -Brightness $Level -Gamma $Gamma -Warmth $Warmth
    $res  = Set-GammaRamp -DeviceName $t.Device -Ramp $ramp

    if (-not $res.Applied) {
        Write-Bad ("{0}: {1}" -f $t.Name, $res.Reason)
        continue
    }
    if ($res.Clamped) {
        Write-Warn2 ("{0}: {1}" -f $t.Name, $res.Reason)
        Write-Info  '        Run  .\Set-SoftDim.ps1 -EnableDeepDim  from an admin window,'
        Write-Info  '        sign out and back in, then try again.'
        continue
    }
    Write-Good ("{0,-8} {1,-22} -> {2:P0} output, gamma {3}, warmth {4}" -f `
        $t.Name, $t.Label, $Level, $Gamma, $Warmth)
}