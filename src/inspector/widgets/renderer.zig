const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const renderer = @import("../../renderer.zig");
const CircBuf = @import("../../datastruct/circ_buf.zig").CircBuf;

const log = std.log.scoped(.inspector_renderer);

pub const FrameEvent = struct {
    start: std.Io.Timestamp,
    end: std.Io.Timestamp, // In nanoseconds

    pub fn frameTimeMs(self: *const FrameEvent) f32 {
        return @as(f32, @floatFromInt(self.start.durationTo(self.end).toMilliseconds())); // Convert to ms
    }
};

pub const FrameTiming = struct {
    pub const RecordableFields = std.meta.FieldEnum(std.meta.FieldEnum(struct {
        input_time: ?std.Io.Timestamp,
        frame_start: ?std.Io.Timestamp,
        cpu_end: ?std.Io.Timestamp,
        frame_end: ?std.Io.Timestamp,
    }));
    pub const Uncommitted = struct {
        input_time: ?std.Io.Timestamp = null,
        prev_end: ?std.Io.Timestamp = null,
        frame_start: ?std.Io.Timestamp = null,
        cpu_end: ?std.Io.Timestamp = null,
        frame_end: ?std.Io.Timestamp = null,

        pub fn record(self: *FrameTiming.Uncommitted, comptime field: RecordableFields, instant: std.Io.Timestamp) void {
            if (@field(self, @tagName(field)) != null) {
                std.debug.panic("Field {s} already recorded in {any}", .{ @tagName(field), self });
            }
            @field(self, @tagName(field)) = instant;
        }

        pub fn commit(self: *const Uncommitted) ?Committed {
            return .{
                .input_time = self.input_time,
                .prev_end = self.prev_end orelse return null,
                .frame_start = self.frame_start orelse return null,
                .cpu_end = self.cpu_end orelse return null,
                .frame_end = self.frame_end orelse return null,
            };
        }
    };

    pub const Committed = struct {
        input_time: ?std.Io.Timestamp = null,
        prev_end: std.Io.Timestamp,
        frame_start: std.Io.Timestamp,
        cpu_end: std.Io.Timestamp,
        frame_end: std.Io.Timestamp,
        pub fn inputLatencyMs(self: *const Committed) ?f32 {
            if (self.input_time) |input| {
                return @as(f32, @floatFromInt(input.durationTo(self.frame_start).toMilliseconds()));
            } else {
                return null;
            }
        }
        /// Total wall time including idle, from prev frame end to this frame end.
        pub fn totalRenderTimeMs(self: *const Committed) f32 {
            return @as(f32, @floatFromInt(self.prev_end.durationTo(self.frame_end).toMilliseconds()));
        }

        /// Idle time waiting between frames.
        pub fn preRenderTimeMs(self: *const Committed) f32 {
            return @as(f32, @floatFromInt(self.prev_end.durationTo(self.frame_start).toMilliseconds()));
        }

        /// Active render time: CPU + GPU.
        pub fn activeTimeMs(self: *const Committed) f32 {
            return @as(f32, @floatFromInt(self.frame_start.durationTo(self.frame_end).toMilliseconds()));
        }

        /// CPU render time only.
        pub fn cpuFrameTimeMs(self: *const Committed) f32 {
            return @as(f32, @floatFromInt(self.frame_start.durationTo(self.cpu_end).toMilliseconds()));
        }

        /// GPU render wait time only.
        pub fn gpuWaitTimeMs(self: *const Committed) f32 {
            return @as(f32, @floatFromInt(self.cpu_end.durationTo(self.frame_end).toMilliseconds()));
        }
    };
};

