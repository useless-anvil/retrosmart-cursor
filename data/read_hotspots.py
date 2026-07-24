#!/usr/bin/env python3
"""Flatten data/hotspots.yaml into TSV for build.sh to consume.

Output columns: name  size  x  y  file  delay
(delay is blank when the cursor isn't animated)

Usage: read_hotspots.py path/to/hotspots.yaml
"""
import sys
import yaml


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: read_hotspots.py <hotspots.yaml>", file=sys.stderr)
        return 1

    with open(sys.argv[1]) as f:
        groups = yaml.safe_load(f) or {}

    for group_name, cursors in groups.items():
        for c in cursors or []:
            try:
                fields = [c["name"], c["size"], c["x"], c["y"], c["file"]]
            except KeyError as missing:
                print(
                    f"error: cursor entry in group '{group_name}' is missing "
                    f"required field {missing}",
                    file=sys.stderr,
                )
                return 1
            fields.append(c.get("delay", ""))
            print("\t".join(str(v) for v in fields))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
