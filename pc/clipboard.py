"""Read and write the Windows clipboard: text and images (images as PNG bytes)."""
import ctypes
import io
from ctypes import wintypes

from PIL import Image, ImageGrab

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
CF_UNICODETEXT, CF_DIB = 13, 8
GMEM_MOVEABLE = 0x2
MAX_IMAGE_BYTES = 8 * 1024 * 1024  # don't push huge screenshots over the cable

user32.GetClipboardData.restype = wintypes.HANDLE
user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
user32.SetClipboardData.restype = wintypes.HANDLE
kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]


def sequence_number():
    """Changes every time anything is copied; cheap to poll."""
    return user32.GetClipboardSequenceNumber()


def read():
    """("text", str) or ("image", png bytes) or None."""
    try:
        grabbed = ImageGrab.grabclipboard()
    except OSError:  # clipboard busy (another app has it open)
        return None
    if isinstance(grabbed, Image.Image):
        out = io.BytesIO()
        grabbed.save(out, "PNG")
        png = out.getvalue()
        return ("image", png) if len(png) <= MAX_IMAGE_BYTES else None
    if not user32.OpenClipboard(None):
        return None
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None
        ptr = kernel32.GlobalLock(handle)
        try:
            return ("text", ctypes.wstring_at(ptr))
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def _set(fmt, data):
    if not user32.OpenClipboard(None):
        raise OSError("clipboard busy")
    try:
        user32.EmptyClipboard()
        mem = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        ptr = kernel32.GlobalLock(mem)
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(mem)
        user32.SetClipboardData(fmt, mem)  # the clipboard owns `mem` from now on
    finally:
        user32.CloseClipboard()


def write_text(text):
    _set(CF_UNICODETEXT, (text + "\0").encode("utf-16-le"))


def write_image(png):
    image = Image.open(io.BytesIO(png)).convert("RGB")
    out = io.BytesIO()
    image.save(out, "BMP")
    _set(CF_DIB, out.getvalue()[14:])  # a DIB is a .bmp file without its 14-byte header
