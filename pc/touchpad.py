"""Read fingers straight from the laptop's precision touchpad (Windows Raw
Input, HID digitizer reports) and recognise three- and four-finger swipes and
taps, which Windows otherwise keeps for itself.

Each report lists contacts in "finger" link collections (X, Y, contact id, tip
switch); the contact count says how many of them are filled in. Touchpads in
"hybrid" mode send one finger per report: then only the first report of a
frame has the count, and the others count 0 but carry one finger.
"""
import ctypes
import threading
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
hid = ctypes.WinDLL("hid")

WM_INPUT = 0x00FF
RID_INPUT, RIDI_PREPARSEDDATA = 0x10000003, 0x20000005
RIDEV_INPUTSINK = 0x100
RIM_TYPEHID = 2
HWND_MESSAGE = ctypes.c_void_p(-3)
HIDP_INPUT, HIDP_STATUS_SUCCESS = 0, 0x00110000
PAGE_GENERIC, PAGE_BUTTON, PAGE_DIGITIZER = 0x01, 0x09, 0x0D
USAGE_X, USAGE_Y = 0x30, 0x31
USAGE_TIP, USAGE_CONTACT_ID, USAGE_CONTACT_COUNT = 0x42, 0x51, 0x54

SWIPE_DISTANCE = 0.18  # of the touchpad's size, for a swipe to count
TAP_SECONDS = 0.35


class RAWINPUTDEVICE(ctypes.Structure):
    _fields_ = [("usUsagePage", wintypes.USHORT), ("usUsage", wintypes.USHORT),
                ("dwFlags", wintypes.DWORD), ("hwndTarget", wintypes.HWND)]


class RAWINPUTHEADER(ctypes.Structure):
    _fields_ = [("dwType", wintypes.DWORD), ("dwSize", wintypes.DWORD),
                ("hDevice", wintypes.HANDLE), ("wParam", wintypes.WPARAM)]


class HIDP_CAPS(ctypes.Structure):
    _fields_ = [("Usage", wintypes.USHORT), ("UsagePage", wintypes.USHORT),
                ("InputReportByteLength", wintypes.USHORT), ("OutputReportByteLength", wintypes.USHORT),
                ("FeatureReportByteLength", wintypes.USHORT), ("Reserved", wintypes.USHORT * 17),
                ("NumberLinkCollectionNodes", wintypes.USHORT), ("NumberInputButtonCaps", wintypes.USHORT),
                ("NumberInputValueCaps", wintypes.USHORT), ("NumberInputDataIndices", wintypes.USHORT),
                ("NumberOutputButtonCaps", wintypes.USHORT), ("NumberOutputValueCaps", wintypes.USHORT),
                ("NumberOutputDataIndices", wintypes.USHORT), ("NumberFeatureButtonCaps", wintypes.USHORT),
                ("NumberFeatureValueCaps", wintypes.USHORT), ("NumberFeatureDataIndices", wintypes.USHORT)]


class HIDP_VALUE_CAPS(ctypes.Structure):
    _fields_ = [("UsagePage", wintypes.USHORT), ("ReportID", ctypes.c_ubyte), ("IsAlias", ctypes.c_ubyte),
                ("BitField", wintypes.USHORT), ("LinkCollection", wintypes.USHORT),
                ("LinkUsage", wintypes.USHORT), ("LinkUsagePage", wintypes.USHORT),
                ("IsRange", ctypes.c_ubyte), ("IsStringRange", ctypes.c_ubyte),
                ("IsDesignatorRange", ctypes.c_ubyte), ("IsAbsolute", ctypes.c_ubyte),
                ("HasNull", ctypes.c_ubyte), ("Reserved", ctypes.c_ubyte), ("BitSize", wintypes.USHORT),
                ("ReportCount", wintypes.USHORT), ("Reserved2", wintypes.USHORT * 5),
                ("UnitsExp", wintypes.ULONG), ("Units", wintypes.ULONG),
                ("LogicalMin", wintypes.LONG), ("LogicalMax", wintypes.LONG),
                ("PhysicalMin", wintypes.LONG), ("PhysicalMax", wintypes.LONG),
                ("UsageMin", wintypes.USHORT), ("UsageMax", wintypes.USHORT),  # = NotRange.Usage
                ("Rest", wintypes.USHORT * 6)]


WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)


