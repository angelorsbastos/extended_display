import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { rand, ramp } from "../motion";
import { dockNight } from "../scenes/DockScene";
import { SHOTS } from "../timeline";

// The air of the film: out-of-focus lights drifting far behind (bokeh), and,
// over everything, a vignette and a fine moving film grain.

const LIGHTS = Array.from({ length: 13 }, (_, i) => ({
  x: rand(i * 7 + 1) * 1080,
  y: 680 + rand(i * 7 + 2) * 1250, // behind the devices, clear of the captions
  size: 90 + rand(i * 7 + 3) * 230,
  speed: 0.15 + rand(i * 7 + 4) * 0.35,
  phase: rand(i * 7 + 5) * Math.PI * 2,
  violet: rand(i * 7 + 6) > 0.6,
}));

const nightAt = (f: number) =>
  f >= SHOTS.dock.from && f < SHOTS.controls.from ? dockNight(f - SHOTS.dock.from) : 0;

export const Bokeh: React.FC = () => {
  const f = useCurrentFrame();
  const night = nightAt(f);
  const fadeIn = ramp(f, 20, 90);
  return (
    <AbsoluteFill style={{ opacity: fadeIn }}>
      {LIGHTS.map((l, i) => {
        const base = l.violet ? [140, 90, 255] : [47, 107, 255];
        const rgb = base.map((c, k) => Math.round(c + ([199, 51, 46][k] - c) * night)).join(",");
        const x = l.x + Math.sin(f * 0.01 * l.speed + l.phase) * 60 - f * l.speed * 0.4;
        const y = l.y + Math.cos(f * 0.008 * l.speed + l.phase) * 40;
        const wrapX = ((x % 1300) + 1300) % 1300 - 110;
        const twinkle = 0.75 + 0.25 * Math.sin(f * 0.05 + l.phase);
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: wrapX - l.size / 2,
              top: y - l.size / 2,
              width: l.size,
              height: l.size,
              borderRadius: "50%",
              background: `radial-gradient(circle, rgba(${rgb},0.035) 0%, rgba(${rgb},0.06) 58%, rgba(${rgb},0.085) 66%, rgba(${rgb},0) 71%)`,
              opacity: twinkle,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

export const Grade: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      {/* vignette */}
      <AbsoluteFill
        style={{ background: "radial-gradient(ellipse 75% 60% at 50% 48%, transparent 55%, rgba(0,0,0,0.55) 100%)" }}
      />
      {/* film grain: new noise every frame, very faint */}
      <svg width={1080} height={1920} style={{ position: "absolute", inset: 0, opacity: 0.07, mixBlendMode: "screen" }}>
        <filter id="grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves={2} seed={f % 97} stitchTiles="stitch" />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width="100%" height="100%" filter="url(#grain)" />
      </svg>
    </AbsoluteFill>
  );
};
