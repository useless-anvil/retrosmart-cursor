#!/usr/bin/env bash
#
# build.sh — builds the Retrosmart Xcursor themes.
#
# Pipeline (output goes into ./artifacts and ./build_themes, nothing else is touched):
#
#   color_schemes/*.yaml (primary/secondary/shadow hex colors, one file per scheme)
#         |  0. load       -> THEMES (in-memory: one scheme -> a plain + a "-shadow" theme)
#   src/base/32-*.xpm  (32px hand-drawn source, "cyan"/"coral" placeholder colors)
#         |  1. colorize   -> artifacts/xpm/<theme>/32-*.xpm   (cyan/coral -> scheme colors)
#         |  2. upscale    -> artifacts/xpm/<theme>/64-*.xpm   (32px x2, nearest-neighbor)
#         |  3. rasterize  -> artifacts/png/<theme>/{32,64}-*.png (+ drop shadow if theme wants one)
#         |  4. hotspots   -> artifacts/in/<cursor>             (from data/hotspots.yaml)
#         |  5. xcursorgen -> build_themes/<theme>/cursors/<cursor> (real binary cursor)
#         |  6. aliases    -> build_themes/<theme>/cursors/<alias>  (symlinks, from data/links.txt)
#         -  7. theme meta -> build_themes/<theme>/index.theme (src/themes/*.theme, or auto-generated)
#
# artifacts/   = scratch/intermediate files used only to build the themes, safe to delete anytime
# build_themes/ = final, ready-to-install cursor theme folders (just cursors/ + index.theme)
#
# To change how a cursor LOOKS: edit its file(s) in src/base/ (32px only, everything
# scales up from there).
# To change WHERE a cursor's hotspot (click point) is: edit data/hotspots.yaml.
# To add/rename a symlinked alias (e.g. "grab" -> "openhand"): edit data/links.txt.
# To add/tweak a COLOR SCHEME (theme variant): add/edit a *.yaml in color_schemes/,
# see color_schemes/white_scheme.yaml for the format. Each scheme yields two themes:
# "retrosmart-xcursor-<id>" and "retrosmart-xcursor-<id>-shadow" (set "shadow: false"
# in the yaml to skip the shadow variant).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ARTIFACTS="$ROOT/artifacts"
BUILD_THEMES="$ROOT/build_themes"
SRC_BASE="$ROOT/src/base"
SRC_THEMES="$ROOT/src/themes"
HOTSPOTS="$ROOT/data/hotspots.yaml"
READ_HOTSPOTS="$ROOT/data/read_hotspots.py"
LINKS="$ROOT/data/links.txt"
COLOR_SCHEMES="$ROOT/color_schemes"
READ_COLOR_SCHEMES="$ROOT/data/read_color_schemes.py"

# Upscale filter: 'point' = crisp nearest-neighbor (keeps the pixel-art look, and is
# what makes the 64px version an actually-clean 2x rather than a blurry/crooked resample).
UPSCALE_FILTER="point"

SIZES=(32 64 128)

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# THEMES is built from color_schemes/*.yaml (one scheme -> up to two themes:
# a plain one and, unless the scheme opts out, a "-shadow" one).
#
# Each entry: theme-name : primary(cyan-replacement) : secondary(coral-replacement) : has-shadow(0/1) : shadow-color
#
# THEME_NAME / THEME_NAME_ES hold the index.theme display names for themes
# that don't already have a hand-written src/themes/<theme>.theme file.
# ---------------------------------------------------------------------------
declare -a THEMES=()
declare -A THEME_NAME=()
declare -A THEME_NAME_ES=()

load_themes() {
  THEMES=()
  THEME_NAME=()
  THEME_NAME_ES=()
  local id primary secondary shadow_color make_shadow name name_es
  while IFS=$'\t' read -r id primary secondary shadow_color make_shadow name name_es; do
    [ -z "$id" ] && continue
    local base="retrosmart-xcursor-$id"
    THEMES+=("$base:$primary:$secondary:0:$shadow_color")
    THEME_NAME["$base"]="$name"
    THEME_NAME_ES["$base"]="$name_es"
    if [ "$make_shadow" = "1" ]; then
      local shadow_theme="${base}-shadow"
      THEMES+=("$shadow_theme:$primary:$secondary:1:$shadow_color")
      THEME_NAME["$shadow_theme"]="$name Shadow"
      THEME_NAME_ES["$shadow_theme"]="$name_es Sombra"
    fi
  done < <(python3 "$READ_COLOR_SCHEMES" "$COLOR_SCHEMES")

  if [ "${#THEMES[@]}" -eq 0 ]; then
    echo "error: no usable color schemes found in $COLOR_SCHEMES" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Figure out every cursor name + its frame list (most cursors are 1 frame;
# progress/wait are animated -- frames are auto-detected from whatever
# 32-progress*.xpm / 32-wait*.xpm files exist in src/base, so adding a frame
# is as simple as dropping in a new xpm).
# ---------------------------------------------------------------------------
# TSV: name  size  x  y  file  delay  (one row per cursor, from data/hotspots.yaml)
hotspots_tsv() {
  python3 "$READ_HOTSPOTS" "$HOTSPOTS"
}

cursor_names() {
  hotspots_tsv | cut -f1
}

frames_for() {
  local name="$1"
  case "$name" in
    progress|wait)
      local f
      for f in "$SRC_BASE"/32-"$name"*.xpm; do
        basename "$f" .xpm | sed 's/^32-//'
      done
      ;;
    *)
      echo "$name"
      ;;
  esac
}

clean() {
  log "Removing $ARTIFACTS and $BUILD_THEMES"
  rm -rf "$ARTIFACTS" "$BUILD_THEMES"
}

