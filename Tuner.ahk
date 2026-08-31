; ===========================================================================
;  Tuner.ahk - the "design a profile by eye" window  (Ctrl+Alt+T)
;
;  Editing config.ini means guessing a number, saving, pressing a hotkey and
;  looking at the result. This does the loop the other way round: drag a
;  slider, watch the screen change, press Save once it looks right.
;
;  Everything is applied live:
;     external brightness / contrast  ->  ControlMyMonitor, debounced (see
;                                         TunerFlush - DDC/CI is slow and a
;                                         drag would otherwise queue hundreds
;                                         of calls)
;     internal panel brightness       ->  Adjust-Brightness.ps1 via WMI,
;                                         debounced and fired-and-forgotten
;     soft dim / gamma / warmth       ->  DllCall straight to the GPU, instant
;
;  Save writes back into [Profile.<name>] and [Soft.<name>] of the same
;  config.ini everything else reads, so a tuned profile is an ordinary
;  profile: it works from the hotkey, the tray, and Set-Profile.ps1 at logon.
; ===========================================================================

global TunerGui   := ""
global TunerRows  := []      ; the controls, rebuilt when the layout changes
global TunerVals  := []      ; the model, survives a rebuild
global TunerDdl   := ""
global TunerHint  := ""
global TunerLive  := true
global TunerLink  := false
global TunerSoft  := false   ; show the GPU soft-dim sliders
global TunerProf  := ""
global TunerDirty := Map()
global TunerBusy  := false   ; suppress events while repopulating controls

; ---------------------------------------------------------------------------
ShowTuner() {
    global TunerGui, TunerProf

    if (TunerVals.Length != Mons.Length)
        TunerInitVals()

    if (TunerProf = "" || !TunerHasProfile(TunerProf))
        TunerProf := Profiles.Length ? Profiles[1] : ""

    if (TunerProf != "")
        TunerLoadProfile(TunerProf)

    TunerBuild()
    TunerGui.Show()
}

TunerHasProfile(name) {
    for p in Profiles
        if (p = name)
            return true
    return false
}

TunerInitVals() {
    global TunerVals := []
    for m in Mons {
        TunerVals.Push({ include: true
                       , bright: 50
                       , useContrast: false
                       , contrast: 50
                       , soft: false
                       , level: 100          ; 5..100  -> 0.05..1.00
                       , gamma: 100          ; 30..300 -> 0.30..3.00
                       , warmth: 0           ; 0..100  -> 0.00..1.00
                       , dev: ResolveDisplayDevice(m.key, m.id) })
    }
}

; ---------------------------------------------------------------------------
;  config.ini -> the model
; ---------------------------------------------------------------------------
TunerLoadProfile(name) {
    global TunerProf := name

    for i, m in Mons {
        v := TunerVals[i]

        raw := Clean(IniRead(CfgFile, "Profile." name, m.name, ""))
        if (raw = "") {
            v.include := false
        } else {
            v.include := true
            parts := StrSplit(raw, ",")
            v.bright := TunerNum(parts[1], v.bright)
            if (parts.Length > 1) {
                v.useContrast := true
                v.contrast := TunerNum(parts[2], v.contrast)
            } else {
                v.useContrast := false
            }
        }

        soft := Clean(IniRead(CfgFile, "Soft." name, m.name, ""))
        if (soft = "") {
            v.soft   := false
            v.level  := 100
            v.gamma  := 100
            v.warmth := 0
        } else {
            sp := StrSplit(soft, ",")
            v.soft   := true
            v.level  := TunerPct(sp.Has(1) ? sp[1] : "", 100)
            v.gamma  := TunerPct(sp.Has(2) ? sp[2] : "", 100)
            v.warmth := TunerPct(sp.Has(3) ? sp[3] : "", 0)
        }

        ; Windows reassigns \\.\DISPLAYn at boot, so re-resolve from the EDID
        ; key rather than trusting anything cached.
        v.dev := ResolveDisplayDevice(m.key, m.id)
    }
}

TunerNum(s, fallback) {
    s := Trim(s)
    return (s != "" && IsNumber(s)) ? Round(Number(s)) : fallback
}

; "0.45" -> 45 slider units
TunerPct(s, fallback) {
    s := Trim(s)
    return (s != "" && IsNumber(s)) ? Round(Number(s) * 100) : fallback
}

