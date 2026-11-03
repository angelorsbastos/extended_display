"""Things the iPad can make the laptop do: press keys, open apps, control media."""
import ctypes
import json
import os
import pathlib
import subprocess

user32 = ctypes.windll.user32
KEYEVENTF_KEYUP = 0x2

KEYS = {"win": 0x5B, "ctrl": 0x11, "shift": 0x10, "alt": 0x12, "tab": 0x09, "esc": 0x1B,
        "enter": 0x0D, "space": 0x20, "printscreen": 0x2C, "delete": 0x2E,
        "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
        **{f"f{n}": 0x6F + n for n in range(1, 13)}}

MEDIA_KEYS = {"play_pause": 0xB3, "next": 0xB0, "previous": 0xB1,
              "volume_up": 0xAF, "volume_down": 0xAE, "mute": 0xAD}

SHORTCUTS_FILE = pathlib.Path(__file__).parent / "shortcuts.json"


def _vk(name):
    name = name.lower()
    if name in KEYS:
        return KEYS[name]
    if len(name) == 1 and name.isalnum():
        return ord(name.upper())
    raise ValueError(f"unknown key {name!r}")


def press(*names):
    """Press a key combination, e.g. press('win', 'shift', 's')."""
    codes = [_vk(n) for n in names]
    for code in codes:
        user32.keybd_event(code, 0, 0, 0)
    for code in reversed(codes):
        user32.keybd_event(code, 0, KEYEVENTF_KEYUP, 0)


def load_shortcuts():
    with open(SHORTCUTS_FILE, encoding="utf-8") as f:
        return json.load(f)


def run_shortcut(shortcut):
    """Run one entry of shortcuts.json. Each entry has exactly one of:
    keys (a combination), open (a file, folder or URI), run (a shell command), lock."""
    if "keys" in shortcut:
        press(*shortcut["keys"])
    elif "open" in shortcut:
        os.startfile(shortcut["open"])
    elif "run" in shortcut:
        subprocess.Popen(shortcut["run"], shell=True)
    elif shortcut.get("lock"):
        user32.LockWorkStation()  # Win+L can't be sent as fake key presses


def media(action):
    code = MEDIA_KEYS[action]
    user32.keybd_event(code, 0, 0, 0)
    user32.keybd_event(code, 0, KEYEVENTF_KEYUP, 0)
