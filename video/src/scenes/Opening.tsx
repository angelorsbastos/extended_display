import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { RiseLine } from "../components/Text";
import { easeIn, ramp } from "../motion";
import { T } from "../theme";
import { beatF, SHOTS } from "../timeline";

// 0-3 s: in the dark, a light runs along an iPad at an angle; its screen
// wakes with the Wingman icon ("This is Wingman."), then the name. The iPad
// itself is stage/IPadStage.tsx; this is the type over it.
export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const end = SHOTS.hook.to - SHOTS.hook.from;
  const exit = ramp(f, end, end + 9, easeIn);
  return (
    <AbsoluteFill style={{ opacity: 1 - exit }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: 1460, display: "flex", justifyContent: "center" }}>
        <RiseLine inAt={50} size={150} weight={700} inFrames={20}>
          Wingman
        </RiseLine>
      </div>
    </AbsoluteFill>
  );
};

// 3-6 s: the promise, one line per beat, spoken, over the music's build.
export const Promise: React.FC = () => {
  const at = (n: number) => beatF(n) - SHOTS.promise.from;
  const out = SHOTS.promise.to - SHOTS.promise.from - 9;
  const lines: [string, string, number][] = [
    ["Your ", "laptop.", at(-6) + 6],
    ["On your ", "iPad.", at(-4)],
    ["And your ", "iPhone.", at(-2)],
  ];
  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 96, top: 220, display: "flex", flexDirection: "column", gap: 14 }}>
        {lines.map(([lead, word, inAt], i) => (
          <RiseLine key={i} inAt={inAt} outAt={out + i * 2} size={112} weight={700}>
            <span style={{ color: T.secondary }}>{lead}</span>
            <span style={{ color: T.text }}>{word}</span>
          </RiseLine>
        ))}
      </div>
    </AbsoluteFill>
  );
};
