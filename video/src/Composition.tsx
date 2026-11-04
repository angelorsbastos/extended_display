import React from "react";
import { AbsoluteFill, interpolate, Sequence, staticFile, useCurrentFrame } from "remotion";
import { Audio } from "@remotion/media";
import { CameraMotionBlur } from "@remotion/motion-blur";
import { z } from "zod";
import { ControlsCaptions } from "./scenes/ControlsScene";
import { DockCaptions } from "./scenes/DockScene";
import { EndCard, Montage } from "./scenes/Closing";
import { Hook, Promise } from "./scenes/Opening";
import { PhoneScene } from "./scenes/PhoneScene";
import { SFX } from "./sound";
import { Bokeh, Grade } from "./stage/Atmosphere";
import { IPadStage, STAGE_END } from "./stage/IPadStage";
import { DROP, DURATION, MUSIC_TRIM_BEFORE, SHOTS } from "./timeline";
import { speaking, VOICE } from "./voice";

export const wingmanSchema = z.object({
  bgm: z.boolean(), // false renders the same film with voice and sound effects only
});

const shot = (name: keyof typeof SHOTS, extra = 0) => ({
  from: SHOTS[name].from,
  durationInFrames: SHOTS[name].to - SHOTS[name].from + extra,
});

// Real motion blur (several sub-frames blended) only where things move fast,
// so the render stays quick everywhere else.
const BLUR_WINDOWS: [number, number][] = [
  [DROP - 14, DROP + 8], // the swing on the drop
  [STAGE_END - 12, STAGE_END + 22], // the iPad leaves, the iPhone rises
  [SHOTS.phone.to - 10, SHOTS.phone.to + 2], // into the montage
  [SHOTS.end.from - 2, SHOTS.end.from + 16], // the icon turns in
];

const Picture: React.FC = () => (
  <AbsoluteFill style={{ background: "#000" }}>
    <Bokeh />
    <Sequence from={0} durationInFrames={STAGE_END + 1} name="iPad stage">
      <IPadStage />
    </Sequence>
    <Sequence {...shot("hook", 10)} name="Hook">
      <Hook />
    </Sequence>
    <Sequence {...shot("promise")} name="Promise">
      <Promise />
    </Sequence>
    <Sequence {...shot("dock")} name="Dock">
      <DockCaptions />
    </Sequence>
    <Sequence {...shot("controls")} name="Controls">
      <ControlsCaptions />
    </Sequence>
    <Sequence {...shot("phone")} name="iPhone">
      <PhoneScene />
    </Sequence>
    <Sequence {...shot("montage")} name="And more">
      <Montage />
    </Sequence>
    <Sequence {...shot("end")} name="End card">
      <EndCard />
    </Sequence>
    <Grade />
  </AbsoluteFill>
);

const BlurredPicture: React.FC = () => {
  const f = useCurrentFrame();
  const blur = BLUR_WINDOWS.some(([a, b]) => f >= a && f <= b);
  return blur ? (
    <CameraMotionBlur shutterAngle={200} samples={8}>
      <Picture />
    </CameraMotionBlur>
  ) : (
    <Picture />
  );
};

export const WingmanFilm: React.FC<z.infer<typeof wingmanSchema>> = ({ bgm }) => {
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <BlurredPicture />

      {bgm ? (
        <Audio
          src={staticFile("music/house-vibez.mp3")}
          trimBefore={MUSIC_TRIM_BEFORE}
          volume={(f) =>
            (0.6 - 0.28 * speaking(f)) *
            interpolate(f, [0, 6, DURATION - 45, DURATION - 2], [0, 1, 1, 0], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            })
          }
        />
      ) : null}
      {VOICE.map((v) => (
        <Sequence key={v.key} from={v.from} durationInFrames={v.frames + 10} name={`voice: ${v.key}`}>
          <Audio src={staticFile(v.src)} volume={1} />
        </Sequence>
      ))}
      {SFX.map((s, i) => (
        <Sequence key={i} from={s.from} durationInFrames={s.frames ?? 90} name={`sfx: ${s.note}`}>
          <Audio src={staticFile(s.src)} volume={s.volume} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