class WNDCLASSW(ctypes.Structure):
    _fields_ = [("style", wintypes.UINT), ("lpfnWndProc", WNDPROC), ("cbClsExtra", ctypes.c_int),
                ("cbWndExtra", ctypes.c_int), ("hInstance", wintypes.HINSTANCE), ("hIcon", wintypes.HICON),
                ("hCursor", wintypes.HANDLE), ("hbrBackground", wintypes.HBRUSH),
                ("lpszMenuName", wintypes.LPCWSTR), ("lpszClassName", wintypes.LPCWSTR)]


kernel32.GetModuleHandleW.restype = wintypes.HMODULE  # 64-bit: the default int would cut it
user32.RegisterClassW.argtypes = [ctypes.c_void_p]
user32.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.DefWindowProcW.restype = ctypes.c_ssize_t
user32.CreateWindowExW.restype = wintypes.HWND
user32.CreateWindowExW.argtypes = [wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
                                   ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
                                   wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID]
user32.GetRawInputData.argtypes = [ctypes.c_void_p, wintypes.UINT, ctypes.c_void_p,
                                   ctypes.POINTER(wintypes.UINT), wintypes.UINT]
user32.GetRawInputDeviceInfoW.argtypes = [wintypes.HANDLE, wintypes.UINT, ctypes.c_void_p,
                                          ctypes.POINTER(wintypes.UINT)]
for name in ("HidP_GetUsageValue", "HidP_GetUsages", "HidP_GetCaps", "HidP_GetValueCaps"):
    getattr(hid, name).restype = ctypes.c_long


class _Device:
    """The layout of one touchpad's reports, learned from its HID description."""

    def __init__(self, handle):
        size = wintypes.UINT()
        user32.GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, None, ctypes.byref(size))
        self.preparsed = ctypes.create_string_buffer(size.value)
        user32.GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, self.preparsed, ctypes.byref(size))
        caps = HIDP_CAPS()
        hid.HidP_GetCaps(self.preparsed, ctypes.byref(caps))
        values = (HIDP_VALUE_CAPS * caps.NumberInputValueCaps)()
        count = wintypes.USHORT(caps.NumberInputValueCaps)
        hid.HidP_GetValueCaps(HIDP_INPUT, values, ctypes.byref(count), self.preparsed)
        self.fingers = {}  # link collection -> (x max, y max)
        self.count_link = None
        for v in values[:count.value]:
            if v.UsagePage == PAGE_GENERIC and v.UsageMin == USAGE_X:
                self.fingers.setdefault(v.LinkCollection, [1, 1])[0] = max(v.LogicalMax, 1)
            elif v.UsagePage == PAGE_GENERIC and v.UsageMin == USAGE_Y:
                self.fingers.setdefault(v.LinkCollection, [1, 1])[1] = max(v.LogicalMax, 1)
            elif v.UsagePage == PAGE_DIGITIZER and v.UsageMin == USAGE_CONTACT_COUNT:
                self.count_link = v.LinkCollection
        self.links = sorted(self.fingers)

    def value(self, page, link, usage, report):
        out = wintypes.ULONG()
        status = hid.HidP_GetUsageValue(HIDP_INPUT, wintypes.USHORT(page), wintypes.USHORT(link),
                                        wintypes.USHORT(usage), ctypes.byref(out), self.preparsed,
                                        report, wintypes.ULONG(len(report)))
        return out.value if status == HIDP_STATUS_SUCCESS else None

    def _usages(self, page, link, report):
        usages = (wintypes.USHORT * 16)()
        length = wintypes.ULONG(16)
        status = hid.HidP_GetUsages(HIDP_INPUT, wintypes.USHORT(page), wintypes.USHORT(link),
                                    usages, ctypes.byref(length), self.preparsed, report,
                                    wintypes.ULONG(len(report)))
        return usages[:length.value] if status == HIDP_STATUS_SUCCESS else []

    def tip(self, link, report):
        return USAGE_TIP in self._usages(PAGE_DIGITIZER, link, report)

    def button(self, report):
        """The touchpad's own click (pressing the surface down)."""
        return 1 in self._usages(PAGE_BUTTON, 0, report)

    def contacts(self, report):
        """[(contact id, x 0..1, y 0..1, touching)] in this report."""
        count = self.value(PAGE_DIGITIZER, self.count_link or 0, USAGE_CONTACT_COUNT, report) or 0
        links = self.links[:count] if count else self.links[:1]
        found = []
        for link in links:
            x = self.value(PAGE_GENERIC, link, USAGE_X, report)
            y = self.value(PAGE_GENERIC, link, USAGE_Y, report)
            contact = self.value(PAGE_DIGITIZER, link, USAGE_CONTACT_ID, report)
            if x is None or y is None:
                continue
            x_max, y_max = self.fingers[link]
            found.append((contact if contact is not None else link, x / x_max, y / y_max,
                          self.tip(link, report)))
        return found


