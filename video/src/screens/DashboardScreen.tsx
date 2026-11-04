import React from "react";
import { BatteryCharging, ChevronLeft, Cpu, Fan, Layers, MemoryStick, Zap } from "lucide-react";
import { fontFamily, T } from "../theme";

// The ROG dashboard (ipad/Wingman/DashboardView.swift), 1180 x 820:
// processor, graphics, memory and battery cards with big numbers and graphs.

export type DashState = {
  frame: number;
  cardsIn: number; // 0..1
  count: number; // 0..1, numbers count up, graphs draw
};

const PAD = 24;
const GAP = 20;
const yellow = "rgb(255,214,10)";
const green = "rgb(48,209,88)";

const Card: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  title: string;
  Icon: typeof Cpu;
  tint: string;
  appear: number;
  children: React.ReactNode;
}> = ({ x, y, w, h, title, Icon, tint, appear, children }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width: w,
      height: h,
      borderRadius: T.radius,
      background: T.tile,
      padding: 22,
      boxSizing: "border-box",
      opacity: appear,
      transform: `translateY(${(1 - appear) * 36}px)`,
      display: "flex",
      flexDirection: "column",
      gap: 16,
    }}
  >
    <div style={{ display: "flex", alignItems: "center", gap: 8, color: tint, fontSize: 18, fontWeight: 700 }}>
      <Icon size={20} strokeWidth={2.4} /> {title}
    </div>
    {children}
  </div>
);

const Big: React.FC<{ items: [string, string, string][] }> = ({ items }) => (
  <div style={{ display: "flex", gap: 44 }}>
    {items.map(([label, value, color]) => (
      <div key={label}>
        <div style={{ fontSize: 13, color: T.secondary, marginBottom: 2 }}>{label}</div>
        <div style={{ fontSize: 46, fontWeight: 700, color, fontVariantNumeric: "tabular-nums", letterSpacing: "-0.02em" }}>
          {value}
        </div>
      </div>
    ))}
  </div>
);

const Graph: React.FC<{ w: number; seed: number; color: string; draw: number; frame: number }> = ({
  w,
  seed,
  color,
  draw,
  frame,
}) => {
  const n = 40;
  const pts = Array.from({ length: n }, (_, i) => {
    const v =
      0.55 +
      0.18 * Math.sin(i * 0.45 + seed) +
      0.1 * Math.sin(i * 1.3 + seed * 2 + frame * 0.04) +
      (i / n) * 0.15;
    return [(i / (n - 1)) * w, 54 - v * 46];
  });
  const d = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  return (
    <svg width={w} height={56} style={{ overflow: "visible" }}>
      <defs>
        <clipPath id={`g${seed}`}>
          <rect x={0} y={-4} width={w * draw} height={64} />
        </clipPath>
      </defs>
      <g clipPath={`url(#g${seed})`}>
        <path d={`${d} L${w},56 L0,56 Z`} fill={color} opacity={0.14} />
        <path d={d} fill="none" stroke={color} strokeWidth={2.5} strokeLinejoin="round" />
      </g>
    </svg>
  );
};

export const DashboardScreen: React.FC<{ s: DashState }> = ({ s }) => {
  const cw = (1180 - PAD * 2 - GAP) / 2;
  const top = 96;
  const ch1 = 360;
  const ch2 = 820 - PAD - top - ch1 - GAP;
  const ap = (i: number) => {
    const t = Math.min(1, Math.max(0, s.cardsIn * 1.6 - i * 0.2));
    return 1 - Math.pow(1 - t, 3);
  };
  const c = s.count;
  const cpuT = Math.round(41 + (78 - 41) * c);
  const gpuT = Math.round(38 + (71 - 38) * c);
  const cpuU = Math.round(8 + (64 - 8) * c);
  const gpuU = Math.round(3 + (88 - 3) * c);
  const fan = Math.round((2100 + (5600 - 2100) * c) / 10) * 10;
  const tempColor = (v: number) => (v < 60 ? green : v < 80 ? yellow : "rgb(255,69,58)");

  return (
    <div style={{ position: "absolute", inset: 0, background: T.background, fontFamily, color: T.text }}>
      <div
        style={{
          position: "absolute",
          left: PAD,
          top: PAD,
          display: "flex",
          alignItems: "center",
          gap: 12,
          opacity: Math.min(1, s.cardsIn * 4),
        }}
      >
        <div
          style={{
            width: 44,
            height: 44,
            borderRadius: 22,
            background: T.tile,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <ChevronLeft size={24} strokeWidth={2.6} />
        </div>
        <div style={{ fontSize: 30, fontWeight: 800 }}>Dashboard</div>
      </div>

      <Card x={PAD} y={top} w={cw} h={ch1} title="Processor" Icon={Cpu} tint={tempColor(cpuT)} appear={ap(0)}>
        <Big items={[["Temperature", `${cpuT}°`, tempColor(cpuT)], ["Usage", `${cpuU}%`, T.text]]} />
        <Graph w={cw - 44} seed={1} color={tempColor(cpuT)} draw={c} frame={s.frame} />
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: T.secondary, fontSize: 16 }}>
          <div style={{ transform: `rotate(${s.frame * (6 + 30 * c)}deg)`, display: "flex" }}>
            <Fan size={20} strokeWidth={2.2} />
          </div>
          <span style={{ fontVariantNumeric: "tabular-nums" }}>{fan} RPM</span>
        </div>
      </Card>
      <Card x={PAD + cw + GAP} y={top} w={cw} h={ch1} title="Graphics" Icon={Layers} tint={tempColor(gpuT)} appear={ap(1)}>
        <Big items={[["Temperature", `${gpuT}°`, tempColor(gpuT)], ["Usage", `${gpuU}%`, T.text]]} />
        <Graph w={cw - 44} seed={4} color={tempColor(gpuT)} draw={c} frame={s.frame} />
        <div style={{ display: "flex", alignItems: "center", gap: 18, color: T.secondary, fontSize: 16 }}>
          <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
            <Zap size={18} /> {(12 + 48 * c).toFixed(1)} W
          </span>
          <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
            <div style={{ transform: `rotate(${s.frame * (6 + 26 * c)}deg)`, display: "flex" }}>
              <Fan size={18} />
            </div>
            <span style={{ fontVariantNumeric: "tabular-nums" }}>{fan - 300} RPM</span>
          </span>
        </div>
      </Card>
      <Card x={PAD} y={top + ch1 + GAP} w={cw} h={ch2} title="Memory" Icon={MemoryStick} tint={T.secondary} appear={ap(2)}>
        <div style={{ fontSize: 13, color: T.secondary }}>In use · {(4.2 + 6.1 * c).toFixed(1)} of 16.0 GB</div>
        <div style={{ height: 10, borderRadius: 5, background: T.tileRaised, overflow: "hidden" }}>
          <div style={{ width: `${(26 + 38 * c).toFixed(1)}%`, height: "100%", background: T.accent, borderRadius: 5 }} />
        </div>
        <div style={{ fontSize: 15, color: T.secondary }}>Power plan: Turbo</div>
      </Card>
      <Card
        x={PAD + cw + GAP}
        y={top + ch1 + GAP}
        w={cw}
        h={ch2}
        title="Battery"
        Icon={BatteryCharging}
        tint={T.secondary}
        appear={ap(3)}
      >
        <Big items={[["Charge", `${Math.round(54 + 32 * c)}%`, T.text], ["Health", "96%", green]]} />
      </Card>
    </div>
  );
};
