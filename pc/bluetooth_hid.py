"""The laptop as a Bluetooth keyboard + trackpad (+ mouse) for the iPad (HID over GATT).

Windows lets an app publish the HID service; the iPad pairs with the laptop
(under its Windows computer name in Settings > Bluetooth) and uses it like any Bluetooth keyboard and
trackpad. What made the iPad accept it (a bare HID service was paired but never
used): boot keyboard/mouse reports, a keyboard LED output report and a Battery
service next to it. Windows refuses the Device Information service ("disabled
by policy"); the iPad manages without.

The trackpad is described the way Windows Precision Touchpads describe
themselves (Digitizer page, Touch Pad: up to 5 fingers with confidence, tip,
contact id, X, Y; scan time, contact count, button; feature reports for the
maximum contacts and input mode). The iPad treats it as a real multi-touch
trackpad: its own pointer, scrolling and gestures, from the raw fingers on the
laptop's touchpad (send_touch). Its Y axis points up, unlike Windows'.

Windows keeps restarting the advertisement with a new private address, so the
iPad lists the laptop several times under Other Devices; once paired it finds
it again by its identity.

All Bluetooth work runs on one asyncio loop in its own thread. send_keys(),
move() and set_buttons() may be called from any thread (the input hooks).
"""
import asyncio
import struct
import threading
import time
import uuid

from winrt.windows.devices.bluetooth import BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCharacteristicProperties as P, GattLocalCharacteristicParameters, GattLocalDescriptorParameters,
    GattProtectionLevel, GattServiceProvider, GattServiceProviderAdvertisingParameters, GattWriteOption)
from winrt.windows.storage.streams import DataWriter

MOUSE_INTERVAL = 0.008  # seconds between mouse reports: about one per Bluetooth connection event
TOUCH_INTERVAL = 0.011  # at most one finger frame per connection event (the iPad's is 15 ms)
FINGERS = 5
TOUCH_MAX = 4095  # finger coordinates 0..TOUCH_MAX
PAD_SIZE_MM = (120, 70)  # the trackpad's size as told to the iPad
TOUCH_REPORT_SIZE = FINGERS * 6 + 4


def _finger():
    w, h = PAD_SIZE_MM[0] * 10, PAD_SIZE_MM[1] * 10  # in 0.1 mm (unit cm, exponent -2)
    return [
        0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,                          # Finger (logical collection)
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
        0x09, 0x47, 0x81, 0x02,                                      # Confidence
        0x09, 0x42, 0x81, 0x02,                                      # Tip Switch
        0x95, 0x06, 0x81, 0x03,                                      # padding
        0x75, 0x08, 0x25, 0x7F, 0x95, 0x01, 0x09, 0x51, 0x81, 0x02,  # Contact Identifier
        0x05, 0x01, 0x15, 0x00, 0x26, TOUCH_MAX & 0xFF, TOUCH_MAX >> 8,
        0x75, 0x10, 0x55, 0x0E, 0x65, 0x11, 0x35, 0x00,
        0x46, w & 0xFF, w >> 8, 0x09, 0x30, 0x81, 0x02,              # X
        0x46, h & 0xFF, h >> 8, 0x09, 0x31, 0x81, 0x02,              # Y
        0xC0,
    ]


# The iPad gets keyboard + trackpad, or keyboard + mouse (laptops without a
# precision touchpad), never both: with a mouse in the map the iPad ignores the
# trackpad and waits for mouse input.
KEYBOARD_MAP = [
    # keyboard, report id 1: input = modifiers, reserved, 6 keys; output = 5 LEDs + padding
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0,
]
MOUSE_MAP = [
    # mouse, report id 2: buttons, x, y, wheel, horizontal scroll (AC Pan)
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0,
]
TRACKPAD_MAP = [
    # trackpad, report id 3 (input) and 4 (feature: max contacts, pad type)
    0x05, 0x0D, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x03,
    *[b for _ in range(FINGERS) for b in _finger()],
    0x05, 0x0D, 0x55, 0x0C, 0x66, 0x01, 0x10, 0x47, 0xFF, 0xFF, 0x00, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00,
    0x75, 0x10, 0x95, 0x01, 0x09, 0x56, 0x81, 0x02,                  # Scan Time (100 µs)
    0x09, 0x54, 0x25, 0x7F, 0x95, 0x01, 0x75, 0x08, 0x81, 0x02,      # Contact Count
    0x05, 0x09, 0x09, 0x01, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,  # Button 1 (the click)
    0x95, 0x07, 0x81, 0x03,
    0x05, 0x0D, 0x85, 0x04, 0x09, 0x55, 0x09, 0x59, 0x75, 0x04, 0x95, 0x02, 0x25, 0x0F, 0xB1, 0x02,
    0xC0,
    # trackpad configuration, report ids 5 (input mode) and 6 (surface/button switch)
    0x05, 0x0D, 0x09, 0x0E, 0xA1, 0x01, 0x85, 0x05, 0x09, 0x22, 0xA1, 0x02,
    0x09, 0x52, 0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, 0xC0,
    0x09, 0x22, 0xA1, 0x00, 0x85, 0x06, 0x09, 0x57, 0x09, 0x58, 0x75, 0x01, 0x95, 0x02, 0x25, 0x01,
    0xB1, 0x02, 0x95, 0x06, 0xB1, 0x03, 0xC0,
    0xC0,
]


