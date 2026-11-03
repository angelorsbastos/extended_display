"""Remember where the user put the Extend screen, separately for each setup
(e.g. "laptop + external monitor" vs "laptop only"), in extend_layout.json."""
import json
import pathlib

import monitors

LAYOUT_FILE = pathlib.Path(__file__).parent / "extend_layout.json"


def setup_key(exclude=None):
    """Identifies the current setup: the other screens' names and sizes."""
    # names look like \\.\DISPLAY1; the key reads e.g. "DISPLAY1 1920x1200 + DISPLAY2 1920x1080"
    return " + ".join(sorted(f"{m['name'].lstrip('\\.')} {m['width']}x{m['height']}"
                             for m in monitors.list_monitors() if m["name"] != exclude))


def _load():
    try:
        return json.loads(LAYOUT_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def saved_position(key):
    """(x, y) of the Extend screen last time in this setup, or None."""
    pos = _load().get(key)
    return tuple(pos) if pos else None


def save_position(key, screen_name):
    """Record where the screen `screen_name` currently is, for setup `key`."""
    screen = next((m for m in monitors.list_monitors() if m["name"] == screen_name), None)
    if not screen:
        return
    layouts = _load()
    layouts[key] = [screen["left"], screen["top"]]
    LAYOUT_FILE.write_text(json.dumps(layouts, indent=2), encoding="utf-8")