class Touchpad:
    """Calls on_gesture(fingers, kind) with kind "up", "down", "left", "right" or
    "tap", for gestures with three or more fingers, while `listening` is set.
    Runs its own thread with a hidden window that receives the raw reports."""

    def __init__(self, on_gesture, on_report=None):
        self.on_gesture = on_gesture
        # on_report(touching, clicked) after every report: {contact id: (x, y)} of
        # the fingers down (0..1 of the touchpad), and whether it's pressed down
        self.on_report = on_report
        self.clicked = False
        self.listening = threading.Event()
        self.ready = threading.Event()
        self.problem = None
        self.devices = {}
        self.touching = {}  # contact id -> (x, y)
        self.gesture = None
        threading.Thread(target=self._run, name="touchpad", daemon=True).start()

    def _run(self):
        self._proc = WNDPROC(self._window_proc)
        instance = kernel32.GetModuleHandleW(None)
        wc = WNDCLASSW(lpfnWndProc=self._proc, hInstance=instance, lpszClassName="ExtendDisplayTouchpad")
        user32.RegisterClassW(ctypes.byref(wc))
        hwnd = user32.CreateWindowExW(0, "ExtendDisplayTouchpad", None, 0, 0, 0, 0, 0,
                                      HWND_MESSAGE, None, instance, None)
        device = RAWINPUTDEVICE(PAGE_DIGITIZER, 0x05, RIDEV_INPUTSINK, hwnd)  # 0x05 = touch pad
        if not hwnd or not user32.RegisterRawInputDevices(ctypes.byref(device), 1, ctypes.sizeof(device)):
            self.problem = f"couldn't listen to the touchpad (error {ctypes.get_last_error()})"
        self.ready.set()
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    def _window_proc(self, hwnd, message, wparam, lparam):
        if message == WM_INPUT:
            try:
                self._on_input(lparam)
            except Exception as e:  # never let a bad report take the thread down
                print(f"touchpad: {e!r}")
        return user32.DefWindowProcW(hwnd, message, wparam, lparam)

    def _on_input(self, lparam):
        size = wintypes.UINT()
        header_size = ctypes.sizeof(RAWINPUTHEADER)
        user32.GetRawInputData(lparam, RID_INPUT, None, ctypes.byref(size), header_size)
        data = ctypes.create_string_buffer(size.value)
        user32.GetRawInputData(lparam, RID_INPUT, data, ctypes.byref(size), header_size)
        header = RAWINPUTHEADER.from_buffer(data)
        if header.dwType != RIM_TYPEHID or not self.listening.is_set():
            return
        report_size, report_count = ctypes.c_uint32.from_buffer(data, header_size).value, \
            ctypes.c_uint32.from_buffer(data, header_size + 4).value
        device = self.devices.get(header.hDevice)
        if device is None:
            device = self.devices[header.hDevice] = _Device(header.hDevice)
        start = header_size + 8
        for i in range(report_count):
            report = data.raw[start + i * report_size:start + (i + 1) * report_size]
            for contact, x, y, touching in device.contacts(report):
                if touching:
                    self.touching[contact] = (x, y)
                else:
                    self.touching.pop(contact, None)
            self.clicked = device.button(report)
            self._track()
            if self.on_report:
                self.on_report(dict(self.touching), self.clicked)

    def _track(self):
        fingers = len(self.touching)
        if fingers:
            cx = sum(x for x, _ in self.touching.values()) / fingers
            cy = sum(y for _, y in self.touching.values()) / fingers
        if fingers >= 3:
            if self.gesture is None:
                self.gesture = {"start": (cx, cy), "last": (cx, cy), "fingers": fingers, "time": time.time()}
            else:
                self.gesture["fingers"] = max(self.gesture["fingers"], fingers)
                self.gesture["last"] = (cx, cy)
        elif fingers == 0 and self.gesture:
            g, self.gesture = self.gesture, None
            dx = g["last"][0] - g["start"][0]
            dy = g["last"][1] - g["start"][1]
            if max(abs(dx), abs(dy)) >= SWIPE_DISTANCE:
                kind = ("down" if dy > 0 else "up") if abs(dy) > abs(dx) else ("right" if dx > 0 else "left")
            elif time.time() - g["time"] < TAP_SECONDS:
                kind = "tap"
            else:
                return
            self.on_gesture(g["fingers"], kind)
