<#
.SYNOPSIS
    One-time setup: finds ControlMyMonitor, inspects every display, and writes
    a ready-to-use config.ini for the rest of the toolkit.

.DESCRIPTION
    Run this first (or via 1-Detect.bat). It will:
      1. Locate ControlMyMonitor.exe.
      2. Enumerate all monitors and their DDC/CI (VCP) capabilities.
      3. Detect the built-in laptop panel, which uses WMI rather than DDC/CI.
      4. Write config.ini pre-filled with real monitor IDs, your CURRENT
         brightness values, and the input source your PC is plugged into.
      5. Drop the raw reports in .\detected\ for reference.

.PARAMETER CmmPath
    Full path to ControlMyMonitor.exe, if auto-detection fails.

.PARAMETER Force
    Overwrite an existing config.ini instead of writing config.detected.ini.
#>
[CmdletBinding()]
param(
    [string]$CmmPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Display.ps1')

$OutDir = Join-Path $PSScriptRoot 'detected'
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

Write-Head '=== 1. Locating ControlMyMonitor.exe ==='

$exe = Resolve-ControlMyMonitor -Configured $CmmPath
if (-not $exe) {
    Write-Bad 'Could not find ControlMyMonitor.exe.'
    Write-Info ''
    Write-Info 'Fix it in one of two ways:'
    Write-Info '  a) Copy ControlMyMonitor.exe into this folder, then re-run.'
    Write-Info '  b) Re-run with the path, e.g.:'
    Write-Info '     .\Detect-Monitors.ps1 -CmmPath "C:\Tools\ControlMyMonitor.exe"'
    exit 1
}
Write-Good "Found: $exe"

# ---------------------------------------------------------------------------
Write-Head '=== 2. Enumerating monitors ==='

$monListFile = Join-Path $OutDir 'monitors.txt'
if (Test-Path -LiteralPath $monListFile) { Remove-Item -LiteralPath $monListFile -Force }
Invoke-CMM -Exe $exe -Arguments @('/smonitors', $monListFile) | Out-Null
Start-Sleep -Milliseconds 400

$blocks = @()
if (Test-Path -LiteralPath $monListFile) {
    $raw = Get-Content -LiteralPath $monListFile -Raw
    foreach ($chunk in ($raw -split "(\r?\n){2,}")) {
        if ($chunk -notmatch '\S') { continue }
        $h = @{}
        foreach ($line in ($chunk -split "\r?\n")) {
            if ($line -match '^\s*(.+?)\s*:\s*(.*)$') {
                $k = $Matches[1].Trim()
                $v = $Matches[2].Trim()
                # /smonitors quotes every value - drop the wrapping quotes so the
                # generated config holds bare ids like \\.\DISPLAY6\Monitor0
                if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                    $v = $v.Substring(1, $v.Length - 2).Trim()
                }
                $h[$k] = $v
            }
        }
        if ($h.Count -gt 0) { $blocks += ,$h }
    }
}

function Find-Key {
    param($Hash, [string]$Pattern)
    foreach ($k in $Hash.Keys) { if ($k -match $Pattern) { return $Hash[$k] } }
    return $null
}

$monitors = @()
foreach ($b in $blocks) {
    $dev = Find-Key $b 'device\s*name'
    if (-not $dev) { $dev = Find-Key $b '^monitor\s*device' }
    if (-not $dev -or $dev -notmatch 'DISPLAY') { continue }
    $monitors += [pscustomobject]@{
        DeviceName  = $dev
        MonitorName = (Find-Key $b '^monitor\s*name$')
        Serial      = (Find-Key $b 'serial')
        ShortId     = (Find-Key $b 'short\s*monitor\s*id')
        Adapter     = (Find-Key $b 'adapter')
    }
}

if ($monitors.Count -eq 0) {
    Write-Warn2 'Could not parse the monitor list; falling back to probing DISPLAY1..DISPLAY6.'
    foreach ($i in 1..6) {
        $dn = "\\.\DISPLAY$i\Monitor0"
        $v = Get-MonitorVcp -Exe $exe -MonitorId $dn -Code $script:VCP.Brightness
        if ($null -ne $v -and $v -ge 0 -and $v -le 100) {
            $monitors += [pscustomobject]@{
                DeviceName = $dn; MonitorName = "Display $i"; Serial = ''; ShortId = ''; Adapter = ''
            }
        }
    }
}

