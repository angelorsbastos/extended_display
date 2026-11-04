import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { IPhoneFrame, LaptopFrame } from "../components/Devices";
import { Label, RiseLine } from "../components/Text";
import { easeIn, easeInOut, land, ramp } from "../motion";
import { LaptopDesktop, SURFACE, Touch, TrackpadScreen } from "../screens/PhoneScreens";
import { T } from "../theme";
import { beatF, SHOTS } from "../timeline";

// 25-31 s: the iPhone. The laptop above, the phone in front; a finger glides
// on the Trackpad screen and the laptop's cursor follows, taps, scrolls.

const lb = (n: number) => beatF(n) - SHOTS.phone.from;

// the finger's path on the phone surface (phone points), by local frame
const PATH: [number, number, number][] = [
  [lb(39.5), 110, 560],
  [lb(41.5), 250, 360],
  [lb(42.5), 255, 350], // settle, then tap at lb(43)
  [lb(44.5), 170, 420],
  [lb(45), 170, 420],
];

const fingerAt = (f: number) => {
  if (f <= PATH[0][0]) return { x: PATH[0][1], y: PATH[0][2] };
  for (let i = 0; i < PATH.length - 1; i++) {
    const [f0, x0, y0] = PATH[i];
    const [f1, x1, y1] = PATH[i + 1];
    if (f <= f1) {
      const t = easeInOut((f - f0) / (f1 - f0));
      return { x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t };
    }
  }
  const last = PATH[PATH.length - 1];
  return { x: last[1], y: last[2] };
};

export const PhoneScene: React.FC = () => {
  const f = useCurrentFrame();
  const laptopIn = land(f, 0, 18, 1);
  const phoneIn = land(f, 6, 16, 1);
  const p = fingerAt(f);
  const scrollStart = lb(45.5);
  const scrollEnd = lb(48);
  const scroll = ramp(f, scrollStart, scrollEnd, easeInOut);
  const scrollY = p.y - 160 * scroll;
  const down =
    ramp(f, lb(39.5) - 6, lb(39.5)) * (1 - ramp(f, lb(44.5), lb(44.5) + 4)) +
    ramp(f, scrollStart - 5, scrollStart) * (1 - ramp(f, scrollEnd, scrollEnd + 5));
  const tapT = (f - lb(43)) / 14;
  const scrolling = f >= scrollStart - 5;
  const touch: Touch = {
    x: p.x,
    y: scrolling ? scrollY : p.y,
    down: Math.min(1, down),
    two: scrolling ? 1 : 0,
    tap: tapT > 0 && tapT < 1 ? tapT : 0,
  };
  // the cursor moves with the finger (relative, like a trackpad), 2.4x faster
  const start = fingerAt(0);
  const cursor = { x: 420 + (p.x - start.x) * 2.4, y: 560 + (p.y - start.y) * 1.6 };
  const end = SHOTS.phone.to - SHOTS.phone.from;
  const exit = ramp(f, end - 8, end, easeIn);
  const orbit = ramp(f, 0, end, (x) => x);

  return (
    <AbsoluteFill style={{ opacity: 1 - exit, transform: `scale(${1 - 0.04 * exit})` }}>
      <div
        style={{
          position: "absolute",
          left: -300,
          top: 500,
          width: 1680,
          height: 1300,
          background: `radial-gradient(ellipse, rgba(${T.accentRGB},0.18) 0%, transparent 62%)`,
        }}
      />
      <div style={{ position: "absolute", left: 96, top: 170 }}>
        <Label opacity={ramp(f, 2, 12)}>And your iPhone</Label>
      </div>
      <div style={{ position: "absolute", left: 90, top: 230, display: "flex", flexDirection: "column", gap: 6 }}>
        <RiseLine inAt={4} size={96} weight={700}>
          It&apos;s a trackpad
        </RiseLine>
        <RiseLine inAt={8} size={96} weight={700} color={T.secondary}>
          for your laptop.
        </RiseLine>
      </div>
      {/* the desk group turns slowly in perspective, like a camera dolly */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          transformOrigin: "540px 1150px",
          transform: `perspective(2400px) rotateX(${8 - 4 * orbit}deg) rotateY(${-12 + 18 * orbit}deg) scale(${0.98 + 0.04 * orbit})`,
        }}
      >
      <div
        style={{
          position: "absolute",
          left: 100,
          top: 470,
          opacity: laptopIn,
          transform: `translateY(${(1 - laptopIn) * 60}px)`,
        }}
      >
        <LaptopFrame width={880}>
          <LaptopDesktop cursor={cursor} click={tapT} scroll={scroll} />
        </LaptopFrame>
      </div>
      <div
        style={{
          position: "absolute",
          left: 540 - 200,
          top: 990,
          transform: `translateY(${(1 - phoneIn) * 900}px) rotate(${(1 - phoneIn) * 6}deg)`,
        }}
      >
        <IPhoneFrame height={840}>
          <TrackpadScreen touch={touch} appear={ramp(f, 14, 24)} />
        </IPhoneFrame>
      </div>
      </div>
    </AbsoluteFill>
  );
};

export { SURFACE };
