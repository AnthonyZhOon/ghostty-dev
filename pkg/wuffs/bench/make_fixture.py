#!/usr/bin/env python3
"""Prepare ten Kitty f=32,o=z payloads near a target base64 size."""

import argparse
import base64
import zlib
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image_directory", type=Path)
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--target-base64-mib", type=float, default=4.0)
    args = parser.parse_args()
    if args.target_base64_mib <= 0:
        parser.error("target size must be positive")

    target_bytes = round(args.target_base64_mib * 1024 * 1024)
    target_compressed = target_bytes * 3 // 4
    candidates = []
    for path in args.image_directory.iterdir():
        try:
            with Image.open(path) as image:
                if image.width > 10000 or image.height > 10000:
                    continue
                candidates.append(path)
        except (OSError, ValueError):
            continue
    if len(candidates) < 10:
        parser.error("need at least ten readable images")

    # Source file size is a cheap proxy. Compress only the 30 closest images,
    # then select by actual base64 payload length.
    candidates.sort(key=lambda path: (abs(path.stat().st_size - target_compressed), path.name))
    records = []
    for path in candidates[:30]:
        with Image.open(path) as image:
            rgba = image.convert("RGBA")
            raw = rgba.tobytes()
            width, height = rgba.size
        if len(raw) > 400 * 1024 * 1024:
            continue
        compressed = zlib.compress(raw)
        encoded_len = 4 * ((len(compressed) + 2) // 3)
        records.append((abs(encoded_len - target_bytes), path.name, path, compressed,
                        len(raw), zlib.crc32(raw), width, height, encoded_len))
    if len(records) < 10:
        parser.error("need at least ten images within the raw size limit")
    records.sort(key=lambda record: (record[0], record[1]))

    args.fixture_directory.mkdir(parents=True, exist_ok=True)
    manifest = []
    for index, (_, _, path, compressed, raw_len, crc32, width, height, encoded_len) in enumerate(records[:10]):
        name = f"{index:02d}.zlib"
        (args.fixture_directory / name).write_bytes(compressed)
        (args.fixture_directory / f"{name}.b64").write_bytes(base64.b64encode(compressed))
        manifest.append(f"{name} {raw_len} {crc32:08x}\n")
        print(f"{name}: {path.name}, f=32,s={width},v={height},o=z, base64={encoded_len}")
    (args.fixture_directory / "manifest.txt").write_text("".join(manifest))


if __name__ == "__main__":
    main()
