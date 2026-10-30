//! GPU-backed tests of the OpenGL rendering contract. See test/README.md.
//! These deliberately use the production context, atlas upload, pipelines,
//! render passes, targets, and presentation path instead of reproducing GL
//! state in a separate harness. Only glyph rasterization is artificial.
const std = @import("std");
const testing = std.testing;
const gl = @import("opengl");
const OpenGL = @import("../OpenGL.zig");
const renderer = @import("../../renderer.zig");
const Atlas = @import("../../font/Atlas.zig");
const Blending = @import("../../config.zig").Config.AlphaBlending;
const shaders = OpenGL.shaders;

const side = 64;
const Pixel = [4]u8;
const Image = [side * side]Pixel;

const Context = struct {
    device: *OpenGL.Device,
    api: OpenGL,
    programs: shaders.Shaders,

    fn init() !Context {
        // GPU availability is not a prerequisite for the ordinary unit suite.
        // Once opted in, initialization failures must fail, never silently skip.
        if (testing.environ.getPosix("GHOSTTY_TEST_GPU") == null)
            return error.SkipZigTest;

        const device = try OpenGL.Device.init(testing.allocator, .{});
        errdefer device.deinit(testing.allocator);
        // OpenGL.init only consumes config.blending; no app surface or font
        // grid is involved in creating a surfaceless rendering context.
        var opts: renderer.Options = undefined;
        opts.config.blending = .linear;
        var api = try OpenGL.init(testing.allocator, device, opts);
        errdefer api.deinit();
        // unload() poisons this thread-local struct. The EGL loader does not
        // initialize GLAD's dlopen handle on subsequent loads; clear it when
        // reusing this test thread so teardown cannot dlclose a poison pointer.
        gl.glad.context = std.mem.zeroes(gl.glad.Context);
        try api.threadEnter(undefined); // The surface parameter is unused.
        errdefer api.threadExit();
        return .{
            .device = device,
            .api = api,
            .programs = try api.initShaders(testing.allocator, &.{}),
        };
    }

    fn deinit(self: *Context) void {
        self.programs.deinit(testing.allocator);
        self.api.threadExit();
        self.api.deinit();
        self.device.deinit(testing.allocator);
    }

    const Options = struct {
        blending: Blending = .linear,
        bg: Pixel = .{ 0, 0, 0, 255 },
        fg: Pixel = .{ 255, 255, 255, 255 },
        atlas: ?shaders.CellText.Atlas = null,
        dmabuf: bool = false,
        intermediate: bool = false,
    };

    fn draw(self: *Context, opts: Options) !Image {
        self.api.blending = opts.blending;
        var target = try self.api.initTarget(side, side);
        defer target.deinit();
        self.api.setViewport(side, side);
        const intermediate: ?OpenGL.Texture = if (opts.intermediate)
            try OpenGL.Texture.init(self.api.textureOptions(), side, side, null)
        else
            null;
        defer if (intermediate) |texture| texture.deinit();

        var uniforms = std.mem.zeroes(shaders.Uniforms);
        uniforms.projection_matrix = .{
            .{ 2.0 / @as(f32, side), 0, 0, 0 },
            .{ 0, -2.0 / @as(f32, side), 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ -1, 1, 0, 1 },
        };
        uniforms.screen_size = .{ side, side };
        uniforms.cell_size = .{ side, side };
        uniforms.grid_size = .{ 1, 1 };
        uniforms.cursor_pos = .{ 0xffff, 0xffff };
        uniforms.bg_color = opts.bg;
        uniforms.bools.use_linear_blending = opts.blending.isLinear();
        uniforms.bools.use_linear_correction = opts.blending == .@"linear-corrected";
        var ubo = try OpenGL.Buffer(shaders.Uniforms).initFill(self.api.uniformBufferOptions(), &.{uniforms});
        defer ubo.deinit();
        var cells_bg = try OpenGL.Buffer(shaders.CellBg).initFill(self.api.bgBufferOptions(), &.{.{ 0, 0, 0, 0 }});
        defer cells_bg.deinit();

        var grayscale = try Atlas.init(testing.allocator, side * 2, .grayscale);
        defer grayscale.deinit(testing.allocator);
        const gray_region = try grayscale.reserve(testing.allocator, side, side);
        const mask = coverage();
        grayscale.set(gray_region, &mask);
        var gray_texture = try self.api.initAtlasTexture(&grayscale);
        defer gray_texture.deinit();
        try gray_texture.replaceRegion(0, 0, grayscale.size, grayscale.size, grayscale.data);

        var color = try Atlas.init(testing.allocator, side * 2, .bgra);
        defer color.deinit(testing.allocator);
        const color_region = try color.reserve(testing.allocator, side, side);
        const glyph = colorGlyph(opts.fg);
        color.set(color_region, std.mem.asBytes(&glyph));
        var color_texture = try self.api.initAtlasTexture(&color);
        defer color_texture.deinit();
        try color_texture.replaceRegion(0, 0, color.size, color.size, color.data);

        const region = if (opts.atlas == .color) color_region else gray_region;
        var cells = try OpenGL.Buffer(shaders.CellText).initFill(self.api.fgBufferOptions(), &.{.{
            .glyph_pos = .{ region.x, region.y },
            .glyph_size = .{ side, side },
            .bearings = .{ 0, side },
            .grid_pos = .{ 0, 0 },
            .color = opts.fg,
            .atlas = opts.atlas orelse .grayscale,
            .bools = .{ .no_min_contrast = true },
        }});
        defer cells.deinit();

        var pass = OpenGL.RenderPass.begin(.{ .attachments = &.{.{
            .target = if (intermediate) |texture| .{ .texture = texture } else .{ .target = target },
            .clear_color = .{ 0, 0, 0, 0 },
        }} });
        pass.step(.{
            .pipeline = self.programs.pipelines.bg_color,
            .uniforms = ubo.buffer,
            .draw = .{ .type = .triangle, .vertex_count = 3 },
        });
        if (opts.atlas != null) pass.step(.{
            .pipeline = self.programs.pipelines.cell_text,
            .uniforms = ubo.buffer,
            .buffers = &.{ cells.buffer, cells_bg.buffer },
            .textures = &.{ gray_texture, color_texture },
            .draw = .{ .type = .triangle_strip, .vertex_count = 4 },
        });
        pass.complete();
        if (intermediate) |texture| {
            // An identity post-processing shader verifies the actual format
            // chosen by textureOptions, including sampling and re-encoding.
            var post = try self.api.initShaders(testing.allocator, &.{
                \\#version 430 core
                \\layout(binding = 0) uniform sampler2D frame;
                \\layout(location = 0) out vec4 color;
                \\void main() { color = texelFetch(frame, ivec2(gl_FragCoord.xy), 0); }
            });
            defer post.deinit(testing.allocator);
            var sampler = try OpenGL.Sampler.init(self.api.samplerOptions());
            defer sampler.deinit();
            var post_pass = OpenGL.RenderPass.begin(.{ .attachments = &.{.{
                .target = .{ .target = target },
                .clear_color = .{ 0, 0, 0, 0 },
            }} });
            post_pass.step(.{
                .pipeline = post.post_pipelines[0],
                .textures = &.{texture},
                .samplers = &.{sampler},
                .draw = .{ .type = .triangle, .vertex_count = 3 },
            });
            post_pass.complete();
        }
        try gl.errors.getError();

        var result: Image = undefined;
        if (opts.dmabuf) {
            const frame = try target.exportDmabuf(self.device.display, self.api.egl_context);
            defer frame.deinit();
            try testing.expect(frame.premultiplied);
            // Inspect the actual exported texture, not the source attachment.
            // Importing the fd in GTK is outside this API-level contract test.
            const binding = try target.export_framebuffer.bind(.read);
            defer binding.unbind();
            try gl.readPixels(0, 0, side, side, .rgba, .unsigned_byte, @ptrCast(&result));
        } else {
            const frame = try self.api.present(target, .unhealthy);
            defer frame.deinit();
            @memcpy(std.mem.asBytes(&result), frame.memory.pixels);
        }
        // ReadPixels has its origin at the bottom; fixtures and files use top.
        for (0..side / 2) |y| for (0..side) |x| {
            std.mem.swap(Pixel, &result[y * side + x], &result[(side - 1 - y) * side + x]);
        };
        return result;
    }
};

