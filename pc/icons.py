"""The real icon of an app, file or folder on the laptop, as a PNG, for the
iPad's shortcut buttons. Works for Start menu apps (shell:AppsFolder\\..., so
Store apps too), .exe and .lnk files, folders, documents: Windows' shell draws
whatever icon Explorer would show (IShellItemImageFactory).

Shell objects use COM: call png() on the controls worker thread (controls.py),
where COM is set up, never from several threads at once.

Websites have no icon in Windows (it shows a blank page), so for a web address
the site's own icon is fetched instead: the big one sites make for phone home
screens if there is one, else the browser-tab one. None if neither works, and
the iPad keeps the shortcut's symbol.
"""
import base64
import ctypes
import io
import re
import urllib.error
import urllib.parse
import urllib.request
from ctypes import wintypes
from html.parser import HTMLParser

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


def for_target(target, worker):
    """Base64 PNG for a shortcut's target, or None: a website's own icon, or
    (through `worker`, the COM thread) the icon Explorer shows."""
    target = str(target)
    if re.match(r"https?://", target, re.I):
        try:
            return website(target)
        except Exception as e:  # any network or image problem: the symbol stays
            print(f"no icon for {target}: {e!r}")
            return None
    return worker.submit(png, target).result()


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


# ---- websites ---------------------------------------------------------------------

FETCH_TIMEOUT = 6
MAX_BYTES = 1_000_000


def _get(url, error_pages=False):
    """(final URL, body). With error_pages, a "not logged in" or similar page is
    returned too: it usually carries the site's icons all the same."""
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0) Wingman"})
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
            return response.geturl(), response.read(MAX_BYTES)
    except urllib.error.HTTPError as e:
        if not error_pages:
            raise
        return e.geturl(), e.read(MAX_BYTES)


class _IconLinks(HTMLParser):
    """The page's <link rel="...icon..."> tags: [(rel, size, href)]."""

    def __init__(self):
        super().__init__()
        self.found = []

    def handle_starttag(self, tag, attrs):
        if tag != "link":
            return
        a = {k.lower(): (v or "") for k, v in attrs}
        rel = a.get("rel", "").lower()
        if "icon" in rel and a.get("href"):
            sizes = re.findall(r"(\d+)x\d+", a.get("sizes", ""))
            self.found.append((rel, max(map(int, sizes)) if sizes else 0, a["href"]))


def website(url):
    """Base64 PNG of the site's icon, or None."""
    candidates = []
    page_url = url
    site = _site(url)
    origin = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(url))
    # the page itself, then the site's front page (a page behind a login often
    # has no icons of its own, the login page does)
    for page_address in dict.fromkeys([url, origin + "/"]):
        try:
            page_url, page = _get(page_address, error_pages=True)
        except Exception:
            continue  # didn't load: still try the usual places
        if _site(page_url) != site:
            # sent to another site, e.g. a university login: its icon isn't this one
            page_url = url
            continue
        links = _IconLinks()
        links.feed(page.decode("utf-8", "replace"))
        # phone home-screen icons first (big and square), then the biggest declared
        links.found.sort(key=lambda f: ("apple-touch-icon" in f[0], f[1]), reverse=True)
        candidates += [urllib.parse.urljoin(page_url, href) for _, _, href in links.found]
        if links.found:
            break
    origin = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(page_url))
    candidates += [origin + "/apple-touch-icon.png", origin + "/favicon.ico"]
    for candidate in dict.fromkeys(candidates):  # in order, once each
        if candidate.lower().split("?")[0].endswith(".svg"):
            continue  # Pillow can't draw these
        try:
            return _image_png(_get(candidate)[1])
        except Exception:
            continue
    return None


def _site(url):
    """example.com for www.example.com, app.example.com and example.com alike."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return ".".join(host.split(".")[-2:])


def _image_png(data):
    image = Image.open(io.BytesIO(data))
    if getattr(image, "format", "") == "ICO":  # several sizes inside: the largest
        sizes = sorted(image.info.get("sizes") or [image.size], key=lambda s: s[0] * s[1])
        image.size = sizes[-1]
    image = image.convert("RGBA")
    if image.width < 16 or image.height < 16:
        raise ValueError("too small")
    image.thumbnail((SIZE_PX, SIZE_PX), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "PNG", optimize=True)
    return base64.b64encode(out.getvalue()).decode()
