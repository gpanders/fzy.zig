const std = @import("std");
const stdout = std.io.getStdOut().writer();

const Tty = @import("Tty.zig");
const Choices = @import("Choices.zig");
const Options = @import("Options.zig");

const match = @import("match.zig");

const config = @cImport({
    @cDefine("COLOR_BLACK", std.fmt.comptimePrint("{d}", .{Tty.COLOR_BLACK}));
    @cDefine("COLOR_RED", std.fmt.comptimePrint("{d}", .{Tty.COLOR_RED}));
    @cDefine("COLOR_GREEN", std.fmt.comptimePrint("{d}", .{Tty.COLOR_GREEN}));
    @cDefine("COLOR_YELLOW", std.fmt.comptimePrint("{d}", .{Tty.COLOR_YELLOW}));
    @cDefine("COLOR_BLUE", std.fmt.comptimePrint("{d}", .{Tty.COLOR_BLUE}));
    @cDefine("COLOR_MAGENTA", std.fmt.comptimePrint("{d}", .{Tty.COLOR_MAGENTA}));
    @cDefine("COLOR_CYAN", std.fmt.comptimePrint("{d}", .{Tty.COLOR_CYAN}));
    @cDefine("COLOR_WHITE", std.fmt.comptimePrint("{d}", .{Tty.COLOR_WHITE}));
    @cInclude("config.h");
});

const TtyInterface = @This();

const SEARCH_SIZE_MAX = 4096;

allocator: *std.mem.Allocator,
tty: *Tty,
choices: *Choices,
options: *Options,

search: std.BoundedArray(u8, SEARCH_SIZE_MAX) = .{ .buffer = undefined },
last_search: std.BoundedArray(u8, SEARCH_SIZE_MAX) = .{ .buffer = undefined },
cursor: usize = 0,

ambiguous_key_pending: bool = false,
input: std.BoundedArray(u8, 32) = .{ .buffer = undefined },

exit: ?u8 = null,

pub fn init(allocator: *std.mem.Allocator, tty: *Tty, choices: *Choices, options: *Options) !TtyInterface {
    var self = TtyInterface{
        .allocator = allocator,
        .tty = tty,
        .choices = choices,
        .options = options,
    };

    if (options.init_search) |q| {
        try self.search.appendSlice(q);
    }

    self.cursor = self.search.len;

    try self.updateSearch();

    return self;
}

pub fn deinit(self: *TtyInterface) void {
    self.tty.deinit();
}

pub fn run(self: *TtyInterface) !u8 {
    try self.draw();
    while (true) {
        while (true) {
            while (!(try self.tty.inputReady(null, true))) {
                try self.draw();
            }

            var s = try self.tty.getChar();
            try self.handleInput(&[_]u8{s}, false);

            if (self.exit) |rc| {
                return rc;
            }

            try self.draw();

            if (!(try self.tty.inputReady(if (self.ambiguous_key_pending) config.KEYTIMEOUT else 0, false))) {
                break;
            }
        }

        if (self.ambiguous_key_pending) {
            try self.handleInput("", true);
            if (self.exit) |rc| {
                return rc;
            }
        }

        try self.update();
    }

    return self.exit orelse unreachable;
}

fn update(self: *TtyInterface) !void {
    if (!std.mem.eql(u8, self.last_search.slice(), self.search.slice())) {
        try self.updateSearch();
        try self.draw();
    }
}

fn updateSearch(self: *TtyInterface) !void {
    try self.choices.search(self.search.constSlice());
    try self.last_search.replaceRange(0, self.last_search.len, self.search.constSlice());
}

fn draw(self: *TtyInterface) !void {
    const tty = self.tty;
    const choices = self.choices;
    const options = self.options;
    const num_lines = options.num_lines;
    var start: usize = 0;
    const available = choices.results.items.len;
    const current_selection = choices.selection;
    if (current_selection + options.scrolloff >= num_lines) {
        start = current_selection + options.scrolloff - num_lines + 1;
        if (start + num_lines >= available and available > 0) {
            start = available - num_lines;
        }
    }

    tty.setCol(0);
    tty.printf("{s}{s}", .{ options.prompt, self.search.constSlice() });
    tty.clearLine();

    if (options.show_info) {
        tty.printf("\n[{d}/{d}]", .{ available, choices.size() });
        tty.clearLine();
    }

    var i: usize = start;
    while (i < start + num_lines) : (i += 1) {
        tty.printf("\n", .{});
        tty.clearLine();
        if (choices.getResult(i)) |result| {
            self.drawMatch(result.str, i == current_selection);
        }
    }

    if (num_lines > 0 or options.show_info) {
        tty.moveUp(num_lines + @boolToInt(options.show_info));
    }

    tty.setCol(0);
    _ = try tty.buffered_writer.writer().write(options.prompt);
    _ = try tty.buffered_writer.writer().write(self.search.slice()[0..self.cursor]);
    tty.flush();
}

