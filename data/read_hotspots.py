#!/usr/bin/env python3
"""Flatten data/hotspots.yaml into TSV for build.sh to consume.

Output columns: name  x  y  delay
(delay is blank when the cursor isn't animated)

See data/hotspots.yaml's header comment for the schema, and
data/hotspots_lib.py for how a style's x/y/delay get resolved against the
"all" fallback.

Usage: read_hotspots.py path/to/hotspots.yaml [style]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hotspots_lib import load_entries, resolve


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: read_hotspots.py <hotspots.yaml> [style]", file=sys.stderr)
        return 1

    style = sys.argv[2] if len(sys.argv) == 3 else None

    for entry in load_entries(sys.argv[1]):
        name = entry.get("cursor")
        if not name:
            print(f"error: hotspots entry missing 'cursor' field: {entry}", file=sys.stderr)
            return 1

        values = resolve(entry, style)
        if "x" not in values or "y" not in values:
            print(
                f"error: cursor '{name}' has no resolved x/y for style "
                f"'{style}' (check 'all' and '{style}' in its hotspots map)",
                file=sys.stderr,
            )
            return 1

        fields = [name, values["x"], values["y"], values.get("delay", "")]
        print("\t".join(str(v) for v in fields))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
