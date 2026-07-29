const std = @import("std");
const process = std.process;
const mem = std.mem;
const Dir = std.Io.Dir;
const fatal = process.fatal;
const builtin = @import("builtin");

const study = @import("study");
const Lecture = study.Lecture;

const PriorityQueue = std.PriorityQueue(Lecture, void, Lecture.compareFn);
const InactiveQueue = std.ArrayList(Lecture);

const Queue = union(enum) {
    priority: *PriorityQueue,
    inactive: *InactiveQueue,

    pub fn isEmpty(self: @This()) bool {
        return switch (self) {
            .priority => |q| q.count() == 0,
            .inactive => |q| q.items.len == 0,
        };
    }
};

const current_filename = "current.txt";
const upcoming_filename = "upcoming.txt";
const inactive_filename = "inactive.txt";

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args_iter = try init.minimal.args.iterateAllocator(arena);

    var buf_stdout: [1024]u8 = undefined;
    var writer_stdout: std.Io.File.Writer = .init(.stdout(), io, &buf_stdout);
    const stdout = &writer_stdout.interface;

    const cmd = try parseCommand(&args_iter);

    const data_path = try dataPathCreateIfAbsent(arena, io, init.environ_map);
    const data_dir = try Dir.openDirAbsolute(io, data_path, .{});
    defer data_dir.close(io);

    // Handle the command
    blk: switch (cmd) {
        .help => try stdout.writeAll(help_text),
        .stages => try stdout.writeAll(stages_text),
        .queue => {
            var current_queue = try getQueue(arena, io, data_dir, current_filename);
            var upcoming_queue = try getQueue(arena, io, data_dir, upcoming_filename);
            var inactive_queue = try getInactive(arena, io, data_dir);

            const fresh_lecture: bool = for (upcoming_queue.items) |lecture| {
                if (lecture.stage == .orientation) break true;
            } else false;

            var current_dirty = false;
            var upcoming_dirty = false;
            var inactive_dirty = false;

            if (!fresh_lecture and inactive_queue.items.len > 0) {
                try upcoming_queue.push(arena, inactive_queue.orderedRemove(0));

                upcoming_dirty = true;
                inactive_dirty = true;
            }

            if (current_queue.count() == 0) {
                while (upcoming_queue.pop()) |lecture| {
                    try current_queue.push(arena, lecture);
                }

                current_dirty = true;
                upcoming_dirty = true;
            }

            for (
                [_]Queue{
                    .{ .priority = &current_queue },
                    .{ .priority = &upcoming_queue },
                    .{ .inactive = &inactive_queue },
                },
                [_][]const u8{ current_filename, upcoming_filename, inactive_filename },
                [_][]const u8{ "Current", "Upcoming", "Inactive" },
                [_]bool{ current_dirty, upcoming_dirty, inactive_dirty },
            ) |queue, filename, name, dirty| {
                if (dirty) try fileWriteQueue(io, data_dir, filename, queue);

                try stdout.print("{s} queue:\n\n", .{name});
                if (queue.isEmpty())
                    try stdout.writeAll("\tEmpty!\n")
                else
                    try printQueue(stdout, queue);
                try stdout.writeAll("\n");
            }
        },
        .new => {
            const title = args_iter.next() orelse
                fatal("\"{t}\" command issued, but missing \"title\" field.", .{cmd});

            const lecture: Lecture = .new(title);

            const current_queue = try getQueue(arena, io, data_dir, current_filename);
            const upcoming_queue = try getQueue(arena, io, data_dir, upcoming_filename);
            var inactive_queue = try getInactive(arena, io, data_dir);

            for ([_][]Lecture{
                current_queue.items,
                upcoming_queue.items,
                inactive_queue.items,
            }) |queued_lectures| {
                for (queued_lectures) |queued| {
                    if (std.mem.eql(u8, queued.title, lecture.title)) {
                        try stdout.print(
                            "Lecture {s} is already in the current queue.\n\n",
                            .{lecture.title},
                        );
                        continue :blk .queue;
                    }
                }
            }

            try inactive_queue.append(arena, lecture);

            try fileWriteQueue(
                io,
                data_dir,
                inactive_filename,
                .{ .inactive = &inactive_queue },
            );

            try stdout.print(
                "Added lecture {s} at stage {f}.\n\n",
                .{ lecture.title, lecture.stage },
            );

            continue :blk .queue;
        },
        .pop => {
            var current_queue = try getQueue(arena, io, data_dir, current_filename);
            var upcoming_queue = try getQueue(arena, io, data_dir, upcoming_filename);

            var lecture = current_queue.pop() orelse {
                try stdout.print("Nothing to pop!\n\n", .{});
                continue :blk .queue;
            };
            try fileWriteQueue(
                io,
                data_dir,
                current_filename,
                .{ .priority = &current_queue },
            );

            try stdout.print(
                "Updated lecture {s} from {f} to ",
                .{ lecture.title, lecture.stage },
            );
            if (lecture.progress()) |_| {
                try stdout.print("{f}", .{lecture.stage});

                try upcoming_queue.push(arena, lecture);
            } else |_| {
                try stdout.writeAll("Finished");
            }

            try fileWriteQueue(
                io,
                data_dir,
                upcoming_filename,
                .{ .priority = &upcoming_queue },
            );
            try stdout.writeAll(".\n\n");
            continue :blk .queue;
        },
        .edit => {
            const current_file = try Dir.path.join(
                arena,
                &.{ data_path, current_filename },
            );
            const upcoming_file = try Dir.path.join(
                arena,
                &.{ data_path, upcoming_filename },
            );
            const inactive_file = try Dir.path.join(
                arena,
                &.{ data_path, inactive_filename },
            );

            if (builtin.os.tag == .windows) {
                try stdout.print(
                    \\Open these files in your editor:
                    \\  {s}
                    \\  {s}
                    \\  {s}
                    \\
                , .{ current_file, upcoming_file, inactive_file });
                break :blk;
            }

            const editor = init.environ_map.get("VISUAL") orelse
                init.environ_map.get("EDITOR") orelse
                switch (builtin.os.tag) {
                    .windows => "notepad.exe",
                    else => fatal(
                        "$VISUAL or $EDITOR environment variable not set.",
                        .{},
                    ),
                };

            var proc = try process.spawn(io, .{
                .argv = &.{
                    editor, current_file, upcoming_file, inactive_file,
                },
            });
            _ = try proc.wait(io);

            continue :blk .queue;
        },
    }
    try stdout.flush();
}

