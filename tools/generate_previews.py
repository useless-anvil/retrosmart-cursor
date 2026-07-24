#!/usr/bin/env python3

from pathlib import Path
from PIL import Image

# Paths
ROOT = Path("artifacts/png")
OUT = Path("tools/previews")
OUT.mkdir(parents=True, exist_ok=True)

# Representative cursors (4×2 grid)
CURSORS = [
    "128-default.png",
    "128-pointer.png",
    "128-crosshair.png",
    "128-fleur.png",
    "128-progress4.png",
    "128-color-picker.png",
    "128-size_hor.png",
    "128-size_ver.png",
]

CELL = 128
PADDING = 32
COLS = 4
ROWS = 2

WIDTH = COLS * CELL + (COLS + 1) * PADDING
HEIGHT = ROWS * CELL + (ROWS + 1) * PADDING


for theme in sorted(ROOT.glob("retrosmart-xcursor-*")):
    if theme.name.endswith("-shadow"):
        continue
    sheet = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))

    for i, filename in enumerate(CURSORS):
        img_path = theme / filename

        if not img_path.exists():
            print(f"[!] Missing {filename} in {theme.name}")
            continue

        img = Image.open(img_path).convert("RGBA")

        # Center the image inside the cell in case it isn't exactly 128×128.
        x = (i % COLS) * (CELL + PADDING) + PADDING + (CELL - img.width) // 2
        y = (i // COLS) * (CELL + PADDING) + PADDING + (CELL - img.height) // 2

        sheet.alpha_composite(img, (x, y))

    # Remove the common prefix from the folder name.
    name = theme.name.removeprefix("retrosmart-xcursor-")
        

    output = OUT / f"{name}.png"
    sheet.save(output)

    print(f"✓ {output}")

print("\nDone!")
