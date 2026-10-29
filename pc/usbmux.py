"""Minimal usbmux client: talks to Apple Mobile Device Service on Windows.

usbmux lets a PC program open a TCP connection to a port on an iPhone/iPad
over the USB cable. On Windows the service listens on 127.0.0.1:27015.
"""
import plistlib
import socket
import struct

USBMUX_ADDR = ("127.0.0.1", 27015)
PLIST_MESSAGE = 8


class UsbmuxError(Exception):
    pass


def _send(sock, payload, tag=1):
    body = plistlib.dumps(payload)
    # header: total length, protocol version 1, message type, tag (little-endian)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, PLIST_MESSAGE, tag) + body)


def _recv(sock):
    header = _recv_exact(sock, 16)
    length, _version, _msgtype, _tag = struct.unpack("<IIII", header)
    return plistlib.loads(_recv_exact(sock, length - 16))


def _recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise UsbmuxError("usbmux connection closed")
        data += chunk
    return data


def _request(message_type, **fields):
    sock = socket.create_connection(USBMUX_ADDR)
    _send(sock, {"MessageType": message_type, "ProgName": "ipad-display",
                 "ClientVersionString": "ipad-display-0.1", **fields})
    return sock, _recv(sock)


def list_devices():
    """Return the devices plugged in over USB, as dicts of their properties."""
    sock, reply = _request("ListDevices")
    sock.close()
    return [d["Properties"] for d in reply.get("DeviceList", [])
            if d["Properties"].get("ConnectionType") == "USB"]


def connect(device_id, port):
    """Open a raw TCP connection to `port` on the device, through the cable."""
    # usbmux wants the port in network byte order, stored as a little-endian int
    port_be = struct.unpack("<H", struct.pack(">H", port))[0]
    sock, reply = _request("Connect", DeviceID=device_id, PortNumber=port_be)
    if reply.get("Number") != 0:
        sock.close()
        raise UsbmuxError(f"device refused port {port} (code {reply.get('Number')}); "
                          "is the iPad app open?")
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


if __name__ == "__main__":
    devices = list_devices()
    if not devices:
        print("No iPhone/iPad found over USB. Plug it in, unlock it, tap 'Trust'.")
    for d in devices:
        print(f"DeviceID={d['DeviceID']}  ProductID={d.get('ProductID')}  "
              f"Serial={d.get('SerialNumber')}")
