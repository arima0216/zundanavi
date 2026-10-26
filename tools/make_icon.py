"""Generate the 1024px app icon (green circle + the kana 'zu').

Usage: python tools/make_icon.py
Writes icon.png (repo root, for SideStore) and Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
"""
import os
import shutil
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 1024
BG = (232, 245, 233)
GREEN = (76, 175, 80)
DARK = (27, 94, 32)

FONT_CANDIDATES = [
    "C:/Windows/Fonts/YuGothB.ttc",
    "C:/Windows/Fonts/meiryob.ttc",
    "C:/Windows/Fonts/msgothic.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]


def main():
    img = Image.new("RGB", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(img)
    m = 72
    d.ellipse((m, m, SIZE - m, SIZE - m), fill=GREEN, outline=DARK, width=24)
    font = None
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            font = ImageFont.truetype(p, 600)
            break
    if font is None:
        font = ImageFont.load_default()
    text = "\u305a"  # hiragana 'zu'
    box = d.textbbox((0, 0), text, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    x = (SIZE - w) / 2 - box[0]
    y = (SIZE - h) / 2 - box[1]
    d.text((x, y), text, font=font, fill=(255, 255, 255))
    out_root = os.path.join(ROOT, "icon.png")
    img.save(out_root, "PNG")
    out_asset = os.path.join(ROOT, "Sources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
    shutil.copyfile(out_root, out_asset)
    print("wrote", out_root, "and", out_asset)


if __name__ == "__main__":
    main()
