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
                         "width": r.right - r.left, "height": r.bottom - r.top,
                         "primary": bool(info.dwFlags & MONITORINFOF_PRIMARY)})
        return True

    user32.EnumDisplayMonitors(None, None, MonitorEnumProc(callback), 0)
    return monitors


def monitor_for_mode(mode):
    """Mirror = the main screen; extend = the first other (virtual) screen, or None."""
    monitors = list_monitors()
    if mode == "mirror":
        return next((m for m in monitors if m["primary"]), monitors[0])
    return next((m for m in monitors if not m["primary"]), None)


if __name__ == "__main__":
    for m in list_monitors():
        print(m)
