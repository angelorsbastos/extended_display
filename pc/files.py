"""Files between the laptop and the iPad, both ways.

On the wire (either direction):
  file_start {id, name, size}   JSON
  type 5 messages               [u32 big-endian id][up to CHUNK bytes of the file]
  file_end {id}                 JSON (or file_cancel {id})
The receiver answers file_saved {id, name} when the file is complete.

iPad -> laptop: saved in the laptop's Downloads folder.
laptop -> iPad: "Send to > iPad" in Explorer runs sendfile.py, which hands the
paths to the running hub through a localhost port (OUTBOX_PORT).
"""
import ctypes
import itertools
import json
import pathlib
import queue
import re
import shutil
import socket
import struct
import tempfile
import threading
import time
import uuid

import osd

MSG_FILE = 5
CHUNK = 64 * 1024
OUTBOX_PORT = 7010  # localhost only: sendfile.py -> hub
# cap file data so the picture keeps flowing next to it (bytes per second; None = no cap)
RATE = {"usb": None, "wifi": 6_000_000, "remote": 1_000_000}


def downloads_folder():
    """The user's Downloads folder, even if they moved it."""
    FOLDERID_Downloads = uuid.UUID("374DE290-123F-4565-9164-39C4925E467B")
    guid = (ctypes.c_byte * 16).from_buffer_copy(FOLDERID_Downloads.bytes_le)
    path = ctypes.c_wchar_p()
    if ctypes.windll.shell32.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(path)) == 0:
        folder = path.value
        ctypes.windll.ole32.CoTaskMemFree(path)
        return pathlib.Path(folder)
    return pathlib.Path.home() / "Downloads"


def safe_name(name):
    """A plain file name from whatever the iPad sends: no folders, no characters
    Windows forbids, no reserved names like CON."""
    name = pathlib.PureWindowsPath(str(name).replace("/", "\\")).name
    name = re.sub(r'[<>:"|?*\x00-\x1f]', "_", name).strip(" .")
    if not name or name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)),
                                                    *(f"LPT{i}" for i in range(10))}:
        name = f"file {time.strftime('%Y-%m-%d %H.%M.%S')}{pathlib.PurePath(name).suffix}"
    return name[:200]


def unique_path(folder, name):
    """folder/name, or folder/"name (2).ext" etc. if that's taken."""
    path = folder / name
    stem, suffix = path.stem, path.suffix
    for n in itertools.count(2):
        if not path.exists() and not path.with_name(path.name + ".part").exists():
            return path
        path = folder / f"{stem} ({n}){suffix}"


class Receiver:
    """Saves files the iPad sends into Downloads. Written as "name.part" and
    renamed when complete, so a half-sent file never looks finished."""

    BATCH_SECONDS = 5  # files arriving this close together go on the clipboard together

    def __init__(self, session):
        self.session = session
        self.incoming = {}  # id -> {file, path, size, got}
        # called with every file saved in the latest batch (the hub puts them on the clipboard)
        self.on_saved = None
        self.batch, self.batch_at = [], 0.0

    def start(self, message):
        try:
            transfer_id, size = int(message["id"]), int(message["size"])
            path = unique_path(downloads_folder(), safe_name(message.get("name", "")))
            handle = open(path.with_name(path.name + ".part"), "wb")
        except (KeyError, ValueError, OSError) as e:
            print(f"file from iPad refused: {e}")
            self.session.send_json({"type": "file_failed", "id": message.get("id"),
                                    "message": f"The laptop couldn't save it: {e}"})
            return
        self.incoming[transfer_id] = {"file": handle, "path": path, "size": size, "got": 0}
        print(f"file <- iPad: {path.name} ({size / 1e6:.1f} MB)")

    def data(self, payload):
        (transfer_id,) = struct.unpack(">I", payload[:4])
        transfer = self.incoming.get(transfer_id)
        if transfer:
            transfer["file"].write(payload[4:])
            transfer["got"] += len(payload) - 4

    def end(self, message):
        transfer = self.incoming.pop(message.get("id"), None)
        if not transfer:
            return
        transfer["file"].close()
        part = transfer["path"].with_name(transfer["path"].name + ".part")
        if transfer["got"] != transfer["size"]:
            part.unlink(missing_ok=True)
            print(f"file {transfer['path'].name}: got {transfer['got']} of {transfer['size']} bytes, dropped")
            self.session.send_json({"type": "file_failed", "id": message["id"],
                                    "message": "Only part of the file arrived."})
            return
        part.replace(transfer["path"])
        print(f"saved {transfer['path']}")
        osd.show("file", f"Saved {transfer['path'].name} to Downloads")
        self.session.send_json({"type": "file_saved", "id": message["id"], "name": transfer["path"].name})
        if time.time() - self.batch_at > self.BATCH_SECONDS:
            self.batch = []
        self.batch.append(transfer["path"])
        self.batch_at = time.time()
        if self.on_saved:
            self.on_saved(list(self.batch))

    def cancel(self, message):
        self._drop(self.incoming.pop(message.get("id"), None))

    def close(self):
        """The iPad disconnected: throw away anything half-received."""
        for transfer in self.incoming.values():
            self._drop(transfer)
        self.incoming.clear()

    @staticmethod
    def _drop(transfer):
        if transfer:
            transfer["file"].close()
            transfer["path"].with_name(transfer["path"].name + ".part").unlink(missing_ok=True)


