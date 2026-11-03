"""The laptop side of Extend Display: start once, then the iPad decides what to do.

Usage: python hub.py
Waits for the iPad (Extend Display app open) over the USB cable or, once paired,
over Wi-Fi, then handles its requests: stream a screen (extend / mirror), input,
shortcuts from shortcuts.json, the Controls screen. The cable wins when both work.

Wire format, both directions: [u8 type][u32 big-endian length][payload]
  type 1 = H.264 video (laptop -> iPad)
  type 4 = AAC audio packet, raw (laptop -> iPad, after audio_started)
  type 5 = a piece of a file, both ways (see files.py: file_start / file_end / file_saved)
  type 3 = a type 1, 2 or 4 message sealed by secure.Cipher (all of Wi-Fi, after login)
  type 2 = JSON message (both ways), always with a "type" field:
    connection setup: identity (iPad, first), pairing and login: see secure.py
    iPad -> laptop: start_video {mode, portrait}, stop_video, orientation {portrait},
                    shortcut {id}, media {action},
                    touch {touches: [{id, x, y, state}]} (x/y are 0..1 of the image),
                    key {usage, down} (HID usage), mouse_move {dx, dy},
                    mouse_button {button, down}, scroll {dx, dy}, clipboard,
                    log {text} (diagnostics, printed to the hub's log),
                    keyframe (re-send the current picture as a full keyframe),
                    watch_controls {on}, control {name, value} (see controls.apply),
                    sound {on} (play the laptop's sound on the iPad, see audio.py)
    laptop -> iPad: hello {shortcuts}, video_started {width, height},
                    audio_started {sample_rate, channels, config: base64 AudioSpecificConfig},
                    now_playing {now_playing}, error {message}, clipboard,
                    controls {controls} (see controls.state)
    clipboard (both ways): {kind: "text", text} or {kind: "image", png: base64};
                           from the iPad also paste: true to press Ctrl+V after
"""
import base64
import ctypes
import json
import socket
import struct
import threading
import time
import traceback

import numpy as np
from av.video.frame import PictureType
from windows_capture import WindowsCapture

import actions
import audio
import clipboard
import controls
import discovery
import files
import inputs
import ipad_control
import layout
import monitors
import nowplaying
import secure
import tailnet
import usbmux
import vdd
from encoder import FPS, make_encoder, make_frame

PORT = 7000
MSG_VIDEO = 1
MSG_JSON = 2
MSG_SEALED = 3
MSG_AUDIO = 4
# Wi-Fi bandwidth is less steady than the cable's; less data means less stutter
BIT_RATE = {"usb": 15_000_000, "wifi": 8_000_000, "remote": 5_000_000}  # remote: home upload
WIFI_PAIRING_RETRY = 60  # seconds before offering pairing again after a cancel
REMOTE_RETRY = 15  # seconds between attempts to reach the iPad through Tailscale
IPAD_WIFI_PORT = 7001  # the iPad's encrypted port (Bonjour tells it on the local network)
IPAD_SIZE = (2360, 1640)  # iPad 10 screen; offered once ipad-resolution.reg is imported
# Windows scale for the Extend screen. 200% shows things at the size iPadOS itself
# uses; try 175 for more room or 225 for bigger text.
EXTEND_SCALE = 200


