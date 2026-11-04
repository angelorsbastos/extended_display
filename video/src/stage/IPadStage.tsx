import React from "react";
import { AbsoluteFill, interpolateColors, useCurrentFrame } from "remotion";
import { IPAD, IPadFrame } from "../components/Devices";
import { WingmanIcon } from "../components/WingmanIcon";
import { Cam3Key, camera3d, easeIn, ramp } from "../motion";
import { ccState, dashPush, dashState } from "../scenes/ControlsScene";
import { dockNight, dockState } from "../scenes/DockScene";
import { ControlCenterScreen } from "../screens/ControlCenterScreen";
import { DashboardScreen } from "../screens/DashboardScreen";
import { DockScreen } from "../screens/DockScreen";
import { T } from "../theme";
import { beatF, DROP, SHOTS } from "../timeline";

// One iPad, one continuous camera, from the dark opening to the controls:
// it turns out of the dark at an angle, swings to face us on the drop, then
// the camera travels over the Dock, the Control Center and the dashboard.

export const IPAD_W = 1000;
export const IPAD_H = (IPAD.h + IPAD.bezel * 2) * (IPAD_W / (IPAD.w + IPAD.bezel * 2));
export const STAGE_END = beatF(38) + 4;

const D = (n: number) => beatF(n); // global frame of beat n
const Y = 1180; // the iPad's usual centre line

// [frame, scale, fx, fy, rotateY, rotateX, centre y]
const KEYS: Cam3Key[] = [
  [0, 1.3, 0.5, 0.5, -40, 16, 900],
  [SHOTS.promise.from, 1.02, 0.5, 0.5, -26, 11, 1060],
  [DROP - 12, 0.94, 0.5, 0.5, -20, 9, 1200],
  [DROP + 6, 1.0, 0.5, 0.5, 0, 0, Y], // the swing on the drop
  [D(3.5), 1.0, 0.5, 0.5, 0, 0, Y],
  [D(4.5), 1.55, 0.75, 0.25, -7, 2, Y], // the song
  [D(7.5), 1.58, 0.74, 0.25, -6, 2, Y],
  [D(8.5), 1.5, 0.31, 0.57, 7, 2, Y], // clock and timer
  [D(11.5), 1.53, 0.31, 0.57, 6, 2, Y],
  [D(12.8), 1.04, 0.5, 0.5, 0, 0, Y], // night, the whole screen
  [D(19.5), 1.06, 0.5, 0.5, -4, 3, Y],
  [D(20.5), 1.0, 0.5, 0.5, 0, 0, Y], // Control Center
  [D(25), 1.0, 0.5, 0.5, 0, 0, Y],
  [D(26), 1.45, 0.73, 0.62, -6, 2, Y], // the sliders
  [D(29), 1.48, 0.73, 0.62, -5, 2, Y],
  [D(30), 1.0, 0.5, 0.5, 0, 0, Y],
  [D(31), 1.0, 0.5, 0.5, 0, 0, Y],
  [D(32), 1.6, 0.29, 0.37, 6, 2, Y], // the processor card
  [D(35.5), 1.63, 0.29, 0.37, 5, 2, Y],
  [D(36.5), 1.0, 0.5, 0.5, 0, 0, Y],
  [D(37.4), 1.0, 0.5, 0.5, -6, 2, Y],
  [STAGE_END, 0.9, 1.5, 0.5, -34, 6, Y], // it leaves to the left
];

/** The iPad's screen before the drop: black, then the Wingman icon wakes up. */
const WakeScreen: React.FC<{ f: number }> = ({ f }) => {
  const wake = ramp(f, 26, 56);
  return (
    <AbsoluteFill style={{ background: "#000", alignItems: "center", justifyContent: "center" }}>
      <div
        style={{
          position: "absolute",
          width: 900,
          height: 900,
          borderRadius: "50%",
          background: `radial-gradient(circle, rgba(${T.accentRGB},0.45) 0%, transparent 60%)`,
          opacity: wake,
        }}
      />
      <div style={{ opacity: wake, transform: `scale(${0.92 + 0.08 * wake})` }}>
        <WingmanIcon size={230} plate={wake} device={ramp(f, 34, 52)} wingman={ramp(f, 40, 62)} />
      </div>
    </AbsoluteFill>
  );
};

export const IPadStage: React.FC = () => {
  const f = useCurrentFrame(); // global frame (the stage starts at 0)
  const cam = camera3d(f, KEYS, IPAD_W, IPAD_H);
  const dockF = f - SHOTS.dock.from;
  const ccF = f - SHOTS.controls.from;

  // the room is dark until the iPad wakes; a light runs along its frame twice
  const dark = 1 - ramp(f, 4, 60);
  const sheen = f < 90 ? ramp(f, 8, 70) : f >= DROP && f < DROP + 30 ? ramp(f, DROP + 2, DROP + 28) : undefined;
  const night = f >= SHOTS.dock.from && f < SHOTS.controls.from ? dockNight(dockF) : 0;
  const toDock = ramp(f, DROP - 3, DROP + 3);

  let screen: React.ReactNode;
  if (f < SHOTS.dock.from) {
    screen = <WakeScreen f={f} />;
  } else if (f < SHOTS.controls.from) {
    screen = (
      <>
        <DockScreen s={dockState(dockF)} />
        {toDock < 1 ? (
          <AbsoluteFill style={{ opacity: 1 - toDock }}>
            <WakeScreen f={f} />
          </AbsoluteFill>
        ) : null}
      </>
    );
  } else {
    const push = dashPush(ccF);
    screen = (
      <>
        <div style={{ position: "absolute", inset: 0, transform: `translateX(${-push * 30}%)`, opacity: 1 - push * 0.6 }}>
          <ControlCenterScreen s={ccState(ccF)} />
        </div>
        {push > 0 ? (
          <div
            style={{
              position: "absolute",
              inset: 0,
              transform: `translateX(${(1 - push) * 100}%)`,
              boxShadow: "-20px 0 40px rgba(0,0,0,0.5)",
            }}
          >
            <DashboardScreen s={dashState(ccF)} />
          </div>
        ) : null}
      </>
    );
  }

  const exit = ramp(f, STAGE_END - 10, STAGE_END, easeIn);
  const pool = interpolateColors(night, [0, 1], [`rgba(${T.accentRGB},0.20)`, "rgba(199,51,46,0.20)"]);
  return (
    <AbsoluteFill style={{ opacity: 1 - exit }}>
      {/* a pool of light on the desk, under the device */}
      <div
        style={{
          position: "absolute",
          left: -300,
          top: 650,
          width: 1680,
          height: 1150,
          background: `radial-gradient(ellipse, ${pool} 0%, transparent 62%)`,
          opacity: 1 - dark * 0.8,
        }}
      />
      <div style={{ position: "absolute", left: 0, top: 0, transform: cam.transform, transformOrigin: "0 0" }}>
        <IPadFrame width={IPAD_W} sheen={sheen} reflect={Math.min(1, Math.max(0, (1.12 - cam.scale) / 0.1))}>
          {screen}
        </IPadFrame>
      </div>
    </AbsoluteFill>
  );
};
