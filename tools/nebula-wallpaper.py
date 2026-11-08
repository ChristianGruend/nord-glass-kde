#!/usr/bin/env python3
"""Nord Glass — nebula wallpaper. One image across ALL monitors, every monitor gets its exact slice.

  nebula-wallpaper.py                    generate a Nord nebula for your monitor layout and apply it (KDE Plasma)
  nebula-wallpaper.py --seed 7           a different nebula
  nebula-wallpaper.py photo.jpg          span your own image instead (cover-scaled, centred)
  nebula-wallpaper.py --size 3840x2160   just write one image (any desktop, no KDE needed)
  nebula-wallpaper.py --skybox           also write an 8192×4096 panorama for the KWin desktop cube

How it works: monitor geometries from kscreen-doctor → render (or scale) one image at the bounding box of
all monitors → cut each monitor's area at native resolution → assign it to that monitor's desktop via a
Plasma script. The nebula is generated at exactly your layout size, so it is never upscaled or blurry.
Re-run after moving or adding monitors. Needs: python3, numpy, pillow.
Output: ~/.local/share/wallpapers/nord-glass/  (part of https://github.com/ChristianGruend/nord-glass-kde)
"""
import argparse
import re
import shutil
import subprocess
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

OUT_DIR = Path.home() / ".local/share/wallpapers/nord-glass"


def outputs():
    if not shutil.which("kscreen-doctor"):
        raise SystemExit("kscreen-doctor not found — use --size WxH to just write an image.")
    txt = re.sub(r"\x1b\[[0-9;]*m", "", subprocess.run(["kscreen-doctor", "-o"], capture_output=True,
                                                        text=True).stdout)
    res, cur = [], None
    for line in txt.splitlines():
        if m := re.match(r"Output: \d+ (\S+)", line):
            cur = {"name": m.group(1)}
        elif cur and (m := re.search(r"Geometry: (-?\d+),(-?\d+) (\d+)x(\d+)", line)):
            cur.update(x=int(m[1]), y=int(m[2]), w=int(m[3]), h=int(m[4]))
        elif cur and (m := re.search(r"Scale: ([\d.]+)", line)):
            cur["scale"] = float(m[1])
            if "w" in cur:
                res.append(cur)
            cur = None
    if not res:
        raise SystemExit("no enabled monitors found via kscreen-doctor.")
    return res


