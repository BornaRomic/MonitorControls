<#
.SYNOPSIS
    Switches the external monitors' input source, e.g. between the desktop PC
    and the laptop.

.DESCRIPTION
    Reads InputPC / InputLaptop from each [Monitor.*] section in config.ini.
    The built-in laptop panel is skipped (it has no selectable input).

    IMPORTANT: if you run this from the PC and switch to Laptop, the PC loses
    its picture. The AutoHotkey hotkeys keep working blind, so Ctrl+Alt+P will
    still bring the monitors back - but the switch back has to be triggered
    from whichever machine is now driving the keyboard.

.EXAMPLE
    .\Set-Input.ps1 -Target Laptop
.EXAMPLE
    .\Set-Input.ps1 -Target PC -Only Left
.EXAMPLE
    .\Set-Input.ps1 -Toggle
#>
[CmdletBinding(DefaultParameterSetName = 'Target')]
param(
    [Parameter(ParameterSetName = 'Target', Position = 0)]
    [ValidateSet('PC', 'Laptop')]
    [string]$Target,

    # Flip each monitor between its InputPC and InputLaptop values
    [Parameter(ParameterSetName = 'Toggle')]
    [switch]$Toggle,

    [string[]]$Only,

    # Show what would happen without changing anything
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini
$exe  = Resolve-ControlMyMonitor -Configured (Get-Ini $ini 'Paths' 'ControlMyMonitor' '')

if (-not $exe) { Write-Bad 'ControlMyMonitor.exe not found - check [Paths] in config.ini.'; exit 1 }
if (-not $Target -and -not $Toggle) {
    Write-Head 'Current inputs'
    foreach ($m in $plan) {
        if ($m.Type -eq 'Internal') { continue }
        $v = Get-MonitorVcp -Exe $exe -MonitorId (Get-CmmTarget $m) -Code $script:VCP.InputSource
        Write-Info ("  {0,-8} {1,4}  ({2})" -f $m.Name, $v, (Get-InputFriendlyName $v))
        Write-Info ("           configured: PC={0}  Laptop={1}" -f $m.InputPC, $m.InputLaptop)
    }
    Write-Info ''
    Write-Info 'Usage: .\Set-Input.ps1 -Target PC   |   -Target Laptop   |   -Toggle'
    return
}

$delay = [int](Get-Ini $ini 'Options' 'InputSwitchDelay' 250)
$done  = @()

foreach ($m in $plan) {
    if ($m.Type -eq 'Internal') { continue }
    if ($Only -and ($Only -notcontains $m.Name)) { continue }
    $target = Get-CmmTarget $m
    if (-not $target) { Write-Warn2 ("{0}: no MonitorKey, Serial or Id in config.ini, skipping." -f $m.Name); continue }

    $pcVal  = $m.InputPC
    $lapVal = $m.InputLaptop

    $wanted = $null
    if ($Toggle) {
        if (-not $pcVal -or -not $lapVal) {
            Write-Warn2 ("{0}: needs both InputPC and InputLaptop for -Toggle, skipping." -f $m.Name)
            continue
        }
        $cur = Get-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.InputSource
        $wanted = if ("$cur" -eq "$pcVal") { $lapVal } else { $pcVal }
    } else {
        $wanted = if ($Target -eq 'PC') { $pcVal } else { $lapVal }
    }

    if (-not $wanted -or "$wanted" -notmatch '^\d+$') {
        Write-Warn2 ("{0}: no valid input value configured for '{1}'. Fill in Input{1} under [{2}] in config.ini." -f $m.Name, $(if ($Toggle) { 'Toggle' } else { $Target }), $m.Section)
        continue
    }

    $label = ("{0} -> {1} ({2})" -f $m.Name, $wanted, (Get-InputFriendlyName $wanted))
    if ($WhatIfOnly) {
        Write-Info ("would set: {0}" -f $label)
        continue
    }

    Set-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.InputSource -Value ([int]$wanted) -Force
    $done += $label
    if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
}

if ($done.Count -gt 0) { Write-Good ("Input switched: {0}" -f ($done -join '   |   ')) }
elseif (-not $WhatIfOnly) { Write-Warn2 'Nothing was switched.' }
