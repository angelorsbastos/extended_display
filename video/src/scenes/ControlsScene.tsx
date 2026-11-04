import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { Label, RiseLine } from "../components/Text";
import { easeInOut, ramp } from "../motion";
import type { CCState } from "../screens/ControlCenterScreen";
import type { DashState } from "../screens/DashboardScreen";
import { T } from "../theme";
import { beatF, SHOTS } from "../timeline";

// 16-25 s: the controls. Same iPad, new screen: the Control Center tiles fall
// into place, music plays, sound moves to the iPad, volume and brightness
// glide. Then the ROG dashboard slides in and its numbers count up.

const lb = (n: number) => beatF(n) - SHOTS.controls.from;

export const ccState = (f: number): CCState => {
  const press = (n: number, tile: string) => {
    const t = (f - lb(n)) / 8;
    return t >= 0 && t <= 1 ? { tile, t } : null;
  };
  return {
    tilesIn: ramp(f, 0, lb(22.5) - 4, (x) => x),
    playing: f >= lb(23) + 2,
    soundOn: ramp(f, lb(24) + 2, lb(24) + 10),
    volume: 0.4 + 0.45 * ramp(f, lb(25.5), lb(27), easeInOut),
    brightness: 0.3 + 0.48 * ramp(f, lb(27), lb(28.5), easeInOut),
    press: press(23, "now") ?? press(24, "sound") ?? press(25.5, "volume") ?? press(27, "bright"),
  };
};

/** 0..1: the navigation push from Control Center to the dashboard. */
export const dashPush = (f: number) => ramp(f, lb(30), lb(30) + 14, easeInOut);

export const dashState = (f: number): DashState => ({
  frame: f,
  cardsIn: ramp(f, lb(30) + 4, lb(32), (x) => x),
  count: ramp(f, lb(31), lb(35), easeInOut),
});

export const ControlsCaptions: React.FC = () => {
  const f = useCurrentFrame();
  const exit = ramp(f, lb(37.5), lb(38));
  const caption = (inAt: number, outAt: number | undefined, a: string, b: string) => (
    <div style={{ position: "absolute", left: 90, top: 240, display: "flex", flexDirection: "column", gap: 4 }}>
      <RiseLine inAt={inAt} outAt={outAt} size={104} weight={700}>
        {a}
      </RiseLine>
      <RiseLine
        inAt={inAt + 3}
        outAt={outAt === undefined ? undefined : outAt + 2}
        size={104}
        weight={700}
        color={T.secondary}
      >
        {b}
      </RiseLine>
    </div>
  );
  const sub = (inAt: number, outAt: number | undefined, text: string) => (
    <div style={{ position: "absolute", left: 96, top: 490 }}>
      <RiseLine inAt={inAt} outAt={outAt} size={46} weight={500} color={T.secondary} tracking={-0.01}>
        {text}
      </RiseLine>
    </div>
  );
  return (
    <AbsoluteFill style={{ opacity: 1 - exit }}>
      <div style={{ position: "absolute", left: 96, top: 190 }}>
        <Label opacity={ramp(f, 2, 10) * (1 - ramp(f, lb(29.5), lb(30)))}>Controls</Label>
      </div>
      <div style={{ position: "absolute", left: 96, top: 190 }}>
        <Label opacity={ramp(f, lb(30), lb(30) + 8)}>ROG Dashboard</Label>
      </div>
      {caption(4, lb(29.5), "Your whole laptop,", "one tap away.")}
      {caption(lb(30), undefined, "Heat, fans,", "battery. Live.")}
      {sub(lb(23), lb(25.5) - 6, "Play, pause, skip.")}
      {sub(lb(25.5), lb(29.5), "Volume and brightness.")}
      {sub(lb(31), undefined, "Straight from the ROG's sensors.")}
    </AbsoluteFill>
  );
};
