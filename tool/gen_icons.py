#!/usr/bin/env python3
"""Generate every app icon of the project from one geometric definition.

The icon is deliberately simple: a rounded indigo square (the app's seed
colour) carrying a white CAN-style square-wave trace.

Run it after changing the definition below; the generated files are checked
into the repository, so a normal build never needs Python:

    python3 -m pip install pillow
    python3 tool/gen_icons.py

Outputs
    assets/icon/app_icon.svg                      vector master (documentation)
    assets/icon/app_icon.png                      1024px master (README/stores)
    android/app/src/main/res/mipmap-*/ic_launcher.png
    android/app/src/main/res/mipmap-*/ic_launcher_foreground.png (adaptive)
    windows/runner/resources/app_icon.ico
    linux/runner/resources/mf4_viewer.png         window/taskbar icon
    linux/runner/resources/icons/hicolor/<size>/apps/<app-id>.png
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent

# GTK application ID; the hicolor icons and the .desktop file are named after
# it so desktop environments can match a running window to its launcher.
LINUX_APP_ID = "com.mf4viewer.mf4_viewer"

# --- Icon definition (all coordinates relative to the icon's edge length) ---

BG_TOP = (74, 92, 199)  # indigo 500-ish, matches the app's seed colour
BG_BOTTOM = (26, 35, 126)  # indigo 900
FG = (255, 255, 255)

CORNER_RADIUS = 0.22
TRACE_X0, TRACE_X1 = 0.15, 0.85
TRACE_HIGH, TRACE_LOW = 0.35, 0.65

# 0 = recessive/low, 1 = dominant/high. The coarse pattern keeps the trace
# readable once the icon is scaled down to a 16px tray icon.
LEVELS = (0, 1, 0, 1, 0)
LEVELS_SMALL = (0, 1, 0)
STROKE = 0.085
STROKE_SMALL = 0.105
SMALL_ICON_PX = 40  # at or below this size the coarse pattern is used

# Android masks an adaptive icon down to roughly the middle 66 of its 108dp,
# and only the middle 72dp are guaranteed to survive. Shrinking the artwork to
# 70% keeps it inside that safe zone while still filling the visible mask.
ADAPTIVE_SCALE = 0.70


def trace_points(levels: tuple[int, ...]) -> list[tuple[float, float]]:
    """Square-wave polyline; consecutive points share an x for the edges."""
    step = (TRACE_X1 - TRACE_X0) / len(levels)
    points: list[tuple[float, float]] = []
    for i, level in enumerate(levels):
        y = TRACE_HIGH if level else TRACE_LOW
        points.append((TRACE_X0 + i * step, y))
        points.append((TRACE_X0 + (i + 1) * step, y))
    return points


def _geometry(size: int) -> tuple[tuple[int, ...], float]:
    if size <= SMALL_ICON_PX:
        return LEVELS_SMALL, STROKE_SMALL
    return LEVELS, STROKE


def _gradient(size: int) -> Image.Image:
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )
    return gradient.resize((size, size), Image.NEAREST)


def render(size: int, *, background: bool = True, scale: float = 1.0) -> Image.Image:
    """Render the icon at `size` px, `scale` shrinking the artwork in place."""
    levels, stroke = _geometry(size)
    ss = 8 if size <= 256 else 4  # supersampling factor for antialiasing
    px = size * ss
    icon = Image.new("RGBA", (px, px), (0, 0, 0, 0))

    if background:
        mask = Image.new("L", (px, px), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, px - 1, px - 1), radius=CORNER_RADIUS * px, fill=255
        )
        icon.paste(_gradient(px), (0, 0), mask)

    def place(value: float) -> float:
        return (0.5 + (value - 0.5) * scale) * px

    points = [(place(x), place(y)) for x, y in trace_points(levels)]
    draw = ImageDraw.Draw(icon)
    draw.line(points, fill=FG, width=max(round(stroke * scale * px), 1), joint="curve")
    # `joint="curve"` rounds the corners but leaves the two ends square.
    radius = stroke * scale * px / 2
    for cx, cy in (points[0], points[-1]):
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=FG)

    return icon.resize((size, size), Image.LANCZOS)


def write_png(path: Path, image: Image.Image) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG")
    print(f"  {path.relative_to(REPO)} ({image.width}x{image.height})")


def write_svg(path: Path) -> None:
    points = trace_points(LEVELS)
    d = "M " + " L ".join(f"{x * 1024:.1f} {y * 1024:.1f}" for x, y in points)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>MF4 Viewer</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#{"%02X%02X%02X" % BG_TOP}"/>
      <stop offset="1" stop-color="#{"%02X%02X%02X" % BG_BOTTOM}"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="{CORNER_RADIUS * 1024:.0f}" fill="url(#bg)"/>
  <path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="{STROKE * 1024:.0f}"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
""",
        encoding="utf-8",
    )
    print(f"  {path.relative_to(REPO)}")


def main() -> None:
    print("Master:")
    write_svg(REPO / "assets/icon/app_icon.svg")
    write_png(REPO / "assets/icon/app_icon.png", render(1024))

    print("Android launcher icons:")
    # mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi: 48dp legacy, 108dp adaptive.
    for bucket, density in (
        ("mdpi", 1),
        ("hdpi", 1.5),
        ("xhdpi", 2),
        ("xxhdpi", 3),
        ("xxxhdpi", 4),
    ):
        res = REPO / "android/app/src/main/res" / f"mipmap-{bucket}"
        write_png(res / "ic_launcher.png", render(round(48 * density)))
        write_png(
            res / "ic_launcher_foreground.png",
            render(round(108 * density), background=False, scale=ADAPTIVE_SCALE),
        )

    print("Windows icon:")
    ico_sizes = (16, 24, 32, 48, 64, 128, 256)
    images = [render(s) for s in ico_sizes]
    ico = REPO / "windows/runner/resources/app_icon.ico"
    ico.parent.mkdir(parents=True, exist_ok=True)
    images[-1].save(
        ico,
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=images[:-1],
    )
    print(f"  {ico.relative_to(REPO)} ({', '.join(str(s) for s in ico_sizes)})")

    print("Linux icons:")
    write_png(REPO / "linux/runner/resources/mf4_viewer.png", render(256))
    hicolor = REPO / "linux/runner/resources/icons/hicolor"
    for size in (16, 32, 48, 64, 128, 256):
        write_png(hicolor / f"{size}x{size}/apps/{LINUX_APP_ID}.png", render(size))


if __name__ == "__main__":
    main()
