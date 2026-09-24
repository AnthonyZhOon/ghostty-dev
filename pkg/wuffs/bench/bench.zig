const std = @import("std");
const c = @import("wuffs_c");

pub const Decoder = enum { zig, wuffs };
const Mode = enum { payload, streamed };
const image_count = 10;
const base64_chunk_size = 4096;

const Image = struct {
    compressed: []u8,
    encoded: ?[]u8,
    pixels: []u8,
    crc32: u32,
};

pub fn run(init: std.process.Init, comptime decoder: Decoder) !void {
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 4) {
        std.log.err("usage: {s} <fixture-directory> [rounds] [streamed]", .{args[0]});
        return error.InvalidArguments;
    }
    const rounds = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 3;
    if (rounds == 0) return error.InvalidArguments;
    const mode: Mode = if (args.len == 4) mode: {
        if (!std.mem.eql(u8, args[3], "streamed")) return error.InvalidArguments;
        break :mode .streamed;
    } else .payload;

    var images = try loadImages(init.io, alloc, args[1], mode);
    defer for (&images) |*image| {
        alloc.free(image.compressed);
        if (image.encoded) |encoded| alloc.free(encoded);
        alloc.free(image.pixels);
    };
    const state_memory = try alloc.alignedAlloc(u8, .@"16", c.sizeof__wuffs_zlib__decoder());
    defer alloc.free(state_memory);

    // Verify every payload before timing. Each image is an independent zlib stream.
    for (&images) |*image| {
        try decodeImage(decoder, mode, image, state_memory);
        if (std.hash.Crc32.hash(image.pixels) != image.crc32) return error.ChecksumMismatch;
    }

    const start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |round| {
        // 3 is coprime with 10, so each round visits every image once. The
        // starting point changes by 7 to avoid a fixed image order.
        for (0..image_count) |offset| {
            const index = (round *% 7 +% offset *% 3) % image_count;
            const image = &images[index];
            try decodeImage(decoder, mode, image, state_memory);
        }
    }
    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io));

    // Keep the decoded output observable, outside the timed region.
    for (&images) |*image| {
        if (std.hash.Crc32.hash(image.pixels) != image.crc32) return error.ChecksumMismatch;
    }
    const count = rounds * image_count;
    std.log.info("{s} {s}: images={d} rounds={d} decodes={d} elapsed_ns={d} ns_per_image={d}", .{
        @tagName(decoder),                                         @tagName(mode), image_count, rounds, count, elapsed.nanoseconds,
        @divTrunc(elapsed.nanoseconds, @as(i96, @intCast(count))),
    });
}

fn loadImages(io: std.Io, alloc: std.mem.Allocator, directory: []const u8, mode: Mode) ![image_count]Image {
    const manifest_path = try std.fs.path.join(alloc, &.{ directory, "manifest.txt" });
    defer alloc.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, alloc, .limited(4096));
    defer alloc.free(manifest);

    var result: [image_count]Image = undefined;
    var loaded: usize = 0;
    errdefer for (result[0..loaded]) |image| {
        alloc.free(image.compressed);
        if (image.encoded) |encoded| alloc.free(encoded);
        alloc.free(image.pixels);
    };
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (loaded == image_count) return error.InvalidManifest;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const filename = fields.next() orelse return error.InvalidManifest;
        const size_text = fields.next() orelse return error.InvalidManifest;
        const crc_text = fields.next() orelse return error.InvalidManifest;
        if (fields.next() != null) return error.InvalidManifest;
        const size = try std.fmt.parseInt(usize, size_text, 10);
        if (size == 0 or size > 400 * 1024 * 1024) return error.InvalidManifest;
        const crc32 = try std.fmt.parseInt(u32, crc_text, 16);
        const path = try std.fs.path.join(alloc, &.{ directory, filename });
        defer alloc.free(path);
        const compressed = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(512 * 1024 * 1024));
        const encoded: ?[]u8 = if (mode == .streamed) encoded: {
            const encoded_path = std.fmt.allocPrint(alloc, "{s}.b64", .{path}) catch |err| {
                alloc.free(compressed);
                return err;
            };
            defer alloc.free(encoded_path);
            break :encoded std.Io.Dir.cwd().readFileAlloc(io, encoded_path, alloc, .limited(768 * 1024 * 1024)) catch |err| {
                alloc.free(compressed);
                return err;
            };
        } else null;
        const pixels = alloc.alloc(u8, size) catch |err| {
            alloc.free(compressed);
            if (encoded) |bytes| alloc.free(bytes);
            return err;
        };
        result[loaded] = .{
            .compressed = compressed,
            .encoded = encoded,
            .pixels = pixels,
            .crc32 = crc32,
        };
        loaded += 1;
    }
    if (loaded != image_count) return error.InvalidManifest;
    return result;
}

fn decodeImage(comptime decoder: Decoder, mode: Mode, image: *Image, state_memory: []u8) !void {
    if (mode == .streamed) {
        const encoded = image.encoded orelse return error.InvalidManifest;
        var written: usize = 0;
        var offset: usize = 0;
        while (offset < encoded.len) {
            const end = @min(offset + base64_chunk_size, encoded.len);
            const chunk = encoded[offset..end];
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(chunk);
            if (decoded_len > image.compressed.len - written) return error.InvalidPayloadLength;
            try std.base64.standard.Decoder.decode(image.compressed[written..][0..decoded_len], chunk);
            written += decoded_len;
            offset = end;
        }
        if (written != image.compressed.len) return error.InvalidPayloadLength;
    }
    try decompress(decoder, image.compressed, image.pixels, state_memory);
}

fn decompress(comptime decoder: Decoder, input: []const u8, output: []u8, state_memory: []u8) !void {
    switch (decoder) {
        .zig => {
            var source: std.Io.Reader = .fixed(input);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var stream: std.compress.flate.Decompress = .init(&source, .zlib, &window);
            stream.reader.readSliceAll(output) catch return error.DecompressionFailed;
            var extra: [1]u8 = undefined;
            const extra_len = stream.reader.readSliceShort(&extra) catch return error.DecompressionFailed;
            if (extra_len != 0 or stream.err != null) return error.InvalidOutputLength;
        },
        .wuffs => {
            const state: *c.wuffs_zlib__decoder = @ptrCast(@alignCast(state_memory.ptr));
            var status = c.wuffs_zlib__decoder__initialize(state, state_memory.len, c.WUFFS_VERSION, 0);
            if (!c.wuffs_base__status__is_ok(&status)) return error.DecompressionFailed;
            var src: c.wuffs_base__io_buffer = .{
                .data = .{ .ptr = @ptrCast(@constCast(input.ptr)), .len = input.len },
                .meta = .{ .wi = input.len, .ri = 0, .pos = 0, .closed = true },
            };
            var dst: c.wuffs_base__io_buffer = .{
                .data = .{ .ptr = @ptrCast(output.ptr), .len = output.len },
                .meta = .{ .wi = 0, .ri = 0, .pos = 0, .closed = false },
            };
            status = c.wuffs_zlib__decoder__transform_io(state, &dst, &src, c.wuffs_base__empty_slice_u8());
            if (!c.wuffs_base__status__is_ok(&status) or dst.meta.wi != output.len or src.meta.ri != input.len)
                return error.DecompressionFailed;
        },
    }
}