fn coverage() [side * side]u8 {
    const glyph = [_][]const u8{
        "01111100", "11000110", "11000000", "11011110",
        "11000110", "11000110", "01111100", "00000000",
    };
    var result: [side * side]u8 = undefined;
    for (0..side) |y| for (0..side) |x| {
        var hits: u8 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const gx: i32 = @intFromFloat(@floor((@as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4 - 8.25) / 5.75));
            const gy: i32 = @intFromFloat(@floor((@as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4 - 4.5) / 5.75));
            if (gx >= 0 and gx < 8 and gy >= 0 and gy < 8 and glyph[@intCast(gy)][@intCast(gx)] == '1') hits += 1;
        };
        result[y * side + x] = if (y >= 53 and y < 61 and x >= 4 and x < 60)
            byte(@as(f64, @floatFromInt(x - 4)) / 55)
        else
            byte(@as(f64, @floatFromInt(hits)) / 16);
    };
    return result;
}

/// FreeType's FT_PIXEL_MODE_BGRA is premultiplied in sRGB, not linear RGB.
fn colorGlyph(fg: Pixel) Image {
    var result: Image = undefined;
    for (&result, coverage()) |*pixel, alpha| {
        pixel.* = .{
            byte(unit(fg[2]) * unit(alpha)),
            byte(unit(fg[1]) * unit(alpha)),
            byte(unit(fg[0]) * unit(alpha)),
            alpha,
        };
    }
    return result;
}

