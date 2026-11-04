"""Find iPads running Wingman on the Wi-Fi, through Bonjour (like AirPlay).

The iPad announces "_extenddisplay._tcp" with its id and name; this keeps a live
list of the ones currently on the network.
"""
import threading
import time

import ifaddr
from zeroconf import IPVersion, ServiceBrowser, ServiceListener, Zeroconf

SERVICE = "_extenddisplay._tcp.local."  # the original name, kept (see the app's StreamServer)
HOTSPOT_ADDRESS = "192.168.137.1"  # Windows' Mobile hotspot always uses this


def networks():
    """This laptop's IPv4 addresses, e.g. ["192.168.1.23", "192.168.137.1 (hotspot)"]."""
    found = []
    for adapter in ifaddr.get_adapters():
        for ip in adapter.ips:
            if isinstance(ip.ip, str) and not ip.ip.startswith(("127.", "169.254.")):
                found.append(f"{ip.ip} (hotspot)" if ip.ip == HOTSPOT_ADDRESS else ip.ip)
    return sorted(found)


class Watcher:
    """A Browser that starts over when the laptop joins or leaves a network (e.g. the
    Mobile hotspot is switched on): Bonjour only listens on the networks it saw at start."""

    def __init__(self):
        self.networks = networks()
        self.browser = Browser()
        self.checked = time.time()

    def ipads(self):
        if time.time() - self.checked > 5:
            self.checked = time.time()
            now = networks()
            if now != self.networks:
                print(f"networks changed: {self.networks} -> {now}; searching again")
                self.networks = now
                self.browser.close()
                self.browser = Browser()
        return self.browser.ipads()

    def close(self):
        self.browser.close()


class Browser(ServiceListener):
    def __init__(self):
        self.lock = threading.Lock()
        self.found = {}  # Bonjour name -> {"id", "name", "address", "port"}
        self.zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
        self.browser = ServiceBrowser(self.zeroconf, SERVICE, self)

    def ipads(self):
        with self.lock:
            return list(self.found.values())

    def close(self):
        self.zeroconf.close()

    # ServiceListener callbacks (run on zeroconf's own thread)

    def add_service(self, zc, type_, name):
        self._resolve(zc, type_, name)

    def update_service(self, zc, type_, name):
        self._resolve(zc, type_, name)

    def remove_service(self, zc, type_, name):
        with self.lock:
            self.found.pop(name, None)

    def _resolve(self, zc, type_, name):
        info = zc.get_service_info(type_, name, timeout=3000)
        addresses = info.parsed_addresses(IPVersion.V4Only) if info else []
        if not addresses:
            return
        props = {k.decode(): (v or b"").decode() for k, v in info.properties.items()}
        with self.lock:
            self.found[name] = {"id": props.get("id"), "name": props.get("name") or name.split(".")[0],
                                "address": addresses[0], "port": info.port}
