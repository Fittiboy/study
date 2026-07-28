const std = @import("std");
const process = std.process;
const fatal = process.fatal;
const mem = std.mem;

const study = @import("study");
const Lecture = study.Lecture;

const PriorityQueue = std.PriorityQueue(Lecture, void, Lecture.compareFn);

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args_iter = try init.minimal.args.iterateAllocator(arena);

    var buf_stdout: [1024]u8 = undefined;
    var writer_stdout: std.Io.File.Writer = .init(.stdout(), io, &buf_stdout);
    const stdout = &writer_stdout.interface;

    const cmd = try parseCommand(&args_iter);
    const name: ?[]const u8 = args_iter.next();
    if (cmd == .new and name == null)
        fatal("\"{t}\" command issued, but missing \"name\" field", .{cmd});

    std.debug.print("Command: {t}\n", .{cmd});
    if (name) |str| std.debug.print("Lecture name: {s}\n", .{str});

    const data_dir = try dataDir(arena, io, init.environ_map);
    defer data_dir.close(io);

    var atomic_file_current = try data_dir.createFileAtomic(io, "current.txt", .{ .replace = true });
    defer atomic_file_current.deinit(io);

    var buf_file_current: [1024]u8 = undefined;
    var writer_current: std.Io.File.Writer = .init(atomic_file_current.file, io, &buf_file_current);
    const current = &writer_current.interface;

    var current_queue = try getQueue(arena, io, data_dir, "current.txt");
    while (current_queue.pop()) |lecture| {
        try stdout.print("{f}\n", .{std.fmt.Alt(Lecture, Lecture.formatHuman){ .data = lecture }});
        try current.print("{f}\n", .{lecture});
    }
    try stdout.flush();
    try current.flush();

    try atomic_file_current.replace(io);

    var atomic_file_next = try data_dir.createFileAtomic(io, "next.txt", .{ .replace = true });
    defer atomic_file_next.deinit(io);

    var buf_file_next: [1024]u8 = undefined;
    var writer_next: std.Io.File.Writer = .init(atomic_file_next.file, io, &buf_file_next);
    const next = &writer_next.interface;

    var next_queue = try getQueue(arena, io, data_dir, "next.txt");
    while (next_queue.pop()) |lecture| {
        try stdout.print("{f}\n", .{std.fmt.Alt(Lecture, Lecture.formatHuman){ .data = lecture }});
        try next.print("{f}\n", .{lecture});
    }
    try stdout.flush();
    try next.flush();

    try atomic_file_next.replace(io);

    // Handle the command
    switch (cmd) {
        .help => try stdout.print("{s}\n", .{help_text}),
        .queue, .pop, .new => {},
    }
    try stdout.flush();
}

fn getQueue(gpa: mem.Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) !PriorityQueue {
    const raw = dir.readFileAlloc(io, filename, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var queue: PriorityQueue = .empty;
    if (raw) |str| {
        var iter = std.mem.tokenizeScalar(u8, str, '\n');
        while (iter.next()) |line| try queue.push(gpa, try .fromString(line));
    }

    return queue;
}

fn dataDir(gpa: mem.Allocator, io: std.Io, env: *const process.Environ.Map) !std.Io.Dir {
    const base_data_dir_path = dataHome(gpa, env) catch |err| switch (err) {
        error.HomeNotSet => fatal("Could not find home directory, $HOME not set.", .{}),
        else => return err,
    };
    const base_data_dir = try std.Io.Dir.openDirAbsolute(io, base_data_dir_path, .{});
    defer base_data_dir.close(io);

    return if (base_data_dir.openDir(io, "study", .{})) |dir| dir else |err| blk: switch (err) {
        error.FileNotFound => {
            try base_data_dir.createDir(io, "study", .default_dir);
            break :blk try base_data_dir.openDir(io, "study", .{});
        },
        else => return err,
    };
}

fn dataHome(gpa: mem.Allocator, env: *const process.Environ.Map) ![]const u8 {
    if (env.get("XDG_DATA_HOME")) |path| {
        if (path.len != 0 and std.fs.path.isAbsolute(path)) return path;
    }

    const home = env.get("HOME") orelse return error.HomeNotSet;
    if (home.len == 0)
        return error.HomeNotSet;

    return try std.fs.path.join(gpa, &.{ home, ".local", "share" });
}

fn parseCommand(args_iter: *process.Args.Iterator) !Command {
    _ = args_iter.skip();

    const cmd_string = args_iter.next();
    return if (cmd_string) |str| command_map.get(str) orelse {
        fatal("\"{s}\" is not a valid command, try \"help\" instead!", .{str});
    } else .help;
}

const command_map: std.StaticStringMap(Command) = .initComptime(.{
    .{ "h", .help },  .{ "help", .help },   .{ "-h", .help },  .{ "--help", .help },

    .{ "q", .queue }, .{ "queue", .queue }, .{ "-q", .queue }, .{ "--queue", .queue },

    .{ "p", .pop },   .{ "pop", .pop },     .{ "-p", .pop },   .{ "--pop", .pop },

    .{ "n", .new },   .{ "new", .new },     .{ "-n", .new },   .{ "--new", .new },
});

const Command = enum {
    help,
    queue,
    pop,
    new,
};

const help_text =
    \\Usage: study COMMAND [name]
    \\
    \\Available commands:
    \\        h[elp]  — Display this help text.
    \\        q[ueue] — Show the current queue of lectures.
    \\        p[op]   — Mark the first lecture in the queue as complete, advancing it
    \\                  to the next stage, or clearing it out of the queue if there is
    \\                  no next stage.
    \\        n[ew]   — Add a new lecture to the queue. This requires the name field.
    \\                  The lecture will start at the orientation stage.
;
