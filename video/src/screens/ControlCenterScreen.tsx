import React from "react";
import { interpolateColors } from "remotion";
import {
  Clipboard,
  Clock,
  FolderUp,
  Keyboard,
  Pause,
  Play,
  Settings,
  SkipBack,
  SkipForward,
  Sun,
  Thermometer,
  Volume2,
  VolumeX,
  Wifi,
  BatteryCharging,
  Copy,
  RectangleHorizontal,
} from "lucide-react";
import { fontFamily, T } from "../theme";
import { AppIcon, CoverArt, SONG, Tile, TileLabel } from "./ui";

// The home screen, a Control Center for the laptop
// (ipad/ExtendDisplay/ControlCenterView.swift, iPad 4 x 5 grid), 1180 x 820.

export type CCState = {
  tilesIn: number; // 0..1, tiles cascade in
  soundOn: number; // 0..1, "Sound here" turns white
  volume: number; // 0..1
  brightness: number; // 0..1
  playing: boolean;
  press: { tile: string; t: number } | null; // a tap: the tile shrinks a little
};

const PAD = 24;
const GAP = T.gap;
const GRID_TOP = 100;
const GW = 1180 - PAD * 2;
const GH = 820 - PAD - GRID_TOP;
const w = (GW - 3 * GAP) / 4;
const h = (GH - 4 * GAP) / 5;

const Pill: React.FC<{ children: React.ReactNode; tint?: string }> = ({ children, tint = T.text }) => (
  <div
    style={{
      height: 40,
      padding: "0 14px",
      borderRadius: 20,
      background: T.tile,
      display: "flex",
      alignItems: "center",
      gap: 7,
      fontSize: 15,
      fontWeight: 600,
      color: tint,
    }}
  >
    {children}
  </div>
);

const SliderTile: React.FC<{ x: number; y: number; w: number; h: number; level: number; Icon: typeof Sun }> = ({
  x,
  y,
  w: tw,
  h: th,
  level,
  Icon,
}) => (
  <Tile x={x} y={y} w={tw} h={th} pad={0}>
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: th * level, background: T.on }} />
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 18,
        display: "flex",
        justifyContent: "center",
        color: level > 0.12 ? T.onText : T.text,
      }}
    >
      <Icon size={26} strokeWidth={2.5} />
    </div>
  </Tile>
);

