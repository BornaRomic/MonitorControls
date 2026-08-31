; ===========================================================================
;  Dimmer.ahk - one owner for every gamma ramp, plus the cross-fade engine.
;
;  WHY THIS EXISTS
;
;  Three separate features want to darken the same screen:
;
;      the profile's [Soft.<name>] section   ->  base
;      focus dim, for screens you are not on ->  focusMul
;      idle dim, for everything, after a while -> idleMul
;
;  If each of them called SetDeviceGammaRamp directly they would clobber one
;  another. Walking away from an already-dimmed CodeNight would either
;  double-dim or, worse, "restore" to full brightness on the way back and undo
;  the profile. So nothing outside this file touches a ramp: the three inputs
;  are stored separately, multiplied together, and only the product is applied.
;
;  The same tick also drives the cross-fade, so a profile change eases in
;  instead of snapping.
;
;  Gamma is a DllCall and can run at 40 fps. DDC/CI cannot - each call costs
;  50-150 ms - so panel brightness is stepped coarsely underneath the smooth
;  gamma fade. See DimTick.
; ===========================================================================

global Dim := []              ; parallel to Mons
global FadeMs := 450          ; cross-fade length; 0 = snap
global FadeDdcSteps := 4      ; coarse steps for panel brightness during a fade

global DimFadeStart := 0
global DimFadeDur := 0
global DimTicking := false

; ---------------------------------------------------------------------------
DimInit() {
    global Dim := []
    for i, m in Mons {
        Dim.Push({ dev: ResolveDisplayDevice(m.key, m.id)
                 ; what the profile asks for
                 , baseLevel: 1.0, baseGamma: 1.0, baseWarmth: 0.0
                 ; the two automatic multipliers
                 , focusMul: 1.0, idleMul: 1.0
                 ; what is on screen right now, and where it is heading
                 , curLevel: 1.0, curGamma: 1.0, curWarmth: 0.0
                 , fromLevel: 1.0, fromGamma: 1.0, fromWarmth: 0.0
                 , tgtLevel: 1.0, tgtGamma: 1.0, tgtWarmth: 0.0
                 ; panel brightness / contrast fade. -1 = nothing pending,
                 ; and ddcLast -1 means "we have never set it, so do not try
                 ; to fade from an unknown starting point".
                 , ddcFrom: -1, ddcTo: -1, ddcLast: -1, ddcStep: 0
                 , conTo: -1
                 ; Windows refuses ramps it thinks are too dark; the tuner
                 ; surfaces this so a slider that does nothing gets explained.
                 , clamped: false })
    }
}

; Re-resolve \\.\DISPLAYn - Windows renumbers them at boot and when a monitor
; is unplugged, so this is called again after any config reload.
DimRefreshDevices() {
    for i, m in Mons {
        if (i <= Dim.Length)
            Dim[i].dev := ResolveDisplayDevice(m.key, m.id)
    }
}

DimIndexOfDevice(dev) {
    if (dev = "")
        return 0
    for i, d in Dim
        if (d.dev != "" && d.dev = dev)
            return i
    return 0
}

; ---------------------------------------------------------------------------
;  Inputs. None of these touch the screen; DimCommit does that.
; ---------------------------------------------------------------------------
DimSetBase(i, level, gamma, warmth) {
    d := Dim[i]
    d.baseLevel  := Clamp(level,  0.05, 1.0)
    d.baseGamma  := Clamp(gamma,  0.3,  3.0)
    d.baseWarmth := Clamp(warmth, 0.0,  1.0)
}

DimSetFocus(i, mul) => Dim[i].focusMul := Clamp(mul, 0.05, 1.0)
DimSetIdle(i, mul)  => Dim[i].idleMul  := Clamp(mul, 0.05, 1.0)

; Panel brightness / contrast to move to on the next commit. contrast -1
; leaves contrast alone.
DimSetDdc(i, brightness, contrast := -1) {
    d := Dim[i]
    d.ddcFrom := d.ddcLast
    d.ddcTo   := brightness
    d.conTo   := contrast
    d.ddcStep := 0
}

