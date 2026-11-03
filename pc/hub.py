"""The laptop side of Extend Display: start once, then the iPad decides what to do.

Usage: python hub.py
Waits for the iPad over USB (Extend Display app open), then handles its requests:
stream a screen (extend / mirror), run shortcuts from shortcuts.json, control media.

Wire format, both directions: [u8 type][u32 big-endian length][payload]
  type 1 = H.264 video (laptop -> iPad)
  type 2 = JSON message (both ways), always with a "type" field:
    iPad -> laptop: start_video {mode, portrait}, stop_video, orientation {portrait},
                    shortcut {id}, media {action},
                    touch {touches: [{id, x, y, state}]} (x/y are 0..1 of the image),
                    key {usage, down} (HID usage), mouse_move {dx, dy},
                    mouse_button {button, down}, scroll {dx, dy}, clipboard,
                    log {text} (diagnostics, printed to the hub's log),
                    keyframe (re-send the current picture as a full keyframe)
    laptop -> iPad: hello {shortcuts}, video_started {width, height},
                    now_playing {now_playing}, error {message}, clipboard
    clipboard (both ways): {kind: "text", text} or {kind: "image", png: base64}
"""
import base64
import json
import struct
import threading
import time
import traceback

import numpy as np
from av.video.frame import PictureType
from windows_capture import WindowsCapture

import actions
import clipboard
import inputs
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
        self.lock = threading.Lock()  # capture thread and keyframe() share the encoder
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
        with self.lock:
            if self.codec is None:
                # a fresh encoder per stream, so the iPad's first frame is a keyframe
                self.codec = make_encoder(frame.width, frame.height)
                self.vf, self.view = make_frame(frame.width, frame.height)
            np.copyto(self.view, frame.frame_buffer)
            sent = self._encode(PictureType.NONE)
        if not sent:
            control.stop()

    def keyframe(self):
        """Re-send the current picture as a full keyframe. The iPad asks for this
        when its decoder was reset (e.g. after the app was in the background):
        it can't show anything until a keyframe arrives, and on a still screen
        the next one could be a long way off."""
        with self.lock:
            if self.codec is not None and not self.stopped.is_set():
                self._encode(PictureType.I)

    def _encode(self, picture_type):
        """Encode the frame in self.vf and send it; False if the iPad is gone."""
        self.vf.pts = self.frames
        self.vf.pict_type = picture_type
        self.frames += 1
        try:
            for packet in self.codec.encode(self.vf):
                self.session.send(MSG_VIDEO, bytes(packet))
            return True
        except OSError:
            self.stopped.set()
            self.session.close()
            return False

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


class ClipboardSync:
    """Sends whatever is copied on the laptop to the iPad, and puts what the iPad
    sends on the laptop's clipboard (text and images)."""

    def __init__(self, session):
        self.session = session
        self.ours = clipboard.sequence_number()  # don't send what was there before
        threading.Thread(target=self._watch, daemon=True).start()

    def _watch(self):
        while not self.session.closed.wait(0.5):
            seq = clipboard.sequence_number()
            if seq == self.ours:
                continue
            self.ours = seq
            content = clipboard.read()
            if not content:
                continue
            kind, data = content
            message = {"type": "clipboard", "kind": kind}
            if kind == "text":
                message["text"] = data
            else:
                message["png"] = base64.b64encode(data).decode()
            try:
                self.session.send_json(message)
            except OSError:
                return
            print(f"clipboard -> iPad ({kind})")

    def from_ipad(self, message):
        try:
            if message.get("kind") == "text":
                clipboard.write_text(message["text"])
            elif message.get("kind") == "image":
                clipboard.write_image(base64.b64decode(message["png"]))
            else:
                return
        except OSError as e:
            print(f"clipboard from iPad failed: {e}")
            return
        # remember this change as ours, so it isn't echoed back to the iPad
        self.ours = clipboard.sequence_number()
        print(f"clipboard <- iPad ({message['kind']})")


_touchscreen = None


def touchscreen():
    """Windows allows touch injection to be set up once per process."""
    global _touchscreen
    if _touchscreen is None:
        _touchscreen = inputs.Touchscreen()
    return _touchscreen


