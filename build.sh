#!/usr/bin/env bash
#
# build.sh — builds the Retrosmart Xcursor themes.
#
# Pipeline (output goes into ./artifacts/png, ./artifacts/in, and ./build_themes):
#
#   schemes.yaml (outline/fill hex colors + cursor style, master definition)
#   src/<style>/  (32px hand-drawn XPM sources, one full set per style --
#                  no shared/ folder; every style owns every cursor)
#         |  0. load       -> THEMES (in-memory)
#         |  0.5 check     -> warns on stray/near-miss colors in src XPMs
#         |                   (per-style, not per-theme; non-fatal)
#         |  1. png        -> artifacts/png/<theme>/{32,64,128}-*.png
#         |                   (in-memory sed recolor -> ImageMagick upscale & shadow straight to PNG;
#         |                   no intermediate XPM files written to disk)
#         |  2. hotspots   -> artifacts/in/<style>/[<alt-*>/]<cursor>  (from data/hotspots.yaml;
#         |                   wait-alt variants get their own in-dir -- frame counts differ)
#         |  3. xcursorgen -> build_themes/Linux/<style>/<theme>/cursors/<cursor> (real binary cursor)
#         |  4. aliases    -> build_themes/Linux/<style>/<theme>/cursors/<alias>  (symlinks, from data/links.txt)
#         -  5. theme meta -> build_themes/Linux/<style>/<theme>/index.theme (auto-generated)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ARTIFACTS="$ROOT/artifacts"
BUILD_THEMES="$ROOT/build_themes"
SRC_BASE="$ROOT/src"
HOTSPOTS="$ROOT/data/hotspots.yaml"
READ_HOTSPOTS="$ROOT/data/read_hotspots.py"
LINKS="$ROOT/data/links.txt"
COLOR_SCHEMES="$ROOT/schemes.yaml"
READ_COLOR_SCHEMES="$ROOT/data/read_color_schemes.py"
WINDOWS_BUILDER="$ROOT/scripts/build_windows.py"

UPSCALE_FILTER="point"
SIZES=(32 64 128)
NPROC="$(nproc 2>/dev/null || echo 4)"

# px size of the hand-drawn source art data/hotspots.yaml's x/y values are
# relative to (must match SOURCE_SIZE in data/hotspots_lib.py).
HOTSPOT_SOURCE_SIZE=32

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

declare -a STYLES=()
declare -a THEMES=()
declare -A THEME_NAME=()
declare -A THEME_NAME_ES=()
declare -A THEME_STYLE=()
declare -A THEME_ACCENT=()
declare -A THEME_ACCENT_DARK=()
declare -A THEME_WAIT_ALT=()   # empty = default top-level wait frames; else alt/<name>/

# Styles that use the fixed-chrome + single-accent recolor scheme instead of
# the standard outline/fill swap. Their src/<style>/*.xpm files keep the 3D
# bevel colors (#000000/#FFFFFF/#C0C0C0/#808080) literal and only use the
# accent placeholder pair (#FF7F50 light / #944A2E dark) for the schemeable part.
ACCENT_STYLES=("win-3d")

is_accent_style() {
  local style="$1" s
  for s in "${ACCENT_STYLES[@]}"; do
    [ "$s" = "$style" ] && return 0
  done
  return 1
}

