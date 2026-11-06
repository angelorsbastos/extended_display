"""The laptop side of Wingman: start once, then the iPad decides what to do.

Usage: python hub.py
Waits for the iPad (Wingman app open) over the USB cable or, once paired,
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
                    key {usage, down} (HID usage), type_text {text} (characters),
                    mouse_move {dx, dy},
                    mouse_button {button, down}, scroll {dx, dy}, clipboard,
                    log {text} (diagnostics, printed to the hub's log),
                    keyframe (re-send the current picture as a full keyframe),
                    watch_controls {on}, control {name, value} (see controls.apply),
                    save_shortcuts {shortcuts} (the whole list, see actions.save_shortcuts),
                    try_shortcut {shortcut} (run one without saving), list_apps,
                    app_icon {open} (-> app_icon {open, png}: base64, "" if none),
                    watch_stats {on} (the Dashboard is open: send stats every 2 s),
                    laptop_input {on} (switch Ctrl+Alt+I from the device),
                    prefs {extend_scale: 175/200/225, quality: smooth/balanced/sharp},
                    timer_done (the Dock's timer ran out: indicator and sound here),
                    sound {on} (play the laptop's sound on the iPad, see audio.py)
    laptop -> iPad: hello {shortcuts, laptop_name, laptop_input} (also after save_shortcuts),
                    bye (Disconnect chosen in the tray menu: the device stops asking to connect),
                    laptop_input {on} (Ctrl+Alt+I switched), apps {apps: [{name, open}]},
                    video_started {width, height},
                    audio_started {sample_rate, channels, config: base64 AudioSpecificConfig},
                    now_playing {now_playing}, artwork {title, jpeg: base64, "" if none},
                    error {message}, clipboard, stats {stats} (stats.read()),
                    controls {controls} (see controls.state)
    clipboard (both ways): {kind: "text", text} or {kind: "image", png: base64};
                           from the iPad also paste: true to press Ctrl+V after
"""
import base64
import ctypes
import json
import socket
import struct
import subprocess
import threading
import time
import traceback
import winsound

import numpy as np
from av.video.frame import PictureType
from windows_capture import WindowsCapture

import actions
import audio
import clipboard
import controls
import discovery
import files
import icons
import inputs
import ipad_control
import layout
import monitors
import nowplaying
import osd
import secure
import stats
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
# the device's Settings can change both: Extend text size (scale) and picture quality
EXTEND_SCALES = (175, 200, 225)
QUALITY = {"smooth": 0.6, "balanced": 1, "sharp": 1.6}  # times BIT_RATE


class Session:
    """One connection to the iPad. Safe to send from several threads.
    transport is "usb" or "wifi"; once `cipher` is set (Wi-Fi, after login),
    everything is sealed both ways and unsealed messages are refused."""

    def __init__(self, sock, transport="usb"):
        self.sock = sock
        self.transport = transport
        self.key = None      # which connection this is, for the hub's list (find_devices)
        self.address = None  # Tailscale address, for remote ones
        self.name = "the iPad"  # set from the device's identity
        self.device = "ipad"    # or "iphone"
        self.prefs = {}         # the device's Settings that matter here (prefs message)
        self.ready = False
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
                                          bit_rate=int(BIT_RATE[self.session.transport]
                                                       * QUALITY.get(self.session.prefs.get("quality"), 1)))
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
    """Tell the iPad whenever the song or play/pause state changes, and send
    the song's cover once per song (the Dock can use it as its background)."""
    last = "unset"
    last_song = None
    while not session.closed.wait(1):
        current = nowplaying.current()
        if current != last:
            try:
                session.send_json({"type": "now_playing", "now_playing": current})
                song = (current["title"], current["artist"]) if current else None
                if song != last_song:
                    last_song = song
                    cover = nowplaying.artwork() if song else None
                    session.send_json({"type": "artwork", "title": song[0] if song else "",
                                       "jpeg": cover or ""})
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

    def files_received(self, paths):
        """Files the device sent: on the clipboard too, ready to paste."""
        try:
            clipboard.write_files(paths)
        except OSError as e:
            print(f"clipboard: couldn't put the files on it: {e}")
            return
        self.ours = clipboard.sequence_number()  # not sent back to the device
        print(f"clipboard <- iPad ({len(paths)} file{'s' if len(paths) > 1 else ''})")

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
            osd.show("paste", f"Pasted from the {self.session.name}")


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


MEDIA_NOTES = {"play_pause": ("play", "Play or pause"), "next": ("next", "Next track"),
               "previous": ("previous", "Previous track")}


