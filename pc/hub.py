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
import traceback

import numpy as np
from windows_capture import WindowsCapture

import actions
import layout
import monitors
import nowplaying
import usbmux
import vdd
from encoder import FPS, make_encoder, make_frame

PORT = 7000
MSG_VIDEO = 1
MSG_JSON = 2
IPAD_SIZE = (2360, 1640)  # iPad 10 screen; offered once ipad-resolution.reg is imported
# Windows scale for the Extend screen. 200% shows things at the size iPadOS itself
# uses; try 175 for more room or 225 for bigger text.
EXTEND_SCALE = 200


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


def create_extend_screen(displays):
    """Plug in a new virtual screen, sized for the iPad, where the user put it last
    time in this setup (or right of the others the first time).
    Returns (driver index, screen name, setup key)."""
    setup = layout.setup_key()
    before = {m["name"] for m in monitors.list_monitors()}
    index = displays.add()
    for _ in range(50):
        new = next((m for m in monitors.list_monitors() if m["name"] not in before), None)
        if new:
            break
        time.sleep(0.1)
    else:
        displays.remove(index)
        raise OSError("Windows did not show the new virtual screen")

    if IPAD_SIZE in monitors.available_modes(new["name"]):
        width, height = IPAD_SIZE
    else:
        width, height = new["width"], new["height"]
        print(f"iPad resolution not available, using {width}x{height}: "
              "import pc/ipad-resolution.reg to fix")
    position = layout.saved_position(setup)
    if position is None:
        right = max(m["left"] + m["width"] for m in monitors.list_monitors()
                    if m["name"] != new["name"])
        position = (right, 0)
    monitors.configure(new["name"], width, height, *position)
    # at 100% a 2360x1640 screen on 10.9" makes everything tiny
    monitors.set_scale(new["name"], EXTEND_SCALE)
    return index, new["name"], setup


def wait_until_screens_settle(timeout=4):
    """After a screen is added or changed, Windows may rearrange and renumber the
    screens for a moment (the first time a layout is seen). Wait until the list
    has stayed the same for half a second."""
    last, stable_since = None, time.time()
    end = time.time() + timeout
    while time.time() < end:
        now = monitors.list_monitors()
        if now != last:
            last, stable_since = now, time.time()
        elif time.time() - stable_since >= 0.5:
            return
        time.sleep(0.1)


def start_capture(session, name, attempts=5):
    """Start streaming the screen called `name` (e.g. '\\\\.\\DISPLAY26').
    Capture is opened by number, and numbers can shift while Windows rearranges
    screens, so the number is looked up right before each attempt."""
    error = None
    for _ in range(attempts):
        monitor = next((m for m in monitors.list_monitors() if m["name"] == name), None)
        if monitor:
            # must reach the iPad before the first frame: it resets the decoder,
            # and the first frame carries the keyframe the decoder needs
            session.send_json({"type": "video_started",
                               "width": monitor["width"], "height": monitor["height"]})
            try:
                return VideoStream(session, monitor["index"]), monitor
            except Exception as e:  # windows_capture raises a plain Exception
                error = e
                print(f"capture of {name} failed, retrying: {e}")
        time.sleep(0.3)
    raise OSError(f"could not capture {name}: {error}")


def handle(session):
    shortcuts = actions.load_shortcuts()
    by_id = {s["id"]: s for s in shortcuts}
    session.send_json({"type": "hello", "shortcuts": [
        {"id": s["id"], "title": s["title"], "icon": s["icon"]} for s in shortcuts]})
    threading.Thread(target=send_now_playing, args=(session,), daemon=True).start()

    video = None
    displays = None      # Parsec driver connection, opened on the first Extend
    extend_index = None  # driver index of the screen we created for Extend
    extend_name = extend_setup = None

    def stop_video():
        nonlocal video, extend_index
        if video:
            video.stop()
            video = None
        if extend_index is not None:
            # remember where the user dragged it in Settings > Display, for next time
            layout.save_position(extend_setup, extend_name)
            displays.remove(extend_index)
            extend_index = None

    def start_video(mode):
        nonlocal displays, extend_index, extend_name, extend_setup, video
        if mode == "extend":
            displays = displays or vdd.VirtualDisplays()
            extend_index, extend_name, extend_setup = create_extend_screen(displays)
            name = extend_name
        else:
            name = monitors.primary_monitor()["name"]
        wait_until_screens_settle()
        video, monitor = start_capture(session, name)
        print(f"{mode}: streaming {name} as monitor {monitor['index']} "
              f"({monitor['width']}x{monitor['height']}, scale {monitors.get_scale(name)}%)")

    # whatever goes wrong, remove the virtual screen and end the session cleanly:
    # otherwise the ping thread keeps the screen alive with nothing using it
    try:
        for msg in session.messages():
            kind = msg.get("type")
            if kind in ("start_video", "stop_video"):
                stop_video()
            if kind == "start_video":
                try:
                    start_video(msg.get("mode"))
                except OSError as e:  # includes vdd.DriverNotFound
                    print(f"{msg.get('mode')} failed: {e}")
                    stop_video()
                    session.send_json({"type": "error", "message": f"Could not start: {e}"})
            elif kind == "stop_video":
                print("video stopped")
            elif kind == "shortcut" and msg.get("id") in by_id:
                print(f"shortcut: {msg['id']}")
                try:
                    actions.run_shortcut(by_id[msg["id"]])
                except OSError as e:  # e.g. the app it opens isn't installed
                    print(f"shortcut {msg['id']} failed: {e}")
            elif kind == "media" and msg.get("action") in actions.MEDIA_KEYS:
                actions.media(msg["action"])
    except Exception:
        traceback.print_exc()
    finally:
        stop_video()
        if displays:
            displays.close()
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
