"""Benchmark: capture a monitor and encode it to H.264, like the real streamer will.

Usage: python capture_test.py [monitor_number] [seconds]
monitor_number starts at 1 (same numbering as Windows display settings).
Writes test.h264 so you can check the result (e.g. open it in VLC).

Uses Windows Graphics Capture rather than DXGI Desktop Duplication, because
Desktop Duplication fails on hybrid-GPU laptops when Python runs on the NVIDIA GPU.
Note: frames only arrive when the screen changes, so move a window around on
the captured monitor while this runs to get a realistic fps number.
"""
import sys
import threading
import time

import numpy as np
from windows_capture import WindowsCapture

from encoder import FPS, make_encoder, make_frame

MONITOR = int(sys.argv[1]) if len(sys.argv) > 1 else 2
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 5

state = {"codec": None, "frames": 0, "bytes": 0, "encode_ms": [], "size": None}
out = open("test.h264", "wb")
done = threading.Event()
capture = WindowsCapture(cursor_capture=True, draw_border=False, monitor_index=MONITOR,
                         minimum_update_interval=1000 // FPS)


@capture.event
def on_frame_arrived(frame, control):
    if done.is_set():
        control.stop()
        return
    if state["codec"] is None:
        state["size"] = (frame.width, frame.height)
        state["codec"] = make_encoder(frame.width, frame.height)
        state["vf"], state["view"] = make_frame(frame.width, frame.height)
        state["start"] = time.perf_counter()
    t0 = time.perf_counter()
    np.copyto(state["view"], frame.frame_buffer)
    vf = state["vf"]
    vf.pts = state["frames"]
    for packet in state["codec"].encode(vf):
        data = bytes(packet)
        state["bytes"] += len(data)
        out.write(data)
    state["encode_ms"].append((time.perf_counter() - t0) * 1000)
    state["frames"] += 1


@capture.event
def on_closed():
    done.set()


control = capture.start_free_threaded()
time.sleep(SECONDS)
done.set()
control.stop()
out.close()

if not state["frames"]:
    sys.exit(f"no frames from monitor {MONITOR} - does it exist? try 1 or 2")
elapsed = time.perf_counter() - state["start"]
ms = sorted(state["encode_ms"])
print(f"monitor {MONITOR}: {state['size'][0]}x{state['size'][1]}")
print(f"{state['frames'] / elapsed:.1f} fps (only counts screen changes), "
      f"{state['bytes'] * 8 / elapsed / 1e6:.1f} Mbit/s")
print(f"convert+encode time: median {ms[len(ms) // 2]:.1f} ms, "
      f"p95 {ms[int(len(ms) * 0.95)]:.1f} ms")