class Sender:
    """Sends files to the iPad one after the other, on its own thread.
    Folders are zipped first."""

    def __init__(self, session):
        self.session = session
        self.queue = queue.Queue()
        self.ids = itertools.count(1)
        threading.Thread(target=self._run, name="file-sender", daemon=True).start()

    def send(self, path):
        self.queue.put(pathlib.Path(path))

    def _run(self):
        while not self.session.closed.is_set():
            try:
                path = self.queue.get(timeout=1)
            except queue.Empty:
                continue
            try:
                self._send(path)
            except OSError as e:
                if self.session.closed.is_set():
                    return
                print(f"sending {path.name} failed: {e}")

    def _send(self, path):
        temp = None
        if path.is_dir():
            temp = pathlib.Path(tempfile.mkdtemp())
            path = pathlib.Path(shutil.make_archive(str(temp / path.name), "zip", path))
        try:
            transfer_id = next(self.ids)
            size = path.stat().st_size
            rate = RATE[self.session.transport]
            self.session.send_json({"type": "file_start", "id": transfer_id, "name": path.name, "size": size})
            print(f"file -> iPad: {path.name} ({size / 1e6:.1f} MB)")
            started, sent = time.time(), 0
            with open(path, "rb") as f:
                while chunk := f.read(CHUNK):
                    if self.session.closed.is_set():
                        return
                    self.session.send(MSG_FILE, struct.pack(">I", transfer_id) + chunk)
                    sent += len(chunk)
                    if rate:
                        time.sleep(max(0.0, sent / rate - (time.time() - started)))
            self.session.send_json({"type": "file_end", "id": transfer_id})
        finally:
            if temp:
                shutil.rmtree(temp, ignore_errors=True)


# ---- the outbox: "Send to > iPad" -> the running hub -------------------------------

_active = {"sender": None}  # the connected iPad's Sender, set by hub.handle
NOBODY = object()  # for set_active_sender(only_if=NOBODY): only if no device has it yet


def set_active_sender(sender, only_if=None):
    """Make `sender` the one "Send to > iPad" uses. With only_if, change it only
    while that one is still active (a newer connection may have replaced it);
    only_if=NOBODY: only if nobody is."""
    current = _active["sender"]
    if only_if is None or current is only_if or (only_if is NOBODY and current is None):
        _active["sender"] = sender


def serve_outbox():
    """Accept paths from sendfile.py (one JSON line each connection) and queue
    them for the iPad. Runs for the life of the hub."""
    server = socket.create_server(("127.0.0.1", OUTBOX_PORT))
    threading.Thread(target=_outbox_loop, args=(server,), name="outbox", daemon=True).start()


def _outbox_loop(server):
    while True:
        conn, _ = server.accept()
        with conn:
            try:
                conn.settimeout(5)
                request = json.loads(conn.makefile("rb").readline())
                paths = [pathlib.Path(p) for p in request.get("paths", [])]
                sender = _active["sender"]
                if sender is None:
                    reply = {"error": "The iPad isn't connected. Open Wingman on it first."}
                elif missing := [p.name for p in paths if not p.exists()]:
                    reply = {"error": f"Not found: {', '.join(missing)}"}
                else:
                    for path in paths:
                        sender.send(path)
                    reply = {"ok": True}
                conn.sendall(json.dumps(reply).encode() + b"\n")
            except (OSError, ValueError) as e:
                print(f"outbox: {e}")
