import { beatF, DROP, SHOTS } from "./timeline";

// Every sound effect, pinned to a picture event. Frames are written relative to
// beats or shots, never as bare numbers, so they follow any timing change.
// Sources and licences: video/CREDITS.md (all Mixkit, free to use, no credit needed).

export type Sfx = { from: number; src: string; volume: number; frames?: number; note: string };

export const SFX: Sfx[] = [
  { from: 30, src: "sfx/sparkle-touch.mp3", volume: 0.35, note: "the wingman outline draws itself" },
  { from: DROP - 10, src: "sfx/whoosh-fast.mp3", volume: 0.35, note: "promise lines leave, into the drop" },
  { from: DROP, src: "sfx/impact-deep-whoosh.mp3", volume: 0.7, note: "SLAM 1: the drop, the iPad lands" },
  { from: beatF(4), src: "sfx/swoosh-quick.mp3", volume: 0.25, note: "the song slides in" },
  { from: beatF(8), src: "sfx/switch-tap.mp3", volume: 0.45, note: "the timer starts" },
  { from: beatF(12), src: "sfx/clock-tick-single.mp3", volume: 0.7, note: "the clock rolls to 22:00" },
  { from: SHOTS.controls.from, src: "sfx/transition-tech-slide.mp3", volume: 0.35, frames: 30, note: "Control Center tiles arrive" },
  { from: beatF(23), src: "sfx/switch-click-quick.mp3", volume: 0.5, note: "play" },
  { from: beatF(24), src: "sfx/switch-tap.mp3", volume: 0.5, note: "Sound here turns on" },
  { from: beatF(30), src: "sfx/air-woosh-quick.mp3", volume: 0.35, note: "the dashboard slides in" },
  { from: beatF(37.5), src: "sfx/whoosh-fast.mp3", volume: 0.35, note: "the iPad leaves" },
  { from: SHOTS.phone.from + 8, src: "sfx/swoosh-quick.mp3", volume: 0.3, note: "the iPhone rises in" },
  { from: beatF(43), src: "sfx/switch-click-quick.mp3", volume: 0.55, note: "tap to click" },
  ...[0, 1, 2, 3, 4, 5, 6].map((k) => ({
    from: beatF(50 + 2 * k) - 2,
    src: k % 2 === 0 ? "sfx/swoosh-quick.mp3" : "sfx/air-woosh-quick.mp3",
    volume: 0.3 - k * 0.015,
    note: `feature ${k + 1} of the montage`,
  })),
  { from: SHOTS.end.from, src: "sfx/bass-hit-futuristic.mp3", volume: 0.55, note: "SLAM 2: the icon lands" },
  { from: SHOTS.end.from + 10, src: "sfx/shimmer-sparkle-sweep.mp3", volume: 0.4, note: "the sheen across the icon" },
];
