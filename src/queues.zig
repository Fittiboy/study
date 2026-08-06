const std = @import("std");
const mem = std.mem;
const zon = std.zon;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const study = @import("root.zig");
const Lecture = study.Lecture;

pub const Queues = @This();

const PriorityQueue = std.PriorityQueue(Lecture, void, Lecture.compareFn);
const InactiveQueue = std.ArrayList(Lecture);

current: PriorityQueue,
upcoming: PriorityQueue,
inactive: InactiveQueue,

pub const empty: Queues = .{
    .current = .empty,
    .inactive = .empty,
    .upcoming = .empty,
};

pub const Queue = union(enum) {
    priority: *PriorityQueue,
    inactive: *InactiveQueue,

    pub fn isEmpty(self: @This()) bool {
        return switch (self) {
            .priority => |q| q.count() == 0,
            .inactive => |q| q.items.len == 0,
        };
    }
};

const RawQueues = struct {
    current: []const Lecture,
    upcoming: []const Lecture,
    inactive: []const Lecture,
};

pub fn fromSlice(
    gpa: mem.Allocator,
    /// The result borrows from this slice,
    /// and therefore cannot exceed its lifetime
    slice: [:0]const u8,
) !Queues {
    const queues_raw = try zon.parse.fromSliceAlloc(
        RawQueues,
        gpa,
        slice,
        null,
        .{},
    );

    var current: PriorityQueue = .empty;
    for (queues_raw.current) |lecture| try current.push(gpa, lecture);
    errdefer current.deinit(gpa);

    var upcoming: PriorityQueue = .empty;
    for (queues_raw.upcoming) |lecture| try upcoming.push(gpa, lecture);
    errdefer upcoming.deinit(gpa);

    var inactive: InactiveQueue = .empty;
    for (queues_raw.inactive) |lecture| try inactive.append(gpa, lecture);
    errdefer inactive.deinit(gpa);

    return .{
        .current = current,
        .upcoming = upcoming,
        .inactive = inactive,
    };
}

pub fn toFile(
    queues: *Queues,
    io: Io,
    dir: Dir,
    filename: []const u8,
) !void {
    var atomic_file = try dir.createFileAtomic(
        io,
        filename,
        .{ .replace = true },
    );
    defer atomic_file.deinit(io);

    var buf_file: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(atomic_file.file, io, &buf_file);
    const file = &writer.interface;

    const queues_raw: RawQueues = .{
        .current = queues.current.items,
        .upcoming = queues.upcoming.items,
        .inactive = queues.inactive.items,
    };

    try zon.stringify.serialize(queues_raw, .{}, file);
    try file.flush();

    try atomic_file.replace(io);
}

pub fn deinit(self: *Queues, gpa: mem.Allocator) void {
    self.current.deinit(gpa);
    self.upcoming.deinit(gpa);
    self.inactive.deinit(gpa);
}
