const std = @import("std");
const process = std.process;
const mem = std.mem;
const Dir = std.Io.Dir;
const fatal = process.fatal;
const builtin = @import("builtin");

const study = @import("study");
const Lecture = study.Lecture;
const Queues = study.Queues;
const Queue = Queues.Queue;

const queues_filename = "queues.zon";

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
        .queue => try flushQueues(io, arena, stdout, data_dir),
        .new => {
            const title = args_iter.next() orelse
                fatal("\"{t}\" command issued, but missing \"title\" field.", .{cmd});

            const lecture: Lecture = .new(title);

            var queues = try getQueues(arena, io, data_dir, queues_filename);

            for ([_][]Lecture{
                queues.current.items,
                queues.upcoming.items,
                queues.inactive.items,
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

            try queues.inactive.append(arena, lecture);
            try queues.toFile(io, data_dir, queues_filename);

            try stdout.print(
                "Added lecture {s} at stage {f}.\n\n",
                .{ lecture.title, lecture.stage },
            );

            continue :blk .queue;
        },
        .pop => {
            var queues = try getQueues(arena, io, data_dir, queues_filename);

            var lecture = queues.current.pop() orelse {
                try stdout.print("Nothing to pop!\n\n", .{});
                continue :blk .queue;
            };

            try stdout.print(
                "Updated lecture {s} from {f} to ",
                .{ lecture.title, lecture.stage },
            );

            if (lecture.progress()) |_| {
                try stdout.print("{f}", .{lecture.stage});

                try queues.upcoming.push(arena, lecture);
            } else |_| {
                try stdout.writeAll("Finished");
            }

            try queues.toFile(io, data_dir, queues_filename);

            try stdout.writeAll(".\n\n");
            continue :blk .queue;
        },
        .edit => {
            const file_queues = try Dir.path.join(
                arena,
                &.{ data_path, queues_filename },
            );

            const maybe_editor = if (builtin.os.tag == .windows)
                null
            else
                init.environ_map.get("VISUAL") orelse
                    init.environ_map.get("EDITOR");

            if (maybe_editor) |editor| editor: {
                if (editor.len == 0) break :editor;
                var proc = try process.spawn(io, .{
                    .argv = &.{
                        editor, file_queues,
                    },
                });
                _ = try proc.wait(io);
                continue :blk .queue;
            }

            try stdout.print(
                \\Open this file in your editor:
                \\  {s}
                \\
            , .{file_queues});
        },
    }
    try stdout.flush();
}

fn flushQueues(
    io: std.Io,
    gpa: mem.Allocator,
    writer: *std.Io.Writer,
    data_dir: Dir,
) !void {
    var queues = try getQueues(gpa, io, data_dir, queues_filename);

    var dirty = false;

    const no_current = queues.current.count() == 0;
    const no_upcoming = queues.upcoming.count() == 0;
    var some_inactive = queues.inactive.items.len > 0;

    if (no_current and no_upcoming) {
        if (some_inactive) {
            try queues.current.push(gpa, queues.inactive.orderedRemove(0));
            some_inactive = queues.inactive.items.len > 0;

            dirty = true;
        }
    } else if (no_current) {
        while (queues.upcoming.pop()) |lecture| {
            try queues.current.push(gpa, lecture);
        }

        dirty = true;
    }

    const fresh_lecture: bool = for (queues.upcoming.items) |lecture| {
        if (lecture.stage == .orientation) break true;
    } else false;

    if (!fresh_lecture and some_inactive) {
        try queues.upcoming.push(gpa, queues.inactive.orderedRemove(0));

        dirty = true;
    }

    if (dirty) try queues.toFile(io, data_dir, queues_filename);

    for (
        [_]Queue{
            .{ .priority = &queues.current },
            .{ .priority = &queues.upcoming },
            .{ .inactive = &queues.inactive },
        },
        [_][]const u8{ "Current", "Upcoming", "Inactive" },
    ) |queue, name| {
        try writer.print("{s} queue:\n\n", .{name});
        if (queue.isEmpty())
            try writer.writeAll("\tEmpty!\n")
        else
            try printQueue(writer, queue);
        try writer.writeAll("\n");
    }
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

fn getQueues(
    gpa: mem.Allocator,
    io: std.Io,
    dir: Dir,
    filename: []const u8,
) !Queues {
    const raw = dir.readFileAllocOptions(io, filename, gpa, .unlimited, .@"1", 0) catch |err|
        switch (err) {
            error.FileNotFound => return .empty,
            else => return err,
        };
    return .fromSlice(gpa, raw);
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
