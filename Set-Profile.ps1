<#
.SYNOPSIS
    Applies a named brightness/contrast profile to all configured monitors.

.EXAMPLE
    .\Set-Profile.ps1 -Name Night
.EXAMPLE
    .\Set-Profile.ps1 -List
.EXAMPLE
    .\Set-Profile.ps1 -Name Day -Only Left,Right
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply', Position = 0)]
    [string]$Name,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    # Restrict to specific monitor names from config.ini
    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$Only,

    # Used by the hotkey script: skip the DDC/CI monitors (which it drives
    # itself, directly and instantly) and do only the parts that need
    # PowerShell - the internal laptop panel and the GPU gamma ramps.
    [Parameter(ParameterSetName = 'Apply')]
    [Alias('InternalOnly')]
    [switch]$NonDdcOnly,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$ExternalOnly,

    # Send the value even if the monitor already reports it
    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Display.ps1')
. (Join-Path $PSScriptRoot 'lib\Gamma.ps1')

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini

$profileNames = @($ini.Keys | Where-Object { $_ -like 'Profile.*' } | ForEach-Object { $_.Substring(8) })

if ($List -or -not $Name) {
    Write-Head 'Available profiles'
    foreach ($p in $profileNames) {
        Write-Info ("  {0}" -f $p)
        foreach ($k in $ini["Profile.$p"].Keys) {
            Write-Info ("      {0,-10} {1}" -f $k, $ini["Profile.$p"][$k])
        }
    }
    Write-Head 'Current levels'
    $exe = Resolve-ControlMyMonitor -Configured (Get-Ini $ini 'Paths' 'ControlMyMonitor' '')
    foreach ($m in $plan) {
        if ($m.Type -eq 'Internal') {
            $v = Get-InternalBrightness
            Write-Info ("  {0,-10} {1}" -f $m.Name, $(if ($null -ne $v) { "$v%" } else { 'unknown' }))
        } elseif ($exe) {
            $v = Get-MonitorVcp -Exe $exe -MonitorId (Get-CmmTarget $m) -Code $script:VCP.Brightness
            Write-Info ("  {0,-10} {1}" -f $m.Name, $v)
        }
    }
    Write-Info ''
    Write-Info 'Usage: .\Set-Profile.ps1 -Name <profile>'
    return
}

$section = "Profile.$Name"
if (-not $ini.Contains($section)) {
    Write-Bad ("No profile named '{0}'. Known profiles: {1}" -f $Name, ($profileNames -join ', '))
    exit 1
}

$exe = Resolve-ControlMyMonitor -Configured (Get-Ini $ini 'Paths' 'ControlMyMonitor' '')
$applied = @()

foreach ($m in $plan) {
    if ($Only -and ($Only -notcontains $m.Name)) { continue }
    if ($NonDdcOnly -and $m.Type -ne 'Internal') { continue }
    if ($ExternalOnly -and $m.Type -eq 'Internal') { continue }
    if (-not $ini[$section].Contains($m.Name)) { continue }

    $vals = Split-ProfileValue $ini[$section][$m.Name]
    if ($null -eq $vals.Brightness) { continue }

    if ($m.Type -eq 'Internal') {
        try {
            Set-InternalBrightness -Percent $vals.Brightness
            $applied += ("{0} -> {1}%" -f $m.Name, $vals.Brightness)
        } catch {
            Write-Warn2 ("{0}: could not set brightness via WMI ({1})" -f $m.Name, $_.Exception.Message)
        }
        continue
    }

    if (-not $exe) { Write-Bad 'ControlMyMonitor.exe not found - check [Paths] in config.ini.'; exit 1 }
    if (-not (Get-CmmTarget $m)) { Write-Warn2 ("{0}: no MonitorKey, Serial or Id in config.ini, skipping." -f $m.Name); continue }

    $target = Get-CmmTarget $m
    Set-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Brightness -Value $vals.Brightness -Force:$Force
    $msg = ("{0} -> {1}" -f $m.Name, $vals.Brightness)
    if ($null -ne $vals.Contrast) {
        Set-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Contrast -Value $vals.Contrast -Force:$Force
        $msg += (" / contrast {0}" -f $vals.Contrast)
    }
    $applied += $msg
}

# ---------------------------------------------------------------------------
#  GPU-level attenuation, from the optional [Soft.<profile>] section.
#
#  This is what gets a monitor below its own brightness 0. Crucially, a profile
#  WITHOUT a [Soft.*] section resets the ramps - otherwise switching from a
#  dimmed profile back to Day would leave the screen dark.
# ---------------------------------------------------------------------------
if (-not $ExternalOnly) {
    $softSection = "Soft.$Name"
    $hasSoft     = $ini.Contains($softSection)

    foreach ($m in $plan) {
        if ($Only -and ($Only -notcontains $m.Name)) { continue }

        $dev = Resolve-DisplayDevice -Key $m.Key -FallbackId $m.Id
        if (-not $dev) { continue }

        if ($hasSoft -and $ini[$softSection].Contains($m.Name)) {
            $sv = Split-SoftValue $ini[$softSection][$m.Name]
            if ($null -eq $sv.Brightness) { continue }
            $ramp = New-GammaRamp -Brightness $sv.Brightness -Gamma $sv.Gamma -Warmth $sv.Warmth
            $res  = Set-GammaRamp -DeviceName $dev -Ramp $ramp
            if ($res.Clamped) {
                Write-Warn2 ("{0}: {1}" -f $m.Name, $res.Reason)
                Write-Info  '        Run  .\Set-SoftDim.ps1 -EnableDeepDim  from an admin window.'
            } elseif (-not $res.Applied) {
                Write-Warn2 ("{0}: {1}" -f $m.Name, $res.Reason)
            } else {
                $applied += ("{0} dim {1:P0}" -f $m.Name, $sv.Brightness)
            }
        } else {
            # No soft entry for this monitor in this profile - clear any ramp
            # a previous profile left behind.
            $cur = [MonitorControls.Gamma]::Read($dev)
            if ($cur -and $cur[255] -lt 64000) {
                Reset-GammaRamp -DeviceName $dev | Out-Null
                $applied += ("{0} dim off" -f $m.Name)
            }
        }
    }
}

if ($applied.Count -eq 0) {
    Write-Warn2 ("Profile '{0}' matched no monitors." -f $Name)
} else {
    Write-Good ("Profile '{0}': {1}" -f $Name, ($applied -join '   |   '))
}
