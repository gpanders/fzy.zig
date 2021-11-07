const std = @import("std");
const stdout = std.io.getStdOut().writer();

const Options = @import("options.zig");
const Choices = @import("choices.zig");
const Tty = @import("tty.zig");
const TtyInterface = @import("tty/interface.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.print("Leaks were found\n", .{});
    };
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();

    var allocator = &gpa.allocator;

    var options = try Options.new();
    var choices = try Choices.init(allocator, options);
    defer choices.deinit();

    if (options.benchmark > 0) {
        if (options.filter) |filter| {
            try choices.read(options.input_delimiter);
            var i: usize = 0;
            while (i < options.benchmark) : (i += 1) {
                try choices.search(filter);
            }
        } else {
            std.debug.print("Must specify -e/--show-matches with --benchmark\n", .{});
            std.process.exit(1);
        }
    } else if (options.filter) |filter| {
        try choices.read(options.input_delimiter);
        try choices.search(filter);
        for (choices.results.items) |result| {
            if (options.show_scores) {
                stdout.print("{}\t", .{ result.score }) catch unreachable;
            }
            stdout.print("{s}\n", .{ result.str }) catch unreachable;
        }
    } else {
        if (std.io.getStdIn().isTty()) {
            try choices.read(options.input_delimiter);
        }

        var tty = try Tty.init(options.tty_filename);

        if (!std.io.getStdIn().isTty()) {
            try choices.read(options.input_delimiter);
        }

        if (options.num_lines > choices.size()) {
            options.num_lines = choices.size();
        }

        const num_lines_adjustment = if (options.show_info) 2 else 1;
        if (options.num_lines + num_lines_adjustment > tty.max_height) {
            options.num_lines = tty.max_height - num_lines_adjustment;
        }

        var tty_interface = TtyInterface.init(&tty, &choices, &options);
        return tty_interface.run();
    }
}
