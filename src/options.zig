const std = @import("std");
const clap = @import("clap");

const Options = @This();

const config = @cImport(@cInclude("config.h"));

const usage_str =
    \\Usage: fzy [OPTION]...
    \\ -l, --lines=LINES        Specify how many lines of results to show (default 10)
    \\ -p, --prompt=PROMPT      Input prompt (default '> ')
    \\ -q, --query=QUERY        Use QUERY as the initial search string
    \\ -e, --show-matches=QUERY Output the sorted matches of QUERY
    \\ -t, --tty=TTY            Specify file to use as TTY device (default /dev/tty)
    \\ -s, --show-scores        Show the scores of each match
    \\ -0, --read-null          Read input delimited by ASCII NUL characters
    \\ -j, --workers=NUM        Use NUM workers for searching. (default is # of CPUs)
    \\ -i, --show-info          Show selection info line
    \\ -h, --help               Display this help and exit
    \\ -v, --version            Output version information and exit
    \\
    ;

fn usage() void {
    std.debug.print(usage_str, .{});
}

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

pub fn new() !Options {
    var options = Options{};

    const params = comptime [_]clap.Param(clap.Help) {
        clap.parseParam("-h, --help                 Display this help and exit") catch unreachable,
        clap.parseParam("-l, --lines <LINES>        Specify how many lines of results to show (default 10)") catch unreachable,
        clap.parseParam("-p, --prompt <PROMPT>      Input prompt (default '> ')") catch unreachable,
        clap.parseParam("-q, --query <QUERY>        Use QUERY as the initial search string") catch unreachable,
        clap.parseParam("-e, --show-matches <QUERY> Output the sorted matches of QUERY") catch unreachable,
        clap.parseParam("-t, --tty <TTY>            Specify file to use as TTY device (default /dev/tty)") catch unreachable,
        clap.parseParam("-s, --show-scores          Show the scores of each match") catch unreachable,
        clap.parseParam("-0, --read-null            Read input delimited by ASCII NUL characters") catch unreachable,
        clap.parseParam("-j, --workers <NUM>        Use NUM workers for searching (default is # of CPUs)") catch unreachable,
        clap.parseParam("-b, --benchmark <NUM>") catch unreachable,
        clap.parseParam("-i, --show-info            Show selection into line") catch unreachable,
        clap.parseParam("-v, --version              Output version information and exit") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        usage();
        std.process.exit(0);
    }

    if (args.option("--lines")) |l| {
        options.num_lines = blk: {
            if (std.fmt.parseUnsigned(usize, l, 10)) |lines| {
                if (lines >= 3) {
                    break :blk lines;
                }
            } else |_| {}
            std.debug.print("Invalid format for --lines: {s}", .{l});
            usage();
            std.process.exit(1);
        };
    }

    if (args.option("--prompt")) |p|
        options.prompt = p;

    if (args.option("--query")) |q|
        options.init_search = q;

    if (args.option("--show-matches")) |e|
        options.filter = e;

    if (args.option("--tty")) |t|
        options.tty_filename = t;

    if (args.flag("--show-scores"))
        options.show_scores = true;

    if (args.flag("--read-null"))
        options.input_delimiter = 0;

    if (args.option("--workers")) |j|
        options.workers = std.fmt.parseUnsigned(usize, j, 10) catch {
            usage();
            std.process.exit(1);
        };

    if (args.flag("--show-info"))
        options.show_info = true;

    if (args.option("--benchmark")) |b| {
        options.benchmark = std.fmt.parseUnsigned(u32, b, 10) catch {
            usage();
            std.process.exit(1);
        };
    }

    return options;
}
