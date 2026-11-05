# PyInstaller recipe for Wingman.exe: the laptop hub with Python and every
# library inside, so it runs without installing Python.
#
#   .venv\Scripts\python.exe -m PyInstaller packaging\wingman.spec --noconfirm
#
# Output: dist\Wingman\Wingman.exe (a folder build: starts faster than a
# one-file exe and upsets antivirus programs less). packaging\wingman.iss
# turns that folder into the installer.
from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules

ROOT = SPECPATH + "\\.."
PC = ROOT + "\\pc"

datas = [
    (PC + "\\assets\\icon.png", "assets"),
    (PC + "\\assets\\icon.ico", "assets"),
    (PC + "\\shortcuts.json", "."),
]
binaries = []
hiddenimports = ["pystray._win32"]

# Windows Runtime bindings (Bluetooth, media, input...): namespace packages
# PyInstaller can't follow on its own
for package in ["winrt", "windows_capture", "soundcard", "pycaw", "comtypes", "zeroconf"]:
    d, b, h = collect_all(package)
    datas += d
    binaries += b
    hiddenimports += h
hiddenimports += collect_submodules("winrt")
datas += collect_data_files("soundcard")  # its C declarations (*.h), read at run time

a = Analysis(
    [PC + "\\tray.py"],
    pathex=[PC],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["matplotlib", "pytest", "IPython"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Wingman",
    icon=PC + "\\assets\\icon.ico",
    console=False,  # like pythonw: no terminal window; output goes to hub.log
    version=None,
)
coll = COLLECT(exe, a.binaries, a.datas, name="Wingman")
