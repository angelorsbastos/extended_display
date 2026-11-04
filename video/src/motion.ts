import { Easing, interpolate, spring } from "remotion";
import { FPS } from "./timeline";

// Motion voice: confident and calm (Apple-like). Out-expo for entrances,
// a soft spring only where something lands.
export const easeOut = Easing.bezier(0.16, 1, 0.3, 1);
export const easeInOut = Easing.bezier(0.65, 0, 0.35, 1);
export const easeIn = Easing.bezier(0.7, 0, 0.84, 0);

/** 0 -> 1 between two frames, eased, clamped. */
export const ramp = (frame: number, from: number, to: number, easing = easeOut) =>
  interpolate(frame, [from, to], [0, 1], {
    easing,
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

/** A landing spring that starts at frame `at`. */
export const land = (frame: number, at: number, damping = 18, mass = 0.9) =>
  spring({ frame: frame - at, fps: FPS, config: { damping, mass, stiffness: 140 } });

export const mix = (a: number, b: number, t: number) => a + (b - a) * t;

/**
 * A camera over a flat object of size w x h: keyframes [frame, scale, fx, fy]
 * (fx, fy = the point of the object, 0..1, that sits at the slot's centre).
 * Eased between keys. Returns a CSS transform (origin top-left).
 */
export type CamKey = [number, number, number, number];
export const camera = (frame: number, keys: CamKey[], w: number, h: number, cx: number, cy: number) => {
  let s = keys[0][1];
  let fx = keys[0][2];
  let fy = keys[0][3];
  for (let i = 0; i < keys.length - 1; i++) {
    const [f0, s0, x0, y0] = keys[i];
    const [f1, s1, x1, y1] = keys[i + 1];
    if (frame >= f0) {
      const t = ramp(frame, f0, f1, easeInOut);
      s = mix(s0, s1, t);
      fx = mix(x0, x1, t);
      fy = mix(y0, y1, t);
    }
  }
  return `translate(${cx - fx * w * s}px, ${cy - fy * h * s}px) scale(${s})`;
};

/**
 * A 3D camera: keyframes [frame, scale, fx, fy, rotateY, rotateX, cy].
 * The object's point (fx, fy) stays at (540, cy) while it turns in perspective.
 */
export type Cam3Key = [number, number, number, number, number, number, number];
export const camera3d = (frame: number, keys: Cam3Key[], w: number, h: number, perspective = 2600) => {
  const v = [...keys[0]];
  for (let i = 0; i < keys.length - 1; i++) {
    const a = keys[i];
    const b = keys[i + 1];
    if (frame >= a[0]) {
      const t = ramp(frame, a[0], b[0], easeInOut);
      for (let k = 1; k < 7; k++) v[k] = mix(a[k], b[k], t);
    }
  }
  const [, s, fx, fy, ry, rx, cy] = v;
  const flat = Math.abs(ry) < 0.05 && Math.abs(rx) < 0.05;
  // stay a flat 2D layer when not turned, so zoomed text rasterises sharply
  const turn = flat ? "" : `perspective(${perspective}px) rotateX(${rx}deg) rotateY(${ry}deg) `;
  return {
    transform: `translate(540px, ${cy}px) ${turn}scale(${s}) translate(${-fx * w}px, ${-fy * h}px)`,
    scale: s,
    ry,
    rx,
  };
};

/** Deterministic pseudo-random (mulberry32). */
export const rand = (seed: number) => {
  let t = (seed + 0x6d2b79f5) | 0;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
