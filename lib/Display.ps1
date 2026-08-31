# ============================================================================
#  Display.ps1 - screen rotation via the Windows display API
#
#  Rotation is NOT a DDC/CI feature, so ControlMyMonitor cannot do it. It is a
#  Windows setting, changed with ChangeDisplaySettingsEx. This file P/Invokes
#  that directly - no extra tools to install, no admin rights needed.
#
#  Dot-sourced by Set-Orientation.ps1.
# ============================================================================

if (-not ('MonitorControls.Display' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace MonitorControls
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short  dmSpecVersion;
        public short  dmDriverVersion;
        public short  dmSize;
        public short  dmDriverExtra;
        public int    dmFields;
        public int    dmPositionX;
        public int    dmPositionY;
        public int    dmDisplayOrientation;
        public int    dmDisplayFixedOutput;
        public short  dmColor;
        public short  dmDuplex;
        public short  dmYResolution;
        public short  dmTTOption;
        public short  dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short  dmLogPixels;
        public int    dmBitsPerPel;
        public int    dmPelsWidth;
        public int    dmPelsHeight;
        public int    dmDisplayFlags;
        public int    dmDisplayFrequency;
        public int    dmICMMethod;
        public int    dmICMIntent;
        public int    dmMediaType;
        public int    dmDitherType;
        public int    dmReserved1;
        public int    dmReserved2;
        public int    dmPanningWidth;
        public int    dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public class DisplayInfo
    {
        public string DeviceName;
        public string Description;
        public string MonitorName;
        public string MonitorDeviceId;
        public string MonitorKey;
        public bool   IsPrimary;
        public int    Width;
        public int    Height;
        public int    Orientation;
        public int    PositionX;
        public int    PositionY;
    }

    public static class Display
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum,
            ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum,
            ref DEVMODE lpDevMode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode,
            IntPtr hwnd, int dwflags, IntPtr lParam);

        private const int ENUM_CURRENT_SETTINGS      = -1;
        private const int DM_POSITION                = 0x00000020;
        private const int DM_DISPLAYORIENTATION      = 0x00000080;
        private const int DM_PELSWIDTH               = 0x00080000;
        private const int DM_PELSHEIGHT              = 0x00100000;
        private const int CDS_UPDATEREGISTRY         = 0x00000001;
        private const int DISPLAY_DEVICE_ATTACHED    = 0x00000001;
        private const int DISPLAY_DEVICE_PRIMARY     = 0x00000004;

        private static DEVMODE NewDevMode()
        {
            DEVMODE dm = new DEVMODE();
            dm.dmDeviceName = new string('\0', 32);
            dm.dmFormName   = new string('\0', 32);
            dm.dmSize       = (short)Marshal.SizeOf(typeof(DEVMODE));
            return dm;
        }

        public static List<DisplayInfo> List()
        {
            List<DisplayInfo> result = new List<DisplayInfo>();
            DISPLAY_DEVICE dev = new DISPLAY_DEVICE();
            dev.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

            for (uint i = 0; EnumDisplayDevices(null, i, ref dev, 0); i++)
            {
                if ((dev.StateFlags & DISPLAY_DEVICE_ATTACHED) == 0)
                {
                    dev.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                    continue;
                }

                DEVMODE dm = NewDevMode();
                DisplayInfo info = new DisplayInfo();
                info.DeviceName  = dev.DeviceName;
                info.Description = dev.DeviceString;
                info.IsPrimary   = (dev.StateFlags & DISPLAY_DEVICE_PRIMARY) != 0;

                // The adapter's child device carries the EDID identity, e.g.
                // MONITOR\PHLC323\{4d36e96e-...}\0001 . That "PHLC323" is the
                // same string ControlMyMonitor calls the Short Monitor ID, and
                // unlike \\.\DISPLAYn it survives reboots and re-cabling.
                DISPLAY_DEVICE mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (EnumDisplayDevices(dev.DeviceName, 0, ref mon, 0))
                {
                    info.MonitorName     = mon.DeviceString;
                    info.MonitorDeviceId = mon.DeviceID;
                    string[] bits = mon.DeviceID.Split('\\');
                    if (bits.Length > 1) info.MonitorKey = bits[1];
                }

                if (EnumDisplaySettings(dev.DeviceName, ENUM_CURRENT_SETTINGS, ref dm))
                {
                    info.Width       = dm.dmPelsWidth;
                    info.Height      = dm.dmPelsHeight;
                    info.Orientation = dm.dmDisplayOrientation;
                    info.PositionX   = dm.dmPositionX;
                    info.PositionY   = dm.dmPositionY;
                }
                result.Add(info);

                dev = new DISPLAY_DEVICE();
                dev.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            }
            return result;
        }

        public static int GetOrientation(string deviceName)
        {
            DEVMODE dm = NewDevMode();
            if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm))
                return -1;
            return dm.dmDisplayOrientation;
        }

        // Returns 0 on success, otherwise the DISP_CHANGE_* code from Windows.
        // -100 means the device could not be read at all.
        public static int SetOrientation(string deviceName, int orientation)
        {
            DEVMODE dm = NewDevMode();
            if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm))
                return -100;

            if (dm.dmDisplayOrientation == orientation)
                return 0;

            // Windows requires width and height to be swapped when crossing
            // between landscape (0, 2) and portrait (1, 3); otherwise the call
            // is rejected with DISP_CHANGE_BADMODE.
            bool wasPortrait = (dm.dmDisplayOrientation % 2) != 0;
            bool willPortrait = (orientation % 2) != 0;
            if (wasPortrait != willPortrait)
            {
                int w = dm.dmPelsWidth;
                dm.dmPelsWidth  = dm.dmPelsHeight;
                dm.dmPelsHeight = w;
            }

            dm.dmDisplayOrientation = orientation;
            dm.dmFields = DM_DISPLAYORIENTATION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_POSITION;

            return ChangeDisplaySettingsEx(deviceName, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        }
    }

    // ---------------------------------------------------------------------
    //  Gamma ramps - GPU-level attenuation, below the monitor's own minimum.
    //
    //  This is the same lever the NVIDIA Control Panel's brightness/contrast/
    //  gamma sliders pull, but it is a plain Windows API, so it works on any
    //  GPU and needs no vendor software.
    // ---------------------------------------------------------------------
    public static class Gamma
    {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateDC(string driver, string device, string port, IntPtr pdm);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteDC(IntPtr hdc);

        [DllImport("gdi32.dll")]
        private static extern bool SetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);

        [DllImport("gdi32.dll")]
        private static extern bool GetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);

        // ramp is 768 WORDs: 256 red, then 256 green, then 256 blue.
        public static bool Apply(string deviceName, ushort[] ramp)
        {
            IntPtr hdc = CreateDC("DISPLAY", deviceName, null, IntPtr.Zero);
            if (hdc == IntPtr.Zero) return false;
            try { return SetDeviceGammaRamp(hdc, ramp); }
            finally { DeleteDC(hdc); }
        }

        public static ushort[] Read(string deviceName)
        {
            IntPtr hdc = CreateDC("DISPLAY", deviceName, null, IntPtr.Zero);
            if (hdc == IntPtr.Zero) return null;
            try
            {
                ushort[] ramp = new ushort[768];
                if (!GetDeviceGammaRamp(hdc, ramp)) return null;
                return ramp;
            }
            finally { DeleteDC(hdc); }
        }
    }
}
'@
}