fn unit(value: u8) f64 {
    return @as(f64, @floatFromInt(value)) / 255;
}

fn byte(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn decode(value: f64) f64 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

fn encode(value: f64) f64 {
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
}

/// Independent scalar source-over reference. Expected pixels are calculated
/// from the input bytes, never from framebuffer samples or shader helpers.
fn reference(opts: Context.Options) Image {
    var result: Image = undefined;
    const glyph = colorGlyph(opts.fg);
    for (&result, coverage(), glyph) |*pixel, mask, color| {
        if (opts.atlas == null) {
            pixel.* = .{ byte(unit(opts.bg[0]) * unit(opts.bg[3])), byte(unit(opts.bg[1]) * unit(opts.bg[3])), byte(unit(opts.bg[2]) * unit(opts.bg[3])), opts.bg[3] };
            continue;
        }
        const alpha = unit(mask);
        for (0..3) |c| {
            const fg = if (opts.atlas == .color)
                (if (alpha == 0) 0 else unit(color[2 - c]) / alpha)
            else
                unit(opts.fg[c]);
            const bg = unit(opts.bg[c]);
            // Corrected grayscale fixtures are black/white, where the desired
            // result is exactly interpolation of the gamma-encoded values.
            pixel[c] = if (opts.blending == .native or
                (opts.blending == .@"linear-corrected" and opts.atlas == .grayscale))
                byte(fg * alpha + bg * (1 - alpha))
            else
                byte(encode(decode(fg) * alpha + decode(bg) * (1 - alpha)));
        }
        pixel[3] = 255; // All glyph fixtures have an opaque background.
    }
    return result;
}

fn writeImage(name: []const u8, image: *const Image) !void {
    const directory = testing.environ.getPosix("GHOSTTY_TEST_RENDER_OUTPUT") orelse return;
    const alloc = testing.allocator;
    try std.Io.Dir.cwd().createDirPath(testing.io, directory);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.ppm", .{ directory, name });
    defer alloc.free(path);
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try output.writer.print("P6\n{d} {d}\n255\n", .{ side, side });
    for (image) |pixel| try output.writer.writeAll(pixel[0..3]);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = output.written() });
}

fn check(name: []const u8, actual: *const Image, expected: *const Image, linear: bool) !bool {
    var difference: Image = undefined;
    var errors: usize = 0;
    var maximum: u8 = 0;
    for (actual, expected, &difference) |a, e, *diff| {
        var bad = false;
        for (a, e, 0..) |av, ev, c| {
            const delta: u8 = @intCast(@abs(@as(i16, av) - ev));
            maximum = @max(maximum, delta);
            // Some drivers quantize blending weights to attachment precision.
            // One linear UNORM8 step can span several sRGB codes near black.
            // Alpha and gamma-space output still use the strict byte bound.
            const rounding = linear and c < 3 and @abs(decode(unit(av)) - decode(unit(ev))) <= 1.0 / 255.0;
            bad = bad or (delta > 2 and !rounding);
            diff[c] = delta *| 4;
        }
        errors += @intFromBool(bad);
        diff[3] = 255;
    }
    var buf: [256]u8 = undefined;
    try writeImage(try std.fmt.bufPrint(&buf, "{s}-actual", .{name}), actual);
    try writeImage(try std.fmt.bufPrint(&buf, "{s}-reference", .{name}), expected);
    try writeImage(try std.fmt.bufPrint(&buf, "{s}-difference", .{name}), &difference);
    if (errors != 0) std.debug.print("{s}: {d}/{d} pixels differ, max channel error {d}\n", .{ name, errors, side * side, maximum });
    return errors == 0;
}