; Pull whatever the monitors are showing right now into the sliders, so a
; level dialled in on the monitor's own OSD can be captured as a profile.
TunerReadLive() {
    for i, m in Mons {
        v := TunerVals[i]
        if (m.type = "Internal" || m.target = "")
            continue
        b := RunWait('"' CMM '" /GetValue "' m.target '" 10', , "Hide")
        if (b >= 0 && b <= 100)
            v.bright := b
        if (v.useContrast) {
            c := RunWait('"' CMM '" /GetValue "' m.target '" 12', , "Hide")
            if (c >= 0 && c <= 100)
                v.contrast := c
        }
    }
    TunerRefresh()
    Flash("Read the current values off the monitors")
}

; ---------------------------------------------------------------------------
;  The window. Rebuilt from scratch when the soft-dim rows are toggled - two
;  fixed layouts is far less code than reflowing one.
; ---------------------------------------------------------------------------
TunerBuild() {
    global TunerGui, TunerRows, TunerDdl, TunerHint

    if (TunerGui) {
        try TunerGui.Destroy()
        TunerGui := ""
    }
    TunerRows := []

    W    := 496          ; content width
    LBL  := 78           ; label column
    SLD  := 288          ; slider column
    VAL  := 60           ; readout column
    xLbl := 22
    xSld := xLbl + LBL
    xVal := xSld + SLD + 8

    g := Gui("-MaximizeBox", "MonitorControls - Tune profile")
    g.SetFont("s9", "Segoe UI")
    g.MarginX := 12
    g.MarginY := 12
    TunerGui := g

    ; --- header ------------------------------------------------------------
    g.Add("Text", "xm ym w46 h23 +0x200", "Profile")
    TunerDdl := g.Add("DropDownList", "x+4 yp w150 h300", Profiles)
    TunerSelectProfile(TunerProf)
    TunerDdl.OnEvent("Change", (*) => TunerPickProfile())

    g.Add("Button", "x+8 yp w86 h23", "Revert").OnEvent("Click", (*) => TunerRevert())
    g.Add("Button", "x+6 yp w96 h23", "Read screens").OnEvent("Click", (*) => TunerReadLive())

    TunerHint := g.Add("Text", "xm y+8 w" W " cGray", "")
    TunerSetHint()

    ; --- one block per monitor ---------------------------------------------
    for i, m in Mons {
        v := TunerVals[i]
        row := {}

        g.SetFont("s9 bold")
        row.inc := g.Add("Checkbox", "xm y+10 w" W " h20"
                       , m.name "    " m.label (m.type = "Internal" ? "   (built-in)" : ""))
        row.inc.Value := v.include
        row.inc.OnEvent("Click", TunerToggleInclude.Bind(i))
        g.SetFont("s9 norm")

        row.b  := g.Add("Slider", "x" xSld " y+6 w" SLD " Range0-100 Page5 NoTicks", v.bright)
        row.bl := g.Add("Text", "x" xLbl " yp+2 w" LBL " h20", "Brightness")
        row.bv := g.Add("Text", "x" xVal " yp w" VAL " h20", v.bright)
        row.b.OnEvent("Change", TunerBright.Bind(i))

        if (m.type != "Internal") {
            row.con   := g.Add("Slider", "x" xSld " y+6 w" SLD " Range0-100 Page5 NoTicks", v.contrast)
            row.conOn := g.Add("Checkbox", "x" xLbl " yp+2 w" LBL " h20", "Contrast")
            row.conOn.Value := v.useContrast
            row.conOn.OnEvent("Click", TunerToggleContrast.Bind(i))
            row.conv := g.Add("Text", "x" xVal " yp w" VAL " h20", v.contrast)
            row.con.OnEvent("Change", TunerContrast.Bind(i))
        }

        if (TunerSoft) {
            row.softOn := g.Add("Checkbox", "x" xLbl " y+8 w" (W - 20) " h20"
                              , "Soft dim on the GPU - goes below the panel's own 0")
            row.softOn.Value := v.soft
            row.softOn.OnEvent("Click", TunerToggleSoft.Bind(i))

            row.lvl := g.Add("Slider", "x" xSld " y+4 w" SLD " Range5-100 Page5 NoTicks", v.level)
            g.Add("Text", "x" xLbl " yp+2 w" LBL " h20", "   Output")
            row.lvlv := g.Add("Text", "x" xVal " yp w" VAL " h20", v.level "%")
            row.lvl.OnEvent("Change", TunerSoftChange.Bind(i))

            row.gam := g.Add("Slider", "x" xSld " y+4 w" SLD " Range30-300 Page10 NoTicks", v.gamma)
            g.Add("Text", "x" xLbl " yp+2 w" LBL " h20", "   Gamma")
            row.gamv := g.Add("Text", "x" xVal " yp w" VAL " h20", TunerF2(v.gamma))
            row.gam.OnEvent("Change", TunerSoftChange.Bind(i))

            row.wrm := g.Add("Slider", "x" xSld " y+4 w" SLD " Range0-100 Page5 NoTicks", v.warmth)
            g.Add("Text", "x" xLbl " yp+2 w" LBL " h20", "   Warmth")
            row.wrmv := g.Add("Text", "x" xVal " yp w" VAL " h20", TunerF2(v.warmth))
            row.wrm.OnEvent("Change", TunerSoftChange.Bind(i))
        }

        TunerRows.Push(row)
        TunerEnableRow(i)
        g.Add("Text", "xm y+10 w" W " h1 +0x10")     ; separator
    }

    ; --- footer ------------------------------------------------------------
    cLive := g.Add("Checkbox", "xm y+10 h20", "Live preview")
    cLive.Value := TunerLive
    cLive.OnEvent("Click", TunerSetLive)

    cLink := g.Add("Checkbox", "x+14 yp h20", "Link brightness")
    cLink.Value := TunerLink
    cLink.OnEvent("Click", TunerSetLink)

    cSoft := g.Add("Checkbox", "x+14 yp h20", "GPU soft dim")
    cSoft.Value := TunerSoft
    cSoft.OnEvent("Click", TunerSetSoftRows)

    g.Add("Button", "xm y+12 w96 h26", "Apply now").OnEvent("Click", (*) => TunerApplyAll())
    g.Add("Button", "x+6 yp w120 h26 Default", "Save").OnEvent("Click", (*) => TunerSave(TunerProf))
    g.Add("Button", "x+6 yp w110 h26", "Save as new...").OnEvent("Click", (*) => TunerSaveAs())
    g.Add("Button", "x+6 yp w56 h26", "Close").OnEvent("Click", (*) => TunerGui.Hide())

    g.OnEvent("Close",  (*) => TunerGui.Hide())
    g.OnEvent("Escape", (*) => TunerGui.Hide())
}

