import React from "react";
import { Composition } from "remotion";
import { WingmanFilm, wingmanSchema } from "./Composition";
import { DURATION, FPS, HEIGHT, WIDTH } from "./timeline";

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="Wingman"
      component={WingmanFilm}
      durationInFrames={DURATION}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
      schema={wingmanSchema}
      defaultProps={{ bgm: true }}
    />
  );
};
