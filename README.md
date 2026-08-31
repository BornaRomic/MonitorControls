# MonitorControls

Hotkey-driven brightness profiles and input switching for a laptop + 2 external
monitors, built on [ControlMyMonitor](https://www.nirsoft.net/utils/control_my_monitor.html)
and AutoHotkey v2.

Everything reads a single `config.ini`, so there's exactly one place to change a
number.

---

## Setup (about 5 minutes)

**1. Detect your hardware**

Double-click **`1-Detect.bat`**.

It finds `ControlMyMonitor.exe`, asks each display what it supports, and writes
`config.ini` pre-filled with your real monitor IDs, your *current* brightness
values, and the input your PC is plugged into. Raw reports land in `detected\`.

If it can't find ControlMyMonitor, either drop `ControlMyMonitor.exe` into this
folder and re-run, or run:

```powershell
.\Detect-Monitors.ps1 -CmmPath "C:\path\to\ControlMyMonitor.exe"
```

**2. Fill in the laptop input**

Open `config.ini`. Each external monitor has a commented list of the input
values it reports. `InputPC` is already filled in (it's whatever is active
right now). Set `InputLaptop` to the port your laptop's cable goes into:

```ini
[Monitor.Left]
;       15 = DisplayPort-1
;       17 = HDMI-1
;       18 = HDMI-2
InputPC=15
InputLaptop=17
```

Then adjust the numbers under `[Profile.Day]`, `[Profile.Night]`,
`[Profile.Movie]` to taste.

**3. Sanity check**

Double-click **`2-Test.bat`** — it prints every profile, every configured
input, and the live values straight off the monitors. Then try one for real:

```powershell
.\Set-Profile.ps1 -Name Night
```

**4. Turn on the hotkeys**

Install [AutoHotkey v2](https://www.autohotkey.com/) (v2 specifically — this
script won't run under v1), then double-click **`MonitorControls.ahk`**.
A tray icon appears with everything on a right-click menu.

To have the hotkeys load at every logon, run **`4-Startup-Task.bat`** ONCE.
It is a setup step, not the startup item: it registers a scheduled task that
launches AutoHotkey directly at logon, with no console window at all.

Do not put `4-Startup-Task.bat` itself in Startup or Task Scheduler - it would
re-register the task on every boot and flash a console at you.

Two alternatives if you would rather not use a scheduled task:

- **`Start-Hotkeys.bat`** - finds AutoHotkey, starts the script, exits
  immediately. Nothing to close. Drop it in `shell:startup`. A `.bat` always
  shows a brief console flash; the scheduled task does not.
- **`Install-Startup.bat`** - puts a shortcut to the `.ahk` in the Startup
  folder. No flash, but it cannot run elevated.

---

## Hotkeys

| Keys | Action |
|---|---|
| `Ctrl+Alt+1` | Profile 1 (Day) |
| `Ctrl+Alt+2` | Profile 2 (Night) |
| `Ctrl+Alt+3` | Profile 3 (Movie) |
| `Ctrl+Alt+P` | Switch external monitors to the **PC** |
| `Ctrl+Alt+L` | Switch external monitors to the **laptop** |
| `Ctrl+Alt+I` | Toggle each monitor between PC and laptop |
| `Ctrl+Alt+0` | Blank / unblank the external monitors |
| `Ctrl+Alt+O` | Rotate the right monitor (landscape <-> portrait) |
| `Ctrl+Alt+Shift+O` | Force the right monitor back to landscape |
| `Ctrl+Alt+Up` / `Down` | Nudge brightness on everything |
| `Ctrl+Alt+Shift+Up` / `Down` | Nudge **only the screen the active window is on** |
| `Ctrl+Alt+F` | Toggle dimming of the screens you are not using |
| `Ctrl+Alt+T` | **Tune** — sliders per monitor, live preview, save to a profile |
| `Ctrl+Alt+M` | Open the ControlMyMonitor GUI |
| `Ctrl+Alt+R` | Reload after editing `config.ini` |

Profile hotkeys are assigned in the order the `[Profile.*]` sections appear in
`config.ini`, up to 9. Add a `[Profile.Gaming]` section and it gets `Ctrl+Alt+4`
automatically after a reload — no script editing.

---

## Doing it without you (schedule, focus dim, idle dim)

Three things can move the screens on their own. All of them are **off by
default** - a tool that changes your brightness unasked is worse than one that
doesn't - and each is one tray click or one uncommented line away.

### The gamma problem, and why these compose

The profile's `[Soft.*]` dimming, focus dim and idle dim all want to darken the
same screen. If each wrote `SetDeviceGammaRamp` itself they would clobber one
another: walking away from an already-dim `CodeNight` would either double-dim,
or "restore" to full brightness on the way back and quietly undo the profile.

So nothing writes a ramp except `Dimmer.ahk`. The three inputs are kept apart
and **multiplied**:

```
output = profile level  x  focus multiplier  x  idle multiplier
```

A `CodeNight` screen at 45% that is not the one you're looking at (x0.60) and
has gone idle (x0.35) lands at 9.5% - and lifting any one of those three
restores exactly that one. There is a 5% floor so nothing can reach black.

### A profile at a time of day

```ini
AutoProfile=Day@07:30, CodeNight@20:30
AutoProfile=Day@sunrise, Night@sunset-30
Latitude=45.81
Longitude=15.98
```

`sunrise` / `sunset` are computed from your latitude and longitude with NOAA's
approximation - arithmetic, so no network, no API key, nothing to expire.
Longitude is positive **east**. Accuracy is about a minute: for Zagreb on 31
August it gives 06:15 and 19:38 against published 06:16 and 19:39. An optional
`+n` / `-n` offset shifts an entry, so `sunset-30` fires half an hour early.

An entry is in force from its own time until the next one, so whichever applies
**right now** is applied the moment the script starts - launching at 21:00 lands
on the evening profile instead of waiting until morning. Picking a profile by
hand parks the schedule on the current slot, so it will not immediately
overwrite your choice; the next boundary still fires normally. Toggle the whole
thing from the tray.

### Dimming the screens you're not using (`Ctrl+Alt+F`)

```ini
FocusDim=0.45
FocusDimDelay=600
```

The screens that don't hold the active window drop to `FocusDim` of their
normal output. `FocusDimDelay` is how long a window has to keep focus first -
without it, alt-tabbing across the desk would strobe. Because it's a gamma
ramp it's instant, and because it goes through the compositor it stacks with
whatever profile is loaded rather than fighting it.

Focus dim **suspends itself while the tuner is open** - dimming two thirds of
the desk is not helpful when the whole point is judging how a profile looks.

The hotkey turns it on at 0.45 without editing anything, so leaving `FocusDim=0`
does not put the feature out of reach.

### Dimming when you walk away

```ini
IdleDimAfter=300
IdleDimLevel=0.35
IdleDimFadeMs=1500
```

`IdleDimAfter` is in **seconds**. It watches `A_TimeIdlePhysical`, which ignores
synthetic input, so a script moving the mouse doesn't count as you being there.
Slow on the way down (1.5 s, so it isn't startling) and quick on the way back
(250 ms, so the screen is usable by the time you've finished moving the mouse).

---

## Fading instead of snapping

```ini
FadeMs=450
FadeDdcSteps=4
```

Profiles ease in. This is honest about a hardware limit, so it's worth knowing
exactly what happens:

| Part | How it fades |
|---|---|
| GPU gamma / soft dim | Genuinely smooth, ~40 fps - it's a `DllCall` |
| Panel brightness / contrast | `FadeDdcSteps` coarse steps underneath - each DDC/CI call costs 50-150 ms, so a real fade isn't possible |
| Internal laptop panel | Set once; WMI needs a PowerShell round trip |

Intermediate DDC steps are fired asynchronously so they can't stall the gamma
fade sharing the timer; the **final** step is synchronous and authoritative, so
the panel always lands exactly on the target even if a step was dropped. The
first time a profile is applied there's no known starting value, so brightness
snaps rather than fading from a guess - same after a manual nudge.

`FadeMs=0` restores the old instant switch.

---

## Nudging one screen (`Ctrl+Alt+Shift+Up`/`Down`)

`Ctrl+Alt+Up`/`Down` moves every monitor. Add **Shift** and it moves only the
screen the active window is sitting on - judged by the window's centre point,
so a window straddling a seam counts as being on the screen it mostly covers.
Falls back to the mouse pointer when nothing useful is focused.

---

## Volume and picture presets

Two more VCP codes your monitors already expose:

| | VCP | Stored in |
|---|---|---|
| Speaker volume | `62` | `[Volume.<profile>]` |
| Picture preset | `14` | `[Preset.<profile>]` |

Both are per-profile and opt-in per monitor, so a profile that doesn't mention
them leaves the monitor alone. Tick **Sound & colour** in the tuner to get the
rows.

Support is declared in config, not probed:

```ini
[Monitor.Left]
Volume=1
Presets=2:Display native,4:5000K,5:6500K,6:7500K,7:8200K,8:9300K,11:User 1,13:User 3
```

Probing is tempting but wrong here: a monitor with no speakers still answers
`/GetValue 62` with something that looks like a perfectly valid level, so
probing invents features that aren't there. `Detect-Monitors.ps1` reads the real
capability table and writes both lines for you; a bare number list like
`Presets=5,11` works too and picks up the standard MCCS names. **Only the values
a panel lists are accepted** - sending any other one is silently ignored.

---

## Tuning a profile by eye (`Ctrl+Alt+T`)

Picking the numbers for Day and Night by editing the INI means guessing a
value, saving, pressing a hotkey and looking at the result. The tuner runs
that loop the other way round: **drag a slider, watch the screen change, press
Save once it looks right.**

```
Profile: [ CodeNight v ]   [ Revert ]  [ Read screens ]

  [x] Left    Philips Evnia
        Brightness  ──●──────────────   0
        [ ] Contrast  ───────●───────   50
        [x] Soft dim on the GPU - goes below the panel's own 0
              Output  ──────●────────   45%
              Gamma   ────●──────────   1.15
              Warmth  ────●──────────   0.35
  ...
  [x] Live preview   [ ] Link brightness   [x] GPU soft dim
  [ Apply now ]  [ Save ]  [ Save as new... ]  [ Close ]
```

- **Pick a profile** from the dropdown and its stored values load into the
  sliders — and, with *Live preview* on, onto the monitors. Flipping between
  Day and Night in the dropdown is the fastest way to compare them.
- **Every monitor gets its own row.** Untick a monitor and this profile leaves
  it alone entirely (the key is removed from the section on save).
- **Contrast is opt-in per monitor**, matching the `brightness,contrast` form
  in the INI. Unticked means brightness only.
- **GPU soft dim** exposes `[Soft.<profile>]` — the attenuation that gets a
  panel below its own brightness 0. Off by default to keep the window short.
- **Link brightness** moves every included monitor by the same *step*, not to
  the same value. Panels disagree wildly about what a number means — Left 20
  and Right 45 look the same here — so matching them outright would throw away
  the balance you just found.
- **Read screens** pulls the external monitors' current values back into the
  sliders, so a level you dialled in on the monitor's own OSD can be captured.
- **Save** writes straight back into `[Profile.<name>]` and `[Soft.<name>]` of
  the same `config.ini` everything else reads. A tuned profile is an ordinary
  profile: hotkey, tray menu and `Set-Profile.ps1` at logon all pick it up.
  **Save as new...** creates a section that did not exist and, if it lands in
  the first nine, hands it a `Ctrl+Alt+n` on the spot.

Comments in `config.ini` survive a save — only the value lines change — and the
previous version is kept as `config.ini.bak`. If you have the file open in an
editor, reload it after saving.

Brightness and contrast are debounced ~180 ms, because each DDC/CI call costs
50–150 ms and a slider drag would otherwise queue hundreds of them. The gamma
sliders are a direct `DllCall` and track the drag with no lag at all.

---

## Command line

Every hotkey is just a script, so anything can call them — Stream Deck, a
taskbar shortcut, Task Scheduler, another script.

```powershell
.\Set-Profile.ps1 -Name Night              # apply a profile
.\Set-Profile.ps1 -Name Day -Only Left     # one monitor only
.\Set-Profile.ps1 -List                    # profiles + live values

.\Set-Input.ps1                            # show current inputs
.\Set-Input.ps1 -Target Laptop             # hand the monitors to the laptop
.\Set-Input.ps1 -Target PC
.\Set-Input.ps1 -Toggle
.\Set-Input.ps1 -Target Laptop -WhatIfOnly # dry run

.\Set-Power.ps1 -State Off                 # blank the externals
.\Set-Power.ps1 -State On

.\Adjust-Brightness.ps1 -Delta -10         # nudge everything down
.\Adjust-Brightness.ps1 -Set 50            # absolute, all monitors

.\Set-Orientation.ps1                      # right monitor -> landscape
.\Set-Orientation.ps1 -Orientation Portrait
.\Set-Orientation.ps1 -Orientation Toggle
.\Set-Orientation.ps1 -Only Left           # a different monitor
.\Set-Orientation.ps1 -List                # which display is which

.\Set-SoftDim.ps1 -Level 0.45 -Gamma 1.15 -Warmth 0.35
.\Set-SoftDim.ps1 -Reset                   # back to normal
.\Set-SoftDim.ps1 -Status                  # current ramps + clamp state
.\Set-SoftDim.ps1 -EnableDeepDim           # admin: allow very dark ramps
```

---

## How the three displays are driven

| Display | Mechanism | Why |
|---|---|---|
| 2 external monitors | ControlMyMonitor / DDC-CI over the video cable | The monitor's own hardware controls, same as its OSD menu |
| Built-in laptop panel | WMI (`WmiMonitorBrightnessMethods`) | Internal panels almost never answer DDC/CI, so ControlMyMonitor can't touch them |
| Screen rotation (any display) | Windows display API (`ChangeDisplaySettingsEx`) | Rotation is a Windows setting, not a monitor setting — DDC/CI has no concept of it |
| Dimming below brightness 0 | GPU gamma ramp (`SetDeviceGammaRamp`) | The panel's own floor is a hardware limit; attenuating the signal is the only way under it |

This is why the laptop screen is `Type=Internal` in the config and has no
input to switch. The hotkey script handles the externals itself and shells out
to PowerShell only for the laptop panel, so external changes are instant.

One quirk of DDC/CI worth knowing: **codes are hex, values are decimal.**
Brightness is code `10` (hex 0x10), input select is code `60`, power is `D6`.
But `DisplayPort-1` is value `15`, not `0F`. The config uses decimal
throughout, and `Detect-Monitors.ps1` translates for you.

---

## Going darker than the monitor allows

Some panels have a high backlight floor — the Philips Evnia is a known case,
measuring around 100 nits even at brightness 0. DDC/CI cannot help: 0 is 0.

The way under it is to attenuate on the GPU, by reshaping the display's gamma
ramp. That is the same lever the NVIDIA Control Panel's brightness and gamma
sliders pull, but `SetDeviceGammaRamp` is a plain Windows API — so this works on
any GPU, needs no vendor software, and is scriptable per monitor.

Add a `[Soft.<profile>]` section and it applies with the profile:

```ini
[Profile.CodeNight]
Left=0
Right=0

[Soft.CodeNight]
Left=0.45,1.15,0.35     ; brightness, gamma, warmth
Right=0.60,1.10,0.30
```

- **brightness** `0.05`–`1.0` — output level. `0.45` is a good dark-room start.
- **gamma** — above `1.0` lifts midtones, so text stays legible while whites dim.
  This is what keeps code readable instead of muddy.
- **warmth** `0`–`1` — pulls blue down. Like Night Light, but it does not fight
  with the brightness setting.

A profile with **no** `[Soft.*]` section clears the ramps, so `Ctrl+Alt+1` for
Day undoes the dimming automatically.

**Windows clamps gamma ramps by default.** It refuses ramps it considers
extreme, so an app cannot black out your screen — and `SetDeviceGammaRamp`
reports success while quietly doing nothing. The scripts read the ramp back and
tell you when that happens. To lift the limit:

```powershell
.\Set-SoftDim.ps1 -EnableDeepDim     # admin window; sign out and back in
```

That sets `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM\GdiIcmGammaRange`
to 256 (unrestricted). Try the normal route first — moderate levels usually
apply without it.

Three things to know about gamma ramps:

- **HDR overrides them.** Turn HDR off for desktop work, or the ramp is ignored.
- **They reset on display events** — resolution changes, monitor hotplug, some
  fullscreen games, waking from sleep. Re-press the profile hotkey.
- **Dimming costs tonal steps.** At 45% you lose roughly 1.2 bits, so gradients
  may band slightly. For text and code it is not noticeable.

---

## Things that will bite you

**HDR silently kills every gamma trick.** Windows ignores `SetDeviceGammaRamp`
on a display in HDR mode — no error, the call reports success and nothing
happens. That takes out soft dim, focus dim and idle dim in one go, so if the
sliders stop doing anything on the Evnia, check HDR first. Panel brightness and
contrast still work, because those are DDC/CI and have nothing to do with the
GPU. Some fullscreen games and driver events also reset ramps; `Ctrl+Alt+R`
reapplies.

**Switching to the laptop blinds the PC.** Once `Ctrl+Alt+L` runs, the monitors
show the laptop and your PC is still running with no picture. The hotkey script
is still listening, so `Ctrl+Alt+P` on the PC's keyboard brings them back —
but you have to press it on the *PC's* keyboard, which you can't see. Two
practical answers:

- Copy this whole folder to the laptop too, and run detection there. Then each
  machine can grab the monitors with its own `Ctrl+Alt+P` / `Ctrl+Alt+L`.
- Or use a real KVM / the monitor's built-in USB switch so keyboard and mouse
  follow the input.

**Monitors that accept "off" but ignore "on".** VCP `D6` power-off works nearly
everywhere; power-on often doesn't, because the monitor's DDC controller went
to sleep along with the panel. If `Ctrl+Alt+0` blanks but won't wake, just move
the mouse (Windows re-asserts the signal) or use the power button. This is a
monitor firmware limitation, not a script bug.

**DDC/CI can be turned off in the monitor's own menu.** If detection reports
"no response" for a display you know is external, look for DDC/CI in its OSD
settings and enable it.

**Docks, KVMs, MST daisy-chains and DisplayLink adapters can block DDC/CI.**
DisplayLink in particular has no DDC path at all. If one monitor works and the
other doesn't, the difference is usually the cable path, not the monitor.

**Input values are vendor-flavoured.** The standard runs out at HDMI-2 (18).
USB-C / DP-Alt-mode inputs use vendor codes — commonly `27` on Dell and `208`
on LG. Detection lists whatever your monitor actually reports, so use those
numbers even if they look odd.

**One folder, two machines.** A laptop and a desktop driving the same monitors
cannot share one config: they plug into different ports (so the `InputPC` and
`InputLaptop` values differ), ControlMyMonitor may live somewhere else, and only
the laptop has an internal panel to drive over WMI.

So the config is per machine. Every script, and the hotkey script, look for
`config.<COMPUTERNAME>.ini` first and fall back to `config.ini`. Copy the folder
to the second machine, run `1-Detect.bat` there, and detection notices the
existing `config.ini` came from a different machine and writes
`config.<COMPUTERNAME>.ini` alongside it instead of overwriting it. Both machines
then read their own file out of the same folder - which also means the folder
can live in OneDrive or a git repo without the two fighting.

The AutoHotkey tray tooltip shows which config file is in use.

**Display numbers change at every boot — the config does not depend on them.**
Windows assigns `\\.\DISPLAYn` at startup, and it moves around: yours went from
`DISPLAY5`/`DISPLAY6` to `DISPLAY9`/`DISPLAY10` after one reboot. So monitors are
identified by `MonitorKey` — the EDID hardware id burned into the panel
(`PHLC323` for the Philips, `DELD0F3` for the Dell). Every run looks up which
`\\.\DISPLAYn` that panel is on right now, and ControlMyMonitor is handed the
hardware id rather than a display number. Nothing needs re-running after a
reboot, a cable swap, or a GPU driver update.

`Left` and `Right` are bound to specific panels, not to positions or
enumeration order. To see the mapping:

```powershell
.\Set-Orientation.ps1 -List
```

That prints each attached display's hardware id and which config entry owns it.
To move a name to a different panel, change its `MonitorKey=`. Detection now
also names monitors by actual desktop position, so the leftmost screen becomes
`Left` from the start.

If a configured monitor isn't plugged in, scripts say so and stop, rather than
acting on whichever display inherited that number.

**Rotating reshuffles your windows.** Windows moves and resizes anything on the
rotated screen, and the desktop arrangement (which edge sits next to which) may
need fixing in Display Settings the first time. It doesn't rearrange your other
monitors, but it can shift where they sit relative to the rotated one.

**If a hotkey seems to do nothing, run `3-Debug.bat`.** The hotkeys run
PowerShell in a hidden window, so a script that fails and exits looks identical
to one that did nothing at all. `3-Debug.bat` runs the same things in a visible
console that stays open. `Ctrl+Alt+O` also re-opens itself in a visible window
when rotation fails, rather than reporting a success it didn't achieve.

**Note on quoting in `config.ini`.** ControlMyMonitor's own exports wrap values
in double quotes. Both readers strip a matching pair of surrounding quotes, so
`Id="\\.\DISPLAY6\Monitor0"` and `Id=\\.\DISPLAY6\Monitor0` behave the same.
Detection now writes them unquoted.

**Task Scheduler cannot launch a `.ahk` file.** Its "Program/script" box runs
`CreateProcess`, which starts executables only - it does not follow the file
associations that make a double-click work. Point it at a `.ahk` and the task
sits at **Ready** with Last Run Result `0x2` and nothing happens. The program
has to be AutoHotkey itself, with the script as an argument:

```
Program/script : C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe
Arguments      : "C:\Users\romic\MonitorControls\MonitorControls.ahk"
Start in       : C:\Users\romic\MonitorControls
```

Two more traps in the same dialog: use the **At log on** trigger, never **At
startup** - a startup task runs in session 0 before anyone logs in, where there
is no desktop and global hotkeys cannot exist. And clear the execution time
limit on the Settings tab, or Task Scheduler kills the script after three days.
`4-Startup-Task.bat` sets all of this up for you - run it once, then leave it
alone. If you want a startup item you can see and manage yourself, use
`Start-Hotkeys.bat` instead; it launches the script and closes immediately
rather than waiting for a keypress.

**Don't confuse this with Windows Night Light or HDR.** These scripts change the
panel's actual backlight. If HDR is on, Windows' own brightness slider does
something different (SDR content brightness) and may appear to fight with this.

---

## Optional extras

**Automatic day/night.** Two scheduled tasks, no extra software. Run these once
in a normal (non-admin) terminal, adjusting the times:

```powershell
$ps = "powershell.exe"
$dir = "C:\Users\romic\MonitorControls"
schtasks /Create /TN "Monitors-Day"   /SC DAILY /ST 08:00 /F /TR "$ps -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Set-Profile.ps1`" -Name Day"
schtasks /Create /TN "Monitors-Night" /SC DAILY /ST 20:30 /F /TR "$ps -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Set-Profile.ps1`" -Name Night"
```

Delete with `schtasks /Delete /TN "Monitors-Day" /F`.

**Apply a profile on wake / on login.** DDC/CI settings live in the monitor, so
they survive reboots — but monitors sometimes reset themselves after a power
blip. Adding a `Monitors-Day` style task with `/SC ONLOGON` covers that.

**More profiles.** Add sections like this; they pick up the next free
`Ctrl+Alt+<n>`:

```ini
[Profile.Gaming]
Left=90,85
Right=90,85
Laptop=80

[Profile.Screenshare]
Left=60
Right=60
```

**Per-monitor hotkeys.** `Set-Profile.ps1 -Only Left` and
`Set-Input.ps1 -Only Right` let you build "only change the left screen"
bindings if you want them.

**Volume.** If your monitors have speakers, VCP `62` is audio volume. The
plumbing is already there — `Set-MonitorVcp -Code 62` in `lib\Common.ps1`.

---

## Files

| File | Purpose |
|---|---|
| `config.ini` | The file you edit. Generated by detection. |
| `config.<PC-NAME>.ini` | Per-machine override, used when the folder is shared. |
| `config.example.ini` | Reference copy showing the expected shape. |
| `Detect-Monitors.ps1` | One-time hardware discovery + config generation. |
| `Set-Profile.ps1` | Apply a brightness/contrast profile. |
| `Set-Input.ps1` | Switch input sources. |
| `Set-Power.ps1` | Blank / wake external monitors. |
| `Adjust-Brightness.ps1` | Relative or absolute brightness nudge. |
| `Set-Orientation.ps1` | Rotate a monitor; `-List` identifies which is which. |
| `Set-SoftDim.ps1` | GPU-level dimming below the panel's own minimum. |
| `lib\Common.ps1` | Shared helpers (INI parsing, DDC calls, WMI brightness). |
| `lib\Display.ps1` | Windows display API bindings: rotation + stable id lookup. |
| `lib\Gamma.ps1` | Gamma-ramp maths for the soft dimming. |
| `lib\Util.ahk` | Small pure helpers shared by every `.ahk` file - the part the tests exercise directly. |
| `lib\Gdi.ahk` | Display enumeration, monitor geometry and the gamma-ramp DllCalls. |
| `Dimmer.ahk` | The only thing that writes a gamma ramp: composes profile x focus x idle, and cross-fades. |
| `Auto.ahk` | Time-of-day schedule (incl. sunrise/sunset), focus watcher, idle watcher. |
| `MonitorControls.ahk` | Hotkeys and tray menu. |
| `Tuner.ahk` | The `Ctrl+Alt+T` window: per-monitor sliders, live preview, save back to `config.ini`. |
| `1-Detect.bat`, `2-Test.bat`, `Install-Startup.bat` | Double-click entry points. |
| `3-Debug.bat` | Diagnostics: shows the errors hidden hotkey windows swallow. |
| `4-Startup-Task.bat`, `Setup-Startup.ps1` | ONE-TIME setup: registers the logon scheduled task. |
| `Start-Hotkeys.bat` | Silent launcher for the hotkeys; exits on its own. |
| `detected\` | Raw ControlMyMonitor reports, for reference. |

No admin rights are needed for any of it. The `.bat` files pass
`-ExecutionPolicy Bypass`, so there's nothing to change in your PowerShell
settings.
