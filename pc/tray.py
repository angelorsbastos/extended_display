"""Run the hub in the background with a tray icon (no terminal window).

This is what the "Wingman" desktop / Start menu shortcut starts, using
pythonw.exe, or Wingman.exe when installed. Output goes to hub.log (see
paths.py for where). Quit from the tray icon's menu.

Wingman.exe --send FILE ... is Explorer's "Send to > iPad (Wingman)" when
installed: it hands the files to the running hub (sendfile.py) and exits.
"""
import ctypes
import faulthandler
import os
import pathlib
import sys
import threading
import time

import paths  # noqa: E402

if sys.argv[1:2] == ["--send"]:
    import sendfile
    sendfile.main(sys.argv[2:])
    sys.exit()

LOG = paths.DATA / "hub.log"

# pythonw has no console: send prints and errors to a log file instead
sys.stdout = sys.stderr = open(LOG, "a", encoding="utf-8", buffering=1)
print(f"\n--- started {time.strftime('%Y-%m-%d %H:%M:%S')} ---")
# if native code crashes the process, write every thread's Python stack to the
# log first; otherwise the hub just vanishes without a trace
faulthandler.enable(file=sys.stderr, all_threads=True)

import pystray  # noqa: E402
from PIL import Image  # noqa: E402

import hub  # noqa: E402

ICON = paths.CODE / "assets" / "icon.png"
MUTEX_NAME = "WingmanHub"
ERROR_ALREADY_EXISTS = 183


def already_running():
    """True if another hub is running. Two would fight over the iPad."""
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW(None, False, MUTEX_NAME)  # kept until this process exits
    return kernel32.GetLastError() == ERROR_ALREADY_EXISTS


def main():
    if already_running():
        ctypes.windll.user32.MessageBoxW(
            None, "Wingman is already running.\nLook for its icon next to the clock.",
            "Wingman", 0x40)
        return

    stop = threading.Event()
    status = {"text": "Starting..."}

    def on_status(text):
        print(text)
        status["text"] = text
        icon.title = f"Wingman: {text}"[:127]  # Windows' limit for tooltips
        icon.update_menu()

    def quit_hub(icon, _item):
        stop.set()
        worker.join(timeout=8)  # lets the hub remove the virtual screen first
        icon.stop()

    def disconnect_action(key):
        return lambda: hub.disconnect(key)  # pystray calls actions with at most (icon, item)

    def device_items():
        """The menu, rebuilt each time it opens: the status, then each connected
        device (how it's connected, and a Disconnect), then Open log and Quit."""
        items = [pystray.MenuItem(lambda _item: status["text"], None, enabled=False),
                 pystray.Menu.SEPARATOR]
        devices = hub.connected_devices()
        if not devices:
            items.append(pystray.MenuItem("No iPad or iPhone connected", None, enabled=False))
        for key, name, device, transport in devices:
            how = {"usb": "cable", "wifi": "Wi-Fi", "remote": "Tailscale"}.get(transport, transport)
            kind = "iPhone" if device == "iphone" else "iPad"
            items.append(pystray.MenuItem(f"{name} ({kind}, {how})", pystray.Menu(
                pystray.MenuItem("Disconnect", disconnect_action(key)))))
        items += [pystray.Menu.SEPARATOR,
                  pystray.MenuItem("Open log", lambda: os.startfile(LOG)),
                  pystray.MenuItem("Quit", quit_hub)]
        return items

    icon = pystray.Icon("Wingman", Image.open(ICON), "Wingman", menu=pystray.Menu(device_items))

    worker = threading.Thread(target=hub.run, args=(stop, on_status), daemon=True)
    worker.start()
    icon.run()


if __name__ == "__main__":
    main()
