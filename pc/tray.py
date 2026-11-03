"""Run the hub in the background with a tray icon (no terminal window).

This is what the "Extend Display" desktop / Start menu shortcut starts, using
pythonw.exe. Output goes to pc/hub.log. Quit from the tray icon's menu.
"""
import ctypes
import faulthandler
import os
import pathlib
import sys
import threading
import time

HERE = pathlib.Path(__file__).parent
LOG = HERE / "hub.log"

# pythonw has no console: send prints and errors to a log file instead
sys.stdout = sys.stderr = open(LOG, "a", encoding="utf-8", buffering=1)
print(f"\n--- started {time.strftime('%Y-%m-%d %H:%M:%S')} ---")
# if native code crashes the process, write every thread's Python stack to the
# log first; otherwise the hub just vanishes without a trace
faulthandler.enable(file=sys.stderr, all_threads=True)

import pystray  # noqa: E402
from PIL import Image  # noqa: E402

import hub  # noqa: E402

ICON = HERE / "assets" / "icon.png"
MUTEX_NAME = "ExtendDisplayHub"
ERROR_ALREADY_EXISTS = 183


def already_running():
    """True if another hub is running. Two would fight over the iPad."""
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW(None, False, MUTEX_NAME)  # kept until this process exits
    return kernel32.GetLastError() == ERROR_ALREADY_EXISTS


def main():
    if already_running():
        ctypes.windll.user32.MessageBoxW(
            None, "Extend Display is already running.\nLook for its icon next to the clock.",
            "Extend Display", 0x40)
        return

    stop = threading.Event()
    status = {"text": "Starting..."}

    def on_status(text):
        print(text)
        status["text"] = text
        icon.title = f"Extend Display: {text}"
        icon.update_menu()

    def quit_hub(icon, _item):
        stop.set()
        worker.join(timeout=8)  # lets the hub remove the virtual screen first
        icon.stop()

    icon = pystray.Icon(
        "ExtendDisplay", Image.open(ICON), "Extend Display",
        menu=pystray.Menu(
            pystray.MenuItem(lambda _item: status["text"], None, enabled=False),
            pystray.MenuItem("Open log", lambda: os.startfile(LOG)),
            pystray.MenuItem("Quit", quit_hub)))

    worker = threading.Thread(target=hub.run, args=(stop, on_status), daemon=True)
    worker.start()
    icon.run()


if __name__ == "__main__":
    main()
