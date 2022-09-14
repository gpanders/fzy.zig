const std = @import("std");

const config = @cImport(@cInclude("config.h"));

pub const Score = f64;

pub const SCORE_MIN = -std.math.f64_max;
pub const SCORE_MAX = std.math.f64_max;

pub const MAX_LEN = 1024;

const BONUS_INDEX = init: {
    var table: [256]usize = undefined;
    std.mem.set(usize, &table, 0);

    var i = 'A';
    while (i <= 'Z') : (i += 1) {
        table[i] = 2;
    }

    i = 'a';
    while (i <= 'z') : (i += 1) {
        table[i] = 1;
    }

    i = '0';
    while (i <= '9') : (i += 1) {
        table[i] = 1;
    }
    break :init table;
};

const BONUS_STATES = init: {
    var table: [3][256]Score = undefined;
    for (table) |*sub| {
        std.mem.set(Score, sub, 0);
    }

    table[1]['/'] = config.SCORE_MATCH_SLASH;
    table[1]['-'] = config.SCORE_MATCH_WORD;
    table[1]['_'] = config.SCORE_MATCH_WORD;
    table[1][' '] = config.SCORE_MATCH_WORD;
    table[1]['.'] = config.SCORE_MATCH_DOT;

    table[2]['/'] = config.SCORE_MATCH_SLASH;
    table[2]['-'] = config.SCORE_MATCH_WORD;
    table[2]['_'] = config.SCORE_MATCH_WORD;
    table[2][' '] = config.SCORE_MATCH_WORD;
    table[2]['.'] = config.SCORE_MATCH_DOT;

    var i = 'a';
    while (i <= 'z') : (i += 1) {
        table[2][i] = config.SCORE_MATCH_CAPITAL;
    }

    break :init table;
};

fn computeBonus(last_ch: u8, ch: u8) Score {
    return BONUS_STATES[BONUS_INDEX[ch]][last_ch];
}

// Lower case versions of needle and haystack. Statically allocated per thread
threadlocal var match_needle: [MAX_LEN]u8 = undefined;
threadlocal var match_haystack: [MAX_LEN]u8 = undefined;
threadlocal var match_bonus: [MAX_LEN]Score = [_]Score{0} ** MAX_LEN;

pub const Match = struct {
    needle: []const u8 = undefined,
    haystack: []const u8 = undefined,

    fn init(needle: []const u8, haystack: []const u8) Match {
        var self = Match{};
        self.needle = std.ascii.lowerString(&match_needle, needle);
        self.haystack = std.ascii.lowerString(&match_haystack, haystack);
        if (haystack.len <= MAX_LEN and needle.len <= haystack.len) {
            var last_ch: u8 = '/';
            for (haystack) |c, i| {
                match_bonus[i] = computeBonus(last_ch, c);
                last_ch = c;
            }
        }

        return self;
    }

    fn matchRow(self: *Match, row: usize, curr_D: []Score, curr_M: []Score, last_D: []const Score, last_M: []const Score) void {
        var prev_score: Score = SCORE_MIN;
        var gap_score: Score = if (row == self.needle.len - 1)
            config.SCORE_GAP_TRAILING
        else
            config.SCORE_GAP_INNER;

        for (self.haystack) |h, j| {
            if (self.needle[row] == h) {
                var score: Score = SCORE_MIN;
                if (row == 0) {
                    score = (@intToFloat(f64, j) * config.SCORE_GAP_LEADING) + match_bonus[j];
                } else if (j > 0) {
                    score = std.math.max(last_M[j - 1] + match_bonus[j], last_D[j - 1] + config.SCORE_MATCH_CONSECUTIVE);
                }

                curr_D[j] = score;
                prev_score = std.math.max(score, prev_score + gap_score);
                curr_M[j] = prev_score;
            } else {
                curr_D[j] = SCORE_MIN;
                prev_score = prev_score + gap_score;
                curr_M[j] = prev_score;
            }
        }
    }
};

