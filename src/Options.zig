const std = @import("std");
const clap = @import("clap");
const stderr = std.io.getStdErr().writer();

const Options = @This();

const config = @cImport(@cInclude("config.h"));

benchmark: u32 = 0,
filter: ?[]const u8 = null,
init_search: ?[]const u8 = null,
show_scores: bool = false,
scrolloff: usize = 1,
tty_filename: []const u8 = config.DEFAULT_TTY,
num_lines: usize = config.DEFAULT_NUM_LINES,
prompt: []const u8 = config.DEFAULT_PROMPT,
workers: usize = config.DEFAULT_WORKERS,
input_delimiter: u8 = '\n',
show_info: bool = config.DEFAULT_SHOW_INFO != 0,
input_file: ?[]const u8 = null,
sort: bool = true,

pub fn new() !Options {
    var options = Options{};

    const params = comptime clap.parseParamsComptime(
        \\ -l, --lines <LINES>        Specify how many lines of results to show (default 10)
        \\ -p, --prompt <PROMPT>      Input prompt (default '> ')
        \\ -q, --query <QUERY>        Use QUERY as the initial search string
        \\ -e, --show-matches <QUERY> Output the sorted matches of QUERY
        \\ -t, --tty <TTY>            Specify file to use as TTY device (default /dev/tty)
        \\ -s, --show-scores          Show the scores of each match
        \\ -0, --read-null            Read input delimited by ASCII NUL characters
        \\ -j, --workers <NUM>        Use NUM workers for searching. (default is # of CPUs)
        \\ -b, --benchmark <NUM>      Run the match algorithm NUM times
        \\ -i, --show-info            Show selection info line
        \\ -f, --file <FILE>          Read choices from FILE instead of stdin
        \\ -n, --no-sort              Do not sort matches
        \\ -h, --help                 Display this help and exit
        \\ -v, --version              Output version information and exit
    );

    const usage = struct {
        fn usage() !void {
            try stderr.writeAll("Usage: fzy [OPTION]...\n");
            try clap.help(stderr, clap.Help, &params, .{
                .description_on_new_line = false,
                .spacing_between_parameters = 0,
            });
        }
    }.usage;

    const parsers = comptime .{
        .LINES = clap.parsers.string,
        .PROMPT = clap.parsers.string,
        .QUERY = clap.parsers.string,
        .TTY = clap.parsers.string,
        .NUM = clap.parsers.int(u32, 10),
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help) {
        try usage();
        std.process.exit(0);
    }

    if (res.args.lines) |l| {
        options.num_lines = blk: {
            if (std.fmt.parseUnsigned(usize, l, 10)) |lines| {
                if (lines >= 3) {
                    break :blk lines;
                }
            } else |_| {}
            std.debug.print("Invalid format for --lines: {s}", .{l});
            // usage();
            std.process.exit(1);
        };
    }

    if (res.args.prompt) |p|
        options.prompt = p;

    if (res.args.query) |q|
        options.init_search = q;

    if (res.args.@"show-matches") |e|
        options.filter = e;

    if (res.args.tty) |t|
        options.tty_filename = t;

    if (res.args.@"show-scores")
        options.show_scores = true;

    if (res.args.@"read-null")
        options.input_delimiter = 0;

    if (res.args.workers) |j|
        options.workers = j;

    if (res.args.@"show-info")
        options.show_info = true;

    if (res.args.benchmark) |b|
        options.benchmark = b;

    if (res.args.file) |f| {
        options.input_file = f;
    }

    if (res.args.@"no-sort")
        options.sort = false;

    return options;
}
