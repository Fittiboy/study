const std = @import("std");
const testing = std.testing;

pub const Lecture = @import("lecture.zig");
pub const Stage = Lecture.Stage;
pub const Queues = @import("queues.zig");

test {
    _ = std.testing.refAllDecls(@This());
}
