//! Represents a render target.
//!
//! In this case, a texture-backed framebuffer. The color attachment is a
//! `GL_TEXTURE_2D` texture instead of a renderbuffer so that we can create
//! an EGLImage from it and export the rendered frame as a dma-buf for
//! presentation by the apprt.
//!
//! We use two textures:
//!
//!   - `texture`: `GL_SRGB8_ALPHA8` for linear blending, `GL_RGBA8` for
//!     native blending. The attachment format controls automatic sRGB
//!     decoding/encoding while `GL_FRAMEBUFFER_SRGB` is enabled.
//!
//!   - `export_texture`: `GL_RGBA8`, containing sRGB-premultiplied bytes for
//!     both DMA-BUF and CPU presentation. A shader converts the render
//!     target's linear-premultiplied colors to this representation; a raw
//!     copy would encode alpha as part of RGB and produce bright fringes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const Dmabuf = @import("../Dmabuf.zig");
const shaders = @import("shaders.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
    /// Whether shaders output linear rather than gamma-encoded RGB.
    linear: bool,
};

/// The framebuffer we render to.
framebuffer: gl.Framebuffer,

/// The color attachment texture we render to, in the blending color space.
texture: gl.Texture,

/// A plain RGBA8 texture containing sRGB-premultiplied presentation pixels.
export_texture: gl.Texture,
export_framebuffer: gl.Framebuffer,
export_program: gl.Program,
export_vao: gl.VertexArray,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound_tex = try texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            if (opts.linear) .srgba else .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    {
        const bound_fbo = try fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("render framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    // --- Export texture (plain RGBA8, for dma-buf export) ---
    const export_texture = try gl.Texture.create();
    errdefer export_texture.destroy();
    {
        const bound_tex = try export_texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const export_fbo = try gl.Framebuffer.create();
    errdefer export_fbo.destroy();
    {
        const bound_fbo = try export_fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", export_texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("export framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    const export_program = try gl.Program.createVF(
        shaders.loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        shaders.loadShaderCode("../shaders/glsl/present.f.glsl"),
    );
    errdefer export_program.destroy();
    {
        const binding = try export_program.use();
        defer binding.unbind();
        try export_program.setUniform("linear_blending", opts.linear);
    }
    const export_vao = try gl.VertexArray.create();
    errdefer export_vao.destroy();

    return .{
        .framebuffer = fbo,
        .texture = texture,
        .export_framebuffer = export_fbo,
        .export_texture = export_texture,
        .export_program = export_program,
        .export_vao = export_vao,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.texture.destroy();
    self.export_framebuffer.destroy();
    self.export_texture.destroy();
    self.export_program.destroy();
    self.export_vao.destroy();
}

/// Prepare pixels for either presentation path. Subsequent render passes set
/// their own blending state and viewport before drawing into a target again.
fn prepareExport(self: *const Self) !void {
    const draw_bind = try self.export_framebuffer.bind(.draw);
    defer draw_bind.unbind();
    const program_bind = try self.export_program.use();
    defer program_bind.unbind();
    const vao_bind = try self.export_vao.bind();
    defer vao_bind.unbind();
    try gl.Texture.active(0);
    const texture_bind = try self.texture.bind(.@"2d");
    defer texture_bind.unbind();
    try gl.viewport(0, 0, @intCast(self.width), @intCast(self.height));
    try gl.disable(gl.c.GL_BLEND);
    try gl.drawArraysInstanced(.triangle, 0, 3, 1);
}

pub fn exportDmabuf(
    self: *const Self,
    display: *egl.Display,
    context: *egl.Context,
) !Dmabuf {
    try self.prepareExport();
    const image: *egl.Image = try .create(
        display,
        context,
        .{ .texture_2d = self.export_texture.id },
        &.{},
    );
    defer image.destroy(display) catch {};

    const query = try image.exportDmabufQuery(display);

    if (query.num_planes < 1 or query.num_planes > Dmabuf.max_planes) {
        log.err("DMABUF has too many planes={}", .{query.num_planes});
        return error.DmabufTooManyPlanes;
    }

    var planes: Dmabuf.Planes = .{ .count = @intCast(query.num_planes) };
    try image.exportDmabuf(
        display,
        &planes.fds,
        &planes.strides,
        &planes.offsets,
    );
    try planes.validate();

    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        // bitCast instead of intCast since the numerical value of fourccs
        // is rather meaningless, and we only care about the bit pattern
        .fourcc = @bitCast(query.fourcc),
        .modifier = query.modifier,
        .premultiplied = true,
        .planes = planes,
    };
}

/// Read the presentation pixels into CPU memory.
///
/// This is used by the CPU readback presentation fallback. The
/// returned data is tightly-packed RGBA8 with premultiplied alpha,
/// i.e. `width * 4` bytes per row, premultiplied in sRGB just like DMA-BUF.
pub fn readPixelsAlloc(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    try self.prepareExport();
    const bind = try self.export_framebuffer.bind(.read);
    defer bind.unbind();

    const pixels = try alloc.alloc(u8, self.width * self.height * 4);
    errdefer alloc.free(pixels);

    try gl.readPixels(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        .rgba,
        .unsigned_byte,
        pixels.ptr,
    );

    return pixels;
}