class Session:
    """One connection to the iPad. Safe to send from several threads.
    transport is "usb" or "wifi"; once `cipher` is set (Wi-Fi, after login),
    everything is sealed both ways and unsealed messages are refused."""

    def __init__(self, sock, transport="usb"):
        self.sock = sock
        self.transport = transport
        self.cipher = None
        self.send_lock = threading.Lock()
        self.closed = threading.Event()

    def send(self, msg_type, payload):
        with self.send_lock:  # also keeps the cipher's message count in wire order
            if self.cipher:
                payload, msg_type = self.cipher.seal(bytes([msg_type]) + payload), MSG_SEALED
            self.sock.sendall(struct.pack(">BI", msg_type, len(payload)) + payload)

    def send_json(self, message):
        self.send(MSG_JSON, json.dumps(message).encode())

    def read(self):
        """The next message as (type, payload), unsealed if the link is encrypted."""
        msg_type, length = struct.unpack(">BI", self._recv_exact(5))
        payload = self._recv_exact(length)
        if self.cipher:
            if msg_type != MSG_SEALED:
                raise OSError("unencrypted message on an encrypted link")
            opened = self.cipher.open(payload)
            msg_type, payload = opened[0], opened[1:]
        return msg_type, payload

    def recv_json(self):
        msg_type, payload = self.read()
        if msg_type != MSG_JSON:
            raise OSError(f"expected a JSON message, got type {msg_type}")
        return json.loads(payload)

    def messages(self):
        """Yield the JSON messages the iPad sends, until it disconnects. A piece
        of a file comes as {"type": "file_data", "payload": bytes}."""
        try:
            while True:
                msg_type, payload = self.read()
                if msg_type == MSG_JSON:
                    yield json.loads(payload)
                elif msg_type == files.MSG_FILE:
                    yield {"type": "file_data", "payload": payload}
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
                self.codec = make_encoder(frame.width, frame.height,
                                          bit_rate=BIT_RATE[self.session.transport])
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
        if message.get("paste"):  # "Paste on laptop" in the iPad's clipboard history
            actions.press("ctrl", "v")


class ControlsWatch:
    """While the iPad shows its Controls screen, keep it up to date with the
    laptop's volume, brightness, Wi-Fi, ... (every 2 s, and right after a change)."""

    def __init__(self, session):
        self.session = session
        self.on = threading.Event()
        self.refresh = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def watch(self, on):
        if on:
            self.on.set()
            self.refresh.set()
        else:
            self.on.clear()

    def _run(self):
        while not self.session.closed.is_set():
            if not self.on.wait(0.5):
                continue
            try:
                self.session.send_json({"type": "controls", "controls": controls.state()})
            except OSError:
                return
            self.refresh.wait(2)
            self.refresh.clear()


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
    controls_watch = ControlsWatch(session)
    touch = touchscreen()
    receiver = files.Receiver(session)
    sender = files.Sender(session)
    files.set_active_sender(sender)

    video = None
    sound = None         # audio.AudioStream while the iPad plays the laptop's sound
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

    def set_sound(on):
        nonlocal sound
        if sound:
            sound.stop()
            sound = None
        if on:
            sound = audio.AudioStream(
                audio.BIT_RATE[session.transport],
                on_started=lambda config: session.send_json({
                    "type": "audio_started", "sample_rate": audio.SAMPLE_RATE,
                    "channels": audio.CHANNELS, "config": base64.b64encode(config).decode()}),
                on_packet=lambda packet: session.send(MSG_AUDIO, packet))
        print("sound on the iPad" if on else "sound on the laptop only")

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
            elif kind == "file_data":
                receiver.data(msg["payload"])
            elif kind == "file_start":
                receiver.start(msg)
            elif kind == "file_end":
                receiver.end(msg)
            elif kind == "file_cancel":
                receiver.cancel(msg)
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
            elif kind == "watch_controls":
                controls_watch.watch(bool(msg.get("on")))
            elif kind == "sound":
                set_sound(bool(msg.get("on")))
            elif kind == "control":
                print(f"control: {msg.get('name')} = {msg.get('value')}")
                try:
                    controls.apply(msg.get("name"), msg.get("value"))
                except Exception as e:  # COM, WMI and WinRT each raise their own errors
                    print(f"control {msg.get('name')} failed: {e}")
                    session.send_json({"type": "error", "message": f"Couldn't change that: {e}"})
                controls_watch.refresh.set()
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
        if sound:
            sound.stop()
        receiver.close()
        files.set_active_sender(None, only_if=sender)
        if displays:
            displays.close()
        session.close()


