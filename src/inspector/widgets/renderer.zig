const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const renderer = @import("../../renderer.zig");
const CircBuf = @import("../../datastruct/circ_buf.zig").CircBuf;

const log = std.log.scoped(.inspector_renderer);

pub const FrameEvent = struct {
    start: std.time.Instant,
    end: std.time.Instant, // In nanoseconds

    pub fn frameTimeMs(self: *const FrameEvent) f32 {
        return @as(f32, @floatFromInt(self.end.since(self.start))) / 1e6; // Convert to ms
    }
};
fn FrameRing(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        frames: CircBuf(FrameEvent, undefined),

        pub fn init(alloc: Allocator) !Self {
            return .{
                .frames = try .init(alloc, capacity),
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.frames.deinit(alloc);
        }

        pub fn recordFrameTime(
            self: *Self,
            frame_time: FrameEvent,
        ) void {
            if (self.frames.full) {
                self.frames.deleteOldest(1);
            }
            self.frames.append(frame_time) catch {
                log.err("Failed to record frame time", .{});
            };
        }

        pub fn draw(
            self: *Self,
            open: bool,
        ) void {
            if (!open) return;
            const len = self.frames.len();
            if (len == 0) {
                cimgui.c.ImGui_Text("No frame times recorded yet.");
                return;
            }
            const slice = self.frames.getPtrSlice(0, len);
            var data: [capacity]f32 = undefined;
            // Milliseconds won't overflow, probably
            var sum: f32 = 0.0;
            for (slice[0], 0..) |frame, i| {
                const ms = frame.frameTimeMs();
                sum += ms;
                data[i] = ms;
            }
            for (slice[1], slice[0].len..) |frame, i| {
                const ms = frame.frameTimeMs();
                sum += ms;
                data[i] = ms;
            }

            cimgui.c.ImGui_SeparatorText("Performance");
            cimgui.c.ImGui_PlotLines("Frame Times", @ptrCast(&data), @intCast(len));
            const len_f32: f32 = @floatFromInt(len);
            const avg_frame_time = sum / len_f32;
            const duration_ns: f32 = @floatFromInt(self.frames.last().?.end.since(self.frames.first().?.start));
            const buffer_duration_ms: f32 = duration_ns / 1e6;
            const avg_fps = 1000 * len_f32 / buffer_duration_ms;
            cimgui.c.ImGui_Text("Average Frame Time: %3g ms", avg_frame_time);
            cimgui.c.ImGui_Text("Last Frame Time: %3g ms", self.frames.last().?.frameTimeMs());
            cimgui.c.ImGui_Text("FPS: %3g", avg_fps);
            return;
        }
    };
}
pub const FrameTimes = FrameRing(256);
/// Renderer information inspector widget.
pub const Info = struct {
    features: std.AutoArrayHashMapUnmanaged(
        std.meta.Tag(renderer.Overlay.Feature),
        renderer.Overlay.Feature,
    ),

    pub const empty: Info = .{
        .features = .empty,
    };

    pub fn deinit(self: *Info, alloc: Allocator) void {
        self.features.deinit(alloc);
    }

    /// Grab the features into a new allocated slice. This is used by
    pub fn overlayFeatures(
        self: *const Info,
        alloc: Allocator,
    ) Allocator.Error![]renderer.Overlay.Feature {
        // The features from our internal state.
        const features = self.features.values();

        // For now we do a dumb copy since the features have no managed
        // memory.
        const result = try alloc.dupe(
            renderer.Overlay.Feature,
            features,
        );
        errdefer alloc.free(result);

        return result;
    }

    /// Draw the renderer info window.
    pub fn draw(
        self: *Info,
        alloc: Allocator,
        open: bool,
    ) void {
        if (!open) return;

        cimgui.c.ImGui_SetNextItemOpen(true, cimgui.c.ImGuiCond_Once);
        if (!cimgui.c.ImGui_CollapsingHeader("Overlays", cimgui.c.ImGuiTreeNodeFlags_None)) return;

        cimgui.c.ImGui_SeparatorText("Hyperlinks");
        self.overlayHyperlinks(alloc);
        cimgui.c.ImGui_SeparatorText("Semantic Prompts");
        self.overlaySemanticPrompts(alloc);
    }

    fn overlayHyperlinks(self: *Info, alloc: Allocator) void {
        var hyperlinks: bool = self.features.contains(.highlight_hyperlinks);
        _ = cimgui.c.ImGui_Checkbox("Overlay Hyperlinks", &hyperlinks);
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("When enabled, highlights OSC8 hyperlinks.");

        if (!hyperlinks) {
            _ = self.features.swapRemove(.highlight_hyperlinks);
        } else {
            self.features.put(
                alloc,
                .highlight_hyperlinks,
                .highlight_hyperlinks,
            ) catch log.warn("error enabling hyperlink overlay feature", .{});
        }
    }

    fn overlaySemanticPrompts(self: *Info, alloc: Allocator) void {
        var semantic_prompts: bool = self.features.contains(.semantic_prompts);
        _ = cimgui.c.ImGui_Checkbox("Overlay Semantic Prompts", &semantic_prompts);
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("When enabled, highlights OSC 133 semantic prompts.");

        // Handle the checkbox results
        if (!semantic_prompts) {
            _ = self.features.swapRemove(.semantic_prompts);
        } else {
            self.features.put(
                alloc,
                .semantic_prompts,
                .semantic_prompts,
            ) catch log.warn("error enabling semantic prompt overlay feature", .{});
        }

        // Help
        cimgui.c.ImGui_Indent();
        defer cimgui.c.ImGui_Unindent();

        cimgui.c.ImGui_TextDisabled("Colors:");

        const prompt_rgb = renderer.Overlay.Color.semantic_prompt.rgb();
        const input_rgb = renderer.Overlay.Color.semantic_input.rgb();
        const prompt_col: cimgui.c.ImVec4 = .{
            .x = @as(f32, @floatFromInt(prompt_rgb.r)) / 255.0,
            .y = @as(f32, @floatFromInt(prompt_rgb.g)) / 255.0,
            .z = @as(f32, @floatFromInt(prompt_rgb.b)) / 255.0,
            .w = 1.0,
        };
        const input_col: cimgui.c.ImVec4 = .{
            .x = @as(f32, @floatFromInt(input_rgb.r)) / 255.0,
            .y = @as(f32, @floatFromInt(input_rgb.g)) / 255.0,
            .z = @as(f32, @floatFromInt(input_rgb.b)) / 255.0,
            .w = 1.0,
        };

        _ = cimgui.c.ImGui_ColorButton("##prompt_color", prompt_col, cimgui.c.ImGuiColorEditFlags_NoTooltip);
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_Text("Prompt");

        _ = cimgui.c.ImGui_ColorButton("##input_color", input_col, cimgui.c.ImGuiColorEditFlags_NoTooltip);
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_Text("Input");
    }
};
