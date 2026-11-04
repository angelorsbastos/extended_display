import React from "react";
import { interpolateColors } from "remotion";
import { Timer } from "lucide-react";
import { fontFamily, T } from "../theme";
import { AppIcon, SONG } from "./ui";

// The Dock (ipad/Wingman/Dock.swift), iPad on its side, 1180 x 820:
// a huge thin clock with the date and a running timer on the left; the song
// with its equalizer and volume line, then six shortcuts, on the right; a slow
// glow in the song's colour behind it all. Night turns everything dim red.

export type DockState = {
  frame: number; // for the equalizer and glow
  clockFrom: string;
  clockTo: string;
  clockRoll: number; // 0..1, the minutes rolling over
  songIn: number; // 0..1
  timerIn: number; // 0..1
  timerSeconds: number; // remaining
  night: number; // 0..1
  volume: number; // 0..1
  volumeVisible: number; // 0..1
  shortcutsIn: number; // 0..1
};

const W = 1180;
const H = 820;

const RollingText: React.FC<{ from: string; to: string; t: number; size: number }> = ({
  from,
  to,
  t,
  size,
}) => (
  <div style={{ display: "flex", fontVariantNumeric: "tabular-nums" }}>
    {to.split("").map((ch, i) => {
      const old = from[i] ?? ch;
      if (old === ch) return <span key={i}>{ch}</span>;
      return (
        <span
          key={i}
          style={{ position: "relative", display: "inline-block", overflow: "hidden", height: size * 1.1 }}
        >
          <span style={{ visibility: "hidden" }}>{ch}</span>
          <span
            style={{
              position: "absolute",
              left: 0,
              top: 0,
              transform: `translateY(${-t * 70}%)`,
              opacity: 1 - t,
              filter: `blur(${t * 6}px)`,
            }}
          >
            {old}
          </span>
          <span
            style={{
              position: "absolute",
              left: 0,
              top: 0,
              transform: `translateY(${(1 - t) * 70}%)`,
              opacity: t,
              filter: `blur(${(1 - t) * 6}px)`,
            }}
          >
            {ch}
          </span>
        </span>
      );
    })}
  </div>
);

const Equalizer: React.FC<{ frame: number; color: string }> = ({ frame, color }) => (
  <div style={{ display: "flex", gap: 4, height: 22, alignItems: "flex-end" }}>
    {[0, 1, 2, 3].map((i) => {
      const h = 0.35 + 0.65 * Math.abs(Math.sin(frame * (0.21 + i * 0.07) + i * 1.7));
      return <div key={i} style={{ width: 5, height: 22 * h, borderRadius: 3, background: color }} />;
    })}
  </div>
);

export const DockScreen: React.FC<{ s: DockState }> = ({ s }) => {
  const text = interpolateColors(s.night, [0, 1], [T.text, T.nightRed]);
  const secondary = interpolateColors(s.night, [0, 1], [T.secondary, T.nightDim]);
  const glowColour = interpolateColors(s.night, [0, 1], [SONG.hueColour, "rgb(153,13,13)"]);
  const glowOpacity = (0.3 - 0.14 * s.night) * (0.85 + 0.15 * Math.sin(s.frame / 40));
  const mm = Math.floor(s.timerSeconds / 60);
  const ss = Math.floor(s.timerSeconds % 60);
  const timer = `${mm}:${ss.toString().padStart(2, "0")}`;

  const padX = W * 0.06;
  const column = W * 0.34;
  const block = H * 0.62;
  const clockSize = 214;

  return (
    <div style={{ position: "absolute", inset: 0, background: "#000", fontFamily, color: text, overflow: "hidden" }}>
      {/* the breathing glow, in the song's colour */}
      <div
        style={{
          position: "absolute",
          left: W * 0.22 - 531,
          top: H * 0.3 - 531,
          width: 1062,
          height: 1062,
          borderRadius: "50%",
          background: `radial-gradient(circle, ${glowColour} 0%, transparent 62%)`,
          opacity: glowOpacity * (0.4 + 0.6 * s.songIn),
        }}
      />
      <div
        style={{
          position: "absolute",
          left: padX,
          right: padX,
          top: (H - block) / 2,
          height: block,
          display: "flex",
          alignItems: "center",
          gap: W * 0.06,
        }}
      >
        {/* clock block */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: clockSize * 0.04 }}>
          <div style={{ fontSize: clockSize, fontWeight: 200, letterSpacing: "-0.04em", lineHeight: 1.05 }}>
            <RollingText from={s.clockFrom} to={s.clockTo} t={s.clockRoll} size={clockSize} />
          </div>
          <div style={{ fontSize: 34, color: secondary, paddingLeft: 10 }}>Wednesday 4 November</div>
          <div
            style={{
              fontSize: 34,
              fontWeight: 500,
              paddingLeft: 10,
              display: "flex",
              alignItems: "center",
              gap: 10,
              fontVariantNumeric: "tabular-nums",
              opacity: s.timerIn,
              transform: `translateY(${(1 - s.timerIn) * 16}px)`,
              height: 44 * s.timerIn,
            }}
          >
            <Timer size={30} strokeWidth={2.4} />
            {timer}
          </div>
        </div>
        {/* right column: the song, then the shortcuts */}
        <div style={{ width: column, height: block, display: "flex", flexDirection: "column" }}>
          <div
            style={{
              opacity: s.songIn,
              transform: `translateY(${(1 - s.songIn) * 24}px)`,
              display: "flex",
              flexDirection: "column",
              gap: 4,
            }}
          >
            <div style={{ marginBottom: 6 }}>
              <Equalizer frame={s.frame} color={text} />
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
              <div style={{ fontSize: 28, fontWeight: 600, letterSpacing: "-0.01em" }}>{SONG.title}</div>
              <div style={{ flex: 1 }} />
              <div style={{ width: 120, height: 5, position: "relative", opacity: s.volumeVisible }}>
                <div style={{ position: "absolute", inset: 0, borderRadius: 3, background: text, opacity: 0.2 }} />
                <div
                  style={{
                    position: "absolute",
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: Math.max(5, 120 * s.volume),
                    borderRadius: 3,
                    background: text,
                  }}
                />
              </div>
            </div>
            <div style={{ fontSize: 18, color: secondary }}>{SONG.artist}</div>
          </div>
          <div style={{ flex: 1 }} />
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 110px)", columnGap: 35.5, rowGap: 35.5 }}>
            {[0, 1, 2, 3, 4, 5].map((i) => {
              const t = Math.min(1, Math.max(0, s.shortcutsIn * 1.8 - i * 0.14));
              return (
                <div
                  key={i}
                  style={{
                    width: 110,
                    height: 110,
                    borderRadius: 33,
                    background: interpolateColors(
                      s.night,
                      [0, 1],
                      ["rgba(255,255,255,0.07)", "rgba(199,51,46,0.12)"],
                    ),
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    opacity: t,
                    transform: `scale(${0.9 + 0.1 * t})`,
                  }}
                >
                  <div style={{ position: "relative" }}>
                    <div style={{ opacity: 1 - s.night }}>
                      <AppIcon index={i} size={46} />
                    </div>
                    {/* at night the colour drains to the red */}
                    <div style={{ position: "absolute", inset: 0, opacity: s.night }}>
                      <AppIcon index={i} size={46} mono={T.nightRed} />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
};
