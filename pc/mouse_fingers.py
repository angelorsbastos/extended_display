"""A mouse on the laptop, as fingers on the iPad's trackpad (Ctrl+Alt+I).

The iPad ignores a trackpad that comes with a mouse, so the mouse is played as
fingers instead: moving = one finger sliding, left click = pressing the pad
with that finger (held: dragging), right click = pressing with two fingers,
the wheel = two fingers sliding (natural direction, like the iPad's own).

A finger that would run off the pad is lifted and put back in the middle.
Fingers lift once the mouse rests. While sliding, the picture is refreshed
every 4 ms, so whenever Bluetooth sends (about every 11 ms) the finger is where
the mouse is right then: even speed, like the touchpad's own reports. Changes
(a finger down or up, a click) are held long enough to be sent for sure.
"""
import threading
import time
from collections import deque

FRAME = 0.004            # seconds between pictures (Bluetooth takes the newest every ~11 ms)
HOLD = 0.02              # a finger put down / lifted / pressed stays so long, to be sent for sure
SCROLL_EVERY = 4         # scrolling slides every this many frames (16 ms: its own pace)
PIXELS_PER_PAD = 1250    # mouse pixels for one full pad width of finger travel
PAD_ASPECT = 120 / 70    # the pad's width / height (bluetooth_hid.PAD_SIZE_MM)
SCROLL_PER_NOTCH = 0.07  # pad heights the fingers slide per wheel notch (120 units)
# each frame the scrolling fingers slide this share of what's left, so notches
# blend into one smooth glide instead of start-stop
SCROLL_EASE, SCROLL_MIN_STEP, SCROLL_MAX_STEP = 0.3, 0.004, 0.03
REST_SECONDS = 0.25      # fingers lift after this long without use
EDGE = 0.06              # keep fingers this far from the pad's edges
MOVE_STEP = 0.15         # most a pointing finger slides in one frame (the rest: next frames)


