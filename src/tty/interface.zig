const std = @import("std");

const Tty = @import("../tty.zig");
const Choices = @import("../choices.zig");
const Options = @import("../options.zig");

const TtyInterface = @This();

const SEARCH_SIZE_MAX = 4096;

tty: *Tty,
choices: *Choices,
options: *Options,

search: [SEARCH_SIZE_MAX]u8 = undefined,
last_search: [SEARCH_SIZE_MAX]u8 = undefined,
cursor: usize = 0,

ambiguous_key_pending: bool = false,
input: [32]u8 = undefined,

exit: i32 = -1,

pub fn init(tty: *Tty, choices: *Choices, options: *Options) TtyInterface {
    var self = TtyInterface{
        .tty = tty,
        .choices = choices,
        .options = options,
    };

    std.mem.copy(u8, self.input, "");
    std.mem.copy(u8, self.last_search, "");

    if (options.init_search) |q| {
        std.mem.copy(u8, self.search, q);
    } else {
        std.mem.copy(u8, self.search, "");
    }

    self.cursor = self.search.len;

    self.update();

    return self;
}

pub fn run(self: *TtyInterface) i32 {
    return self.exit;
}

fn update(self: *TtyInterface) void {
    self.choices.search(&self.search);
    std.mem.copy(u8, &self.last_search, &self.search);
}
