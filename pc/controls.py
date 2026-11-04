"""Read and change laptop settings for the iPad's Controls screen.

state() returns everything the screen shows; apply(name, value) changes one thing.
All of it works without admin rights.

Crash safety: audio goes through COM, and freeing COM objects at the wrong time
crashes the whole process (see _endpoint_volume). COM runs in multi-thread mode
and all the work happens on one dedicated thread, so objects are never used or
released concurrently. Brightness deliberately avoids WMI (see _brightness).
"""
import sys

# must be set before comtypes / pythoncom are first imported anywhere
sys.coinit_flags = 0  # COINIT_MULTITHREADED

import asyncio  # noqa: E402
import ctypes  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import winreg  # noqa: E402
from concurrent.futures import ThreadPoolExecutor  # noqa: E402
from ctypes import wintypes  # noqa: E402

import comtypes  # noqa: E402
from comtypes import CLSCTX_ALL  # noqa: E402
from pycaw.constants import CLSID_MMDeviceEnumerator  # noqa: E402
from pycaw.pycaw import IAudioEndpointVolume, IMMDeviceEnumerator  # noqa: E402
from winrt.windows.devices.radios import Radio, RadioKind, RadioState  # noqa: E402

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
powrprof = ctypes.windll.powrprof
COINIT_MULTITHREADED = 0x0


def _start_com():
    comtypes.CoInitializeEx(COINIT_MULTITHREADED)


# every state() / apply() runs here, one at a time
_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="controls",
                             initializer=_start_com)


# ---- sound ------------------------------------------------------------------------

E_RENDER, E_CAPTURE, E_CONSOLE = 0, 1, 0


def _endpoint_volume(flow):
    enumerator = comtypes.CoCreateInstance(CLSID_MMDeviceEnumerator, IMMDeviceEnumerator,
                                           CLSCTX_ALL)
    device = enumerator.GetDefaultAudioEndpoint(flow, E_CONSOLE)  # COMError if none
    # QueryInterface, NOT ctypes.cast (pycaw's usual example): cast makes a second
    # pointer without AddRef, so the object gets Released twice and the garbage
    # collector later crashes the whole hub with an access violation.
    return device.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None).QueryInterface(
        IAudioEndpointVolume)


def _speakers():
    return _endpoint_volume(E_RENDER)


def _microphone():
    return _endpoint_volume(E_CAPTURE)


def speaker_level_db():
    """The speakers' volume in dB (0 at 100%, negative below), or None if unknown.
    audio.py uses it to undo the volume in what it captures."""
    return _worker.submit(_safe, _speaker_db).result()


def _speaker_db():
    return _speakers().GetMasterVolumeLevel()


# ---- screen and theme -------------------------------------------------------------

THEME_KEY = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"


# The laptop's own panel, through the \\.\LCD device. (Not WMI: the WMI library
# uses pywin32, whose COM handling crashed the hub when mixed with pycaw's.)
IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS = 0x230498
IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS = 0x23049C
DISPLAYPOLICY_BOTH = 3  # same level on charger and on battery
kernel32.CreateFileW.restype = wintypes.HANDLE


class DISPLAY_BRIGHTNESS(ctypes.Structure):
    _fields_ = [("ucDisplayPolicy", ctypes.c_ubyte), ("ucACBrightness", ctypes.c_ubyte),
                ("ucDCBrightness", ctypes.c_ubyte)]


def _lcd_ioctl(code, in_buf=None, out_buf=None):
    handle = kernel32.CreateFileW("\\\\.\\LCD", 0xC0000000, 0x3, None, 3, 0, None)  # read/write, shared, open existing
    if handle in (None, wintypes.HANDLE(-1).value):
        raise ctypes.WinError()
    try:
        done = wintypes.DWORD()
        ok = kernel32.DeviceIoControl(
            handle, code,
            ctypes.byref(in_buf) if in_buf else None, ctypes.sizeof(in_buf) if in_buf else 0,
            ctypes.byref(out_buf) if out_buf else None, ctypes.sizeof(out_buf) if out_buf else 0,
            ctypes.byref(done), None)
        if not ok:
            raise ctypes.WinError()
    finally:
        kernel32.CloseHandle(handle)


