const std = @import("std");

const study = @import("study");

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    _ = io;

    var args_iter = try init.minimal.args.iterateAllocator(arena);
    _ = args_iter.skip();

    const cmd_string = args_iter.next();
    const cmd: Command = if (cmd_string) |str| command_map.get(str) orelse {
        std.process.fatal("\"{s}\" is not a valid command, try \"help\" instead!", .{str});
    } else .help;

    const name: ?[]const u8 = if (cmd == .new) if (args_iter.next()) |str| str else {
        std.process.fatal("\"{t}\" command issued, but missing \"name\" field", .{cmd});
    } else null;

    std.debug.print("Hello from study!\n", .{});
    std.debug.print("Command: {t}\n", .{cmd});
    if (name) |str| std.debug.print("Lecture name: {s}\n", .{str});

    switch (cmd) {
        .help => std.debug.print("{s}\n", .{help_text}),
        .queue, .pop, .new => {},
    }
}