pub fn match(needle: []const u8, haystack: []const u8) Score {
    if (needle.len == 0) {
        return SCORE_MIN;
    }

    if (haystack.len > MAX_LEN or needle.len > haystack.len) {
        // Unreasonably large candidate: return no score
        // If it is a valid match it will still be returned, it will
        // just be ranked below any reasonably sized candidates
        return SCORE_MIN;
    }

    if (needle.len == haystack.len) {
        // Since this method can only be called with a haystack which
        // matches needle, if the lengths of the strings are equal the
        // strings themselves must also be equal (ignoring case).
        return SCORE_MAX;
    }

    // D stores the best score for this position ending with a match.
    // M stores the best possible score at this position.
    var D: [2][MAX_LEN]Score = undefined;
    var M: [2][MAX_LEN]Score = undefined;
    var last_D: []Score = &D[0];
    var last_M: []Score = &M[0];
    var curr_D: []Score = &D[1];
    var curr_M: []Score = &M[1];

    var this_match = Match.init(needle, haystack);
    for (needle) |_, i| {
        this_match.matchRow(i, curr_D, curr_M, last_D, last_M);
        std.mem.swap([]Score, &curr_D, &last_D);
        std.mem.swap([]Score, &curr_M, &last_M);
    }

    return last_M[haystack.len - 1];
}

pub fn matchPositions(allocator: std.mem.Allocator, needle: []const u8, haystack: []const u8, positions: ?[]usize) Score {
    if (needle.len == 0) {
        return SCORE_MIN;
    }

    if (haystack.len > MAX_LEN or needle.len > haystack.len) {
        // Unreasonably large candidate: return no score
        // If it is a valid match it will still be returned, it will
        // just be ranked below any reasonably sized candidates
        return SCORE_MIN;
    }

    if (needle.len == haystack.len) {
        // Since this method can only be called with a haystack which
        // matches needle, if the lengths of the strings are equal the
        // strings themselves must also be equal (ignoring case).
        if (positions) |_| {
            for (needle) |_, i| {
                positions.?[i] = i;
            }
        }
        return SCORE_MAX;
    }

    var D = allocator.alloc([MAX_LEN]Score, needle.len) catch unreachable;
    defer allocator.free(D);

    var M = allocator.alloc([MAX_LEN]Score, needle.len) catch unreachable;
    defer allocator.free(M);

    var last_D: []Score = undefined;
    var last_M: []Score = undefined;
    var curr_D: []Score = undefined;
    var curr_M: []Score = undefined;

    var this_match = Match.init(needle, haystack);
    for (needle) |_, i| {
        curr_D = &D[i];
        curr_M = &M[i];

        this_match.matchRow(i, curr_D, curr_M, last_D, last_M);

        last_D = curr_D;
        last_M = curr_M;
    }

    if (positions) |_| {
        var match_required = false;
        var i: usize = needle.len;
        var j: usize = haystack.len;
        outer: while (i > 0) {
            i -= 1;
            while (j > 0) : (j -= 1) {
                const jj = j - 1;
                // There may be multiple paths which result in the optimal
                // weight.
                //
                // For simplicity, we will pick the first one we encounter,
                // the latest in the candidate string.
                if (D[i][jj] != SCORE_MIN and
                    (match_required or D[i][jj] == M[i][jj]))
                {
                    // If this score was determined using
                    // SCORE_MATCH_CONSECUTIVE, the previous character MUST
                    // be a match
                    match_required = (i != 0) and (jj != 0) and M[i][jj] == D[i - 1][jj - 1] + config.SCORE_MATCH_CONSECUTIVE;
                    positions.?[i] = jj;
                    if (jj == 0) break :outer;
                    j -= 1;
                    break;
                }
            }
        }
    }

    return M[needle.len - 1][haystack.len - 1];
}

// This is the hot loop for matching algorithm. If this can be optimized, everything speeds up.
pub fn hasMatch(needle: []const u8, haystack: []const u8) bool {
    var i: usize = 0;
    for (needle) |c| {
        i = if (std.mem.indexOfAnyPos(u8, haystack, i, &[_]u8{ c, std.ascii.toUpper(c) })) |j|
            j + 1
        else
            return false;
    }

    return true;
}
