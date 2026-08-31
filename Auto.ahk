; ===========================================================================
;  Auto.ahk - the things that happen without you pressing anything.
;
;    1. Time of day   apply a profile at a clock time, or at sunrise / sunset
;    6. Focus dim     pull down the screens the active window is NOT on
;    7. Idle dim      pull everything down after a spell of no input
;
;  All three only ever move the multipliers in Dimmer.ahk and ask it to
;  re-commit, so they compose with each other and with the profile instead of
;  fighting over the gamma ramp.
;
;  One 250 ms timer drives the lot. Focus and idle are checked every tick;
;  the schedule, which only needs minute resolution, every 60th.
; ===========================================================================

global AutoSchedule := []      ; [{ name, kind, mins, offset }]
global SchedOn      := false
global SchedLast    := -1      ; index of the entry currently in force
global SchedCache   := Map()   ; "YYYYMMDD|sunrise" -> minutes past midnight

global FocusDim     := 0.0     ; 0 = off, else the level unfocused screens go to
global FocusDelay   := 600
global FocusDev     := ""
global FocusSeenDev := ""
global FocusSeenAt  := 0

global IdleAfter    := 0       ; seconds, 0 = off
global IdleLevel    := 0.35
global IdleFadeMs   := 1500
global IdleIsDim    := false

global Latitude     := 0.0
global Longitude    := 0.0

global AutoTickN    := 0
global AutoRunning  := false

; ---------------------------------------------------------------------------
AutoStart() {
    global AutoRunning
    ; Only pay for the timer if something actually uses it.
    want := (AutoSchedule.Length && SchedOn) || (FocusDim > 0) || (IdleAfter > 0)
    if (want && !AutoRunning) {
        AutoRunning := true
        SetTimer(AutoTick, 250)
    } else if (!want && AutoRunning) {
        AutoRunning := false
        SetTimer(AutoTick, 0)
    }
}

AutoStop() {
    global AutoRunning := false
    SetTimer(AutoTick, 0)
}

AutoTick() {
    global AutoTickN := AutoTickN + 1

    if (IdleAfter > 0)
        IdleCheck()
    if (FocusDim > 0)
        FocusCheck()
    if (SchedOn && AutoSchedule.Length && Mod(AutoTickN, 60) = 0)
        SchedCheck()
}

; ===========================================================================
;  7. Idle dim
; ===========================================================================
IdleCheck() {
    ; A_TimeIdlePhysical ignores synthetic input, so a script moving the mouse
    ; does not count as you being at the desk.
    idle := A_TimeIdlePhysical >= (IdleAfter * 1000)

    if (idle = IdleIsDim)
        return
    global IdleIsDim := idle

    for i, d in Dim
        DimSetIdle(i, idle ? IdleLevel : 1.0)

    ; Slow on the way down so it is not startling, quick on the way back so the
    ; screen is usable by the time you have finished moving the mouse.
    DimCommit(idle ? IdleFadeMs : 250)
}

; ===========================================================================
;  6. Focus dim
; ===========================================================================
FocusCheck() {
    dev := ActiveMonitorDevice()
    if (dev = "")
        return

    ; The tuner is where you judge how a profile looks. Dimming two thirds of
    ; the desk the moment it opens would make that impossible.
    if (TunerGui && WinExist("ahk_id " TunerGui.Hwnd) && DllCall("IsWindowVisible", "ptr", TunerGui.Hwnd)) {
        if (FocusDev != "") {
            FocusApply("")
        }
        return
    }

    ; Settle before acting: alt-tabbing through windows would otherwise fire a
    ; fade per window, and a click on the far screen and back would flicker.
    if (dev != FocusSeenDev) {
        global FocusSeenDev := dev
        global FocusSeenAt  := A_TickCount
        return
    }
    if (dev = FocusDev)
        return
    if (A_TickCount - FocusSeenAt < FocusDelay)
        return

    FocusApply(dev)
}

; dev "" means "no screen is favoured" - everything back to full.
FocusApply(dev) {
    global FocusDev := dev
    for i, d in Dim
        DimSetFocus(i, (dev = "" || d.dev = dev) ? 1.0 : FocusDim)
    DimCommit()
}

FocusSetEnabled(level) {
    global FocusDim := level
    if (level <= 0)
        FocusApply("")
    else
        FocusApply(ActiveMonitorDevice())
    AutoStart()
}

