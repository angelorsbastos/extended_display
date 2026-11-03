"""Pairing and encryption for connecting to the iPad over Wi-Fi.

Over the USB cable only this laptop can reach the iPad, so that link is trusted
as it is. Over Wi-Fi any device on the network could pretend to be the iPad
(and receive the screen, or send keystrokes), so Wi-Fi connections need a key
both sides share:

Pairing, once (pair_over_wifi): an X25519 key exchange. The iPad commits to its
key (sends its hash) before seeing the laptop's, both derive a 6-digit code
from the two keys, the laptop shows it and the user types it on the iPad. Someone
in the middle would cause the codes to differ, with one 1-in-a-million try.
With the cable plugged in, pairing happens silently instead (pair_over_usb).

Every Wi-Fi connection (authenticate): both send a fresh random nonce and prove
with HMAC that they hold the key; per-connection keys come from HKDF. Every
message after that is sealed with ChaCha20-Poly1305 (see Cipher), so it can't
be read, changed, reordered or replayed.

The laptop keeps its keys in pairings.json, encrypted with the Windows account
(DPAPI); the iPad keeps them in its Keychain.
"""
import base64
import ctypes
import hashlib
import hmac
import json
import os
import pathlib
import socket
import uuid
from ctypes import wintypes

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

STORE = pathlib.Path(__file__).parent / "pairings.json"
LAPTOP_NAME = socket.gethostname()


class PairingFailed(Exception):
    pass


class NeedsPairing(Exception):
    """The iPad doesn't (or no longer) know this laptop: pair again."""


# ---- keys at rest: DPAPI, so only this Windows account can read them -------------

class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


crypt32 = ctypes.windll.crypt32
kernel32 = ctypes.windll.kernel32
kernel32.LocalFree.argtypes = [ctypes.c_void_p]


