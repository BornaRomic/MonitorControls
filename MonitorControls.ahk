#Requires AutoHotkey v2.0
#SingleInstance Force
; ===========================================================================
;  MonitorControls.ahk
;
;  Global hotkeys + tray menu for brightness profiles, input switching and
;  monitor power, driven entirely by config.ini sitting next to this file.
;
;  HOTKEYS
;    Ctrl+Alt+1 .. 9      apply profile 1..9 (in config.ini order)
;    Ctrl+Alt+P           switch external monitors to the PC input
;    Ctrl+Alt+L           switch external monitors to the laptop input
;    Ctrl+Alt+I           toggle each monitor between PC and laptop
;    Ctrl+Alt+0           blank / unblank the external monitors
;    Ctrl+Alt+O           rotate the RotateTarget monitor (landscape <-> portrait)
;    Ctrl+Alt+Shift+O     force that monitor back to landscape
;    Ctrl+Alt+Up/Down     nudge brightness on everything
;    Ctrl+Alt+Shift+Up/Down   nudge only the screen the active window is on
;    Ctrl+Alt+F           toggle dimming of the screens you are not using
;    Ctrl+Alt+T           open the tuner: sliders per monitor, live preview
;    Ctrl+Alt+M           open the ControlMyMonitor GUI
;    Ctrl+Alt+R           reload after editing config.ini
;
;  External monitors are driven by calling ControlMyMonitor directly (fast).
;  The built-in laptop panel needs WMI, so that one call goes out through
;  Set-Profile.ps1 in the background.
;
;  Gamma ramps belong to Dimmer.ahk and nothing else - the profile, focus dim
;  and idle dim all want to darken the same screen, so they are multiplied
;  together rather than each writing the ramp themselves.
; ===========================================================================

SetWorkingDir A_ScriptDir

; Util.ahk   - small pure helpers, shared and unit-testable.
; Gdi.ahk    - EnumDisplayDevices, monitor geometry and the gamma-ramp
;              DllCalls, so a slider or a fade needs no PowerShell.
; Dimmer.ahk - the only thing allowed to write a gamma ramp: it multiplies the
;              profile, focus dim and idle dim together, and cross-fades.
; Auto.ahk   - schedule, focus watcher, idle watcher.
; Tuner.ahk  - the Ctrl+Alt+T window.
#Include lib\Util.ahk
#Include lib\Gdi.ahk
#Include Dimmer.ahk
#Include Auto.ahk
#Include Tuner.ahk

global CfgFile := ""
global CMM := ""
global Mons := []
global Profiles := []
global ShowFeedback := true
global NudgeStep := 10
global SwitchDelay := 250
global RotateTarget := "Right"
global CurProfile := ""

LoadConfig()
DimInit()
BuildTray()
BuildHotkeys()
AutoStart()

; The gamma ramps live in the graphics driver, not in this process - exiting
; without putting them back would leave the desktop dimmed with nothing left
; running to explain why.
OnExit(OnQuit)
OnQuit(*) {
    DimResetAll()
}

; Apply whichever scheduled profile is in force right now, so starting the
; script in the evening lands on the evening profile.
if (SchedOn && AutoSchedule.Length)
    SchedCheck()

