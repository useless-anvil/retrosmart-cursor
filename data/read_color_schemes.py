#!/usr/bin/env python3
"""Flatten schemes.yaml into TSV for build.sh to consume.

schemes.yaml describes color schemes AND which cursor style each scheme renders with:

    mac-ish-catppucin:
      name: "CATPPUCCIN (Mac-ish)"  # display name used in index.theme
      outline: "#1e1e2e"          # outline color (replaces the xpm's cyan #00FFFF)
      fill: "#cdd6f4"             # fill color    (replaces the xpm's coral #FF7F50)
      cursors: "mac-ish"          # required: which src/<style>/ folder to use

outline/fill are required UNLESS the scheme sets `accent` instead (accent
styles, e.g. win-3d, never use outline/fill and should omit them -- see
schemes.yaml's win-3d-* entries).

Output columns (one row per scheme):
    id  outline  fill  bright  dark  name  cursors  accent  accent_dark

`accent` is optional (used by shaded styles like win-3d, which keep their
chrome colors fixed and only recolor one accent hue). When present,
`accent_dark` is always derived automatically at a fixed 0.58 brightness
scale (matching the ratio observed in the original Win95/98 3D cursor art:
0x94/0xFF ~= 0.58) — it is not a schemes.yaml field. When `accent` is
absent, both columns are emitted empty.

`bright` / `dark` are likewise derived, not schemes.yaml fields: `bright` is
whichever of `outline`/`fill` has the higher perceptual luminance and `dark`
is the other one. build.sh uses them for cursors sourced from a brighter/
folder: those always get outline = bright, fill = dark, regardless of the
scheme's own orientation (so e.g. cur-font's pointing hand is white outline /
black fill in both classic and white). Both are empty for accent schemes.

Usage: read_color_schemes.py [path/to/schemes.yaml | path/to/color_schemes_dir]
"""
import re
import sys
from pathlib import Path

import yaml

HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
ACCENT_SCALE = 0.58


def scale_hex(value: str, scale: float) -> str:
    r = int(value[1:3], 16)
    g = int(value[3:5], 16)
    b = int(value[5:7], 16)
    r, g, b = (max(0, min(255, round(c * scale))) for c in (r, g, b))
    return f"#{r:02X}{g:02X}{b:02X}"


def luminance(value: str) -> float:
    r = int(value[1:3], 16)
    g = int(value[3:5], 16)
    b = int(value[5:7], 16)
    # ITU BT.601 perceptual luma.
    return 0.299 * r + 0.587 * g + 0.114 * b


def scheme_id(path: Path, root: Path) -> str:
    rel = path.relative_to(root).with_suffix("")
    stem = str(rel).replace("/", "-").replace("\\", "-")
    if stem.endswith("_scheme"):
        stem = stem[: -len("_scheme")]
    return stem


def titlecase(id_: str) -> str:
    return id_.replace("_", " ").replace("-", " ").title()


def process_scheme(id_: str, scheme_data: dict, source_label: str, seen_ids: set) -> bool:
    if id_ in seen_ids:
        print(f"error: duplicate color scheme id '{id_}' (from {source_label})", file=sys.stderr)
        return False
    seen_ids.add(id_)

    outline = scheme_data.get("outline", scheme_data.get("primary"))
    fill = scheme_data.get("fill", scheme_data.get("secondary"))
    accent = scheme_data.get("accent")

    # Accent schemes (win-3d) never use outline/fill -- the style's chrome is
    # literal in the XPM and only the accent pair gets substituted. They're
    # optional there, required everywhere else.
    if accent is None:
        if outline is None:
            print(f"error: {source_label} scheme '{id_}' is missing required field 'outline'", file=sys.stderr)
            return False
        if fill is None:
            print(f"error: {source_label} scheme '{id_}' is missing required field 'fill'", file=sys.stderr)
            return False

    outline = "" if outline is None else str(outline)
    fill = "" if fill is None else str(fill)

    for label, value in (("outline", outline), ("fill", fill)):
        if value and not HEX_RE.match(value):
            print(
                f"error: {source_label} scheme '{id_}' field '{label}' = '{value}' is not a "
                f"'#RRGGBB' hex color",
                file=sys.stderr,
            )
            return False

    if "accent_dark" in scheme_data:
        print(
            f"error: {source_label} scheme '{id_}' has 'accent_dark' — that field was removed; "
            f"shadow is auto-derived from 'accent' at scale {ACCENT_SCALE}",
            file=sys.stderr,
        )
        return False

    if accent is not None:
        accent = str(accent)
        if not HEX_RE.match(accent):
            print(
                f"error: {source_label} scheme '{id_}' field 'accent' = '{accent}' is not a "
                f"'#RRGGBB' hex color",
                file=sys.stderr,
            )
            return False
        accent_dark = scale_hex(accent, ACCENT_SCALE)
    else:
        accent = ""
        accent_dark = ""

    if outline and fill:
        if luminance(outline) >= luminance(fill):
            bright, dark = outline, fill
        else:
            bright, dark = fill, outline
    else:
        bright, dark = "", ""

    name = str(scheme_data.get("name", titlecase(id_)))

    cursors = scheme_data.get("cursors")
    if not cursors or not isinstance(cursors, str):
        print(f"error: {source_label} scheme '{id_}' is missing required field 'cursors'", file=sys.stderr)
        return False
    if "/" in cursors or "\\" in cursors or cursors in (".", ".."):
        print(f"error: {source_label} scheme '{id_}' field 'cursors' = '{cursors}' must be a plain folder name", file=sys.stderr)
        return False

    print("\t".join([id_, outline, fill, bright, dark, name, cursors, accent, accent_dark]))
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: read_color_schemes.py <schemes.yaml | color_schemes_dir>", file=sys.stderr)
        return 1

    path_arg = Path(sys.argv[1])
    if path_arg.is_file():
        files = [path_arg]
        root_dir = path_arg.parent
    elif (path_arg / "schemes.yaml").is_file():
        files = [path_arg / "schemes.yaml"]
        root_dir = path_arg
    elif path_arg.is_dir():
        files = sorted(path_arg.rglob("*.yaml")) + sorted(path_arg.rglob("*.yml"))
        root_dir = path_arg
    else:
        print(f"error: '{path_arg}' not found", file=sys.stderr)
        return 1

    if not files:
        print(f"error: no *.yaml files found under {path_arg}", file=sys.stderr)
        return 1

    seen_ids = set()
    for path in files:
        with open(path) as f:
            data = yaml.safe_load(f) or {}

        if isinstance(data, dict) and any(isinstance(v, dict) for v in data.values()):
            for s_id, s_data in data.items():
                if isinstance(s_data, dict):
                    if not process_scheme(s_id, s_data, str(path), seen_ids):
                        return 1
        elif isinstance(data, list):
            for idx, s_data in enumerate(data):
                if isinstance(s_data, dict):
                    s_id = str(s_data.get("id", f"scheme_{idx}"))
                    if not process_scheme(s_id, s_data, str(path), seen_ids):
                        return 1
        elif isinstance(data, dict):
            s_id = scheme_id(path, root_dir)
            if not process_scheme(s_id, data, str(path), seen_ids):
                return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