test "OpenGL blending grayscale coverage" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var valid = true;
    for ([_]Blending{ .linear, .@"linear-corrected" }) |mode| {
        for ([_]u8{ 0, 255 }) |fg| {
            const opts: Context.Options = .{ .blending = mode, .fg = .{ fg, fg, fg, 255 }, .bg = .{ 255 - fg, 255 - fg, 255 - fg, 255 }, .atlas = .grayscale };
            var name: [128]u8 = undefined;
            valid = try check(try std.fmt.bufPrint(&name, "grayscale-{s}-{d}", .{ @tagName(mode), fg }), &try ctx.draw(opts), &reference(opts), true) and valid;
        }
    }
    try testing.expect(valid);
}

test "OpenGL blending color glyphs" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var valid = true;
    for ([_]Blending{ .linear, .native }) |mode| {
        for ([_]Pixel{ .{ 255, 255, 255, 255 }, .{ 219, 103, 37, 255 }, .{ 37, 149, 231, 255 } }, 0..) |fg, col| {
            for ([_]u8{ 0, 96, 255 }) |bg| {
                const opts: Context.Options = .{ .blending = mode, .fg = fg, .bg = .{ bg, bg, bg, 255 }, .atlas = .color };
                var name: [128]u8 = undefined;
                valid = try check(try std.fmt.bufPrint(&name, "color-{s}-{d}-{d}", .{ @tagName(mode), col, bg }), &try ctx.draw(opts), &reference(opts), mode.isLinear()) and valid;
            }
        }
    }
    try testing.expect(valid);
}

test "OpenGL blending opaque backgrounds preserve sRGB" {
    var ctx = try Context.init();
    defer ctx.deinit();
    var valid = true;
    for ([_]Blending{ .native, .linear, .@"linear-corrected" }) |mode| {
        for ([_]bool{ false, true }) |intermediate| {
            const opts: Context.Options = .{ .blending = mode, .bg = .{ 128, 64, 192, 255 }, .intermediate = intermediate };
            var name: [128]u8 = undefined;
            valid = try check(try std.fmt.bufPrint(&name, "background-{s}-{s}", .{ @tagName(mode), if (intermediate) "post" else "direct" }), &try ctx.draw(opts), &reference(opts), mode.isLinear()) and valid;
        }
    }
    try testing.expect(valid);
}

fn checkExport(ctx: *Context, dmabuf: bool) !void {
    var valid = true;
    for ([_]Blending{ .linear, .native }) |mode| {
        for ([_]u8{ 0, 1, 64, 128, 192, 254, 255 }) |alpha| {
            const opts: Context.Options = .{ .blending = mode, .bg = .{ 255, 127, 31, alpha }, .dmabuf = dmabuf };
            var name: [128]u8 = undefined;
            valid = try check(try std.fmt.bufPrint(&name, "export-{s}-{s}-{d}", .{ if (dmabuf) "dmabuf" else "memory", @tagName(mode), alpha }), &try ctx.draw(opts), &reference(opts), false) and valid;
        }
    }
    try testing.expect(valid);
}

test "OpenGL blending CPU export is sRGB premultiplied" {
    var ctx = try Context.init();
    defer ctx.deinit();
    try checkExport(&ctx, false);
}

test "OpenGL blending DMA-BUF export is sRGB premultiplied" {
    var ctx = try Context.init();
    defer ctx.deinit();
    const extensions = ctx.device.display.queryString(.extensions) orelse "";
    if (!gl.egl.hasExtension(extensions, "EGL_MESA_image_dma_buf_export")) return error.SkipZigTest;
    try checkExport(&ctx, true);
}