; ---------------------------------------------------------------------------
LoadConfig() {
    global
    ; A folder shared between machines keeps one config per machine. The two
    ; cannot share a file: different ports, different ControlMyMonitor path,
    ; and only a laptop has an internal panel.
    CfgFile := A_ScriptDir "\config." A_ComputerName ".ini"
    if !FileExist(CfgFile)
        CfgFile := A_ScriptDir "\config.ini"

    if !FileExist(CfgFile) {
        MsgBox "No config file found next to this script.`n`nLooked for:`n"
             . "    config." A_ComputerName ".ini`n"
             . "    config.ini`n`nRun 1-Detect.bat first.", "MonitorControls", "Iconx"
        ExitApp
    }

    CMM := Clean(IniRead(CfgFile, "Paths", "ControlMyMonitor", ""))
    if (CMM = "" || !FileExist(CMM)) {
        MsgBox "ControlMyMonitor.exe not found at:`n" CMM "`n`nFix the ControlMyMonitor= line under [Paths] in config.ini.", "MonitorControls", "Iconx"
        ExitApp
    }

    ShowFeedback := (Clean(IniRead(CfgFile, "Options", "ShowFeedback", "1")) != "0")
    NudgeStep    := NumOr(Clean(IniRead(CfgFile, "Options", "NudgeStep", "10")), 10)
    SwitchDelay  := NumOr(Clean(IniRead(CfgFile, "Options", "InputSwitchDelay", "250")), 250)
    RotateTarget := Clean(IniRead(CfgFile, "Options", "RotateTarget", "Right"))

    ; --- cross-fade ---------------------------------------------------------
    FadeMs       := NumOr(Clean(IniRead(CfgFile, "Options", "FadeMs", "450")), 450)
    FadeDdcSteps := NumOr(Clean(IniRead(CfgFile, "Options", "FadeDdcSteps", "4")), 4)

    ; --- schedule -----------------------------------------------------------
    Latitude  := FloatOr(Clean(IniRead(CfgFile, "Options", "Latitude", "")), 0.0)
    Longitude := FloatOr(Clean(IniRead(CfgFile, "Options", "Longitude", "")), 0.0)
    SchedParse(Clean(IniRead(CfgFile, "Options", "AutoProfile", "")))
    SchedOn   := AutoSchedule.Length > 0
    SchedLast := -1

    ; --- focus dim ----------------------------------------------------------
    FocusDim   := FloatOr(Clean(IniRead(CfgFile, "Options", "FocusDim", "0")), 0.0)
    FocusDelay := NumOr(Clean(IniRead(CfgFile, "Options", "FocusDimDelay", "600")), 600)
    if (FocusDim > 0 && FocusDim < 0.05)
        FocusDim := 0.05
    if (FocusDim > 1)
        FocusDim := 1.0

    ; --- idle dim -----------------------------------------------------------
    IdleAfter := NumOr(Clean(IniRead(CfgFile, "Options", "IdleDimAfter", "0")), 0)
    IdleLevel := FloatOr(Clean(IniRead(CfgFile, "Options", "IdleDimLevel", "0.35")), 0.35)
    IdleFadeMs := NumOr(Clean(IniRead(CfgFile, "Options", "IdleDimFadeMs", "1500")), 1500)
    IdleLevel := Clamp(IdleLevel, 0.05, 1.0)

    Mons := []
    for name in StrSplit(Clean(IniRead(CfgFile, "Monitors", "Names", "")), ",") {
        name := Trim(name)
        if (name = "")
            continue
        sec := "Monitor." name
        key    := Clean(IniRead(CfgFile, sec, "MonitorKey", ""))
        serial := Clean(IniRead(CfgFile, sec, "Serial", ""))
        id     := Clean(IniRead(CfgFile, sec, "Id", ""))

        ; What ControlMyMonitor gets handed. Never \\.\DISPLAYn - Windows
        ; renumbers those at boot. The hardware id is part of the panel.
        target := key != "" ? key : (serial != "" ? serial : id)

        Mons.Push({ name:   name
                  , label:  Clean(IniRead(CfgFile, sec, "Label", name))
                  , type:   Clean(IniRead(CfgFile, sec, "Type", "External"))
                  , id:     id
                  ; The EDID key on its own, kept separate from target: the
                  ; gamma ramps need it to look up the current \\.\DISPLAYn,
                  ; which ControlMyMonitor never sees.
                  , key:    key
                  , target: target
                  ; VCP 62 / 14. Declared in config rather than probed: a
                  ; monitor without speakers answers /GetValue 62 with a value
                  ; that looks perfectly valid, so probing invents features
                  ; that are not there. Detect-Monitors.ps1 fills these in.
                  , hasVol: Clean(IniRead(CfgFile, sec, "Volume", "0")) = "1"
                  , presets: ParsePresets(Clean(IniRead(CfgFile, sec, "Presets", "")))
                  , pc:     Clean(IniRead(CfgFile, sec, "InputPC", ""))
                  , lap:    Clean(IniRead(CfgFile, sec, "InputLaptop", "")) })
    }
    if (Mons.Length = 0) {
        MsgBox "No monitors listed under [Monitors] Names= in config.ini.", "MonitorControls", "Iconx"
        ExitApp
    }

    ; Discover [Profile.*] sections, keeping the order they appear in the file.
    Profiles := []
    for sec in StrSplit(IniRead(CfgFile), "`n") {
        sec := Trim(sec)
        if (SubStr(sec, 1, 8) = "Profile.")
            Profiles.Push(SubStr(sec, 9))
    }

    A_IconTip := "MonitorControls - " . RegExReplace(CfgFile, ".*\\", "") . "`n"
               . "Ctrl+Alt+1.." (Profiles.Length < 9 ? Profiles.Length : 9) " profiles, Ctrl+Alt+P/L input"
}


