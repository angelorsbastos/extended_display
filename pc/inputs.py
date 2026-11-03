"""Turn the iPad's touch, trackpad and keyboard events into real Windows input.

Touch uses Windows touch injection, so Windows treats the iPad as a touchscreen
(tap, drag, swipe-scroll, pinch, long-press for right-click).
Trackpad and keyboard go through SendInput. Keys are sent as scan codes, so
Windows applies its own keyboard layout (e.g. Portuguese, AltGr included).
"""
import ctypes
import threading
import time
from ctypes import wintypes

user32 = ctypes.windll.user32


# ---- touch ---------------------------------------------------------------------

class POINTER_INFO(ctypes.Structure):
    _fields_ = [("pointerType", ctypes.c_uint32), ("pointerId", ctypes.c_uint32),
                ("frameId", ctypes.c_uint32), ("pointerFlags", ctypes.c_uint32),
                ("sourceDevice", wintypes.HANDLE), ("hwndTarget", wintypes.HWND),
                ("ptPixelLocation", wintypes.POINT), ("ptHimetricLocation", wintypes.POINT),
                ("ptPixelLocationRaw", wintypes.POINT), ("ptHimetricLocationRaw", wintypes.POINT),
                ("dwTime", wintypes.DWORD), ("historyCount", ctypes.c_uint32),
                ("InputData", ctypes.c_int32), ("dwKeyStates", wintypes.DWORD),
                ("PerformanceCount", ctypes.c_uint64), ("ButtonChangeType", ctypes.c_int)]


class POINTER_TOUCH_INFO(ctypes.Structure):
    _fields_ = [("pointerInfo", POINTER_INFO), ("touchFlags", ctypes.c_uint32),
                ("touchMask", ctypes.c_uint32), ("rcContact", wintypes.RECT),
                ("rcContactRaw", wintypes.RECT), ("orientation", ctypes.c_uint32),
                ("pressure", ctypes.c_uint32)]


PT_TOUCH = 2
POINTER_FLAG_INRANGE, POINTER_FLAG_INCONTACT = 0x2, 0x4
POINTER_FLAG_DOWN, POINTER_FLAG_UPDATE, POINTER_FLAG_UP = 0x10000, 0x20000, 0x40000
POINTER_FLAG_CANCELED = 0x8000
TOUCH_FEEDBACK_DEFAULT = 0x1
MAX_TOUCHES = 10
CONTACT_RADIUS = 4  # pixels around the finger point; Windows wants some contact area
TOUCH_MASK_CONTACTAREA = 0x1
REPEAT_INTERVAL = 0.05  # a finger held still must still be re-sent, or Windows drops it

user32.InjectTouchInput.argtypes = [ctypes.c_uint32, ctypes.POINTER(POINTER_TOUCH_INFO)]


class Touchscreen:
    """Injects multi-touch on one screen. Call update() with the iPad's fingers;
    coordinates are fractions (0..1) of that screen."""

    def __init__(self):
        # if Windows refuses, touch is off but video, keyboard and trackpad still work
        self.ok = bool(user32.InitializeTouchInjection(MAX_TOUCHES, TOUCH_FEEDBACK_DEFAULT))
        if not self.ok:
            print(f"touch injection unavailable: {ctypes.WinError()}")
        self.lock = threading.Lock()
        self.rect = None      # (left, top, width, height) of the screen being touched
        self.down = {}        # finger id -> (x, y) in pixels, for fingers touching now
        threading.Thread(target=self._repeat, daemon=True).start()

    def set_screen(self, left, top, width, height):
        with self.lock:
            self.rect = (left, top, width, height)

    def update(self, touches):
        """touches: [{"id", "x", "y", "state": "down"|"move"|"up"|"cancel"}]"""
        with self.lock:
            if not self.rect:
                return
            left, top, width, height = self.rect
            frame = []
            for t in touches:
                tid = int(t["id"]) % MAX_TOUCHES
                x = left + round(min(max(t["x"], 0.0), 1.0) * (width - 1))
                y = top + round(min(max(t["y"], 0.0), 1.0) * (height - 1))
                state = t["state"]
                if state == "down":
                    flags = POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT
                    self.down[tid] = (x, y)
                elif state == "move":
                    if tid not in self.down:
                        continue
                    flags = POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT
                    self.down[tid] = (x, y)
                else:  # up / cancel
                    if tid not in self.down:
                        continue
                    x, y = self.down.pop(tid)
                    flags = POINTER_FLAG_UP | (POINTER_FLAG_CANCELED if state == "cancel" else 0)
                frame.append((tid, x, y, flags))
            # every finger still touching has to be part of each frame
            sent = {f[0] for f in frame}
            frame += [(tid, x, y, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT)
                      for tid, (x, y) in self.down.items() if tid not in sent]
            self._inject(frame)

    def release_all(self):
        with self.lock:
            frame = [(tid, x, y, POINTER_FLAG_UP | POINTER_FLAG_CANCELED)
                     for tid, (x, y) in self.down.items()]
            self.down.clear()
            self._inject(frame)

    def _repeat(self):
        while True:
            time.sleep(REPEAT_INTERVAL)
            with self.lock:
                if self.down:
                    self._inject([(tid, x, y, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE
                                   | POINTER_FLAG_INCONTACT)
                                  for tid, (x, y) in self.down.items()])

    def _inject(self, frame):
        if not frame or not self.ok:
            return
        infos = (POINTER_TOUCH_INFO * len(frame))()
        for info, (tid, x, y, flags) in zip(infos, frame):
            info.pointerInfo.pointerType = PT_TOUCH
            info.pointerInfo.pointerId = tid
            info.pointerInfo.pointerFlags = flags
            info.pointerInfo.ptPixelLocation = wintypes.POINT(x, y)
            info.touchMask = TOUCH_MASK_CONTACTAREA
            info.rcContact = wintypes.RECT(x - CONTACT_RADIUS, y - CONTACT_RADIUS,
                                           x + CONTACT_RADIUS, y + CONTACT_RADIUS)
        if not user32.InjectTouchInput(len(frame), infos):
            print(f"touch injection failed: {ctypes.WinError()}")


