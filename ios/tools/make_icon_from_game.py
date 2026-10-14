#!/usr/bin/env python3
"""Build the app icon from the user's own Skate 3 files (local builds only).

Reads the dashboard-art package (nxeart, from an extracted game folder or the
ISO), keys the official logo out of its 1920x1080 background and centers it
on charcoal, like the Xbox title tile. The output goes to a git-ignored asset
catalog (ios/LocalAssets.xcassets) that ios/build.sh uses when present, so no
EA artwork is ever committed; without it the build keeps the original icon.

usage: make_icon_from_game.py <game dir | image.iso> <output .xcassets dir>
"""
import io
import pathlib
import shutil
import subprocess
import sys

from PIL import Image, ImageFilter

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
here = pathlib.Path(__file__).resolve().parent

if src.is_dir():
    nxeart = (src / "nxeart").read_bytes()
else:
    tmp = out.parent / ".nxeart-extract"
    subprocess.run([sys.executable, str(here / "extract_from_iso.py"), str(src), str(tmp), "nxeart"],
                   check=True, stdout=subprocess.DEVNULL)
    nxeart = (tmp / "nxeart").read_bytes()
    shutil.rmtree(tmp)

# The package's JPEGs: the 1920x1080 dashboard background carries the logo.
background = None
start = nxeart.find(b"\xff\xd8\xff")
while start >= 0 and background is None:
    end = nxeart.find(b"\xff\xd9", start)
    image = Image.open(io.BytesIO(nxeart[start:end + 2])).convert("RGB")
    if image.size == (1920, 1080):
        background = image
    start = nxeart.find(b"\xff\xd8\xff", end)
if background is None:
    sys.exit("no 1920x1080 dashboard background in nxeart")

# Logo region, top centre, on flat sky.
logo = background.crop((770, 70, 1140, 160))
w, h = logo.size
sky = tuple(sum(logo.getpixel((x, y))[c] for x, y in ((1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2))) / 4
            for c in range(3))
inks = ((255, 255, 255), (238, 102, 44))  # white lettering, orange emblem


def dist(a, b):
    return sum((a[i] - b[i]) ** 2 for i in range(3)) ** 0.5


rgba = Image.new("RGBA", logo.size)
px = logo.load()
op = rgba.load()
for y in range(h):
    for x in range(w):
        p = px[x, y]
        ink = min(inks, key=lambda c: dist(p, c))
        a = max(0.0, min(1.0, dist(p, sky) / dist(ink, sky)))
        if a < 0.06:
            op[x, y] = (0, 0, 0, 0)
            continue
        # Unmix the sky to recover the ink colour at anti-aliased edges.
        col = tuple(max(0, min(255, round((p[i] - (1 - a) * sky[i]) / a))) for i in range(3))
        op[x, y] = (*col, round(a * 255))
rgba = rgba.crop(rgba.getbbox())

size = 1024
icon = Image.new("RGB", (size, size))
top, bottom = (44, 49, 53), (24, 27, 30)
for y in range(size):
    t = y / (size - 1)
    row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    icon.paste(row, (0, y, size, y + 1))
target_w = round(size * 0.84)
scaled = rgba.resize((target_w, round(rgba.height * target_w / rgba.width)), Image.LANCZOS)
pos = ((size - scaled.width) // 2, (size - scaled.height) // 2)
shadow = Image.new("RGBA", scaled.size, (0, 0, 0, 0))
shadow.putalpha(scaled.getchannel("A").point(lambda v: v * 0.5))
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
icon.paste(shadow, (pos[0], pos[1] + 10), shadow)
icon.paste(scaled, pos, scaled)

# Copy the committed catalog (launch colour etc.) and swap the icon.
if out.exists():
    shutil.rmtree(out)
shutil.copytree(here.parent / "Assets.xcassets", out)
icon.save(out / "AppIcon.appiconset" / "icon-1024.png")
print(f"icon from game files -> {out}")
