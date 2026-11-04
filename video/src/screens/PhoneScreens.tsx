import React from "react";
import { ChevronLeft, CornerDownRight, Keyboard, LogOut } from "lucide-react";
import { fontFamily, T } from "../theme";
import { AppIcon } from "./ui";

// The iPhone's Trackpad screen (ipad/Wingman/PhoneViews.swift), 393 x 852,
// and a stylised laptop desktop (1280 x 800) whose cursor follows the finger.

export const SURFACE = { x: 16, y: 112, w: 361, h: 600 };

export type Touch = { x: number; y: number; down: number; two?: number; tap?: number };

export const TrackpadScreen: React.FC<{ touch: Touch; appear: number }> = ({ touch, appear }) => (
  <div style={{ position: "absolute", inset: 0, background: T.background, fontFamily, color: T.text }}>
    <div style={{ position: "absolute", left: 16, top: 58, display: "flex", alignItems: "center", gap: 10, opacity: appear }}>
      <div
        style={{
          width: 40,
          height: 40,
          borderRadius: 20,
          background: T.tile,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <ChevronLeft size={22} strokeWidth={2.6} />
      </div>
      <div style={{ fontSize: 26, fontWeight: 800 }}>Trackpad</div>
    </div>
    <div
      style={{
        position: "absolute",
        left: SURFACE.x,
        top: SURFACE.y,
        width: SURFACE.w,
        height: SURFACE.h,
        borderRadius: T.radius,
        background: T.tile,
        overflow: "hidden",
      }}
    >
      {/* the finger(s) */}
      {[0, 1].map((k) => {
        if (k === 1 && !touch.two) return null;
        const dx = k === 1 ? 46 : 0;
        return (
          <div
            key={k}
            style={{
              position: "absolute",
              left: touch.x - SURFACE.x + dx - 30,
              top: touch.y - SURFACE.y - 30,
              width: 60,
              height: 60,
              borderRadius: 30,
              background: "radial-gradient(circle, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.18) 55%, transparent 72%)",
              opacity: touch.down * (k === 1 ? touch.two ?? 0 : 1),
              transform: `scale(${0.8 + 0.2 * touch.down})`,
            }}
          />
        );
      })}
      {touch.tap ? (
        <div
          style={{
            position: "absolute",
            left: touch.x - SURFACE.x - 50,
            top: touch.y - SURFACE.y - 50,
            width: 100,
            height: 100,
            borderRadius: 50,
            border: "2px solid rgba(255,255,255,0.6)",
            transform: `scale(${0.3 + 0.9 * touch.tap})`,
            opacity: 1 - touch.tap,
          }}
        />
      ) : null}
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          bottom: 12,
          textAlign: "center",
          fontSize: 12,
          color: T.secondary,
        }}
      >
        Tap to click · two fingers to scroll or right-click
      </div>
    </div>
    <div style={{ position: "absolute", left: 16, right: 16, top: 728, display: "flex", gap: 12 }}>
      {[
        ["Esc", LogOut],
        ["Tab", CornerDownRight],
        ["Keyboard", Keyboard],
      ].map(([label, Icon]) => {
        const I = Icon as typeof Keyboard;
        return (
          <div
            key={label as string}
            style={{
              flex: 1,
              height: 48,
              borderRadius: 14,
              background: T.tile,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 6,
              fontSize: 15,
              fontWeight: 600,
            }}
          >
            <I size={16} strokeWidth={2.4} /> {label as string}
          </div>
        );
      })}
    </div>
  </div>
);

/** A stylised Windows 11 desktop: a soft bloom wallpaper, a window, the taskbar, the cursor. */
export const LaptopDesktop: React.FC<{ cursor: { x: number; y: number }; click: number; scroll: number }> = ({
  cursor,
  click,
  scroll,
}) => (
  <div
    style={{
      position: "absolute",
      inset: 0,
      fontFamily,
      background:
        "radial-gradient(ellipse at 60% 65%, rgba(47,107,255,0.55) 0%, transparent 45%), radial-gradient(ellipse at 35% 80%, rgba(120,80,255,0.35) 0%, transparent 40%), linear-gradient(180deg, #070a14 0%, #0d1530 100%)",
      overflow: "hidden",
    }}
  >
    {/* a browser-ish window */}
    <div
      style={{
        position: "absolute",
        left: 170,
        top: 90,
        width: 940,
        height: 560,
        borderRadius: 14,
        background: "#1b1c21",
        boxShadow: "0 30px 80px rgba(0,0,0,0.5)",
        overflow: "hidden",
      }}
    >
      <div style={{ height: 52, background: "#24252b", display: "flex", alignItems: "center", padding: "0 18px", gap: 12 }}>
        <div style={{ width: 260, height: 30, borderRadius: 8, background: "#1b1c21" }} />
        <div style={{ flex: 1 }} />
        {[0, 1, 2].map((i) => (
          <div key={i} style={{ width: 14, height: 14, borderRadius: 7, background: "#3a3c44" }} />
        ))}
      </div>
      <div style={{ padding: 34, transform: `translateY(${-scroll * 180}px)` }}>
        <div style={{ width: 520, height: 34, borderRadius: 8, background: "#e9eaee", marginBottom: 22 }} />
        {[0.95, 0.88, 0.92, 0.7, 0.9, 0.84, 0.6, 0.93, 0.8, 0.88, 0.7].map((wv, i) => (
          <div key={i} style={{ width: `${wv * 100}%`, height: 16, borderRadius: 6, background: "#3a3c44", marginBottom: 16 }} />
        ))}
        <div style={{ display: "flex", gap: 18, marginTop: 10 }}>
          {[0, 1, 2].map((i) => (
            <div key={i} style={{ flex: 1, height: 150, borderRadius: 12, background: i === 1 ? "rgba(47,107,255,0.5)" : "#2a2c33" }} />
          ))}
        </div>
      </div>
    </div>
    {/* taskbar */}
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 0,
        height: 64,
        background: "rgba(20,22,30,0.85)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 14,
      }}
    >
      {[1, 2, 3, 5, 6].map((i) => (
        <AppIcon key={i} index={i} size={38} />
      ))}
    </div>
    {/* click ripple */}
    {click > 0 && click < 1 ? (
      <div
        style={{
          position: "absolute",
          left: cursor.x - 40,
          top: cursor.y - 40,
          width: 80,
          height: 80,
          borderRadius: 40,
          border: `3px solid rgba(${T.accentRGB},0.9)`,
          transform: `scale(${0.2 + click})`,
          opacity: 1 - click,
        }}
      />
    ) : null}
    {/* the cursor */}
    <svg
      width={34}
      height={46}
      viewBox="0 0 17 23"
      style={{ position: "absolute", left: cursor.x - 2, top: cursor.y - 2, filter: "drop-shadow(0 2px 3px rgba(0,0,0,0.6))" }}
    >
      <path d="M1 1 L1 18 L5.5 14 L8.5 21 L11.5 19.8 L8.6 13 L14.5 13 Z" fill="#fff" stroke="#000" strokeWidth={1.2} strokeLinejoin="round" />
    </svg>
  </div>
);
