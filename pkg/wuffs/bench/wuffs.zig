const std = @import("std");
const bench = @import("bench.zig");

pub fn main(init: std.process.Init) !void {
    try bench.run(init, .wuffs);
}
