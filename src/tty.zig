const std = @import("std");

const Tty = @This();

const COLOR_BLACK = 0;
const COLOR_RED = 1;
const COLOR_GREEN = 2;
const COLOR_YELLOW = 3;
const COLOR_BLUE = 4;
const COLOR_MAGENTA = 5;
const COLOR_CYAN = 6;
const COLOR_WHITE = 7;
const COLOR_NORMAL = 9;


fdin: i32,
fout: *std.fs.File,
buffered_writer: anytype,
original_termios: std.os.termios,
fg_color: i32 = 0,
max_width: usize = 0,
max_height: usize = 0,

pub fn reset(self: *Tty) void {
    std.os.tcsetattr(self.fdin, std.os.TCSA.NOW, &self.original_termios);
}

pub fn close(self: *Tty) void {
    self.reset();
    self.fout.close();
    std.os.close(self.fdin);
}

pub fn init(filename: []const u8) !Tty {
    var fdin = try std.os.open(filename, std.os.O.RDONLY, 0);
    errdefer std.os.close(fdin);

    var fout = try std.fs.openFileAbsolute(filename, .{ .read = false, .write = true });
    errdefer fout.close();

    var tty = Tty{
        .fdin = fdin,
        .fout = &fout,
        .buffered_writer = std.io.bufferedWriter(fout.writer()),
        .original_termios = try std.os.tcgetattr(fdin),
    };

    var new_termios = tty.original_termios;
    new_termios.iflag &= ~(@as(@TypeOf(new_termios.iflag), std.c.ICRNL));
    new_termios.lflag &= ~(@as(@TypeOf(new_termios.lflag), (std.c.ICANON | std.c.ECHO | std.c.ISIG)));

    std.os.tcsetattr(tty.fdin, std.os.TCSA.NOW, new_termios) catch {
        std.debug.print("Failed to update termios attributes\n", .{});
    };

    tty.getWinSize();
    tty.setNormal();

    var act = std.os.Sigaction{
        .handler = .{ .sigaction = std.os.SIG.IGN },
        .mask = std.os.empty_sigset,
        .flags = 0
    };
    _ = std.os.sigaction(std.os.SIG.WINCH, &act, null);

    return tty;
}

pub fn getWinSize(self: *Tty) void {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(self.fout.handle, std.c.T.IOCGWINSZ, &ws) == -1) {
        self.max_width = 80;
        self.max_height = 25;
    } else {
        self.max_width = ws.ws_col;
        self.max_height = ws.ws_row;
    }
}

pub fn printf(self: *Tty, comptime format: []const u8, args: anytype) void {
    self.buffered_writer.writer().print(format, args) catch unreachable;
}

pub fn setNormal(self: *Tty) void {
    self.sgr(0);
    self.fg_color = COLOR_NORMAL;
}

fn sgr(self: *Tty, code: i32) void {
    self.printf("{c}{c}{d}m", .{0x1b, '[', code});
}

fn handleSigwinch(_: i32) void {}