fn fileWriteQueue(
    io: std.Io,
    dir: Dir,
    filename: []const u8,
    queue: Queue,
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

    const items = switch (queue) {
        inline else => |q| q.items,
    };

    for (items) |lecture| {
        try file.print("{f}\n", .{lecture});
    }
    try file.flush();

    try atomic_file.replace(io);
}

fn printQueue(
    writer: *std.Io.Writer,
    queue: Queue,
) !void {
    switch (queue) {
        .priority => |q| {
            while (q.pop()) |lecture|
                try writer.print("  {f}\n", .{std.fmt.alt(lecture, .formatHuman)});
        },
        .inactive => |q| {
            for (q.items) |lecture|
                try writer.print("  {f}\n", .{std.fmt.alt(lecture, .formatHuman)});
        },
    }
    try writer.flush();
}

fn getQueue(
    gpa: mem.Allocator,
    io: std.Io,
    dir: Dir,
    filename: []const u8,
) !PriorityQueue {
    const raw = dir.readFileAlloc(io, filename, gpa, .unlimited) catch |err|
        switch (err) {
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

fn getInactive(gpa: mem.Allocator, io: std.Io, dir: Dir) !InactiveQueue {
    const raw = dir.readFileAlloc(
        io,
        inactive_filename,
        gpa,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var queue: InactiveQueue = .empty;
    if (raw) |str| {
        var iter = std.mem.tokenizeScalar(u8, str, '\n');
        while (iter.next()) |line| try queue.append(gpa, try .fromString(line));
    }

    return queue;
}

fn dataPathCreateIfAbsent(
    gpa: mem.Allocator,
    io: std.Io,
    env: *const process.Environ.Map,
) ![]const u8 {
    const base_data_dir_path = dataHome(gpa, env) catch |err|
        if (builtin.os.tag == .windows) {
            fatal("Could not determine user data directory.", .{});
        } else {
            switch (err) {
                error.DataHomeNotSet => {
                    fatal("Could not determine user data directory.", .{});
                },
                else => return err,
            }
        };
    const base_data_dir = try Dir.openDirAbsolute(io, base_data_dir_path, .{});
    defer base_data_dir.close(io);

    base_data_dir.createDirPath(io, "study") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return Dir.path.join(gpa, &.{ base_data_dir_path, "study" });
}

fn dataHome(gpa: mem.Allocator, env: *const process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const local_app_data = env.get("LOCALAPPDATA") orelse
            return error.DataHomeNotSet;

        if (local_app_data.len == 0 or !Dir.path.isAbsolute(local_app_data))
            return error.DataHomeNotSet;

        return local_app_data;
    }

    if (env.get("XDG_DATA_HOME")) |path|
        if (path.len != 0 and Dir.path.isAbsolute(path)) return path;

    const home = env.get("HOME") orelse return error.DataHomeNotSet;
    if (home.len == 0)
        return error.DataHomeNotSet;

    return try Dir.path.join(gpa, &.{ home, ".local", "share" });
}

fn parseCommand(args_iter: *process.Args.Iterator) !Command {
    _ = args_iter.skip();

    const cmd_string = args_iter.next();
    return if (cmd_string) |str| command_map.get(str) orelse {
        fatal("\"{s}\" is not a valid command, try \"help\" instead.", .{str});
    } else .help;
}

const command_map: std.StaticStringMap(Command) = .initComptime(.{
    .{ "h", .help },    .{ "help", .help },
    .{ "-h", .help },   .{ "--help", .help },

    .{ "q", .queue },   .{ "queue", .queue },
    .{ "-q", .queue },  .{ "--queue", .queue },

    .{ "p", .pop },     .{ "pop", .pop },
    .{ "-p", .pop },    .{ "--pop", .pop },

    .{ "n", .new },     .{ "new", .new },
    .{ "-n", .new },    .{ "--new", .new },

    .{ "e", .edit },    .{ "edit", .edit },
    .{ "-e", .edit },   .{ "--edit", .edit },

    .{ "s", .stages },  .{ "stages", .stages },
    .{ "-s", .stages }, .{ "--stages", .stages },
});

const Command = enum {
    help,
    stages,
    queue,
    pop,
    new,
    edit,
};

const help_text =
    \\Usage: study COMMAND [title]
    \\
    \\Available commands:
    \\        h[elp]   - Display this help text.
    \\        s[tages] - Learn what the stages actually are.
    \\        q[ueue]  - Show the current queue of lectures.
    \\        p[op]    - Mark the first lecture in the queue as complete, advancing it
    \\                   to the next stage, or clearing it out of the queue if there is
    \\                   no next stage.
    \\        n[ew]    - Add a new lecture to the queue. This requires the title field.
    \\                   The lecture will start at the orientation stage.
    \\        e[dit]   - Edit the queue files directly (or output their file names
    \\                   on Windows).
    \\
;

const stages_text =
    \\Orientation:    Get a first overview. What questions does the lecture want to answer,
    \\                and roughly how?
    \\
    \\Conceptual:     Create a structural map of the objects of the lecture. Is there some
    \\                hierarchy? How do ideas depend on each other? Get a first, conceptual
    \\                understanding of the pieces, to form some level of intuition and
    \\                familiarity.
    \\
    \\Technical:      Study the material in full depth. Learn derivations and proofs,
    \\                terminology, details, etc.
    \\
    \\Reconstruction: Without the material in front of you, try to reconstruct it from
    \\                memory, in as much detail as possible, to test your understanding,
    \\                and check where you went wrong.
    \\
    \\Repair:         Use the output from the previous stage to fix the misunderstandings
    \\                and gaps that led to the mistakes you made.
    \\
;
