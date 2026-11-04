"""Live numbers for the iPad's Dashboard: temperatures, fans, usage, battery health.

All of it works without admin rights:
- CPU temperature and fan speeds: the ASUS ACPI driver (\\\\.\\ATKACPI), the
  way open-source ROG tools like G-Helper read them
- GPU: nvidia-smi (comes with the NVIDIA driver). Asking it wakes a sleeping
  GPU, which costs battery, so the hub only reads while the Dashboard is open.
- CPU usage and memory: GetSystemTimes / GlobalMemoryStatusEx
- battery health: Windows' battery report (powercfg), read at most every 10 min

read() returns a dict; anything unavailable is None.
"""
import csv
import ctypes
import shutil
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from ctypes import wintypes

import controls

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateFileW.restype = wintypes.HANDLE

ATK_CONTROL = 0x0022240C
ATK_DSTS = 0x53545344  # "DSTS": read a device's status
ATK_CPU_FAN, ATK_GPU_FAN, ATK_CPU_TEMP = 0x00110013, 0x00110014, 0x00120094
NO_WINDOW = 0x08000000
BATTERY_EVERY = 600  # seconds

_lock = threading.Lock()
_last_times = None
_battery = {"time": 0.0, "value": None}


def read():
    with _lock:
        cpu_temp, cpu_fan, gpu_fan = _asus()
        return {
            "cpu": {"temp": cpu_temp, "usage": _cpu_usage(), "fan": cpu_fan},
            "gpu": {**_nvidia(), "fan": gpu_fan},
            "memory": _memory(),
            "battery": _battery_health(),
            "power_plan": _power_plan_name(),
        }


def _power_plan_name():
    """The active power plan's name (on this ROG: Silent / Performance / Turbo ...)."""
    try:
        plans, active = controls._power_plans()
    except OSError:
        return None
    return next((p["name"] for p in plans if p["id"] == active), None)


# ---- ASUS ACPI ---------------------------------------------------------------------

def _asus():
    """(CPU temperature °C, CPU fan RPM, GPU fan RPM)."""
    handle = kernel32.CreateFileW(r"\\.\ATKACPI", 0xC0000000, 3, None, 3, 0, None)
    if handle in (None, wintypes.HANDLE(-1).value):
        return None, None, None
    try:
        temp = _dsts(handle, ATK_CPU_TEMP)
        fans = [_dsts(handle, ATK_CPU_FAN), _dsts(handle, ATK_GPU_FAN)]
        # the high word says "present"; fans report hundreds of RPM
        return (temp if temp and 0 < temp < 120 else None,
                *[(f * 100 if f is not None and f < 200 else None) for f in fans])
    finally:
        kernel32.CloseHandle(wintypes.HANDLE(handle))


def _dsts(handle, device):
    args = (ctypes.c_uint32 * 4)(ATK_DSTS, 8, device, 0)
    out = (ctypes.c_uint32 * 4)()
    returned = wintypes.DWORD()
    if not kernel32.DeviceIoControl(wintypes.HANDLE(handle), ATK_CONTROL, args, 16, out, 16,
                                    ctypes.byref(returned), None):
        return None
    return out[0] & 0xFFFF if out[0] >> 16 else None


# ---- NVIDIA ------------------------------------------------------------------------

FIELDS = ["name", "temperature.gpu", "utilization.gpu", "power.draw", "clocks.gr",
          "memory.used", "memory.total"]