def note_control(name, value):
    """Show on the laptop's screen what a device just changed (osd.py)."""
    on = bool(value)
    if name in ("volume", "brightness"):
        osd.show(name, name.capitalize(), int(value))
    elif name == "muted":
        osd.show("mute" if on else "volume", "Sound off" if on else "Sound on")
    elif name == "mic_muted":
        osd.show("mic_off" if on else "mic", "Microphone off" if on else "Microphone on")
    elif name == "dark_mode":
        osd.show("dark", f"Dark mode {'on' if on else 'off'}")
    elif name in ("wifi", "bluetooth"):
        osd.show(name, f"{'Wi-Fi' if name == 'wifi' else 'Bluetooth'} {'on' if on else 'off'}")
    elif name == "keep_awake":
        osd.show("awake", "Staying awake" if on else "Can sleep again")
    elif name == "power_plan":
        plans, _ = controls._power_plans()
        plan = next((p["name"] for p in plans if p["id"] == value), "changed")
        osd.show("plan", f"Power plan: {plan}")
    elif name in ("lock", "sleep", "restart", "shutdown"):
        words = {"lock": "Locking", "sleep": "Going to sleep", "restart": "Restarting", "shutdown": "Shutting down"}
        osd.show("lock" if name == "lock" else "power", words[name])


class StatsWatch:
    """While the iPad shows its Dashboard, send temperatures, fans, usage and
    battery health every 2 s (see stats.py). Only then: asking the NVIDIA
    driver wakes a sleeping GPU."""

    def __init__(self, session):
        self.session = session
        self.on = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def watch(self, on):
        (self.on.set if on else self.on.clear)()

    def _run(self):
        while not self.session.closed.is_set():
            if not self.on.wait(0.5):
                continue
            started = time.time()
            try:
                self.session.send_json({"type": "stats", "stats": stats.read()})
            except OSError:
                return
            time.sleep(max(0.0, 2 - (time.time() - started)))


_touchscreen = None


def touchscreen():
    """Windows allows touch injection to be set up once per process."""
    global _touchscreen
    if _touchscreen is None:
        _touchscreen = inputs.Touchscreen()
    return _touchscreen