Write-Info ("Monitors reported by ControlMyMonitor: {0}" -f $monitors.Count)
foreach ($m in $monitors) {
    Write-Info ("  {0}  |  {1}  |  serial: {2}" -f $m.DeviceName, $m.MonitorName, $m.Serial)
}

# ---------------------------------------------------------------------------
Write-Head '=== 3. Reading DDC/CI capabilities per monitor ==='

$details = @()
$idx = 0
foreach ($m in $monitors) {
    $idx++
    $safe = ($m.DeviceName -replace '[^A-Za-z0-9]', '_')
    $csv  = Join-Path $OutDir ("vcp_{0}_{1}.csv" -f $idx, $safe)
    $txt  = Join-Path $OutDir ("vcp_{0}_{1}.txt" -f $idx, $safe)
    foreach ($f in @($csv, $txt)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }

    Invoke-CMM -Exe $exe -Arguments @('/scomma', $csv, $m.DeviceName) | Out-Null
    Invoke-CMM -Exe $exe -Arguments @('/stext', $txt, $m.DeviceName) | Out-Null
    Start-Sleep -Milliseconds 300

    $rows = @()
    if ((Test-Path -LiteralPath $csv) -and ((Get-Item -LiteralPath $csv).Length -gt 0)) {
        try { $rows = @(Import-Csv -LiteralPath $csv) } catch { $rows = @() }
    }

    $curBright = $null; $curContrast = $null; $curInput = $null; $inputOptions = @()
    $csvHadRows = ($rows.Count -gt 0)

    if ($rows.Count -gt 0) {
        $cols    = $rows[0].psobject.Properties.Name
        $colCode = $cols | Where-Object { $_ -match 'code' -and $_ -notmatch 'name' } | Select-Object -First 1
        $colCur  = $cols | Where-Object { $_ -match 'current' }  | Select-Object -First 1
        $colPos  = $cols | Where-Object { $_ -match 'possible' } | Select-Object -First 1
        if (-not $colCode) { $colCode = $cols[0] }

        foreach ($r in $rows) {
            $code = ("$($r.$colCode)").Trim() -replace '^0x', ''
            $cur  = if ($colCur) { ("$($r.$colCur)").Trim() } else { '' }
            switch ($code.ToUpper()) {
                '10' { if ($cur -match '^\d+$') { $curBright = [int]$cur } }
                '12' { if ($cur -match '^\d+$') { $curContrast = [int]$cur } }
                '60' {
                    if ($cur -match '^\d+$') { $curInput = [int]$cur }
                    if ($colPos) {
                        $pos = ("$($r.$colPos)").Trim()
                        $inputOptions = @([regex]::Matches($pos, '\d+') | ForEach-Object { [int]$_.Value } | Select-Object -Unique)
                    }
                }
            }
        }
    }

    # A DDC/CI-capable monitor always exports at least a few VCP rows. An empty
    # export means the display did not answer at all - typically a built-in
    # laptop panel, or a link that blocks DDC (some docks / DisplayLink / KVMs).
    # /GetValue exit codes are not trustworthy in that case, so only fall back
    # to them when we actually got rows.
    if ($csvHadRows) {
        if ($null -eq $curBright) {
            $v = Get-MonitorVcp -Exe $exe -MonitorId $m.DeviceName -Code $script:VCP.Brightness
            if ($null -ne $v -and $v -ge 0 -and $v -le 100) { $curBright = [int]$v }
        }
        if ($null -eq $curInput) {
            $v = Get-MonitorVcp -Exe $exe -MonitorId $m.DeviceName -Code $script:VCP.InputSource
            if ($null -ne $v -and $v -gt 0 -and $v -lt 255) { $curInput = [int]$v }
        }
    }

    $isExternal = ($csvHadRows -and $null -ne $curBright)

    $details += [pscustomobject]@{
        Index        = $idx
        DeviceName   = $m.DeviceName
        MonitorName  = $m.MonitorName
        Serial       = $m.Serial
        ShortId      = $m.ShortId
        Brightness   = $curBright
        Contrast     = $curContrast
        CurrentInput = $curInput
        InputOptions = $inputOptions
        IsExternal   = $isExternal
        Report       = $txt
    }

    Write-Info ''
    Write-Info ("[{0}] {1}" -f $idx, $m.MonitorName)
    Write-Info ("     Id           : {0}" -f $m.DeviceName)
    if ($isExternal) {
        Write-Good ("     DDC/CI       : yes  (brightness {0}{1})" -f $curBright, $(if ($null -ne $curContrast) { ", contrast $curContrast" } else { '' }))
        if ($null -ne $curInput) {
            Write-Info ("     Active input : {0} -> {1}" -f $curInput, (Get-InputFriendlyName $curInput))
        }
        if ($inputOptions.Count -gt 0) {
            Write-Info  '     Selectable inputs:'
            foreach ($o in ($inputOptions | Sort-Object)) {
                Write-Info ("       {0,4} = {1}" -f $o, (Get-InputFriendlyName $o))
            }
        } else {
            Write-Warn2 '     Selectable inputs: not reported - see the .txt report in .\detected\'
        }
    } else {
        Write-Warn2 '     DDC/CI       : no response - normal for a built-in laptop panel.'
        Write-Warn2 '                    If this IS an external monitor, enable DDC/CI in its OSD menu'
        Write-Warn2 '                    and re-run. Docks, KVMs and DisplayLink adapters can also block it.'
    }
}

