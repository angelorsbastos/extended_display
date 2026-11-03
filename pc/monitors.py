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


class LUID(ctypes.Structure):
    _fields_ = [("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG)]


class DISPLAYCONFIG_PATH_INFO(ctypes.Structure):
    # only the source part is read; the rest is padding up to the real 72-byte size
    _fields_ = [("sourceAdapterId", LUID), ("sourceId", ctypes.c_uint32),
                ("sourceModeInfoIdx", ctypes.c_uint32), ("sourceStatusFlags", ctypes.c_uint32),
                ("rest", ctypes.c_ubyte * 52)]


class DISPLAYCONFIG_DEVICE_INFO_HEADER(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int32), ("size", ctypes.c_uint32),
                ("adapterId", LUID), ("id", ctypes.c_uint32)]


class DISPLAYCONFIG_SOURCE_DEVICE_NAME(ctypes.Structure):
    _fields_ = [("header", DISPLAYCONFIG_DEVICE_INFO_HEADER),
                ("viewGdiDeviceName", wintypes.WCHAR * 32)]


class DPI_SCALE_GET(ctypes.Structure):
    _fields_ = [("header", DISPLAYCONFIG_DEVICE_INFO_HEADER), ("minScaleRel", ctypes.c_int32),
                ("curScaleRel", ctypes.c_int32), ("maxScaleRel", ctypes.c_int32)]


class DPI_SCALE_SET(ctypes.Structure):
    _fields_ = [("header", DISPLAYCONFIG_DEVICE_INFO_HEADER), ("scaleRel", ctypes.c_int32)]


QDC_ONLY_ACTIVE_PATHS = 0x2
GET_SOURCE_NAME = 1
# Undocumented, but what the Settings app itself uses for the "Scale" dropdown.
# Scale is set relative to the display's recommended step in this list.
GET_DPI_SCALE, SET_DPI_SCALE = -3, -4
SCALE_STEPS = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]


def _source(name):
    """The (adapter id, source id) pair Windows' display-config API uses for `name`."""
    n_paths, n_modes = ctypes.c_uint32(), ctypes.c_uint32()
    user32.GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, ctypes.byref(n_paths),
                                       ctypes.byref(n_modes))
    paths = (DISPLAYCONFIG_PATH_INFO * n_paths.value)()
    modes = (ctypes.c_ubyte * (64 * n_modes.value))()  # DISPLAYCONFIG_MODE_INFO is 64 bytes
    user32.QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ctypes.byref(n_paths), paths,
                              ctypes.byref(n_modes), modes, None)
    for path in paths[:n_paths.value]:
        info = DISPLAYCONFIG_SOURCE_DEVICE_NAME()
        info.header.type, info.header.size = GET_SOURCE_NAME, ctypes.sizeof(info)
        info.header.adapterId, info.header.id = path.sourceAdapterId, path.sourceId
        if user32.DisplayConfigGetDeviceInfo(ctypes.byref(info)) == 0 \
                and info.viewGdiDeviceName == name:
            return path.sourceAdapterId, path.sourceId
    return None


def _scale_info(adapter, source):
    info = DPI_SCALE_GET()
    info.header.type, info.header.size = GET_DPI_SCALE, ctypes.sizeof(info)
    info.header.adapterId, info.header.id = adapter, source
    if user32.DisplayConfigGetDeviceInfo(ctypes.byref(info)) != 0:
        return None
    recommended = -info.minScaleRel  # index of the recommended step in SCALE_STEPS
    return recommended, info


def get_scale(name):
    """Current Windows scale of a display in percent, e.g. 200, or None."""
    source = _source(name)
    found = source and _scale_info(*source)
    if not found:
        return None
    recommended, info = found
    return SCALE_STEPS[recommended + info.curScaleRel]


def set_scale(name, percent):
    """Set a display's Windows scale (Settings > Display > Scale). True if it worked."""
    source = _source(name)
    found = source and _scale_info(*source)
    if not found:
        return False
    recommended, info = found
    rel = SCALE_STEPS.index(percent) - recommended
    rel = max(info.minScaleRel, min(info.maxScaleRel, rel))
    request = DPI_SCALE_SET()
    request.header.type, request.header.size = SET_DPI_SCALE, ctypes.sizeof(request)
    request.header.adapterId, request.header.id = source
    request.scaleRel = rel
    return user32.DisplayConfigSetDeviceInfo(ctypes.byref(request)) == 0


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
