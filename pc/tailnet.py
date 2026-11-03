"""Find the iPad through Tailscale, for using it away from home.

Bonjour only works on the local network, so for remote use the hub asks the
Tailscale app on this laptop which of your devices are online, and tries the
iPads among them. Tailscale gets the connection through routers and encrypts
it; the app's own pairing and encryption still apply on top.
"""
import json
import pathlib
import subprocess
import time

CLI = pathlib.Path(r"C:\Program Files\Tailscale\tailscale.exe")
CACHE_SECONDS = 10
_cache = {"time": 0.0, "result": ([], None)}


def ipads():
    """([{"name", "address"}] of online iPads/iPhones in your tailnet, problem or None).
    The problem says why none can be listed, e.g. Tailscale not installed or off."""
    if time.time() - _cache["time"] < CACHE_SECONDS:
        return _cache["result"]
    _cache["time"] = time.time()
    _cache["result"] = _query()
    return _cache["result"]


def _query():
    if not CLI.exists():
        return [], None  # not installed: just no remote use, not a problem to report
    try:
        out = subprocess.run([str(CLI), "status", "--json"], capture_output=True, text=True,
                             timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
        status = json.loads(out.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        return [], f"couldn't ask Tailscale ({e})"
    if status.get("BackendState") != "Running":
        return [], f"Tailscale on this laptop is {status.get('BackendState', 'not running').lower()}"
    found = []
    for peer in (status.get("Peer") or {}).values():
        # iPadOS reports itself as "iOS"
        if peer.get("OS") == "iOS" and peer.get("Online") and peer.get("TailscaleIPs"):
            ipv4 = [ip for ip in peer["TailscaleIPs"] if "." in ip]
            if ipv4:
                found.append({"name": peer.get("HostName") or "iPad", "address": ipv4[0]})
    return found, None if found else "the iPad isn't online in Tailscale"
