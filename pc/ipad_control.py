"""Ctrl+Alt+I: the laptop's keyboard and trackpad control the iPad, over
Bluetooth (see bluetooth_hid.py), until Ctrl+Alt+I is pressed again.

How: a registered hotkey switches over. While switched, low-level keyboard and
mouse hooks catch all input before Windows sees it, and forward it to the iPad
instead. The hooks exist only while switched, so they can never slow down the
laptop's own pointer. The pointer waits in the middle of the screen and its
movements are sent as mouse movement; keys are sent by position (HID usage),
so the iPad's keyboard layout setting decides the characters, like a real
keyboard.

Keys map like Extend Display does the other way round: Ctrl -> Cmd (so Ctrl+C
copies on the iPad), Alt -> Option, Win -> Ctrl, AltGr -> right Option.

Touchpad gestures that Windows itself handles (three/four-finger swipes) don't
pass through the hooks and still act on the laptop.
"""
import ctypes
import queue
import threading
import time
import tkinter
from ctypes import wintypes

import inputs
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

# (PC scan code, extended) -> HID usage: Extend Display's iPad -> PC table, reversed.
# The key left of Enter on ISO keyboards (Portuguese: ~ ^) is HID 50, not 49.
SCAN_TO_HID = {scan: usage for usage, scan in inputs.HID_TO_SCAN.items() if usage != 49}
ALTGR_FAKE_CTRL = 0x21D  # Windows' extra left-Ctrl that comes with every AltGr press

POINTER_SCALE = 1.0  # laptop pointer movement -> iPad pointer movement
SCROLL_UNIT = 40     # Windows wheel units per iPad scroll step (a mouse notch is 120)
CONNECT_TIMEOUT = 12  # seconds to wait for the iPad before giving up


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
        threading.Thread(target=self._run, name="ipad-control", daemon=True).start()

    # ---- hotkey thread -----------------------------------------------------------

    def _run(self):
        self.thread_id = kernel32.GetCurrentThreadId()
        if not user32.RegisterHotKey(None, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_I):
            print(f"Ctrl+Alt+I is taken by another app (error {ctypes.get_last_error()}); "
                  "controlling the iPad from the laptop is off")
            return
        print("Ctrl+Alt+I: the laptop's keyboard and trackpad control the iPad")
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_HOTKEY:
                self._enter()
            elif msg.message == WM_UNHOOK:
                self._unhook()

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
        self.bluetooth.start()
        self.hint.show("Connecting to the iPad…", "Ctrl+Alt+I to cancel")
        threading.Thread(target=self._give_up_if_not_connected, daemon=True).start()
        print("controlling the iPad")

    def _leave(self, reason=None):
        """Back to the laptop. Called from a hook or another thread."""
        if not self.active:
            return
        self.active = False
        self.bluetooth.send_keys(0, [])
        self.bluetooth.set_buttons(0)
        # what's still held went to the iPad: its releases are nobody's now
        self.swallow = set(self.ipad_held)
        self.ipad_held = {}
        user32.SetCursorPos(*self.pointer_home)
        user32.PostThreadMessageW(self.thread_id, WM_UNHOOK, 0, 0)
        # let the last key-up reach the iPad before Bluetooth goes
        self.stopping = threading.Timer(0.3, self.bluetooth.stop)
        self.stopping.start()
        if reason:
            self.hint.show(reason, None, seconds=6)
        else:
            self.hint.hide()
        print(f"back to the laptop{f': {reason}' if reason else ''}")

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
        self._leave("The iPad didn't connect. Is Bluetooth on, and “LAPRÉ” paired in its "
                    "Settings > Bluetooth?")

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
        if m.flags & LLMHF_INJECTED:
            return user32.CallNextHookEx(None, code, message, data)
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


class Hint:
    """A small always-on-top note at the top of the screen, saying where the
    keyboard and trackpad go. Tk runs on its own thread; show/hide from any."""

    def __init__(self):
        self.requests = queue.Queue()
        threading.Thread(target=self._run, name="hint", daemon=True).start()

    def show(self, title, subtitle, seconds=None):
        self.requests.put((title, subtitle, seconds))

    def hide(self):
        self.requests.put(None)

    def _run(self):
        root = tkinter.Tk()
        root.withdraw()
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.attributes("-alpha", 0.92)
        root.configure(bg="#1c1c1e")
        title = tkinter.Label(root, font=("Segoe UI Semibold", 13), fg="white", bg="#1c1c1e")
        subtitle = tkinter.Label(root, font=("Segoe UI", 10), fg="#a0a0a5", bg="#1c1c1e")
        title.pack(padx=22, pady=(10, 0))
        subtitle.pack(padx=22, pady=(0, 10))
        hide_at = [None]

        def poll():
            try:
                while True:
                    request = self.requests.get_nowait()
                    if request is None:
                        root.withdraw()
                        hide_at[0] = None
                        continue
                    text, small, seconds = request
                    title.config(text=text)
                    subtitle.config(text=small or "")
                    if small:
                        subtitle.pack(padx=22, pady=(0, 10))
                    else:
                        subtitle.pack_forget()
                    root.update_idletasks()
                    x = (root.winfo_screenwidth() - root.winfo_reqwidth()) // 2
                    root.geometry(f"+{x}+24")
                    root.deiconify()
                    root.lift()
                    hide_at[0] = time.time() + seconds if seconds else None
            except queue.Empty:
                pass
            if hide_at[0] and time.time() > hide_at[0]:
                root.withdraw()
                hide_at[0] = None
            root.after(100, poll)

        poll()
        root.mainloop()
