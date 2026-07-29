#!/usr/bin/env python3
"""
build_win.py -- turns the PNGs already produced by build.sh
(artifacts/png/<theme>/{32,64,128}-<name>.png) into real Windows cursor
theme folders (build_themes/Windows/<theme>/*.cur, *.ani, install.inf).

Requires build.sh to have been run first (uses its artifacts/png output
directly -- doesn't touch src/base or re-colorize anything). Writes
alongside build.sh's own build_themes/Linux/<theme>/ output.

Usage: scripts/build_windows.py [theme-name ...]
       (no args = build every theme found in artifacts/png/)
"""
from __future__ import annotations
import shutil
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from curtools import build_cur, build_ani  # noqa: E402

PNG_DIR = ROOT / "artifacts" / "png"
OUT_DIR = ROOT / "build_themes"
HOTSPOTS = ROOT / "data" / "hotspots.yaml"
SIZES = (32, 64, 128)

# Standard 15-role Windows cursor scheme, in the exact order Windows'
# "Control Panel\Cursors\Schemes" registry value expects them.
# role: (retrosmart cursor name, animated?)
WIN_ROLES = [
    ("Arrow",       "default",     False),
    ("Help",        "help",        False),
    ("AppStarting", "progress",    True),
    ("Wait",        "wait",        True),
    ("NWPen",       "pencil",      False),
    ("Crosshair",   "crosshair",   False),
    ("IBeam",       "text",        False),
    ("No",          "not-allowed", False),
    ("SizeNS",      "size_ver",    False),
    ("SizeWE",      "size_hor",    False),
    ("SizeNWSE",    "size_fdiag",  False),
    ("SizeNESW",    "size_bdiag",  False),
    ("SizeAll",     "fleur",       False),
    ("UpArrow",     "up-arrow",    False),
    ("Hand",        "pointer",     False),
]
# base filename (no extension) each role is saved under inside a theme
# folder -- the real extension (.cur vs .ani) is decided at build time from
# whether that role's source cursor actually turned out animated, so this
# can never drift out of sync with the file's real RIFF/ICO content again.
WIN_ROLE_BASENAME = {
    "Arrow": "arrow", "Help": "help", "AppStarting": "appstarting",
    "Wait": "wait", "NWPen": "nwpen", "Crosshair": "crosshair",
    "IBeam": "ibeam", "No": "no", "SizeNS": "sizens",
    "SizeWE": "sizewe", "SizeNWSE": "sizenwse", "SizeNESW": "sizenesw",
    "SizeAll": "sizeall", "UpArrow": "uparrow", "Hand": "hand",
}


def log(msg: str) -> None:
    print(f"\033[1;36m==>\033[0m {msg}")


def load_hotspots() -> list[dict]:
    import yaml
    groups = yaml.safe_load(HOTSPOTS.read_text()) or {}
    rows = []
    for cursors in groups.values():
        for c in cursors or []:
            rows.append(c)
    return rows


def frames_for(pdir: Path, name: str) -> list[str]:
    """All animation frame names for `name` (progress/wait), else [name]."""
    if name not in ("progress", "wait"):
        return [name]
    frames = sorted(p.stem[len(f"{SIZES[0]}-"):] for p in pdir.glob(f"{SIZES[0]}-{name}*.png"))
    return frames


def build_cursor_bytes(pdir: Path, frame: str, x: int, y: int, orig_size: int) -> bytes:
    images = []
    for s in SIZES:
        img = Image.open(pdir / f"{s}-{frame}.png")
        sx, sy = round(x * s / orig_size), round(y * s / orig_size)
        images.append((img, sx, sy))
    return build_cur(images)