TunerF2(sliderUnits) => Format("{:.2f}", sliderUnits / 100.0)

; Select by index, not by .Text - assigning a name the list does not contain
; throws "Invalid value", and the list is one failed config write away from
; not containing a profile we just saved.
TunerSelectProfile(name) {
    for j, p in Profiles {
        if (p = name) {
            TunerDdl.Choose(j)
            return j
        }
    }
    if Profiles.Length
        TunerDdl.Choose(1)
    return 0
}

TunerSetHint() {
    if !TunerHint
        return
    TunerHint.Value := "Editing [Profile." TunerProf "] in " RegExReplace(CfgFile, ".*\\", "")
                     . "  -  unticked monitors are left alone by this profile."
}

TunerSetLive(ctrl, *) {
    global TunerLive := ctrl.Value
}

TunerSetLink(ctrl, *) {
    global TunerLink := ctrl.Value
}

TunerSetSoftRows(ctrl, *) {
    global TunerSoft := ctrl.Value
    TunerBuild()
    TunerGui.Show()
}

; ---------------------------------------------------------------------------
;  Push the model back into the controls, without changing the layout.
; ---------------------------------------------------------------------------
TunerRefresh() {
    global TunerBusy := true
    for i, row in TunerRows {
        v := TunerVals[i]
        row.inc.Value := v.include
        row.b.Value   := v.bright
        row.bv.Value  := v.bright
        if row.HasProp("con") {
            row.conOn.Value := v.useContrast
            row.con.Value   := v.contrast
            row.conv.Value  := v.contrast
        }
        if row.HasProp("lvl") {
            row.softOn.Value := v.soft
            row.lvl.Value    := v.level
            row.lvlv.Value   := v.level "%"
            row.gam.Value    := v.gamma
            row.gamv.Value   := TunerF2(v.gamma)
            row.wrm.Value    := v.warmth
            row.wrmv.Value   := TunerF2(v.warmth)
        }
        TunerEnableRow(i)
    }
    global TunerBusy := false
    TunerSetHint()
}

