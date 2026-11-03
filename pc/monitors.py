"""Find the laptop's monitors, numbered the way Windows Graphics Capture numbers them."""
import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32
try:
    # report real pixel sizes instead of sizes scaled by the Windows zoom level
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except OSError:
    pass

MONITORINFOF_PRIMARY = 1


class MONITORINFOEXW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD),
                ("szDevice", wintypes.WCHAR * 32)]


MonitorEnumProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC,
                                     ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)


def list_monitors():
    """Monitors as dicts: index (1-based, for WindowsCapture), width, height, primary."""
    monitors = []

    def callback(hmonitor, _hdc, _rect, _lparam):
        info = MONITORINFOEXW()
        info.cbSize = ctypes.sizeof(info)
        user32.GetMonitorInfoW(hmonitor, ctypes.byref(info))
        r = info.rcMonitor
        monitors.append({"index": len(monitors) + 1, "name": info.szDevice,
                         "left": r.left, "top": r.top,
                         "width": r.right - r.left, "height": r.bottom - r.top,
                         "primary": bool(info.dwFlags & MONITORINFOF_PRIMARY)})
        return True

    user32.EnumDisplayMonitors(None, None, MonitorEnumProc(callback), 0)
    return monitors


def primary_monitor():
    monitors = list_monitors()
    return next((m for m in monitors if m["primary"]), monitors[0])


class DEVMODEW(ctypes.Structure):
    # the display variant of DEVMODEW (the printer fields share this memory)
    _fields_ = [("dmDeviceName", wintypes.WCHAR * 32), ("dmSpecVersion", wintypes.WORD),
                ("dmDriverVersion", wintypes.WORD), ("dmSize", wintypes.WORD),
                ("dmDriverExtra", wintypes.WORD), ("dmFields", wintypes.DWORD),
                ("dmPositionX", wintypes.LONG), ("dmPositionY", wintypes.LONG),
                ("dmDisplayOrientation", wintypes.DWORD), ("dmDisplayFixedOutput", wintypes.DWORD),
                ("dmColor", ctypes.c_short), ("dmDuplex", ctypes.c_short),
                ("dmYResolution", ctypes.c_short), ("dmTTOption", ctypes.c_short),
                ("dmCollate", ctypes.c_short), ("dmFormName", wintypes.WCHAR * 32),
                ("dmLogPixels", wintypes.WORD), ("dmBitsPerPel", wintypes.DWORD),
                ("dmPelsWidth", wintypes.DWORD), ("dmPelsHeight", wintypes.DWORD),
                ("dmDisplayFlags", wintypes.DWORD), ("dmDisplayFrequency", wintypes.DWORD),
                ("dmICMMethod", wintypes.DWORD), ("dmICMIntent", wintypes.DWORD),
                ("dmMediaType", wintypes.DWORD), ("dmDitherType", wintypes.DWORD),
                ("dmReserved1", wintypes.DWORD), ("dmReserved2", wintypes.DWORD),
                ("dmPanningWidth", wintypes.DWORD), ("dmPanningHeight", wintypes.DWORD)]


DM_POSITION, DM_PELSWIDTH, DM_PELSHEIGHT = 0x20, 0x80000, 0x100000
CDS_UPDATEREGISTRY = 0x1
DISP_CHANGE_SUCCESSFUL = 0


def available_modes(name):
    """Set of (width, height) the display `name` (e.g. '\\\\.\\DISPLAY3') supports."""
    modes, i = set(), 0
    dm = DEVMODEW()
    dm.dmSize = ctypes.sizeof(dm)
    while user32.EnumDisplaySettingsW(name, i, ctypes.byref(dm)):
        modes.add((dm.dmPelsWidth, dm.dmPelsHeight))
        i += 1
    return modes


def configure(name, width, height, x, y):
    """Set a display's resolution and its position on the desktop. True if it worked."""
    dm = DEVMODEW()
    dm.dmSize = ctypes.sizeof(dm)
    dm.dmPelsWidth, dm.dmPelsHeight = width, height
    dm.dmPositionX, dm.dmPositionY = x, y
    dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_POSITION
    return user32.ChangeDisplaySettingsExW(name, ctypes.byref(dm), None,
                                           CDS_UPDATEREGISTRY, None) == DISP_CHANGE_SUCCESSFUL


if __name__ == "__main__":
    for m in list_monitors():
        print(m)
