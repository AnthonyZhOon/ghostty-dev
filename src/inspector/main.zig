pub const widgets = @import("widgets.zig");
pub const Inspector = @import("Inspector.zig");

pub const KeyEvent = widgets.key.Event;
pub const FrameEvent = widgets.renderer.FrameEvent;
pub const FrameTiming = widgets.renderer.FrameTiming;

test {
    @import("std").testing.refAllDecls(@This());
}
