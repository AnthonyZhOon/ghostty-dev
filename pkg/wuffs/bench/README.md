# Kitty zlib decompression microbenchmark

The two binaries compare Zig's streaming `std.compress.flate.Decompress` with one Wuffs `wuffs_zlib__decoder__transform_io` call per image. Both decode the same ten RFC 1950 zlib streams into preallocated pixel buffers. The streams represent Kitty graphics `f=32,o=z` images: raw sRGB RGBA pixels are compressed **before** base64 transport encoding. Kitty compresses the complete image once; direct transmission then splits the base64 text into chunks of at most 4096 bytes. Chunks are not independent zlib streams. See the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).

The default `payload` mode times zlib decompression only. The `streamed` mode times 4096-byte base64 chunk decoding and reassembly followed by decompression of the complete image. Both modes exclude fixture file reads, allocations, and CRC checks from the internal timed loop. The streamed mode does not parse APC escape codes.

## Prepare and run

From `pkg/wuffs`:

```sh
python3 bench/make_fixture.py ~/Pictures/wallpapers /tmp/ghostty-kitty-fixtures
zig build bench -Doptimize=ReleaseFast
./zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2
./zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2
./zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2 streamed
./zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2 streamed
```

The fixture script requires Pillow. It looks for ten images whose actual base64 payloads are closest to 4 MiB (configurable with `--target-base64-mib`), converts each to RGBA, compresses it with Python's zlib, and writes both the compressed payload and its base64 encoding. It also records the uncompressed size and CRC32 in `manifest.txt` and prints the Kitty `f`, `s`, `v`, and `o` parameters. Run the script once, outside the benchmark. The optional round count defaults to 3; every round decodes all ten images once in a varying order. Both binaries validate all ten images before and after the timed loop.

To compare complete process runs, including fixture loading and untimed validation:

```sh
hyperfine --warmup 1 --runs 5 \
  './zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2' \
  './zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2'

poop -d 3000 \
  './zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2' \
  './zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2'

hyperfine --warmup 1 --runs 5 \
  './zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2 streamed' \
  './zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2 streamed'

poop -d 3000 \
  './zig-out/bin/kitty-zlib-zig /tmp/ghostty-kitty-fixtures 2 streamed' \
  './zig-out/bin/kitty-zlib-wuffs /tmp/ghostty-kitty-fixtures 2 streamed'
```

On an Intel Core i5-12400F with Zig 0.16.0 and `ReleaseFast`, the ten-image fixture prepared on 2026-09-25 averaged 3.89 MiB of base64 per image and gave:

| Mode and tool | Zig streaming | Wuffs single pass | Wuffs speedup |
| --- | ---: | ---: | ---: |
| Payload, `hyperfine` (5 runs, mean wall time) | 2.294 s | 1.961 s | 1.17× |
| Payload, `poop` (3 runs, mean wall time) | 2.30 s | 1.96 s | 1.17× |
| Streamed, `hyperfine` (5 runs, mean wall time) | 2.326 s | 1.987 s | 1.17× |
| Streamed, `poop` (3 runs, mean wall time) | 2.34 s | 1.99 s | 1.18× |

These wall times include one untimed validation pass and process startup. The binaries also print decode-only elapsed nanoseconds and nanoseconds per image. The relative result depends on the selected images, compression ratio, CPU, and build mode.
