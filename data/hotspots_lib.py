"""Shared helpers for reading data/hotspots.yaml.

Used by data/read_hotspots.py, tools/generate_previews.py, and
scripts/build_windows.py -- keep this the single place that knows how
hotspots.yaml is shaped, so the three consumers can't drift out of sync
with each other.

Schema (see data/hotspots.yaml's own header comment for the full story):

    - cursor: pointer
      hotspots:
        all:      {x: 3, y: 0}
        win-ish:  {x: 5, y: 0}
        cur-font: {x: 0, y: 2}
        win-3d:   {x: 7, y: 0}

"all" is the fallback used when a style has no entry of its own. A style's
entry only needs to carry the keys (x/y/delay) that actually differ from
"all" -- resolve() merges on top, it doesn't require a full x/y/delay set.
"""
from pathlib import Path

import yaml

# px size of the hand-drawn XPM source art every x/y value in hotspots.yaml
# is relative to. All source art is 32px; this is a constant, not a
# per-cursor property, because the hotspot-scaling math (see build.sh's
# step_in and scripts/build_windows.py's build_cursor_bytes) assumes one
# fixed source size for every cursor.
SOURCE_SIZE = 32


def load_entries(path) -> list[dict]:
    """Flatten hotspots.yaml's headed groups into one flat list of entries."""
    groups = yaml.safe_load(Path(path).read_text()) or {}
    entries = []
    for cursors in groups.values():
        for c in cursors or []:
            entries.append(c)
    return entries


def resolve(entry: dict, style: str | None) -> dict:
    """Resolve x/y/delay for `entry` under `style`.

    Starts from hotspots.all (if present), then layers the style-specific
    keys on top (if a style is given and has an entry). Missing keys are
    simply absent from the result -- callers decide their own defaults.
    """
    hotspots = entry.get("hotspots", {})
    values = dict(hotspots.get("all", {}))
    if style and style in hotspots:
        values.update(hotspots[style])
    return values