; ===========================================================================
;  1. Time of day
;
;  AutoProfile=Day@sunrise, CodeNight@sunset-30, Night@23:00
;
;  An entry is "in force" from its own time until the next one. Whichever is
;  in force when the script starts is applied at once, so launching at 21:00
;  lands on the evening profile rather than waiting until tomorrow morning.
; ===========================================================================
SchedParse(raw) {
    global AutoSchedule := []
    for part in StrSplit(raw, ",") {
        part := Trim(part)
        if (part = "")
            continue
        if !RegExMatch(part, "^(.+?)@(.+)$", &m)
            continue

        name := Trim(m[1])
        when := Trim(m[2])
        if (name = "")
            continue

        if RegExMatch(when, "i)^(sunrise|sunset)\s*([+-]\s*\d+)?$", &sm) {
            off := sm.Count >= 2 && sm[2] != "" ? Integer(RegExReplace(sm[2], "\s", "")) : 0
            AutoSchedule.Push({ name: name, kind: StrLower(sm[1]), mins: -1, offset: off })
        } else if RegExMatch(when, "^(\d{1,2}):(\d{2})$", &tm) {
            h := Integer(tm[1]), mi := Integer(tm[2])
            if (h < 0 || h > 23 || mi < 0 || mi > 59)
                continue
            AutoSchedule.Push({ name: name, kind: "clock", mins: h * 60 + mi, offset: 0 })
        }
    }
}

; Minutes past local midnight for one entry, today.
SchedMinutes(e) {
    if (e.kind = "clock")
        return e.mins

    key := FormatTime(A_Now, "yyyyMMdd") "|" e.kind
    if !SchedCache.Has(key)
        SchedCache[key] := SunMinutes(Latitude, Longitude, e.kind = "sunset")
    base := SchedCache[key]
    if (base < 0)
        return -1
    m := base + e.offset
    while (m < 0)
        m += 1440
    while (m >= 1440)
        m -= 1440
    return m
}

; Index of the entry in force right now, or 0 if the schedule is unusable.
SchedCurrent() {
    now := A_Hour * 60 + A_Min
    best := 0, bestM := -1
    ; The latest entry at or before now.
    for i, e in AutoSchedule {
        m := SchedMinutes(e)
        if (m < 0 || m > now)
            continue
        if (m >= bestM) {
            bestM := m
            best := i
        }
    }
    if (best)
        return best
    ; Before the first entry of the day, so yesterday's last one still stands.
    lateM := -1
    for i, e in AutoSchedule {
        m := SchedMinutes(e)
        if (m < 0)
            continue
        if (m >= lateM) {
            lateM := m
            best := i
        }
    }
    return best
}

SchedCheck() {
    idx := SchedCurrent()
    if (!idx || idx = SchedLast)
        return
    global SchedLast := idx
    ApplyProfile(AutoSchedule[idx].name)
}

; Called after any manual profile change, so the schedule does not immediately
; undo it. The current entry is marked as already handled; the next boundary
; still fires normally.
SchedMarkManual() {
    if AutoSchedule.Length
        global SchedLast := SchedCurrent()
}

SchedDescribe() {
    if !AutoSchedule.Length
        return "no schedule"
    out := []
    for i, e in AutoSchedule {
        m := SchedMinutes(e)
        when := (m < 0) ? "n/a" : Format("{:02d}:{:02d}", m // 60, Mod(m, 60))
        if (e.kind != "clock")
            when .= " (" e.kind (e.offset ? Format("{:+d}", e.offset) : "") ")"
        out.Push(e.name " " when (i = SchedLast ? "  <- now" : ""))
    }
    return Join(out, "`n")
}

; ---------------------------------------------------------------------------
;  Sunrise / sunset, NOAA's approximation.
;
;  Accurate to a couple of minutes, which is far better than "dim at dusk"
;  needs, and it is arithmetic - no network, no API key, nothing to expire.
;  Longitude is positive EAST.
; ---------------------------------------------------------------------------
SunMinutes(lat, lon, isSunset) {
    static PI := 3.141592653589793

    if (lat = 0 && lon = 0)
        return -1                     ; not configured

    ; Day of the year.
    n := DateDiff(FormatTime(A_Now, "yyyyMMdd"), FormatTime(A_Now, "yyyy") "0101", "Days") + 1

    g := (2 * PI / 365.0) * (n - 1 + 0.5)

    eq := 229.18 * (0.000075
                  + 0.001868 * Cos(g)   - 0.032077 * Sin(g)
                  - 0.014615 * Cos(2*g) - 0.040849 * Sin(2*g))

    dec := 0.006918
         - 0.399912 * Cos(g)   + 0.070257 * Sin(g)
         - 0.006758 * Cos(2*g) + 0.000907 * Sin(2*g)
         - 0.002697 * Cos(3*g) + 0.001480 * Sin(3*g)

    latR := lat * PI / 180.0
    zen  := 90.833 * PI / 180.0        ; sun's centre, refraction included

    c := (Cos(zen) / (Cos(latR) * Cos(dec))) - (Tan(latR) * Tan(dec))
    if (c > 1.0 || c < -1.0)
        return -1                      ; polar day or polar night

    ha := ACos(c) * 180.0 / PI         ; hour angle, degrees
    if isSunset
        ha := -ha

    utc := 720 - 4 * (lon + ha) - eq

    ; Local time, with whatever DST is in force today.
    m := utc + DateDiff(A_Now, A_NowUTC, "Minutes")
    while (m < 0)
        m += 1440
    while (m >= 1440)
        m -= 1440
    return Round(m)
}
