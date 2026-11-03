"""Draw the app icon (two overlapping monitors) as a 1024x1024 PNG, no alpha."""
import pathlib

import cv2
import numpy as np

S = 1024
OUT = pathlib.Path(__file__).parent / "ExtendDisplay/Assets.xcassets/AppIcon.appiconset/icon.png"

# vertical gradient background, BGR
top, bottom = np.array([120, 40, 20]), np.array([200, 90, 40])
t = np.linspace(0, 1, S)[:, None, None]
img = (top * (1 - t) + bottom * t).astype(np.uint8).repeat(S, axis=1)


def monitor(x, y, w, h, fill):
    cv2.rectangle(img, (x, y), (x + w, y + h), (255, 255, 255), -1, cv2.LINE_AA)
    pad = 34
    cv2.rectangle(img, (x + pad, y + pad), (x + w - pad, y + h - pad), fill, -1, cv2.LINE_AA)
    cv2.rectangle(img, (x + w // 2 - 30, y + h), (x + w // 2 + 30, y + h + 60), (255, 255, 255), -1)
    cv2.rectangle(img, (x + w // 2 - 110, y + h + 60), (x + w // 2 + 110, y + h + 90), (255, 255, 255), -1)


monitor(150, 230, 520, 360, (90, 60, 40))
monitor(430, 400, 460, 320, (230, 160, 70))

OUT.parent.mkdir(parents=True, exist_ok=True)
cv2.imwrite(str(OUT), img)
print("wrote", OUT)
