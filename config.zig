pub const tty_color_highlight = .yellow;
pub const tty_selection_underline = false;

pub const score_gap_leading = -0.005;
pub const score_gap_trailing = -0.005;
pub const score_gap_inner = -0.01;
pub const score_match_consecutive = 1.0;
pub const score_match_slash = 0.9;
pub const score_match_word = 0.8;
pub const score_match_capital = 0.7;
pub const score_match_dot = 0.6;

// Time (in ms) to wait for additional bytes of an escape sequence
pub const keytimeout = 25;

pub const default_tty = "/dev/tty";
pub const default_prompt = "> ";
pub const default_num_lines = 10;
pub const default_workers = 0;
pub const default_show_info = false;
