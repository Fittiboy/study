const std = @import("std");

const study = @import("study");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("Hello from study!\n", .{});
}