def create_extend_screen(displays, portrait=False, scale=EXTEND_SCALE):
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
    monitors.set_scale(new["name"], scale)
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
    # the whole definitions: the iPad edits them (save_shortcuts)
    session.send_json({"type": "hello", "shortcuts": shortcuts, "laptop_name": socket.gethostname(),
                       "laptop_input": ipad_control.is_active()})
    threading.Thread(target=send_now_playing, args=(session,), daemon=True).start()

    clip = ClipboardSync(session)
    controls_watch = ControlsWatch(session)
    stats_watch = StatsWatch(session)
    touch = touchscreen()
    receiver = files.Receiver(session)
    receiver.on_saved = clip.files_received
    sender = files.Sender(session)

    def laptop_input_changed(active):  # Ctrl+Alt+I switched, from the laptop or a device
        try:
            session.send_json({"type": "laptop_input", "on": active})
        except OSError:
            pass
    ipad_control.listeners.add(laptop_input_changed)
    # Explorer's "Send to > iPad": the iPad when there is one, else the iPhone
    files.set_active_sender(sender, only_if=None if session.device == "ipad" else files.NOBODY)

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
            scale = session.prefs.get("extend_scale")
            extend_index, extend_name, extend_setup = create_extend_screen(
                displays, portrait, scale if scale in EXTEND_SCALES else EXTEND_SCALE)
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
        osd.show("speaker", f"Sound also on the {session.name}" if on else "Sound on the laptop only")

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
            elif kind == "type_text":
                inputs.type_text(msg.get("text", ""))
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
            elif kind == "watch_stats":
                stats_watch.watch(bool(msg.get("on")))
            elif kind == "laptop_input":
                ipad_control.request(bool(msg.get("on")))
            elif kind == "prefs":  # used from the next Extend / Mirror on
                session.prefs = {k: msg.get(k) for k in ("extend_scale", "quality")}
            elif kind == "timer_done":  # the Dock's timer ran out: say so here too
                osd.show("timer", f"Time's up on the {session.name}")
                winsound.MessageBeep(winsound.MB_ICONASTERISK)  # Windows' own soft sound
            elif kind == "sound":
                set_sound(bool(msg.get("on")))
            elif kind == "control":
                print(f"control: {msg.get('name')} = {msg.get('value')}")
                try:
                    if msg.get("name") in ("lock", "sleep", "restart", "shutdown"):
                        note_control(msg.get("name"), True)  # before: afterwards there's no screen
                        time.sleep(0.8)
                    controls.apply(msg.get("name"), msg.get("value"))
                    if msg.get("name") not in ("lock", "sleep", "restart", "shutdown"):
                        note_control(msg.get("name"), msg.get("value"))
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
                    osd.show("shortcut", by_id[msg["id"]]["title"])
                except OSError as e:  # e.g. the app it opens isn't installed
                    print(f"shortcut {msg['id']} failed: {e}")
            elif kind == "media" and msg.get("action") in actions.MEDIA_KEYS:
                actions.media(msg["action"])
                if msg["action"] in MEDIA_NOTES:
                    osd.show(*MEDIA_NOTES[msg["action"]])
            elif kind == "save_shortcuts":
                try:
                    # an app, file or folder gets its own icon, unless the iPad chose a symbol ("")
                    for wanted in msg.get("shortcuts") or []:
                        if isinstance(wanted, dict) and wanted.get("open") and "image" not in wanted:
                            wanted["image"] = icons.for_target(wanted["open"], controls._worker) or ""
                    shortcuts = actions.save_shortcuts(msg.get("shortcuts"))
                except (ValueError, OSError) as e:
                    session.send_json({"type": "error", "message": f"Couldn't save the shortcuts: {e}"})
                else:
                    by_id.clear()
                    by_id.update({s["id"]: s for s in shortcuts})
                    print(f"shortcuts saved ({len(shortcuts)})")
                session.send_json({"type": "hello", "shortcuts": actions.load_shortcuts()})
            elif kind == "try_shortcut":
                try:
                    tried = actions.check_shortcut(msg.get("shortcut"))
                    actions.run_shortcut(tried)
                    osd.show("shortcut", f"Trying {tried['title']}")
                except (ValueError, OSError) as e:
                    session.send_json({"type": "error", "message": f"That didn't work: {e}"})
            elif kind == "app_icon":  # the shortcut editor's app list, one icon at a time
                def send_icon(target=str(msg.get("open", ""))):
                    try:
                        png = icons.for_target(target, controls._worker)
                        session.send_json({"type": "app_icon", "open": target, "png": png or ""})
                    except OSError:
                        pass
                threading.Thread(target=send_icon, daemon=True).start()
            elif kind == "list_apps":
                def send_apps():
                    try:
                        session.send_json({"type": "apps", "apps": actions.start_apps()})
                    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
                        print(f"listing apps failed: {e}")
                threading.Thread(target=send_apps, daemon=True).start()  # takes a few seconds
    except Exception:
        traceback.print_exc()
    finally:
        stop_video()
        if sound:
            sound.stop()
        receiver.close()
        ipad_control.listeners.discard(laptop_input_changed)
        files.set_active_sender(None, only_if=sender)
        if displays:
            displays.close()
        session.close()


class CodePopup:
    """Shows the 6-digit pairing code on the laptop (osd.show_code), and closes it again."""

    def show(self, code, ipad_name):
        print(f"pairing code for {ipad_name}: {code}")
        osd.show_code(code, ipad_name)

    def hide(self):
        osd.hide_code()


class AlreadyConnected(Exception):
    """This device is already connected another way (e.g. Wi-Fi and Tailscale)."""


class Refused(AlreadyConnected):
    """The device declined this connection: its settings turn this way off, or
    set it to "Ask" and nobody has tapped Connect yet."""


REFUSED_RETRY = 10  # seconds before trying a way the device turned off again
ASK_RETRY = 2       # ...or one waiting for a tap on Connect: soon, so the tap feels instant


class Devices:
    """Which iPads / iPhones are connected, so several can be served at once but
    each only once. A device is "claimed" by the session that serves it: a
    Wi-Fi or Tailscale connection to a device that's already claimed is dropped
    right after it says who it is (before login, so the device never switches to
    it); the cable may take over from Wi-Fi, as the app itself prefers it."""

    def __init__(self):
        self.lock = threading.Lock()
        self.claims = {}         # device id -> Session
        self.remote_ids = {}     # Tailscale address -> device id, learned on the first try
        self.paused_until = {}   # device id or "remote <address>" -> time (pairing/retry back-off)
        self.asking = {}         # connection key -> (device name, when), waiting for a tap on Connect

    def claim(self, device_id, session):
        with self.lock:
            other = self.claims.get(device_id)
            if other is not None and other is not session and not other.closed.is_set() \
                    and session.transport != "usb":
                return False
            self.claims[device_id] = session
            return True

    def claimed(self, device_id):
        with self.lock:
            session = self.claims.get(device_id)
            return session is not None and not session.closed.is_set()


