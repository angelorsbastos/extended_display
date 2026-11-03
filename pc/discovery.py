"""Find iPads running Extend Display on the Wi-Fi, through Bonjour (like AirPlay).

The iPad announces "_extenddisplay._tcp" with its id and name; this keeps a live
list of the ones currently on the network.
"""
import threading

from zeroconf import IPVersion, ServiceBrowser, ServiceListener, Zeroconf

SERVICE = "_extenddisplay._tcp.local."


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
