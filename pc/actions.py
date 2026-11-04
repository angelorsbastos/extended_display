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

SHORTCUTS_FILE = pathlib.Path(__file__).parent / "shortcuts.json"  # defaults, in git
USER_SHORTCUTS_FILE = pathlib.Path(__file__).parent / "shortcuts.user.json"  # edited on the iPad
MAX_SHORTCUTS = 60


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
    """The user's shortcuts (edited on the iPad), or the defaults until then."""
    path = USER_SHORTCUTS_FILE if USER_SHORTCUTS_FILE.exists() else SHORTCUTS_FILE
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_shortcuts(shortcuts):
    """Check the list the iPad sends and keep it (in USER_SHORTCUTS_FILE, so the
    defaults in git stay as they are). Returns the cleaned list; ValueError if bad."""
    if not isinstance(shortcuts, list) or len(shortcuts) > MAX_SHORTCUTS:
        raise ValueError("expected a list of at most 60 shortcuts")
    clean = [check_shortcut(s) for s in shortcuts]
    if len({s["id"] for s in clean}) != len(clean):
        raise ValueError("two shortcuts have the same id")
    temp = USER_SHORTCUTS_FILE.with_suffix(".tmp")
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(clean, f, indent=2, ensure_ascii=False)
    temp.replace(USER_SHORTCUTS_FILE)
    return clean


def check_shortcut(s):
    """One shortcut with only known fields and exactly one action; ValueError if not."""
    if not isinstance(s, dict):
        raise ValueError("a shortcut must be an object")
    clean = {}
    for field, limit in (("id", 64), ("title", 40), ("icon", 64)):
        value = s.get(field)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError(f"shortcut {field} missing or too long")
        clean[field] = value.strip()
    actions = [a for a in ("keys", "open", "run", "lock") if s.get(a)]
    if len(actions) != 1:
        raise ValueError(f"“{clean['title']}” needs exactly one action")
    action = actions[0]
    if action == "keys":
        keys = s["keys"]
        if not isinstance(keys, list) or not 1 <= len(keys) <= 5:
            raise ValueError(f"“{clean['title']}”: 1 to 5 keys")
        for key in keys:
            _vk(str(key))  # ValueError for an unknown key
        clean["keys"] = [str(k).lower() for k in keys]
    elif action in ("open", "run"):
        if not isinstance(s[action], str) or len(s[action]) > 1000:
            raise ValueError(f"“{clean['title']}”: bad {action}")
        clean[action] = s[action].strip()
    else:
        clean["lock"] = True
    return clean


def start_apps():
    """The apps in the Start menu, as [{name, open}] where open goes to
    run_shortcut's "open" (shell:AppsFolder\\<id> covers Store apps too)."""
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress"],
                         capture_output=True, text=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
    apps = json.loads(out.stdout or "[]")
    if isinstance(apps, dict):
        apps = [apps]
    seen, result = set(), []
    for app in sorted(apps, key=lambda a: a.get("Name", "").lower()):
        name = app.get("Name", "")
        if not name or name.lower() in seen or any(w in name.lower() for w in ("uninstall", "readme")):
            continue
        seen.add(name.lower())
        result.append({"name": name, "open": f"shell:AppsFolder\\{app['AppID']}"})
    return result


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