# ---------------------------------------------------------------------------
Write-Head '=== 4. Built-in laptop panel (WMI) ==='

$hasInternal = Test-InternalBrightnessSupport
if ($hasInternal) {
    $ib = Get-InternalBrightness
    Write-Good ("WMI brightness control available. Current level: {0}" -f $(if ($null -ne $ib) { "$ib%" } else { 'unknown' }))
} else {
    Write-Warn2 'No WMI brightness interface found.'
    Write-Warn2 'If this machine IS a laptop, its panel may need the OEM driver, or you may be'
    Write-Warn2 'running on the desktop PC. You can still control the two external monitors.'
}

# ---------------------------------------------------------------------------
Write-Head '=== 5. Writing config ==='

$externals = @($details | Where-Object { $_.IsExternal })

# Name them by where they actually sit on the desktop, not by the order
# ControlMyMonitor happened to enumerate them. Leftmost becomes "Left".
$posByKey = @{}
try {
    foreach ($d in (Get-DisplayList)) {
        if ($d.MonitorKey) { $posByKey[$d.MonitorKey] = $d.PositionX }
    }
} catch { }

if ($posByKey.Count -gt 0) {
    $externals = @($externals | Sort-Object `
        @{ Expression = { if ($_.ShortId -and $posByKey.ContainsKey($_.ShortId)) { [int]$posByKey[$_.ShortId] } else { [int]::MaxValue } } }, `
        @{ Expression = { $_.Index } })
    Write-Info 'Ordered left-to-right by desktop position.'
} else {
    Write-Warn2 'Could not read desktop positions; falling back to enumeration order.'
}

# Work out the friendly key each external monitor gets in the config.
$names = @()
$keyFor = @{}
$n = 0
foreach ($d in $externals) {
    $n++
    $nm = if ($n -eq 1) { 'Left' } elseif ($n -eq 2) { 'Right' } else { "Ext$n" }
    $keyFor[$d.DeviceName] = $nm
    $names += $nm
}
if ($hasInternal) { $names += 'Laptop' }

$sb = New-Object System.Text.StringBuilder
function Add-Line { param([string]$s = '') [void]$sb.AppendLine($s) }