class CodePopup:
    """Shows the 6-digit pairing code on the laptop, and closes it again."""

    TITLE = "Extend Display pairing"

    def show(self, code, ipad_name):
        print(f"pairing code for {ipad_name}: {code}")
        text = (f"Type this code on {ipad_name}:\n\n        {code[:3]} {code[3:]}\n\n"
                "This window closes by itself when pairing is done.")
        threading.Thread(target=ctypes.windll.user32.MessageBoxW, daemon=True,
                         args=(None, text, self.TITLE, 0x40 | 0x40000)).start()  # info icon, on top

    def hide(self):
        for _ in range(10):  # the window may still be opening
            window = ctypes.windll.user32.FindWindowW(None, self.TITLE)
            if window:
                ctypes.windll.user32.PostMessageW(window, 0x10, 0, 0)  # WM_CLOSE
                return
            time.sleep(0.1)


def wait_for_ipad(stop, on_status, browser, pairing_paused_until):
    """Block until the iPad is reachable with the app open, over the cable (preferred)
    or Wi-Fi; return a Session, or None if `stop` gets set first."""
    waiting_for = None
    while not stop.is_set():
        usb_problem = None
        try:
            devices = usbmux.list_devices()
        except OSError:
            devices, usb_problem = [], "Apple's USB service isn't running (install Apple Devices or iTunes)."
        if devices:
            try:
                return Session(usbmux.connect(devices[0]["DeviceID"], PORT), "usb")
            except usbmux.UsbmuxError:
                usb_problem = "iPad plugged in. Open the Extend Display app on it."

        # explain the Wi-Fi side as precisely as possible: the user can't see it otherwise
        wifi_problem = None
        for ipad in browser.ipads() if browser else []:
            unpaired = secure.key_for(ipad["id"]) is None
            wait = pairing_paused_until.get(ipad["id"], 0) - time.time()
            if unpaired and wait > 0:  # pairing was just cancelled; don't pop it up right away
                wifi_problem = f"{ipad['name']}: pairing didn't finish. Offering it again in {int(wait) + 1} s."
                continue
            try:
                sock = socket.create_connection((ipad["address"], ipad["port"]), timeout=3)
            except OSError as e:
                wifi_problem = (f"Found {ipad['name']} on Wi-Fi at {ipad['address']} but couldn't connect "
                                f"({e}). On the iPad, check Settings > Privacy & Security > "
                                "Local Network > Extend Display.")
                continue
            network_socket(sock)
            on_status(f"Found {ipad['name']} on Wi-Fi, connecting…")
            return Session(sock, "wifi")

        # away from home: through Tailscale (only when nothing local works)
        remote_problem = None
        peers, remote_problem = tailnet.ipads()
        for peer in peers:
            key = f"remote {peer['address']}"
            if pairing_paused_until.get(key, 0) > time.time():
                continue  # it just failed (e.g. not paired yet); don't retry every second
            pairing_paused_until[key] = time.time() + REMOTE_RETRY
            try:
                sock = socket.create_connection((peer["address"], IPAD_WIFI_PORT), timeout=5)
            except OSError as e:
                remote_problem = (f"{peer['name']} is online in Tailscale but didn't answer ({e}). "
                                  "Is Extend Display open on it?")
                continue
            network_socket(sock)
            on_status(f"Found {peer['name']} through Tailscale, connecting…")
            return Session(sock, "remote")

        searching = ", ".join(browser.networks) if browser else "nothing (no network)"
        reason = usb_problem or wifi_problem or (
            "Looking for the iPad: plug in the cable, or open Extend Display on the same Wi-Fi "
            f"(searching on {searching}; guest networks usually block this)."
            + (f" Remote: {remote_problem}." if remote_problem else ""))
        if reason != waiting_for:
            on_status(reason)
            waiting_for = reason
        stop.wait(1)
    return None


def network_socket(sock):
    """Settings for a Wi-Fi/Tailscale connection. If the app is closed or the iPad drops
    off the network, its goodbye can get lost, and without keepalive the hub would wait
    on the dead connection forever. Keepalive probes a quiet link every 2 s after 5 s,
    and gives up after 3 missed answers."""
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    sock.ioctl(socket.SIO_KEEPALIVE_VALS, (1, 5000, 2000))
    if hasattr(socket, "TCP_KEEPCNT"):
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)  # Windows default is 10


