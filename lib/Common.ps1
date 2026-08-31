# ============================================================================
#  Common.ps1 - shared helpers for the MonitorControls toolkit
#  Dot-sourced by the other scripts. Not meant to be run on its own.
# ============================================================================

Set-StrictMode -Off

$script:LibRoot = $PSScriptRoot
$script:AppRoot = Split-Path -Parent $PSScriptRoot

# --- Well known VCP codes (hex, as ControlMyMonitor expects them) -----------
$script:VCP = @{
    Brightness  = '10'
    Contrast    = '12'
    InputSource = '60'
    Power       = 'D6'
    Volume      = '62'
    ColorPreset = '14'
}

# --- Decimal input-source values -> friendly names -------------------------
# ControlMyMonitor takes the VALUE in decimal even though the CODE is hex.
$script:InputNames = @{
    1   = 'VGA-1'
    2   = 'VGA-2'
    3   = 'DVI-1'
    4   = 'DVI-2'
    5   = 'Composite-1'
    6   = 'Composite-2'
    7   = 'S-Video-1'
    8   = 'S-Video-2'
    9   = 'Tuner-1'
    10  = 'Tuner-2'
    11  = 'Tuner-3'
    12  = 'Component-1'
    13  = 'Component-2'
    14  = 'Component-3'
    15  = 'DisplayPort-1'
    16  = 'DisplayPort-2'
    17  = 'HDMI-1'
    18  = 'HDMI-2'
    27  = 'USB-C / DP-Alt (vendor code, common on Dell)'
    208 = 'USB-C (vendor code, common on LG)'
}

