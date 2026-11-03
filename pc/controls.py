"""Read and change laptop settings for the iPad's Controls screen.

state() returns everything the screen shows; apply(name, value) changes one thing.
All of it works without admin rights.
"""
import asyncio
import ctypes
import re
import subprocess
import threading
import winreg
from ctypes import POINTER, cast, wintypes

import comtypes
import screen_brightness_control as sbc
from comtypes import CLSCTX_ALL
from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
from winrt.windows.devices.radios import Radio, RadioKind, RadioState

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
powrprof = ctypes.windll.powrprof


# ---- sound ------------------------------------------------------------------------

def _com():
    """pycaw talks COM, which every thread must switch on for itself."""
    try:
        comtypes.CoInitialize()
    except OSError:
        pass  # already on in this thread


def _speakers():
    _com()
    return AudioUtilities.GetSpeakers().EndpointVolume


def _microphone():
    _com()
    mic = AudioUtilities.GetMicrophone()
    if mic is None:
        return None
    return cast(mic.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None),
                POINTER(IAudioEndpointVolume))


# ---- screen and theme -------------------------------------------------------------

THEME_KEY = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"


def _brightness():
    # "wmi" is the laptop's own panel; external monitors use a different method
    return sbc.get_brightness(method="wmi")[0]


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
    }


def apply(name, value=None):
    """Change one setting, or run a power action (lock, sleep, restart, shutdown)."""
    if name == "volume":
        _speakers().SetMasterVolumeLevelScalar(min(max(float(value), 0), 100) / 100, None)
    elif name == "muted":
        _speakers().SetMute(bool(value), None)
    elif name == "mic_muted":
        _microphone().SetMute(bool(value), None)
    elif name == "brightness":
        sbc.set_brightness(int(min(max(float(value), 0), 100)), method="wmi")
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
