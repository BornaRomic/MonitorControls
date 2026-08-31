<#
.SYNOPSIS
    Nudges brightness up or down on every configured monitor at once.

.EXAMPLE
    .\Adjust-Brightness.ps1 -Delta 10
.EXAMPLE
    .\Adjust-Brightness.ps1 -Delta -10 -InternalOnly
.EXAMPLE
    .\Adjust-Brightness.ps1 -Set 50
#>
[CmdletBinding(DefaultParameterSetName = 'Delta')]
param(
    [Parameter(ParameterSetName = 'Delta', Position = 0)]
    [int]$Delta = 10,

    # Set an absolute level on every monitor, ignoring profiles
    [Parameter(ParameterSetName = 'Set')]
    [ValidateRange(0, 100)]
    [int]$Set,

    [string[]]$Only,
    [switch]$InternalOnly,
    [switch]$ExternalOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$ini  = Read-IniFile (Get-ConfigPath)
$plan = Get-MonitorPlan $ini
$exe  = Resolve-ControlMyMonitor -Configured (Get-Ini $ini 'Paths' 'ControlMyMonitor' '')
$absolute = ($PSCmdlet.ParameterSetName -eq 'Set')
$done = @()

foreach ($m in $plan) {
    if ($Only -and ($Only -notcontains $m.Name)) { continue }
    if ($InternalOnly -and $m.Type -ne 'Internal') { continue }
    if ($ExternalOnly -and $m.Type -eq 'Internal') { continue }

    if ($m.Type -eq 'Internal') {
        $cur = Get-InternalBrightness
        $new = if ($absolute) { $Set } elseif ($null -ne $cur) { $cur + $Delta } else { 50 }
        if ($new -lt 0)   { $new = 0 }
        if ($new -gt 100) { $new = 100 }
        try {
            Set-InternalBrightness -Percent $new
            $done += ("{0} {1}%" -f $m.Name, $new)
        } catch {
            Write-Warn2 ("{0}: WMI brightness failed ({1})" -f $m.Name, $_.Exception.Message)
        }
        continue
    }

    $target = Get-CmmTarget $m
    if (-not $exe -or -not $target) { continue }
    if ($absolute) {
        Set-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Brightness -Value $Set
        $done += ("{0} {1}" -f $m.Name, $Set)
    } else {
        Step-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Brightness -Delta $Delta
        $now = Get-MonitorVcp -Exe $exe -MonitorId $target -Code $script:VCP.Brightness
        $done += ("{0} {1}" -f $m.Name, $now)
    }
}

if ($done.Count -gt 0) { Write-Good ($done -join '   |   ') } else { Write-Warn2 'No monitors matched.' }
