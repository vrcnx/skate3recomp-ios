#!/usr/bin/env python3
"""Copy selected files out of an Xbox 360 disc image (XDVDFS).

The iOS build only needs the executables for codegen on the Mac
(default.xex and data/webkit/EAWebkit.xex); the full game is installed on the
iPad by the app itself. Same partition offsets as src/skate3_iso_installer.cpp.

usage: extract_from_iso.py <image.iso> <output dir> <path in image>...
"""
import pathlib
import struct
import sys

SECTOR = 2048
GAME_OFFSETS = (0x00000000, 0x0000FB20, 0x00020600, 0x02080000, 0x0FD90000)
MAGIC = b"MICROSOFT*XBOX*MEDIA"


def find_partition(iso):
    for offset in GAME_OFFSETS:
        iso.seek(offset + 32 * SECTOR)
        if iso.read(len(MAGIC)) == MAGIC:
            root_sector, root_size = struct.unpack("<II", iso.read(8))
            return offset, root_sector, root_size
    sys.exit("not an Xbox 360 disc image (no XDVDFS header found)")


def walk(iso, base, sector, size, prefix=""):
    """Yields (path, start offset, length) for every file in the directory tree."""
    iso.seek(base + sector * SECTOR)
    table = iso.read(size)
    pending = [0]
    while pending:
        pos = pending.pop()
        if pos + 14 > len(table):
            continue
        left, right, start, length, attrs, name_len = struct.unpack_from("<HHIIBB", table, pos)
        if left == 0xFFFF:  # sector padding
            continue
        name = table[pos + 14 : pos + 14 + name_len].decode("latin-1")
        if left:
            pending.append(left * 4)
        if right:
            pending.append(right * 4)
        path = prefix + name
        if attrs & 0x10:
            if length:
                yield from walk(iso, base, start, length, path + "/")
        else:
            yield path, base + start * SECTOR, length


def main():
    iso_path, out_dir, *wanted = sys.argv[1:]
    wanted = {w.lower(): w for w in wanted}
    out = pathlib.Path(out_dir)
    with open(iso_path, "rb") as iso:
        base, root_sector, root_size = find_partition(iso)
        for path, offset, length in walk(iso, base, root_sector, root_size):
            if path.lower() not in wanted:
                continue
            target = out / wanted.pop(path.lower())
            target.parent.mkdir(parents=True, exist_ok=True)
            iso.seek(offset)
            with open(target, "wb") as f:
                remaining = length
                while remaining:
                    chunk = iso.read(min(remaining, 1 << 20))
                    f.write(chunk)
                    remaining -= len(chunk)
            print(f"{path}: {length} bytes")
    if wanted:
        sys.exit(f"not found in image: {', '.join(wanted.values())}")


main()
