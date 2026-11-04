"""The real icon of an app, file or folder on the laptop, as a PNG, for the
iPad's shortcut buttons. Works for Start menu apps (shell:AppsFolder\\..., so
Store apps too), .exe and .lnk files, folders, documents: Windows' shell draws
whatever icon Explorer would show (IShellItemImageFactory).

Shell objects use COM: call png() on the controls worker thread (controls.py),
where COM is set up, never from several threads at once.
"""
import base64
import ctypes
import io
from ctypes import wintypes

import comtypes
from comtypes import COMMETHOD, GUID, HRESULT, IUnknown
from PIL import Image

SIZE_PX = 96
SIIGBF_BIGGERSIZEOK, SIIGBF_ICONONLY = 0x1, 0x4


class SIZE(ctypes.Structure):
    _fields_ = [("cx", ctypes.c_long), ("cy", ctypes.c_long)]


class IShellItemImageFactory(IUnknown):
    _iid_ = GUID("{bcc18b79-ba16-442f-80c4-8a59c30c463b}")
    _methods_ = [COMMETHOD([], HRESULT, "GetImage", (["in"], SIZE, "size"), (["in"], ctypes.c_int, "flags"),
                           (["out"], ctypes.POINTER(wintypes.HBITMAP), "phbm"))]


class BITMAP(ctypes.Structure):
    _fields_ = [("bmType", ctypes.c_long), ("bmWidth", ctypes.c_long), ("bmHeight", ctypes.c_long),
                ("bmWidthBytes", ctypes.c_long), ("bmPlanes", wintypes.WORD), ("bmBitsPixel", wintypes.WORD),
                ("bmBits", ctypes.c_void_p)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


shell32 = ctypes.WinDLL("shell32")
gdi32 = ctypes.WinDLL("gdi32")
user32 = ctypes.WinDLL("user32")
shell32.SHCreateItemFromParsingName.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, ctypes.POINTER(GUID),
                                                 ctypes.c_void_p]
gdi32.GetObjectW.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p]
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT, ctypes.c_void_p,
                            ctypes.c_void_p, wintypes.UINT]
gdi32.DeleteObject.argtypes = [wintypes.HANDLE]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]


def png(target):
    """Base64 PNG of the icon Explorer shows for `target`, or None."""
    factory = ctypes.POINTER(IShellItemImageFactory)()
    if shell32.SHCreateItemFromParsingName(str(target), None, ctypes.byref(IShellItemImageFactory._iid_),
                                           ctypes.byref(factory)) != 0 or not factory:
        return None
    try:
        bitmap = factory.GetImage(SIZE(SIZE_PX, SIZE_PX), SIIGBF_BIGGERSIZEOK | SIIGBF_ICONONLY)
    except comtypes.COMError:
        return None
    try:
        return _encode(bitmap)
    finally:
        gdi32.DeleteObject(bitmap)


def _encode(bitmap):
    info = BITMAP()
    gdi32.GetObjectW(bitmap, ctypes.sizeof(info), ctypes.byref(info))
    width, height = info.bmWidth, info.bmHeight
    header = BITMAPINFOHEADER(biSize=ctypes.sizeof(BITMAPINFOHEADER), biWidth=width, biHeight=-height,  # top-down
                              biPlanes=1, biBitCount=32, biCompression=0)
    pixels = ctypes.create_string_buffer(width * height * 4)
    dc = user32.GetDC(None)
    try:
        gdi32.GetDIBits(dc, bitmap, 0, height, pixels, ctypes.byref(header), 0)
    finally:
        user32.ReleaseDC(None, dc)
    image = Image.frombuffer("RGBA", (width, height), pixels.raw, "raw", "BGRA", 0, 1)
    if image.getextrema()[3][1] == 0:  # no alpha at all: an old-style icon, treat as opaque
        image.putalpha(255)
    out = io.BytesIO()
    image.save(out, "PNG", optimize=True)
    return base64.b64encode(out.getvalue()).decode()
