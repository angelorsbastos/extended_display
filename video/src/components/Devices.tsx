import React from "react";

// Device frames drawn in code. Screens are laid out in the device's own points
// (iPad 10: 1180 x 820 landscape, iPhone 14 Pro: 393 x 852), then scaled.

const frameShadow =
  "0 60px 120px rgba(0,0,0,0.65), 0 0 0 1.5px rgba(255,255,255,0.10), inset 0 0 0 1.5px rgba(255,255,255,0.06)";

export const IPAD = { w: 1180, h: 820, bezel: 30, radius: 46 };
export const IPHONE = { w: 393, h: 852, bezel: 13, radius: 56 };

/** A band of light that slides across a device's frame (0..1), under the screen. */
const Sheen: React.FC<{ at: number; radius: number }> = ({ at, radius }) => (
  <div style={{ position: "absolute", inset: 0, borderRadius: radius, overflow: "hidden" }}>
    <div
      style={{
        position: "absolute",
        top: "-30%",
        bottom: "-30%",
        width: "22%",
        left: `${-30 + at * 140}%`,
        transform: "rotate(18deg)",
        background: "linear-gradient(90deg, transparent, rgba(255,255,255,0.42), transparent)",
      }}
    />
  </div>
);

export const IPadFrame: React.FC<{
  width: number; // on-canvas width of the whole device
  children: React.ReactNode;
  style?: React.CSSProperties;
  sheen?: number; // 0..1, a light passing over the frame
  reflect?: number; // 0..1, a faint reflection on the desk below
}> = ({ width, children, style, sheen, reflect = 0 }) => {
  const outerW = IPAD.w + IPAD.bezel * 2;
  const outerH = IPAD.h + IPAD.bezel * 2;
  const scale = width / outerW;
  return (
    <div style={{ width, height: outerH * scale, position: "relative", ...style }}>
      <div
        style={{
          width: outerW,
          height: outerH,
          transform: `scale(${scale})`,
          transformOrigin: "top left",
          position: "absolute",
          borderRadius: IPAD.radius,
          background: "linear-gradient(145deg, #2b2d33 0%, #141518 45%, #0c0d0f 100%)",
          boxShadow: frameShadow,
          WebkitBoxReflect:
            reflect > 0.01
              ? `below 36px linear-gradient(transparent 62%, rgba(255,255,255,${(0.16 * reflect).toFixed(3)}))`
              : undefined,
        }}
      >
        {sheen !== undefined && sheen > 0 && sheen < 1 ? <Sheen at={sheen} radius={IPAD.radius} /> : null}
        <div
          style={{
            position: "absolute",
            left: IPAD.bezel,
            top: IPAD.bezel,
            width: IPAD.w,
            height: IPAD.h,
            borderRadius: 20,
            overflow: "hidden",
            background: "#000",
          }}
        >
          {children}
        </div>
        {/* front camera on the long edge (iPad 10) */}
        <div
          style={{
            position: "absolute",
            left: outerW / 2 - 5,
            top: IPAD.bezel / 2 - 5,
            width: 10,
            height: 10,
            borderRadius: 5,
            background: "#1d2a3a",
            boxShadow: "inset 0 0 2px rgba(120,160,255,0.5)",
          }}
        />
      </div>
    </div>
  );
};

export const IPhoneFrame: React.FC<{
  height: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ height, children, style }) => {
  const outerW = IPHONE.w + IPHONE.bezel * 2;
  const outerH = IPHONE.h + IPHONE.bezel * 2;
  const scale = height / outerH;
  return (
    <div style={{ width: outerW * scale, height, position: "relative", ...style }}>
      <div
        style={{
          width: outerW,
          height: outerH,
          transform: `scale(${scale})`,
          transformOrigin: "top left",
          position: "absolute",
          borderRadius: IPHONE.radius + IPHONE.bezel,
          background: "linear-gradient(145deg, #3a3c43 0%, #17181b 40%, #0b0b0d 100%)",
          boxShadow: frameShadow,
        }}
      >
        <div
          style={{
            position: "absolute",
            left: IPHONE.bezel,
            top: IPHONE.bezel,
            width: IPHONE.w,
            height: IPHONE.h,
            borderRadius: IPHONE.radius,
            overflow: "hidden",
            background: "#000",
          }}
        >
          {children}
          {/* Dynamic Island */}
          <div
            style={{
              position: "absolute",
              left: IPHONE.w / 2 - 63,
              top: 11,
              width: 126,
              height: 37,
              borderRadius: 19,
              background: "#000",
            }}
          />
        </div>
      </div>
    </div>
  );
};

/** A stylised laptop (the ROG Flow X13): 16:10 screen, thin bezel, a slim base. */
export const LaptopFrame: React.FC<{
  width: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ width, children, style }) => {
  const sw = 1280;
  const sh = 800;
  const bezel = 22;
  const outerW = sw + bezel * 2;
  const outerH = sh + bezel * 2;
  const baseH = 34;
  const scale = width / (outerW + 120);
  return (
    <div style={{ width, height: (outerH + baseH) * scale, position: "relative", ...style }}>
      <div
        style={{
          position: "absolute",
          transform: `scale(${scale})`,
          transformOrigin: "top left",
          width: outerW + 120,
          height: outerH + baseH,
        }}
      >
        <div
          style={{
            position: "absolute",
            left: 60,
            top: 0,
            width: outerW,
            height: outerH,
            borderRadius: "26px 26px 8px 8px",
            background: "linear-gradient(160deg, #26282d, #0d0e10)",
            boxShadow: frameShadow,
          }}
        >
          <div
            style={{
              position: "absolute",
              left: bezel,
              top: bezel,
              width: sw,
              height: sh,
              borderRadius: 8,
              overflow: "hidden",
              background: "#000",
            }}
          >
            {children}
          </div>
        </div>
        <div
          style={{
            position: "absolute",
            left: 0,
            top: outerH,
            width: outerW + 120,
            height: baseH,
            borderRadius: "4px 4px 30px 30px",
            background: "linear-gradient(180deg, #3a3c42 0%, #1a1b1e 60%, #0e0f11 100%)",
            boxShadow: "0 40px 80px rgba(0,0,0,0.6)",
          }}
        >
          <div
            style={{
              position: "absolute",
              left: (outerW + 120) / 2 - 110,
              top: 0,
              width: 220,
              height: 12,
              borderRadius: "0 0 12px 12px",
              background: "#101113",
            }}
          />
        </div>
      </div>
    </div>
  );
};