def _nvidia():
    smi = shutil.which("nvidia-smi") or r"C:\Windows\System32\nvidia-smi.exe"
    try:
        out = subprocess.run([smi, f"--query-gpu={','.join(FIELDS)}", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5, creationflags=NO_WINDOW)
        row = next(csv.reader([out.stdout.strip()]))
    except (OSError, subprocess.TimeoutExpired, StopIteration):
        return {"name": None, "temp": None, "usage": None, "power": None, "clock": None,
                "memory_used": None, "memory_total": None}
    values = dict(zip(FIELDS, (v.strip() for v in row)))

    def number(field):
        try:
            return round(float(values.get(field, "")), 1)
        except ValueError:
            return None  # "[N/A]"
    return {"name": values.get("name"), "temp": number("temperature.gpu"), "usage": number("utilization.gpu"),
            "power": number("power.draw"), "clock": number("clocks.gr"),
            "memory_used": number("memory.used"), "memory_total": number("memory.total")}


# ---- CPU and memory ----------------------------------------------------------------

def _cpu_usage():
    """% since the previous call (None the first time)."""
    global _last_times
    idle, kernel, user = wintypes.FILETIME(), wintypes.FILETIME(), wintypes.FILETIME()
    kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user))
    now = [t.dwHighDateTime << 32 | t.dwLowDateTime for t in (idle, kernel, user)]
    previous, _last_times = _last_times, now
    if previous is None:
        return None
    idle_d, busy_d = now[0] - previous[0], (now[1] - previous[1]) + (now[2] - previous[2])
    return round(100 * (busy_d - idle_d) / busy_d, 1) if busy_d else None


class MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
                ("ullTotalPhys", ctypes.c_uint64), ("ullAvailPhys", ctypes.c_uint64),
                ("ullTotalPageFile", ctypes.c_uint64), ("ullAvailPageFile", ctypes.c_uint64),
                ("ullTotalVirtual", ctypes.c_uint64), ("ullAvailVirtual", ctypes.c_uint64),
                ("ullAvailExtendedVirtual", ctypes.c_uint64)]


def _memory():
    m = MEMORYSTATUSEX(dwLength=ctypes.sizeof(MEMORYSTATUSEX))
    if not kernel32.GlobalMemoryStatusEx(ctypes.byref(m)):
        return {"used": None, "total": None}
    gib = 1024 ** 3
    return {"used": round((m.ullTotalPhys - m.ullAvailPhys) / gib, 1), "total": round(m.ullTotalPhys / gib, 1)}


# ---- battery health ----------------------------------------------------------------

class SYSTEM_POWER_STATUS(ctypes.Structure):
    _fields_ = [("ACLineStatus", ctypes.c_ubyte), ("BatteryFlag", ctypes.c_ubyte),
                ("BatteryLifePercent", ctypes.c_ubyte), ("SystemStatusFlag", ctypes.c_ubyte),
                ("BatteryLifeTime", wintypes.DWORD), ("BatteryFullLifeTime", wintypes.DWORD)]


def _battery_health():
    """Health (from the battery report, cached) plus the charge right now."""
    status = SYSTEM_POWER_STATUS()
    kernel32.GetSystemPowerStatus(ctypes.byref(status))
    now = {"percent": status.BatteryLifePercent if status.BatteryLifePercent <= 100 else None,
           "plugged_in": status.ACLineStatus == 1}
    return {**(_battery_report() or {}), **now}


def _battery_report():
    if time.time() - _battery["time"] < BATTERY_EVERY:
        return _battery["value"]
    _battery["time"] = time.time()
    with tempfile.TemporaryDirectory() as folder:
        report = f"{folder}\\battery.xml"
        try:
            subprocess.run(["powercfg", "/batteryreport", "/xml", "/output", report],
                           capture_output=True, timeout=20, creationflags=NO_WINDOW)
            root = ET.parse(report).getroot()
        except (OSError, subprocess.TimeoutExpired, ET.ParseError):
            return None
    battery = next((e for e in root.iter() if e.tag.endswith("}Battery") or e.tag == "Battery"), None)
    if battery is None:
        return None

    def field(name):
        element = next((e for e in battery if e.tag.split("}")[-1] == name), None)
        try:
            return int(element.text)
        except (AttributeError, TypeError, ValueError):
            return None
    design, full = field("DesignCapacity"), field("FullChargeCapacity")
    _battery["value"] = {"design_wh": round(design / 1000, 1) if design else None,
                         "full_wh": round(full / 1000, 1) if full else None,
                         "health": round(100 * full / design) if design and full else None,
                         "cycles": field("CycleCount") or None}
    return _battery["value"]
