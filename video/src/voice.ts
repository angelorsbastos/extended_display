import durations from "./voice-durations.json";
import { beatF, DROP, FPS, SHOTS } from "./timeline";

// The narration (Microsoft neural voice "Andrew", made by scripts/make_voice.py
// from voice-lines.json). Each line starts so that its first word lands on the
// picture it talks about.

type Key = keyof typeof durations;

const PLACE: [Key, number][] = [
  ["intro", 38], // the icon wakes on the iPad
  ["laptop", beatF(-6) + 2],
  ["ipad", beatF(-4) - 3],
  ["iphone", beatF(-2) - 3],
  ["dock", DROP + 8],
  ["music", beatF(4) - 1],
  ["focus", beatF(8) - 1],
  ["night", beatF(12) + 3],
  ["controls", SHOTS.controls.from + 5],
  ["sliders", beatF(25.5) - 3],
  ["dash", beatF(30) + 2],
  ["phone", SHOTS.phone.from + 10],
  ["more", SHOTS.montage.from + 3],
  ["end", SHOTS.end.from + 6],
];

export const VOICE = PLACE.map(([key, from]) => {
  const d = durations[key];
  return {
    key,
    from,
    src: `voice/${key}.mp3`,
    // frames from `from` until the speech ends
    frames: Math.ceil((d.lead + d.speech) * FPS) + 2,
  };
});

/** 0..1: how much someone is speaking at frame f (eased), to duck the music. */
export const speaking = (f: number) => {
  let v = 0;
  for (const line of VOICE) {
    const a = line.from;
    const b = line.from + line.frames;
    const t = Math.min(1, Math.max(0, Math.min((f - a + 6) / 6, (b + 8 - f) / 8)));
    v = Math.max(v, t);
  }
  return v;
};