# Scans a style's XPM sources for colors outside its allowed placeholder
# palette. Warns (does not fail the build) -- catches stray/near-miss hex
# values that sed's literal recolor substitution will silently skip over.
# Mirrors tools/preflight.py's check_palette(); keep the two in sync.
check_style_palette() {
  local style="$1" allowed_re xpm color base
  if is_accent_style "$style"; then
    allowed_re='^(NONE|#000000|#FFFFFF|#C0C0C0|#808080|#FF7F50|#944A2E)$'
  else
    allowed_re='^(NONE|#00FFFF|#FF7F50)$'
  fi
  declare -A seen=()
  local -a xpm_globs=("$SRC_BASE/$style"/32-*.xpm)
  if [ -d "$SRC_BASE/$style/alt" ]; then
    xpm_globs+=("$SRC_BASE/$style"/alt/*/32-*.xpm)
  fi
  for xpm in "${xpm_globs[@]}"; do
    [ -e "$xpm" ] || continue
    # Dedup by relative path so top-level and alt wait frames are both checked.
    base="${xpm#"$SRC_BASE/$style/"}"
    [ -n "${seen[$base]:-}" ] && continue
    seen[$base]=1
    while read -r color; do
      [ -z "$color" ] && continue
      if ! [[ "${color^^}" =~ $allowed_re ]]; then
        echo "warn: $xpm uses unrecognized color '$color' for style '$style' -- sed recolor will leave it untouched" >&2
      fi
    done < <(grep -oE 'c[[:space:]]+(#[0-9A-Fa-f]{6}|None)' "$xpm" | awk '{print $2}' | sort -u)
  done
}

step_check_palette() {
  log "check: scanning XPM sources for unrecognized colors (${#STYLES[@]} styles)"
  local style
  for style in "${STYLES[@]}"; do
    check_style_palette "$style"
  done
}

_shadow_name() {
  local name="$1"
  if [[ "$name" =~ ^(.*)(\ \([^()]*\))$ ]]; then
    printf '%s Shadow%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s Shadow\n' "$name"
  fi
}

# Title-case an alt folder name: hand_stopwatch -> Hand Stopwatch
_titlecase_alt() {
  local s="${1//_/ }" w out=""
  for w in $s; do
    out+="${out:+ }${w^}"
  done
  printf '%s\n' "$out"
}

# Insert alt label before a trailing "(Style)" suffix:
#   BLUE (Win-3D) + Hourglass -> BLUE Hourglass (Win-3D)
_with_alt_label() {
  local name="$1" alt_label="$2"
  if [[ "$name" =~ ^(.*)(\ \([^()]*\))$ ]]; then
    printf '%s %s%s\n' "${BASH_REMATCH[1]}" "$alt_label" "${BASH_REMATCH[2]}"
  else
    printf '%s %s\n' "$name" "$alt_label"
  fi
}

# List wait-alt folder names under src/<style>/alt/* that contain 32-wait*.xpm.
discover_wait_alts() {
  local style="$1" d
  local alt_root="$SRC_BASE/$style/alt"
  [ -d "$alt_root" ] || return 0
  for d in "$alt_root"/*/; do
    [ -d "$d" ] || continue
    local has_wait=0
    for f in "$d"32-wait*.xpm; do
      [ -e "$f" ] || break
      has_wait=1
      break
    done
    [ "$has_wait" -eq 1 ] || continue
    basename "${d%/}"
  done
}

# artifacts/in path for a (style, wait_alt) pair.
in_dir_for() {
  local style="$1" wait_alt="${2:-}"
  if [ -n "$wait_alt" ]; then
    printf '%s\n' "$ARTIFACTS/in/$style/alt-$wait_alt"
  else
    printf '%s\n' "$ARTIFACTS/in/$style"
  fi
}

SHADOW_COLOR="#000000"

build_theme_list() {
  THEMES=()
  THEME_NAME=()
  THEME_NAME_ES=()
  THEME_STYLE=()
  THEME_ACCENT=()
  THEME_ACCENT_DARK=()
  THEME_WAIT_ALT=()
  STYLES=()
  declare -A seen_styles=()
  local id outline fill name name_es style accent accent_dark base shadow_theme
  local altname alt_label alt_name alt_name_es alt_base alt_shadow

  _register_theme_pair() {
    local base="$1" outline="$2" fill="$3" name="$4" name_es="$5" style="$6" accent="$7" accent_dark="$8" wait_alt="$9"
    local shadow_theme="${base}-shadow"
    THEMES+=("$base:$outline:$fill:0")
    THEME_NAME["$base"]="Retrosmart $name"
    THEME_NAME_ES["$base"]="Retrosmart $name_es"
    THEME_STYLE["$base"]="$style"
    THEME_ACCENT["$base"]="$accent"
    THEME_ACCENT_DARK["$base"]="$accent_dark"
    THEME_WAIT_ALT["$base"]="$wait_alt"

    THEMES+=("$shadow_theme:$outline:$fill:1")
    THEME_NAME["$shadow_theme"]="Retrosmart $(_shadow_name "$name")"
    THEME_NAME_ES["$shadow_theme"]="Retrosmart $(_shadow_name "$name_es")"
    THEME_STYLE["$shadow_theme"]="$style"
    THEME_ACCENT["$shadow_theme"]="$accent"
    THEME_ACCENT_DARK["$shadow_theme"]="$accent_dark"
    THEME_WAIT_ALT["$shadow_theme"]="$wait_alt"
  }

  while IFS=$'\t' read -r id outline fill name name_es style accent accent_dark; do
    [ -z "$id" ] && continue

    if [ ! -d "$SRC_BASE/$style" ]; then
      echo "error: color scheme '$id' points 'cursors: $style' at a folder that doesn't exist ($SRC_BASE/$style)" >&2
      exit 1
    fi
    if is_accent_style "$style" && [ -z "$accent" ]; then
      echo "error: color scheme '$id' uses accent style '$style' but has no 'accent' field" >&2
      exit 1
    fi
    if [ -z "${seen_styles[$style]:-}" ]; then
      seen_styles[$style]=1
      STYLES+=("$style")
    fi

    base="retrosmart-xcursor-$id"
    _register_theme_pair "$base" "$outline" "$fill" "$name" "$name_es" "$style" "$accent" "$accent_dark" ""

    # Auto-discover wait-alt variants (src/<style>/alt/<altname>/32-wait*.xpm).
    while IFS= read -r altname; do
      [ -z "$altname" ] && continue
      alt_label="$(_titlecase_alt "$altname")"
      alt_name="$(_with_alt_label "$name" "$alt_label")"
      alt_name_es="$(_with_alt_label "$name_es" "$alt_label")"
      alt_base="retrosmart-xcursor-${id}-${altname}"
      _register_theme_pair "$alt_base" "$outline" "$fill" "$alt_name" "$alt_name_es" "$style" "$accent" "$accent_dark" "$altname"
    done < <(discover_wait_alts "$style" | sort)
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
  local name="$1" style="$2" wait_alt="${3:-}"
  local f base
  declare -a frames=()
  # Any source cursor with a numeric suffix is a frame sequence. The delay
  # in hotspots.yaml decides whether that sequence is emitted as animated;
  # this keeps frame discovery in sync for Xcursor and future animated roles.
  # Wait-alt themes pull wait frames from src/<style>/alt/<altname>/ only.
  if [ "$name" = "wait" ] && [ -n "$wait_alt" ]; then
    for f in "$SRC_BASE/$style/alt/$wait_alt"/32-wait[0-9]*.xpm; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .xpm | sed 's/^32-//')"
      frames+=("$base")
    done
  else
    for f in "$SRC_BASE/$style"/32-"$name"[0-9]*.xpm; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .xpm | sed 's/^32-//')"
      frames+=("$base")
    done
  fi
  if [ "${#frames[@]}" -gt 0 ]; then
    printf '%s\n' "${frames[@]}" | sort -V
  else
    echo "$name"
  fi
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

