const std = @import("std");
const testing = std.testing;

pub const Stage = enum(u3) {
    orientation,
    conceptual,
    technical,
    reconstruction,
    repair,
};

pub const Lecture = struct {
    title: []const u8,
    stage: Stage,

    pub fn format(
        self: @This(),
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
    pub fn fromString(raw: []const u8) FromStringError!@This() {
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
