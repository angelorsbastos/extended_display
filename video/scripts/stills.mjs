// Renders QA stills: node scripts/stills.mjs 60 150 220 ...  -> out/qa/f<frame>.png
import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import path from "node:path";
const frames = process.argv.slice(2).map(Number);
const serveUrl = await bundle({ entryPoint: path.resolve("src/index.ts") });
const composition = await selectComposition({ serveUrl, id: "Wingman", inputProps: { bgm: true } });
for (const frame of frames) {
  await renderStill({ serveUrl, composition, frame, output: `out/qa/f${frame}.png`, inputProps: { bgm: true }, scale: 0.5 });
  console.log("wrote", frame);
}
