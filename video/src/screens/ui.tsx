import React from "react";
import type { LucideIcon } from "lucide-react";
import {
  Code2,
  FolderOpen,
  Gamepad2,
  Globe,
  MessageCircle,
  Music2,
  NotebookPen,
  Terminal,
} from "lucide-react";
import { fontFamily, T } from "../theme";

// Building blocks of Wingman's screens, in the app's own points.

export type TileStyle = "normal" | "on" | "accent";

export const tileFill = (style: TileStyle) =>
  style === "on" ? T.on : style === "accent" ? T.accent : T.tile;

export const Tile: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  style?: TileStyle;
  children?: React.ReactNode;
  pad?: number;
  extra?: React.CSSProperties;
}> = ({ x, y, w, h, style = "normal", children, pad = 14, extra }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width: w,
      height: h,
      borderRadius: T.radius,
      background: tileFill(style),
      color: style === "on" ? T.onText : T.text,
      padding: pad,
      boxSizing: "border-box",
      overflow: "hidden",
      fontFamily,
      ...extra,
    }}
  >
    {children}
  </div>
);

export const TileLabel: React.FC<{
  Icon: LucideIcon;
  title: string;
  detail?: string;
  on?: boolean;
}> = ({ Icon, title, detail, on }) => (
  <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
    <Icon size={24} strokeWidth={2.4} />
    <div style={{ flex: 1 }} />
    <div style={{ fontSize: 15, fontWeight: 600, lineHeight: 1.15 }}>{title}</div>
    {detail ? (
      <div style={{ fontSize: 12, marginTop: 3, color: on ? "rgba(16,17,20,0.65)" : T.secondary }}>
        {detail}
      </div>
    ) : null}
  </div>
);

// Stand-ins for the user's app shortcuts (the real app shows each app's own
// icon; brand logos aren't ours to put in a film, so these are generic).
export const APPS: { name: string; Icon: LucideIcon; from: string; to: string }[] = [
  { name: "Music", Icon: Music2, from: "#3ddc84", to: "#12a150" },
  { name: "Browser", Icon: Globe, from: "#5aa2ff", to: "#1f5fe0" },
  { name: "Code", Icon: Code2, from: "#4fc3f7", to: "#1673c9" },
  { name: "Chat", Icon: MessageCircle, from: "#a78bfa", to: "#6d3fe0" },
  { name: "Games", Icon: Gamepad2, from: "#ff6b6b", to: "#d6283b" },
  { name: "Files", Icon: FolderOpen, from: "#ffd166", to: "#f0a020" },
  { name: "Terminal", Icon: Terminal, from: "#5b5f6b", to: "#2a2c33" },
  { name: "Notes", Icon: NotebookPen, from: "#ffe58a", to: "#f5c518" },
];

/** An app icon: a little squircle with a glyph, like a real app's icon. */
export const AppIcon: React.FC<{ index: number; size: number; mono?: string }> = ({
  index,
  size,
  mono,
}) => {
  const app = APPS[index % APPS.length];
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.24,
        background: mono ? "transparent" : `linear-gradient(160deg, ${app.from}, ${app.to})`,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: mono ? undefined : "inset 0 0 0 1px rgba(255,255,255,0.12)",
      }}
    >
      <app.Icon size={size * 0.56} strokeWidth={2.2} color={mono ?? "#fff"} />
    </div>
  );
};

/** Generated cover art for the made-up song (no real album art in the film). */
export const CoverArt: React.FC<{ size: number; radius?: number }> = ({ size, radius = 10 }) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: radius,
      position: "relative",
      overflow: "hidden",
      background:
        "radial-gradient(circle at 30% 25%, #ff8bd1 0%, transparent 45%), radial-gradient(circle at 75% 70%, #5b6cff 0%, transparent 55%), linear-gradient(140deg, #5a1a8f, #14123a)",
      flexShrink: 0,
    }}
  >
    <div
      style={{
        position: "absolute",
        left: "18%",
        right: "18%",
        bottom: "22%",
        height: 2,
        background: "rgba(255,255,255,0.55)",
        boxShadow: "0 -8px 0 rgba(255,255,255,0.25), 0 -16px 0 rgba(255,255,255,0.12)",
      }}
    />
  </div>
);

export const SONG = { title: "Midnight Drive", artist: "Nova Lane", hueColour: "rgb(186,72,230)" };