class MouseFingers:
    def __init__(self, send, busy):
        """send(touching, clicked) like BluetoothHID.send_touch; busy() is true
        while the laptop's own touchpad has fingers on it (it wins)."""
        self.send = send
        self.busy = busy
        self.lock = threading.Lock()
        self.dx = self.dy = 0.0       # pointer movement not sent yet, in pad units
        self.scroll_x = self.scroll_y = 0.0  # scrolling not slid yet, in pad units
        self.presses = deque()        # ("left" / "right", down) in order
        self.running = False
        self.tick = 0
        self._reset()

    def _reset(self):
        self.mode = None          # None, "point" or "scroll"
        self.at = (0.5, 0.5)      # the (first) finger
        self.pressed = None       # "left" / "right" while a button is held
        self.two = False          # two fingers down for a right click
        self.lift_after = False   # lift on the next quiet frame (after a right click)
        self.used = 0.0

    # ---- from the mouse hook ------------------------------------------------------

    def start(self):
        if not self.running:
            self.running = True
            threading.Thread(target=self._run, name="mouse-fingers", daemon=True).start()

    def stop(self):
        self.running = False

    def move(self, dx_pixels, dy_pixels):
        with self.lock:
            self.dx += dx_pixels / PIXELS_PER_PAD
            self.dy += dy_pixels / PIXELS_PER_PAD * PAD_ASPECT

    def wheel(self, delta, horizontal=False):
        """Windows wheel units (120 a notch; up / right positive). Natural:
        the fingers slide the way the content moves."""
        notches = delta / 120
        with self.lock:
            if horizontal:
                self.scroll_x -= notches * SCROLL_PER_NOTCH / PAD_ASPECT
            else:
                self.scroll_y += notches * SCROLL_PER_NOTCH

    def button(self, which, down):
        with self.lock:
            self.presses.append((which, down))

    # ---- the frame thread ------------------------------------------------------------

    def _run(self):
        while self.running:
            time.sleep(FRAME)
            self.tick += 1
            try:
                self._frame()
            except Exception as e:  # never let a bad frame stop the mouse
                print(f"mouse fingers: {e!r}")
        self._lift()

    def _frame(self):
        if self.busy():
            # the touchpad's own fingers are being sent; ours are gone with that
            with self.lock:
                self.dx = self.dy = self.scroll_x = self.scroll_y = 0
                self.presses.clear()
            self._reset()
            return
        now = time.time()
        with self.lock:
            press = self.presses[0] if self.presses else None
        if press and self._press(*press, now):
            with self.lock:
                self.presses.popleft()
            return
        if press:
            return  # the press needs fingers put down first: done this frame

        with self.lock:
            dx = max(-MOVE_STEP, min(MOVE_STEP, self.dx))
            dy = max(-MOVE_STEP, min(MOVE_STEP, self.dy))
            self.dx -= dx
            self.dy -= dy
            sx = sy = 0.0
            if self.tick % SCROLL_EVERY == 0:
                sx, sy = _ease(self.scroll_x), _ease(self.scroll_y)
            self.scroll_x -= sx
            self.scroll_y -= sy

        if (sx or sy) and self.pressed is None:
            if self.mode != "scroll":
                with self.lock:  # slide on the next frame, fingers first
                    self.scroll_x += sx
                    self.scroll_y += sy
                self._switch("scroll")
                return
            self.at = self._slide(self.at, sx, sy)
            self._show()
            self.used = now
            return

        if dx or dy:
            if self.mode != "point":
                self._switch("point")
            self.at = self._slide(self.at, dx, dy)
            self.used = now
            self._show()
            return

        if self.lift_after:
            self._lift()
        elif self.mode and self.pressed is None and now - self.used > REST_SECONDS:
            self._lift()

    def _press(self, which, down, now):
        """One step of a button press; true once it's fully shown."""
        if not down:
            if self.pressed == which:
                self.pressed = None
                self._show(clicked=False, hold=True)
                self.two = False
                self.lift_after = which == "right"  # two fingers would scroll next
                self.used = now
            return True
        if self.pressed is not None:
            return True  # another button while one is held: ignored
        if self.mode != "point":
            self._switch("point")
            return False
        if which == "right" and not self.two:
            self.two = True  # two fingers down first, then press
            self._show(hold=True)
            return False
        self.pressed = which
        self._show(hold=True)
        self.used = now
        return True

    def _slide(self, at, dx, dy):
        """Move the finger(s); one about to leave the pad goes back to the middle
        (lifted for a frame first, like picking a finger up on a real pad)."""
        x, y = at[0] + dx, at[1] + dy
        if EDGE <= x <= 1 - EDGE and EDGE <= y <= 1 - EDGE:
            return x, y
        if self.pressed:  # dragging: hold at the edge rather than letting go
            return min(max(x, EDGE), 1 - EDGE), min(max(y, EDGE), 1 - EDGE)
        # pick the finger up, put it down in the middle, and slide from there next frame
        if self.mode == "scroll":
            # rest the fingers a moment first: lifted while moving, the iPad
            # would fling the page on its own and the scrolling would jump
            for _ in range(3):
                self._show(hold=True)
        with self.lock:
            if self.mode == "scroll":
                self.scroll_x += dx
                self.scroll_y += dy
            else:
                self.dx += dx
                self.dy += dy
        # pointing: put it down on the side it's coming from, for the longest slide
        start = (0.25 if dx > 0 else 0.75 if dx < 0 else 0.5,
                 0.25 if dy > 0 else 0.75 if dy < 0 else 0.5)
        self._switch(self.mode, start)
        return self.at

    def _switch(self, mode, start=(0.5, 0.5)):
        if self.mode:
            self._lift()
        self.mode = mode
        self.at = start
        if mode == "scroll":
            # start at the far side, so the fingers have the whole pad to slide
            with self.lock:
                sx, sy = self.scroll_x, self.scroll_y
            far = 1 - EDGE - 0.02
            self.at = (far if sx < 0 else 1 - far if sx > 0 else 0.5,
                       far if sy < 0 else 1 - far if sy > 0 else 0.5)
        self.used = time.time()
        self._show(hold=True)

    def _show(self, clicked=None, hold=False):
        """Send the fingers as they are now."""
        x, y = self.at
        two = self.mode == "scroll" or self.two
        touching = {"m1": (x - 0.04, y), "m2": (x + 0.04, y)} if two else {"m1": (x, y)}
        if clicked is None:
            clicked = self.pressed is not None
        self.send(touching, clicked)
        if hold:
            time.sleep(HOLD)

    def _lift(self):
        if self.mode:
            self.send({}, False)
            time.sleep(HOLD)
        self._reset()


def _ease(left):
    """How far the scrolling fingers slide this frame, of `left` still to go."""
    if not left:
        return 0.0
    step = min(max(abs(left) * SCROLL_EASE, SCROLL_MIN_STEP), SCROLL_MAX_STEP, abs(left))
    return step if left > 0 else -step