# DMDO_* values used by the Windows display API
$script:Orientations = @{
    'Landscape'        = 0
    'Portrait'         = 1
    'LandscapeFlipped' = 2
    'PortraitFlipped'  = 3
}

function Get-OrientationName {
    param([int]$Value)
    switch ($Value) {
        0 { 'Landscape' }
        1 { 'Portrait' }
        2 { 'Landscape (flipped)' }
        3 { 'Portrait (flipped)' }
        default { "unknown ($Value)" }
    }
}

function Get-DispChangeMessage {
    param([int]$Code)
    switch ($Code) {
        0     { 'OK' }
        1     { 'The change needs a restart to take effect.' }
        -1    { 'Windows rejected the change (DISP_CHANGE_FAILED).' }
        -2    { 'That resolution/orientation combination is not valid for this display (DISP_CHANGE_BADMODE).' }
        -3    { 'The settings could not be written to the registry (DISP_CHANGE_NOTUPDATED).' }
        -4    { 'Invalid flags passed to the display API.' }
        -5    { 'Invalid parameter passed to the display API.' }
        -6    { 'This display driver does not support the requested mode.' }
        -100  { 'Could not read the current settings for that display device.' }
        default { "Display API returned $Code" }
    }
}

function Get-DisplayList {
    return [MonitorControls.Display]::List()
}

# Turns a ControlMyMonitor monitor id such as "\\.\DISPLAY2\Monitor0" into the
# Windows display adapter name "\\.\DISPLAY2" that the rotation API wants.
function ConvertTo-DisplayDeviceName {
    param([string]$MonitorId)
    if (-not $MonitorId) { return $null }
    # Deliberately unanchored and quote-tolerant: ControlMyMonitor exports ids
    # wrapped in double quotes, and people paste them with stray whitespace.
    if ($MonitorId -match '(\\\\\.\\DISPLAY\d+)') { return $Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
#  Stable identity
#
#  \\.\DISPLAYn is assigned by Windows at boot and moves around - after a
#  reboot the same physical monitor can go from DISPLAY5 to DISPLAY9. So
#  nothing is keyed on it. Monitors are identified by their EDID hardware id
#  (PHLC323, DELD0F3, ...), which is burned into the panel, and the volatile
#  \\.\DISPLAYn is looked up fresh on every run.
# ---------------------------------------------------------------------------

function Resolve-DisplayDevice {
    <#
      Returns the current \\.\DISPLAYn for a monitor, given its stable key.
      Falls back to a literal device name so old configs keep working.
    #>
    param(
        [string]$Key,          # EDID hardware id, e.g. PHLC323
        [string]$FallbackId    # legacy Id= value, e.g. \\.\DISPLAY5\Monitor0
    )

    if ($Key) {
        $hit = Get-DisplayList | Where-Object { $_.MonitorKey -and $_.MonitorKey -eq $Key }
        if (@($hit).Count -gt 1) {
            # Two identical panels. Left-to-right desktop order is the only
            # tie-break available, so take the leftmost deterministically.
            $hit = @($hit | Sort-Object PositionX)[0]
        }
        if ($hit) { return (@($hit)[0]).DeviceName }
    }

    if ($FallbackId) {
        $dev = ConvertTo-DisplayDeviceName $FallbackId
        if ($dev) {
            $known = Get-DisplayList | Where-Object { $_.DeviceName -eq $dev }
            if ($known) { return $dev }
        }
    }
    return $null
}

function Get-DisplayByKey {
    param([string]$Key)
    if (-not $Key) { return $null }
    return (Get-DisplayList | Where-Object { $_.MonitorKey -eq $Key } | Select-Object -First 1)
}
