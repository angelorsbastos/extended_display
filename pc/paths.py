"""Where Wingman's files are.

Run from the project (python / pythonw), everything sits in pc/ as always.
Installed (Wingman.exe, built by PyInstaller), the program's own files are
read-only in the install folder, so what Wingman writes (the log, pairing keys,
shortcuts edited on the device, where the Extend screen goes) lives in
%APPDATA%\\Wingman instead.
"""
import os
import pathlib
import sys

FROZEN = getattr(sys, "frozen", False)

# files that ship with Wingman: icons, the default shortcuts
CODE = pathlib.Path(getattr(sys, "_MEIPASS", pathlib.Path(__file__).parent))

# files Wingman writes
DATA = (pathlib.Path(os.environ.get("APPDATA") or pathlib.Path.home()) / "Wingman") if FROZEN \
    else pathlib.Path(__file__).parent
DATA.mkdir(parents=True, exist_ok=True)
