"""Ctrl+Alt+I: the laptop's keyboard and trackpad control the iPad, over
Bluetooth (see bluetooth_hid.py), until Ctrl+Alt+I is pressed again.

How: a registered hotkey switches over. While switched, low-level keyboard and
mouse hooks catch all input before Windows sees it. The hooks exist only while
switched, so they can never slow down the laptop's own pointer. Keys are sent
by position (HID usage), so the iPad's keyboard layout setting decides the
characters, like a real keyboard.

The touchpad goes to the iPad as a real multi-touch trackpad: touchpad.py
reads the raw fingers and bluetooth_hid.py forwards them, so the pointer,
scrolling and gestures are the iPad's own. The mouse hook keeps the laptop's
pointer still, and a plugged-in mouse is played as fingers too
(mouse_fingers.py). The hook can't tell the two apart, so mouse input while
(or just after) fingers are on the touchpad counts as the touchpad's. Without a precision touchpad, pointer movement, clicks
and the wheel are sent as a mouse instead (the pointer waits mid-screen and
its movements are forwarded).

Keys map like Wingman does the other way round: Ctrl -> Cmd (so Ctrl+C
copies on the iPad), Alt -> Option, Win -> Ctrl, AltGr -> right Option.

Three/four-finger gestures never pass through the hooks: Windows' shell takes
them. While switched, a TouchpadGesturesController (Windows 11's official way
for remote-desktop-style apps) claims them instead, which only works while one
of our windows is in front, so the hint window is brought to the front and the
previous window gets the focus back afterwards.
"""
import ctypes
import os
import queue
import threading
import time
import tkinter
from ctypes import wintypes

import inputs
import osd
import touchpad
from mouse_fingers import MouseFingers
from bluetooth_hid import BluetoothHID

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