function Write-Info    { param([string]$m) Write-Host $m }
function Write-Good    { param([string]$m) Write-Host $m -ForegroundColor Green }
function Write-Warn2   { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Bad     { param([string]$m) Write-Host $m -ForegroundColor Red }
function Write-Head    { param([string]$m) Write-Host ''; Write-Host $m -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
#  INI handling - the same config.ini is read by PowerShell and by AutoHotkey
# ---------------------------------------------------------------------------
function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path`nRun 1-Detect.bat first to generate it."
    }

    $ini = [ordered]@{}
    $section = 'Root'
    $ini[$section] = [ordered]@{}

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
            continue
        }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $t.Substring(0, $idx).Trim()
        $val = $t.Substring($idx + 1).Trim()
        # strip a trailing inline comment that starts with " ;"
        $val = ($val -replace '\s+;.*$', '').Trim()
        # ControlMyMonitor's /smonitors export quotes every value, so ids can
        # arrive as "\\.\DISPLAY6\Monitor0". Windows' own INI API strips those
        # quotes, so strip them here too and keep both readers consistent.
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2).Trim()
        }
        $ini[$section][$key] = $val
    }
    return $ini
}

function Get-Ini {
    param($Ini, [string]$Section, [string]$Key, $Default = $null)
    if ($Ini.Contains($Section) -and $Ini[$Section].Contains($Key)) {
        $v = $Ini[$Section][$Key]
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $Default
}

function Get-ConfigPath {
    # One folder can be shared between machines - a laptop and a desktop that
    # drive the same monitors through different ports, for example. The two
    # need different input values, different ControlMyMonitor paths, and the
    # desktop has no internal panel at all, so they cannot share one file.
    #
    # config.<COMPUTERNAME>.ini wins when present; config.ini is the fallback.
    $perMachine = Join-Path $script:AppRoot ("config.{0}.ini" -f $env:COMPUTERNAME)
    if (Test-Path -LiteralPath $perMachine) { return $perMachine }
    return (Join-Path $script:AppRoot 'config.ini')
}

function Get-PerMachineConfigPath {
    return (Join-Path $script:AppRoot ("config.{0}.ini" -f $env:COMPUTERNAME))
}

# Reads the "Generated on <machine>" stamp from a config header, if any.
function Get-ConfigOrigin {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount 12)) {
        if ($line -match 'Generated\s+on\s+(\S+)') { return $Matches[1] }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  Locate ControlMyMonitor.exe
# ---------------------------------------------------------------------------
function Resolve-ControlMyMonitor {
    param([string]$Configured)

    $candidates = New-Object System.Collections.ArrayList
    if ($Configured) { [void]$candidates.Add($Configured) }

    $fixed = @(
        (Join-Path $script:AppRoot 'ControlMyMonitor.exe'),
        (Join-Path $script:AppRoot 'tools\ControlMyMonitor.exe'),
        "$env:ProgramFiles\ControlMyMonitor\ControlMyMonitor.exe",
        "${env:ProgramFiles(x86)}\ControlMyMonitor\ControlMyMonitor.exe",
        "$env:LOCALAPPDATA\Programs\ControlMyMonitor\ControlMyMonitor.exe",
        "$env:LOCALAPPDATA\ControlMyMonitor\ControlMyMonitor.exe",
        "$env:USERPROFILE\Downloads\ControlMyMonitor\ControlMyMonitor.exe",
        "$env:USERPROFILE\Downloads\controlmymonitor\ControlMyMonitor.exe",
        "$env:USERPROFILE\Downloads\ControlMyMonitor.exe",
        "$env:USERPROFILE\Desktop\ControlMyMonitor.exe",
        "$env:USERPROFILE\OneDrive\Desktop\ControlMyMonitor.exe",
        "$env:USERPROFILE\Documents\ControlMyMonitor\ControlMyMonitor.exe",
        "C:\Tools\ControlMyMonitor\ControlMyMonitor.exe",
        "C:\ControlMyMonitor\ControlMyMonitor.exe"
    )
    foreach ($f in $fixed) { [void]$candidates.Add($f) }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    # Shallow recursive sweep of the likely roots (fast: depth limited).
    $roots = @(
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Documents",
        "$env:LOCALAPPDATA\Programs",
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        'C:\Tools',
        'C:\Program Files\NirSoft'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($r in $roots) {
        $hit = Get-ChildItem -LiteralPath $r -Filter 'ControlMyMonitor.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

# ---------------------------------------------------------------------------
#  Invoke ControlMyMonitor
#  It is a GUI-subsystem exe, so Start-Process -Wait is required to make the
#  call synchronous. Exit code is meaningful for /GetValue.
# ---------------------------------------------------------------------------
function Invoke-CMM {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$PassThruExitCode
    )
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }
    $p = Start-Process -FilePath $Exe -ArgumentList $quoted -Wait -PassThru -WindowStyle Hidden
    if ($PassThruExitCode) { return $p.ExitCode }
    return $null
}

function Set-MonitorVcp {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$MonitorId,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][int]$Value,
        [switch]$Force
    )
    $verb = if ($Force) { '/SetValue' } else { '/SetValueIfNeeded' }
    Invoke-CMM -Exe $Exe -Arguments @($verb, $MonitorId, $Code, "$Value") | Out-Null
}

function Get-MonitorVcp {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$MonitorId,
        [Parameter(Mandatory)][string]$Code
    )
    return (Invoke-CMM -Exe $Exe -Arguments @('/GetValue', $MonitorId, $Code) -PassThruExitCode)
}

function Step-MonitorVcp {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$MonitorId,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][int]$Delta
    )
    Invoke-CMM -Exe $Exe -Arguments @('/ChangeValue', $MonitorId, $Code, "$Delta") | Out-Null
}

# ---------------------------------------------------------------------------
#  Internal laptop panel - DDC/CI almost never works on built-in displays,
#  so this goes through the WMI brightness interface instead.
# ---------------------------------------------------------------------------
function Test-InternalBrightnessSupport {
    try {
        $null = Get-CimInstance -Namespace 'root/wmi' -ClassName 'WmiMonitorBrightnessMethods' -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-InternalBrightness {
    try {
        $b = Get-CimInstance -Namespace 'root/wmi' -ClassName 'WmiMonitorBrightness' -ErrorAction Stop |
             Select-Object -First 1
        if ($b) { return [int]$b.CurrentBrightness }
    } catch { }
    return $null
}

function Set-InternalBrightness {
    param([Parameter(Mandatory)][int]$Percent)

    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $methods = Get-CimInstance -Namespace 'root/wmi' -ClassName 'WmiMonitorBrightnessMethods' -ErrorAction Stop
    foreach ($m in @($methods)) {
        Invoke-CimMethod -InputObject $m -MethodName 'WmiSetBrightness' `
            -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$Percent } | Out-Null
    }
}

