# Render one snapshot's dots onto the map to calibrate INSET (where 0..1 maps).
# Usage: python preview-frame.py [x0 y0 x1 y1]   (defaults to full image)
import sys, json
from PIL import Image, ImageDraw

T = json.loads(open("track.js", encoding="utf-8").read().split("=", 1)[1].strip().rstrip(";"))
inset = list(map(float, sys.argv[1:5])) if len(sys.argv) >= 5 else [0.0, 0.0, 1.0, 1.0]
x0, y0, x1, y1 = inset

img = Image.open(T["map"] + ".png").convert("RGB")
W, H = img.size
d = ImageDraw.Draw(img)

# pick the snapshot with the most units (mid-game, everyone alive/spread)
snap = max(T["snapshots"], key=lambda s: len(s["units"]))
for u in snap["units"]:
    X = (x0 + (x1 - x0) * u["x"]) * W
    Y = (y0 + (y1 - y0) * u["y"]) * H
    d.ellipse([X - 8, Y - 8, X + 8, Y + 8], fill=(255, 40, 40), outline=(0, 0, 0), width=2)

out = "preview.png"
img.save(out)
print("map=%s  inset=%s  units=%d  -> %s" % (T["map"], inset, len(snap["units"]), out))