def set_up_link(session, on_status, pairing_paused_until):
    """Before the normal conversation: learn who the iPad is, pair if needed, and on
    Wi-Fi log in and switch to encryption. Raises if the link can't be trusted."""
    session.sock.settimeout(3 if session.transport != "remote" else 10)  # internet is slower
    try:
        identity = session.recv_json()
    except socket.timeout:
        if session.transport != "usb":
            raise
        identity = None  # an app version from before Wi-Fi support: the cable is enough
    if identity is not None and identity.get("type") != "identity":
        raise OSError(f"expected identity, got {identity.get('type')}")

    if identity:
        ipad_id, name = identity["ipad_id"], identity.get("ipad_name", "the iPad")
        knows_us = secure.laptop_id() in identity.get("paired_laptops", [])
        key = secure.key_for(ipad_id) if knows_us else None
        if session.transport == "usb":
            if key is None:
                secure.pair_over_usb(session, identity)
                on_status(f"Paired with {name} through the cable; Wi-Fi works now too.")
        else:
            if key is None and session.transport == "remote":
                # nobody is at the laptop to read a pairing code
                raise secure.PairingFailed(f"{name} isn't paired with this laptop yet. Pair it once at "
                                           "home: plug in the cable, or use the same Wi-Fi.")
            if key is None:
                on_status(f"Pairing with {name}: type the code shown on the laptop.")
                session.sock.settimeout(120)  # the user is typing
                try:
                    secure.pair_over_wifi(session, identity, CodePopup().show, CodePopup().hide)
                except (secure.PairingFailed, OSError):
                    pairing_paused_until[ipad_id] = time.time() + WIFI_PAIRING_RETRY
                    raise
                session.sock.settimeout(3)
                key = secure.key_for(ipad_id)
                on_status(f"Paired with {name}.")
            secure.authenticate(session, ipad_id, key)
    session.sock.settimeout(None)


def serve(session, on_status, pairing_paused_until):
    how = {"usb": "the cable", "wifi": "Wi-Fi", "remote": "Tailscale (remote)"}[session.transport]
    try:
        set_up_link(session, on_status, pairing_paused_until)
    except secure.NeedsPairing:
        on_status("The iPad no longer knows this laptop (app reinstalled?). Pairing again…")
        session.close()
        return
    except (OSError, EOFError, ValueError, KeyError, secure.PairingFailed) as e:
        # EOFError: the iPad closed the connection halfway through (e.g. app closed)
        on_status(f"Couldn't connect over {how}: {e or type(e).__name__}")
        session.close()
        return
    session.ready = True
    on_status(f"iPad connected over {how}.")
    handle(session)


def run(stop, on_status=print):
    """Serve the iPad until `stop` is set. on_status gets short status texts."""
    try:
        browser = discovery.Watcher()
    except OSError as e:  # e.g. no network at all: the cable still works
        print(f"Wi-Fi discovery unavailable: {e}")
        browser = None
    pairing_paused_until = {}  # iPad id -> time
    try:
        files.serve_outbox()  # "Send to > iPad" in Explorer
    except OSError as e:
        print(f"Send to iPad unavailable: {e}")
    try:
        ipad_control.Controller()  # Ctrl+Alt+I: keyboard and trackpad -> iPad, over Bluetooth
    except Exception as e:  # missing Bluetooth libraries, no Tk...: the rest still works
        print(f"Controlling the iPad from the laptop is unavailable: {e!r}")
    try:
        while not stop.is_set():
            session = wait_for_ipad(stop, on_status, browser, pairing_paused_until)
            if session is None:
                return
            # setup and the reader run in a thread so the wait below can notice
            # `stop` and Ctrl+C, even while pairing waits for the user to type
            worker = threading.Thread(target=serve, daemon=True,
                                      args=(session, on_status, pairing_paused_until))
            worker.start()
            try:
                while not session.closed.wait(0.2) and not stop.is_set():
                    pass
            finally:
                # closing the socket ends handle(), which saves the layout and
                # removes the virtual screen
                session.close()
                worker.join(timeout=5)
            if getattr(session, "ready", False):
                on_status("iPad disconnected.")
    finally:
        if browser:
            browser.close()


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
