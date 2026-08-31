<#
.SYNOPSIS
    Blanks or wakes the external monitors via DDC/CI power mode (VCP D6),
    without putting the PC itself to sleep.

.DESCRIPTION
    VCP D6 values:  1 = on,  2 = standby,  3 = suspend,  4 = off,  5 = off (hard)

    Caveat worth knowing: plenty of monitors accept "off" happily but ignore
    "on" afterwards, because their DDC controller is asleep too. If -State On
    does nothing on your panels, use Windows' own wake (move the mouse) or the
    monitor's power button. -State Standby is usually more reliable to recover
    from than -State Off.

.EXAMPLE
    .\Set-Power.ps1 -State Off
.EXAMPLE
    .\Set-Power.ps1 -State On
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('On', 'Standby', 'Off', 'Toggle')]
    [string]$State = 'Toggle',

    [string[]]$Only
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini
$exe  = Resolve-ControlMyMonitor -Configured (Get-Ini $ini 'Paths' 'ControlMyMonitor' '')
if (-not $exe) { Write-Bad 'ControlMyMonitor.exe not found - check [Paths] in config.ini.'; exit 1 }

$map = @{ On = 1; Standby = 4; Off = 4 }
$done = @()

foreach ($m in $plan) {
    if ($m.Type -eq 'Internal') { continue }
    if ($Only -and ($Only -notcontains $m.Name)) { continue }
    $target = Get-CmmTarget $m
    if (-not $target) { continue }

    if ($State -eq 'Toggle') {
        Invoke-CMM -Exe $exe -Arguments @('/SwitchValue', $target, $script:VCP.Power, '1', '4') | Out-Null
        $done += ("{0} toggled" -f $m.Name)
    } else {
        $v = if ($State -eq 'Standby') { 4 } else { $map[$State] }
        Set-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Power -Value $v -Force
        $done += ("{0} -> {1}" -f $m.Name, $State)
    }
}

if ($done.Count -gt 0) { Write-Good ($done -join '   |   ') } else { Write-Warn2 'No external monitors matched.' }