def build_theme(theme: str, hotspots: list[dict]) -> None:
    pdir = PNG_DIR / theme
    if not pdir.is_dir():
        log(f"skip {theme}: no artifacts/png/{theme} (run ./build.sh first)")
        return
    outdir = OUT_DIR / "Windows" / theme
    outdir.mkdir(parents=True, exist_ok=True)
    log(f"win  : {theme}")

    made: dict[str, bytes] = {}   # cursor name -> raw .cur/.ani bytes
    is_ani: dict[str, bool] = {}

    for c in hotspots:
        name, size, x, y = c["name"], c["size"], c["x"], c["y"]
        delay = c.get("delay")
        frames = frames_for(pdir, name)
        if delay is not None and len(frames) > 1:
            frame_curs = [build_cursor_bytes(pdir, f, x, y, size) for f in frames]
            made[name] = build_ani(frame_curs, [int(delay)] * len(frame_curs))
            is_ani[name] = True
        else:
            made[name] = build_cursor_bytes(pdir, frames[0], x, y, size)
            is_ani[name] = False

    def ext(nm: str) -> str:
        return "ani" if is_ani.get(nm) else "cur"

    for name, data in made.items():
        (outdir / f"{name}.{ext(name)}").write_bytes(data)

    # NOTE: deliberately NOT writing out data/links.txt aliases here.
    # Those aliases fall into two buckets, neither useful on Windows:
    #   - raw-hash names (e.g. "08e8e1c95fe2fc01f976f1e063a24ccd") exist
    #     purely so old X11/Xcursor apps that look up a cursor by hash
    #     (XcursorLibraryLoadCursor) don't fall back to the plain arrow --
    #     Windows has no such hash-lookup mechanism at all.
    #   - legacy X11-core-font names ("grab", "circle", "hand1", "xterm",
    #     "top_left_arrow", ...) are pre-Xcursor naming conventions some
    #     X11 window managers/toolkits still query by default; Windows
    #     doesn't do name-based cursor resolution either.
    # The canonical `made` names above (default, pointer, text, ...) are
    # already human-readable and cover everything worth hand-assigning.

    # standard 15-role files (arrow.cur, wait.ani, ...) for the install.inf
    missing_roles = []
    role_file: dict[str, str] = {}
    for role, cname, _animated in WIN_ROLES:
        if cname not in made:
            missing_roles.append((role, cname))
            continue
        fname = f"{WIN_ROLE_BASENAME[role]}.{ext(cname)}"
        role_file[role] = fname
        (outdir / fname).write_bytes(made[cname])
    if missing_roles:
        log(f"  warning: {theme} missing source cursors for roles: {missing_roles}")

    write_inf(theme, outdir, role_file)
    thumb = pdir / "128-default.png"
    if thumb.exists():
        shutil.copy(thumb, outdir / "thumbnail.png")


def write_inf(theme: str, outdir: Path, role_file: dict[str, str]) -> None:
    display = theme.replace("retrosmart-xcursor-", "Retrosmart ").replace("-", " ").title()
    roles = [r for r, _, _ in WIN_ROLES if r in role_file]
    file_list = ",".join(f"%10%\\Cursors\\{theme}\\{role_file[r]}" for r in roles)
    cur_section = "\n".join(role_file[r] for r in roles)
    inf = f"""[Version]
signature="$CHICAGO$"

[DefaultInstall]
CopyFiles=Scheme.Cur
AddReg=Scheme.Reg

[DestinationDirs]
Scheme.Cur=10,"Cursors\\{theme}"

[Scheme.Reg]
HKCU,"Control Panel\\Cursors\\Schemes","{display}",,"{file_list}"

[Scheme.Cur]
{cur_section}

[Strings]
"""
    (outdir / "install.inf").write_text(inf, newline="\r\n")
    readme = f"""Retrosmart cursors for Windows -- {display}
=================================================

To install:
  1. Right-click "install.inf" and choose "Install".
     (This registers "{display}" as a cursor scheme -- it does not
     apply it automatically.)
  2. Open Settings > Bluetooth & devices > Mouse > Additional mouse
     settings (or "Control Panel > Mouse"), go to the "Pointers" tab,
     and pick "{display}" from the Scheme dropdown, then Apply.

Besides the 15 files Windows uses for a scheme, every other Retrosmart
cursor is also included as a plain .cur/.ani file in this folder (named
after its role -- default, pointer, text, crosshair, zoom-in, ...), in
case you want to assign one manually (e.g. via a game or app that lets
you pick a custom cursor file, or via a registry/AutoHotkey script).

Note: this Windows build was generated automatically from the same
32px pixel-art source as the Linux/Xcursor theme; it hasn't been
tested on a real Windows machine, so if something looks off (wrong
hotspot, wrong role) please open an issue on the GitHub repo.
"""
    (outdir / "README.txt").write_text(readme, newline="\r\n")


def main() -> int:
    if not PNG_DIR.is_dir():
        print("error: artifacts/png/ not found -- run ./build.sh first", file=sys.stderr)
        return 1
    hotspots = load_hotspots()
    wanted = sys.argv[1:]
    themes = wanted if wanted else sorted(p.name for p in PNG_DIR.iterdir() if p.is_dir())
    OUT_DIR.mkdir(exist_ok=True)
    for theme in themes:
        build_theme(theme, hotspots)
    log(f"Done. Windows theme folders are in {OUT_DIR}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
