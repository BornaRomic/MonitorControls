; ===========================================================================
;  Util.ahk - small pure helpers shared by every other .ahk file here.
;
;  Nothing in this file touches a monitor, the config, or the screen, which is
;  what makes it the one piece the tests can exercise directly.
;
;  Included FIRST by MonitorControls.ahk. The other files never include it -
;  AutoHotkey has no include-once, so a second #Include of the same file is a
;  duplicate-function error at load.
; ===========================================================================

; The Windows INI API keeps inline comments, so strip a trailing "; ..." here.
Clean(v) {
    return Trim(RegExReplace(v, "\s*;.*$", ""))
}

NumOr(v, fallback)   => (v != "" && IsInteger(v)) ? Integer(v) : fallback
FloatOr(v, fallback) => (v != "" && IsNumber(v))  ? Number(v)  : fallback

Clamp(v, lo, hi) => (v < lo) ? lo : ((v > hi) ? hi : v)

Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") . v
    return out
}

; "5:6500K, 11:User 1"  ->  [{val:5, label:"6500K"}, {val:11, label:"User 1"}]
; A bare "5" is accepted too and picks up the standard MCCS name.
ParsePresets(raw) {
    out := []
    for p in StrSplit(raw, ",") {
        p := Trim(p)
        if (p = "")
            continue
        if RegExMatch(p, "^(\d+)\s*:\s*(.+)$", &m)
            out.Push({ val: Integer(m[1]), label: Trim(m[2]) })
        else if IsInteger(p)
            out.Push({ val: Integer(p), label: PresetLabel(Integer(p)) })
    }
    return out
}

; The standard VCP 14 table, so a config with bare numbers still reads sensibly.
PresetLabel(v) {
    static names := Map(1, "sRGB", 2, "Display native", 3, "4000K", 4, "5000K"
                      , 5, "6500K", 6, "7500K", 7, "8200K", 8, "9300K"
                      , 9, "10000K", 10, "11500K", 11, "User 1", 12, "User 2"
                      , 13, "User 3")
    return names.Has(v) ? names[v] : ("Preset " v)
}
