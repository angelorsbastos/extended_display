"""A small note on the laptop's screen whenever a device changes something on
it (volume, Wi-Fi, a shortcut, a file arriving...), like Windows' own volume
indicator. Wingman's look: a graphite pill, white icon and text, and a white
level bar for volume and brightness.

It never takes the focus or catches clicks (no-activate, click-through), so it
can't interrupt what's being typed on the laptop: it stays on screen invisible
and fades in and out instead of being shown and hidden. show() works from any
thread; Tk runs on its own.
"""
import ctypes
import queue
import threading
import time
import tkinter
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
dwmapi = ctypes.WinDLL("dwmapi")
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_long]

# Segoe Fluent Icons (Windows 11's icon font)
ICONS = {
    "volume": "", "mute": "", "brightness": "", "wifi": "",
    "bluetooth": "", "mic": "", "mic_off": "", "dark": "",
    "awake": "", "plan": "", "lock": "", "play": "", "pause": "",
    "next": "", "previous": "", "shortcut": "", "file": "",
    "paste": "", "speaker": "", "tablet": "", "power": "",
}
GRAPHITE, WHITE, MUTED, TRACK = "#1e1f24", "#f3f3f5", "#9a9ca5", "#3a3c44"
SHOW_SECONDS = 1.6
FADE_STEPS = 6

_requests = queue.Queue()
_started = threading.Lock()
_thread = None


def show(icon, text, level=None):
    """icon: a key of ICONS; level: 0-100 for a bar, or None."""
    global _thread
    with _started:
        if _thread is None:
            _thread = threading.Thread(target=_run, name="osd", daemon=True)
            _thread.start()
    _requests.put((ICONS.get(icon, ICONS["shortcut"]), str(text)[:60], level))


def _run():
    root = tkinter.Tk()
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-alpha", 0.0)
    root.configure(bg=GRAPHITE)
    frame = tkinter.Frame(root, bg=GRAPHITE)
    frame.pack(padx=20, pady=12)
    icon = tkinter.Label(frame, font=("Segoe Fluent Icons", 15), fg=WHITE, bg=GRAPHITE)
    icon.pack(side="left", padx=(0, 12))
    text = tkinter.Label(frame, font=("Segoe UI Variable Text", 11), fg=WHITE, bg=GRAPHITE)
    text.pack(side="left")
    bar = tkinter.Canvas(frame, width=140, height=6, bg=GRAPHITE, highlightthickness=0)
    percent = tkinter.Label(frame, font=("Segoe UI Variable Text", 10), fg=MUTED, bg=GRAPHITE, width=4,
                            anchor="e")
    root.update_idletasks()
    hwnd = int(root.wm_frame(), 16)
    # no focus, no taskbar button, clicks go through; Windows 11 rounds the corners
    GWL_EXSTYLE, NOACTIVATE, TOOLWINDOW, TRANSPARENT, LAYERED = -20, 0x08000000, 0x80, 0x20, 0x80000
    style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | NOACTIVATE | TOOLWINDOW | TRANSPARENT | LAYERED)
    dwmapi.DwmSetWindowAttribute(wintypes.HWND(hwnd), 33, ctypes.byref(ctypes.c_int(2)), 4)  # round corners
    state = {"until": 0.0, "alpha": 0.0}

    def place():
        work = wintypes.RECT()
        user32.SystemParametersInfoW(0x30, 0, ctypes.byref(work), 0)  # SPI_GETWORKAREA: above the taskbar
        root.update_idletasks()
        w, h = root.winfo_reqwidth(), root.winfo_reqheight()
        root.geometry(f"+{(work.left + work.right - w) // 2}+{work.bottom - h - 36}")

    def poll():
        try:
            while True:
                glyph, words, level = _requests.get_nowait()
                icon.config(text=glyph)
                text.config(text=words)
                if level is None:
                    bar.pack_forget()
                    percent.pack_forget()
                else:
                    level = max(0, min(100, int(level)))
                    bar.pack(side="left", padx=(14, 6))
                    percent.pack(side="left")
                    bar.delete("all")
                    bar.create_line(3, 3, 137, 3, fill=TRACK, width=6, capstyle="round")
                    if level:
                        bar.create_line(3, 3, 3 + 134 * level / 100, 3, fill=WHITE, width=6, capstyle="round")
                    percent.config(text=f"{level}%")
                place()
                state["until"] = time.time() + SHOW_SECONDS
        except queue.Empty:
            pass
        target = 0.96 if time.time() < state["until"] else 0.0
        if state["alpha"] != target:  # fade in fast, out a bit slower
            step = 0.96 / (3 if target else FADE_STEPS)
            state["alpha"] = min(target, state["alpha"] + step) if target else max(0.0, state["alpha"] - step)
            root.attributes("-alpha", state["alpha"])
        root.after(30, poll)

    poll()
    root.mainloop()