; ---------------------------------------------------------------------------
BuildTray() {
    T := A_TrayMenu
    T.Delete()
    for i, p in Profiles {
        label := (i <= 9) ? (p "`tCtrl+Alt+" i) : p
        T.Add(label, MenuProfile.Bind(p))
    }
    T.Add()
    T.Add("Input: PC`tCtrl+Alt+P",      MenuInput.Bind("pc"))
    T.Add("Input: Laptop`tCtrl+Alt+L",  MenuInput.Bind("lap"))
    T.Add("Input: toggle`tCtrl+Alt+I",  MenuInput.Bind("toggle"))
    T.Add()
    T.Add("Blank monitors`tCtrl+Alt+0", MenuPower.Bind("off"))
    T.Add("Wake monitors",              MenuPower.Bind("on"))
    T.Add()
    T.Add("Rotate " . RotateTarget . ": landscape`tCtrl+Alt+Shift+O", MenuRotate.Bind("Landscape"))
    T.Add("Rotate " . RotateTarget . ": portrait",                    MenuRotate.Bind("Portrait"))
    T.Add("Rotate " . RotateTarget . ": toggle`tCtrl+Alt+O",          MenuRotate.Bind("Toggle"))
    T.Add("Which screen is which?",                                   (*) => ShowDisplays())
    T.Add()
    if AutoSchedule.Length {
        T.Add("Auto profile by time", (*) => ToggleSchedule())
        if SchedOn
            T.Check("Auto profile by time")
        T.Add("Show schedule", (*) => MsgBox(SchedDescribe(), "MonitorControls - schedule", "Iconi"))
    }
    T.Add("Dim unfocused screens`tCtrl+Alt+F", (*) => ToggleFocusDim())
    if (FocusDim > 0)
        T.Check("Dim unfocused screens")
    T.Add("Dim when idle", (*) => ToggleIdleDim())
    if (IdleAfter > 0)
        T.Check("Dim when idle")
    T.Add()
    T.Add("Tune profile...`tCtrl+Alt+T", (*) => ShowTuner())
    T.Add("Show current values",         (*) => ShowStatus())
    T.Add("Edit config.ini",             (*) => Run('notepad.exe "' . CfgFile . '"'))
    T.Add("Open ControlMyMonitor",       (*) => Run('"' . CMM . '"'))
    T.Add("Reload`tCtrl+Alt+R",          (*) => Reload())
    T.Add("Exit",                        (*) => ExitApp())
}

MenuProfile(name, *) => ApplyProfile(name)
MenuInput(which, *)  => SwitchInput(which)
MenuPower(state, *)  => SetPower(state)
MenuRotate(o, *)     => Rotate(o)

; --- runtime toggles for the automatic behaviour ---------------------------
; These do not write to config.ini: they are "not right now", not "not ever".
ToggleSchedule() {
    global SchedOn := !SchedOn
    global SchedLast := -1
    AutoStart()
    if SchedOn
        SchedCheck()
    BuildTray()
    Flash("Auto profile by time: " (SchedOn ? "on" : "off"))
}

global FocusDimSaved := 0.45
ToggleFocusDim() {
    global FocusDimSaved
    if (FocusDim > 0) {
        FocusDimSaved := FocusDim
        FocusSetEnabled(0)
        Flash("Unfocused screens: no longer dimmed")
    } else {
        FocusSetEnabled(FocusDimSaved)
        Flash(Format("Unfocused screens dim to {:d}%", Round(FocusDimSaved * 100)))
    }
    BuildTray()
}

global IdleAfterSaved := 300
ToggleIdleDim() {
    global IdleAfter, IdleAfterSaved, IdleIsDim
    if (IdleAfter > 0) {
        IdleAfterSaved := IdleAfter
        IdleAfter := 0
        if IdleIsDim {
            IdleIsDim := false
            for i, d in Dim
                DimSetIdle(i, 1.0)
            DimCommit(250)
        }
        Flash("Idle dim: off")
    } else {
        IdleAfter := IdleAfterSaved
        Flash("Idle dim: after " IdleAfter " s")
    }
    AutoStart()
    BuildTray()
}

