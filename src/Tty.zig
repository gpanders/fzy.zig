const std = @import("std");
const builtin = @import("builtin");
const system = std.os.system;

const libc = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

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
    std.os.tcsetattr(self.fdin, std.os.TCSA.NOW, self.original_termios) catch unreachable;
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
    new_termios.iflag &= ~(@as(@TypeOf(new_termios.iflag), system.ICRNL));
    new_termios.lflag &= ~(@as(@TypeOf(new_termios.lflag), (system.ICANON | system.ECHO | system.ISIG)));

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
    var ws: system.winsize = undefined;
    if (system.ioctl(self.fout.handle, system.T.IOCGWINSZ, &ws) == -1) {
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

fn sgr(self: *Tty, code: i32) void {
    self.printf("\x1b[{d}m", .{code});
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

pub fn inputReady(self: *Tty, timeout: ?isize, return_on_signal: bool) !bool {
    var ts = if (timeout) |t| &std.os.timespec{
        .tv_sec = @divTrunc(t, 1000),
        .tv_nsec = @rem(t, 1000) * 1000000,
    } else null;

    switch (builtin.os.tag) {
        .macos, .freebsd, .netbsd, .dragonfly => {
            var kq = try std.os.kqueue();
            defer std.os.close(kq);
            var evlist: [2]std.os.Kevent = undefined;
            var chlist = try std.BoundedArray(std.os.Kevent, 2).init(0);
            chlist.append(.{
                .ident = @intCast(usize, self.fdin),
                .filter = std.os.system.EVFILT_READ,
                .flags = std.os.system.EV_ADD,
                .fflags = std.os.system.NOTE_LOWAT,
                .data = 1,
                .udata = 0,
            }) catch unreachable;
            if (return_on_signal) {
                chlist.append(.{
                    .ident = std.os.SIG.WINCH,
                    .filter = std.os.system.EVFILT_SIGNAL,
                    .flags = std.os.system.EV_ADD | std.os.system.EV_ONESHOT | std.os.system.EV_CLEAR,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                }) catch unreachable;
            }
            _ = try std.os.kevent(kq, chlist.slice(), &evlist, ts);
            for (evlist) |ev| {
                if (ev.filter == std.os.system.EVFILT_READ) {
                    if (ev.flags & std.os.system.EV_ERROR != 0) {
                        std.debug.print("kevent error: {s}\n", .{@tagName(std.os.errno(ev.data))});
                        std.process.exit(1);
                    } else {
                        return true;
                    }
                }
            }
            return false;
        },
        .linux => {
            // TODO
        },
        else => unreachable,
    }

    return false;
}
