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

    const data_dir = try dataDir(arena, io, init.environ_map);
    defer data_dir.close(io);

    // Handle the command
    blk: switch (cmd) {
        .help => try stdout.print("{s}\n", .{help_text}),
        .queue => {
            var current_queue = try getQueue(arena, io, data_dir, "current.txt");
            var next_queue = try getQueue(arena, io, data_dir, "next.txt");

            if (current_queue.count() == 0) {
                while (next_queue.pop()) |lecture| {
                    try current_queue.push(arena, lecture);
                    if (lecture.stage == .orientation) break;
                }

                try fileWriteQueue(io, data_dir, "current.txt", &current_queue);
                try fileWriteQueue(io, data_dir, "next.txt", &next_queue);

                current_queue = try getQueue(arena, io, data_dir, "current.txt");
                next_queue = try getQueue(arena, io, data_dir, "next.txt");
            }

            try stdout.writeAll("Current queue:\n\n");
            if (current_queue.count() == 0)
                try stdout.writeAll("\tEmpty!\n")
            else
                try printQueue(&current_queue, stdout);

            try stdout.writeAll("\nUpcoming queue:\n\n");
            if (next_queue.count() == 0)
                try stdout.writeAll("\tEmpty!\n")
            else
                try printQueue(&next_queue, stdout);
        },
        .new => {
            const title = args_iter.next() orelse
                fatal("\"{t}\" command issued, but missing \"title\" field.", .{cmd});

            const lecture: Lecture = .new(title);

            const current_queue = try getQueue(arena, io, data_dir, "current.txt");
            for (current_queue.items) |existing| {
                if (std.mem.eql(u8, existing.title, lecture.title)) {
                    try stdout.print("Lecture {s} is already in the current queue.\n\n", .{lecture.title});
                    continue :blk .queue;
                }
            }

            var next_queue = try getQueue(arena, io, data_dir, "next.txt");
            for (next_queue.items) |existing| {
                if (std.mem.eql(u8, existing.title, lecture.title)) {
                    try stdout.print("Lecture {s} is already in the upcoming queue.\n\n", .{lecture.title});
                    continue :blk .queue;
                }
                if (existing.stage == .orientation) {
                    try stdout.writeAll("You should not add more than one fresh lecture at a time!\n\n");
                    continue :blk .queue;
                }
            }
            try next_queue.push(arena, lecture);

            try fileWriteQueue(io, data_dir, "next.txt", &next_queue);

            try stdout.print("Added lecture {s} at stage {f}.\n\n", .{ lecture.title, lecture.stage });

            continue :blk .queue;
        },
        .pop => {
            var current_queue = try getQueue(arena, io, data_dir, "current.txt");
            var next_queue = try getQueue(arena, io, data_dir, "next.txt");

            var lecture = current_queue.pop() orelse {
                try stdout.print("Nothing to pop!\n", .{});
                continue :blk .queue;
            };
            try fileWriteQueue(io, data_dir, "current.txt", &current_queue);

            try stdout.print("Updated lecture {s} from {f} to ", .{ lecture.title, lecture.stage });
            if (lecture.progress()) |_| {
                try stdout.print("{f}", .{lecture.stage});

                try next_queue.push(arena, lecture);
            } else |_| {
                try stdout.writeAll("Finished");
            }

            try fileWriteQueue(io, data_dir, "next.txt", &next_queue);
            try stdout.writeAll(".\n\n");
            continue :blk .queue;
        },
        .edit => {
            const current_file = try data_dir.realPathFileAlloc(io, "current.txt", arena);
            const next_file = try data_dir.realPathFileAlloc(io, "next.txt", arena);

            const editor = init.environ_map.get("EDITOR") orelse {
                process.fatal("$EDITOR environment variable not set.", .{});
            };

            var proc = try std.process.spawn(io, .{ .argv = &.{
                editor, current_file, next_file,
            } });
            _ = try proc.wait(io);

            continue :blk .queue;
        },
    }
    try stdout.flush();
}

fn fileWriteQueue(
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
    queue: *PriorityQueue,
) !void {
    var atomic_file = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic_file.deinit(io);

    var buf_file: [1024]u8 = undefined;
    var writer: std.Io.File.Writer = .init(atomic_file.file, io, &buf_file);
    const file = &writer.interface;

    while (queue.pop()) |lecture| {
        try file.print("{f}\n", .{lecture});
    }
    try file.flush();

    try atomic_file.replace(io);
}

fn printQueue(
    queue: *PriorityQueue,
    writer: *std.Io.Writer,
) !void {
    while (queue.pop()) |lecture| {
        try writer.print("  {f}\n", .{std.fmt.Alt(Lecture, Lecture.formatHuman){ .data = lecture }});
    }
    try writer.flush();
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
        if (path.len != 0 and std.Io.Dir.path.isAbsolute(path)) return path;
    }

    const home = env.get("HOME") orelse return error.HomeNotSet;
    if (home.len == 0)
        return error.HomeNotSet;

    return try std.Io.Dir.path.join(gpa, &.{ home, ".local", "share" });
}

fn parseCommand(args_iter: *process.Args.Iterator) !Command {
    _ = args_iter.skip();

    const cmd_string = args_iter.next();
    return if (cmd_string) |str| command_map.get(str) orelse {
        fatal("\"{s}\" is not a valid command, try \"help\" instead.", .{str});
    } else .help;
}

const command_map: std.StaticStringMap(Command) = .initComptime(.{
    .{ "h", .help },  .{ "help", .help },   .{ "-h", .help },  .{ "--help", .help },

    .{ "q", .queue }, .{ "queue", .queue }, .{ "-q", .queue }, .{ "--queue", .queue },

    .{ "p", .pop },   .{ "pop", .pop },     .{ "-p", .pop },   .{ "--pop", .pop },

    .{ "n", .new },   .{ "new", .new },     .{ "-n", .new },   .{ "--new", .new },

    .{ "e", .edit },  .{ "edit", .edit },   .{ "-e", .edit },  .{ "--edit", .edit },
});

const Command = enum {
    help,
    queue,
    pop,
    new,
    edit,
};

const help_text =
    \\Usage: study COMMAND [title]
    \\
    \\Available commands:
    \\        h[elp]  — Display this help text.
    \\        q[ueue] — Show the current queue of lectures.
    \\        p[op]   — Mark the first lecture in the queue as complete, advancing it
    \\                  to the next stage, or clearing it out of the queue if there is
    \\                  no next stage.
    \\        n[ew]   — Add a new lecture to the queue. This requires the title field.
    \\                  The lecture will start at the orientation stage.
;
