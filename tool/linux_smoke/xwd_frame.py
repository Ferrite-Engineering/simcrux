#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

"""Turn an Xvfb screen dump into a PNG and say whether the app drew a frame.

Xvfb started with `-fbdir DIR` keeps its framebuffer in DIR/Xvfb_screen0 as an
XWD image, so a screenshot needs no xwd or ImageMagick in the container: copy
that file. This script reads it, writes a PNG next to it and prints one line:

    <name> frame=yes colours=4182 dominant=61.2%

The screen starts uniform (Xvfb -br: black root). The runner shows its window
only after Flutter's first frame, so a screen that is still one flat colour
means nothing was drawn. Two things can still sit on an empty screen: the X
pointer, which with a cursor theme installed is an anti-aliased arrow of up to
about a hundred colours but a few hundred pixels, and a mapped window GTK has
not painted, which is one or two flat colours. A drawn SimCrux window covers
most of the screen with text, icons and anti-aliasing: thousands of colours.
So a frame counts as drawn when at least DRAWN_MIN_AREA of the screen differs
from its most common colour AND it has DRAWN_MIN_COLOURS colours or more.

Standard library only, so it runs on any CI host.

    xwd_frame.py <file.xwd> [<file.xwd> ...]
"""

import collections
import struct
import sys
import zlib

DRAWN_MIN_COLOURS = 16
DRAWN_MIN_AREA = 2.0  # percent of the screen


def read_xwd(path):
    with open(path, "rb") as f:
        data = f.read()
    # XWDFileHeader: 25 CARD32, most significant byte first.
    (header_size, _version, _fmt, _depth, width, height, _xoff, byte_order,
     _unit, _bit_order, _pad, bpp, bpl, _vclass, rmask, gmask, bmask,
     _bits_rgb, _cmap_entries, ncolors) = struct.unpack(">20I", data[:80])
    if bpp != 32 or byte_order != 0 or (rmask, gmask, bmask) != (
            0xFF0000, 0xFF00, 0xFF):
        raise ValueError(
            f"{path}: unsupported XWD layout (bpp={bpp}, byte_order={byte_order},"
            f" masks={rmask:#x}/{gmask:#x}/{bmask:#x}); start Xvfb at depth 24")
    offset = header_size + ncolors * 12
    pixels = data[offset:offset + bpl * height]
    rows = []
    for y in range(height):
        src = pixels[y * bpl:y * bpl + width * 4]
        rgb = bytearray(width * 3)
        rgb[0::3] = src[2::4]
        rgb[1::3] = src[1::4]
        rgb[2::3] = src[0::4]
        rows.append(bytes(rgb))
    return width, height, rows


def write_png(path, width, height, rows):
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body +
                struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + row for row in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main(paths):
    for path in paths:
        name = path.rsplit("/", 1)[-1].removesuffix(".xwd")
        try:
            width, height, rows = read_xwd(path)
        except (OSError, ValueError, struct.error) as e:
            print(f"{name} frame=unknown error={e}")
            continue
        counts = collections.Counter()
        for row in rows:
            counts.update(zip(row[0::3], row[1::3], row[2::3]))
        dominant = counts.most_common(1)[0][1] / (width * height) * 100
        write_png(path.removesuffix(".xwd") + ".png", width, height, rows)
        drawn = "yes" if (len(counts) >= DRAWN_MIN_COLOURS and
                          100 - dominant >= DRAWN_MIN_AREA) else "no"
        print(f"{name} frame={drawn} colours={len(counts)} dominant={dominant:.1f}%")


if __name__ == "__main__":
    main(sys.argv[1:])
