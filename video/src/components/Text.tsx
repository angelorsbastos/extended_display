import React from "react";
import { useCurrentFrame } from "remotion";
import { easeIn, easeOut, ramp } from "../motion";
import { fontFamily, T } from "../theme";

/**
 * A line that rises out of an invisible slot (mask reveal) at `inAt`, and
 * leaves upwards at `outAt` (optional). Text is either fully readable or gone.
 */
export const RiseLine: React.FC<{
  children: React.ReactNode;
  inAt: number;
  outAt?: number;
  size: number;
  weight?: number;
  color?: string;
  inFrames?: number;
  outFrames?: number;
  tracking?: number;
  style?: React.CSSProperties;
}> = ({
  children,
  inAt,
  outAt,
  size,
  weight = 700,
  color = T.text,
  inFrames = 16,
  outFrames = 9,
  tracking = -0.035,
  style,
}) => {
  const frame = useCurrentFrame();
  const enter = ramp(frame, inAt, inAt + inFrames, easeOut);
  const leave = outAt === undefined ? 0 : ramp(frame, outAt, outAt + outFrames, easeIn);
  const y = (1 - enter) * 130 - leave * 130;
  return (
    <div style={{ overflow: "hidden", paddingBottom: size * 0.12, marginBottom: -size * 0.12, ...style }}>
      <div
        style={{
          transform: `translateY(${y}%)`,
          fontFamily,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: `${tracking}em`,
          lineHeight: 1.04,
          color,
          whiteSpace: "nowrap",
        }}
      >
        {children}
      </div>
    </div>
  );
};

/** Small spaced capitals in the accent blue, the label above a caption. */
export const Label: React.FC<{ children: React.ReactNode; opacity?: number; color?: string }> = ({
  children,
  opacity = 1,
  color = T.accent,
}) => (
  <div
    style={{
      fontFamily,
      fontSize: 34,
      fontWeight: 700,
      letterSpacing: "0.22em",
      textTransform: "uppercase",
      color,
      opacity,
    }}
  >
    {children}
  </div>
);