export const ControlCenterScreen: React.FC<{ s: CCState }> = ({ s }) => {
  // tiles arrive one after another, faster and faster
  const order = ["extend", "mirror", "sound", "volume", "now", "keys", "dock", "clip", "files", "bright", "shortcuts"];
  const appear = (name: string): React.CSSProperties => {
    const i = order.indexOf(name);
    const start = Math.pow(i / order.length, 0.8) * 0.6;
    const t = Math.min(1, Math.max(0, (s.tilesIn - start) / 0.4));
    const e = 1 - Math.pow(1 - t, 3);
    const pressed = s.press && s.press.tile === name ? 1 - 0.05 * Math.sin(Math.PI * s.press.t) : 1;
    return {
      opacity: e,
      transform: `translateY(${(1 - e) * 40}px) scale(${(0.94 + 0.06 * e) * pressed})`,
    };
  };
  const at = (name: string, el: React.ReactNode) => (
    <div key={name} style={{ position: "absolute", inset: 0, ...appear(name) }}>
      {el}
    </div>
  );
  const soundBg = interpolateColors(s.soundOn, [0, 1], [T.tile, T.on]);
  const soundFg = interpolateColors(s.soundOn, [0, 1], [T.text, T.onText]);
  const x2 = w * 2 + GAP * 2;
  const x3 = w * 3 + GAP * 3;
  const third = (2 * w - GAP) / 3;

  return (
    <div style={{ position: "absolute", inset: 0, background: T.background, fontFamily, color: T.text }}>
      {/* header */}
      <div
        style={{
          position: "absolute",
          left: PAD,
          right: PAD,
          top: PAD,
          height: 60,
          display: "flex",
          alignItems: "center",
          gap: 10,
          opacity: Math.min(1, s.tilesIn * 4),
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          <div style={{ fontSize: 34, fontWeight: 800, letterSpacing: "-0.01em" }}>LAPRÉ</div>
          <div style={{ fontSize: 15, color: T.secondary }}>Connected over Wi-Fi</div>
        </div>
        <div style={{ flex: 1 }} />
        <Pill>
          <Settings size={18} strokeWidth={2.4} />
        </Pill>
        <Pill tint={T.good}>
          <Wifi size={18} strokeWidth={2.6} /> Wi-Fi
        </Pill>
        <Pill>
          <BatteryCharging size={20} strokeWidth={2.2} /> 86%
        </Pill>
        <Pill tint={T.good}>
          <Thermometer size={18} strokeWidth={2.4} /> 64°
        </Pill>
      </div>

      <div style={{ position: "absolute", left: PAD, top: GRID_TOP, width: GW, height: GH }}>
        {at(
          "extend",
          <Tile x={0} y={0} w={w * 2 + GAP} h={h * 2 + GAP} style="accent">
            <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
              <Copy size={30} strokeWidth={2.4} />
              <div style={{ flex: 1 }} />
              <div style={{ fontSize: 30, fontWeight: 800, letterSpacing: "-0.01em" }}>Extend</div>
              <div style={{ fontSize: 16, opacity: 0.8, marginTop: 4 }}>Use the iPad as a second screen</div>
            </div>
            <div
              style={{
                position: "absolute",
                right: 18,
                bottom: 18,
                width: 120,
                height: 82,
                borderRadius: 10,
                background: "rgba(255,255,255,0.14)",
                border: "2px solid rgba(255,255,255,0.45)",
              }}
            />
          </Tile>,
        )}
        {at(
          "mirror",
          <Tile x={x2} y={0} w={w} h={h}>
            <TileLabel Icon={RectangleHorizontal} title="Mirror" detail="Same picture" />
          </Tile>,
        )}
        {at(
          "sound",
          <Tile x={x2} y={h + GAP} w={w} h={h} extra={{ background: soundBg, color: soundFg }}>
            <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
              {s.soundOn > 0.5 ? <Volume2 size={24} strokeWidth={2.4} /> : <VolumeX size={24} strokeWidth={2.4} />}
              <div style={{ flex: 1 }} />
              <div style={{ fontSize: 15, fontWeight: 600 }}>Sound here</div>
              <div style={{ fontSize: 12, marginTop: 3, opacity: 0.65 }}>
                {s.soundOn > 0.5 ? "On" : "On the laptop"}
              </div>
            </div>
          </Tile>,
        )}
        {at("volume", <SliderTile x={x3} y={0} w={w} h={h * 2 + GAP} level={s.volume} Icon={Volume2} />)}
        {at(
          "now",
          <Tile x={0} y={(h + GAP) * 2} w={w * 2 + GAP} h={h}>
            <div style={{ display: "flex", alignItems: "center", gap: 16, height: "100%" }}>
              <CoverArt size={h - 28} radius={12} />
              <div style={{ display: "flex", flexDirection: "column", gap: 3, flex: 1 }}>
                <div style={{ fontSize: 18, fontWeight: 700 }}>{SONG.title}</div>
                <div style={{ fontSize: 14, color: T.secondary }}>{SONG.artist}</div>
              </div>
              <SkipBack size={26} fill={T.text} strokeWidth={0} />
              <div
                style={{
                  width: 54,
                  height: 54,
                  borderRadius: 27,
                  background: T.on,
                  color: T.onText,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                }}
              >
                {s.playing ? (
                  <Pause size={24} fill={T.onText} strokeWidth={0} />
                ) : (
                  <Play size={24} fill={T.onText} strokeWidth={0} style={{ marginLeft: 3 }} />
                )}
              </div>
              <SkipForward size={26} fill={T.text} strokeWidth={0} />
            </div>
          </Tile>,
        )}
        {at(
          "keys",
          <Tile x={0} y={(h + GAP) * 3} w={w * 2 + GAP} h={h}>
            <div style={{ display: "flex", alignItems: "center", gap: 14, height: "100%" }}>
              <Keyboard size={30} strokeWidth={2.2} />
              <div>
                <div style={{ fontSize: 15, fontWeight: 600 }}>Laptop keyboard and trackpad</div>
                <div style={{ fontSize: 12, color: T.secondary, marginTop: 2 }}>Or Ctrl+Alt+I on the laptop</div>
              </div>
            </div>
          </Tile>,
        )}
        {at(
          "dock",
          <Tile x={0} y={(h + GAP) * 4} w={third} h={h}>
            <TileLabel Icon={Clock} title="Dock" detail="Focus clock" />
          </Tile>,
        )}
        {at(
          "clip",
          <Tile x={third + GAP} y={(h + GAP) * 4} w={third} h={h}>
            <TileLabel Icon={Clipboard} title="Clipboard" detail="12 items" />
          </Tile>,
        )}
        {at(
          "files",
          <Tile x={(third + GAP) * 2} y={(h + GAP) * 4} w={third} h={h}>
            <TileLabel Icon={FolderUp} title="Files" detail="Send both ways" />
          </Tile>,
        )}
        {at("bright", <SliderTile x={x2} y={(h + GAP) * 2} w={w} h={h * 3 + GAP * 2} level={s.brightness} Icon={Sun} />)}
        {at(
          "shortcuts",
          <Tile x={x3} y={(h + GAP) * 2} w={w} h={h * 3 + GAP * 2}>
            <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 14 }}>Shortcuts</div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(2, 1fr)", rowGap: 16, justifyItems: "center" }}>
              {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
                <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
                  <AppIcon index={i} size={56} />
                </div>
              ))}
            </div>
          </Tile>,
        )}
      </div>
    </div>
  );
};
