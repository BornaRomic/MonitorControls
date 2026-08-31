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
;    Ctrl+Alt+T           open the tuner: sliders per monitor, live preview
;    Ctrl+Alt+M           open the ControlMyMonitor GUI
;    Ctrl+Alt+R           reload after editing config.ini
;
;  External monitors are driven by calling ControlMyMonitor directly (fast).
;  The built-in laptop panel needs WMI, so that one call goes out through
;  Set-Profile.ps1 in the background.
; ===========================================================================

SetWorkingDir A_ScriptDir

; Gdi.ahk  - EnumDisplayDevices and the gamma-ramp DllCalls, so the tuner can
;            move a ramp on every slider tick without spawning PowerShell.
; Tuner.ahk - the Ctrl+Alt+T window.
#Include lib\Gdi.ahk
#Include Tuner.ahk

global CfgFile := ""
global CMM := ""
global Mons := []
global Profiles := []
global ShowFeedback := true
global NudgeStep := 10
global SwitchDelay := 250
global RotateTarget := "Right"

LoadConfig()
BuildTray()
BuildHotkeys()

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

; The Windows INI API keeps inline comments, so strip a trailing "; ..." here.
Clean(v) {
    return Trim(RegExReplace(v, "\s*;.*$", ""))
}

NumOr(v, fallback) => (v != "" && IsInteger(v)) ? Integer(v) : fallback

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
    Hotkey("^!Up",   (*) => Nudge(NudgeStep))
    Hotkey("^!Down", (*) => Nudge(-NudgeStep))
    Hotkey("^!t",    (*) => ShowTuner())
    Hotkey("^!m",    (*) => Run('"' . CMM . '"'))
    Hotkey("^!r",    (*) => Reload())
}

ApplyProfileHK(name, *) => ApplyProfile(name)

; ---------------------------------------------------------------------------
CmmRun(args) {
    global CMM
    RunWait('"' CMM '" ' args, , "Hide")
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
ApplyProfile(name) {
    parts := []

    for m in Mons {
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
        if (m.target = "")
            continue

        CmmRun('/SetValueIfNeeded "' m.target '" 10 ' bright)
        if (contrast != "")
            CmmRun('/SetValueIfNeeded "' m.target '" 12 ' contrast)
        parts.Push(m.name ": " bright (contrast != "" ? "/" contrast : ""))
    }

    ; Always run the non-DDC pass, even with no internal panel on this machine:
    ; the GPU gamma ramps (soft dimming) have to be applied for profiles that
    ; define one, and CLEARED for profiles that do not - otherwise switching
    ; back to a day profile would leave the screen dimmed.
    PsRun("Set-Profile.ps1", "-Name " name " -NonDdcOnly")

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

Nudge(delta) {
    for m in Mons {
        if (m.type = "Internal")
            continue
        if (m.target != "")
            CmmRun('/ChangeValue "' m.target '" 10 ' delta)
    }
    hasInternal := false
    for m in Mons
        if (m.type = "Internal")
            hasInternal := true
    if hasInternal
        PsRun("Adjust-Brightness.ps1", "-Delta " delta " -InternalOnly")
    Flash("Brightness " (delta > 0 ? "+" : "") delta)
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

Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") . v
    return out
}