BuildHotkeys() {
    for i, p in Profiles {
        if (i > 9)
            break
        Hotkey("^!" . i, ApplyProfileHK.Bind(p))
    }
    Hotkey("^!p",    (*) => SwitchInput("pc"))
    Hotkey("^!l",    (*) => SwitchInput("lap"))
    Hotkey("^!i",    (*) => SwitchInput("toggle"))
    Hotkey("^!0",    (*) => SetPower("toggle"))
    Hotkey("^!o",    (*) => Rotate("Toggle"))
    Hotkey("^!+o",   (*) => Rotate("Landscape"))
    Hotkey("^!Up",    (*) => Nudge(NudgeStep))
    Hotkey("^!Down",  (*) => Nudge(-NudgeStep))
    ; Shift narrows the same gesture to the screen the active window is on.
    Hotkey("^!+Up",   (*) => Nudge(NudgeStep, true))
    Hotkey("^!+Down", (*) => Nudge(-NudgeStep, true))
    Hotkey("^!f",     (*) => ToggleFocusDim())
    Hotkey("^!t",     (*) => ShowTuner())
    Hotkey("^!m",     (*) => Run('"' . CMM . '"'))
    Hotkey("^!r",     (*) => Reload())
}

ApplyProfileHK(name, *) => ApplyProfile(name)

; ---------------------------------------------------------------------------
CmmRun(args) {
    global CMM
    RunWait('"' CMM '" ' args, , "Hide")
}

; Fire and forget. Only for intermediate fade steps, where waiting 50-150 ms
; for the panel to answer would stall the gamma fade on the same timer, and
; where a dropped write does not matter because the final step is synchronous.
CmmRunAsync(args) {
    global CMM
    try Run('"' CMM '" ' args, , "Hide")
}

PsRun(scriptName, args) {
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
         . A_ScriptDir . '\' . scriptName . '" ' . args
    Run(cmd, , "Hide")
}

; Same, but waits and hands back the exit code, so a failure can be surfaced
; instead of vanishing into a hidden window.
PsRunWait(scriptName, args) {
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
         . A_ScriptDir . '\' . scriptName . '" ' . args
    return RunWait(cmd, , "Hide")
}

; Re-runs a script in a console window that stays open, so the error is readable.
PsRunVisible(scriptName, args) {
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "'
         . A_ScriptDir . '\' . scriptName . '" ' . args
    Run(cmd)
}

Flash(text) {
    global ShowFeedback
    if !ShowFeedback
        return
    ToolTip text
    SetTimer(() => ToolTip(), -1400)
}

; ---------------------------------------------------------------------------
;  Apply a profile.
;
;  Brightness, contrast and the soft-dim base are handed to Dimmer.ahk, which
;  cross-fades them together on one timer. Volume and colour preset are set
;  outright - they are not visual, so there is nothing to ease.
;
;  The gamma ramps are NOT delegated to Set-Profile.ps1 any more: focus dim and
;  idle dim also move them, so they need a single owner inside this process.
;  PowerShell is still called for the internal panel's WMI brightness, with
;  -NoSoft so it keeps its hands off the ramps. Run on its own from a shell or
;  at logon, Set-Profile.ps1 still does the whole job.
; ---------------------------------------------------------------------------
ApplyProfile(name, fadeMs := -1) {
    global CurProfile := name
    parts := []

    for i, m in Mons {
        ; Soft dim first, and for EVERY monitor - a monitor with no entry in
        ; [Soft.<name>] must be reset to neutral, or switching from CodeNight
        ; back to Day would leave the screen dark.
        sraw := Clean(IniRead(CfgFile, "Soft." name, m.name, ""))
        if (sraw != "") {
            s := StrSplit(sraw, ",")
            DimSetBase(i, FloatOr(Trim(s[1]), 1.0)
                        , s.Length > 1 ? FloatOr(Trim(s[2]), 1.0) : 1.0
                        , s.Length > 2 ? FloatOr(Trim(s[3]), 0.0) : 0.0)
        } else {
            DimSetBase(i, 1.0, 1.0, 0.0)
        }

        raw := Clean(IniRead(CfgFile, "Profile." name, m.name, ""))
        if (raw = "")
            continue

        v := StrSplit(raw, ",")
        bright := Trim(v[1])
        contrast := v.Length > 1 ? Trim(v[2]) : ""

        if (m.type = "Internal") {
            parts.Push(m.name ": " bright "%")
            continue
        }
        if (m.target = "" || !IsInteger(bright))
            continue

        DimSetDdc(i, Integer(bright), (contrast != "" && IsInteger(contrast)) ? Integer(contrast) : -1)
        parts.Push(m.name ": " bright (contrast != "" ? "/" contrast : ""))

        vol := Clean(IniRead(CfgFile, "Volume." name, m.name, ""))
        if (vol != "" && IsInteger(vol) && m.hasVol) {
            CmmRun('/SetValueIfNeeded "' m.target '" 62 ' vol)
            parts.Push(m.name " vol " vol)
        }
        pre := Clean(IniRead(CfgFile, "Preset." name, m.name, ""))
        if (pre != "" && IsInteger(pre)) {
            CmmRun('/SetValueIfNeeded "' m.target '" 14 ' pre)
            parts.Push(m.name " " PresetLabel(Integer(pre)))
        }
    }

    DimCommit(fadeMs)
    PsRun("Set-Profile.ps1", "-Name " name " -NonDdcOnly -NoSoft")

    ; Choosing a profile by hand parks the schedule on the current slot, so it
    ; will not immediately overwrite the choice. The next boundary still fires.
    SchedMarkManual()

    Flash(parts.Length ? (name "  -  " Join(parts, "   ")) : ("Profile '" name "' matched no monitors"))
}

