const std = @import("std");

const Tty = @This();

pub const COLOR_BLACK = 0;
pub const COLOR_RED = 1;
pub const COLOR_GREEN = 2;
pub const COLOR_YELLOW = 3;
pub const COLOR_BLUE = 4;
pub const COLOR_MAGENTA = 5;
pub const COLOR_CYAN = 6;
pub const COLOR_WHITE = 7;
pub const COLOR_NORMAL = 9;

fdin: i32,
fout: *std.fs.File,
buffered_writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
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
    const fdin = try std.os.open(filename, std.os.O.RDONLY, 0);
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

    const act = std.os.Sigaction{ .handler = .{ .sigaction = std.os.SIG.IGN }, .mask = std.os.empty_sigset, .flags = 0 };
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

pub fn setFg(self: *Tty, fg: i32) void {
    if (self.fg_color != fg) {
        self.sgr(30 + fg);
        self.fg_color = 30;
    }
}

pub fn setInvert(self: *Tty) void {
    self.sgr(7);
}

pub fn setUnderline(self: *Tty) void {
    self.sgr(4);
}

pub fn setNormal(self: *Tty) void {
    self.sgr(0);
    self.fg_color = COLOR_NORMAL;
}

pub fn setWrap(self: *Tty, wrap: bool) void {
    var c: u8 = if (wrap) 'h' else 'l';
    self.printf("\x1b[?7{c}", .{c});
}

pub fn newline(self: *Tty) void {
    self.printf("\x1b[K\n", .{});
}

pub fn clearLine(self: *Tty) void {
    self.printf("\x1b[K", .{});
}

pub fn setCol(self: *Tty, col: usize) void {
    self.printf("\x1b[{d}G", .{col + 1});
}

pub fn moveUp(self: *Tty, i: usize) void {
    self.printf("\x1b[{d}A", .{i});
}

pub fn putc(self: *Tty, c: u8) void {
    self.buffered_writer.writer().writeByte(c) catch unreachable;
}

pub fn flush(self: *Tty) void {
    self.buffered_writer.flush() catch unreachable;
}

pub fn getChar(self: *Tty) !u8 {
    var c: [1]u8 = undefined;
    if (std.os.read(self.fdin, &c)) |bytes_read| {
        if (bytes_read == 0) {
            // EOF
            return error.EndOfFile;
        }
        return c[0];
    } else |err| {
        std.log.err("error reading from tty", .{});
        return err;
    }
}

pub fn inputReady(self: *Tty, timeout: isize, return_on_signal: bool) !bool {
    var fds = [_]std.os.pollfd{.{ .fd = self.fdin, .events = std.os.POLL.IN, .revents = 0 }};
    var ts = std.os.timespec{
        .tv_sec = @divTrunc(timeout, 1000),
        .tv_nsec = @rem(timeout, 1000) * 1000000,
    };

    var mask = std.os.empty_sigset;
    if (!return_on_signal) {
        std.c.sigaddset(&mask, std.os.SIG.WINCH);
    }

    if (std.os.ppoll(&fds, &ts, &mask)) |rc| {
        return rc > 0;
    } else |err| switch (err) {
        error.SignalInterrupt => return false,
        else => return err,
    }
}

fn sgr(self: *Tty, code: i32) void {
    self.printf("\x1b[{d}m", .{code});
}
