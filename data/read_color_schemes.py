#!/usr/bin/env python3
"""Flatten color_schemes/*.yaml into TSV for build.sh to consume.

Each *_scheme.yaml (or *.yaml) file in the schemes directory describes one
color scheme:

    name: "Gruvbox"        # optional, display name used in index.theme
    name_es: "Gruvbox"      # optional, Spanish display name
    primary: "#ebdbb2"      # fill color   (replaces the xpm's cyan  #00FFFF)
    secondary: "#282828"    # outline color(replaces the xpm's coral #FF7F50)
    shadow: "#000000"       # drop-shadow color, used by the "-shadow" variant
    shadow: false           # (alternative) set to false/no/0 to skip the
                             # shadow variant entirely for this scheme

Output columns (one row per scheme):
    id  primary  secondary  shadow_color  make_shadow(0/1)  name  name_es

`id` is the filename with a trailing "_scheme"/".yaml" stripped, e.g.
"gruvbox_scheme.yaml" -> "gruvbox". It's used verbatim to build the theme
name: retrosmart-xcursor-<id> (and retrosmart-xcursor-<id>-shadow).

Usage: read_color_schemes.py path/to/color_schemes/
"""
import re
import sys
from pathlib import Path

import yaml

HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
FALSY = {"false", "no", "0", "off", "none", ""}


def scheme_id(path: Path) -> str:
    stem = path.stem
    if stem.endswith("_scheme"):
        stem = stem[: -len("_scheme")]
    return stem


def titlecase(id_: str) -> str:
    return id_.replace("_", " ").replace("-", " ").title()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: read_color_schemes.py <color_schemes_dir>", file=sys.stderr)
        return 1

    schemes_dir = Path(sys.argv[1])
    files = sorted(schemes_dir.glob("*.yaml")) + sorted(schemes_dir.glob("*.yml"))
    if not files:
        print(f"error: no *.yaml files found in {schemes_dir}", file=sys.stderr)
        return 1

    seen_ids = set()
    for path in files:
        with open(path) as f:
            data = yaml.safe_load(f) or {}

        id_ = scheme_id(path)
        if id_ in seen_ids:
            print(f"error: duplicate color scheme id '{id_}' (from {path})", file=sys.stderr)
            return 1
        seen_ids.add(id_)

        try:
            primary = str(data["primary"])
            secondary = str(data["secondary"])
        except KeyError as missing:
            print(f"error: {path} is missing required field {missing}", file=sys.stderr)
            return 1

        for label, value in (("primary", primary), ("secondary", secondary)):
            if not HEX_RE.match(value):
                print(
                    f"error: {path} field '{label}' = '{value}' is not a "
                    f"'#RRGGBB' hex color",
                    file=sys.stderr,
                )
                return 1

        shadow_raw = data.get("shadow", "#000000")
        if isinstance(shadow_raw, bool):
            make_shadow = "1" if shadow_raw else "0"
            shadow_color = primary
        elif str(shadow_raw).strip().lower() in FALSY:
            make_shadow = "0"
            shadow_color = primary
        else:
            shadow_color = str(shadow_raw)
            if not HEX_RE.match(shadow_color):
                print(
                    f"error: {path} field 'shadow' = '{shadow_color}' is not "
                    f"a '#RRGGBB' hex color (or false/no/0 to disable)",
                    file=sys.stderr,
                )
                return 1
            make_shadow = "1"

        name = str(data.get("name", titlecase(id_)))
        name_es = str(data.get("name_es", name))

        print("\t".join([id_, primary, secondary, shadow_color, make_shadow, name, name_es]))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