def _brightness():
    current = DISPLAY_BRIGHTNESS()
    _lcd_ioctl(IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS, out_buf=current)
    on_charger = SYSTEM_POWER_STATUS()
    kernel32.GetSystemPowerStatus(ctypes.byref(on_charger))
    return current.ucACBrightness if on_charger.ACLineStatus == 1 else current.ucDCBrightness


def _set_brightness(level):
    level = int(min(max(float(level), 0), 100))
    _lcd_ioctl(IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS,
               in_buf=DISPLAY_BRIGHTNESS(DISPLAYPOLICY_BOTH, level, level))


def _dark_mode():
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, THEME_KEY) as key:
        return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0


def _set_dark_mode(dark):
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, THEME_KEY, 0, winreg.KEY_SET_VALUE) as key:
        for name in ("AppsUseLightTheme", "SystemUsesLightTheme"):
            winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, 0 if dark else 1)
    # tell open windows the theme changed, so they switch without a restart
    user32.SendMessageTimeoutW(0xFFFF, 0x1A, 0, "ImmersiveColorSet", 0x2, 5000, None)


# ---- Wi-Fi and Bluetooth (Windows.Devices.Radios) ---------------------------------

RADIO_KINDS = {"wifi": RadioKind.WI_FI, "bluetooth": RadioKind.BLUETOOTH}


async def _radios():
    await Radio.request_access_async()
    return list(await Radio.get_radios_async())


def _radio_states():
    """{"wifi": True/False/None, "bluetooth": ...}; None when there is no such radio."""
    radios = asyncio.run(_radios())
    return {name: next((r.state == RadioState.ON for r in radios if r.kind == kind), None)
            for name, kind in RADIO_KINDS.items()}


def _set_radio(name, on):
    async def go():
        for radio in await _radios():
            if radio.kind == RADIO_KINDS[name]:
                await radio.set_state_async(RadioState.ON if on else RadioState.OFF)
    asyncio.run(go())


# ---- battery, keep awake, power mode, power buttons ------------------------------

class SYSTEM_POWER_STATUS(ctypes.Structure):
    _fields_ = [("ACLineStatus", ctypes.c_ubyte), ("BatteryFlag", ctypes.c_ubyte),
                ("BatteryLifePercent", ctypes.c_ubyte), ("SystemStatusFlag", ctypes.c_ubyte),
                ("BatteryLifeTime", wintypes.DWORD), ("BatteryFullLifeTime", wintypes.DWORD)]


def _battery():
    status = SYSTEM_POWER_STATUS()
    kernel32.GetSystemPowerStatus(ctypes.byref(status))
    percent = status.BatteryLifePercent
    return {"percent": None if percent == 255 else percent,
            "charging": status.ACLineStatus == 1}


class _KeepAwake:
    """Stops the laptop from sleeping or turning its screen off while on.
    Windows ties this to the thread that asks, so it gets a thread of its own."""

    ES_CONTINUOUS, ES_SYSTEM_REQUIRED, ES_DISPLAY_REQUIRED = 0x80000000, 0x1, 0x2

    def __init__(self):
        self.on = threading.Event()
        self.off = threading.Event()

    def set(self, on):
        if on and not self.on.is_set():
            self.on.set()
            self.off.clear()
            threading.Thread(target=self._hold, daemon=True).start()
        elif not on:
            self.on.clear()
            self.off.set()

    def _hold(self):
        kernel32.SetThreadExecutionState(
            self.ES_CONTINUOUS | self.ES_SYSTEM_REQUIRED | self.ES_DISPLAY_REQUIRED)
        self.off.wait()
        kernel32.SetThreadExecutionState(self.ES_CONTINUOUS)


keep_awake = _KeepAwake()


# The hub runs without a console (pythonw), so command-line tools must not open one
NO_WINDOW = subprocess.CREATE_NO_WINDOW


