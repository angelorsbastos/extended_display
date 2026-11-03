"""The laptop as a Bluetooth keyboard + mouse for the iPad (HID over GATT).

Windows lets an app publish the HID service; the iPad pairs with the laptop
("LAPRÉ" in Settings > Bluetooth) and uses it like any Bluetooth keyboard and
mouse. What made the iPad accept it (a bare HID service was paired but never
used): boot keyboard/mouse reports, a keyboard LED output report and a Battery
service next to it. Windows refuses the Device Information service ("disabled
by policy"); the iPad manages without.

Windows keeps restarting the advertisement with a new private address, so the
iPad lists the laptop several times under Other Devices; once paired it finds
it again by its identity.

All Bluetooth work runs on one asyncio loop in its own thread. send_keys(),
move() and set_buttons() may be called from any thread (the input hooks).
"""
import asyncio
import threading
import uuid

from winrt.windows.devices.bluetooth import BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCharacteristicProperties as P, GattLocalCharacteristicParameters, GattLocalDescriptorParameters,
    GattProtectionLevel, GattServiceProvider, GattServiceProviderAdvertisingParameters, GattWriteOption)
from winrt.windows.storage.streams import DataWriter

MOUSE_INTERVAL = 0.008  # seconds between mouse reports: about one per Bluetooth connection event

REPORT_MAP = bytes([
    # keyboard, report id 1: input = modifiers, reserved, 6 keys; output = 5 LEDs + padding
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0,
    # mouse, report id 2: buttons, x, y, wheel, horizontal scroll (AC Pan)
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0,
])


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
        self.sender = None

    # ---- from any thread ---------------------------------------------------------

    def start(self):
        asyncio.run_coroutine_threadsafe(self._start(), self.loop)

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

    # ---- on the loop -------------------------------------------------------------

    async def _start(self):
        if self.providers:
            return
        self.on_state("starting", None)
        try:
            hid = await self._provider(0x1812)
            s = hid.service
            await self._add(s, 0x2A4A, P.READ, [0x11, 0x01, 0x00, 0x02])  # HID information
            await self._add(s, 0x2A4B, P.READ, REPORT_MAP)
            await self._add(s, 0x2A4C, P.WRITE_WITHOUT_RESPONSE)             # control point
            await self._add(s, 0x2A4E, P.READ | P.WRITE_WITHOUT_RESPONSE, [0x01])  # protocol mode: report
            self.keyboard = await self._add(s, 0x2A4D, P.READ | P.NOTIFY, [0] * 8, reference=[1, 1])
            await self._add(s, 0x2A4D, P.READ | P.WRITE | P.WRITE_WITHOUT_RESPONSE, [0], reference=[1, 2])
            self.mouse = await self._add(s, 0x2A4D, P.READ | P.NOTIFY, [0] * 5, reference=[2, 1])
            await self._add(s, 0x2A22, P.READ | P.NOTIFY, [0] * 8)                   # boot keyboard in
            await self._add(s, 0x2A32, P.READ | P.WRITE | P.WRITE_WITHOUT_RESPONSE, [0])  # boot LEDs
            await self._add(s, 0x2A33, P.READ | P.NOTIFY, [0] * 3)                   # boot mouse in
            battery = await self._provider(0x180F)
            await self._add(battery.service, 0x2A19, P.READ | P.NOTIFY, [100], encrypted=False)
        except OSError as e:
            await self._stop()
            self.on_state("error", str(e))
            return

        self.keyboard.add_subscribed_clients_changed(lambda *_: self._report_state())
        shown = GattServiceProviderAdvertisingParameters()
        shown.is_connectable = shown.is_discoverable = True
        hid.start_advertising_with_parameters(shown)
        quiet = GattServiceProviderAdvertisingParameters()
        quiet.is_connectable, quiet.is_discoverable = True, False  # published, not advertised
        battery.start_advertising_with_parameters(quiet)
        self.sender = asyncio.ensure_future(self._send_reports())
        self._report_state()

    async def _stop(self):
        if self.sender:
            self.sender.cancel()
            self.sender = None
        for provider in self.providers:
            try:
                provider.stop_advertising()
            except OSError:
                pass
        self.providers = []
        self.keyboard = self.mouse = None
        self.on_state("off", None)

    def _report_state(self):
        self.on_state("connected" if self.connected else "waiting", None)

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

    async def _notify(self, characteristic, report):
        if characteristic is None or characteristic.subscribed_clients.size == 0:
            return
        try:
            await characteristic.notify_value_async(_buffer(report))
        except OSError:
            pass  # the iPad went away; on_state reports it
