const std = @import("std");
const testing = std.testing;

pub const Stage = enum(u3) {
    orientation,
    conceptual,
    technical,
    reconstruction,
    repair,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const name = @tagName(self);
        try writer.print("{c}{s}", .{ std.ascii.toUpper(name[0]), name[1..] });
    }

    pub fn formatPadded(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const name = @tagName(self);
        for (0..14 - name.len) |_| try writer.writeByte(' ');
        try writer.print("{c}{s}", .{ std.ascii.toUpper(name[0]), name[1..] });
    }
};

pub const Lecture = struct {
    title: []const u8,
    stage: Stage,

    const Self = @This();

    pub fn new(title: []const u8) Self {
        return .{ .title = title, .stage = .orientation };
    }

    const ProgressError = error{NoNextStage};
    pub fn progress(self: *Self) ProgressError!void {
        self.stage = std.enums.fromInt(Stage, @intFromEnum(self.stage) + 1) orelse
            return error.NoNextStage;
    }

    pub fn formatHuman(
        self: Self,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f} — {s}", .{
            std.fmt.Alt(Stage, Stage.formatPadded){ .data = self.stage },
            self.title,
        });
    }

    pub fn format(
        self: Self,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{d};{s}", .{ @intFromEnum(self.stage), self.title });
    }

    pub const FromStringError = error{
        MalformedInput,
        MalformedStage,
        InvalidStage,
        MissingTitle,
    };
    /// The returned Lecture borrows the name, and is only valid while the raw string
    /// input is valid.
    pub fn fromString(raw: []const u8) FromStringError!Self {
        const semicolon_index = std.mem.findScalar(u8, raw, ';') orelse {
            return error.MalformedInput;
        };

        const stage_int = std.fmt.parseInt(u3, raw[0..semicolon_index], 10) catch {
            return error.MalformedStage;
        };

        const stage = std.enums.fromInt(Stage, stage_int) orelse {
            return error.InvalidStage;
        };

        if (raw.len == semicolon_index + 1) return error.MissingTitle;

        const title = raw[semicolon_index + 1 ..];

        return .{
            .title = title,
            .stage = stage,
        };
    }

    pub fn compareFn(context: void, a: Self, b: Self) std.math.Order {
        _ = context;
        const a_val = @intFromEnum(a.stage);
        const b_val = @intFromEnum(b.stage);

        return if (a_val > b_val) .lt else if (a_val < b_val) .gt else .eq;
    }
};

test "Lecture from valid string" {
    const raw = "3;Software Testing";
    const expected: Lecture = .{
        .title = "Software Testing",
        .stage = .reconstruction,
    };
    const actual: Lecture = try .fromString(raw);

    try testing.expectEqualDeep(expected, actual);
}

test "Lecture fmt + fromString round trip" {
    const expected: Lecture = .{
        .title = "Software Testing",
        .stage = .reconstruction,
    };
    const raw = try std.fmt.allocPrint(testing.allocator, "{f}", .{expected});
    defer testing.allocator.free(raw);
    const actual: Lecture = try .fromString(raw);

    try testing.expectEqualDeep(expected, actual);
}

test "Malformed input error" {
    const raw = "3,Software Testing";
    const expected = Lecture.FromStringError.MalformedInput;
    const actual = Lecture.fromString(raw);

    try testing.expectError(expected, actual);
}

test "Malformed stage error" {
    const raw = "Four;Software Testing";
    const expected = Lecture.FromStringError.MalformedStage;
    const actual = Lecture.fromString(raw);

    try testing.expectError(expected, actual);
}

test "Invalid Stage" {
    const raw = "7;Software Testing";
    const expected = Lecture.FromStringError.InvalidStage;
    const actual = Lecture.fromString(raw);

    try testing.expectError(expected, actual);
}

test "Missing Title" {
    const raw = "4;";
    const expected = Lecture.FromStringError.MissingTitle;
    const actual = Lecture.fromString(raw);

    try testing.expectError(expected, actual);
}
