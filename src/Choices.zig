const std = @import("std");

const match = @import("match.zig");
const Options = @import("Options.zig");

const Choices = @This();

const INITIAL_CHOICE_CAPACITY = 128;

fn compareChoice(_: void, a: ScoredResult, b: ScoredResult) bool {
    if (a.score == b.score) {
        if (@ptrToInt(a.str.ptr) < @ptrToInt(b.str.ptr)) {
            return false;
        } else {
            return true;
        }
    } else if (a.score < b.score) {
        return true;
    } else {
        return false;
    }
}

const ScoredResult = struct {
    score: match.Score,
    str: []const u8,
};

allocator: *std.mem.Allocator,
strings: std.ArrayList([]const u8),
results: std.ArrayList(ScoredResult),
selections: std.StringHashMap(void),
selection: usize = 0,
worker_count: usize,

pub fn init(allocator: *std.mem.Allocator, options: Options) !Choices {
    var strings = try std.ArrayList([]const u8).initCapacity(allocator, INITIAL_CHOICE_CAPACITY);
    errdefer strings.deinit();

    return Choices{
        .allocator = allocator,
        .strings = strings,
        .results = std.ArrayList(ScoredResult).init(allocator),
        .selections = std.StringHashMap(void).init(allocator),
        .worker_count = if (options.workers > 0)
            options.workers
        else
            std.Thread.getCpuCount() catch unreachable,
    };
}

pub fn deinit(self: *Choices) void {
    for (self.strings.items) |s| {
        self.allocator.free(s);
    }
    self.strings.deinit();
    self.results.deinit();
}

pub fn size(self: *Choices) usize {
    return self.strings.items.len;
}

pub fn next(self: *Choices) void {
    if (self.results.items.len > 0) {
        self.selection = (self.selection + 1) % self.results.items.len;
    }
}

pub fn prev(self: *Choices) void {
    if (self.results.items.len > 0) {
        self.selection = (self.selection + self.results.items.len - 1) % self.results.items.len;
    }
}

pub fn read(self: *Choices, file: std.fs.File, input_delimiter: u8) !void {
    var buffer = try file.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
    defer self.allocator.free(buffer);

    var it = std.mem.tokenize(u8, buffer, &[_]u8{input_delimiter});
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        var new_line = try self.allocator.dupe(u8, line);
        if (i < self.strings.capacity) {
            self.strings.appendAssumeCapacity(new_line);
        } else {
            try self.strings.append(new_line);
        }
    }
}

pub fn resetSearch(self: *Choices) void {
    self.selection = 0;
    self.results.clearAndFree();
    self.selections.clearAndFree();
}

pub fn select(self: *Choices, choice: []const u8) !void {
    try self.selections.put(choice, {});
}

pub fn deselect(self: *Choices, choice: []const u8) void {
    _ = self.selections.remove(choice);
}

pub fn search(self: *Choices, query: []const u8) !void {
    self.resetSearch();

    var workers = try self.allocator.alloc(Worker, self.worker_count);
    defer self.allocator.free(workers);

    var job = SearchJob{
        .search = query,
        .choices = self,
        .workers = workers,
    };

    var i = self.worker_count;
    while (i > 0) : (i -= 1) {
        workers[i - 1] = .{
            .job = &job,
            .worker_num = i - 1,
            .results = try ResultList.initCapacity(self.allocator, self.strings.items.len),
            .thread = try std.Thread.spawn(.{}, searchWorker, .{&workers[i - 1]}),
        };
    }

    workers[0].thread.join();
    self.results = workers[0].results;
}

pub fn getResult(self: *Choices, i: usize) ?ScoredResult {
    return if (i < self.results.items.len) self.results.items[i] else null;
}

fn searchWorker(worker: *Worker) void {
    var job = worker.job;
    const choices = job.choices;
    var results = &worker.results;
    var start: usize = undefined;
    var end: usize = undefined;

    while (true) {
        job.getNextBatch(&start, &end);

        if (start == end) break;

        var i = start;
        while (i < end) : (i += 1) {
            if (match.hasMatch(job.search, choices.strings.items[i])) {
                results.appendAssumeCapacity(.{
                    .str = choices.strings.items[i],
                    .score = match.match(job.search, choices.strings.items[i]),
                });
            }
        }
    }

    std.sort.sort(ScoredResult, results.items, {}, compareChoice);

    var step: u6 = 0;
    while (true) : (step += 1) {
        if ((worker.worker_num % (@as(usize, 2) << step)) != 0) {
            break;
        }

        var next_worker = worker.worker_num | (@as(usize, 1) << step);
        if (next_worker >= choices.worker_count) {
            break;
        }

        job.workers[next_worker].thread.join();

        worker.results = merge2(choices.allocator, results, &job.workers[next_worker].results) catch unreachable;
    }
}

const ResultList = std.ArrayList(ScoredResult);

fn merge2(allocator: *std.mem.Allocator, list1: *ResultList, list2: *ResultList) !ResultList {
    var index1: usize = 0;
    var index2: usize = 0;
    var result = try ResultList.initCapacity(allocator, list1.items.len + list2.items.len);

    while (index1 < list1.items.len and index2 < list2.items.len) {
        if (!compareChoice({}, list1.items[index1], list2.items[index2])) {
            result.appendAssumeCapacity(list1.items[index1]);
            index1 += 1;
        } else {
            result.appendAssumeCapacity(list2.items[index2]);
            index2 += 1;
        }
    }

    result.appendSliceAssumeCapacity(list1.items[index1..]);
    result.appendSliceAssumeCapacity(list2.items[index2..]);
    list1.deinit();
    list2.deinit();
    return result;
}

const BATCH_SIZE = 512;

const SearchJob = struct {
    lock: std.Thread.Mutex = .{},
    choices: *Choices,
    search: []const u8,
    processed: usize = 0,
    workers: []Worker,

    fn getNextBatch(self: *SearchJob, start: *usize, end: *usize) void {
        var lock = self.lock.acquire();

        start.* = self.processed;
        self.processed += BATCH_SIZE;
        if (self.processed > self.choices.strings.items.len) {
            self.processed = self.choices.strings.items.len;
        }
        end.* = self.processed;

        lock.release();
    }
};

const Worker = struct {
    thread: std.Thread,
    job: *SearchJob,
    worker_num: usize,
    results: ResultList,
};
