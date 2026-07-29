#!/usr/bin/env bash
#
# build.sh — builds the Retrosmart Xcursor themes.
#
# Pipeline (output goes into ./artifacts/png, ./artifacts/in, and ./build_themes):
#
#   schemes.yaml (outline/fill hex colors + cursor style, master definition)
#   src/base/<style>/ + src/base/shared/  (32px hand-drawn XPM sources)
#         |  0. load       -> THEMES (in-memory)
#         |  1. png        -> artifacts/png/<theme>/{32,64,128}-*.png
#         |                   (in-memory sed recolor -> ImageMagick upscale & shadow straight to PNG;
#         |                   no intermediate XPM files written to disk)
#         |  2. hotspots   -> artifacts/in/<style>/<cursor>     (from data/hotspots.yaml)
#         |  3. xcursorgen -> build_themes/Linux/<theme>/cursors/<cursor> (real binary cursor)
#         |  4. aliases    -> build_themes/Linux/<theme>/cursors/<alias>  (symlinks, from data/links.txt)
#         -  5. theme meta -> build_themes/Linux/<theme>/index.theme (src/themes/*.theme, or auto-generated)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ARTIFACTS="$ROOT/artifacts"
BUILD_THEMES="$ROOT/build_themes"
SRC_BASE="$ROOT/src/base"
SRC_SHARED="$SRC_BASE/shared"
SRC_THEMES="$ROOT/src/themes"
HOTSPOTS="$ROOT/data/hotspots.yaml"
READ_HOTSPOTS="$ROOT/data/read_hotspots.py"
LINKS="$ROOT/data/links.txt"
COLOR_SCHEMES="$ROOT/schemes.yaml"
READ_COLOR_SCHEMES="$ROOT/data/read_color_schemes.py"
WINDOWS_BUILDER="$ROOT/scripts/build_windows.py"

UPSCALE_FILTER="point"
SIZES=(32 64 128)
NPROC="$(nproc 2>/dev/null || echo 4)"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

declare -a STYLES=()
declare -a THEMES=()
declare -A THEME_NAME=()
declare -A THEME_NAME_ES=()
declare -A THEME_STYLE=()

_shadow_name() {
  local name="$1"
  if [[ "$name" =~ ^(.*)(\ \([^()]*\))$ ]]; then
    printf '%s Shadow%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s Shadow\n' "$name"
  fi
}

SHADOW_COLOR="#000000"

build_theme_list() {
  THEMES=()
  THEME_NAME=()
  THEME_NAME_ES=()
  THEME_STYLE=()
  STYLES=()
  declare -A seen_styles=()
  local id outline fill name name_es style base shadow_theme
  while IFS=$'\t' read -r id outline fill name name_es style; do
    [ -z "$id" ] && continue

    if [ ! -d "$SRC_BASE/$style" ]; then
      echo "error: color scheme '$id' points 'cursors: $style' at a folder that doesn't exist ($SRC_BASE/$style)" >&2
      exit 1
    fi
    if [ -z "${seen_styles[$style]:-}" ]; then
      seen_styles[$style]=1
      STYLES+=("$style")
    fi

    base="retrosmart-xcursor-$id"
    THEMES+=("$base:$outline:$fill:0")
    THEME_NAME["$base"]="Retrosmart $name"
    THEME_NAME_ES["$base"]="Retrosmart $name_es"
    THEME_STYLE["$base"]="$style"

    shadow_theme="${base}-shadow"
    THEMES+=("$shadow_theme:$outline:$fill:1")
    THEME_NAME["$shadow_theme"]="Retrosmart $(_shadow_name "$name")"
    THEME_NAME_ES["$shadow_theme"]="Retrosmart $(_shadow_name "$name_es")"
    THEME_STYLE["$shadow_theme"]="$style"
  done < <(python3 "$READ_COLOR_SCHEMES" "$COLOR_SCHEMES")

  if [ "${#THEMES[@]}" -eq 0 ]; then
    echo "error: no usable color schemes found under $COLOR_SCHEMES" >&2
    exit 1
  fi
}

hotspots_tsv() {
  local style="${1:-}"
  python3 "$READ_HOTSPOTS" "$HOTSPOTS" ${style:+"$style"}
}

cursor_names() {
  hotspots_tsv | cut -f1
}

frames_for() {
  local name="$1" style="$2"
  case "$name" in
    progress|wait)
      local f base
      declare -A seen=()
      for f in "$SRC_BASE/$style"/32-"$name"*.xpm "$SRC_SHARED"/32-"$name"*.xpm; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .xpm | sed 's/^32-//')"
        [ -n "${seen[$base]:-}" ] && continue
        seen[$base]=1
        echo "$base"
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