_rasterize_xpm_to_png() {
  local xpm="$1" name="$2" pdir="$3" has_shadow="$4"
  shift 4
  local -a recolor_args=("$@")

  if [ "$has_shadow" = 1 ]; then
    # Direct stream: sed in-memory recolor -> ImageMagick convert (32px, 64px, 128px + shadow) straight to PNG
    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/32-$name.png"

    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- -filter "$UPSCALE_FILTER" -scale 200% \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/64-$name.png"

    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- -filter "$UPSCALE_FILTER" -scale 400% \( +clone -background "$SHADOW_COLOR" -shadow 60x2+5+5 \) +swap -background none -layers merge +repage "$pdir/128-$name.png"
  else
    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- "$pdir/32-$name.png"

    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- -filter "$UPSCALE_FILTER" -scale 200% "$pdir/64-$name.png"

    sed "${recolor_args[@]}" "$xpm" | \
      convert xpm:- -filter "$UPSCALE_FILTER" -scale 400% "$pdir/128-$name.png"
  fi
}

process_theme_png() {
  local entry="$1"
  local theme outline fill has_shadow style pdir xpm base name wait_alt
  local -a recolor_args
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  wait_alt="${THEME_WAIT_ALT[$theme]:-}"
  pdir="$ARTIFACTS/png/$theme"
  mkdir -p "$pdir"

  if is_accent_style "$style"; then
    # Fixed-chrome styles: bevel colors are literal in the source, only the
    # accent placeholder pair gets swapped.
    recolor_args=(-e "s/#FF7F50/${THEME_ACCENT[$theme]}/gI" -e "s/#944A2E/${THEME_ACCENT_DARK[$theme]}/gI")
  else
    recolor_args=(-e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI")
  fi

  declare -A seen=()
  for xpm in "$SRC_BASE/$style"/32-*.xpm; do
    [ -e "$xpm" ] || continue
    base="$(basename "$xpm")"
    [ -n "${seen[$base]:-}" ] && continue
    seen[$base]=1
    name="$(basename "$xpm" .xpm | sed 's/^32-//')"

    # Wait-alt themes skip top-level wait frames; those come from alt/<name>/.
    if [ -n "$wait_alt" ] && [[ "$name" =~ ^wait[0-9] ]]; then
      continue
    fi

    _rasterize_xpm_to_png "$xpm" "$name" "$pdir" "$has_shadow" "${recolor_args[@]}"
  done

  if [ -n "$wait_alt" ]; then
    for xpm in "$SRC_BASE/$style/alt/$wait_alt"/32-wait[0-9]*.xpm; do
      [ -e "$xpm" ] || continue
      name="$(basename "$xpm" .xpm | sed 's/^32-//')"
      # Still write 32-waitNN.png (normal names) into this theme's png dir.
      _rasterize_xpm_to_png "$xpm" "$name" "$pdir" "$has_shadow" "${recolor_args[@]}"
    done
  fi
}

step_png() {
  log "png  : recoloring & rasterizing straight to PNG (${#THEMES[@]} themes, parallel $NPROC jobs)"
  run_parallel_theme_task process_theme_png
}

step_in() {
  # .in configs are keyed by (style, wait_alt) because wait-alt variants can
  # have different frame counts (default 6, hand_stopwatch 9, hourglass 15).
  declare -A generated=()
  local entry theme style wait_alt key indir
  for entry in "${THEMES[@]}"; do
    IFS=: read -r theme _ _ _ <<<"$entry"
    style="${THEME_STYLE[$theme]}"
    wait_alt="${THEME_WAIT_ALT[$theme]:-}"
    key="${style}|${wait_alt}"
    [ -n "${generated[$key]:-}" ] && continue
    generated[$key]=1

    indir="$(in_dir_for "$style" "$wait_alt")"
    mkdir -p "$indir"
    if [ -n "$wait_alt" ]; then
      log "in   : generating for style=$style wait_alt=$wait_alt from data/hotspots.yaml"
    else
      log "in   : generating for style=$style from data/hotspots.yaml"
    fi
    while IFS=$'\t' read -r name x y delay; do
      [ -z "$name" ] && continue
      local out="$indir/$name"
      : > "$out"
      for frame in $(frames_for "$name" "$style" "$wait_alt"); do
        for s in "${SIZES[@]}"; do
          local sx=$((x * s / HOTSPOT_SOURCE_SIZE))
          local sy=$((y * s / HOTSPOT_SOURCE_SIZE))
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
  local theme outline fill has_shadow style cdir name link target wait_alt indir
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  wait_alt="${THEME_WAIT_ALT[$theme]:-}"
  indir="$(in_dir_for "$style" "$wait_alt")"
  cdir="$BUILD_THEMES/Linux/$style/$theme/cursors"
  mkdir -p "$cdir"

  while read -r name; do
    [ -z "$name" ] && continue
    xcursorgen -p "$ARTIFACTS/png/$theme" "$indir/$name" "$cdir/$name"
  done < <(cursor_names)

  while IFS=: read -r link target; do
    [ -z "$link" ] && continue
    [[ "$link" == \#* ]] && continue
    ln -sf "$target" "$cdir/$link"
  done < "$LINKS"

  cat > "$BUILD_THEMES/Linux/$style/$theme/index.theme" <<EOF
[Icon Theme]
Name=${THEME_NAME[$theme]}
Name[es]=${THEME_NAME_ES[$theme]}
Comment=Retrosmart cursor theme
Comment[es]=Tema de cursores Retrosmart
EOF
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
  step_check_palette
  step_png
  step_in
  step_cursors
  step_windows
  log "Done. Ready-to-install themes are in $BUILD_THEMES/ (intermediates in $ARTIFACTS/)"
}

case "${1:-all}" in
  all)   all ;;
  clean) clean ;;
  check) build_theme_list; step_check_palette ;;
  png)   build_theme_list; step_png ;;
  in)    build_theme_list; step_in ;;
  cursors) build_theme_list; step_cursors ;;
  windows) python3 "$WINDOWS_BUILDER" ;;
  *) echo "Usage: $0 [all|clean|check|png|in|cursors|windows]" >&2; exit 1 ;;
esac