SwitchInput(which) {
    parts := []
    for m in Mons {
        if (m.type = "Internal" || m.target = "")
            continue

        want := ""
        if (which = "pc")
            want := m.pc
        else if (which = "lap")
            want := m.lap
        else {
            ; toggle: read the live value and flip
            if (m.pc = "" || m.lap = "")
                continue
            ; ControlMyMonitor returns the current value as its exit code
            if (!IsInteger(m.pc) || !IsInteger(m.lap)) {
                parts.Push(m.name ": bad input value")
                continue
            }
            cur := RunWait('"' . CMM . '" /GetValue "' . m.target . '" 60', , "Hide")
            want := (cur = Integer(m.pc)) ? m.lap : m.pc
        }

        if (want = "") {
            parts.Push(m.name ": not configured")
            continue
        }
        CmmRun('/SetValue "' m.target '" 60 ' want)
        parts.Push(m.name ": " want)
        if (SwitchDelay > 0)
            Sleep SwitchDelay
    }
    label := (which = "pc") ? "PC" : (which = "lap") ? "Laptop" : "toggled"
    Flash("Input -> " label "`n" Join(parts, "   "))
}

SetPower(state) {
    for m in Mons {
        if (m.type = "Internal" || m.target = "")
            continue
        if (state = "off")
            CmmRun('/SetValue "' m.target '" D6 4')
        else if (state = "on")
            CmmRun('/SetValue "' m.target '" D6 1')
        else
            CmmRun('/SwitchValue "' m.target '" D6 1 4')
    }
    Flash("Monitor power: " state)
}

; activeOnly restricts the nudge to the screen the active window is sitting on,
; which is what Ctrl+Alt+Shift+Up/Down does. Without it every monitor moves.
Nudge(delta, activeOnly := false) {
    only := 0
    if activeOnly {
        only := DimIndexOfDevice(ActiveMonitorDevice())
        if !only {
            Flash("Could not tell which screen is active")
            return
        }
    }

    hasInternal := false
    internalName := ""
    for i, m in Mons {
        if (only && i != only)
            continue
        if (m.type = "Internal") {
            hasInternal := true
            internalName := m.name
            continue
        }
        if (m.target != "") {
            CmmRun('/ChangeValue "' m.target '" 10 ' delta)
            ; The panel moved without going through a fade, so the value the
            ; fade engine thinks it last set is now wrong. Forget it rather
            ; than fading from a stale number next time.
            DimForgetDdc(i)
        }
    }
    if hasInternal
        PsRun("Adjust-Brightness.ps1", "-Delta " delta
            . (only ? (' -Only ' internalName) : " -InternalOnly"))

    Flash((only ? Mons[only].name " " : "Brightness ") (delta > 0 ? "+" : "") delta)
}

Rotate(orientation) {
    ; Rotation is a Windows display setting, not a DDC/CI one, so this goes
    ; through the PowerShell script rather than ControlMyMonitor.
    code := PsRunWait("Set-Orientation.ps1", "-Orientation " orientation)
    if (code = 0) {
        Flash(RotateTarget " -> " orientation)
        return
    }
    ; Don't pretend it worked - show the reason in a window that stays open.
    Flash("Rotation failed - opening the error")
    PsRunVisible("Set-Orientation.ps1", "-Orientation " orientation)
}

ShowDisplays() {
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "' . A_ScriptDir . '\Set-Orientation.ps1" -List')
}

ShowStatus() {
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "' . A_ScriptDir . '\Set-Profile.ps1" -List')
}
