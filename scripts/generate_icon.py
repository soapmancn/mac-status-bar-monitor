#!/usr/bin/env python3
from __future__ import annotations

import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


PROJECT_DIR = Path(__file__).resolve().parents[1]
RESOURCES_DIR = PROJECT_DIR / "Resources"
ICONSET_DIR = RESOURCES_DIR / "AppIcon.iconset"
ICNS_PATH = RESOURCES_DIR / "AppIcon.icns"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]

    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)

    return ImageFont.load_default(size=size)


def rounded_gradient(size: int, radius: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    pad = 58
    mask_draw.rounded_rectangle([pad, pad, size - pad, size - pad], radius=radius, fill=255)

    gradient = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = gradient.load()
    for y in range(size):
        for x in range(size):
            nx = x / (size - 1)
            ny = y / (size - 1)
            t = min(1, max(0, (nx * 0.35 + ny * 0.9)))
            r = int(18 + 16 * t)
            g = int(24 + 96 * t)
            b = int(38 + 112 * t)
            pixels[x, y] = (r, g, b, 255)

    accent = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    accent_draw = ImageDraw.Draw(accent)
    accent_draw.ellipse([430, -180, 1220, 570], fill=(88, 216, 196, 74))
    accent_draw.ellipse([-260, 520, 590, 1230], fill=(89, 136, 255, 56))
    accent = accent.filter(ImageFilter.GaussianBlur(48))

    image.alpha_composite(gradient)
    image.alpha_composite(accent)
    image.putalpha(mask)
    return image


def draw_shadow(base: Image.Image, box: tuple[int, int, int, int], radius: int, blur: int, opacity: int) -> None:
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle(box, radius=radius, fill=(0, 0, 0, opacity))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(shadow)


def draw_status_chip(base: Image.Image) -> None:
    draw = ImageDraw.Draw(base)
    box = (154, 286, 870, 466)
    draw_shadow(base, (box[0], box[1] + 18, box[2], box[3] + 18), 88, 26, 90)
    draw.rounded_rectangle(box, radius=88, fill=(255, 255, 255, 38), outline=(255, 255, 255, 115), width=5)

    label_font = font(52, bold=True)
    value_font = font(66, bold=True)
    arrow_font = font(52, bold=True)
    small_font = font(44, bold=True)

    x = 222
    for label, value in [("C", "38"), ("M", "77"), ("D", "83")]:
        draw.text((x, 338), label, fill=(255, 255, 255, 218), font=label_font, anchor="lm")
        draw.text((x + 62, 336), value, fill=(255, 255, 255, 248), font=value_font, anchor="lm")
        draw.text((x + 164, 340), "%", fill=(255, 255, 255, 226), font=small_font, anchor="lm")
        x += 178

    net_x = 706
    draw.text((net_x, 330), "↑", fill=(255, 255, 255, 248), font=arrow_font, anchor="lm")
    draw.text((net_x + 60, 330), "1.3M", fill=(255, 255, 255, 248), font=small_font, anchor="lm")
    draw.text((net_x, 386), "↓", fill=(255, 255, 255, 248), font=arrow_font, anchor="lm")
    draw.text((net_x + 60, 386), "840K", fill=(255, 255, 255, 248), font=small_font, anchor="lm")


def draw_signal_mark(base: Image.Image) -> None:
    draw = ImageDraw.Draw(base)
    center = (512, 642)
    colors = [
        (255, 255, 255, 76),
        (255, 255, 255, 112),
        (255, 255, 255, 180),
    ]
    radii = [220, 164, 108]
    widths = [17, 19, 21]

    for radius, width, color in zip(radii, widths, colors):
        bbox = [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius]
        draw.arc(bbox, start=204, end=336, fill=color, width=width)

    for i, height in enumerate([78, 124, 172]):
        x = 392 + i * 82
        y = 744 - height
        fill = (255, 255, 255, 155 + i * 35)
        draw.rounded_rectangle([x, y, x + 42, 744], radius=21, fill=fill)

    dot_shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    dot_draw = ImageDraw.Draw(dot_shadow)
    dot_draw.ellipse([472, 604, 552, 684], fill=(0, 0, 0, 82))
    dot_shadow = dot_shadow.filter(ImageFilter.GaussianBlur(20))
    base.alpha_composite(dot_shadow)
    draw.ellipse([474, 600, 550, 676], fill=(255, 255, 255, 235))


def draw_highlight(base: Image.Image) -> None:
    highlight = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(highlight)
    draw.rounded_rectangle([86, 86, 938, 938], radius=190, outline=(255, 255, 255, 48), width=4)
    draw.arc([116, 92, 908, 908], start=205, end=285, fill=(255, 255, 255, 62), width=8)
    base.alpha_composite(highlight)


def create_master() -> Image.Image:
    image = rounded_gradient(1024, 210)
    draw_status_chip(image)
    draw_signal_mark(image)
    draw_highlight(image)
    return image


def save_iconset(master: Image.Image) -> None:
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    for size, name in sizes:
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(ICONSET_DIR / name, dpi=(72, 72))

    master.save(RESOURCES_DIR / "AppIcon-preview.png", dpi=(72, 72))


def main() -> None:
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    master = create_master()
    save_iconset(master)
    tiff_path = RESOURCES_DIR / "AppIcon.tiff"
    master.convert("RGB").save(tiff_path, format="TIFF")
    subprocess.run(["tiff2icns", str(tiff_path)], check=True)
    print(f"Wrote {ICNS_PATH}")


if __name__ == "__main__":
    main()
