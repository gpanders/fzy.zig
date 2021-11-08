const std = @import("std");

const Tty = @import("../tty.zig");
const Choices = @import("../choices.zig");
const Options = @import("../options.zig");
const match = @import("../match.zig");

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

search: [SEARCH_SIZE_MAX]u8 = undefined,
last_search: [SEARCH_SIZE_MAX]u8 = undefined,
cursor: usize = 0,

ambiguous_key_pending: bool = false,
input: [32]u8 = undefined,

exit: i32 = -1,

pub fn init(allocator: *std.mem.Allocator, tty: *Tty, choices: *Choices, options: *Options) !TtyInterface {
    var self = TtyInterface{
        .allocator = allocator,
        .tty = tty,
        .choices = choices,
        .options = options,
    };

    std.mem.copy(u8, &self.input, "");
    std.mem.copy(u8, &self.last_search, "");

    if (options.init_search) |q| {
        std.mem.copy(u8, &self.search, q);
    } else {
        std.mem.copy(u8, &self.search, "");
    }

    self.cursor = self.search.len;

    try self.update();

    return self;
}

pub fn run(self: *TtyInterface) !i32 {
    try self.draw();
    while (true) {
        while (true) {
            while (!(try self.tty.inputReady(-1, true))) {
                try self.draw();
            }

            var s = try self.tty.getChar();
            self.handleInput(&[_]u8{s}, false);

            if (self.exit >= 0) {
                return self.exit;
            }

            try self.draw();

            if (!(try self.tty.inputReady(if (self.ambiguous_key_pending) config.KEYTIMEOUT else 0, false))) {
                break;
            }
        }

        if (self.ambiguous_key_pending) {
            self.handleInput("", true);
            if (self.exit >= 0) {
                return self.exit;
            }
        }

        try self.update();
    }

    return self.exit;
}

fn update(self: *TtyInterface) !void {
    try self.choices.search(&self.search);
    std.mem.copy(u8, &self.last_search, &self.search);
}

fn appendSearch(self: *TtyInterface, c: u8) void {
    var search = self.search;
    if (search.len < SEARCH_SIZE_MAX) {
        std.mem.copyBackwards(u8, search[self.cursor+1..], search[self.cursor..]);
        search[self.cursor] = c;
        self.cursor += 1;
    }
}

fn draw(self: *TtyInterface) !void {
    var tty = self.tty;
    var choices = self.choices;
    var options = self.options;
    var num_lines = options.num_lines;
    var start: usize = 0;
    var num_choices = choices.size();
    var available = choices.results.items.len;
    var current_selection = choices.selection;
    if (current_selection + options.scrolloff >= num_lines) {
        start = current_selection + options.scrolloff - num_lines + 1;
        if (start + num_lines >= available and available > 0) {
            start = available - num_lines;
        }
    }

    tty.setCol(0);
    tty.printf("{s}{s}", .{ options.prompt, self.search });
    tty.clearLine();

    if (options.show_info) {
        tty.printf("\n[{d}/{d}]", .{ available, num_choices });
        tty.clearLine();
    }

    var i: usize = start;
    while (i < start + num_lines) : (i += 1) {
        tty.printf("\n", .{});
        tty.clearLine();
        if (i < num_choices) {
            const choice = choices.strings.items[i];
            self.drawMatch(choice, i == current_selection);
        }
    }

    if (num_lines > 0 or options.show_info) {
        tty.moveUp(num_lines + @boolToInt(options.show_info));
    }

    tty.setCol(0);
    _ = try tty.buffered_writer.writer().write(options.prompt);
    i = 0;
    while (i < self.cursor) : (i += 1) {
        _ = try tty.buffered_writer.writer().writeByte(self.search[i]);
    }
    tty.flush();
}

fn drawMatch(self: *TtyInterface, choice: []const u8, selected: bool) void {
    var tty = self.tty;
    var options = self.options;
    var search = self.search;
    var n = search.len;
    var positions: [match.MAX_LEN]isize = undefined;
    var i: usize = 0;
    while (i < n + 1 and i < match.MAX_LEN) : (i += 1) {
        positions[i] = -1;
    }

    var score = match.matchPositions(self.allocator, &search, choice, &positions);

    if (options.show_scores) {
        if (score == match.SCORE_MIN) {
            tty.printf("(     ) ", .{});
        } else {
            tty.printf("({:5.2}) ", .{score});
        }
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

const Action = struct {
    fn exit(_: *TtyInterface) void {}
};

const KeyBinding = struct {
    key: []const u8,
    action: fn (tty_interface: *TtyInterface) void,
};

fn keyCtrl(key: u8) []const u8 {
    return &[_]u8{key - '@'};
}

const keybindings = [_]KeyBinding{
    .{ "\x1b", Action.exit },
};

fn isPrintOrUnicode(c: u8) bool {
    return std.ascii.isPrint(c) or (c & (1 << 7)) != 0;
}

fn handleInput(self: *TtyInterface, s: []const u8, handle_ambiguous_key: bool) void {
    self.ambiguous_key_pending = false;
    var input = self.input;
    _ = try std.fmt.bufPrint(self.input, "{s}{s}", .{ self.input, s });

    // Figure out if we have completed a keybinding and whether we're in
    // the middle of one (both can happen, because of Esc)
    var found_keybinding: ?KeyBinding = null;
    var in_middle = false;
    for (keybindings) |k| {
        if (std.mem.eql(u8, input, k.key)) {
            found_keybinding = k;
        } else if (std.mem.eql(u8, input, k.key[0..input.len])) {
            in_middle = true;
        }
    }

    // If we have an unambiguous keybinding, run it.
    if (found_keybinding) |keybinding| {
        if (!in_middle or handle_ambiguous_key) {
            keybinding.action(self);
            self.input = "";
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
    for (input) |c| {
        if (isPrintOrUnicode(c)) {
            self.appendSearch(c);
        }
    }

    self.input = "";
}
