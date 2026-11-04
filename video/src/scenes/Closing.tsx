import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import type { LucideIcon } from "lucide-react";
import { Clipboard, Copy, FolderUp, Globe, LayoutGrid, RectangleHorizontal, Volume2 } from "lucide-react";
import { Label, RiseLine } from "../components/Text";
import { WingmanIcon } from "../components/WingmanIcon";
import { easeIn, easeOut, land, ramp } from "../motion";
import { fontFamily, T } from "../theme";
import { beatF, SHOTS } from "../timeline";
import type { TileStyle } from "../screens/ui";
import { tileFill } from "../screens/ui";

// 31-37 s: "and more", one feature every two beats, as Control Center tiles.
export const FEATURES: { word: string; line: string; Icon: LucideIcon; style: TileStyle }[] = [
  { word: "Extend", line: "The iPad as a second screen.", Icon: Copy, style: "accent" },
  { word: "Mirror", line: "Your laptop's screen, on the iPad.", Icon: RectangleHorizontal, style: "normal" },
  { word: "Sound", line: "The laptop's audio, played here.", Icon: Volume2, style: "on" },
  { word: "Files", line: "Send them both ways.", Icon: FolderUp, style: "normal" },
  { word: "Clipboard", line: "Copy there, paste here.", Icon: Clipboard, style: "normal" },
  { word: "Shortcuts", line: "Your apps, one tap away.", Icon: LayoutGrid, style: "normal" },
  { word: "Anywhere", line: "Cable, Wi-Fi, or away from home.", Icon: Globe, style: "on" },
];

const mlb = (n: number) => beatF(n) - SHOTS.montage.from;

export const Montage: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: -300,
          top: 300,
          width: 1680,
          height: 1300,
          background: `radial-gradient(ellipse, rgba(${T.accentRGB},0.14) 0%, transparent 60%)`,
        }}
      />
      <div style={{ position: "absolute", left: 0, right: 0, top: 380, display: "flex", justifyContent: "center" }}>
        <Label opacity={ramp(f, 0, 8)}>And there&apos;s more</Label>
      </div>
      {/* progress dots */}
      <div style={{ position: "absolute", left: 0, right: 0, top: 1450, display: "flex", justifyContent: "center", gap: 14 }}>
        {FEATURES.map((_, k) => {
          const active = f >= mlb(50 + 2 * k) && f < mlb(52 + 2 * k);
          return (
            <div
              key={k}
              style={{
                width: active ? 34 : 10,
                height: 10,
                borderRadius: 5,
                background: active ? T.text : "rgba(255,255,255,0.25)",
              }}
            />
          );
        })}
      </div>
      {FEATURES.map((it, k) => {
        const inAt = mlb(50 + 2 * k);
        const outAt = k === FEATURES.length - 1 ? mlb(64) - 6 : mlb(52 + 2 * k) - 6;
        if (f < inAt - 2 || f > outAt + 12) return null;
        const enter = ramp(f, inAt, inAt + 12, easeOut);
        const leave = ramp(f, outAt, outAt + 8, easeIn);
        const pop = land(f, inAt, 12);
        const fg = it.style === "on" ? T.onText : T.text;
        return (
          <React.Fragment key={it.word}>
            <div
              style={{
                position: "absolute",
                left: 540 - 150,
                top: 590,
                width: 300,
                height: 300,
                borderRadius: 66,
                background: tileFill(it.style),
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                opacity: enter * (1 - leave),
                transform: `perspective(1400px) translateY(${(1 - enter) * 90 - leave * 90}px) rotateX(${(1 - enter) * -65 + leave * 50}deg) rotateY(${Math.sin((f - inAt) / 9) * 6}deg) scale(${0.86 + 0.14 * pop})`,
                boxShadow: it.style === "accent" ? `0 30px 80px rgba(${T.accentRGB},0.45)` : "0 30px 80px rgba(0,0,0,0.5)",
              }}
            >
              <it.Icon size={128} strokeWidth={2.1} color={fg} />
            </div>
            <div style={{ position: "absolute", left: 0, right: 0, top: 960, display: "flex", justifyContent: "center" }}>
              <RiseLine inAt={inAt + 2} outAt={outAt} size={150} weight={700} inFrames={12} outFrames={8}>
                {it.word}
              </RiseLine>
            </div>
            <div style={{ position: "absolute", left: 0, right: 0, top: 1160, display: "flex", justifyContent: "center" }}>
              <RiseLine
                inAt={inAt + 5}
                outAt={outAt}
                size={46}
                weight={500}
                color={T.secondary}
                tracking={-0.01}
                inFrames={12}
                outFrames={8}
              >
                {it.line}
              </RiseLine>
            </div>
          </React.Fragment>
        );
      })}
    </AbsoluteFill>
  );
};

// 37-40 s: the icon lands, the name, the credit. Held to the last frame.
export const EndCard: React.FC = () => {
  const f = useCurrentFrame();
  const plate = land(f, 0, 14);
  const device = land(f, 4, 14);
  const wingman = ramp(f, 8, 22);
  const shine = ramp(f, 10, 34, easeOut);
  const turn = ramp(f, 0, 30, easeOut);
  return (
    <AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: 540 - 650,
          top: 800 - 650,
          width: 1300,
          height: 1300,
          borderRadius: "50%",
          background: `radial-gradient(circle, rgba(${T.accentRGB},0.32) 0%, transparent 60%)`,
          opacity: plate,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 540 - 150,
          top: 800 - 150,
          filter: `drop-shadow(0 30px 60px rgba(${T.accentRGB},0.5))`,
          transform: `perspective(1600px) rotateY(${(1 - turn) * -38}deg) rotateX(${(1 - turn) * 14}deg) translateY(${Math.sin(f / 14) * 6}px)`,
        }}
      >
        <div style={{ position: "relative", width: 300, height: 300, borderRadius: 66, overflow: "hidden" }}>
          <WingmanIcon size={300} plate={plate} device={device} wingman={wingman} />
          {/* one sheen across the icon, clipped to its corners */}
          <div
            style={{
              position: "absolute",
              top: -100,
              bottom: -100,
              width: 90,
              left: -150 + shine * 600,
              transform: "rotate(20deg)",
              background: "linear-gradient(90deg, transparent, rgba(255,255,255,0.35), transparent)",
              opacity: shine < 1 ? 1 : 0,
            }}
          />
        </div>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 1000, display: "flex", justifyContent: "center" }}>
        <RiseLine inAt={8} size={150} weight={700} inFrames={18}>
          Wingman
        </RiseLine>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, top: 1196, display: "flex", justifyContent: "center", fontFamily }}>
        <RiseLine inAt={16} size={40} weight={500} color={T.secondary} tracking={0}>
          Designed &amp; built by Ângelo
        </RiseLine>
      </div>
    </AbsoluteFill>
  );
};
