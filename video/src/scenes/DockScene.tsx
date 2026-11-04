import React from "react";
import { AbsoluteFill, interpolateColors, useCurrentFrame } from "remotion";
import { Label, RiseLine } from "../components/Text";
import { easeInOut, ramp } from "../motion";
import type { DockState } from "../screens/DockScreen";
import { T } from "../theme";
import { beatF, SHOTS } from "../timeline";

// 6-16 s, the star: the Dock. One idea per four beats: Time, Music, Focus,
// Night (the clock rolls to 22:00 and the screen fades to dim red, as the app
// does at 22:00). The iPad itself lives in stage/IPadStage.tsx.

const lb = (n: number) => beatF(n) - SHOTS.dock.from;

/** How dark-red the Dock is at local frame f (0..1). */
export const dockNight = (f: number) => ramp(f, lb(12) + 8, lb(15), easeInOut);

/** The Dock screen at local frame f. */
export const dockState = (f: number): DockState => {
  const timerStart = lb(9);
  return {
    frame: f,
    clockFrom: "21:59",
    clockTo: f >= lb(12) ? "22:00" : "21:59",
    clockRoll: f >= lb(12) ? ramp(f, lb(12), lb(12) + 22) : 1,
    songIn: ramp(f, lb(4), lb(5)),
    timerIn: ramp(f, lb(8), lb(8) + 14),
    timerSeconds: 25 * 60 - Math.max(0, (f - timerStart) / 30),
    night: dockNight(f),
    volume: 0.45 + 0.35 * ramp(f, lb(6), lb(7.5), easeInOut),
    volumeVisible: ramp(f, lb(5.5), lb(6)) * (1 - ramp(f, lb(10.5), lb(11.5))),
    shortcutsIn: ramp(f, lb(1), lb(3)),
  };
};

const WORDS: [string, string, number][] = [
  ["Time.", "A clock you can read across the room.", 0],
  ["Music.", "Whatever the laptop is playing.", 4],
  ["Focus.", "A timer, right under the clock.", 8],
  ["Night.", "At 22:00 it turns a soft red.", 12],
];

export const DockCaptions: React.FC = () => {
  const f = useCurrentFrame();
  const night = dockNight(f);
  const wordNight = interpolateColors(night, [0, 1], [T.text, T.nightRed]);
  const labelColor = interpolateColors(night, [0, 1], [T.accent, T.nightRed]);
  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 96, top: 190 }}>
        <Label color={labelColor} opacity={ramp(f, 4, 14)}>
          The Dock
        </Label>
      </div>
      {WORDS.map(([word, line, n], i) => {
        const next = WORDS[i + 1]?.[2];
        const outAt = next === undefined ? lb(19.5) : lb(next) - 8;
        const inAt = n === 0 ? 8 : lb(n);
        return (
          <React.Fragment key={word}>
            <div style={{ position: "absolute", left: 90, top: 240 }}>
              <RiseLine inAt={inAt} outAt={outAt} size={150} weight={700} color={i === 3 ? wordNight : T.text}>
                {word}
              </RiseLine>
            </div>
            <div style={{ position: "absolute", left: 96, top: 430 }}>
              <RiseLine inAt={inAt + 4} outAt={outAt} size={46} weight={500} color={T.secondary} tracking={-0.01}>
                {line}
              </RiseLine>
            </div>
          </React.Fragment>
        );
      })}
    </AbsoluteFill>
  );
};