fn drawMatch(self: *TtyInterface, choice: []const u8, selected: bool) void {
    const tty = self.tty;
    const options = self.options;
    const search = self.search;
    const n = search.len;
    var positions: [match.MAX_LEN]usize = undefined;
    var i: usize = 0;
    while (i < n + 1 and i < match.MAX_LEN) : (i += 1) {
        positions[i] = std.math.maxInt(usize);
    }

    var score = match.matchPositions(self.allocator, search.constSlice(), choice, &positions);

    if (options.show_scores) {
        if (score == match.SCORE_MIN) {
            tty.printf("(     ) ", .{});
        } else {
            tty.printf("({:5.2}) ", .{score});
        }
    }

    if (self.choices.selections.contains(choice)) {
        tty.setBold();
    }

    if (selected) {
        if (config.TTY_SELECTION_UNDERLINE != 0) {
            tty.setUnderline();
        } else {
            tty.setInvert();
        }
    }

    tty.setWrap(false);
    var p: usize = 0;
    for (choice) |c, k| {
        if (positions[p] == k) {
            tty.setFg(config.TTY_COLOR_HIGHLIGHT);
            p += 1;
        } else {
            tty.setFg(Tty.COLOR_NORMAL);
        }

        if (c == '\n') {
            tty.putc(' ');
        } else {
            tty.putc(c);
        }
    }
    tty.setWrap(true);
    tty.setNormal();
}

fn clear(self: *TtyInterface) void {
    var tty = self.tty;
    tty.setCol(0);
    var line: usize = 0;
    while (line < self.options.num_lines + @as(usize, if (self.options.show_info) 1 else 0)) : (line += 1) {
        tty.newline();
    }
    tty.clearLine();
    if (self.options.num_lines > 0) {
        tty.moveUp(line);
    }
    tty.flush();
}

const Action = struct {
    fn exit(tty_interface: *TtyInterface) !void {
        tty_interface.clear();
        tty_interface.exit = 1;
    }

    fn delChar(tty_interface: *TtyInterface) !void {
        if (tty_interface.cursor == 0) {
            return;
        }

        var search = tty_interface.search.slice();
        while (tty_interface.cursor > 0) {
            tty_interface.cursor -= 1;
            _ = tty_interface.search.orderedRemove(tty_interface.cursor);
            if (isBoundary(search[tty_interface.cursor])) break;
        }
    }

    fn delCharOrExit(tty_interface: *TtyInterface) !void {
        if (tty_interface.cursor < tty_interface.search.len) {
            _ = tty_interface.search.orderedRemove(tty_interface.cursor);
        } else if (tty_interface.search.len == 0) {
            try exit(tty_interface);
        }
    }

    fn delWord(tty_interface: *TtyInterface) !void {
        var search = tty_interface.search.constSlice();
        var i: usize = tty_interface.cursor;
        while (i > 0 and std.ascii.isSpace(search[i - 1])) : (i -= 1) {}
        while (i > 0 and !std.ascii.isSpace(search[i - 1])) : (i -= 1) {}
        tty_interface.search.len = i;
        tty_interface.cursor = i;
    }

    fn delAll(tty_interface: *TtyInterface) !void {
        tty_interface.search.len = 0;
        tty_interface.cursor = 0;
    }

    fn emit(tty_interface: *TtyInterface) !void {
        try tty_interface.update();
        tty_interface.clear();

        const choices = tty_interface.choices;
        if (choices.selections.count() == 0) {
            if (choices.getResult(choices.selection)) |selection| {
                try stdout.print("{s}\n", .{selection.str});
            } else {
                // No match, output the query instead
                try stdout.print("{s}\n", .{tty_interface.search.slice()});
            }
        } else {
            var it = choices.selections.keyIterator();
            while (it.next()) |selection| {
                try stdout.print("{s}\n", .{selection.*});
            }
        }

        tty_interface.exit = 0;
    }

    fn next(tty_interface: *TtyInterface) !void {
        try tty_interface.update();
        tty_interface.choices.next();
    }

    fn prev(tty_interface: *TtyInterface) !void {
        try tty_interface.update();
        tty_interface.choices.prev();
    }

    fn beginning(tty_interface: *TtyInterface) !void {
        tty_interface.cursor = 0;
    }

    fn end(tty_interface: *TtyInterface) !void {
        tty_interface.cursor = tty_interface.search.len;
    }

    fn left(tty_interface: *TtyInterface) !void {
        if (tty_interface.cursor > 0) {
            tty_interface.cursor -= 1;
        }
    }

    fn right(tty_interface: *TtyInterface) !void {
        if (tty_interface.cursor < tty_interface.search.len) {
            tty_interface.cursor += 1;
        }
    }

    fn pageUp(tty_interface: *TtyInterface) !void {
        try tty_interface.update();
        var choices = tty_interface.choices;
        var i: usize = 0;
        while (i < tty_interface.options.num_lines and choices.selection > 0) : (i += 1) {
            choices.next();
        }
    }

    fn pageDown(tty_interface: *TtyInterface) !void {
        try tty_interface.update();
        var choices = tty_interface.choices;
        const available = choices.results.items.len;
        var i: usize = 0;
        while (i < tty_interface.options.num_lines and choices.selection < available - 1) : (i += 1) {
            choices.next();
        }
    }

    fn select(tty_interface: *TtyInterface) !void{
        try tty_interface.update();
        const choices = tty_interface.choices;
        if (choices.getResult(choices.selection)) |selection| {
            if (choices.selections.contains(selection.str)) {
                choices.deselect(selection.str);
            } else {
                try choices.select(selection.str);
            }
            choices.next();
        }
    }

    fn ignore(_: *TtyInterface) !void {}
};

