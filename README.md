![banner](media/banner.png)

# Retrosmart Xcursor (fork)

This is a fork of [retrosmart-x11-cursors](https://github.com/mdomlop/retrosmart-x11-cursors)
by [Manuel Domínguez López](https://github.com/mdomlop). Credit for the
original artwork and design goes to him — see [AUTHORS](AUTHORS) and
[NOTES.md](NOTES.md) for details on what changed in this fork.

## What's new in this fork

- **Multiple Cursor Styles**: Includes `mac-ish`, `win-ish`, `cur-font`, and `win-3d` (`src/`). Win-3D keeps fixed Win95/98 chrome and recolors a single `accent` (shadow tone is auto-derived).
- **HiDPI Support**: New sizes (32px, 64px, and 128px), rendered cleanly via nearest-neighbor scaling.
- **Unified Color Schemes**: Master configuration in `schemes.yaml` (`outline` / `fill` for most styles; `accent` for win-3d).
- **Streamlined Multi-Core Build**: In-memory streaming directly to PNGs (no intermediate XPM files on disk) with parallel CPU execution (`nproc`). Builds X11 and Windows themes.
- **Theme Variants**: 28 color schemes (8× mac-ish / win-ish / cur-font + 4 win-3d), plain and drop-shadow — 72 installable themes total.

Some of this fork's tooling and docs were put together with AI assistance.
The cursor artwork itself is hand-drawn/hand-edited pixel art.

## Downloads

Releases are packaged into 4 archives — pick your platform and whether you
want the classic black/white looks or the full extra-color set:

| Archive | Contains |
|---|---|
| `retrosmart-cursor-classic-<version>-linux.tar.gz` | Classic + Inverted schemes, X11 (Mac-ish, Win-ish, Cur-font; plain + shadow) |
| `retrosmart-cursor-classic-<version>-windows.zip` | Classic + Inverted schemes, Windows `.cur`/`.ani` |
| `retrosmart-cursor-extras-<version>-linux.tar.gz` | All other color schemes (Catppuccin, Everforest, Gruvbox, Rose Pine, Solarized Dark, …) plus Win-3D, X11 |
| `retrosmart-cursor-extras-<version>-windows.zip` | Same extra schemes (incl. Win-3D), Windows `.cur`/`.ani` |

Grab both archives for your OS if you want everything.

## Previews

### Mac-ish Styles

![Mac-ish Classic](media/mac-ish-classic.png)
![Mac-ish Inverted](media/mac-ish-inverted.png)
![Mac-ish Catppuccin](media/mac-ish-catppucin.png)
![Mac-ish Everforest](media/mac-ish-everforest.png)
![Mac-ish Gruvbox](media/mac-ish-gruvbox.png)
![Mac-ish Rose Pine](media/mac-ish-rose_pine.png)
![Mac-ish Solarized Dark](media/mac-ish-solarized_dark.png)
![Mac-ish Violet](media/mac-ish-violet.png)

### Win-ish Styles

![Win-ish Classic](media/win-ish-classic.png)
![Win-ish Inverted](media/win-ish-inverted.png)
![Win-ish Catppuccin](media/win-ish-catppucin.png)
![Win-ish Everforest](media/win-ish-everforest.png)
![Win-ish Gruvbox](media/win-ish-gruvbox.png)
![Win-ish Rose Pine](media/win-ish-rose_pine.png)
![Win-ish Solarized Dark](media/win-ish-solarized_dark.png)
![Win-ish Violet](media/win-ish-violet.png)

### Cur-font Styles

![Cur-font Classic](media/cur-font-classic.png)
![Cur-font Inverted](media/cur-font-inverted.png)
![Cur-font Catppuccin](media/cur-font-catppucin.png)
![Cur-font Everforest](media/cur-font-everforest.png)
![Cur-font Gruvbox](media/cur-font-gruvbox.png)
![Cur-font Rose Pine](media/cur-font-rose_pine.png)
![Cur-font Solarized Dark](media/cur-font-solarized_dark.png)
![Cur-font Violet](media/cur-font-violet.png)

### Win-3D Styles

![Win-3D Red](media/win-3d-red.png)
![Win-3D Green](media/win-3d-green.png)
![Win-3D Blue](media/win-3d-blue.png)
![Win-3D Violet](media/win-3d-violet.png)

![Win-3D Red Hourglass](media/win-3d-red-hourglass.png)
![Win-3D Green Hourglass](media/win-3d-green-hourglass.png)
![Win-3D Blue Hourglass](media/win-3d-blue-hourglass.png)
![Win-3D Violet Hourglass](media/win-3d-violet-hourglass.png)

![Win-3D Red Hand Stopwatch](media/win-3d-red-hand_stopwatch.png)
![Win-3D Green Hand Stopwatch](media/win-3d-green-hand_stopwatch.png)
![Win-3D Blue Hand Stopwatch](media/win-3d-blue-hand_stopwatch.png)
![Win-3D Violet Hand Stopwatch](media/win-3d-violet-hand_stopwatch.png)

Regenerate preview sheets with `python3 tools/generate_previews.py` after `./build.sh png`.

## Requirements

- `bash`
- [ImageMagick](https://imagemagick.org/) (`convert`)
- `xcursorgen` (part of `xorg-xcursor` / `libxcursor` on most distros)
- `python3` (with `PyYAML` and `Pillow`)

## Building

```sh
git clone https://github.com/useless-anvil/retrosmart-cursor.git
cd retrosmart-cursor
make            # or: ./build.sh all
```

This runs the full pipeline:

1. **Palette check**: Warns on unrecognized colors in `src/` XPMs.
2. **Recolors, upscales, and rasterizes**: Streams the 32px sources through in-memory recoloring (`outline`/`fill`, or win-3d `accent` + auto shadow), nearest-neighbor upscaling (32px, 64px, 128px), and optional drop-shadow effects straight into PNGs.
3. **Generates hotspot configs**: Creates `xcursorgen` input files from `data/hotspots.yaml`.
4. **Builds X11 cursors**: Binary cursors, aliases from `data/links.txt`, and `index.theme` under `build_themes/Linux/<style>/<theme-name>/`.
5. **Builds Windows cursors**: `.cur` / `.ani` + `install.inf` under `build_themes/Windows/<style>/<theme-name>/` via `scripts/build_windows.py`.

Output is grouped by style (`mac-ish`, `win-ish`, `cur-font`, `win-3d`).

Other build targets:

```sh
./build.sh png      # recolor, upscale, and rasterize PNGs
./build.sh in       # generate xcursorgen input files only
./build.sh cursors  # build X11 binaries/aliases/theme metadata only
./build.sh windows  # build Windows themes from existing PNG artifacts
./build.sh check    # palette warnings only
./build.sh clean    # remove artifacts/ and build_themes/
```

Preview sheets for README / store listings:

```sh
./build.sh png
python3 tools/generate_previews.py   # writes media/<scheme>.png
```

- To tweak theme palettes: edit `schemes.yaml` (`outline`/`fill`, or `accent` for win-3d).
- To change how a cursor looks: edit its file(s) in `src/<style>/` (32px only).
- To change a cursor's hotspot (click point): edit `data/hotspots.yaml`. Each
  cursor's `hotspots` map is keyed by style (`mac-ish`, `win-ish`, `cur-font`, `win-3d`, …), with
  `all` as the fallback for styles that don't need their own value.

## License

GPL-3.0, inherited from the original project. See [COPYING](COPYING) and
[LICENSE](LICENSE).