LRESULT = ctypes.c_ssize_t
HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = ctypes.c_void_p
user32.CallNextHookEx.argtypes = [ctypes.c_void_p, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.UnhookWindowsHookEx.argtypes = [ctypes.c_void_p]
user32.GetForegroundWindow.restype = ctypes.c_void_p
user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
user32.BringWindowToTop.argtypes = [ctypes.c_void_p]
user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
kernel32.GetModuleHandleW.restype = wintypes.HMODULE


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", wintypes.POINT), ("mouseData", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


WH_KEYBOARD_LL, WH_MOUSE_LL = 13, 14
WM_HOTKEY, WM_APP = 0x0312, 0x8000
WM_UNHOOK, WM_QUIT = WM_APP + 1, 0x0012
MOD_ALT, MOD_CONTROL, MOD_NOREPEAT = 0x1, 0x2, 0x4000
VK_I = 0x49
VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU = 0xA2, 0xA3, 0xA4, 0xA5
LLKHF_EXTENDED, LLKHF_INJECTED, LLKHF_UP = 0x01, 0x10, 0x80
LLMHF_INJECTED = 0x01
WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_MOUSEHWHEEL = 0x0200, 0x020A, 0x020E
MOUSE_BUTTON_MESSAGES = {0x0201: (1, True), 0x0202: (1, False), 0x0204: (2, True), 0x0205: (2, False),
                         0x0207: (4, True), 0x0208: (4, False)}

# (PC scan code, extended) -> HID usage: Wingman's iPad -> PC table, reversed.
# The key left of Enter on ISO keyboards (Portuguese: ~ ^) is HID 50, not 49.
SCAN_TO_HID = {scan: usage for usage, scan in inputs.HID_TO_SCAN.items() if usage != 49}
ALTGR_FAKE_CTRL = 0x21D  # Windows' extra left-Ctrl that comes with every AltGr press

ALL_GLOBAL_GESTURES = 0x3F  # TouchpadGlobalGestureKinds: 3/4/5-finger swipes and taps

POINTER_SCALE = 1.0  # laptop pointer movement -> iPad pointer movement
SCROLL_UNIT = 40     # Windows wheel units per iPad scroll step (a mouse notch is 120)
CONNECT_TIMEOUT = 12  # seconds to wait for the iPad before giving up
# mouse input this soon after the touchpad was touched is the touchpad's own
# (taps click a moment after the finger lifts)
TOUCHPAD_MOVE_GRACE, TOUCHPAD_CLICK_GRACE = 0.15, 0.6


WM_REQUEST = WM_APP + 2  # switch on (wParam 1) / off (0) on request from a device

_controller = None
listeners = set()  # called with True / False whenever it switches (hub tells the devices)


def start():
    global _controller
    _controller = Controller()


def is_active():
    return bool(_controller and _controller.active)


def request(on):
    """Switch from a device (the iPad's keyboard tile), as if Ctrl+Alt+I was pressed."""
    if _controller and _controller.thread_id:
        user32.PostThreadMessageW(_controller.thread_id, WM_REQUEST, int(bool(on)), 0)


def _tell(active):
    for listener in list(listeners):
        listener(active)


class Controller:
    """Owns the hotkey thread (with its message loop, where the hooks live too),
    the Bluetooth keyboard/mouse and the on-screen hint."""

    def __init__(self):
        self.hint = Hint()
        self.bluetooth = BluetoothHID(self._bluetooth_state)
        self.active = False
        self.thread_id = None
        self.hooks = []
        self.stopping = None  # timer that turns Bluetooth off after switching back
        self.gestures = None  # TouchpadGesturesController, made on the hotkey thread
        self.previous_window = None
        self.touchpad = touchpad.Touchpad(lambda *_: None, self._on_fingers)
        self.trackpad_mode = False  # the touchpad goes to the iPad as a trackpad (else as a mouse)
        self.touch_seen = 0.0  # when the touchpad last had fingers on it
        self.hook_calls = self.hook_slowest = 0  # diagnostics (_report_escape)
        self.mouse_fingers = MouseFingers(self.bluetooth.send_touch,
                                          lambda: bool(self.touchpad.touching) or self.touchpad.clicked)
        threading.Thread(target=self._run, name="ipad-control", daemon=True).start()

    # ---- hotkey thread -----------------------------------------------------------

    def _run(self):
        self.thread_id = kernel32.GetCurrentThreadId()
        if not user32.RegisterHotKey(None, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_I):
            print(f"Ctrl+Alt+I is taken by another app (error {ctypes.get_last_error()}); "
                  "controlling the iPad from the laptop is off")
            return
        print("Ctrl+Alt+I: the laptop's keyboard and trackpad control the iPad")
        self.gestures = _gesture_controller()
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_HOTKEY:
                self._enter()
            elif msg.message == WM_UNHOOK:
                self._unhook()
            elif msg.message == WM_REQUEST:
                self._enter() if msg.wParam else self._leave()
            else:  # the gesture controller's window lives on this thread
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))

    def _enter(self):
        if self.active:
            return
        if self.stopping:
            self.stopping.cancel()  # switched back and forth quickly: keep Bluetooth on
        self.active = True
        self.started = time.time()
        # keys Windows has seen go down (Ctrl, Alt, I): let their release reach it,
        # or Windows would think they're still held
        self.pc_held = {vk for vk in range(1, 255) if user32.GetAsyncKeyState(vk) & 0x8000}
        self.swallow = set()       # releases that belong to neither side any more
        self.ipad_held = {}        # vk -> HID usage, keys down on the iPad
        self.buttons = 0
        self.wheel_rest = self.pan_rest = 0
        point = wintypes.POINT()
        user32.GetCursorPos(ctypes.byref(point))
        self.pointer_home = (point.x, point.y)
        # the pointer waits mid-screen, so it never hits an edge and stops moving
        self.anchor = (user32.GetSystemMetrics(0) // 2, user32.GetSystemMetrics(1) // 2)
        user32.SetCursorPos(*self.anchor)
        module = kernel32.GetModuleHandleW(None)
        self._keyboard_proc = HOOKPROC(self._on_key)
        self._mouse_proc = HOOKPROC(self._on_mouse)
        self.hooks = [user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._keyboard_proc, module, 0),
                      user32.SetWindowsHookExW(WH_MOUSE_LL, self._mouse_proc, module, 0)]
        self.trackpad_mode = self.touchpad.problem is None
        self.bluetooth.start(trackpad=self.trackpad_mode)
        if self.trackpad_mode:
            self.mouse_fingers.start()
        # 3/4-finger gestures: ours instead of Windows', while our hint is in front
        self.previous_window = user32.GetForegroundWindow()
        if self.gestures:
            self.gestures.enabled = True
        self.touchpad.listening.set()
        self.hint.show("Connecting to the iPad…", "Ctrl+Alt+I to cancel", in_front=True)
        threading.Thread(target=self._give_up_if_not_connected, daemon=True).start()
        threading.Thread(target=self._stay_in_front, daemon=True).start()
        print("controlling the iPad")
        _tell(True)

    def _leave(self, reason=None):
        """Back to the laptop. Called from a hook or another thread."""
        if not self.active:
            return
        self.active = False
        self.bluetooth.send_keys(0, [])
        self.bluetooth.set_buttons(0)
        self.mouse_fingers.stop()
        self.bluetooth.send_touch({}, False)  # lift any fingers still down
        # what's still held went to the iPad: its releases are nobody's now
        self.swallow = set(self.ipad_held)
        self.ipad_held = {}
        user32.SetCursorPos(*self.pointer_home)
        user32.PostThreadMessageW(self.thread_id, WM_UNHOOK, 0, 0)
        # let the last key-up reach the iPad before Bluetooth goes
        self.stopping = threading.Timer(0.3, self.bluetooth.stop)
        self.stopping.start()
        self.touchpad.listening.clear()
        if self.gestures:
            self.gestures.enabled = False
        if reason:
            self.hint.show(reason, None, seconds=6)
        else:
            self.hint.hide()
        if self.previous_window:
            user32.SetForegroundWindow(self.previous_window)  # allowed: we're in front now
        print(f"back to the laptop{f': {reason}' if reason else ''}")
        _tell(False)

    def _unhook(self):
        if self.active:
            return  # switched again meanwhile
        for hook in self.hooks:
            if hook:
                user32.UnhookWindowsHookEx(hook)
        self.hooks = []

    def _give_up_if_not_connected(self):
        started = self.started
        while time.time() - started < CONNECT_TIMEOUT:
            time.sleep(0.25)
            if not self.active or self.started != started or self.bluetooth.connected:
                return
        # the iPad lists the laptop under its Windows computer name
        name = os.environ.get("COMPUTERNAME", "this laptop")
        self._leave(f"The iPad didn't connect. Is Bluetooth on, and “{name}” paired in its "
                    "Settings > Bluetooth?")

    def _stay_in_front(self):
        """Windows only hands gestures to the app in front; if something else
        took the front (a notification, a new window), take it back.
        In trackpad mode the still pointer also waits on the hint: two-finger
        scrolling isn't mouse input the hook can stop, Windows sends it to the
        window under the pointer, and the hint ignores it."""
        started = self.started
        parked = None
        while self.active and self.started == started:
            if self.hint.hwnd and user32.GetForegroundWindow() != self.hint.hwnd:
                bring_to_front(self.hint.hwnd)
            if self.trackpad_mode and self.hint.hwnd:
                rect = wintypes.RECT()
                if user32.GetWindowRect(ctypes.c_void_p(self.hint.hwnd), ctypes.byref(rect)) and rect.right > rect.left:
                    self._report_escape(parked)
                    parked = ((rect.left + rect.right) // 2, (rect.top + rect.bottom) // 2)
                    user32.SetCursorPos(*parked)
            time.sleep(0.25)

    def _report_escape(self, parked):
        """Diagnostics: the laptop pointer should stay where it was parked. If it
        moved, mouse input got past the hook: log it with how the hook was doing
        (how many events it saw, and the longest an event waited for it)."""
        calls, slowest = self.hook_calls, self.hook_slowest
        self.hook_calls = self.hook_slowest = 0
        if parked is None:
            return
        here = wintypes.POINT()
        user32.GetCursorPos(ctypes.byref(here))
        if (here.x, here.y) != parked:
            touched = time.time() - self.touch_seen < 0.5
            print(f"pointer escaped by ({here.x - parked[0]}, {here.y - parked[1]}): hook saw {calls} "
                  f"events, slowest waited {slowest} ms, touchpad {'in use' if touched else 'idle'}")

    def _on_fingers(self, touching, clicked):
        """Every touchpad report (touchpad thread): the fingers go to the iPad."""
        if touching or clicked:
            self.touch_seen = time.time()
        if self.active and self.trackpad_mode:
            self.bluetooth.send_touch(touching, clicked)

    # ---- hooks (run on the hotkey thread; must be quick) --------------------------

    def _on_key(self, code, message, data):
        if code < 0:
            return user32.CallNextHookEx(None, code, message, data)
        k = KBDLLHOOKSTRUCT.from_address(data)
        vk, up = k.vkCode, bool(k.flags & LLKHF_UP)
        if k.flags & LLKHF_INJECTED:
            return user32.CallNextHookEx(None, code, message, data)
        if up and vk in self.pc_held:
            self.pc_held.discard(vk)
            return user32.CallNextHookEx(None, code, message, data)
        if up and vk in self.swallow:
            self.swallow.discard(vk)
            return 1
        if not self.active:
            return user32.CallNextHookEx(None, code, message, data)
        if k.scanCode == ALTGR_FAKE_CTRL:
            return 1
        if not up and vk == VK_I and self._held(VK_LCONTROL, VK_RCONTROL) and self._held(VK_LMENU, VK_RMENU):
            self._leave()
            self.swallow.add(VK_I)
            return 1
        usage = SCAN_TO_HID.get((k.scanCode & 0xFF, bool(k.flags & LLKHF_EXTENDED)))
        if usage is None:
            return 1  # a key the iPad wouldn't understand: still not for the laptop
        if up:
            self.ipad_held.pop(vk, None)
        elif vk in self.ipad_held:
            return 1  # Windows' auto-repeat: the iPad repeats held keys itself
        else:
            self.ipad_held[vk] = usage
        modifiers = sum(1 << (u - 224) for u in self.ipad_held.values() if u >= 224)
        keys = [u for u in self.ipad_held.values() if u < 224]
        self.bluetooth.send_keys(modifiers, keys)
        return 1

    def _held(self, *vks):
        return any(vk in self.ipad_held or vk in self.pc_held for vk in vks)

    def _on_mouse(self, code, message, data):
        if code < 0 or not self.active:
            return user32.CallNextHookEx(None, code, message, data)
        m = MSLLHOOKSTRUCT.from_address(data)
        self.hook_calls += 1  # diagnostics, see _report_escape
        waited = (kernel32.GetTickCount() - m.time) & 0xFFFFFFFF
        if waited < 60_000:
            self.hook_slowest = max(self.hook_slowest, waited)
        if m.flags & LLMHF_INJECTED:
            return user32.CallNextHookEx(None, code, message, data)
        if self.trackpad_mode:
            # the pointer stays still; a plugged-in mouse goes to the iPad as fingers
            self._mouse_as_fingers(message, m)
            return 1
        if message == WM_MOUSEMOVE:
            # the pointer stays at the anchor, so this is how far it would have moved
            dx, dy = m.pt.x - self.anchor[0], m.pt.y - self.anchor[1]
            self.bluetooth.move(round(dx * POINTER_SCALE), round(dy * POINTER_SCALE))
        elif message in MOUSE_BUTTON_MESSAGES:
            bit, down = MOUSE_BUTTON_MESSAGES[message]
            self.buttons = self.buttons | bit if down else self.buttons & ~bit
            self.bluetooth.set_buttons(self.buttons)
        elif message in (WM_MOUSEWHEEL, WM_MOUSEHWHEEL):
            delta = ctypes.c_short(m.mouseData >> 16).value
            if message == WM_MOUSEWHEEL:
                self.wheel_rest += delta
                steps = int(self.wheel_rest / SCROLL_UNIT)
                self.wheel_rest -= steps * SCROLL_UNIT
                self.bluetooth.move(wheel=steps)
            else:
                self.pan_rest += delta
                steps = int(self.pan_rest / SCROLL_UNIT)
                self.pan_rest -= steps * SCROLL_UNIT
                self.bluetooth.move(pan=steps)
        return 1

    def _mouse_as_fingers(self, message, m):
        since_touch = time.time() - self.touch_seen
        if message == WM_MOUSEMOVE:
            if since_touch < TOUCHPAD_MOVE_GRACE:
                return
            here = wintypes.POINT()
            user32.GetCursorPos(ctypes.byref(here))
            dx, dy = m.pt.x - here.x, m.pt.y - here.y
            if dx or dy:
                self.mouse_fingers.move(dx, dy)
            return
        if since_touch < TOUCHPAD_CLICK_GRACE:
            return
        if message in MOUSE_BUTTON_MESSAGES:
            bit, down = MOUSE_BUTTON_MESSAGES[message]
            if bit in (1, 2):
                self.mouse_fingers.button("left" if bit == 1 else "right", down)
        elif message in (WM_MOUSEWHEEL, WM_MOUSEHWHEEL):
            delta = ctypes.c_short(m.mouseData >> 16).value
            self.mouse_fingers.wheel(delta, horizontal=message == WM_MOUSEHWHEEL)

    # ---- Bluetooth -----------------------------------------------------------------

    def _bluetooth_state(self, state, detail):
        if not self.active:
            return
        if state == "connected":
            self.hint.show("Keyboard and trackpad → iPad", "Ctrl+Alt+I to come back")
        elif state == "error":
            self._leave(f"Couldn't control the iPad: {detail}.")
        elif state == "waiting" and time.time() - self.started > 1:
            self.hint.show("The iPad disconnected. Reconnecting…", "Ctrl+Alt+I to come back")


def _gesture_controller():
    """Windows' TouchpadGesturesController, claiming 3/4/5-finger swipes and taps
    (disabled until switched over), or None on Windows versions without it.
    Must be made on a thread that dispatches window messages."""
    try:
        from winrt.windows.ui.input import TouchpadGesturesController, TouchpadGlobalGestureKinds
        if not TouchpadGesturesController.is_supported():
            raise OSError("not supported on this Windows")
        controller = TouchpadGesturesController.create_for_process()
        controller.supported_gestures = TouchpadGlobalGestureKinds(ALL_GLOBAL_GESTURES)
        controller.enabled = False
        return controller
    except Exception as e:  # older Windows 11 / Windows 10, missing library
        print(f"three/four-finger swipes will still go to Windows: {e!r}")
        return None


def bring_to_front(hwnd):
    """SetForegroundWindow, with the usual workaround for Windows refusing it to
    a process that isn't in front: briefly share input state with the one that is."""
    front = user32.GetForegroundWindow()
    if front == hwnd:
        return
    front_thread = user32.GetWindowThreadProcessId(front, None) if front else 0
    me = kernel32.GetCurrentThreadId()
    attached = front_thread and front_thread != me and user32.AttachThreadInput(me, front_thread, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    if attached:
        user32.AttachThreadInput(me, front_thread, False)


class Hint:
    """A small always-on-top note at the top of the screen, saying where the
    keyboard and trackpad go. Tk runs on its own thread; show/hide from any.
    With in_front it also takes the focus (see Controller._stay_in_front)."""

    def __init__(self):
        self.requests = queue.Queue()
        self.hwnd = None
        threading.Thread(target=self._run, name="hint", daemon=True).start()

    def show(self, title, subtitle, seconds=None, in_front=False):
        self.requests.put((title, subtitle, seconds, in_front))

    def hide(self):
        self.requests.put(None)

    def _run(self):
        root = tkinter.Tk()
        root.withdraw()
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.attributes("-alpha", 0.97)
        # Wingman's look (see osd.py): a graphite pill, white text, Windows 11 icons
        root.configure(bg=osd.GRAPHITE)
        row = tkinter.Frame(root, bg=osd.GRAPHITE)
        row.pack(padx=22, pady=12)
        tkinter.Label(row, text="", font=("Segoe Fluent Icons", 18), fg=osd.WHITE,  # keyboard
                      bg=osd.GRAPHITE).pack(side="left", padx=(0, 14))
        words = tkinter.Frame(row, bg=osd.GRAPHITE)
        words.pack(side="left")
        title = tkinter.Label(words, font=("Segoe UI Variable Display Semib", 12), fg=osd.WHITE,
                              bg=osd.GRAPHITE, anchor="w")
        subtitle = tkinter.Label(words, font=("Segoe UI Variable Text", 10), fg=osd.MUTED, bg=osd.GRAPHITE,
                                 anchor="w")
        title.pack(fill="x")
        subtitle.pack(fill="x")
        root.update_idletasks()
        self.hwnd = int(root.wm_frame(), 16)  # the real top-level window
        ctypes.WinDLL("dwmapi").DwmSetWindowAttribute(wintypes.HWND(self.hwnd), 33,  # round corners
                                                      ctypes.byref(ctypes.c_int(2)), 4)
        hide_at = [None]

        def poll():
            try:
                while True:
                    request = self.requests.get_nowait()
                    if request is None:
                        root.withdraw()
                        hide_at[0] = None
                        continue
                    text, small, seconds, in_front = request
                    title.config(text=text)
                    subtitle.config(text=small or "")
                    if small:
                        subtitle.pack(fill="x")
                    else:
                        subtitle.pack_forget()
                    root.update_idletasks()
                    x = (root.winfo_screenwidth() - root.winfo_reqwidth()) // 2
                    root.geometry(f"+{x}+24")
                    root.deiconify()
                    root.lift()
                    if in_front:
                        root.update_idletasks()
                        bring_to_front(self.hwnd)
                    hide_at[0] = time.time() + seconds if seconds else None
            except queue.Empty:
                pass
            if hide_at[0] and time.time() > hide_at[0]:
                root.withdraw()
                hide_at[0] = None
            root.after(100, poll)

        poll()
        root.mainloop()