def _power_plans():
    """Windows power plans (on this ROG: Silent / Turbo / ... from Armoury Crate).
    Plans rather than Settings' "power mode" slider, because Windows ignores that
    slider whenever a custom plan like ASUS's is active.
    Returns ([{"id", "name"}], id of the active plan)."""
    out = subprocess.run(["powercfg", "/list"], capture_output=True, text=True,
                         creationflags=NO_WINDOW).stdout
    plans, active = [], None
    for guid, name, star in re.findall(r"([0-9a-f]{8}-[0-9a-f-]{27})\s+\((.*?)\)(\s*\*)?", out):
        plans.append({"id": guid, "name": name})
        if star:
            active = guid
    return plans, active


def _set_power_plan(plan_id):
    # only check it looks like a plan id: Armoury Crate rewrites the plan list for a
    # moment after each switch, so a real plan can be briefly missing from it.
    # powercfg itself refuses ids that don't exist.
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", str(plan_id)):
        raise ValueError(f"not a power plan id: {plan_id!r}")
    subprocess.run(["powercfg", "/setactive", plan_id], creationflags=NO_WINDOW, check=True)


POWER_ACTIONS = {
    "lock": lambda: user32.LockWorkStation(),
    "sleep": lambda: powrprof.SetSuspendState(False, False, False),
    "restart": lambda: subprocess.Popen(["shutdown", "/r", "/t", "0"], creationflags=NO_WINDOW),
    "shutdown": lambda: subprocess.Popen(["shutdown", "/s", "/t", "0"], creationflags=NO_WINDOW),
}


# ---- the two functions the hub uses -----------------------------------------------

def _safe(read, default=None):
    """One unreadable setting (e.g. no microphone) shouldn't hide all the others."""
    try:
        return read()
    except Exception as e:  # each library raises its own kinds of errors
        print(f"controls: could not read {read.__name__}: {e}")
        return default


def state():
    """Everything the Controls screen shows (runs on the controls thread)."""
    return _worker.submit(_state).result()


def apply(name, value=None):
    """Change one setting, or run a power action (lock, sleep, restart, shutdown).
    Runs on the controls thread; errors are raised here in the caller."""
    return _worker.submit(_apply, name, value).result()


def _state():
    speakers = _safe(_speakers)
    mic = _safe(_microphone)
    radios = _safe(_radio_states, {})
    plans, active_plan = _safe(_power_plans, ([], None))
    return {
        "volume": round(speakers.GetMasterVolumeLevelScalar() * 100) if speakers else None,
        "muted": bool(speakers.GetMute()) if speakers else None,
        "mic_muted": bool(mic.GetMute()) if mic else None,
        "brightness": _safe(_brightness),
        "dark_mode": _safe(_dark_mode),
        "wifi": radios.get("wifi"),
        "bluetooth": radios.get("bluetooth"),
        "battery": _safe(_battery),
        "keep_awake": keep_awake.on.is_set(),
        "power_plans": plans,
        "power_plan": active_plan,
        "cpu_temp": _safe(_cpu_temp),
    }


def _cpu_temp():
    """°C from the ASUS ACPI driver: cheap, unlike the GPU (stats.py)."""
    import stats  # here: stats imports this module
    return stats._asus()[0]


def _apply(name, value):
    if name == "volume":
        _speakers().SetMasterVolumeLevelScalar(min(max(float(value), 0), 100) / 100, None)
    elif name == "muted":
        _speakers().SetMute(bool(value), None)
    elif name == "mic_muted":
        _microphone().SetMute(bool(value), None)
    elif name == "brightness":
        _set_brightness(value)
    elif name == "dark_mode":
        _set_dark_mode(bool(value))
    elif name in RADIO_KINDS:
        _set_radio(name, bool(value))
    elif name == "keep_awake":
        keep_awake.set(bool(value))
    elif name == "power_plan":
        _set_power_plan(value)
    elif name in POWER_ACTIONS:
        POWER_ACTIONS[name]()
    else:
        raise ValueError(f"unknown control {name!r}")
