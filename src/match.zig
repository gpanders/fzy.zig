const std = @import("std");

const config = @cImport(@cInclude("config.h"));

pub const Score = f64;

pub const SCORE_MIN = -std.math.f64_max;
pub const SCORE_MAX = std.math.f64_max;

const MATCH_MAX_LEN = 1024;

const BONUS_INDEX = init: {
    comptime var table: [256]usize = undefined;
    std.mem.set(usize, &table, 0);

    comptime var i = 'A';
    inline while (i <= 'Z') : (i += 1) {
        table[i] = 2;
    }

    i = 'a';
    inline while (i <= 'z') : (i += 1) {
        table[i] = 1;
    }

    i = '0';
    inline while (i <= '9') : (i += 1) {
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
    inline while (i <= 'z') : (i += 1) {
        table[2][i] = config.SCORE_MATCH_CAPITAL;
    }

    break :init table;
};

fn computeBonus(last_ch: u8, ch: u8) Score {
    return BONUS_STATES[BONUS_INDEX[ch]][last_ch];
}

pub const Match = struct {
    needle: [MATCH_MAX_LEN]u8 = undefined,
    haystack: [MATCH_MAX_LEN]u8 = undefined,
    bonus: [MATCH_MAX_LEN]Score = undefined,

    const Self = @This();

    fn init(needle: []const u8, haystack: []const u8) Self {
        var self = Self{};
        _ = std.ascii.lowerString(&self.needle, needle);
        _ = std.ascii.lowerString(&self.haystack, haystack);
        if (haystack.len <= MATCH_MAX_LEN and needle.len <= haystack.len) {
            var last_ch: u8 = '/';
            var i: usize = 0;
            for (haystack) |c| {
                self.bonus[i] = computeBonus(last_ch, c);
                last_ch = c;
                i += 1;
            }
            std.mem.set(Score, self.bonus[i..], 0);
        } else {
            std.mem.set(Score, &self.bonus, 0);
        }

        return self;
    }

    fn matchRow(self: *Self, row: usize, curr_D: []Score, curr_M: []Score, last_D: []const Score, last_M: []const Score) void {
        var n = self.needle.len;
        var m = self.haystack.len;
        var i = row;

        var prev_score: Score = SCORE_MIN;
        var gap_score: Score = if (i == n - 1) config.SCORE_GAP_TRAILING else config.SCORE_GAP_INNER;

        var j: usize = 0;
        while (j < m) : (j += 1) {
            if (self.needle[i] == self.haystack[j]) {
                var score: Score = SCORE_MIN;
                if (i == 0) {
                    score = (@intToFloat(f64, j) * config.SCORE_GAP_LEADING) + self.bonus[j];
                } else if (j != 0) {
                    score = std.math.max(last_M[j - 1] + self.bonus[j], last_D[j - 1] + config.SCORE_MATCH_CONSECUTIVE);
                }

                curr_D[j] = score;
                curr_M[j] = prev_score;
                prev_score = std.math.max(score, prev_score + gap_score);
            } else {
                curr_D[j] = SCORE_MIN;
                curr_M[j] = prev_score;
                prev_score = prev_score + gap_score;
            }
        }
    }
};

pub fn match(needle: []const u8, haystack: []const u8) Score {
    if (needle.len == 0) {
        return SCORE_MIN;
    }

    var this_match = Match.init(needle, haystack);
    var n = this_match.needle.len;
    var m = this_match.haystack.len;

    if (m > MATCH_MAX_LEN or n > m) {
        // Unreasonably large candidate: return no score
        // If it is a valid match it will still be returned, it will
        // just be ranked below any reasonably sized candidates
        return SCORE_MIN;
    }

    if (n == m) {
        // Since this method can only be called with a haystack which
        // matches needle, if the lengths of the strings are equal the
        // strings themselves must also be equal (ignoring case).
        return SCORE_MAX;
    }

    // D stores the best score for this position ending with a match.
    // M stores the best possible score at this position.
    var D: [2][MATCH_MAX_LEN]Score = undefined;
    var M: [2][MATCH_MAX_LEN]Score = undefined;
    var last_D: []Score = &D[0];
    var last_M: []Score = &M[0];
    var curr_D: []Score = &D[1];
    var curr_M: []Score = &M[1];

    var i: usize = 0;
    while (i <= n) : (i += 1) {
        this_match.matchRow(i, curr_D, curr_M, last_D, last_M);
        std.mem.swap([]Score, &curr_D, &last_D);
        std.mem.swap([]Score, &curr_M, &last_M);
    }

    return last_M[m - 1];
}

pub fn hasMatch(needle: []const u8, haystack: []const u8) bool {
    var i: usize = 0;
    for (needle) |c| {
        i = std.mem.indexOfScalarPos(u8, haystack, i, c) orelse
            std.mem.indexOfScalarPos(u8, haystack, i, std.ascii.toUpper(c)) orelse
            return false;
    }

    return true;
}