; Panel brightness was changed by something other than a fade (a nudge, the
; monitor's own OSD). We no longer know the value, so the next fade must not
; pretend to know where it is starting from.
DimForgetDdc(i) {
    Dim[i].ddcLast := -1
}

; ---------------------------------------------------------------------------
;  Work out where every monitor should end up and start easing towards it.
;  durMs -1 uses the configured FadeMs; 0 snaps.
; ---------------------------------------------------------------------------
DimCommit(durMs := -1) {
    global DimFadeStart, DimFadeDur, DimTicking

    if (durMs < 0)
        durMs := FadeMs

    pending := false
    for d in Dim {
        d.fromLevel  := d.curLevel
        d.fromGamma  := d.curGamma
        d.fromWarmth := d.curWarmth

        d.tgtLevel  := Clamp(d.baseLevel * d.focusMul * d.idleMul, 0.05, 1.0)
        d.tgtGamma  := d.baseGamma
        d.tgtWarmth := d.baseWarmth

        if (Abs(d.tgtLevel - d.curLevel) > 0.002
         || Abs(d.tgtGamma - d.curGamma) > 0.002
         || Abs(d.tgtWarmth - d.curWarmth) > 0.002
         || d.ddcTo >= 0)
            pending := true
    }
    if !pending
        return

    if (durMs <= 0) {
        DimFadeDur := 0
        DimStep(1.0)
        DimFinish()
        return
    }

    DimFadeStart := A_TickCount
    DimFadeDur   := durMs
    if !DimTicking {
        DimTicking := true
        SetTimer(DimTick, 25)
    }
}

; ---------------------------------------------------------------------------
DimTick() {
    global DimTicking

    t := (DimFadeDur > 0) ? ((A_TickCount - DimFadeStart) / DimFadeDur) : 1.0
    if (t > 1.0)
        t := 1.0

    DimStep(t)

    if (t >= 1.0) {
        SetTimer(DimTick, 0)
        DimTicking := false
        DimFinish()
    }
}

DimStep(t) {
    e := t * t * (3.0 - 2.0 * t)          ; smoothstep - no abrupt start or stop

    for i, d in Dim {
        ; --- gamma: cheap, so it moves every tick ---------------------------
        if (d.dev != "") {
            lvl := d.fromLevel  + (d.tgtLevel  - d.fromLevel)  * e
            gam := d.fromGamma  + (d.tgtGamma  - d.fromGamma)  * e
            wrm := d.fromWarmth + (d.tgtWarmth - d.fromWarmth) * e

            if (t >= 1.0
             || Abs(lvl - d.curLevel) > 0.002
             || Abs(gam - d.curGamma) > 0.002
             || Abs(wrm - d.curWarmth) > 0.002)
                DimApplyRamp(i, lvl, gam, wrm, t >= 1.0)
        }

        ; --- panel brightness: expensive, so it moves in coarse steps -------
        if (d.ddcTo >= 0 && Mons[i].type != "Internal" && Mons[i].target != "") {
            steps := (FadeDdcSteps < 1) ? 1 : FadeDdcSteps
            ; Nothing to fade from on the first ever apply, or when something
            ; else moved the panel - go straight to the final value.
            if (d.ddcFrom < 0)
                steps := 1

            si := Ceil(e * steps)
            if (si < 1)
                si := 1

            if (si > d.ddcStep) {
                d.ddcStep := si
                if (si >= steps) {
                    ; The last step is authoritative and synchronous, so the
                    ; panel is guaranteed to land exactly on the target even if
                    ; an intermediate write was dropped.
                    CmmRun('/SetValueIfNeeded "' Mons[i].target '" 10 ' d.ddcTo)
                    if (d.conTo >= 0)
                        CmmRun('/SetValueIfNeeded "' Mons[i].target '" 12 ' d.conTo)
                    d.ddcLast := d.ddcTo
                } else {
                    ; Intermediate steps are fire-and-forget: waiting on DDC
                    ; here would stall the gamma fade sharing this timer.
                    v := Round(d.ddcFrom + (d.ddcTo - d.ddcFrom) * (si / steps))
                    CmmRunAsync('/SetValue "' Mons[i].target '" 10 ' v)
                }
            }
        }
    }
}

; final:=true only on the last frame of a fade, where it is worth paying for
; the read-back that tells us whether Windows clamped the ramp.
DimApplyRamp(i, lvl, gam, wrm, final := true) {
    d := Dim[i]
    d.curLevel := lvl, d.curGamma := gam, d.curWarmth := wrm

    ; Hand the identity ramp back when nothing is being asked for, rather than
    ; leaving a computed-but-neutral ramp in place.
    if (lvl >= 0.999 && Abs(gam - 1.0) < 0.005 && wrm < 0.005) {
        ResetGammaRamp(d.dev)
        d.clamped := false
        return
    }
    res := ApplyGammaRamp(d.dev, BuildGammaRampCached(lvl, gam, wrm), final)
    if final
        d.clamped := res.clamped
}

DimFinish() {
    for d in Dim {
        d.ddcTo   := -1
        d.conTo   := -1
        d.ddcFrom := -1
        d.ddcStep := 0
    }
}

; Everything back to untouched - used when the script exits, so it never
; leaves a dimmed screen behind.
DimResetAll() {
    SetTimer(DimTick, 0)
    global DimTicking := false
    for i, d in Dim {
        d.baseLevel := 1.0, d.baseGamma := 1.0, d.baseWarmth := 0.0
        d.focusMul := 1.0, d.idleMul := 1.0
        if (d.dev != "") {
            ResetGammaRamp(d.dev)
            d.curLevel := 1.0, d.curGamma := 1.0, d.curWarmth := 0.0
        }
    }
    DimFinish()
}

; A one-line summary of what is currently pulling a screen down, for the tray.
DimDescribe(i) {
    d := Dim[i]
    bits := []
    if (d.baseLevel < 0.999)
        bits.Push(Format("profile {:d}%", Round(d.baseLevel * 100)))
    if (d.focusMul < 0.999)
        bits.Push(Format("unfocused {:d}%", Round(d.focusMul * 100)))
    if (d.idleMul < 0.999)
        bits.Push(Format("idle {:d}%", Round(d.idleMul * 100)))
    if !bits.Length
        return "normal"
    return Format("{:d}% output", Round(d.curLevel * 100)) "  (" Join(bits, " x ") ")"
}
