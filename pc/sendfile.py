"""Explorer's right-click "Send to > iPad (Extend Display)" runs this with the
selected files as arguments. It hands them to the running hub (files.py, the
outbox), which sends them to the iPad. Problems are shown in a message box,
since there's no window otherwise.

Usage: pythonw sendfile.py FILE [FILE ...]
"""
import ctypes
import json
import socket
import sys

from files import OUTBOX_PORT

MB_ICONWARNING = 0x30


def main():
    paths = sys.argv[1:]
    if not paths:
        return
    try:
        with socket.create_connection(("127.0.0.1", OUTBOX_PORT), timeout=5) as conn:
            conn.sendall(json.dumps({"paths": paths}).encode() + b"\n")
            reply = json.loads(conn.makefile("rb").readline())
    except ConnectionRefusedError:
        reply = {"error": "Extend Display isn't running on this laptop. Start it from the desktop icon first."}
    except (OSError, ValueError) as e:
        reply = {"error": f"Couldn't reach Extend Display: {e}"}
    if "error" in reply:
        ctypes.windll.user32.MessageBoxW(None, reply["error"], "Send to iPad", MB_ICONWARNING)


if __name__ == "__main__":
    main()
