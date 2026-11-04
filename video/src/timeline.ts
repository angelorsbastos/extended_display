// One source of truth for timing. Everything is written in beats of the music.
//
// Music: "House Vibez" (Lily J, Mixkit Stock Music Free License), 122.0 BPM.
// Its drop is at 63.037 s in the track. We start the track 6 s before that, so
// the drop lands on frame 180, the first frame of the Dock.

export const FPS = 30;
export const WIDTH = 1080;
export const HEIGHT = 1920;
export const DURATION = 1200; // 40 s

export const BEAT_SECONDS = 0.49179;
export const BEAT = BEAT_SECONDS * FPS; // 14.754 frames
export const DROP = 180;
export const MUSIC_TRIM_BEFORE = Math.round((63.037 - DROP / FPS) * FPS); // frames into the track

/** The frame of beat n, counted from the drop (negative before it). */
export const beatF = (n: number) => Math.round(DROP + n * BEAT);

export const SHOTS = {
  hook: { from: 0, to: beatF(-6) }, // icon builds, "Wingman"
  promise: { from: beatF(-6), to: DROP }, // three lines
  dock: { from: DROP, to: beatF(20) }, // the star
  controls: { from: beatF(20), to: beatF(38) }, // Control Center + dashboard
  phone: { from: beatF(38), to: beatF(50) }, // iPhone trackpad
  montage: { from: beatF(50), to: beatF(64) }, // 7 features, 2 beats each
  end: { from: beatF(64), to: DURATION }, // icon + name + credit
} as const;

export type ShotName = keyof typeof SHOTS;
export const len = (s: ShotName) => SHOTS[s].to - SHOTS[s].from;