Add-Line '; ==========================================================================='
Add-Line ';  MonitorControls configuration'
Add-Line (';  Generated on {0} at {1} by Detect-Monitors.ps1' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Add-Line ';'
Add-Line ';  Read by BOTH the PowerShell scripts and MonitorControls.ahk, so this is'
Add-Line ';  the single place to edit. Values are DECIMAL (ControlMyMonitor takes hex'
Add-Line ';  VCP codes but decimal values).'
Add-Line '; ==========================================================================='
Add-Line ''
Add-Line '[Paths]'
Add-Line ("ControlMyMonitor={0}" -f $exe)
Add-Line ''
Add-Line '[Options]'
Add-Line '; Show a brief on-screen confirmation when a hotkey fires (1 = yes, 0 = no)'
Add-Line 'ShowFeedback=1'
Add-Line '; Milliseconds to pause between monitors when switching inputs'
Add-Line 'InputSwitchDelay=250'
Add-Line '; Step size for the nudge-brightness hotkeys'
Add-Line 'NudgeStep=10'
$extNames = @($externals | ForEach-Object { $keyFor[$_.DeviceName] })
$rotTarget = if ($extNames -contains 'Right') { 'Right' } elseif ($extNames.Count -gt 0) { $extNames[0] } else { '' }
Add-Line '; Monitor that Set-Orientation.ps1 and Ctrl+Alt+O rotate by default.'
Add-Line '; Check this is really your right-hand screen: .\Set-Orientation.ps1 -List'
Add-Line ("RotateTarget={0}" -f $rotTarget)
Add-Line ''
Add-Line '[Monitors]'
Add-Line '; Every name listed here needs a matching [Monitor.<name>] section below.'
Add-Line ("Names={0}" -f ($names -join ','))
Add-Line ''

foreach ($d in $externals) {
    $nm = $keyFor[$d.DeviceName]
    Add-Line ("[Monitor.$nm]")
    Add-Line ("Label={0}" -f $(if ($d.MonitorName) { $d.MonitorName } else { $nm }))
    Add-Line  'Type=External'
    Add-Line  ';   Stable identity. This is what every script keys on - it is burned'
    Add-Line  ';   into the panel and survives reboots, re-cabling and GPU changes.'
    Add-Line ("MonitorKey={0}" -f $d.ShortId)
    Add-Line ("Serial={0}" -f $d.Serial)
    Add-Line  ';   Windows display number at the time of detection. VOLATILE - Windows'
    Add-Line  ';   renumbers these at boot. Kept only as a fallback; nothing breaks'
    Add-Line  ';   when it goes stale.'
    Add-Line ("Id={0}" -f $d.DeviceName)
    Add-Line ''
    Add-Line ';   Input source values this monitor reports:'
    if ($d.InputOptions.Count -gt 0) {
        foreach ($o in ($d.InputOptions | Sort-Object)) {
            Add-Line (';     {0,4} = {1}' -f $o, (Get-InputFriendlyName $o))
        }
    } else {
        Add-Line ';     (none reported - open detected\vcp_*.txt or ControlMyMonitor GUI,'
        Add-Line ';      look at VCP code 60, and use the values listed there)'
    }
    if ($null -ne $d.CurrentInput) {
        Add-Line (';   Active right now (so this is almost certainly the PC): {0} = {1}' -f $d.CurrentInput, (Get-InputFriendlyName $d.CurrentInput))
        Add-Line ("InputPC={0}" -f $d.CurrentInput)
    } else {
        Add-Line ';   FILL IN: the value for the port your desktop PC is plugged into'
        Add-Line 'InputPC='
    }
    Add-Line ';   FILL IN: the value for the port your laptop is plugged into'
    Add-Line 'InputLaptop='
    Add-Line ''
}

if ($hasInternal) {
    Add-Line '[Monitor.Laptop]'
    Add-Line 'Label=Built-in laptop screen'
    Add-Line '; Internal panels do not answer DDC/CI, so this one is driven through WMI'
    Add-Line '; instead of ControlMyMonitor. It has no input to switch.'
    Add-Line 'Type=Internal'
    Add-Line ''
}

$skipped = @($details | Where-Object { -not $_.IsExternal })
if ($skipped.Count -gt 0) {
    Add-Line '; ---------------------------------------------------------------------------'
    Add-Line ';  These displays did not answer DDC/CI and were left out. That is expected'
    Add-Line ';  for a built-in laptop panel (handled by [Monitor.Laptop] above). If one of'
    Add-Line ';  them is really an external monitor, turn DDC/CI on in its OSD menu and'
    Add-Line ';  re-run detection, or uncomment a block below and add it to Names= .'
    foreach ($s in $skipped) {
        Add-Line ';'
        Add-Line (';   [Monitor.Extra{0}]' -f $s.Index)
        Add-Line (';   Label={0}' -f $s.MonitorName)
        Add-Line  ';   Type=External'
        Add-Line (';   MonitorKey={0}' -f $s.ShortId)
        Add-Line (';   Id={0}' -f $s.DeviceName)
        Add-Line  ';   InputPC='
        Add-Line  ';   InputLaptop='
    }
    Add-Line '; ---------------------------------------------------------------------------'
    Add-Line ''
}

Add-Line '; ==========================================================================='
Add-Line ';  Profiles:  <MonitorName>=brightness   or   <MonitorName>=brightness,contrast'
Add-Line ';  Leave a monitor out of a profile to leave that monitor untouched.'
Add-Line ';  Add your own sections too, e.g. [Profile.Gaming] - the hotkey file and'
Add-Line ';  Set-Profile.ps1 -Name Gaming will both pick it up.'
Add-Line '; ==========================================================================='
Add-Line ''

$internalNow = if ($hasInternal) { Get-InternalBrightness } else { $null }

foreach ($pName in @('Day', 'Night', 'Movie')) {
    Add-Line "[Profile.$pName]"
    foreach ($d in $externals) {
        $nm   = $keyFor[$d.DeviceName]
        $base = if ($null -ne $d.Brightness) { [int]$d.Brightness } else { 70 }
        $val  = switch ($pName) {
            'Day'   { $base }
            'Night' { [Math]::Max(0, [int]($base * 0.25)) }
            'Movie' { [Math]::Max(0, [int]($base * 0.55)) }
        }
        if ($pName -eq 'Movie' -and $null -ne $d.Contrast) {
            Add-Line ("{0}={1},{2}" -f $nm, $val, [Math]::Min(100, [int]($d.Contrast + 5)))
        } else {
            Add-Line ("{0}={1}" -f $nm, $val)
        }
    }
    if ($hasInternal) {
        $base = if ($null -ne $internalNow) { [int]$internalNow } else { 60 }
        $val  = switch ($pName) {
            'Day'   { $base }
            'Night' { [Math]::Max(5, [int]($base * 0.25)) }
            'Movie' { [Math]::Max(5, [int]($base * 0.55)) }
        }
        Add-Line ("Laptop={0}" -f $val)
    }
    Add-Line ''
}

$final = $sb.ToString()

$shared     = Join-Path $PSScriptRoot 'config.ini'
$perMachine = Get-PerMachineConfigPath
$origin     = Get-ConfigOrigin $shared

if (-not (Test-Path -LiteralPath $shared)) {
    # Nothing here yet - this machine owns the shared file.
    $target = $shared
} elseif ($origin -and $origin -ne $env:COMPUTERNAME) {
    # config.ini was generated on a DIFFERENT machine. Copying the folder
    # between a laptop and a desktop is normal, but they cannot share one
    # config: different ports, different ControlMyMonitor path, and only the
    # laptop has an internal panel. Give this machine its own file - the
    # scripts prefer config.<COMPUTERNAME>.ini automatically.
    $target = $perMachine
    Write-Warn2 ("config.ini was generated on '{0}', not on this machine ('{1}')." -f $origin, $env:COMPUTERNAME)
    Write-Good  ("Writing a config for this machine instead: {0}" -f (Split-Path -Leaf $perMachine))
    Write-Info  'Both machines can now share this folder; each picks up its own file.'
} elseif ($Force) {
    $target = $shared
} else {
    $target = Join-Path $PSScriptRoot 'config.detected.ini'
    Write-Warn2 'config.ini already exists for this machine - writing config.detected.ini instead.'
    Write-Warn2 'Compare the two, then copy over what you want (or re-run with -Force).'
}
Set-Content -LiteralPath $target -Value $final -Encoding UTF8
Write-Good ("Wrote: {0}" -f $target)

Write-Head '=== Next steps ==='
Write-Info '1. Open config.ini and fill in the InputPC / InputLaptop values for each'
Write-Info '   external monitor, using the value lists in the comments.'
Write-Info '2. Tweak the [Profile.Day] / [Profile.Night] / [Profile.Movie] numbers.'
Write-Info '3. Test without hotkeys:'
Write-Info '      .\Set-Profile.ps1 -Name Night'
Write-Info '      .\Set-Profile.ps1 -List'
Write-Info '4. Install AutoHotkey v2, then double-click MonitorControls.ahk.'
Write-Info ''
Write-Info ("Raw reports for reference: {0}" -f $OutDir)
