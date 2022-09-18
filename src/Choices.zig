const std = @import("std");

const match = @import("match.zig");
const Options = @import("Options.zig");

const Choices = @This();

pub const String = struct {
    start: usize,
    end: usize,
};

const ScoredResult = struct {
    score: match.Score,
    str: String,
};

const ResultList = std.ArrayListUnmanaged(ScoredResult);

const SearchJob = struct {
    lock: std.Thread.Mutex = .{},
    choices: *Choices,
    strings: []String,
    search: []const u8,
    workers: []Worker,
    processed: usize = 0,

    const BATCH_SIZE = 512;

    fn getNextBatch(self: *SearchJob, start: *usize, end: *usize) void {
        self.lock.lock();
        defer self.lock.unlock();

        start.* = self.processed;
        self.processed += BATCH_SIZE;
        if (self.processed > self.strings.len) {
            self.processed = self.strings.len;
        }
        end.* = self.processed;
    }
};

const Worker = struct {
    thread: std.Thread,
    job: *SearchJob,
    options: *const Options,
    worker_num: usize,
    results: ResultList,
};

const chunk_size = 64 * 1024;

allocator: std.mem.Allocator,
strings: std.ArrayList(String),
results: ResultList = .{},
selections: std.AutoHashMap(String, void),
selection: usize = 0,
worker_count: usize = 0,
options: *const Options,
buffer: std.ArrayList(u8),
buffer_cursor: usize = 0,
file: ?std.fs.File,

pub fn init(allocator: std.mem.Allocator, options: *const Options, file: std.fs.File) !Choices {
    const worker_count: usize = if (options.workers > 0)
        options.workers
    else
        std.Thread.getCpuCount() catch unreachable;

    return Choices{
        .allocator = allocator,
        .strings = std.ArrayList(String).init(allocator),
        .selections = std.AutoHashMap(String, void).init(allocator),
        .worker_count = worker_count,
        .options = options,
        .buffer = try std.ArrayList(u8).initCapacity(allocator, chunk_size),
        .file = file,
    };
}

pub fn deinit(self: *Choices) void {
    self.results.deinit(self.allocator);
    self.strings.deinit();
    self.selections.deinit();
    self.buffer.deinit();
    if (self.file) |file| file.close();
}

pub fn numChoices(self: Choices) usize {
    return self.strings.items.len;
}

pub fn numResults(self: Choices) usize {
    return self.results.items.len;
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

pub fn read(self: *Choices) !bool {
    var file = self.file orelse return false;

    if (self.buffer.capacity < self.buffer.items.len + chunk_size) {
        try self.buffer.ensureTotalCapacity(2 * self.buffer.capacity);
    }

    const orig_len = self.buffer.items.len;
    self.buffer.items.len = orig_len + chunk_size;
    var slice = self.buffer.items[orig_len..];
    const bytes_read = try file.reader().read(slice);
    if (bytes_read == 0) {
        // EOF
        file.close();
        self.file = null;
    }

    self.buffer.items.len = orig_len + bytes_read;
    if (self.buffer_cursor >= self.buffer.items.len - 1) {
        return false;
    }

    while (std.mem.indexOfScalarPos(
        u8,
        self.buffer.items,
        self.buffer_cursor,
        self.options.input_delimiter,
    )) |i| : (self.buffer_cursor = i + 1) {
        try self.strings.append(.{
            .start = self.buffer_cursor,
            .end = i,
        });
    }

    return true;
}

pub fn readAll(self: *Choices) !void {
    while (self.file) |_| _ = try self.read();
}

pub fn resetSearch(self: *Choices) void {
    self.selection = 0;
    self.results.clearAndFree(self.allocator);
}

pub fn getResult(self: Choices, i: usize) ?ScoredResult {
    return if (i < self.results.items.len)
        self.results.items[i]
    else
        null;
}

pub fn getString(self: Choices, s: String) []const u8 {
    return self.buffer.items[s.start..s.end];
}

pub fn search(self: *Choices, query: []const u8) !void {
    self.resetSearch();

    if (query.len == 0) {
        self.results = try ResultList.initCapacity(self.allocator, self.strings.items.len);
        for (self.strings.items) |item| {
            self.results.appendAssumeCapacity(.{
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
        .choices = self,
        .strings = self.strings.items,
        .workers = workers,
    };

    var i = self.worker_count;
    while (i > 0) {
        i -= 1;
        workers[i].job = &job;
        workers[i].options = self.options;
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

        for (job.strings[start..end]) |item| {
            const str = job.choices.getString(item);
            if (match.hasMatch(job.search, str)) {
                try worker.results.append(allocator, .{
                    .str = item,
                    .score = match.match(job.search, str),
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

        worker.results = try merge2(allocator, worker.options.sort, &worker.results, &job.workers[next_worker].results);
    }
}

fn merge2(allocator: std.mem.Allocator, sort: bool, list1: *ResultList, list2: *ResultList) !ResultList {
    if (list2.items.len == 0) {
        list2.deinit(allocator);
        return list1.*;
    }

    if (list1.items.len == 0) {
        list1.deinit(allocator);
        return list2.*;
    }

    var result = try ResultList.initCapacity(allocator, list1.items.len + list2.items.len);
    errdefer result.deinit(allocator);

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

    list1.deinit(allocator);
    list2.deinit(allocator);

    return result;
}