# ---------------------------------------------------------------------------
#  Config model: turn config.ini into a list of monitor objects
# ---------------------------------------------------------------------------
function Get-MonitorPlan {
    param($Ini)

    $namesRaw = Get-Ini $Ini 'Monitors' 'Names' ''
    $names = @($namesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($names.Count -eq 0) {
        throw "No monitors listed. Set 'Names=' under [Monitors] in config.ini."
    }

    $plan = @()
    foreach ($n in $names) {
        $sec = "Monitor.$n"
        $plan += [pscustomobject]@{
            Name         = $n
            Label        = (Get-Ini $Ini $sec 'Label' $n)
            Type         = (Get-Ini $Ini $sec 'Type' 'External')
            Id           = (Get-Ini $Ini $sec 'Id' '')
            Key          = (Get-Ini $Ini $sec 'MonitorKey' '')
            Serial       = (Get-Ini $Ini $sec 'Serial' '')
            InputPC      = (Get-Ini $Ini $sec 'InputPC' '')
            InputLaptop  = (Get-Ini $Ini $sec 'InputLaptop' '')
            Section      = $sec
        }
    }
    return $plan
}

# The string handed to ControlMyMonitor to identify a monitor.
#
# Deliberately NOT \\.\DISPLAYn - Windows renumbers those at boot, so a config
# keyed on them breaks after a reboot. ControlMyMonitor accepts the Short
# Monitor ID (the EDID hardware id, e.g. PHLC323) and the serial number, both
# of which are properties of the panel itself and never move.
function Get-CmmTarget {
    param($Monitor)
    if ($Monitor.Key)    { return $Monitor.Key }
    if ($Monitor.Serial) { return $Monitor.Serial }
    return $Monitor.Id
}

function Split-ProfileValue {
    # "80" -> brightness 80, no contrast.  "80,65" -> brightness 80, contrast 65.
    param([string]$Raw)
    $parts = @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $out = [pscustomobject]@{ Brightness = $null; Contrast = $null }
    if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') { $out.Brightness = [int]$parts[0] }
    if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') { $out.Contrast   = [int]$parts[1] }
    return $out
}

# --- VCP 14 (Select Color Preset), the standard MCCS table -----------------
$script:PresetNames = @{
    1  = 'sRGB'
    2  = 'Display native'
    3  = '4000K'
    4  = '5000K'
    5  = '6500K'
    6  = '7500K'
    7  = '8200K'
    8  = '9300K'
    9  = '10000K'
    10 = '11500K'
    11 = 'User 1'
    12 = 'User 2'
    13 = 'User 3'
}

function Get-PresetFriendlyName {
    param($Value)
    $i = 0
    if (-not [int]::TryParse("$Value", [ref]$i)) { return "preset $Value" }
    if ($script:PresetNames.ContainsKey($i)) { return $script:PresetNames[$i] }
    return "preset $i"
}

function Get-InputFriendlyName {
    param($Value)
    $i = 0
    if (-not [int]::TryParse("$Value", [ref]$i)) { return "value $Value" }
    if ($script:InputNames.ContainsKey($i)) { return $script:InputNames[$i] }
    return ("unknown (dec {0} / hex 0x{1:X2})" -f $i, $i)
}
