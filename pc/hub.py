"""The laptop side of Extend Display: start once, then the iPad decides what to do.

Usage: python hub.py
Waits for the iPad over USB (Extend Display app open), then handles its requests:
stream a screen (extend / mirror), run shortcuts from shortcuts.json, control media.

Wire format, both directions: [u8 type][u32 big-endian length][payload]
  type 1 = H.264 video (laptop -> iPad)
  type 2 = JSON message (both ways), always with a "type" field:
    iPad -> laptop: start_video {mode}, stop_video, shortcut {id}, media {action}
    laptop -> iPad: hello {shortcuts}, video_started {width, height},
                    now_playing {now_playing}, error {message}
"""
import json
import struct
import threading
import time

import numpy as np
from windows_capture import WindowsCapture

import actions
import monitors
import nowplaying
import usbmux
from encoder import FPS, make_encoder, make_frame

PORT = 7000
MSG_VIDEO = 1
MSG_JSON = 2


class Session:
    """One connection to the iPad. Safe to send from several threads."""

    def __init__(self, sock):
        self.sock = sock
        self.send_lock = threading.Lock()
        self.closed = threading.Event()

    def send(self, msg_type, payload):
        with self.send_lock:
            self.sock.sendall(struct.pack(">BI", msg_type, len(payload)) + payload)

    def send_json(self, message):
        self.send(MSG_JSON, json.dumps(message).encode())

    def messages(self):
        """Yield the JSON messages the iPad sends, until it disconnects."""
        try:
            while True:
                msg_type, length = struct.unpack(">BI", self._recv_exact(5))
                payload = self._recv_exact(length)
                if msg_type == MSG_JSON:
                    yield json.loads(payload)
        except (OSError, EOFError):
            return

    def _recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def close(self):
        self.closed.set()
        try:
            self.sock.close()
        except OSError:
            pass


class VideoStream:
    """Captures one monitor and sends it as H.264 until stopped."""

    def __init__(self, session, monitor_index):
        self.session = session
        self.stopped = threading.Event()
        self.codec = None
        self.frames = 0
        capture = WindowsCapture(cursor_capture=True, draw_border=False,
                                 monitor_index=monitor_index,
                                 minimum_update_interval=1000 // FPS)
        capture.event(self.on_frame_arrived)
        capture.event(self.on_closed)
        self.control = capture.start_free_threaded()

    def on_frame_arrived(self, frame, control):
        if self.stopped.is_set():
            control.stop()
            return
        if self.codec is None:
            # a fresh encoder per stream, so the iPad's first frame is a keyframe
            self.codec = make_encoder(frame.width, frame.height)
            self.vf, self.view = make_frame(frame.width, frame.height)
        np.copyto(self.view, frame.frame_buffer)
        self.vf.pts = self.frames
        self.frames += 1
        try:
            for packet in self.codec.encode(self.vf):
                self.session.send(MSG_VIDEO, bytes(packet))
        except OSError:
            self.stopped.set()
            control.stop()
            self.session.close()

    def on_closed(self):
        self.stopped.set()

    def stop(self):
        self.stopped.set()
        try:
            self.control.stop()
        except Exception:  # already stopped from inside the capture thread
            pass


def send_now_playing(session):
    """Tell the iPad whenever the song or play/pause state changes."""
    last = "unset"
    while not session.closed.wait(1):
        current = nowplaying.current()
        if current != last:
            try:
                session.send_json({"type": "now_playing", "now_playing": current})
            except OSError:
                return
            last = current


def handle(session):
    shortcuts = actions.load_shortcuts()
    by_id = {s["id"]: s for s in shortcuts}
    session.send_json({"type": "hello", "shortcuts": [
        {"id": s["id"], "title": s["title"], "icon": s["icon"]} for s in shortcuts]})
    threading.Thread(target=send_now_playing, args=(session,), daemon=True).start()

    video = None
    for msg in session.messages():
        kind = msg.get("type")
        if kind in ("start_video", "stop_video") and video:
            video.stop()
            video = None
        if kind == "start_video":
            monitor = monitors.monitor_for_mode(msg.get("mode"))
            if monitor is None:
                session.send_json({"type": "error", "message":
                                   "No second display on the laptop. Install a virtual display "
                                   "driver, or use Mirror."})
                continue
            print(f"{msg['mode']}: streaming monitor {monitor['index']} "
                  f"({monitor['width']}x{monitor['height']})")
            session.send_json({"type": "video_started",
                               "width": monitor["width"], "height": monitor["height"]})
            video = VideoStream(session, monitor["index"])
        elif kind == "stop_video":
            print("video stopped")
        elif kind == "shortcut" and msg.get("id") in by_id:
            print(f"shortcut: {msg['id']}")
            actions.run_shortcut(by_id[msg["id"]])
        elif kind == "media" and msg.get("action") in actions.MEDIA_KEYS:
            actions.media(msg["action"])
    if video:
        video.stop()
    session.close()


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


def main():
    try:
        while True:
            session = Session(wait_for_ipad())
            print("iPad connected. Ctrl+C to quit.")
            # the reader runs in a thread so Ctrl+C still works while it waits on the socket
            threading.Thread(target=handle, args=(session,), daemon=True).start()
            while not session.closed.wait(0.2):
                pass
            print("iPad disconnected.")
    except KeyboardInterrupt:
        print("Stopped.")


if __name__ == "__main__":
    main()