const KeyBinding = struct {
    key: []const u8,
    action: fn (tty_interface: *TtyInterface) anyerror!void,
};

fn keyCtrl(key: u8) []const u8 {
    return &[_]u8{key - '@'};
}

const keybindings = [_]KeyBinding{
    .{ .key = "\x1b", .action = Action.exit }, // ESC
    .{ .key = "\x7f", .action = Action.delChar }, // DEL
    .{ .key = keyCtrl('C'), .action = Action.exit },
    .{ .key = keyCtrl('D'), .action = Action.delCharOrExit },
    .{ .key = keyCtrl('G'), .action = Action.exit },
    .{ .key = keyCtrl('M'), .action = Action.emit },
    .{ .key = keyCtrl('N'), .action = Action.next },
    .{ .key = keyCtrl('T'), .action = Action.select },
    .{ .key = keyCtrl('P'), .action = Action.prev },
    .{ .key = keyCtrl('J'), .action = Action.next },
    .{ .key = keyCtrl('K'), .action = Action.prev },
    .{ .key = keyCtrl('H'), .action = Action.delChar }, // Backspace
    .{ .key = keyCtrl('U'), .action = Action.delAll },
    .{ .key = keyCtrl('W'), .action = Action.delWord },
    .{ .key = keyCtrl('A'), .action = Action.beginning },
    .{ .key = keyCtrl('E'), .action = Action.end },
    .{ .key = keyCtrl('B'), .action = Action.left },
    .{ .key = keyCtrl('F'), .action = Action.right },
    .{ .key = "\x1bOD", .action = Action.left },
    .{ .key = "\x1b[D", .action = Action.left },
    .{ .key = "\x1bOC", .action = Action.right },
    .{ .key = "\x1b[C", .action = Action.right },
    .{ .key = "\x1b[1~", .action = Action.beginning}, // HOME
    .{ .key = "\x1b[H", .action = Action.beginning}, // HOME
    .{ .key = "\x1b[4~", .action = Action.end}, // END
    .{ .key = "\x1b[F", .action = Action.end}, // END
    .{ .key = "\x1bOA", .action = Action.prev}, // UP
    .{ .key = "\x1b[A", .action = Action.prev}, // UP
    .{ .key = "\x1bOB", .action = Action.next}, // DOWN
    .{ .key = "\x1b[B", .action = Action.next}, // DOWN
    .{ .key = "\x1b[5~", .action = Action.pageUp},
    .{ .key = "\x1b[6~", .action = Action.pageDown},
    .{ .key = "\x1b[200~", .action = Action.ignore},
    .{ .key = "\x1b[201~", .action = Action.ignore},
};

fn isPrintOrUnicode(c: u8) bool {
    return std.ascii.isPrint(c) or (c & (1 << 7)) != 0;
}

fn isBoundary(c: u8) bool {
    return (~c & (1 << 7)) != 0 or (c & (1 << 6)) != 0;
}

fn handleInput(self: *TtyInterface, s: []const u8, handle_ambiguous_key: bool) !void {
    self.ambiguous_key_pending = false;
    try self.input.appendSlice(s);

    // Figure out if we have completed a keybinding and whether we're in
    // the middle of one (both can happen, because of Esc)
    var found_keybinding: ?KeyBinding = null;
    var in_middle = false;
    for (keybindings) |k| {
        if (std.mem.eql(u8, self.input.slice(), k.key)) {
            found_keybinding = k;
        } else if (std.mem.startsWith(u8, k.key, self.input.slice())) {
            in_middle = true;
        }
    }

    // If we have an unambiguous keybinding, run it.
    if (found_keybinding) |keybinding| {
        if (!in_middle or handle_ambiguous_key) {
            try keybinding.action(self);
            self.input.len = 0;
            return;
        }
    }

    // We could have a complete keybinding, or could be in the middle of
    // one. We'll need to wait a few milliseconds to find out.
    if (found_keybinding != null and in_middle) {
        self.ambiguous_key_pending = true;
        return;
    }

    // Wait for more if we are in the middle of a keybinding
    if (in_middle) {
        return;
    }

    // No matching keybinding, add to search
    for (self.input.constSlice()) |c| {
        if (isPrintOrUnicode(c)) {
            try self.search.insertSlice(self.cursor, &[_]u8{c});
            self.cursor += 1;
        }
    }

    self.input.len = 0;
}
