; ===========================================================================
;  Gdi.ahk - display enumeration and gamma ramps, straight from AutoHotkey
;
;  These are the same two Windows APIs lib\Display.ps1 and lib\Gamma.ps1 wrap
;  for PowerShell. They are duplicated here on purpose: the tuner moves a
;  gamma ramp on every slider tick, and spawning powershell.exe for that would
;  cost a few hundred milliseconds a frame (Add-Type recompiles the P/Invoke
;  block in every new process). A DllCall is instant, so the slider tracks the
;  screen live.
;
;  If you change the ramp maths here, change New-GammaRamp in lib\Gamma.ps1 to
;  match - a profile saved from the tuner has to look the same when
;  Set-Profile.ps1 applies it at logon.
; ===========================================================================

; DISPLAY_DEVICEW field offsets. cb(4) DeviceName(32w) DeviceString(128w)
; StateFlags(4) DeviceID(128w) DeviceKey(128w) = 840 bytes, no padding.
global DD_SIZE   := 840
global DD_NAME   := 4
global DD_STRING := 68
global DD_STATE  := 324
global DD_ID     := 328

; ---------------------------------------------------------------------------
;  Every attached display, with the EDID hardware id that survives a reboot.
;
;  \.\DISPLAYn is handed out by Windows at boot and moves - the same panel
;  can be DISPLAY5 today and DISPLAY9 tomorrow. The adapter's child device
;  carries MONITOR\PHLC323\{guid}\0001, and that "PHLC323" is burned into the
;  panel, so it is what config.ini keys on.
; ---------------------------------------------------------------------------
EnumDisplays() {
    out := []
    i := 0
    loop {
        dd := Buffer(DD_SIZE, 0)
        NumPut("UInt", DD_SIZE, dd, 0)
        if !DllCall("user32\EnumDisplayDevicesW", "ptr", 0, "uint", i, "ptr", dd, "uint", 0)
            break
        i++

        state := NumGet(dd, DD_STATE, "UInt")
        if !(state & 1)                     ; DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
            continue

        device := StrGet(dd.Ptr + DD_NAME, 32, "UTF-16")

        md := Buffer(DD_SIZE, 0)
        NumPut("UInt", DD_SIZE, md, 0)
        key := "", panel := ""
        if DllCall("user32\EnumDisplayDevicesW", "wstr", device, "uint", 0, "ptr", md, "uint", 0) {
            panel := StrGet(md.Ptr + DD_STRING, 128, "UTF-16")
            parts := StrSplit(StrGet(md.Ptr + DD_ID, 128, "UTF-16"), "\")
            if (parts.Length > 1)
                key := parts[2]
        }
        out.Push({ device: device, key: key, panel: panel, primary: (state & 4) != 0 })
    }
    return out
}

; Stable key -> current \.\DISPLAYn. Falls back to the volatile Id= in
; config.ini so a config written before keys existed still works.
ResolveDisplayDevice(key, fallbackId := "") {
    if (key != "") {
        hits := []
        for d in EnumDisplays()
            if (d.key != "" && d.key = key)
                hits.Push(d.device)
        if (hits.Length)
            return hits[1]
    }
    if (fallbackId != "" && RegExMatch(fallbackId, "(\\\.\DISPLAY\d+)", &m)) {
        for d in EnumDisplays()
            if (d.device = m[1])
                return d.device
    }
    return ""
}

; ---------------------------------------------------------------------------
;  A 768-entry ramp: 256 red, then 256 green, then 256 blue, as UInt16.
;
;  bright  0.05 - 1.0   1.0 = untouched, 0.45 = 45% output
;  gamma   0.3 - 3.0    above 1.0 lifts midtones so text stays readable
;  warmth  0 - 1        pulls blue down; roughly 6500K -> 3400K at 1.0
; ---------------------------------------------------------------------------
BuildGammaRamp(bright, gamma, warmth) {
    bright := Clamp(bright, 0.05, 1.0)
    gamma  := Clamp(gamma,  0.3,  3.0)
    warmth := Clamp(warmth, 0.0,  1.0)

    mul := [1.0, 1.0 - (0.16 * warmth), 1.0 - (0.55 * warmth)]
    ramp := Buffer(768 * 2, 0)

    loop 256 {
        i := A_Index - 1
        v := i / 255.0
        if (gamma != 1.0)
            v := v ** (1.0 / gamma)
        v := v * bright

        loop 3 {
            c  := A_Index - 1
            cv := Clamp(v * mul[c + 1], 0.0, 1.0)
            NumPut("UShort", Round(cv * 65535.0), ramp, ((c * 256) + i) * 2)
        }
    }
    return ramp
}

BuildIdentityRamp() => BuildGammaRamp(1.0, 1.0, 0.0)

Clamp(v, lo, hi) => (v < lo) ? lo : ((v > hi) ? hi : v)

; ---------------------------------------------------------------------------
;  SetDeviceGammaRamp can return TRUE and quietly do nothing: Windows refuses
;  ramps it considers too extreme so an app cannot black out the screen. So
;  read it back and report a clamp rather than letting it look like success.
;  Set-SoftDim.ps1 -EnableDeepDim raises that limit.
; ---------------------------------------------------------------------------
ApplyGammaRamp(deviceName, ramp) {
    if (deviceName = "")
        return { applied: false, clamped: false }

    hdc := DllCall("gdi32\CreateDCW", "wstr", "DISPLAY", "wstr", deviceName
                 , "ptr", 0, "ptr", 0, "ptr")
    if !hdc
        return { applied: false, clamped: false }

    ok   := DllCall("gdi32\SetDeviceGammaRamp", "ptr", hdc, "ptr", ramp, "int")
    back := Buffer(768 * 2, 0)
    got  := DllCall("gdi32\GetDeviceGammaRamp", "ptr", hdc, "ptr", back, "int")
    DllCall("gdi32\DeleteDC", "ptr", hdc)

    if !ok
        return { applied: false, clamped: false }
    if !got
        return { applied: true, clamped: false }

    ; Compare the white point of each channel; drivers quantise, so allow slack.
    worst := 0.0
    loop 3 {
        idx  := (((A_Index - 1) * 256) + 255) * 2
        diff := Abs(NumGet(back, idx, "UShort") - NumGet(ramp, idx, "UShort")) / 65535.0
        if (diff > worst)
            worst := diff
    }
    return { applied: true, clamped: (worst > 0.08) }
}

ResetGammaRamp(deviceName) => ApplyGammaRamp(deviceName, BuildIdentityRamp())

; Current output level at white, 0.0 - 1.0, or -1 if it cannot be read.
ReadGammaLevel(deviceName) {
    if (deviceName = "")
        return -1
    hdc := DllCall("gdi32\CreateDCW", "wstr", "DISPLAY", "wstr", deviceName
                 , "ptr", 0, "ptr", 0, "ptr")
    if !hdc
        return -1
    ramp := Buffer(768 * 2, 0)
    ok := DllCall("gdi32\GetDeviceGammaRamp", "ptr", hdc, "ptr", ramp, "int")
    DllCall("gdi32\DeleteDC", "ptr", hdc)
    return ok ? (NumGet(ramp, 255 * 2, "UShort") / 65535.0) : -1
}