def find_devices(devices, busy, on_status, browser):
    """New connections to iPads / iPhones that aren't connected yet: over the cable,
    on the same Wi-Fi (Bonjour), or through Tailscale. `busy` = keys of the
    connections already running. Returns (new sessions, why nothing was found)."""
    found, problems = [], []
    # devices waiting for a tap on Connect answer every few seconds; one that
    # stopped answering (app closed, out of reach) isn't waiting any more
    for key, (_, when) in list(devices.asking.items()):
        if time.time() - when > 4 * ASK_RETRY + (REMOTE_RETRY if key.startswith("remote") else 0):
            del devices.asking[key]
    try:
        cabled = usbmux.list_devices()
    except OSError:
        cabled = []
        problems.append("Apple's USB service isn't running (install Apple Devices or iTunes).")
    for device in cabled:
        key = f"usb {device['DeviceID']}"
        if key in busy or devices.paused_until.get(key, 0) > time.time():
            continue
        try:
            session = Session(usbmux.connect(device["DeviceID"], PORT), "usb")
        except usbmux.UsbmuxError:
            problems.append("A device is plugged in: open the Wingman app on it.")
            continue
        session.key = key
        found.append(session)

    # explain the Wi-Fi side as precisely as possible: the user can't see it otherwise
    for ipad in browser.ipads() if browser else []:
        key = f"wifi {ipad['id']}"
        if key in busy or devices.claimed(ipad["id"]) or devices.paused_until.get(key, 0) > time.time():
            continue
        asking = key in devices.asking  # tried a moment ago: no need to announce it again
        unpaired = secure.key_for(ipad["id"]) is None
        wait = devices.paused_until.get(ipad["id"], 0) - time.time()
        if unpaired and wait > 0:  # pairing was just cancelled; don't pop it up right away
            problems.append(f"{ipad['name']}: pairing didn't finish. Offering it again in {int(wait) + 1} s.")
            continue
        try:
            sock = socket.create_connection((ipad["address"], ipad["port"]), timeout=3)
        except OSError as e:
            problems.append(f"Found {ipad['name']} on Wi-Fi at {ipad['address']} but couldn't connect "
                            f"({e}). On it, check Settings > Privacy & Security > Local Network > "
                            "Wingman.")
            continue
        network_socket(sock)
        if not asking:
            on_status(f"Found {ipad['name']} on Wi-Fi, connecting…")
        session = Session(sock, "wifi")
        session.key = key
        devices.claim(ipad["id"], session)  # so Tailscale doesn't race it to the same device
        found.append(session)

    # away from home: through Tailscale
    peers, remote_problem = tailnet.ipads()
    for peer in peers:
        key = f"remote {peer['address']}"
        known = devices.remote_ids.get(peer["address"])
        if key in busy or (known and devices.claimed(known)) \
                or devices.paused_until.get(key, 0) > time.time():
            continue  # connected another way, or just failed: don't retry every second
        devices.paused_until[key] = time.time() + REMOTE_RETRY
        try:
            sock = socket.create_connection((peer["address"], IPAD_WIFI_PORT), timeout=5)
        except OSError as e:
            remote_problem = f"{peer['name']} is online in Tailscale but didn't answer ({e}). " \
                             "Is Wingman open on it?"
            continue
        network_socket(sock)
        session = Session(sock, "remote")
        session.key, session.address = key, peer["address"]
        found.append(session)

    searching = ", ".join(browser.networks) if browser else "nothing (no network)"
    if devices.asking:
        names = sorted({name for name, _ in devices.asking.values()})
        problems.insert(0, f"{' and '.join(names)} found: tap Connect in Wingman on it.")
    reason = problems[0] if problems else (
        "Looking for the iPad / iPhone: plug in the cable, or open Wingman on the same Wi-Fi "
        f"(searching on {searching}; guest networks usually block this)."
        + (f" Remote: {remote_problem}." if remote_problem else ""))
    return found, reason


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


