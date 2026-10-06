#!/usr/bin/env python3
"""Regenerates the app icon: BONE in ink over DUST in stamp red, in Rubik Dirt, on the page.

    python3 scripts/make-app-icon.py

Needs Pillow. The colours are the Earth ramp's, verbatim (BonedustCore/Content/EarthRamp.swift):
the page is earth1, the ink is earth8, the accent is stamp, and the dot grid is earth3 at 0.35 over
the page, as in the app. If a value there changes, change it here and run this again.

The output is opaque RGB with no alpha channel, because the App Store rejects an icon that has one,
and it carries an sRGB profile so the values above are the values on screen.
"""

from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "ios/Bonedust/Resources/Fonts/RubikDirt-Regular.ttf"
OUT = ROOT / "ios/Bonedust/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

SIZE = 1024
PAGE = (0xED, 0xE4, 0xCF)  # earth1
INK = (0x1C, 0x1A, 0x17)  # earth8
STAMP = (0xB0, 0x3A, 0x2B)
HAIRLINE = (0xC4, 0xB5, 0x96)  # earth3

# How wide the wordmark may be: 78% of the icon, which leaves the margins iOS's corner
# rounding needs.
TEXT_WIDTH = 800


def over(foreground, background, alpha):
    return tuple(round(alpha * f + (1 - alpha) * b) for f, b in zip(foreground, background))


def ink_bounds(font, text):
    left, top, right, bottom = font.getbbox(text)
    return left, top, right - left, bottom - top


def word(font, text):
    """The word as a mask trimmed to its ink, so it is placed by what is drawn and not by advance."""
    left, top, width, height = ink_bounds(font, text)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).text((-left, -top), text, font=font, fill=255)
    return mask


def main():
    image = Image.new("RGB", (SIZE, SIZE), PAGE)
    draw = ImageDraw.Draw(image)

    # The page's graph grid, on a lattice that is centred on the icon.
    dot, pitch, radius = over(HAIRLINE, PAGE, 0.35), 64, 3
    for y in range(pitch // 2, SIZE, pitch):
        for x in range(pitch // 2, SIZE, pitch):
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=dot)

    # One size for both words, so the block is a clean rectangle: the wider word fills the width.
    size = 400
    while size > 100:
        font = ImageFont.truetype(str(FONT), size)
        if max(ink_bounds(font, text)[2] for text in ("BONE", "DUST")) <= TEXT_WIDTH:
            break
        size -= 4
    font = ImageFont.truetype(str(FONT), size)

    words = [(word(font, "BONE"), INK), (word(font, "DUST"), STAMP)]
    gap = round(size * 0.09)
    y = (SIZE - (sum(mask.height for mask, _ in words) + gap)) // 2
    for mask, colour in words:
        image.paste(colour, ((SIZE - mask.width) // 2, y), mask)
        y += mask.height + gap

    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    image.save(OUT, icc_profile=profile, optimize=True)
    print(f"{OUT.relative_to(ROOT)}: {image.size[0]}x{image.size[1]} {image.mode}, Rubik Dirt at {size}")


if __name__ == "__main__":
    main()
