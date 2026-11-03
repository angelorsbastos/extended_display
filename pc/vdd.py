"""Create and remove virtual screens with the Parsec Virtual Display Driver.

A Python port of the control calls in github.com/nomi-san/parsec-vdd (core/parsec-vdd.h).
The driver removes every screen we added unless we ping it at least every ~100 ms,
so if this program dies, Windows drops the virtual screens by itself.
"""
import ctypes
import threading
from ctypes import wintypes

setupapi = ctypes.windll.setupapi
kernel32 = ctypes.windll.kernel32

IOCTL_ADD = 0x0022E004
IOCTL_REMOVE = 0x0022A008
IOCTL_UPDATE = 0x0022A00C  # the "ping"
PING_INTERVAL = 0.05

DIGCF_PRESENT = 0x2
DIGCF_DEVICEINTERFACE = 0x10
INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value


class GUID(ctypes.Structure):
    _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]


# {00b41627-04c4-429e-a26e-0265cf50c8fa}: the Parsec adapter's device interface
ADAPTER_GUID = GUID(0x00B41627, 0x04C4, 0x429E,
                    (ctypes.c_ubyte * 8)(0xA2, 0x6E, 0x02, 0x65, 0xCF, 0x50, 0xC8, 0xFA))


class SP_DEVICE_INTERFACE_DATA(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("InterfaceClassGuid", GUID),
                ("Flags", wintypes.DWORD), ("Reserved", ctypes.c_void_p)]


class OVERLAPPED(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_void_p), ("InternalHigh", ctypes.c_void_p),
                ("Offset", wintypes.DWORD), ("OffsetHigh", wintypes.DWORD),
                ("hEvent", wintypes.HANDLE)]


setupapi.SetupDiGetClassDevsW.restype = wintypes.HANDLE
setupapi.SetupDiGetClassDevsW.argtypes = [ctypes.POINTER(GUID), wintypes.LPCWSTR,
                                          wintypes.HWND, wintypes.DWORD]
setupapi.SetupDiEnumDeviceInterfaces.argtypes = [wintypes.HANDLE, ctypes.c_void_p,
                                                 ctypes.POINTER(GUID), wintypes.DWORD,
                                                 ctypes.POINTER(SP_DEVICE_INTERFACE_DATA)]
setupapi.SetupDiGetDeviceInterfaceDetailW.argtypes = [
    wintypes.HANDLE, ctypes.POINTER(SP_DEVICE_INTERFACE_DATA), ctypes.c_void_p,
    wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
setupapi.SetupDiDestroyDeviceInfoList.argtypes = [wintypes.HANDLE]
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                 wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
kernel32.CreateEventW.restype = wintypes.HANDLE
kernel32.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p,
                                     wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
                                     ctypes.c_void_p, ctypes.POINTER(OVERLAPPED)]
kernel32.GetOverlappedResultEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(OVERLAPPED),
                                           ctypes.POINTER(wintypes.DWORD), wintypes.DWORD,
                                           wintypes.BOOL]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


class DriverNotFound(Exception):
    pass


def _open_adapter():
    devs = setupapi.SetupDiGetClassDevsW(ctypes.byref(ADAPTER_GUID), None, None,
                                         DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)
    if devs == INVALID_HANDLE_VALUE:
        raise DriverNotFound("could not list devices")
    try:
        iface = SP_DEVICE_INTERFACE_DATA()
        iface.cbSize = ctypes.sizeof(iface)
        i = 0
        while setupapi.SetupDiEnumDeviceInterfaces(devs, None, ctypes.byref(ADAPTER_GUID),
                                                   i, ctypes.byref(iface)):
            i += 1
            size = wintypes.DWORD()
            setupapi.SetupDiGetDeviceInterfaceDetailW(devs, ctypes.byref(iface), None, 0,
                                                      ctypes.byref(size), None)
            detail = ctypes.create_string_buffer(size.value)
            # SP_DEVICE_INTERFACE_DETAIL_DATA_W: DWORD cbSize (8 on 64-bit) + path
            ctypes.c_uint32.from_buffer(detail).value = 8
            if not setupapi.SetupDiGetDeviceInterfaceDetailW(devs, ctypes.byref(iface), detail,
                                                             size, None, None):
                continue
            path = ctypes.wstring_at(ctypes.addressof(detail) + 4)
            handle = kernel32.CreateFileW(
                path, 0xC0000000, 0x3, None, 3,  # read/write, shared, OPEN_EXISTING
                0x80 | 0x20000000 | 0x40000000 | 0x80000000,  # normal, no buffering, overlapped, write-through
                None)
            if handle not in (None, INVALID_HANDLE_VALUE):
                return handle
    finally:
        setupapi.SetupDiDestroyDeviceInfoList(devs)
    raise DriverNotFound("Parsec Virtual Display Adapter not found; is the driver installed?")


class VirtualDisplays:
    """Owns the driver connection and the ping thread. Use add() / remove() / close()."""

    def __init__(self):
        self.handle = _open_adapter()
        self.added = []
        self.closed = threading.Event()
        threading.Thread(target=self._ping_loop, daemon=True).start()

    def _ioctl(self, code, data=b""):
        in_buf = ctypes.create_string_buffer(data, 32)
        out = wintypes.DWORD()
        transferred = wintypes.DWORD()
        ov = OVERLAPPED()
        ov.hEvent = kernel32.CreateEventW(None, True, False, None)
        try:
            kernel32.DeviceIoControl(self.handle, code, in_buf, 32, ctypes.byref(out), 4,
                                     None, ctypes.byref(ov))
            if not kernel32.GetOverlappedResultEx(self.handle, ctypes.byref(ov),
                                                  ctypes.byref(transferred), 5000, False):
                return -1
            return out.value
        finally:
            kernel32.CloseHandle(ov.hEvent)

    def _ping_loop(self):
        while not self.closed.wait(PING_INTERVAL):
            self._ioctl(IOCTL_UPDATE)

    def add(self):
        """Plug in a new virtual screen; returns its driver index."""
        index = self._ioctl(IOCTL_ADD)
        self._ioctl(IOCTL_UPDATE)
        if index == -1 or index > 0xFFFF:
            raise OSError("the driver refused to add a display")
        self.added.append(index)
        return index

    def remove(self, index):
        # the driver wants the index as a 16-bit big-endian number
        self._ioctl(IOCTL_REMOVE, index.to_bytes(2, "big"))
        self._ioctl(IOCTL_UPDATE)
        if index in self.added:
            self.added.remove(index)

    def close(self):
        # newest first, so Windows keeps the arrangement of the others
        for index in reversed(list(self.added)):
            self.remove(index)
        self.closed.set()
        kernel32.CloseHandle(self.handle)
