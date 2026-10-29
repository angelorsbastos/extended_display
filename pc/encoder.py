"""H.264 encoding on the NVIDIA GPU, tuned for latency rather than quality."""
from fractions import Fraction

import av
import numpy as np

FPS = 60


def make_encoder(width, height, bit_rate=15_000_000):
    codec = av.CodecContext.create("h264_nvenc", "w")
    codec.width, codec.height = width, height
    # bgr0 = same memory layout as the captured BGRA, so NVENC does the colour
    # conversion on the GPU instead of us doing it on the CPU (~10 ms saved)
    codec.pix_fmt = "bgr0"
    codec.time_base = Fraction(1, FPS)
    codec.bit_rate = bit_rate
    # no B-frames, no lookahead, one frame in flight
    codec.options = {"preset": "p1", "tune": "ull", "zerolatency": "1", "delay": "0",
                     "rc": "cbr", "bf": "0", "g": str(FPS * 2)}
    codec.open()
    return codec


def make_frame(width, height):
    """An encoder frame plus a numpy view onto its pixel memory, to copy into."""
    frame = av.VideoFrame(width, height, "bgr0")
    plane = frame.planes[0]
    view = (np.frombuffer(plane, np.uint8).reshape(height, plane.line_size)
            [:, :width * 4].reshape(height, width, 4))
    return frame, view
