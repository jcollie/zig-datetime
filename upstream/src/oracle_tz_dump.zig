// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writes what `posixtz.parseLenient` makes of a corpus of `TZ` values,
//! for `oracle_tz.c` to ask glibc about.
//!
//! For each value a `Z` record names it, and then one `S` record per span
//! this library places over a handful of years: where the span starts and
//! ends, its offset in seconds east of UTC, 1 for daylight saving time or
//! 0, and its name. The spans are clipped to the years asked about, so
//! the C side checks a bounded stretch of time.
//!
//! The corpus is a list of values worth naming and then twelve thousand
//! built at random from pieces, each piece one of the things glibc was
//! seen to do something particular with. An `Mm.w.d` rule with a month
//! outside 1 to 12 is never built: glibc answers one by reading past the
//! end of its own table, and `parseLenient` does not model it.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const posixtz = datetime.posixtz;

const named = [_][]const u8{
    "",                         "UTC0",                          "EST5",
    "EST5EDT",                  "EST5EDT,M3.2.0,M11.1.0",        "CET-1CEST,M3.5.0,M10.5.0/3",
    "<+0330>-3:30",             "<-03>3",                        "ABC-25",
    "XYZ3:75",                  "XYZ3,junk",                     "ABC24",
    "ABC-24:59:59",             "ABC167",                        "AB5",
    "<AB>5",                    "junk",                          "junk5",
    "E5",                       "5",                             "EST+",
    "EST-",                     "EST5x",                         "EST5:",
    "EST5::",                   "EST5:3",                        "EST500",
    "EST 5",                    "EST5EDT-",                      "EST5EDT6",
    "EST5EDT25,M3.2.0,M11.1.0", "EST5:30:30:30",                 "ABC5DEF,M4.1.0/24",
    "ABC5DEF,M4.1.0/500",       "ABC5DEF,M4.1.0/-200",           "ABC5DEF,M4.1.0/2:99",
    "ABC5DEF,M4.1.0/x",         "ABC5DEF,M4.1.0/",               "ABC5DEF,junk,M10.1.0",
    "ABC5DEF-x,M4.1.0,M10.1.0", "ABC5DEF4x",                     "ABC5DEF,M4.1.0,",
    "ABC5DEF,M4.1.0;M10.1.0",   "ABC5DEF,M4.1.0,M10.1.0,J5",     "ABC5DEF,J0,M10.1.0",
    "ABC5DEF,J1,M10.1.0",       "ABC5DEF,0,M10.1.0",             "ABC5DEF,M4.1.0,M10.1.0x",
    "ABC5DEF,M4.0.0,M10.1.0",   "ABC5DEF,M4.6.0,M10.1.0",        "ABC5DEF,M4.1.7,M10.1.0",
    "ABC5DEF,M4.1.9,M10.1.0",   "ABC5DEF,J366,M10.1.0",          "ABC5DEF,366,M10.1.0",
    "ABC5DEF,M4.1,M10.1.0",     "ABC5DEF,M4,M10.1.0",            "ABC5DEF,M04.01.00,M10.1.0",
    "ABC5DEF,J,M10.1.0",        "ABC5DEF,M4.1.0/+3,M10.1.0",     "ABC5DEF,M4.1.0/3:,M10.1.0",
    "ABC5DEF,",                 "ABC5DEF,,",                     "<ABC",
    "<A-B>5",                   "<ABCDEFGHIJKLMNOPQRSTUVWXYZ>5",
};

const names = [_][]const u8{ "ABC", "EST", "<+05>", "<-0330>", "AB", "<AB>", "x", "abc", "<A_B>", "ABCDEFGHIJ", "<ABC", "<>", "<+>5", "<A B C>", "A1C", "<ABC>>" };
const offsets = [_][]const u8{ "5", "-5", "+5", "25", "-25", "5:30", "3:75", "5:99:99", "24:59:59", "", "+", "-", "5:", "05", "500", "0", "-0:30", "1:2:3", "5: 30", "+ 5", "99999999999", "65541", "-65535", "5:-0", "5:+3", "5::3", "1:2:3:4" };
const dst_names = [_][]const u8{ "", "DEF", "DE", "x", "<D+1>", "-", ",", ":" };
const dst_offsets = [_][]const u8{ "", "", "", "4", "-1", "25", "-", "+x", "4:30", "x", "6" };
const rules = [_][]const u8{
    "M3.2.0", "M11.1.0",    "M3.5.0",  "M10.5.0",   "J60",     "J300",    "59",      "299",     "J1",
    "J365",   "0",          "365",     "J0",        "J366",    "366",     "M4.0.0",  "M4.6.0",  "M4.1.7",
    "M4.1.9", "M4",         "M4.1",    "M04.01.00", "M1.1.0",  "M12.5.6", "junk",    "",        "J",
    "M2.5.4", "M2.4.4",     "60",      "J59",       "M 4.1.0", "M4. 1.0", "M4.-1.0", "M4.1.-1", "J 60",
    "J-5",    "M4.1.65543", "M4.99.0", "M2.5.20",
};
const times = [_][]const u8{ "", "", "", "/0", "/24", "/167", "/500", "/-1", "/-200", "/2:99", "/", "/x", "/+3", "/3:", "/-48", "/1:2:3", "/26", "/ 3", "/--2", "/65537", "/-:3", "/3:-1" };
const separators = [_][]const u8{ ",", ",", ",", ";", "", ",," };
const trailers = [_][]const u8{ "", "", "", "x", ",", ",J5", " " };

/// The years whose spans are written, chosen for a leap year, an ordinary
/// one, the epoch, and one past 2038.
const years = [_]i32{ 1970, 2000, 2023, 2024, 2100 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    for (named) |value| try writeValue(out, value);

    var prng: std.Random.DefaultPrng = .init(0x6c69626302);
    const random = prng.random();
    var value_buffer: [256]u8 = undefined;
    for (0..12000) |_| {
        var built = std.Io.Writer.fixed(&value_buffer);
        try built.writeAll(pick(random, &names));
        try built.writeAll(pick(random, &offsets));
        try built.writeAll(pick(random, &dst_names));
        try built.writeAll(pick(random, &dst_offsets));
        if (random.boolean()) {
            try built.writeAll(",");
            try built.writeAll(pick(random, &rules));
            try built.writeAll(pick(random, &times));
            try built.writeAll(pick(random, &separators));
            try built.writeAll(pick(random, &rules));
            try built.writeAll(pick(random, &times));
            try built.writeAll(pick(random, &trailers));
        }
        try writeValue(out, built.buffered());
    }

    try out.flush();
}

fn pick(random: std.Random, from: []const []const u8) []const u8 {
    return from[random.uintLessThan(usize, from.len)];
}

fn writeValue(out: *Io.Writer, value: []const u8) !void {
    const rule = posixtz.parseLenient(value);
    try out.print("Z\t{s}\n", .{value});
    for (years) |year| {
        const opens = (datetime.Date{ .year = year, .month = .Jan, .day = 1 }).toDayNumber();
        const from = @as(i64, opens - 10) * std.time.s_per_day;
        const to = @as(i64, opens + 376) * std.time.s_per_day;
        var at = from;
        while (at < to) {
            const span = rule.spanAt(at);
            const end = @min(span.end, to);
            try out.print("S\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{
                at,
                end,
                span.local_type.offset,
                @intFromBool(span.local_type.is_dst),
                span.local_type.designation,
            });
            if (span.end <= at) return error.SpanDoesNotAdvance;
            at = end;
        }
    }
}
