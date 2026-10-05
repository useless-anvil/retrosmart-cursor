#!/usr/bin/env bash
#
# build.sh — builds the Retrosmart Xcursor themes.
#
# Pipeline (output goes into ./artifacts/png, ./artifacts/in, and ./build_themes):
#
#   schemes.yaml (per-scheme colors + cursor style, master definition:
#                  outline/fill for two-color styles, accent for win-3d)
#   src/<style>/  (32px hand-drawn XPM sources; every style owns its own
#                  full cursor set, EXCEPT src/<style>/brighter/ overrides,
#                  which fall back to src/shared/brighter/ when a style has
#                  no override of its own -- see merged_xpm_list(). A style can also
#                  carry src/<style>/alt/<name>/ folders: each one becomes an extra
#                  theme variant per scheme, with that folder's 32-*.xpm (and its
#                  brighter/32-*.xpm) replacing the same-named cursors of the base set)
#         |  0. load       -> THEMES (in-memory)
#         |  0.5 check     -> warns on stray/near-miss colors in src XPMs
#         |                   (per-style, not per-theme; non-fatal)
#         |  1. png        -> artifacts/png/<theme>/{32,64,128}-*.png
#         |                   (in-memory sed recolor -> ImageMagick upscale & shadow straight to PNG;
#         |                   no intermediate XPM files written to disk)
#         |  2. hotspots   -> artifacts/in/<style>/[<alt-*>/]<cursor>  (from data/hotspots.yaml;
#         |                   alt variants get their own in-dir -- frame counts / hotspots can differ)
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
declare -A THEME_STYLE=()
declare -A THEME_ACCENT=()
declare -A THEME_ACCENT_DARK=()
declare -A THEME_BRIGHT=()     # brighter of outline/fill; brighter/-sourced cursors use it as outline
declare -A THEME_DARK=()       # the other one; brighter/-sourced cursors use it as fill
declare -A THEME_ALT=()        # empty = base theme; else the src/<style>/alt/<name>/ folder layered on top

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

