const std = @import("std");
const testing = std.testing;

pub fn StackArrayList(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        buf: [N]T = undefined,
        items: []T = undefined,
        capacity: usize = N,

        pub fn append(self: *Self, item: T) void {
            std.debug.assert(self.items.len < N);
            var s = self.buf[0..self.items.len + 1];
            s[s.len-1] = item;
            self.items = s;
        }

        pub fn appendSlice(self: *Self, items: []const T) void {
            std.debug.assert(self.items.len + items.len <= N);
            var s = self.buf[0.. self.items.len + items.len];
            std.mem.copy(T, s[self.items.len..], items);
            self.items = s;
        }

        pub fn clear(self: *Self) void {
            self.items.len = 0;
        }

        pub fn set(self: *Self, items: []const T) void {
            std.debug.assert(items.len <= N);
            self.items = self.buf[0..items.len];
            std.mem.copy(T, self.items, items);
        }

        pub fn insert(self: *Self, n: usize, item: T) void {
            std.debug.assert(self.items.len < N);
            self.items.len += 1;
            std.mem.copyBackwards(T, self.items[n + 1 .. self.items.len], self.items[n .. self.items.len - 1]);
            self.items[n] = item;
        }

        pub fn insertSlice(self: *Self, n: usize, items: []const T) void {
            std.debug.assert(self.items.len + items.len <= N);
            self.items.len += items.len;
            std.mem.copyBackwards(T, self.items[n + items.len .. self.items.len], self.items[n .. self.items.len - items.len]);
            std.mem.copy(T, self.items[n .. n + items.len], items);
        }
    };
}

test "StackArrayList" {
    var list = StackArrayList(u32, 32){};

    try testing.expect(list.items.len == 0);
    try testing.expect(list.capacity == 32);

    list.append(42);
    try testing.expect(list.items.len == 1);

    list.appendSlice(&[_]u32{1, 2, 3});
    try testing.expect(list.items.len == 4);

    list.clear();
    try testing.expect(list.items.len == 0);

    list.set(&[_]u32{4, 5, 6, 7, 8});
    try testing.expect(list.items.len == 5);
    try testing.expect(list.items[2] == 6);
}