def nebula(w, h, seed):
    """Nord nebula: deep cyan-tinted Polar Night, Frost clouds, a touch of Aurora purple, stars."""
    rng = np.random.default_rng(seed)

    def noise(octaves, base):
        acc = np.zeros((h, w), np.float32)
        amp, tot = 1.0, 0.0
        for o in range(octaves):
            n = max(2, base * 2 ** o)
            small = rng.random((max(2, n * h // w), n)).astype(np.float32)
            layer = np.asarray(Image.fromarray(small).resize((w, h), Image.BICUBIC), np.float32)
            acc += layer * amp
            tot += amp
            amp *= 0.5
        acc /= tot
        return (acc - acc.min()) / (np.ptp(acc) + 1e-6)

    def lift(n, cut, gamma):                         # show only the dense parts → crisp cloud edges
        return np.clip((n - cut) / (1 - cut), 0, 1) ** gamma

    cloud = lift(noise(7, 3), 0.34, 1.5)              # main clouds
    core = lift(noise(6, 5), 0.60, 1.4) * cloud       # bright cores inside the clouds
    wisp = lift(noise(6, 7), 0.50, 2.0)               # fine veils
    purple = lift(noise(5, 2), 0.55, 1.8)             # a little Aurora purple
    yy = np.mgrid[0:h, 0:w][0].astype(np.float32)
    grad = (yy / h)[..., None]

    bg_top, bg_bot = np.array([14, 26, 33]), np.array([5, 9, 13])           # deep, cyan-tinted Polar Night
    frost, frost2 = np.array([136, 192, 208]), np.array([143, 188, 187])    # nord8, nord7
    blue = np.array([94, 129, 172])                                          # nord10
    aurora = np.array([180, 142, 173])                                       # nord15
    img = bg_top * (1 - grad) + bg_bot * grad
    img = img + cloud[..., None] * blue * 0.55 + core[..., None] * frost * 1.0
    img = img + wisp[..., None] * frost2 * 0.30 + purple[..., None] * aurora * 0.35

    # stars: many fine ones + a few bright with glow; dimmed inside clouds
    dark = 1 - np.clip(cloud * 1.3, 0, 1)
    stars = np.zeros((h, w), np.float32)
    n = int(w * h / 900)
    ys, xs = rng.integers(0, h, n), rng.integers(0, w, n)
    stars[ys, xs] = 80 + rng.random(n) ** 4 * 175
    fine = np.asarray(Image.fromarray(stars.astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(0.6)), np.float32) * 2.5
    big = np.zeros((h, w), np.float32)
    m = int(w * h / 60000)
    ys, xs = rng.integers(0, h, m), rng.integers(0, w, m)
    big[ys, xs] = 255
    glow = np.asarray(Image.fromarray(big.astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(3.0)), np.float32) * 9
    glow += np.asarray(Image.fromarray(big.astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(1.0)), np.float32) * 3
    st = (fine + glow) * (0.35 + 0.65 * dark)
    img = img + st[..., None] * np.array([0.90, 0.95, 1.0])
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def cover(img, w, h):
    s = max(w / img.width, h / img.height)
    img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    l, t = (img.width - w) // 2, (img.height - h) // 2
    return img.crop((l, t, l + w, t + h))


def apply_kde(parts):
    """parts: list of (x, y, w, h, file) in logical coordinates."""
    qdbus = shutil.which("qdbus6") or shutil.which("qdbus")
    if not qdbus:
        print("qdbus6 not found — set the images manually from", OUT_DIR)
        return
    js = ",".join(f'[{x},{y},{w},{h},"file://{f}"]' for x, y, w, h, f in parts)
    script = """
var m = [%s];
desktops().forEach(function (d) {
  var g = screenGeometry(d.screen);
  m.forEach(function (e) {
    if (g.x == e[0] && g.y == e[1] && g.width == e[2] && g.height == e[3]) {
      d.wallpaperPlugin = "org.kde.image";
      d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
      d.writeConfig("Image", e[4]);
      d.writeConfig("FillMode", 2);
      print("applied: screen " + d.screen + "\\n");
    }
  });
});""" % js
    r = subprocess.run([qdbus, "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", script],
                       capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip())


def main():
    ap = argparse.ArgumentParser(description="One Nord nebula (or your image) across all monitors.")
    ap.add_argument("image", nargs="?", help="span this image instead of generating a nebula")
    ap.add_argument("--seed", type=int, default=117, help="nebula variant (any integer)")
    ap.add_argument("--size", help="WxH: only write a single image of this size, don't touch the desktop")
    ap.add_argument("--no-apply", action="store_true", help="write the slices but don't set them as wallpaper")
    ap.add_argument("--skybox", action="store_true", help="also write an 8192×4096 panorama for the KWin cube")
    a = ap.parse_args()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")   # new file names, otherwise Plasma shows its cached image

    if a.skybox:
        f = OUT_DIR / "skybox.jpg"
        nebula(8192, 4096, a.seed).save(f, quality=92)
        print(f"skybox: {f}  → System Settings → Desktop Effects → Cube → Background: Skybox")

    if a.size:
        W, H = (int(v) for v in a.size.lower().split("x"))
        img = cover(Image.open(a.image).convert("RGB"), W, H) if a.image else nebula(W, H, a.seed)
        f = OUT_DIR / f"nebula-{W}x{H}-{stamp}.png"
        img.save(f)
        print(f)
        return

    outs = outputs()
    x0, y0 = min(o["x"] for o in outs), min(o["y"] for o in outs)
    x1, y1 = max(o["x"] + o["w"] for o in outs), max(o["y"] + o["h"] for o in outs)
    k = max(o.get("scale", 1.0) for o in outs)        # pixel density of the sharpest monitor
    W, H = round((x1 - x0) * k), round((y1 - y0) * k)
    print(f"layout {x1 - x0}×{y1 - y0} (logical) → image {W}×{H}")
    big = cover(Image.open(a.image).convert("RGB"), W, H) if a.image else nebula(W, H, a.seed)

    for old in OUT_DIR.glob("*.png"):
        old.unlink()
    big.save(OUT_DIR / f"_full-{stamp}.png")
    parts = []
    for o in outs:
        box = tuple(round(v * k) for v in (o["x"] - x0, o["y"] - y0, o["x"] - x0 + o["w"], o["y"] - y0 + o["h"]))
        part = big.crop(box)
        native = (round(o["w"] * o.get("scale", 1.0)), round(o["h"] * o.get("scale", 1.0)))
        if part.size != native:
            part = part.resize(native, Image.LANCZOS)
        f = OUT_DIR / f"{o['name']}-{stamp}.png"
        part.save(f)
        print(f"  {o['name']:16} {native[0]}×{native[1]}")
        parts.append((o["x"], o["y"], o["w"], o["h"], f))
    if not a.no_apply:
        apply_kde(parts)


if __name__ == "__main__":
    main()
