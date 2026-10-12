#!/usr/bin/env python3
"""Génère l'icône « manette pixel art » (PNG sans dépendance) en plusieurs tailles."""
import struct, sys, zlib
from pathlib import Path

ART = [
    "................",
    "................",
    "................",
    "...KKKK..KKKK...",
    "..KBBBBKKBBBBK..",
    ".KBHHBBBBBBBBBK.",
    ".KBBDBBBBBBYBBK.",
    "KBBDDDBBBBCBRBBK",
    "KBBBDBBWWBBGBBBK",
    "KBBBBBBBBBBBBBBK",
    "KBBBBBKKKKBBBBBK",
    ".KBBBK....KBBBK.",
    "..KKK......KKK..",
    "................",
    "................",
    "................",
]
PAL = {
    "K": (24, 20, 37, 255),     # contour
    "B": (124, 92, 255, 255),   # corps violet
    "H": (186, 168, 255, 255),  # reflet
    "D": (30, 26, 48, 255),     # croix directionnelle
    "W": (230, 230, 240, 255),  # start/select
    "R": (255, 77, 109, 255), "G": (61, 220, 132, 255),
    "Y": (255, 209, 102, 255), "C": (77, 171, 255, 255),
    ".": (0, 0, 0, 0),
}


def png(size, bg=True):
    scale = size // 16
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            c = PAL[ART[y // scale][x // scale]]
            if bg and c[3] == 0:
                # fond arrondi sombre (style icône macOS)
                m, r = size * 0.06, size * 0.2
                inside = m <= x < size - m and m <= y < size - m
                cx = min(max(x, m + r), size - m - r); cy = min(max(y, m + r), size - m - r)
                if inside and (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    c = (44, 40, 72, 255)
            row += bytes(c)
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "icon")
    out.mkdir(parents=True, exist_ok=True)
    for s in (16, 32, 64, 128, 256, 512, 1024):
        (out / f"icon_{s}.png").write_bytes(png(s))
    print(f"✅ icônes dans {out}/")