def set_up_link(session, on_status, devices):
    """Before the normal conversation: learn who the device is, pair if needed, and on
    Wi-Fi log in and switch to encryption. Raises if the link can't be trusted,
    AlreadyConnected if that device is already served another way."""
    pairing_paused_until = devices.paused_until
    session.sock.settimeout(3 if session.transport != "remote" else 10)  # internet is slower
    # every app version says who it is first; one that stays silent (e.g. the app
    # suspended in the background) isn't ready: give up and try again later
    identity = session.recv_json()
    if identity.get("type") != "identity":
        raise OSError(f"expected identity, got {identity.get('type')}")

    if identity:
        ipad_id, name = identity["ipad_id"], identity.get("ipad_name", "the iPad")
        session.name = name
        session.device = identity.get("device", "ipad")  # apps before the iPhone version: iPads
        if getattr(session, "address", None):
            devices.remote_ids[session.address] = ipad_id
        refused = identity.get("refused")
        if refused:
            asks = refused == "ask"
            devices.paused_until[session.key] = time.time() + (ASK_RETRY if asks else REFUSED_RETRY)
            if asks:
                devices.asking[session.key] = (name, time.time())
            else:
                devices.asking.pop(session.key, None)
            raise Refused(name)
        devices.asking.pop(session.key, None)
        if not devices.claim(ipad_id, session):
            raise AlreadyConnected(name)
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


def serve(session, on_status, devices):
    how = {"usb": "the cable", "wifi": "Wi-Fi", "remote": "Tailscale (remote)"}[session.transport]
    try:
        set_up_link(session, on_status, devices)
    except AlreadyConnected:
        session.close()  # quietly: it's connected already, another way
        return
    except socket.timeout:
        # the app is there but silent (e.g. suspended in the background): quietly
        # try again in a few seconds
        devices.paused_until[session.key] = time.time() + 5
        session.close()
        return
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
    on_status(f"{session.name} connected over {how}.")
    handle(session)


# the devices being served right now, for the tray menu: connection key -> Session
live = {}
_live_lock = threading.Lock()


def connected_devices():
    """[(key, name, device, transport)] of the devices connected right now."""
    with _live_lock:
        return [(key, s.name, getattr(s, "device", "ipad"), s.transport)
                for key, s in live.items() if getattr(s, "ready", False) and not s.closed.is_set()]


def disconnect(key):
    """The tray's Disconnect: tell the device (it stops asking to connect, like
    its own Disconnect button) and hang up."""
    with _live_lock:
        session = live.get(key)
    if session is None:
        return
    try:
        session.send_json({"type": "bye"})
    except OSError:
        pass
    threading.Timer(0.5, session.close).start()  # let the bye arrive first


def run(stop, on_status=print):
    """Serve iPads and iPhones until `stop` is set: each connected device gets its
    own Session and thread, and the search for more goes on meanwhile.
    on_status gets short status texts."""
    try:
        browser = discovery.Watcher()
    except OSError as e:  # e.g. no network at all: the cable still works
        print(f"Wi-Fi discovery unavailable: {e}")
        browser = None
    devices = Devices()
    try:
        files.serve_outbox()  # "Send to > iPad" in Explorer
    except OSError as e:
        print(f"Send to iPad unavailable: {e}")
    try:
        ipad_control.start()  # Ctrl+Alt+I: keyboard and trackpad -> iPad, over Bluetooth
    except Exception as e:  # missing Bluetooth libraries, no Tk...: the rest still works
        print(f"Controlling the iPad from the laptop is unavailable: {e!r}")
    running = {}  # connection key -> (Session, thread)
    shown = None
    try:
        while not stop.is_set():
            for key, (session, worker) in list(running.items()):
                if session.closed.is_set():
                    worker.join(timeout=5)
                    del running[key]
                    with _live_lock:
                        live.pop(key, None)
                    if getattr(session, "ready", False):
                        on_status(f"{session.name} disconnected.")
                        shown = None
            new, reason = find_devices(devices, set(running), on_status, browser)
            for session in new:
                # setup and the reader run in their own thread, so this loop keeps
                # looking (and notices `stop`), even while pairing waits for typing
                worker = threading.Thread(target=serve, daemon=True, args=(session, on_status, devices))
                worker.start()
                running[session.key] = (session, worker)
                with _live_lock:
                    live[session.key] = session
            ready = [s for s, _ in running.values() if getattr(s, "ready", False)]
            status = ("Connected: " + ", ".join(sorted(s.name for s in ready))) if ready else reason
            if status != shown and not new:
                on_status(status)
                shown = status
            stop.wait(1)
    finally:
        # closing the sockets ends handle(), which saves the layout and removes
        # the virtual screen
        for session, worker in running.values():
            session.close()
        for session, worker in running.values():
            worker.join(timeout=5)
        if browser:
            browser.close()


def main():
    stop = threading.Event()
    print("Wingman hub. Ctrl+C to quit.")
    try:
        run(stop)
    except KeyboardInterrupt:
        stop.set()
        print("Stopped.")


if __name__ == "__main__":
    main()
