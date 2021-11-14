const std = @import("std");

const match = @import("match.zig");
const Options = @import("Options.zig");

const Choices = @This();

const INITIAL_CHOICE_CAPACITY = 128;

const ScoredResult = struct {
    score: match.Score,
    str: []const u8,
};

const ResultList = std.ArrayList(ScoredResult);

const SearchJob = struct {
    lock: std.Thread.Mutex = .{},
    choices: *Choices,
    search: []const u8,
    processed: usize = 0,

    const BATCH_SIZE = 512;

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

allocator: *std.mem.Allocator,
strings: std.ArrayList([]const u8),
results: *ResultList,
selections: std.StringHashMap(void),
selection: usize = 0,
workers: []Worker,

pub fn init(allocator: *std.mem.Allocator, options: Options) !Choices {
    var strings = try std.ArrayList([]const u8).initCapacity(allocator, INITIAL_CHOICE_CAPACITY);
    errdefer strings.deinit();

    const worker_count = if (options.workers > 0)
        options.workers
    else
        std.Thread.getCpuCount() catch unreachable;
    var workers = try allocator.alloc(Worker, worker_count);
    for (workers) |*w, i| {
        w.worker_num = i;
        w.results = ResultList.init(allocator);
    }

    return Choices{
        .allocator = allocator,
        .strings = strings,
        .results = &workers[0].results,
        .selections = std.StringHashMap(void).init(allocator),
        .workers = workers,
    };
}

pub fn deinit(self: *Choices) void {
    for (self.strings.items) |s| {
        self.allocator.free(s);
    }
    for (self.workers) |w| {
        w.results.deinit();
    }
    self.allocator.free(self.workers);
    self.strings.deinit();
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
    self.selections.clearAndFree();
    for (self.workers) |*w| {
        w.results.clearRetainingCapacity();
    }
}

pub fn select(self: *Choices, choice: []const u8) !void {
    try self.selections.put(choice, {});
}

pub fn deselect(self: *Choices, choice: []const u8) void {
    _ = self.selections.remove(choice);
}

pub fn getResult(self: *Choices, i: usize) ?ScoredResult {
    return if (i < self.results.items.len) self.results.items[i] else null;
}

pub fn search(self: *Choices, query: []const u8) !void {
    self.resetSearch();

    var job = SearchJob{
        .search = query,
        .choices = self,
    };

    var i = self.workers.len;
    while (i > 0) {
        i -= 1;
        self.workers[i].job = &job;
        try self.workers[i].results.ensureTotalCapacity(self.strings.items.len);
        self.workers[i].thread = try std.Thread.spawn(.{}, searchWorker, .{&self.workers[i]});
    }

    self.workers[0].thread.join();
}

fn searchWorker(worker: *Worker) !void {
    var job = worker.job;
    var results = &worker.results;
    const choices = job.choices;
    var workers = choices.workers;
    var start: usize = undefined;
    var end: usize = undefined;

    while (true) {
        job.getNextBatch(&start, &end);

        if (start == end) break;

        for (choices.strings.items[start..end]) |item| {
            if (match.hasMatch(job.search, item)) {
                results.appendAssumeCapacity(.{
                    .str = item,
                    .score = match.match(job.search, item),
                });
            }
        }
    }

    var step: u6 = 0;
    while (true) : (step += 1) {
        if ((worker.worker_num % (@as(usize, 2) << step)) != 0) {
            break;
        }

        const next_worker = worker.worker_num | (@as(usize, 1) << step);
        if (next_worker >= choices.workers.len) {
            break;
        }

        workers[next_worker].thread.join();

        try results.appendSlice(workers[next_worker].results.items);
        std.sort.sort(ScoredResult, results.items, {}, struct {
            fn sort(_: void, a: ScoredResult, b: ScoredResult) bool {
                if (a.score == b.score) {
                    if (@ptrToInt(a.str.ptr) > @ptrToInt(b.str.ptr)) {
                        return false;
                    } else {
                        return true;
                    }
                } else if (a.score > b.score) {
                    return true;
                } else {
                    return false;
                }
            }
        }.sort);
    }
}

