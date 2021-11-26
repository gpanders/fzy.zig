const std = @import("std");
const builtin = @import("builtin");
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const stdin = std.io.getStdIn();

const Options = @import("Options.zig");
const Choices = @import("Choices.zig");
const Tty = @import("Tty.zig");
const TtyInterface = @import("TtyInterface.zig");

pub fn main() anyerror!u8 {
    // Use a GeneralPurposeAllocator in Debug builds and an arena allocator in Release builds
    var gpa: ?std.heap.GeneralPurposeAllocator(.{}) = null;
    var arena: ?std.heap.ArenaAllocator = null;
    var allocator = switch (builtin.mode) {
        .Debug => blk: {
            gpa = .{};
            break :blk &gpa.?.allocator;
        },
        else => blk: {
            arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            break :blk &arena.?.allocator;
        },
    };
    defer {
        if (gpa) |_| _ = gpa.?.deinit();
        if (arena) |_| arena.?.deinit();
    }

    var options = try Options.new();
    var choices = try Choices.init(allocator, options);
    defer choices.deinit();

    var file = if (options.input_file) |f|
        std.fs.cwd().openFile(f, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("Input file {s} not found\n", .{f});
                return 1;
            },
            error.PathAlreadyExists => unreachable,
            else => return err,
        }
    else
        stdin;
    defer if (options.input_file) |_| file.close();

    if (options.benchmark > 0) {
        if (options.filter) |filter| {
            try choices.read(file, options.input_delimiter);
            var i: usize = 0;
            while (i < options.benchmark) : (i += 1) {
                try choices.search(filter);
            }
        } else {
            std.debug.print("Must specify -e/--show-matches with --benchmark\n", .{});
            return 1;
        }
    } else if (options.filter) |filter| {
        try choices.read(file, options.input_delimiter);
        try choices.search(filter);
        for (choices.results.?.items) |result| {
            if (options.show_scores) {
                stdout.print("{}\t", .{result.score}) catch unreachable;
            }
            stdout.print("{s}\n", .{result.str}) catch unreachable;
        }
    } else {
        if (stdin.isTty()) {
            try choices.read(file, options.input_delimiter);
        }

        var tty = try Tty.init(options.tty_filename);

        if (!stdin.isTty()) {
            try choices.read(file, options.input_delimiter);
        }

        if (options.num_lines > choices.numChoices()) {
            options.num_lines = choices.numChoices();
        }

        const num_lines_adjustment: usize = if (options.show_info) 2 else 1;
        if (options.num_lines + num_lines_adjustment > tty.max_height) {
            options.num_lines = tty.max_height - num_lines_adjustment;
        }

        var tty_interface = try TtyInterface.init(allocator, &tty, &choices, &options);
        defer tty_interface.deinit();

        if (tty_interface.run()) |rc| {
            return rc;
        } else |err| return err;
    }

    return 0;
}