TunerEnableRow(i) {
    row := TunerRows[i]
    v   := TunerVals[i]

    row.b.Enabled := v.include
    if row.HasProp("con") {
        row.conOn.Enabled := v.include
        row.con.Enabled   := v.include && v.useContrast
    }
    if row.HasProp("lvl") {
        ; A monitor that is not attached right now has no \\.\DISPLAYn, so
        ; there is nothing to hang a gamma ramp on.
        attached := (v.dev != "")
        row.softOn.Enabled := v.include && attached
        on := v.include && v.soft && attached
        row.lvl.Enabled := on
        row.gam.Enabled := on
        row.wrm.Enabled := on
    }
}

; ---------------------------------------------------------------------------
;  Slider and checkbox handlers
; ---------------------------------------------------------------------------
TunerBright(i, ctrl, *) {
    if TunerBusy
        return
    v := TunerVals[i]
    delta := ctrl.Value - v.bright
    v.bright := ctrl.Value
    TunerRows[i].bv.Value := v.bright
    TunerMark(i)

    ; Linked mode moves the others by the same STEP, not to the same value.
    ; Different panels sit at wildly different numbers for the same apparent
    ; brightness - Left 20 against Right 45 here - so matching them outright
    ; would throw away the balance you just spent time finding.
    if (TunerLink && delta != 0) {
        global TunerBusy := true
        for j, other in TunerVals {
            if (j = i || !other.include)
                continue
            other.bright := Clamp(other.bright + delta, 0, 100)
            TunerRows[j].b.Value  := other.bright
            TunerRows[j].bv.Value := other.bright
            TunerMark(j)
        }
        global TunerBusy := false
    }
    TunerSchedule()
}

TunerContrast(i, ctrl, *) {
    if TunerBusy
        return
    TunerVals[i].contrast := ctrl.Value
    TunerRows[i].conv.Value := ctrl.Value
    TunerMark(i)
    TunerSchedule()
}

TunerSoftChange(i, *) {
    if TunerBusy
        return
    row := TunerRows[i]
    v   := TunerVals[i]
    v.level  := row.lvl.Value
    v.gamma  := row.gam.Value
    v.warmth := row.wrm.Value
    row.lvlv.Value := v.level "%"
    row.gamv.Value := TunerF2(v.gamma)
    row.wrmv.Value := TunerF2(v.warmth)
    if TunerLive
        TunerApplySoft(i)          ; a DllCall, so no debounce needed
}

TunerToggleInclude(i, ctrl, *) {
    TunerVals[i].include := ctrl.Value
    TunerEnableRow(i)
    if TunerLive {
        if ctrl.Value
            TunerApplyOne(i)
        TunerApplySoft(i)          ; unticking has to lift any ramp too
    }
}

TunerToggleContrast(i, ctrl, *) {
    TunerVals[i].useContrast := ctrl.Value
    TunerEnableRow(i)
    if (TunerLive && ctrl.Value) {
        TunerMark(i)
        TunerSchedule()
    }
}

TunerToggleSoft(i, ctrl, *) {
    TunerVals[i].soft := ctrl.Value
    TunerEnableRow(i)
    if TunerLive
        TunerApplySoft(i)          ; unticking resets the ramp
}

TunerPickProfile() {
    name := TunerDdl.Text
    if (name = "")
        return
    TunerLoadProfile(name)
    TunerRefresh()
    if TunerLive
        TunerApplyAll()
}

TunerRevert() {
    TunerLoadProfile(TunerProf)
    TunerRefresh()
    TunerApplyAll()
    Flash("Reverted to the saved '" TunerProf "'")
}

; ---------------------------------------------------------------------------
;  Applying
;
;  DDC/CI costs roughly 50-150 ms a call, so a slider drag is coalesced into
;  one pass 180 ms after the last movement rather than one call per tick.
; ---------------------------------------------------------------------------
TunerMark(i) {
    TunerDirty[i] := true
}

TunerSchedule() {
    if TunerLive
        SetTimer(TunerFlush, -180)
}

TunerFlush() {
    pending := TunerDirty
    global TunerDirty := Map()
    for i in pending
        TunerApplyOne(i)
}

