#!/usr/bin/env python3
"""
curtools.py -- tiny, dependency-light (Pillow only) helpers for building
real Windows .cur / .ani cursor files out of the same PNGs the Xcursor
pipeline already produces (artifacts/png/<theme>/{32,64,128}-<name>.png).

Windows .cur is byte-for-byte identical to .ico except:
  - the ICONDIR "type" field is 2 (cur) instead of 1 (ico)
  - each ICONDIRENTRY's "planes"/"bitcount" uint16 pair is repurposed as
    the hotspot (xHotspot, yHotspot) in pixels, instead of colour info.

Pillow can happily *write* multi-resolution .ico files (it just can't
write .cur directly), so the approach here is: build a normal ICO with
Pillow, then patch those 6 bytes in-place per entry. Cheap and reliable.

.ani is a RIFF container: 'anih' header chunk + optional 'rate' chunk
(per-frame duration, in 1/60s "jiffies") + a 'LIST'/'fram' list of raw
'icon' chunks, each one a full in-memory .cur file. Built by hand below
since Pillow has no support for it at all.
"""

from __future__ import annotations
import io
import struct
from typing import Sequence
from PIL import Image

# ---------------------------------------------------------------------------
# .cur (single or multi-resolution)
# ---------------------------------------------------------------------------

def build_cur(images_and_hotspots: Sequence[tuple[Image.Image, int, int]]) -> bytes:
    """
    images_and_hotspots: list of (PIL Image, hotspot_x, hotspot_y), one per
    resolution, all for the *same* cursor (e.g. the 32/64/128px renders).
    Returns the raw bytes of a valid multi-res .cur file.
    """
    # Pillow's ICO writer is picky: to get exactly (and only) our own
    # resolutions in the output -- no auto-generated 16/24/48px thumbnails,
    # no silent collapsing to a single frame -- the base image must be the
    # LARGEST one, append_images must follow in descending size order, and
    # "sizes" must be passed explicitly in that same descending order.
    ordered = sorted(images_and_hotspots, key=lambda t: t[0].size[0], reverse=True)
    imgs = [im.convert("RGBA") for im, _, _ in ordered]
    base, *rest = imgs
    sizes = [im.size for im in imgs]

    buf = io.BytesIO()
    base.save(buf, format="ICO", sizes=sizes, append_images=rest)
    data = bytearray(buf.getvalue())

    # ICONDIR header: reserved(2) type(2) count(2)
    reserved, ico_type, count = struct.unpack_from("<HHH", data, 0)
    assert ico_type == 1, "expected Pillow to write an ICO (type=1)"
    struct.pack_into("<H", data, 2, 2)  # -> CUR

    # hotspot lookup by (width, height) as actually stored (0 means 256)
    hotspot_by_size = {}
    for im, hx, hy in images_and_hotspots:
        w, h = im.size
        hotspot_by_size[(w if w < 256 else 0, h if h < 256 else 0)] = (hx, hy)

    for i in range(count):
        off = 6 + i * 16
        w, h = data[off], data[off + 1]
        key = (w, h)
        if key not in hotspot_by_size:
            # shouldn't happen given we build sizes ourselves, but degrade
            # gracefully to (0,0) rather than raising mid-build
            hx, hy = 0, 0
        else:
            hx, hy = hotspot_by_size[key]
        # planes(2) + bitcount(2) -> hotspot x,y (both little-endian uint16)
        struct.pack_into("<HH", data, off + 4, hx, hy)

    return bytes(data)


def write_cur(path: str, images_and_hotspots: Sequence[tuple[Image.Image, int, int]]) -> None:
    with open(path, "wb") as f:
        f.write(build_cur(images_and_hotspots))


# ---------------------------------------------------------------------------
# .ani (animated cursor)
# ---------------------------------------------------------------------------

def _chunk(fourcc: bytes, payload: bytes) -> bytes:
    out = fourcc + struct.pack("<I", len(payload)) + payload
    if len(payload) % 2:
        out += b"\x00"  # RIFF chunks are word-aligned
    return out


def build_ani(frame_curs: Sequence[bytes], delays_ms: Sequence[int]) -> bytes:
    """
    frame_curs: list of raw .cur bytes, one per animation frame (in order).
    delays_ms: matching per-frame delay in milliseconds.
    """
    assert len(frame_curs) == len(delays_ms) and frame_curs, "need >=1 frame"
    n = len(frame_curs)

    # ANIHeader: cbSizeOf, nFrames, nSteps, iWidth, iHeight, iBitCount,
    # nPlanes, iDispRate, bfAttributes
    # width/height/bitcount/planes left at 0 -> "use each frame's own".
    # bit0 of bfAttributes = frames are icon/cursor files (not raw DIBs).
    anih = struct.pack("<9I", 36, n, n, 0, 0, 0, 0, 0, 0x1)

    rate = b"".join(struct.pack("<I", max(1, round(ms * 60 / 1000))) for ms in delays_ms)

    fram_payload = b"LIST" + b"fram"
    # LIST needs its own size prefix too -> build inner first
    icons = b"".join(_chunk(b"icon", c) for c in frame_curs)
    fram_list = _chunk(b"LIST", b"fram" + icons)

    riff_payload = b"ACON"
    riff_payload += _chunk(b"anih", anih)
    riff_payload += _chunk(b"rate", rate)
    riff_payload += fram_list

    return _chunk(b"RIFF", riff_payload)


def write_ani(path: str, frame_curs: Sequence[bytes], delays_ms: Sequence[int]) -> None:
    with open(path, "wb") as f:
        f.write(build_ani(frame_curs, delays_ms))