# Resolves the effective set of 32px XPM sources for a style, applying
# brighter/ override precedence:
#   src/<style>/32-<name>.xpm            (highest precedence)
#   src/<style>/brighter/32-<name>.xpm   (style-specific override)
#   src/shared/brighter/32-<name>.xpm    (cross-style fallback override)
# Prints one line per resolved cursor: "<name>\x1f<path>\x1f<is_bright>"
# (is_bright is 1 when the file came from a brighter/ folder, else 0).
#
# With a second argument (an alt name) the alt's files are layered on top:
#   src/<style>/alt/<alt>/32-<n>.xpm            (is_bright 0)
#   src/<style>/alt/<alt>/brighter/32-<n>.xpm   (is_bright 1; not for accent styles)
# An alt replaces whole cursors: if it ships wait01..wait09, every base wait
# frame is dropped first (matching is on the name minus its trailing digits),
# so a shorter or longer frame set can never leave stray base frames behind.
# Without an alt, alt/ is not walked (see discover_alts).
merged_xpm_list() {
  local style="$1" alt="${2:-}" xpm name base
  declare -A resolved=()

  # shared/brighter is outline/fill art; accent styles (win-3d) never use it.
  if ! is_accent_style "$style"; then
    for xpm in "$SRC_BASE/shared/brighter"/32-*.xpm; do
      [ -e "$xpm" ] || continue
      name="$(basename "$xpm" .xpm | sed 's/^32-//')"
      resolved["$name"]="$xpm"$'\x1f'"1"
    done
  fi
  for xpm in "$SRC_BASE/$style/brighter"/32-*.xpm; do
    [ -e "$xpm" ] || continue
    name="$(basename "$xpm" .xpm | sed 's/^32-//')"
    resolved["$name"]="$xpm"$'\x1f'"1"
  done
  for xpm in "$SRC_BASE/$style"/32-*.xpm; do
    [ -e "$xpm" ] || continue
    name="$(basename "$xpm" .xpm | sed 's/^32-//')"
    resolved["$name"]="$xpm"$'\x1f'"0"
  done

  if [ -n "$alt" ]; then
    local alt_dir="$SRC_BASE/$style/alt/$alt"
    declare -A override=()
    declare -A replaced=()
    if ! is_accent_style "$style"; then
      for xpm in "$alt_dir/brighter"/32-*.xpm; do
        [ -e "$xpm" ] || continue
        name="$(basename "$xpm" .xpm | sed 's/^32-//')"
        override["$name"]="$xpm"$'\x1f'"1"
      done
    fi
    for xpm in "$alt_dir"/32-*.xpm; do
      [ -e "$xpm" ] || continue
      name="$(basename "$xpm" .xpm | sed 's/^32-//')"
      override["$name"]="$xpm"$'\x1f'"0"
    done
    for name in "${!override[@]}"; do
      replaced["${name%"${name##*[!0-9]}"}"]=1
    done
    for name in "${!resolved[@]}"; do
      base="${name%"${name##*[!0-9]}"}"
      if [ -n "${replaced[$base]:-}" ]; then
        unset -v 'resolved[$name]'
      fi
    done
    for name in "${!override[@]}"; do
      resolved["$name"]="${override[$name]}"
    done
  fi

  for name in "${!resolved[@]}"; do
    printf '%s\x1f%s\n' "$name" "${resolved[$name]}"
  done
}

# Scans a style's XPM sources for colors outside its allowed placeholder
# palette. Warns (does not fail the build) -- catches stray/near-miss hex
# values that sed's literal recolor substitution will silently skip over.
# Related to tools/preflight.py's check_palette(), but NOT identical: this
# one also walks src/<style>/alt/*/ , preflight currently only globs the
# style root. Fix preflight before claiming they're in sync.
check_style_palette() {
  local style="$1" allowed_re xpm color base
  if is_accent_style "$style"; then
    allowed_re='^(NONE|#000000|#FFFFFF|#C0C0C0|#808080|#FF7F50|#944A2E)$'
  else
    allowed_re='^(NONE|#00FFFF|#FF7F50)$'
  fi
  declare -A seen=()
  local -a xpm_globs=("$SRC_BASE/$style"/32-*.xpm "$SRC_BASE/$style/brighter"/32-*.xpm)
  if ! is_accent_style "$style"; then
    xpm_globs+=("$SRC_BASE/shared/brighter"/32-*.xpm)
  fi
  if [ -d "$SRC_BASE/$style/alt" ]; then
    xpm_globs+=("$SRC_BASE/$style"/alt/*/32-*.xpm "$SRC_BASE/$style"/alt/*/brighter/32-*.xpm)
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

# List alt folder names under src/<style>/alt/* that carry at least one
# 32-*.xpm (directly or under brighter/). Wait animations and single-cursor
# swaps (e.g. mac-ish/alt/straight_hand) are discovered the same way.
discover_alts() {
  local style="$1" d f found
  local alt_root="$SRC_BASE/$style/alt"
  [ -d "$alt_root" ] || return 0
  for d in "$alt_root"/*/; do
    [ -d "$d" ] || continue
    found=0
    for f in "$d"32-*.xpm "$d"brighter/32-*.xpm; do
      [ -e "$f" ] || continue
      found=1
      break
    done
    if [ "$found" -eq 1 ]; then
      basename "${d%/}"
    fi
  done
}

# artifacts/in path for a (style, alt) pair.
in_dir_for() {
  local style="$1" alt="${2:-}"
  if [ -n "$alt" ]; then
    printf '%s\n' "$ARTIFACTS/in/$style/alt-$alt"
  else
    printf '%s\n' "$ARTIFACTS/in/$style"
  fi
}

SHADOW_COLOR="#000000"

build_theme_list() {
  THEMES=()
  THEME_NAME=()
  THEME_STYLE=()
  THEME_ACCENT=()
  THEME_ACCENT_DARK=()
  THEME_BRIGHT=()
  THEME_DARK=()
  THEME_ALT=()
  STYLES=()
  declare -A seen_styles=()
  local id outline fill bright dark name style accent accent_dark base shadow_theme
  local altname alt_label alt_name alt_base alt_shadow

  _register_theme_pair() {
    local base="$1" outline="$2" fill="$3" bright="$4" dark="$5" name="$6" style="$7" accent="$8" accent_dark="$9" alt="${10}"
    local shadow_theme="${base}-shadow"
    THEMES+=("$base:$outline:$fill:0")
    THEME_NAME["$base"]="Retrosmart $name"
    THEME_STYLE["$base"]="$style"
    THEME_ACCENT["$base"]="$accent"
    THEME_ACCENT_DARK["$base"]="$accent_dark"
    THEME_BRIGHT["$base"]="$bright"
    THEME_DARK["$base"]="$dark"
    THEME_ALT["$base"]="$alt"

    THEMES+=("$shadow_theme:$outline:$fill:1")
    THEME_NAME["$shadow_theme"]="Retrosmart $(_shadow_name "$name")"
    THEME_STYLE["$shadow_theme"]="$style"
    THEME_ACCENT["$shadow_theme"]="$accent"
    THEME_ACCENT_DARK["$shadow_theme"]="$accent_dark"
    THEME_BRIGHT["$shadow_theme"]="$bright"
    THEME_DARK["$shadow_theme"]="$dark"
    THEME_ALT["$shadow_theme"]="$alt"
  }

  # NOTE: don't use `IFS=$'\t' read` directly here. Bash counts tab as IFS
  # whitespace, so runs of tabs collapse into one delimiter and interior
  # empty columns (e.g. outline/fill on win-3d schemes) silently shift every
  # later field left. Swap tabs for a non-whitespace separator first, which
  # preserves empty fields.
  local line
  while IFS= read -r line; do
    IFS=$'\x1f' read -r id outline fill bright dark name style accent accent_dark <<<"${line//$'\t'/$'\x1f'}"
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
    _register_theme_pair "$base" "$outline" "$fill" "$bright" "$dark" "$name" "$style" "$accent" "$accent_dark" ""

    # Auto-discover alt variants (src/<style>/alt/<altname>/32-*.xpm).
    while IFS= read -r altname; do
      [ -z "$altname" ] && continue
      alt_label="$(_titlecase_alt "$altname")"
      alt_name="$(_with_alt_label "$name" "$alt_label")"
      alt_base="retrosmart-xcursor-${id}-${altname}"
      _register_theme_pair "$alt_base" "$outline" "$fill" "$bright" "$dark" "$alt_name" "$style" "$accent" "$accent_dark" "$altname"
    done < <(discover_alts "$style" | sort)
  done < <(python3 "$READ_COLOR_SCHEMES" "$COLOR_SCHEMES")

  if [ "${#THEMES[@]}" -eq 0 ]; then
    echo "error: no usable color schemes found under $COLOR_SCHEMES" >&2
    exit 1
  fi
}

hotspots_tsv() {
  local style="${1:-}" alt="${2:-}"
  local -a args=()
  [ -n "$style" ] && args+=("$style")
  [ -n "$style" ] && [ -n "$alt" ] && args+=("$alt")
  python3 "$READ_HOTSPOTS" "$HOTSPOTS" ${args[@]+"${args[@]}"}
}

cursor_names() {
  hotspots_tsv | cut -f1
}

frames_for() {
  local name="$1" style="$2" alt="${3:-}"
  declare -a frames=()
  # Any source cursor with a numeric suffix is a frame sequence. The delay
  # in hotspots.yaml decides whether that sequence is emitted as animated;
  # this keeps frame discovery in sync for Xcursor and future animated roles.
  # Frame sources may live at the style's top level, come from a brighter/
  # override (e.g. mac-ish's wait01-08) or from an alt/<name>/ folder (e.g.
  # win-3d's hourglass) -- merged_xpm_list resolves all of that, so an alt
  # theme sees exactly the frame set it will rasterize.
  local rname rpath rbright
  while IFS=$'\x1f' read -r rname rpath rbright; do
    [[ "$rname" =~ ^${name}[0-9]+$ ]] || continue
    frames+=("$rname")
  done < <(merged_xpm_list "$style" "$alt")
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
  local theme outline fill has_shadow style pdir xpm name alt
  local -a recolor_args
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  alt="${THEME_ALT[$theme]:-}"
  pdir="$ARTIFACTS/png/$theme"
  mkdir -p "$pdir"

  local -a bright_recolor_args=()
  if is_accent_style "$style"; then
    # Fixed-chrome styles: bevel colors are literal in the source, only the
    # accent placeholder pair gets swapped.
    recolor_args=(-e "s/#FF7F50/${THEME_ACCENT[$theme]}/gI" -e "s/#944A2E/${THEME_ACCENT_DARK[$theme]}/gI")
  else
    recolor_args=(-e "s/#00FFFF/$outline/gI" -e "s/#FF7F50/$fill/gI")
    # Cursors sourced from a brighter/ override always use the scheme's
    # brighter color as outline and the darker one as fill, whatever the
    # scheme's own orientation (cur-font pointing hand: white outline /
    # black fill in classic AND white).
    bright_recolor_args=(-e "s/#00FFFF/${THEME_BRIGHT[$theme]}/gI" -e "s/#FF7F50/${THEME_DARK[$theme]}/gI")
  fi

  local rname rpath rbright
  while IFS=$'\x1f' read -r rname rpath rbright; do
    [ -z "$rname" ] && continue

    if [ "$rbright" = 1 ] && [ "${#bright_recolor_args[@]}" -gt 0 ]; then
      _rasterize_xpm_to_png "$rpath" "$rname" "$pdir" "$has_shadow" "${bright_recolor_args[@]}"
    else
      _rasterize_xpm_to_png "$rpath" "$rname" "$pdir" "$has_shadow" "${recolor_args[@]}"
    fi
  done < <(merged_xpm_list "$style" "$alt")
}

step_png() {
  log "png  : recoloring & rasterizing straight to PNG (${#THEMES[@]} themes, parallel $NPROC jobs)"
  run_parallel_theme_task process_theme_png
}

step_in() {
  # .in configs are keyed by (style, alt) because alt variants can differ in
  # frame count (default 6, hand_stopwatch 9, hourglass 15) and in hotspot
  # (hotspots.yaml's "<style>/<alt>" keys, e.g. mac-ish/straight_hand).
  declare -A generated=()
  local entry theme style alt key indir
  for entry in "${THEMES[@]}"; do
    IFS=: read -r theme _ _ _ <<<"$entry"
    style="${THEME_STYLE[$theme]}"
    alt="${THEME_ALT[$theme]:-}"
    key="${style}|${alt}"
    [ -n "${generated[$key]:-}" ] && continue
    generated[$key]=1

    indir="$(in_dir_for "$style" "$alt")"
    mkdir -p "$indir"
    if [ -n "$alt" ]; then
      log "in   : generating for style=$style alt=$alt from data/hotspots.yaml"
    else
      log "in   : generating for style=$style from data/hotspots.yaml"
    fi
    while IFS=$'\t' read -r name x y delay; do
      [ -z "$name" ] && continue
      local out="$indir/$name"
      : > "$out"
      for frame in $(frames_for "$name" "$style" "$alt"); do
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
    done < <(hotspots_tsv "$style" "$alt")
  done
}

process_theme_cursors() {
  local entry="$1"
  local theme outline fill has_shadow style cdir name link target alt indir
  IFS=: read -r theme outline fill has_shadow <<<"$entry"
  style="${THEME_STYLE[$theme]}"
  alt="${THEME_ALT[$theme]:-}"
  indir="$(in_dir_for "$style" "$alt")"
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
