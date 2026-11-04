"""Draws the Wingman icon: a big device with a smaller one at its side, white on
blue. Writes the iOS app icon (1024 px, square: iOS rounds the corners itself)
and the laptop's icon.png / icon.ico (rounded, transparent around).

Usage: python make_icon.py
"""
import pathlib

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).parent
IOS_ICON = HERE.parent.parent / "ipad" / "ExtendDisplay" / "Assets.xcassets" / "AppIcon.appiconset" / "icon.png"
BLUE, WHITE = (47, 107, 255), (243, 243, 245)
SCALE = 4  # draw big, then shrink: smooth edges


def draw(size, rounded):
    s = size * SCALE
    u = s / 100  # the design is laid out on a 100 x 100 grid
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(image)
    if rounded:
        d.rounded_rectangle((0, 0, s - 1, s - 1), radius=22 * u, fill=BLUE)
    else:
        d.rectangle((0, 0, s, s), fill=BLUE)
    d.rounded_rectangle((20 * u, 28 * u, 58 * u, 72 * u), radius=7 * u, fill=WHITE)            # the main device
    d.rounded_rectangle((62 * u, 36 * u, 80 * u, 64 * u), radius=5 * u, outline=WHITE,       # its wingman
                        width=round(4 * u))
    return image.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    draw(1024, rounded=False).convert("RGB").save(IOS_ICON)  # iOS wants no transparency
    laptop = draw(256, rounded=True)
    laptop.save(HERE / "icon.png")
    laptop.save(HERE / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("wrote", IOS_ICON, HERE / "icon.png", HERE / "icon.ico")