run_parallel_theme_task() {
  local task_fn="$1"
  local count=0
  for entry in "${THEMES[@]}"; do
    "$task_fn" "$entry" &
    count=$((count + 1))
    if [ "$count" -ge "$NPROC" ]; then
      wait -n 2>/dev/null || wait
      count=$((count - 1))
    fi
  done
  wait
}

process_theme_png() {
  local entry="$1"
  local theme outline fill has_shadow style pdir xpm base name
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  pdir="$ARTIFACTS/png/$theme"
  mkdir -p "$pdir"

  declare -A seen=()
  for xpm in "$SRC_BASE/$style"/32-*.xpm "$SRC_SHARED"/32-*.xpm; do
    [ -e "$xpm" ] || continue
    base="$(basename "$xpm")"
    [ -n "${seen[$base]:-}" ] && continue
    seen[$base]=1
    name="$(basename "$xpm" .xpm | sed 's/^32-//')"

    if [ "$has_shadow" = 1 ]; then
      # Direct stream: sed in-memory recolor -> ImageMagick convert (32px, 64px, 128px + shadow) straight to PNG
      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/32-$name.png"

      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- -filter "$UPSCALE_FILTER" -scale 200% \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/64-$name.png"

      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- -filter "$UPSCALE_FILTER" -scale 400% \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/128-$name.png"
    else
      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- "$pdir/32-$name.png"

      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- -filter "$UPSCALE_FILTER" -scale 200% "$pdir/64-$name.png"

      sed -e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI" "$xpm" | \
        convert xpm:- -filter "$UPSCALE_FILTER" -scale 400% "$pdir/128-$name.png"
    fi
  done
}

step_png() {
  log "png  : recoloring & rasterizing straight to PNG (${#THEMES[@]} themes, parallel $NPROC jobs)"
  run_parallel_theme_task process_theme_png
}

step_in() {
  local style indir
  for style in "${STYLES[@]}"; do
    indir="$ARTIFACTS/in/$style"
    mkdir -p "$indir"
    log "in   : generating for style=$style from data/hotspots.yaml"
    while IFS=$'\t' read -r name size x y _filename delay; do
      [ -z "$name" ] && continue
      local out="$indir/$name"
      : > "$out"
      for frame in $(frames_for "$name" "$style"); do
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
    done < <(hotspots_tsv "$style")
  done
}

process_theme_cursors() {
  local entry="$1"
  local theme outline fill has_shadow style cdir name link target theme_file
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  cdir="$BUILD_THEMES/Linux/$theme/cursors"
  mkdir -p "$cdir"

  while read -r name; do
    [ -z "$name" ] && continue
    xcursorgen -p "$ARTIFACTS/png/$theme" "$ARTIFACTS/in/$style/$name" "$cdir/$name"
  done < <(cursor_names)

  while IFS=: read -r link target; do
    [ -z "$link" ] && continue
    [[ "$link" == \#* ]] && continue
    ln -sf "$target" "$cdir/$link"
  done < "$LINKS"

  theme_file="$SRC_THEMES/$theme.theme"
  if [ -f "$theme_file" ]; then
    cp "$theme_file" "$BUILD_THEMES/Linux/$theme/index.theme"
  else
    cat > "$BUILD_THEMES/Linux/$theme/index.theme" <<EOF
[Icon Theme]
Name=${THEME_NAME[$theme]}
Name[es]=${THEME_NAME_ES[$theme]}
Comment=Retrosmart cursor theme
Comment[es]=Tema de cursores Retrosmart
EOF
  fi
  cp "$ARTIFACTS/png/$theme/128-default.png" "$cdir/thumbnail.png"
}

step_cursors() {
  log "build: generating binary cursors (${#THEMES[@]} themes, parallel $NPROC jobs)"
  run_parallel_theme_task process_theme_cursors
}

step_windows() {
  log "win  : generating Windows cursor themes"
  python3 "$WINDOWS_BUILDER"
}

all() {
  build_theme_list
  step_png
  step_in
  step_cursors
  step_windows
  log "Done. Ready-to-install themes are in $BUILD_THEMES/ (intermediates in $ARTIFACTS/)"
}

case "${1:-all}" in
  all)   all ;;
  clean) clean ;;
  png)   build_theme_list; step_png ;;
  in)    build_theme_list; step_in ;;
  cursors) build_theme_list; step_cursors ;;
  windows) python3 "$WINDOWS_BUILDER" ;;
  *) echo "Usage: $0 [all|clean|png|in|cursors|windows]" >&2; exit 1 ;;
esac
