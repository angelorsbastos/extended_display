"""Generates the narration (one mp3 per line) with a Microsoft neural voice.

Needs: pip install edge-tts librosa   (and an internet connection)
Usage, from video/:  python scripts/make_voice.py
Writes public/voice/<id>.mp3 and src/voice-durations.json (seconds of speech).
"""
import json, pathlib, subprocess, sys, time

import librosa

HERE = pathlib.Path(__file__).resolve().parent.parent
spec = json.loads((HERE / "voice-lines.json").read_text(encoding="utf-8"))
out = HERE / "public" / "voice"
out.mkdir(parents=True, exist_ok=True)
exe = pathlib.Path(sys.executable).with_name("edge-tts")
durations = {}
for key, text in spec["lines"].items():
    target = out / f"{key}.mp3"
    for attempt in range(8):  # the service drops requests now and then
        subprocess.run([str(exe), "--voice", spec["voice"], f"--rate={spec['rate']}",
                        "--text", text, "--write-media", str(target)], capture_output=True)
        if target.exists() and target.stat().st_size > 1000:
            break
        time.sleep(2)
    else:
        sys.exit(f"no audio for {key}")
    y, sr = librosa.load(str(target), sr=None)
    start, end = librosa.effects.trim(y, top_db=40)[1]
    durations[key] = {"lead": round(start / sr, 3), "speech": round((end - start) / sr, 3)}
    print(key, durations[key])
(HERE / "src" / "voice-durations.json").write_text(json.dumps(durations, indent=2))