# ---------------------------------------------------------------------------
# 1+2: colorize the 32px base, then upscale to 64px
# ---------------------------------------------------------------------------
step_xpm() {
  local theme cyan coral has_shadow shadow_color xpm base name
  for entry in "${THEMES[@]}"; do
    IFS=: read -r theme cyan coral has_shadow shadow_color <<<"$entry"
    local outdir="$ARTIFACTS/xpm/$theme"
    mkdir -p "$outdir"
    log "xpm  : $theme (cyan->$cyan, coral->$coral)"
    for xpm in "$SRC_BASE"/32-*.xpm; do
      base="$(basename "$xpm")"
      sed \
        -e "s/#00FFFF/$cyan/gI" \
        -e "s/#FF7F50/$coral/gI" \
        "$xpm" > "$outdir/$base"
    done
    for xpm in "$outdir"/32-*.xpm; do
      name="$(basename "$xpm" .xpm | sed 's/^32-//')"
      convert -filter "$UPSCALE_FILTER" "$xpm" -scale 200% "$outdir/64-$name.xpm"
    done
    for xpm in "$outdir"/64-*.xpm; do
      name="$(basename "$xpm" .xpm | sed 's/^64-//')"
      convert -filter "$UPSCALE_FILTER" "$xpm" -scale 200% "$outdir/128-$name.xpm"
    done
  done
}

# ---------------------------------------------------------------------------
# 3: rasterize xpm -> png, applying the drop shadow for "-shadow" themes
# ---------------------------------------------------------------------------
step_png() {
  local theme cyan coral has_shadow shadow_color size xpm base
  for entry in "${THEMES[@]}"; do
    IFS=: read -r theme cyan coral has_shadow shadow_color <<<"$entry"
    local xdir="$ARTIFACTS/xpm/$theme"
    local pdir="$ARTIFACTS/png/$theme"
    mkdir -p "$pdir"
    log "png  : $theme$( [ "$has_shadow" = 1 ] && echo " (+shadow $shadow_color)" )"
    for xpm in "$xdir"/*.xpm; do
      base="$(basename "$xpm" .xpm)"
      if [ "$has_shadow" = 1 ]; then
        # Drop-shadow recipe (unchanged from upstream), color comes from the scheme's "shadow" field.
        convert "$xpm" \( +clone -background "$shadow_color" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/$base.png"
      else
        convert "$xpm" "$pdir/$base.png"
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# 4: build the xcursorgen .in files straight from data/hotspots.yaml
# ---------------------------------------------------------------------------
step_in() {
  local indir="$ARTIFACTS/in"
  mkdir -p "$indir"
  log "in   : generating from data/hotspots.yaml"
  while IFS=$'\t' read -r name size x y _filename delay; do
    [ -z "$name" ] && continue
    local out="$indir/$name"
    : > "$out"
    for frame in $(frames_for "$name"); do
      for s in "${SIZES[@]}"; do
        local sx=$((x * s / size))
        local sy=$((y * s / size))
        if [ -n "${delay:-}" ]; then
          printf '%s %s %s %s-%s.png %s\n' "$s" "$sx" "$sy" "$s" "$frame" "$delay" >> "$out"
        else
          printf '%s %s %s %s-%s.png\n' "$s" "$sx" "$sy" "$s" "$frame" >> "$out"
        fi
      done
    done
  done < <(hotspots_tsv)
}

# ---------------------------------------------------------------------------
# 5+6+7: generate the real cursor binaries, their aliases, and index.theme
# ---------------------------------------------------------------------------
step_cursors() {
  local theme cyan coral has_shadow shadow_color name link target theme_file
  for entry in "${THEMES[@]}"; do
    IFS=: read -r theme cyan coral has_shadow shadow_color <<<"$entry"
    local cdir="$BUILD_THEMES/$theme/cursors"
    mkdir -p "$cdir"
    log "build: $theme"
    while read -r name; do
      [ -z "$name" ] && continue
      xcursorgen -p "$ARTIFACTS/png/$theme" "$ARTIFACTS/in/$name" "$cdir/$name"
    done < <(cursor_names)

    while IFS=: read -r link target; do
      [ -z "$link" ] && continue
      [[ "$link" == \#* ]] && continue
      ln -sf "$target" "$cdir/$link"
    done < "$LINKS"

    # Prefer a hand-written src/themes/<theme>.theme (lets you add extra
    # locales, tweak wording, etc.); otherwise generate one from the color
    # scheme's "name"/"name_es" fields.
    theme_file="$SRC_THEMES/$theme.theme"
    if [ -f "$theme_file" ]; then
      cp "$theme_file" "$BUILD_THEMES/$theme/index.theme"
    else
      cat > "$BUILD_THEMES/$theme/index.theme" <<EOF
[Icon Theme]
Name=${THEME_NAME[$theme]}
Name[es]=${THEME_NAME_ES[$theme]}
Comment=Retrosmart cursor theme
Comment[es]=Tema de cursores Retrosmart
EOF
    fi
    cp "$ARTIFACTS/png/$theme/128-default.png" "$cdir/thumbnail.png"
  done
}

all() {
  step_xpm
  step_png
  step_in
  step_cursors
  log "Done. Ready-to-install themes are in $BUILD_THEMES/ (intermediates in $ARTIFACTS/)"
}

case "${1:-all}" in
  all)   load_themes; all ;;
  clean) clean ;;
  xpm)   load_themes; step_xpm ;;
  png)   load_themes; step_png ;;
  in)    step_in ;;
  cursors) load_themes; step_cursors ;;
  *) echo "Usage: $0 [all|clean|xpm|png|in|cursors]" >&2; exit 1 ;;
esac