fn FrameHistory(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        frames: CircBuf(FrameTiming.Committed, undefined),
        uncommitted_frame: FrameTiming.Uncommitted = .{},

        pub fn init(alloc: Allocator) !Self {
            return .{
                .frames = try .init(alloc, capacity),
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.frames.deinit(alloc);
        }

        pub fn record(self: *Self, comptime field: FrameTiming.RecordableFields, instant: std.Io.Timestamp) void {
            log.debug("Recording frame timing: {s} at {any}", .{ @tagName(field), self.uncommitted_frame });
            self.uncommitted_frame.record(field, instant);
        }

        pub fn commitRecord(self: *Self) void {
            const uncomitted = self.uncommitted_frame;
            if (uncomitted.commit()) |commit_frame| {
                self.uncommitted_frame = .{ .prev_end = commit_frame.frame_end };
                if (self.frames.full) {
                    self.frames.deleteOldest(1);
                }
                self.frames.appendAssumeCapacity(commit_frame);
            } else {
                self.uncommitted_frame = .{ .prev_end = self.uncommitted_frame.frame_end };
            }
        }

        pub fn draw(self: *Self, open: bool) void {
            if (!open) return;
            const len = self.frames.len();
            if (len == 0) {
                cimgui.c.ImGui_Text("No frame times recorded yet.");
                return;
            }
            const slice = self.frames.getPtrSlice(0, len);
            var data: [capacity]f32 = undefined;
            var sum_total: f32 = 0.0;
            var sum_active: f32 = 0.0;
            var sum_cpu: f32 = 0.0;
            var sum_gpu: f32 = 0.0;
            var sum_idle: f32 = 0.0;
            for (slice[0], 0..) |frame, i| {
                data[i] = frame.totalRenderTimeMs();
                sum_total += frame.totalRenderTimeMs();
                sum_active += frame.activeTimeMs();
                sum_cpu += frame.cpuFrameTimeMs();
                sum_gpu += frame.gpuWaitTimeMs();
                sum_idle += frame.preRenderTimeMs();
            }
            for (slice[1], slice[0].len..) |frame, i| {
                data[i] = frame.totalRenderTimeMs();
                sum_total += frame.totalRenderTimeMs();
                sum_active += frame.activeTimeMs();
                sum_cpu += frame.cpuFrameTimeMs();
                sum_gpu += frame.gpuWaitTimeMs();
                sum_idle += frame.preRenderTimeMs();
            }

            const len_f32: f32 = @floatFromInt(len);
            const duration_ns: f32 = @floatFromInt(self.frames.first().?.frame_start.durationTo(self.frames.last().?.frame_end).toNanoseconds());
            const avg_fps = 1e9 * (len_f32 - 1.0) / duration_ns;

            cimgui.c.ImGui_SeparatorText("Performance");
            cimgui.c.ImGui_PlotLines("Frame Times", @ptrCast(&data), @intCast(len));
            cimgui.c.ImGui_Text("Average FPS: %3g", avg_fps);
            cimgui.c.ImGui_Text("Average Total Frame Time: %3g ms", sum_total / len_f32);
            cimgui.c.ImGui_Text("Average Idle Time: %3g ms", sum_idle / len_f32);
            cimgui.c.ImGui_Text("Average Active (CPU+GPU) Time: %3g ms", sum_active / len_f32);
            cimgui.c.ImGui_Text("Average CPU Time: %3g ms", sum_cpu / len_f32);
            cimgui.c.ImGui_Text("Average GPU Wait Time: %3g ms", sum_cpu / len_f32);
            cimgui.c.ImGui_Text("Last Total Frame Time: %3g ms", self.frames.last().?.totalRenderTimeMs());
            cimgui.c.ImGui_Text("Last Idle Time: %3g ms", self.frames.last().?.preRenderTimeMs());
            cimgui.c.ImGui_Text("Last Active Time: %3g ms", self.frames.last().?.activeTimeMs());
            cimgui.c.ImGui_Text("Last CPU Time: %3g ms", self.frames.last().?.cpuFrameTimeMs());
            cimgui.c.ImGui_Text("Last GPU Wait Time: %3g ms", self.frames.last().?.gpuWaitTimeMs());
            cimgui.c.ImGui_Text("Last Input Latency: %3g ms", self.frames.last().?.inputLatencyMs() orelse 0.0);
        }
    };
}
pub const FrameTimes = FrameHistory(256);
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