def _dpapi(function, data):
    buffer = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    blob_out = DATA_BLOB()
    if not function(ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def _load():
    try:
        return json.loads(STORE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save(data):
    STORE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def laptop_id():
    data = _load()
    if "laptop_id" not in data:
        data["laptop_id"] = str(uuid.uuid4())
        _save(data)
    return data["laptop_id"]


def key_for(ipad_id):
    entry = _load().get("ipads", {}).get(ipad_id)
    return _dpapi(crypt32.CryptUnprotectData, _unb64(entry["key"])) if entry else None


def remember(ipad_id, ipad_name, key):
    data = _load()
    data.setdefault("ipads", {})[ipad_id] = {
        "name": ipad_name, "key": _b64(_dpapi(crypt32.CryptProtectData, key))}
    _save(data)


def forget(ipad_id):
    data = _load()
    data.get("ipads", {}).pop(ipad_id, None)
    _save(data)


# ---- small crypto helpers ---------------------------------------------------------

def _b64(data):
    return base64.b64encode(data).decode()


def _unb64(text):
    return base64.b64decode(text)


def _hkdf(key_material, salt, info, length=32):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(key_material)


def _mac(key, label, *parts):
    return hmac.new(key, label + b"".join(parts), hashlib.sha256).digest()


def _raw(public_key):
    return public_key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def pairing_code(ipad_public, laptop_public, ipad_nonce, laptop_nonce):
    """The 6 digits the user types. Both sides compute it from the same values."""
    digest = hashlib.sha256(b"extend-display code v1" + ipad_public + laptop_public
                            + ipad_nonce + laptop_nonce).digest()
    return f"{int.from_bytes(digest[:4], 'big') % 1_000_000:06d}"


def _expect(session, kind):
    message = session.recv_json()
    if message.get("type") != kind:
        raise PairingFailed(message.get("message") or f"expected {kind}, got {message.get('type')}")
    return message


# ---- pairing ------------------------------------------------------------------------

def pair_over_usb(session, identity):
    """Cable plugged in: the link itself is trusted, so just hand the iPad a new key."""
    key = os.urandom(32)
    session.send_json({"type": "pair_usb", "laptop_id": laptop_id(), "laptop_name": LAPTOP_NAME,
                       "key": _b64(key)})
    _expect(session, "pair_usb_ok")
    remember(identity["ipad_id"], identity["ipad_name"], key)


def pair_over_wifi(session, identity, show_code, hide_code):
    """First Wi-Fi connection: key exchange checked with a 6-digit code (see module doc).
    show_code(code, ipad_name) / hide_code() put the code on the laptop's screen."""
    session.send_json({"type": "pair_hello", "laptop_id": laptop_id(), "laptop_name": LAPTOP_NAME})
    commit = _expect(session, "pair_commit")

    private = X25519PrivateKey.generate()
    laptop_public, laptop_nonce = _raw(private.public_key()), os.urandom(16)
    session.send_json({"type": "pair_key", "public": _b64(laptop_public), "nonce": _b64(laptop_nonce)})

    reveal = _expect(session, "pair_reveal")
    ipad_public, ipad_nonce = _unb64(reveal["public"]), _unb64(reveal["nonce"])
    if not hmac.compare_digest(hashlib.sha256(ipad_public + ipad_nonce).digest(),
                               _unb64(commit["commit"])):
        raise PairingFailed("the iPad's key doesn't match what it committed to")

    shared = private.exchange(X25519PublicKey.from_public_bytes(ipad_public))
    key = _hkdf(shared, ipad_nonce + laptop_nonce, b"extend-display pairing v1")
    show_code(pairing_code(ipad_public, laptop_public, ipad_nonce, laptop_nonce),
              identity["ipad_name"])
    try:
        answer = session.recv_json()  # comes once the user has typed the code
    finally:
        hide_code()
    if answer.get("type") != "pair_confirm":
        raise PairingFailed(answer.get("message") or "pairing was cancelled on the iPad")
    if not hmac.compare_digest(_unb64(answer["mac"]), _mac(key, b"ipad confirm")):
        raise PairingFailed("the code typed on the iPad was wrong")
    session.send_json({"type": "pair_done", "mac": _b64(_mac(key, b"laptop confirm"))})
    remember(identity["ipad_id"], identity["ipad_name"], key)


# ---- every Wi-Fi connection -----------------------------------------------------

def authenticate(session, ipad_id, key):
    """Prove to each other that both hold the pairing key, then encrypt everything."""
    laptop_nonce = os.urandom(16)
    session.send_json({"type": "auth_hello", "laptop_id": laptop_id(), "nonce": _b64(laptop_nonce)})
    reply = session.recv_json()
    if reply.get("type") == "auth_unknown":
        forget(ipad_id)
        raise NeedsPairing()
    if reply.get("type") != "auth_reply":
        raise PairingFailed(f"unexpected {reply.get('type')}")
    ipad_nonce = _unb64(reply["nonce"])
    if not hmac.compare_digest(_unb64(reply["mac"]), _mac(key, b"ipad auth", laptop_nonce, ipad_nonce)):
        raise PairingFailed("this device couldn't prove it is the paired iPad")
    session.send_json({"type": "auth_finish",
                       "mac": _b64(_mac(key, b"laptop auth", laptop_nonce, ipad_nonce))})
    keys = _hkdf(key, laptop_nonce + ipad_nonce, b"extend-display session v1", 64)
    session.cipher = Cipher(send_key=keys[:32], receive_key=keys[32:])


class Cipher:
    """ChaCha20-Poly1305 per message. Each direction has its own key and counts its
    messages; the count is the nonce, so a message can't be replayed or reordered.
    Sending and receiving share nothing, so they can run on different threads."""

    def __init__(self, send_key, receive_key):
        self._send, self._receive = ChaCha20Poly1305(send_key), ChaCha20Poly1305(receive_key)
        self._sent = self._received = 0

    @staticmethod
    def _nonce(counter):
        return bytes(4) + counter.to_bytes(8, "big")

    def seal(self, data):
        sealed = self._send.encrypt(self._nonce(self._sent), data, None)
        self._sent += 1
        return sealed

    def open(self, data):
        try:
            opened = self._receive.decrypt(self._nonce(self._received), data, None)
        except InvalidTag:
            raise OSError("a message failed its integrity check") from None
        self._received += 1
        return opened
