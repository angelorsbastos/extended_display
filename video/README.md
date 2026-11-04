# Wingman showcase video

A 40-second vertical (1080 × 1920, 30 fps) motion-graphics film of Wingman for
Reels and WhatsApp, made with [Remotion](https://www.remotion.dev). Every
screen is rebuilt in code from the app's SwiftUI views and `Theme.swift`
colours, so no screen recordings are needed.

## Re-render

From this folder (`video/`):

```bash
npm install
```

```bash
npx remotion render src/index.ts Wingman out/wingman.mp4
```

Without the music (voice and sound effects only, to add a song in Instagram):

```bash
npx remotion render src/index.ts Wingman out/wingman-nobgm.mp4 --props=props-nobgm.json
```

To preview and scrub through it in the browser: `npm run dev`.

The first render downloads a headless Chrome (about 130 MB). No ffmpeg install
is needed: Remotion brings its own.

## Where things are

| File | What |
|---|---|
| `src/timeline.ts` | All timing, in beats of the music (`beatF(n)`, the drop is frame 180) |
| `src/sound.ts` | Every sound effect, pinned to a beat or a shot |
| `src/theme.ts` | Wingman's colours, copied from `ipad/Wingman/Theme.swift` |
| `src/stage/IPadStage.tsx` | The one iPad and its 3D camera, from the dark opening through the Dock and Controls |
| `src/stage/Atmosphere.tsx` | Out-of-focus lights, vignette and film grain |
| `src/scenes/` | Captions and the other shots: hook, promise, Dock, Controls + Dashboard, iPhone, "and more", end card |
| `src/voice.ts`, `voice-lines.json` | The narration: what's said, and when |
| `src/screens/` | The rebuilt app screens (Dock, Control Center, Dashboard, Trackpad) |
| `src/components/` | Device frames, the Wingman icon, text reveals |
| `scripts/stills.mjs` | Renders single frames for checking: `node scripts/stills.mjs 200 640` → `out/qa/` |

## Changing the narration

The voice is "Andrew", a Microsoft neural voice. To change a line, edit
`voice-lines.json`, then regenerate the audio (needs Python and internet):

```bash
pip install edge-tts librosa
```

```bash
python scripts/make_voice.py
```

This rewrites `public/voice/*.mp3` and `src/voice-durations.json`. When a line
plays is set in `src/voice.ts`.

## Editing

To change a caption, edit the scene file; to move something in time, change its
beat in the scene or in `timeline.ts`, and the sound effects follow.

## Choices worth knowing

- **Font and icons:** Inter and Lucide stand in for Apple's SF Pro and SF
  Symbols, which aren't licensed for use outside Apple devices.
- **Shortcut icons, song and cover art** are made up ("Midnight Drive" by
  "Nova Lane"), so no brand logos or real album art appear.
- **Motion blur** is only switched on around the fast moves (`BLUR_WINDOWS`
  in `src/Composition.tsx`), which keeps the render quick.
- **Music:** "House Vibez" by Lily J, turned down under the voice. The track starts 57 s in, so its drop
  lands exactly when the Dock appears. Licences are listed in `CREDITS.md`.
