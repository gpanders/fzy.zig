const std = @import("std");
const builtin = @import("builtin");
const system = std.os.system;
const linux = std.os.linux;

const libc = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

const Tty = @This();

const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    normal = 9,
};

fdin: i32,
fout: std.fs.File,
buffered_writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
original_termios: std.os.termios,
fg_color: Color = .normal,
max_width: usize = 0,
max_height: usize = 0,

pub fn reset(self: *Tty) void {
    std.os.tcsetattr(self.fdin, std.os.TCSA.NOW, self.original_termios) catch {
        std.debug.print("Failed to reset termios attributes\n", .{});
    };
}

pub fn init(filename: []const u8) !Tty {
    const fdin = try std.os.open(filename, std.os.O.RDONLY, 0);
    errdefer std.os.close(fdin);

    var fout = try std.fs.openFileAbsolute(filename, .{ .mode = .write_only });
    errdefer fout.close();

    var tty = Tty{
        .fdin = fdin,
        .fout = fout,
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

    try std.os.sigaction(std.os.SIG.WINCH, &std.os.Sigaction{
        .handler = .{ .handler = std.os.SIG.IGN },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    return tty;
}

pub fn deinit(self: *Tty) void {
    self.reset();
    self.fout.close();
    std.os.close(self.fdin);
}

pub fn getWinSize(self: *Tty) void {
    var ws: system.winsize = undefined;
    if (system.ioctl(self.fout.handle, system.T.IOCGWINSZ, @intFromPtr(&ws)) == -1) {
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

pub fn setFg(self: *Tty, fg: Color) void {
    if (self.fg_color != fg) {
        self.sgr(30 + @intFromEnum(fg));
        self.fg_color = fg;
    }
}

pub fn setInvert(self: *Tty) void {
    self.sgr(7);
}

pub fn setUnderline(self: *Tty) void {
    self.sgr(4);
}

pub fn setBold(self: *Tty) void {
    self.sgr(1);
}

pub fn setNormal(self: *Tty) void {
    self.sgr(0);
    self.fg_color = .normal;
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

pub const Events = packed struct(u8) {
    input: bool = false,
    key: bool = false,
    signal: bool = false,
    _: u5 = 0,
};

pub fn waitForEvent(self: *Tty, timeout: ?i32, return_on_signal: bool, input: ?std.fs.File) !Events {
    const ts = if (timeout) |t| &std.os.timespec{
        .tv_sec = @divTrunc(t, 1000),
        .tv_nsec = @rem(t, 1000) * 1000000,
    } else null;

    var events = Events{};
    switch (builtin.os.tag) {
        .macos, .freebsd, .netbsd, .dragonfly => {
            var kq = try std.os.kqueue();
            defer std.os.close(kq);
            var chlist: [2]std.os.Kevent = undefined;
            var nevents: i32 = 1;
            chlist[0] = .{
                .ident = @intCast(self.fdin),
                .filter = system.EVFILT_READ,
                .flags = system.EV_ADD | system.EV_ONESHOT | system.EV_CLEAR,
                .fflags = system.NOTE_LOWAT,
                .data = 1,
                .udata = 0,
            };

            if (input) |in| {
                nevents = 2;
                chlist[1] = .{
                    .ident = @intCast(in.handle),
                    .filter = system.EVFILT_READ,
                    .flags = system.EV_ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
            }

            var evlist: [2]std.os.Kevent = undefined;
            // Call kevent directly rather than using the wrapper in std.os so that we can handle
            // EINTR
            while (true) {
                const rc = system.kevent(kq, &chlist, nevents, &evlist, nevents, ts);
                switch (std.os.errno(rc)) {
                    .SUCCESS => {
                        for (evlist[0..@intCast(rc)]) |ev| {
                            if (ev.flags & system.EV_ERROR != 0) {
                                std.debug.print("kevent error: {s}\n", .{
                                    @tagName(std.os.errno(ev.data)),
                                });
                                return error.InvalidValue;
                            } else if (ev.ident == @as(usize, @intCast(self.fdin))) {
                                events.key = true;
                            } else if (input != null and ev.ident == @as(usize, @intCast(input.?.handle))) {
                                events.input = true;
                            }
                        }
                        break;
                    },
                    .INTR => if (return_on_signal) {
                        events.signal = true;
                        break;
                    } else continue,
                    // Copied from std.os.kevent
                    .ACCES => return error.AccessDenied,
                    .FAULT => unreachable,
                    .BADF => unreachable, // Always a race condition.
                    .INVAL => unreachable,
                    .NOENT => return error.EventNotFound,
                    .NOMEM => return error.SystemResources,
                    .SRCH => return error.ProcessNotFound,
                    else => unreachable,
                }
            }
        },
        .linux => {
            const epfd = try std.os.epoll_create1(0);
            defer std.os.close(epfd);

            var nevents: u32 = 1;
            try std.os.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, self.fdin, &linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = self.fdin },
            });

            if (input) |in| {
                nevents = 2;
                try std.os.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, in.handle, &linux.epoll_event{
                    .events = linux.EPOLL.IN,
                    .data = .{ .fd = in.handle },
                });
            }

            var evs: [2]linux.epoll_event = undefined;
            while (true) {
                const rc = linux.epoll_wait(epfd, &evs, nevents, timeout orelse -1);
                switch (std.os.errno(rc)) {
                    .SUCCESS => {
                        for (evs) |ev| {
                            if (ev.data.fd == self.fdin) {
                                events.key = true;
                            } else if (input != null and ev.data.fd == input.?.handle) {
                                events.input = true;
                            }
                        }
                        break;
                    },
                    .INTR => if (return_on_signal) {
                        events.signal = true;
                        break;
                    } else continue,
                    else => unreachable,
                }
            }
        },
        else => {
            @compileError("fzy.zig is not supported on this platform");
        },
    }

    return events;
}
