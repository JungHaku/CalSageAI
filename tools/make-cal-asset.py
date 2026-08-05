#!/usr/bin/env python3
"""Turn a downloaded Cal illustration into the app's `Cal.imageset`.

    ./tools/make-cal-asset.py ~/Downloads/cal.png

Writes `Packages/CalDesign/Sources/CalDesign/Resources/Cal.imageset/` — three
PNGs and a `Contents.json`. Offline, no dependencies beyond Pillow.

Why this is a committed script rather than something done once by hand:

The illustrations come out of an image generator, and generators hand back a
**flattened** PNG. The first one downloaded was 1254x1254 in RGB mode with no
alpha channel at all — the transparency checkerboard was baked in as literal
alternating #F1F1F1 and #FEFEFE squares. Dropped straight into the asset
catalogue, Cal would have rendered sitting on a grey checkerboard, and it would
have looked like a rendering bug rather than a bad export.

That will happen again on every regeneration, so the repair is a script.

## How the background is recognised

Not by colour-matching the whole image, which would eat the hoodie: it is cream
(#F5EFE0-ish) and the checker's light square is #FEFEFE, only 29 apart in blue.

Two things separate them, and both are required:

1. **Neutrality.** The checker is grey — its channels are within a few points of
   each other. The cream hoodie is *warm*: red and blue differ by about 20. So a
   pixel is background only if `max(r,g,b) - min(r,g,b)` is small.
2. **Connectivity.** The fill starts at the four corners and only spreads through
   neighbouring background pixels, so an enclosed cream region can never be
   reached even if it did somehow pass the colour test. The bear is drawn with a
   continuous dark outline, which is what makes this hold.

Edges are then feathered, because a hard binary mask on a smoothly antialiased
drawing leaves a visible white fringe against a dark background — the original
edge pixels are blends of ink and checker, and keeping them fully opaque keeps
the checker's grey in them.
"""

import collections
import json
import pathlib
import sys

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("Pillow is required:  python3 -m pip install Pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Inside an `.xcassets`, not beside it. A bare `.imageset` directory is copied
# into the bundle verbatim and `Image("Cal", bundle: .module)` will not find it;
# only a catalogue compiled by `actool` produces a named image.
DEST = ROOT / "Packages/CalDesign/Sources/CalDesign/Resources/Media.xcassets/Cal.imageset"

# The 1x edge, in points. 3x therefore renders at 600px, which covers the largest
# documented use — the 180pt Home hero — with room, and still costs far less than
# shipping the 1.6 MB original to draw a 24pt avatar.
BASE = 200
SCALES = (1, 2, 3)

# A pixel is background if its channels are within this of each other. The checker
# measures 0-2; the cream hoodie measures about 20. Eight is comfortably between.
NEUTRAL_TOLERANCE = 8
# ...and if it is at least this bright. Both checker squares are above 235; every
# ink in the drawing is far below it.
MIN_BRIGHTNESS = 232

# Transparent margin kept around the trimmed subject, as a fraction of the long
# edge. Without it a circular clip or a halo would shave Cal's ears.
MARGIN = 0.04


def is_background(pixel):
    red, green, blue = pixel[:3]
    return (
        max(red, green, blue) - min(red, green, blue) <= NEUTRAL_TOLERANCE
        and min(red, green, blue) >= MIN_BRIGHTNESS
    )


def background_mask(image):
    """Flood fill inward from the four corners. Returns a bytearray, 255 = keep."""
    width, height = image.size
    pixels = image.load()
    alpha = bytearray([255]) * (width * height)

    queue = collections.deque()
    seen = bytearray(width * height)

    for x, y in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
        if is_background(pixels[x, y]):
            queue.append((x, y))
            seen[y * width + x] = 1

    while queue:
        x, y = queue.popleft()
        alpha[y * width + x] = 0
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                index = ny * width + nx
                if not seen[index] and is_background(pixels[nx, ny]):
                    seen[index] = 1
                    queue.append((nx, ny))

    return alpha


def build(source):
    image = Image.open(source).convert("RGB")
    width, height = image.size

    mask = Image.frombytes("L", (width, height), bytes(background_mask(image)))
    cleared = sum(1 for value in mask.getdata() if value == 0)
    if cleared == 0:
        sys.exit(
            f"No background found in {source.name}. If it already has real alpha, "
            "this script is not needed — but check it is not a solid-colour matte."
        )
    print(f"  background   {cleared / (width * height):.1%} of the image")

    # Feather. A one-pixel blur turns the hard cut into a gradient, so the
    # antialiased outline blends into whatever it is drawn on instead of carrying
    # a pale fringe of the checker it was flattened against.
    mask = mask.filter(ImageFilter.GaussianBlur(0.8))

    rgba = image.convert("RGBA")
    rgba.putalpha(mask)

    box = mask.point(lambda v: 255 if v > 8 else 0).getbbox()
    rgba = rgba.crop(box)
    print(f"  trimmed      {width}x{height} -> {rgba.width}x{rgba.height}")

    # Square it, so a point size means the same thing whichever way Cal is drawn
    # and a circular clip stays concentric.
    side = int(max(rgba.size) * (1 + 2 * MARGIN))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(rgba, ((side - rgba.width) // 2, (side - rgba.height) // 2))

    DEST.mkdir(parents=True, exist_ok=True)
    for scale in SCALES:
        edge = BASE * scale
        name = f"cal@{scale}x.png" if scale > 1 else "cal.png"
        resized = canvas.resize((edge, edge), Image.LANCZOS)
        resized.save(DEST / name, "PNG", optimize=True)
        size_kb = (DEST / name).stat().st_size / 1024
        print(f"  {name:<12} {edge}x{edge}  {size_kb:.0f} KB")

    (DEST / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": f"cal@{scale}x.png" if scale > 1 else "cal.png",
                        "idiom": "universal",
                        "scale": f"{scale}x",
                    }
                    for scale in SCALES
                ],
                "info": {"author": "xcode", "version": 1},
                # The artwork is a full-colour illustration, so it must not be
                # recoloured by a tint the way a symbol would be.
                "properties": {"preserves-vector-representation": False},
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = pathlib.Path(sys.argv[1]).expanduser()
    if not path.exists():
        sys.exit(f"No such file: {path}")
    print(f"Building Cal.imageset from {path.name}")
    build(path)
    print(f"Wrote {DEST.relative_to(ROOT)}")
