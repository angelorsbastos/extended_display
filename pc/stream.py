"""Stream a Windows monitor to the iPad app over the USB cable.

Usage: python stream.py [monitor_number]
monitor_number starts at 1 (same numbering as Windows display settings);
pick the virtual monitor that the iPad should become.

Open the Extend Display app on the iPad first; this waits until it can connect.
Wire format, PC -> iPad: [u8 type][u32 big-endian length][payload]
"""
import struct
import sys
import threading
import time

import numpy as np
from windows_capture import WindowsCapture

import usbmux
from encoder import FPS, make_encoder, make_frame

PORT = 7000
MSG_VIDEO = 1


def wait_for_ipad():
    """Block until an iPad is plugged in with the app open; return the socket."""
    waiting_for = None
    while True:
        devices = usbmux.list_devices()
        if not devices:
            reason = "No iPad over USB: plug it in, unlock it, tap 'Trust'."
        else:
            try:
                return usbmux.connect(devices[0]["DeviceID"], PORT)
            except usbmux.UsbmuxError:
                reason = "iPad found. Open the Extend Display app on it."
        if reason != waiting_for:
            print(reason)
            waiting_for = reason
        time.sleep(1)


def stream(sock, monitor):
    """Capture `monitor` and send it to the iPad until the connection drops."""
    state = {"codec": None, "frames": 0}
    done = threading.Event()
    capture = WindowsCapture(cursor_capture=True, draw_border=False, monitor_index=monitor,
                             minimum_update_interval=1000 // FPS)

    @capture.event
    def on_frame_arrived(frame, control):
        if done.is_set():
            control.stop()
            return
        if state["codec"] is None:
            # a fresh encoder per connection, so the iPad's first frame is a keyframe
            state["codec"] = make_encoder(frame.width, frame.height)
            state["vf"], state["view"] = make_frame(frame.width, frame.height)
            print(f"Streaming monitor {monitor} ({frame.width}x{frame.height}). Ctrl+C to stop.")
        np.copyto(state["view"], frame.frame_buffer)
        vf = state["vf"]
        vf.pts = state["frames"]
        state["frames"] += 1
        try:
            for packet in state["codec"].encode(vf):
                data = bytes(packet)
                sock.sendall(struct.pack(">BI", MSG_VIDEO, len(data)) + data)
        except OSError:
            print("iPad disconnected.")
            done.set()
            control.stop()

    @capture.event
    def on_closed():
        done.set()

    control = capture.start_free_threaded()
    try:
        while not done.wait(0.2):
            pass
    finally:
        done.set()
        control.stop()
        sock.close()


def main():
    monitor = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    try:
        while True:
            stream(wait_for_ipad(), monitor)
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