# ---- mouse and keyboard (SendInput) ---------------------------------------------

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.c_void_p)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_void_p)]


class _INPUTUNION(ctypes.Union):
    # MOUSEINPUT is the largest member, so it sets the union's size
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE, MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x1, 0x800, 0x1000
MOUSE_BUTTONS = {"left": (0x2, 0x4), "right": (0x8, 0x10), "middle": (0x20, 0x40)}
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE = 0x1, 0x2, 0x8
WHEEL_DELTA = 120

user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]


def _send(*inputs):
    arr = (INPUT * len(inputs))(*inputs)
    user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))


def _mouse(flags, dx=0, dy=0, data=0):
    i = INPUT(type=INPUT_MOUSE)
    i.u.mi = MOUSEINPUT(dx, dy, ctypes.c_uint32(data).value, flags, 0, None)
    return i


def mouse_move(dx, dy):
    _send(_mouse(MOUSEEVENTF_MOVE, round(dx), round(dy)))


_held = set()  # keys / buttons currently pressed through us, to release on disconnect


def mouse_button(button, down):
    press, release = MOUSE_BUTTONS[button]
    _send(_mouse(press if down else release))
    (_held.add if down else _held.discard)(("button", button))


def release_all():
    """Let go of every key and button still held, e.g. when the iPad disconnects
    mid-press; otherwise Windows would think Ctrl (say) is stuck down."""
    for kind, value in list(_held):
        if kind == "button":
            mouse_button(value, False)
        else:
            key(value, False)


def scroll(dx, dy):
    """dx/dy in wheel notches; fractions are fine (smooth trackpad scrolling)."""
    inputs = []
    if dy:
        inputs.append(_mouse(MOUSEEVENTF_WHEEL, data=round(dy * WHEEL_DELTA)))
    if dx:
        inputs.append(_mouse(MOUSEEVENTF_HWHEEL, data=round(dx * WHEEL_DELTA)))
    if inputs:
        _send(*inputs)


# HID keyboard usage (what the iPad reports) -> (PC scan code, is extended key).
# Cmd acts as Ctrl and Ctrl as the Windows key, as chosen for this app.
HID_TO_SCAN = {
    **{4 + i: (code, False) for i, code in enumerate(
        [0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
         0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C])},  # a-z
    **{30 + i: (0x02 + i, False) for i in range(10)},                                   # 1-9, 0
    40: (0x1C, False), 41: (0x01, False), 42: (0x0E, False), 43: (0x0F, False),          # enter esc bksp tab
    44: (0x39, False), 45: (0x0C, False), 46: (0x0D, False), 47: (0x1A, False),          # space - = [
    48: (0x1B, False), 49: (0x2B, False), 50: (0x2B, False), 51: (0x27, False),          # ] \ # ;
    52: (0x28, False), 53: (0x29, False), 54: (0x33, False), 55: (0x34, False),          # ' ` , .
    56: (0x35, False), 57: (0x3A, False),                                                # / capslock
    **{58 + i: (0x3B + i, False) for i in range(10)}, 68: (0x57, False), 69: (0x58, False),  # F1-F12
    70: (0x37, True), 71: (0x46, False),                                                 # printscreen scrolllock
    73: (0x52, True), 74: (0x47, True), 75: (0x49, True), 76: (0x53, True),              # ins home pgup del
    77: (0x4F, True), 78: (0x51, True), 79: (0x4D, True), 80: (0x4B, True),              # end pgdn right left
    81: (0x50, True), 82: (0x48, True),                                                  # down up
    100: (0x56, False),                                                                  # ISO key next to left shift
    224: (0x5B, True),   # left Ctrl  -> Windows key
    225: (0x2A, False),  # left Shift
    226: (0x38, False),  # left Option -> Alt
    227: (0x1D, False),  # left Cmd   -> Ctrl
    228: (0x5C, True),   # right Ctrl -> Windows key
    229: (0x36, False),  # right Shift
    230: (0x38, True),   # right Option -> AltGr
    231: (0x1D, True),   # right Cmd  -> Ctrl
}


def key(usage, down):
    """Press or release one key, given its HID usage code. False if unknown."""
    if usage not in HID_TO_SCAN:
        return False
    scan, extended = HID_TO_SCAN[usage]
    flags = KEYEVENTF_SCANCODE | (KEYEVENTF_EXTENDEDKEY if extended else 0) \
        | (0 if down else KEYEVENTF_KEYUP)
    i = INPUT(type=INPUT_KEYBOARD)
    i.u.ki = KEYBDINPUT(0, scan, flags, 0, None)
    _send(i)
    (_held.add if down else _held.discard)(("key", usage))
    return True
