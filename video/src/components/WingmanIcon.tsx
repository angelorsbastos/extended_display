import React from "react";
import { T } from "../theme";

// The Wingman icon (pc/assets/make_icon.py), on its 100 x 100 grid:
// a big device with a smaller one at its side, white on blue.
// Each part has its own 0..1 progress so the icon can build itself.
export const WingmanIcon: React.FC<{
  size: number;
  plate?: number; // the blue squircle
  device?: number; // the big white device
  wingman?: number; // the outlined small one
  night?: boolean;
}> = ({ size, plate = 1, device = 1, wingman = 1 }) => {
  const perimeter = 2 * (18 + 28) - (4 - Math.PI) * 2 * 5; // rounded rect outline length
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ overflow: "visible" }}>
      <defs>
        <linearGradient id="wm-plate" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="rgb(70,128,255)" />
          <stop offset="100%" stopColor={T.accent} />
        </linearGradient>
      </defs>
      <g
        style={{
          transformOrigin: "50px 50px",
          transform: `scale(${0.6 + 0.4 * plate})`,
          opacity: Math.min(1, plate * 1.4),
        }}
      >
        <rect x={0} y={0} width={100} height={100} rx={22} fill="url(#wm-plate)" />
        <rect
          x={0.5}
          y={0.5}
          width={99}
          height={99}
          rx={21.5}
          fill="none"
          stroke="rgba(255,255,255,0.18)"
          strokeWidth={1}
        />
      </g>
      <g
        style={{
          transformOrigin: "39px 50px",
          transform: `scale(${device})`,
          opacity: Math.min(1, device * 3),
        }}
      >
        <rect x={20} y={28} width={38} height={44} rx={7} fill={T.on} />
      </g>
      <g
        style={{
          transform: `translateX(${(1 - wingman) * -14}px)`,
          opacity: Math.min(1, wingman * 2),
        }}
      >
        <rect
          x={64}
          y={38}
          width={14}
          height={24}
          rx={3}
          fill="none"
          stroke={T.on}
          strokeWidth={4}
          strokeDasharray={perimeter}
          strokeDashoffset={perimeter * (1 - wingman)}
          strokeLinecap="round"
        />
      </g>
    </svg>
  );
};