def create_extend_screen(displays, portrait=False):
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
    monitors.configure(new["name"], width, height, *position, portrait=portrait)
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

    clip = ClipboardSync(session)
    touch = touchscreen()

    video = None
    streaming = None     # name of the screen being streamed, e.g. \\.\DISPLAY26
    displays = None      # Parsec driver connection, opened on the first Extend
    extend_index = None  # driver index of the screen we created for Extend
    extend_name = extend_setup = None

    def capture(name):
        """(Re)start streaming `name`, and aim touches at it."""
        nonlocal video, streaming
        wait_until_screens_settle()
        video, monitor = start_capture(session, name)
        streaming = name
        touch.set_screen(monitor["left"], monitor["top"], monitor["width"], monitor["height"])
        print(f"streaming {name} as monitor {monitor['index']} "
              f"({monitor['width']}x{monitor['height']}, scale {monitors.get_scale(name)}%)")

    def stop_video():
        nonlocal video, extend_index, streaming
        touch.release_all()
        inputs.release_all()
        streaming = None
        if video:
            video.stop()
            video = None
        if extend_index is not None:
            # remember where the user dragged it in Settings > Display, for next time
            layout.save_position(extend_setup, extend_name)
            displays.remove(extend_index)
            extend_index = None

    def start_video(mode, portrait):
        nonlocal displays, extend_index, extend_name, extend_setup
        if mode == "extend":
            displays = displays or vdd.VirtualDisplays()
            extend_index, extend_name, extend_setup = create_extend_screen(displays, portrait)
            capture(extend_name)
        else:
            capture(monitors.primary_monitor()["name"])
        print(f"{mode} started")

    def rotate(portrait):
        """The iPad turned: turn the Extend screen to match (Mirror can't rotate
        the laptop's own screen, so it stays as it is)."""
        nonlocal video
        screen = next((m for m in monitors.list_monitors() if m["name"] == extend_name), None)
        if extend_index is None or not screen or (screen["height"] > screen["width"]) == portrait:
            return
        touch.release_all()
        video.stop()
        video = None
        long_side, short_side = max(screen["width"], screen["height"]), min(screen["width"], screen["height"])
        monitors.configure(extend_name, long_side, short_side, screen["left"], screen["top"],
                           portrait=portrait)
        capture(extend_name)
        print("rotated to", "portrait" if portrait else "landscape")

    # whatever goes wrong, remove the virtual screen and end the session cleanly:
    # otherwise the ping thread keeps the screen alive with nothing using it
    try:
        for msg in session.messages():
            kind = msg.get("type")
            # input first: it is by far the most frequent message
            if kind == "touch":
                if streaming:
                    touch.update(msg.get("touches", []))
            elif kind == "key":
                inputs.key(msg.get("usage"), bool(msg.get("down")))
            elif kind == "mouse_move":
                inputs.mouse_move(msg.get("dx", 0), msg.get("dy", 0))
            elif kind == "mouse_button" and msg.get("button") in inputs.MOUSE_BUTTONS:
                inputs.mouse_button(msg["button"], bool(msg.get("down")))
            elif kind == "scroll":
                inputs.scroll(msg.get("dx", 0), msg.get("dy", 0))
            elif kind == "clipboard":
                clip.from_ipad(msg)
            elif kind == "log":
                print(f"iPad: {msg.get('text')}")
            elif kind == "keyframe":
                if video:
                    video.keyframe()
            elif kind in ("start_video", "stop_video"):
                stop_video()
                if kind == "start_video":
                    try:
                        start_video(msg.get("mode"), bool(msg.get("portrait")))
                    except OSError as e:  # includes vdd.DriverNotFound
                        print(f"{msg.get('mode')} failed: {e}")
                        stop_video()
                        session.send_json({"type": "error", "message": f"Could not start: {e}"})
                else:
                    print("video stopped")
            elif kind == "orientation":
                try:
                    rotate(bool(msg.get("portrait")))
                except OSError as e:
                    print(f"rotating failed: {e}")
                    stop_video()
                    session.send_json({"type": "error", "message": f"Could not rotate: {e}"})
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


def wait_for_ipad(stop, on_status):
    """Block until an iPad is plugged in with the app open; return the socket,
    or None if `stop` gets set first."""
    waiting_for = None
    while not stop.is_set():
        try:
            devices = usbmux.list_devices()
        except OSError:
            devices, reason = None, "Apple's USB service isn't running (install Apple Devices or iTunes)."
        if devices == []:
            reason = "Plug in the iPad, unlock it and tap 'Trust'."
        elif devices:
            try:
                return usbmux.connect(devices[0]["DeviceID"], PORT)
            except usbmux.UsbmuxError:
                reason = "iPad found. Open the Extend Display app on it."
        if reason != waiting_for:
            on_status(reason)
            waiting_for = reason
        stop.wait(1)
    return None


def run(stop, on_status=print):
    """Serve the iPad until `stop` is set. on_status gets short status texts."""
    while not stop.is_set():
        sock = wait_for_ipad(stop, on_status)
        if sock is None:
            return
        session = Session(sock)
        on_status("iPad connected.")
        # the reader runs in a thread so the wait below can notice `stop` and Ctrl+C
        worker = threading.Thread(target=handle, args=(session,), daemon=True)
        worker.start()
        try:
            while not session.closed.wait(0.2) and not stop.is_set():
                pass
        finally:
            # closing the socket ends handle(), which saves the layout and
            # removes the virtual screen
            session.close()
            worker.join(timeout=5)
        on_status("iPad disconnected.")


def main():
    stop = threading.Event()
    print("Extend Display hub. Ctrl+C to quit.")
    try:
        run(stop)
    except KeyboardInterrupt:
        stop.set()
        print("Stopped.")


if __name__ == "__main__":
    main()
