"""Send the laptop's sound to the iPad: whatever the speakers play, as AAC.

Windows "loopback" capture records the mix going to the default speakers, so
the laptop keeps playing the sound itself too. Muting the laptop also silences
the capture, and so does the laptop volume (it scales the sound before we get
it). We undo the volume with a matching boost, so the iPad's loudness doesn't
depend on the laptop's slider, but below ~10% the sound gets grainy: Windows
keeps only 16 bits after turning it down.
"""
import threading
import time
import warnings

import av
import numpy as np
import soundcard as sc

import controls

SAMPLE_RATE = 48000
CHANNELS = 2
FRAME = 1024  # samples per AAC packet (21 ms)
BIT_RATE = {"usb": 160_000, "wifi": 128_000, "remote": 96_000}
MAX_BOOST_DB = 40
RECHECK_SECONDS = 2  # how often to look for a new default speaker and volume


def make_encoder(bit_rate):
    codec = av.CodecContext.create("aac", "w")
    codec.sample_rate = SAMPLE_RATE
    codec.layout = "stereo"
    codec.format = "fltp"
    codec.bit_rate = bit_rate
    codec.open()
    return codec


class AudioStream:
    """Captures and encodes on its own thread until stopped. on_started(config)
    gets the AAC setup bytes (AudioSpecificConfig) before the first packet;
    on_packet(bytes) each packet. Either may raise OSError: the iPad is gone."""

    def __init__(self, bit_rate, on_started, on_packet):
        self.bit_rate = bit_rate
        self.on_started = on_started
        self.on_packet = on_packet
        self.stopped = threading.Event()
        threading.Thread(target=self._run, name="audio", daemon=True).start()

    def stop(self):
        self.stopped.set()

    def _run(self):
        # soundcard warns about every tiny gap ("data discontinuity"); harmless
        warnings.filterwarnings("ignore", category=sc.SoundcardRuntimeWarning)
        codec = make_encoder(self.bit_rate)
        try:
            self.on_started(bytes(codec.extradata))
            pts = 0
            while not self.stopped.is_set():
                speaker = sc.default_speaker()
                print(f"sound: sending {speaker.name} to the iPad")
                loopback = sc.get_microphone(id=str(speaker.name), include_loopback=True)
                with loopback.recorder(samplerate=SAMPLE_RATE, channels=CHANNELS,
                                       blocksize=FRAME) as recorder:
                    checked = 0.0
                    while not self.stopped.is_set():
                        if time.time() - checked > RECHECK_SECONDS:
                            checked = time.time()
                            if sc.default_speaker().id != speaker.id:
                                break  # e.g. headphones plugged in: follow them
                            gain = _undo_volume()
                        samples = recorder.record(numframes=FRAME)
                        planar = np.clip(samples.T * gain, -1, 1).astype(np.float32)
                        frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(planar),
                                                           format="fltp", layout="stereo")
                        frame.sample_rate = SAMPLE_RATE
                        frame.pts = pts
                        pts += FRAME
                        for packet in codec.encode(frame):
                            self.on_packet(bytes(packet))
        except OSError:
            pass  # the iPad disconnected
        except Exception as e:  # no speaker at all, or the audio service is restarting
            print(f"sound stopped: {e!r}")
        finally:
            self.stopped.set()


def _undo_volume():
    """The boost that cancels the laptop's volume setting (1.0 at 100%)."""
    level_db = controls.speaker_level_db()
    if level_db is None:
        return 1.0
    return 10 ** (min(-level_db, MAX_BOOST_DB) / 20)
