import { loadFont } from "@remotion/google-fonts/Inter";

// Inter stands in for Apple's SF Pro (not licensed outside Apple devices).
export const { fontFamily } = loadFont("normal", {
  weights: ["200", "300", "400", "500", "600", "700", "800"],
  subsets: ["latin", "latin-ext"],
});

// Wingman's own tokens, copied from ipad/ExtendDisplay/Theme.swift.
export const T = {
  black: "#000000",
  background: "rgb(16,17,20)",
  tile: "rgb(30,31,36)",
  tileRaised: "rgb(42,44,51)",
  on: "rgb(243,243,245)",
  onText: "rgb(16,17,20)",
  text: "rgb(243,243,245)",
  secondary: "rgb(154,156,165)",
  accent: "rgb(47,107,255)",
  accentRGB: "47,107,255",
  warm: "rgb(255,179,92)",
  good: "rgb(95,211,138)",
  nightRed: "rgb(199,51,46)",
  nightDim: "rgb(110,31,28)",
  radius: 22,
  gap: 14,
};

// The film's own type scale (1080 x 1920, read on a phone).
export const TYPE = {
  hero: 132, // one-word captions
  title: 104, // sentence captions
  label: 34, // small caps labels above captions
  credit: 38,
};
