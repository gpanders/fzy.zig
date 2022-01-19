const std = @import("std");

const match = @import("match.zig");
const Options = @import("Options.zig");

const Choices = @This();

const ScoredResult = struct {
    score: match.Score,
    str: []const u8,
};

const ResultList = std.ArrayList(ScoredResult);

const SearchJob = struct {
    lock: std.Thread.Mutex = .{},
    choices: []const []const u8,
    search: []const u8,
    workers: []Worker,
    processed: usize = 0,

    const BATCH_SIZE = 512;

    fn getNextBatch(self: *SearchJob, start: *usize, end: *usize) void {
        self.lock.lock();
        defer self.lock.unlock();

        start.* = self.processed;
        self.processed += BATCH_SIZE;
        if (self.processed > self.choices.len) {
            self.processed = self.choices.len;
        }
        end.* = self.processed;
    }
};

const Worker = struct {
    thread: std.Thread,
    job: *SearchJob,
    options: *Options,
    worker_num: usize,
    results: ResultList,
};

allocator: std.mem.Allocator,
strings: std.ArrayList([]const u8),
results: ?ResultList = null,
selections: std.StringHashMap(void),
selection: usize = 0,
worker_count: usize = 0,
options: Options,

pub fn init(allocator: std.mem.Allocator, options: Options) !Choices {
    var strings = std.ArrayList([]const u8).init(allocator);
    errdefer strings.deinit();

    const worker_count: usize = if (options.workers > 0)
        options.workers
    else
        std.Thread.getCpuCount() catch unreachable;

    return Choices{
        .allocator = allocator,
        .strings = strings,
        .selections = std.StringHashMap(void).init(allocator),
        .worker_count = worker_count,
        .options = options,
    };
}

pub fn deinit(self: *Choices) void {
    for (self.strings.items) |s| {
        self.allocator.free(s);
    }
    if (self.results) |results| results.deinit();
    self.strings.deinit();
    self.selections.deinit();
}

pub fn numChoices(self: Choices) usize {
    return self.strings.items.len;
}

pub fn numResults(self: Choices) usize {
    return if (self.results) |r| r.items.len else 0;
}

pub fn next(self: *Choices) void {
    if (self.results) |results| if (results.items.len > 0) {
        self.selection = (self.selection + 1) % results.items.len;
    };
}

pub fn prev(self: *Choices) void {
    if (self.results) |results| if (results.items.len > 0) {
        self.selection = (self.selection + results.items.len - 1) % results.items.len;
    };
}

pub fn read(self: *Choices, file: std.fs.File, input_delimiter: u8) !void {
    var buffer = try file.reader().readAllAlloc(self.allocator, std.math.maxInt(usize));
    defer self.allocator.free(buffer);

    var it = std.mem.tokenize(u8, buffer, &[_]u8{input_delimiter});
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        var new_line = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(new_line);
        try self.strings.append(new_line);
    }
}

pub fn resetSearch(self: *Choices) void {
    self.selection = 0;
    self.selections.clearRetainingCapacity();
    if (self.results) |results| {
        results.deinit();
        self.results = null;
    }
}

pub fn select(self: *Choices, choice: []const u8) !void {
    try self.selections.put(choice, {});
}

pub fn deselect(self: *Choices, choice: []const u8) void {
    _ = self.selections.remove(choice);
}

pub fn getResult(self: Choices, i: usize) ?ScoredResult {
    return if (self.results != null and i < self.results.?.items.len)
        self.results.?.items[i]
    else
        null;
}

pub fn search(self: *Choices, query: []const u8) !void {
    self.resetSearch();

    if (query.len == 0) {
        self.results = try ResultList.initCapacity(self.allocator, self.strings.items.len);
        for (self.strings.items) |item| {
            self.results.?.appendAssumeCapacity(.{
                .str = item,
                .score = match.SCORE_MIN,
            });
        }
        return;
    }

    var workers = try self.allocator.alloc(Worker, self.worker_count);
    defer self.allocator.free(workers);

    var job = SearchJob{
        .search = query,
        .choices = self.strings.items,
        .workers = workers,
    };

    var i = self.worker_count;
    while (i > 0) {
        i -= 1;
        workers[i].job = &job;
        workers[i].options = &self.options;
        workers[i].worker_num = i;
        workers[i].results = try ResultList.initCapacity(self.allocator, SearchJob.BATCH_SIZE);
        workers[i].thread = try std.Thread.spawn(.{}, searchWorker, .{ self.allocator, &workers[i] });
    }

    workers[0].thread.join();

    self.results = workers[0].results;
}

fn compareChoices(_: void, a: ScoredResult, b: ScoredResult) bool {
    return a.score > b.score;
}

fn searchWorker(allocator: std.mem.Allocator, worker: *Worker) !void {
    var job = worker.job;
    var start: usize = undefined;
    var end: usize = undefined;

    while (true) {
        job.getNextBatch(&start, &end);

        if (start == end) break;

        for (job.choices[start..end]) |item| {
            if (match.hasMatch(job.search, item)) {
                try worker.results.append(.{
                    .str = item,
                    .score = match.match(job.search, item),
                });
            }
        }
    }

    if (worker.options.sort) {
        std.sort.sort(ScoredResult, worker.results.items, {}, compareChoices);
    }

    var step: u6 = 0;
    while (true) : (step += 1) {
        if ((worker.worker_num % (@as(usize, 2) << step)) != 0) {
            break;
        }

        const next_worker = worker.worker_num | (@as(usize, 1) << step);
        if (next_worker >= job.workers.len) {
            break;
        }

        job.workers[next_worker].thread.join();

        worker.results = try merge2(allocator, worker.options.sort, worker.results, job.workers[next_worker].results);
    }
}

fn merge2(allocator: std.mem.Allocator, sort: bool, list1: ResultList, list2: ResultList) !ResultList {
    if (list2.items.len == 0) {
        list2.deinit();
        return list1;
    }

    if (list1.items.len == 0) {
        list1.deinit();
        return list2;
    }

    var result = try ResultList.initCapacity(allocator, list1.items.len + list2.items.len);
    errdefer result.deinit();

    var slice1 = list1.items;
    var slice2 = list2.items;

    while (sort and slice1.len > 0 and slice2.len > 0) {
        if (compareChoices({}, slice1[0], slice2[0])) {
            result.appendAssumeCapacity(slice1[0]);
            slice1 = slice1[1..];
        } else {
            result.appendAssumeCapacity(slice2[0]);
            slice2 = slice2[1..];
        }
    }

    result.appendSliceAssumeCapacity(slice2);
    result.appendSliceAssumeCapacity(slice1);

    list1.deinit();
    list2.deinit();

    return result;
}
