#!/usr/bin/env python3
"""Flatten data/hotspots.yaml into TSV for build.sh to consume.

Output columns: name  size  x  y  file  delay
(delay is blank when the cursor isn't animated)

A cursor entry can optionally carry a per-style "overrides" map, e.g.:
    - {name: pointer, size: 32, x: 3, y: 0, file: 32-pointer.png,
       overrides: {win-ish: {x: 5, y: 0}}}
When a style is passed as the 2nd argument and it has an override, its x/y
(either or both) replace the default for that row only.

Usage: read_hotspots.py path/to/hotspots.yaml [style]
"""
import sys
import yaml


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: read_hotspots.py <hotspots.yaml> [style]", file=sys.stderr)
        return 1

    style = sys.argv[2] if len(sys.argv) == 3 else None

    with open(sys.argv[1]) as f:
        groups = yaml.safe_load(f) or {}

    for group_name, cursors in groups.items():
        for c in cursors or []:
            try:
                name, size, x, y, file_ = c["name"], c["size"], c["x"], c["y"], c["file"]
            except KeyError as missing:
                print(
                    f"error: cursor entry in group '{group_name}' is missing "
                    f"required field {missing}",
                    file=sys.stderr,
                )
                return 1

            override = (c.get("overrides") or {}).get(style) if style else None
            if override:
                x = override.get("x", x)
                y = override.get("y", y)

            fields = [name, size, x, y, file_, c.get("delay", "")]
            print("\t".join(str(v) for v in fields))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
