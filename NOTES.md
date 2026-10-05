# Notes

## On the fork

This started as a personal tweak of
[mdomlop/retrosmart-x11-cursors](https://github.com/mdomlop/retrosmart-x11-cursors)
and evolved into a comprehensive port and rebuild of the packaging/build pipeline:
- Added HiDPI cursor sizes: the hand-drawn source art is 32px, upscaled
  nearest-neighbor to 64px and 128px at build time.
- Expanded styles to four: Mac-ish, Win-ish, Cur-font and Win-3D. Each style
  owns a full cursor set under `src/<style>/`.
- Consolidated color scheme management into a single master `schemes.yaml`.
  Most styles define `outline` and `fill`; Win-3D keeps its Win95/98 chrome
  fixed and defines a single `accent` instead (the darker shadow tone is
  derived automatically).
- Added a Windows target: the same sources build `.cur`/`.ani` files with an
  `install.inf`, alongside the X11 themes.

The core cursor designs honor mdomlop's original artwork while adapting them for multi-style, multi-platform releases.
