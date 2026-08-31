# ============================================================================
#  Gamma.ps1 - software dimming below the monitor's hardware minimum
#
#  Some panels simply will not go dark enough. The Philips Evnia is a known
#  case: reviewers measure roughly 100 nits even at brightness 0, because the
#  mini-LED backlight has a high floor. DDC/CI cannot help - 0 is 0.
#
#  The fix is to attenuate the signal on the GPU instead, by reshaping the
#  display's gamma ramp. That is exactly what the NVIDIA Control Panel's
#  brightness / contrast / gamma sliders do, but SetDeviceGammaRamp is a plain
#  Windows API, so this works on any GPU with no vendor software involved.
#
#  Requires lib\Display.ps1 (the P/Invoke lives in the same compiled block).
# ============================================================================

# ---------------------------------------------------------------------------
#  Build a 768-entry ramp: 256 red, then 256 green, then 256 blue.
#
#  Brightness : 1.0 = untouched, 0.4 = 40% of normal output
#  Gamma      : >1 lifts midtones (text stays readable while whites dim)
#  Warmth     : 0..1, pulls blue (and a little green) down - a Night Light
#               that does not fight with the brightness setting
#  Contrast   : 1.0 = untouched, <1 flattens toward mid grey
# ---------------------------------------------------------------------------
function New-GammaRamp {
    param(
        [double]$Brightness = 1.0,
        [double]$Gamma      = 1.0,
        [double]$Warmth     = 0.0,
        [double]$Contrast   = 1.0
    )

    if ($Brightness -lt 0.05) { $Brightness = 0.05 }   # never fully black
    if ($Brightness -gt 1.0)  { $Brightness = 1.0 }
    if ($Warmth -lt 0)        { $Warmth = 0 }
    if ($Warmth -gt 1)        { $Warmth = 1 }
    if ($Gamma -lt 0.3)       { $Gamma = 0.3 }
    if ($Gamma -gt 3.0)       { $Gamma = 3.0 }

    # Roughly tracks a drop from 6500K toward ~3400K at Warmth = 1.
    $mul = @(
        1.0,
        (1.0 - (0.16 * $Warmth)),
        (1.0 - (0.55 * $Warmth))
    )

    $ramp = New-Object 'System.UInt16[]' 768

    for ($i = 0; $i -lt 256; $i++) {
        $v = $i / 255.0
        if ($Gamma -ne 1.0)    { $v = [Math]::Pow($v, 1.0 / $Gamma) }
        if ($Contrast -ne 1.0) { $v = (($v - 0.5) * $Contrast) + 0.5 }
        $v = $v * $Brightness

        for ($c = 0; $c -lt 3; $c++) {
            $cv = $v * $mul[$c]
            if ($cv -lt 0) { $cv = 0 }
            if ($cv -gt 1) { $cv = 1 }
            $ramp[($c * 256) + $i] = [uint16][Math]::Round($cv * 65535.0)
        }
    }
    return $ramp
}

function New-IdentityRamp {
    return (New-GammaRamp -Brightness 1.0 -Gamma 1.0 -Warmth 0.0 -Contrast 1.0)
}

# ---------------------------------------------------------------------------
#  Apply, then verify.
#
#  SetDeviceGammaRamp can return TRUE and silently do nothing: Windows rejects
#  ramps it considers too extreme, as protection against apps blanking the
#  screen. So the ramp is read back and compared, and a clamp is reported
#  rather than left to look like success.
# ---------------------------------------------------------------------------
function Set-GammaRamp {
    param(
        [Parameter(Mandatory)][string]$DeviceName,
        [Parameter(Mandatory)][System.UInt16[]]$Ramp
    )

    $ok = [MonitorControls.Gamma]::Apply($DeviceName, $Ramp)
    if (-not $ok) {
        return [pscustomobject]@{ Applied = $false; Clamped = $false; Reason = 'The display rejected the gamma ramp (SetDeviceGammaRamp returned false).' }
    }

    $back = [MonitorControls.Gamma]::Read($DeviceName)
    if (-not $back) {
        return [pscustomobject]@{ Applied = $true; Clamped = $false; Reason = 'Applied, but the ramp could not be read back to verify.' }
    }

    # Compare the white point of each channel; drivers quantise, so allow slack.
    $worst = 0.0
    foreach ($c in 0..2) {
        $idx  = ($c * 256) + 255
        $want = [double]$Ramp[$idx]
        $got  = [double]$back[$idx]
        $diff = [Math]::Abs($got - $want) / 65535.0
        if ($diff -gt $worst) { $worst = $diff }
    }

    if ($worst -gt 0.08) {
        return [pscustomobject]@{
            Applied = $true
            Clamped = $true
            Reason  = ('Windows clamped the ramp (asked for {0:P0} at white, got {1:P0}).' -f `
                       ($Ramp[255] / 65535.0), ($back[255] / 65535.0))
        }
    }
    return [pscustomobject]@{ Applied = $true; Clamped = $false; Reason = 'OK' }
}

function Reset-GammaRamp {
    param([Parameter(Mandatory)][string]$DeviceName)
    return (Set-GammaRamp -DeviceName $DeviceName -Ramp (New-IdentityRamp))
}

# ---------------------------------------------------------------------------
#  The clamp is configurable. HKLM\...\ICM\GdiIcmGammaRange controls how far a
#  ramp may deviate: 0 blocks everything, 256 allows anything. Windows ships
#  with a conservative default, which is what stops a really dark ramp.
# ---------------------------------------------------------------------------
$script:GammaRangeKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM'

function Get-GammaRangeLimit {
    try {
        $v = (Get-ItemProperty -Path $script:GammaRangeKey -Name 'GdiIcmGammaRange' -ErrorAction Stop).GdiIcmGammaRange
        return [int]$v
    } catch { return $null }
}

function Enable-DeepDim {
    <# Requires administrator. Takes effect after signing out and back in. #>
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'This needs an administrator PowerShell window (it writes to HKLM).'
    }
    if (-not (Test-Path $script:GammaRangeKey)) {
        New-Item -Path $script:GammaRangeKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:GammaRangeKey -Name 'GdiIcmGammaRange' -Value 256 -Type DWord
    return 256
}

# "0.45", "0.45,1.1", "0.45,1.1,0.35" -> brightness, gamma, warmth
function Split-SoftValue {
    param([string]$Raw)
    $parts = @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $out = [pscustomobject]@{ Brightness = $null; Gamma = 1.0; Warmth = 0.0 }
    if ($parts.Count -ge 1) { [double]$b = 0; if ([double]::TryParse($parts[0], [ref]$b)) { $out.Brightness = $b } }
    if ($parts.Count -ge 2) { [double]$g = 0; if ([double]::TryParse($parts[1], [ref]$g)) { $out.Gamma = $g } }
    if ($parts.Count -ge 3) { [double]$w = 0; if ([double]::TryParse($parts[2], [ref]$w)) { $out.Warmth = $w } }
    return $out
}
