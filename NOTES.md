# Notes

## On the fork

This started as a personal tweak of
[mdomlop/retrosmart-x11-cursors](https://github.com/mdomlop/retrosmart-x11-cursors)
and evolved into a comprehensive port and rebuild of the packaging/build pipeline:
- Added HiDPI cursor sizes (32px, 64px, 128px).
- Expanded styles to include both Mac-ish and Win-ish cursor designs.
- Consolidated color scheme management into a single master `schemes.yaml` file with clear `outline` and `fill` definitions.
- Automated preview generation for all variants and Pling store listings.

The core cursor designs honor Manuel Domínguez López's original artwork while adapting them for multi-style, multi-platform releases.

## On AI assistance

Build scripts, automation tools, and documentation were refined with AI assistance. The cursor artwork in `src/base/` remains hand-drawn pixel art.

## On the wording in the README

"Touch-ups" and "refinements," not "fixes." Any edits happened while adapting the cursors to new sizes, hotspot coordinates, and multi-style variations.