TunerApplyOne(i) {
    m := Mons[i]
    v := TunerVals[i]
    if !v.include
        return

    if (m.type = "Internal") {
        PsRun("Adjust-Brightness.ps1", "-Set " v.bright " -Only " m.name)
        return
    }
    if (m.target = "")
        return

    CmmRun('/SetValueIfNeeded "' m.target '" 10 ' v.bright)
    if v.useContrast
        CmmRun('/SetValueIfNeeded "' m.target '" 12 ' v.contrast)
}

TunerApplySoft(i) {
    v := TunerVals[i]
    if (v.dev = "")
        return

    if (!v.include || !v.soft) {
        ResetGammaRamp(v.dev)
        return
    }

    res := ApplyGammaRamp(v.dev, BuildGammaRamp(v.level / 100.0, v.gamma / 100.0, v.warmth / 100.0))
    if (res.clamped)
        Flash(Mons[i].name ": Windows clamped that ramp.`nRun Set-SoftDim.ps1 -EnableDeepDim from an admin window, then sign out and back in.")
    else if (!res.applied)
        Flash(Mons[i].name ": the display refused the gamma ramp.")
}

TunerApplyAll() {
    global TunerDirty := Map()
    for i, v in TunerVals {
        TunerApplyOne(i)
        TunerApplySoft(i)
    }
}

; ---------------------------------------------------------------------------
;  Saving - straight back into config.ini, so a tuned profile is an ordinary
;  profile that the hotkeys, the tray menu and Set-Profile.ps1 all pick up.
; ---------------------------------------------------------------------------
TunerSave(name) {
    if (name = "") {
        TunerSaveAs()
        return
    }

    ; IniWrite edits in place and cannot be undone, and config.ini is hand
    ; commented - keep one copy back.
    try FileCopy(CfgFile, CfgFile ".bak", true)

    ; Two passes so the [Profile.x] keys land together and the [Soft.x] keys
    ; land together, instead of Windows interleaving two new sections.
    if TunerSectionIsNew("Profile." name)
        TunerEndWithBlankLine()

    for i, m in Mons {
        v := TunerVals[i]
        if !v.include {
            try IniDelete(CfgFile, "Profile." name, m.name)
            continue
        }
        val := "" v.bright
        if (m.type != "Internal" && v.useContrast)
            val .= "," v.contrast
        IniWrite(val, CfgFile, "Profile." name, m.name)
    }

    softNew := TunerSectionIsNew("Soft." name)
    for i, m in Mons {
        v := TunerVals[i]
        if (!v.include || !v.soft) {
            try IniDelete(CfgFile, "Soft." name, m.name)
            continue
        }
        if softNew {
            TunerEndWithBlankLine()
            softNew := false
        }
        IniWrite(Format("{:.2f},{:.2f},{:.2f}", v.level / 100.0, v.gamma / 100.0, v.warmth / 100.0)
               , CfgFile, "Soft." name, m.name)
    }

    ; A profile that did not exist a moment ago needs a tray entry and a
    ; Ctrl+Alt+n of its own.
    LoadConfig()
    BuildTray()
    BuildHotkeys()

    global TunerProf := name
    TunerDdl.Delete()
    TunerDdl.Add(Profiles)
    idx := TunerSelectProfile(name)
    TunerSetHint()

    Flash("Saved [Profile." name "]" (idx && idx <= 9 ? "   -   Ctrl+Alt+" idx : ""))
}

TunerSectionIsNew(section) {
    return (IniRead(CfgFile, section, , "") = "")
}

; Windows appends a brand new section straight onto the last line, which turns
; a hand-commented config into a wall of text after a few saves. Give it a
; blank line to land after.
TunerEndWithBlankLine() {
    try {
        txt := FileRead(CfgFile)
        if (txt = "" || RegExMatch(txt, "\R\R$"))
            return
        FileAppend(RegExMatch(txt, "\R$") ? "`r`n" : "`r`n`r`n", CfgFile)
    }
}

TunerSaveAs() {
    ib := InputBox("Name for the new profile - letters, digits and underscores only.`n"
                 . "It becomes a [Profile.<name>] section in config.ini."
                 , "Save as new profile", "w380 h150", TunerProf)
    if (ib.Result != "OK")
        return

    name := Trim(ib.Value)
    if !RegExMatch(name, "^[A-Za-z0-9_]+$") {
        MsgBox "'" name "' is not a usable profile name.`n`nUse letters, digits and underscores only.", "MonitorControls", "Icon!"
        return
    }
    TunerSave(name)
}