def _ble(short):
    return uuid.UUID(f"0000{short:04x}-0000-1000-8000-00805f9b34fb")


def _buffer(data):
    writer = DataWriter()
    writer.write_bytes(bytes(data))
    return writer.detach_buffer()


def _clamp(value):
    return max(-127, min(127, value))


class BluetoothHID:
    """on_state(state, detail) is called (from the Bluetooth thread) with state
    "off", "starting", "waiting" (advertising, iPad not using it yet),
    "connected" (the iPad listens to the keyboard), or "error" with a reason."""

    def __init__(self, on_state):
        self.on_state = on_state
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, name="bluetooth", daemon=True).start()
        self.providers = []
        self.keyboard = self.mouse = None
        self.keys = asyncio.Queue()  # only touched on the loop
        self.lock = threading.Lock()
        self.pending = {"buttons": 0, "dx": 0, "dy": 0, "wheel": 0, "pan": 0}
        self.buttons_sent = 0
        self.touch = None       # trackpad report characteristic
        self.touch_latest = None  # (touching, clicked) not sent yet
        self.slots = {}         # laptop contact id -> (finger slot 0..4, x, y last sent)
        self.touch_sent_at = 0.0
        self.connection_request = None  # keeps the faster-connection preference alive
        self.sender = None

    # ---- from any thread ---------------------------------------------------------

    def start(self, trackpad=True):
        """Keyboard + trackpad (send_touch), or keyboard + mouse (move/set_buttons)."""
        asyncio.run_coroutine_threadsafe(self._start(trackpad), self.loop)

    def stop(self):
        asyncio.run_coroutine_threadsafe(self._stop(), self.loop)

    @property
    def connected(self):
        keyboard = self.keyboard
        return keyboard is not None and keyboard.subscribed_clients.size > 0

    def send_keys(self, modifiers, usages):
        """The keys held right now: a modifier bit mask and up to 6 key usages."""
        report = bytes([modifiers, 0, *(list(usages)[:6] + [0] * 6)[:6]])
        self.loop.call_soon_threadsafe(self.keys.put_nowait, report)

    def move(self, dx=0, dy=0, wheel=0, pan=0):
        with self.lock:
            self.pending["dx"] += dx
            self.pending["dy"] += dy
            self.pending["wheel"] += wheel
            self.pending["pan"] += pan

    def set_buttons(self, buttons):
        """Bit mask: 1 left, 2 right, 4 middle."""
        with self.lock:
            self.pending["buttons"] = buttons

    def send_touch(self, touching, clicked):
        """The fingers on the laptop's touchpad right now ({contact id: (x, y)},
        0..1 with y downwards) and whether it's pressed down. Only the newest
        picture is kept: frames come faster than Bluetooth can deliver them."""
        with self.lock:
            self.touch_latest = (dict(touching), bool(clicked))

    # ---- on the loop -------------------------------------------------------------

    async def _start(self, trackpad):
        if self.providers:
            return
        self.on_state("starting", None)
        report_map = bytes(KEYBOARD_MAP + (TRACKPAD_MAP if trackpad else MOUSE_MAP))
        try:
            hid = await self._provider(0x1812)
            s = hid.service
            await self._add(s, 0x2A4A, P.READ, [0x11, 0x01, 0x00, 0x02])  # HID information
            await self._add(s, 0x2A4B, P.READ, report_map)
            await self._add(s, 0x2A4C, P.WRITE_WITHOUT_RESPONSE)             # control point
            await self._add(s, 0x2A4E, P.READ | P.WRITE_WITHOUT_RESPONSE, [0x01])  # protocol mode: report
            self.keyboard = await self._add(s, 0x2A4D, P.READ | P.NOTIFY, [0] * 8, reference=[1, 1])
            await self._add(s, 0x2A4D, P.READ | P.WRITE | P.WRITE_WITHOUT_RESPONSE, [0], reference=[1, 2])
            if trackpad:
                self.touch = await self._add(s, 0x2A4D, P.READ | P.NOTIFY, [0] * TOUCH_REPORT_SIZE,
                                             reference=[3, 1])
                await self._add(s, 0x2A4D, P.READ, [FINGERS], reference=[4, 3])         # max contacts
                await self._add(s, 0x2A4D, P.READ | P.WRITE, [0x03], reference=[5, 3])  # input mode
                await self._add(s, 0x2A4D, P.READ | P.WRITE, [0x03], reference=[6, 3])  # surface/button on
            else:
                self.mouse = await self._add(s, 0x2A4D, P.READ | P.NOTIFY, [0] * 5, reference=[2, 1])
            await self._add(s, 0x2A22, P.READ | P.NOTIFY, [0] * 8)                   # boot keyboard in
            await self._add(s, 0x2A32, P.READ | P.WRITE | P.WRITE_WITHOUT_RESPONSE, [0])  # boot LEDs
            if not trackpad:
                await self._add(s, 0x2A33, P.READ | P.NOTIFY, [0] * 3)               # boot mouse in
            battery = await self._provider(0x180F)
            await self._add(battery.service, 0x2A19, P.READ | P.NOTIFY, [100], encrypted=False)
        except OSError as e:
            await self._stop()
            self.on_state("error", str(e))
            return

        self.keyboard.add_subscribed_clients_changed(lambda *_: self._report_state())
        self.touch_frames = 0
        for name, part in (("keyboard", self.keyboard), ("mouse", self.mouse), ("trackpad", self.touch)):
            if part is None:
                continue
            part.add_subscribed_clients_changed(
                lambda c, _, name=name: print(f"Bluetooth: iPad {'uses' if c.subscribed_clients.size else 'left'} "
                                              f"the {name}"))
        shown = GattServiceProviderAdvertisingParameters()
        shown.is_connectable = shown.is_discoverable = True
        hid.start_advertising_with_parameters(shown)
        quiet = GattServiceProviderAdvertisingParameters()
        quiet.is_connectable, quiet.is_discoverable = True, False  # published, not advertised
        battery.start_advertising_with_parameters(quiet)
        self.sender = asyncio.ensure_future(self._send_reports())
        self._report_state()

    async def _stop(self):
        if self.providers:
            print(f"Bluetooth: {getattr(self, 'touch_frames', 0)} trackpad frames sent, "
                  f"{getattr(self, 'failures', 0)} reports failed")
            self.failures = 0
        if self.sender:
            self.sender.cancel()
            self.sender = None
        for provider in self.providers:
            try:
                provider.stop_advertising()
            except OSError:
                pass
        self.providers = []
        self.keyboard = self.mouse = self.touch = None
        self.slots = {}
        self.connection_request = None
        self.on_state("off", None)

    def _report_state(self):
        self.on_state("connected" if self.connected else "waiting", None)
        if self.connected and self.connection_request is None:
            self.connection_request = False  # asking
            # called from Windows' Bluetooth threads too, not only the loop
            asyncio.run_coroutine_threadsafe(self._faster_connection(), self.loop)

    async def _faster_connection(self):
        """Ask for Windows' throughput-optimised connection (shortest interval the
        iPad allows: snappier pointer). Optional: Windows 11 only."""
        try:
            from winrt.windows.devices.bluetooth import (BluetoothLEDevice,
                                                         BluetoothLEPreferredConnectionParameters)
            client = self.keyboard.subscribed_clients[0]
            device = await BluetoothLEDevice.from_id_async(client.session.device_id.id)
            self.connection_request = device.request_preferred_connection_parameters(
                BluetoothLEPreferredConnectionParameters.throughput_optimized)
        except Exception as e:  # stays False: don't ask again this time
            print(f"Bluetooth: couldn't ask for a faster connection: {e!r}")

    async def _provider(self, short):
        result = await GattServiceProvider.create_async(_ble(short))
        if result.error != BluetoothError.SUCCESS:
            if result.error == BluetoothError.RADIO_NOT_AVAILABLE:
                raise OSError("Bluetooth is off on the laptop")
            raise OSError(f"Windows refused the Bluetooth service ({BluetoothError(result.error).name})")
        self.providers.append(result.service_provider)
        return result.service_provider

    async def _add(self, service, short, props, value=b"", encrypted=True, reference=None):
        params = GattLocalCharacteristicParameters()
        params.characteristic_properties = props
        level = GattProtectionLevel.ENCRYPTION_REQUIRED if encrypted else GattProtectionLevel.PLAIN
        params.read_protection_level = params.write_protection_level = level
        result = await service.create_characteristic_async(_ble(short), params)
        if result.error != BluetoothError.SUCCESS:
            raise OSError(f"Windows refused Bluetooth part {short:04x} ({BluetoothError(result.error).name})")
        characteristic = result.characteristic
        if props & P.READ:
            characteristic.add_read_requested(self._answer_reads(bytes(value)))
        if props & (P.WRITE | P.WRITE_WITHOUT_RESPONSE):
            characteristic.add_write_requested(self._accept_writes)
        if reference is not None:
            descriptor = GattLocalDescriptorParameters()
            descriptor.static_value = _buffer(reference)
            descriptor.read_protection_level = level
            await characteristic.create_descriptor_async(_ble(0x2908), descriptor)  # report reference
        return characteristic

    def _answer_reads(self, value):
        def handler(_sender, args):
            deferral = args.get_deferral()

            async def answer():
                try:
                    request = await args.get_request_async()
                    request.respond_with_value(_buffer(value))
                finally:
                    deferral.complete()
            asyncio.run_coroutine_threadsafe(answer(), self.loop)
        return handler

    def _accept_writes(self, _sender, args):
        """Control point, protocol mode, Caps Lock light: accepted, not needed."""
        deferral = args.get_deferral()

        async def accept():
            try:
                request = await args.get_request_async()
                if request.option == GattWriteOption.WRITE_WITH_RESPONSE:
                    request.respond()
            finally:
                deferral.complete()
        asyncio.run_coroutine_threadsafe(accept(), self.loop)

    async def _send_reports(self):
        """Keys go out as they come; mouse movement is gathered and sent at most
        every MOUSE_INTERVAL (more often would only queue up in Bluetooth)."""
        while True:
            try:
                report = await asyncio.wait_for(self.keys.get(), MOUSE_INTERVAL)
                await self._notify(self.keyboard, report)
                continue
            except asyncio.TimeoutError:
                pass
            if time.time() - self.touch_sent_at >= TOUCH_INTERVAL:
                with self.lock:
                    latest, self.touch_latest = self.touch_latest, None
                if latest is not None:
                    self.touch_sent_at = time.time()
                    await self._notify(self.touch, self._touch_report(*latest))
                    self.touch_frames += 1
            with self.lock:
                p = self.pending
                if not (p["dx"] or p["dy"] or p["wheel"] or p["pan"] or p["buttons"] != self.buttons_sent):
                    continue
                dx, dy, wheel, pan = _clamp(p["dx"]), _clamp(p["dy"]), _clamp(p["wheel"]), _clamp(p["pan"])
                p["dx"] -= dx
                p["dy"] -= dy
                p["wheel"] -= wheel
                p["pan"] -= pan
                buttons = self.buttons_sent = p["buttons"]
            await self._notify(self.mouse, [buttons, dx & 0xFF, dy & 0xFF, wheel & 0xFF, pan & 0xFF])

    def _touch_report(self, touching, clicked):
        """One trackpad frame: every finger down, plus once more (tip up, where it
        was) each finger that just lifted. Fingers keep their slot while down."""
        fingers = []
        for contact in list(self.slots):
            if contact not in touching:
                slot, x, y = self.slots.pop(contact)
                fingers.append(struct.pack("<BBHH", 0b01, slot, x, y))  # confident, tip up
        used = {slot for slot, _, _ in self.slots.values()}
        for contact, (fx, fy) in touching.items():
            # the iPad's Y axis points up
            x, y = round(fx * TOUCH_MAX), round((1 - fy) * TOUCH_MAX)
            if contact in self.slots:
                slot = self.slots[contact][0]
            else:
                free = [s for s in range(FINGERS) if s not in used]
                if not free:
                    continue
                slot = free[0]
                used.add(slot)
            self.slots[contact] = (slot, x, y)
            fingers.append(struct.pack("<BBHH", 0b11, slot, x, y))      # confident, tip down
        count = len(fingers)
        fingers = (fingers + [bytes(6)] * FINGERS)[:FINGERS]
        scan_time = int(time.time() * 10000) & 0xFFFF                  # 100 µs units
        return b"".join(fingers) + struct.pack("<HBB", scan_time, count, int(clicked))

    async def _notify(self, characteristic, report):
        if characteristic is None or characteristic.subscribed_clients.size == 0:
            return
        try:
            results = await characteristic.notify_value_async(_buffer(report))
        except OSError as e:  # the iPad went away; on_state reports it
            self._count_failure(repr(e))
            return
        # a failed send doesn't raise: each receiving device has its own result
        for result in results:
            status = getattr(result, "status", None)
            if status is not None and int(status) != 0:  # 0 = GattCommunicationStatus.SUCCESS
                self._count_failure(f"status {int(status)}, protocol error {getattr(result, 'protocol_error', None)}")

    def _count_failure(self, why):
        """Diagnostics: sends the iPad didn't get, summed up when switching back."""
        self.failures = getattr(self, "failures", 0) + 1
        if self.failures == 1:
            print(f"Bluetooth: a report didn't reach the iPad ({why})")
