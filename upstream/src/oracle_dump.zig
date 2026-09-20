// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a fixed corpus of instants against a fixed corpus of format
//! strings and writes the results out for `tools/oracle.js` to check
//! against moment.js.
//!
//! The corpus lives here rather than in the JavaScript because a format
//! string has to be comptime known for `DateTime.format` to unroll it, so
//! only this side can enumerate them. The output is one record per line,
//! tab separated: the instant as milliseconds since the Unix epoch, the
//! offset it is read at in minutes east of UTC, the format string, and
//! what this library made of it. Neither a format
//! string nor a formatted result can contain a tab or a newline, which is
//! asserted rather than assumed.
//!
//! The offset is carried rather than assumed, because without it every
//! comparison would sit at `+00:00` and the sequences that write one
//! would never be checked against anything else. moment applies it with
//! `utcOffset`, which moves the reading without moving the instant, and
//! that is what is done here too.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;

/// The instants to format, as milliseconds since the Unix epoch, each
/// with a note saying what makes it worth having. These are the awkward
/// ones; `sweep_from` below covers the ordinary ones in bulk.
const instants = [_]struct { at: i64, why: []const u8 }{
    .{ .at = 0, .why = "the epoch itself, a Thursday" },
    .{ .at = 1710513005123, .why = "an ordinary afternoon, 2024-03-15T14:30:05.123Z" },
    .{ .at = 1704240429000, .why = "single digit month, day, hour, minute and second" },
    .{ .at = 1704240000000, .why = "midnight, where the 12 and 24 hour clocks differ" },
    .{ .at = 1710460800000, .why = "noon, the other end of the meridiem" },
    .{ .at = 1704067199000, .why = "the last second of 2023" },
    .{ .at = 1704067200000, .why = "the first second of 2024, a leap year" },
    .{ .at = 1709164800000, .why = "2024-02-29, the leap day" },
    .{ .at = 1735689599000, .why = "the last second of 2024" },
    .{ .at = 951782400000, .why = "2000-02-29, the century leap year" },
    .{ .at = -2208988800000, .why = "1900-01-01, well before the epoch" },
    .{ .at = -1, .why = "one millisecond before the epoch" },
};

/// A day-by-day sweep, at noon so that no zone or rounding question can
/// enter into it. Week numbering is where the two implementations are
/// most likely to disagree and the disagreements cluster at the turn of a
/// year, so the sweep is the real check and the list above is a handful
/// of cases it would take a long run to reach.
const sweep_from = 1420070400000; // 2015-01-01
const sweep_days = 6575; // through to the end of 2032
const sweep_step = std.time.ms_per_day;

/// The offsets to read each of the awkward instants at, in minutes east of
/// UTC. Without these the whole corpus would sit at zero and the sequences
/// that write an offset would never be checked against anything but
/// `+00:00`. The sweep stays at zero, being about the calendar rather than
/// the clock.
///
/// A quarter hour offset and both extremes are here because those are
/// where an implementation that assumed whole hours would come apart.
const offsets = [_]i32{ 0, -300, 345, 840, -720 };

/// The format strings to try. Every sequence appears at least once on its
/// own, so a disagreement names the sequence responsible rather than a
/// combination, and the combinations that follow are the shapes a caller
/// actually writes.
const formats = [_][]const u8{
    // Every sequence on its own.
    "M",               "Mo",                   "MM",                           "MMM",
    "MMMM",            "Q",                    "Qo",                           "D",
    "Do",              "DD",                   "DDD",                          "DDDo",
    "DDDD",            "d",                    "do",                           "dd",
    "ddd",             "dddd",                 "e",                            "E",
    "w",               "wo",                   "ww",                           "W",
    "Wo",              "WW",                   "gg",                           "gggg",
    "ggggg",           "GG",                   "GGGG",                         "GGGGG",
    "Y",               "YY",                   "YYYY",                         "YYYYY",
    "YYYYYY",          "y",                    "yo",                           "yy",
    "yyy",             "yyyy",                 "N",                            "NN",
    "NNN",             "NNNN",                 "NNNNN",                        "A",
    "a",               "H",                    "HH",                           "h",
    "hh",              "k",                    "kk",                           "m",
    "mm",              "s",                    "ss",                           "S",
    "SS",              "SSS",                  "Z",                            "ZZ",
    "X",               "x",                    "Hmm",                          "Hmmss",
    "hmm",             "hmmss",                "z",                            "zz",
    // Sequences that only differ from their parts when run together.
    "YYY",             "H mm",                 "h mm ss",
    // Literals, escaping, and the corners of both.
                         "YYYY/MM/DD",
    "[abc]",           "[Y]YYYY",              "a[bc]d",                       "[]",
    "[[]",             "[abc",                 "abc]",                         "[a[b]",
    "q",               "%",                    "#$@!",                         "YYYY[T]HH",
    "[today is] dddd",
    // The shapes a caller writes.
    "YYYY-MM-DD",           "YYYY-MM-DDTHH:mm:ss",          "HH:mm",
    "h:mm a",          "dddd, D MMMM YYYY",    "ddd, DD MMM YYYY HH:mm:ss ZZ", "MMM D",
    "Do MMMM",         "YYYY-MM-DDTHH:mm:ssZ", "GGGG-[W]WW-E",                 "gggg-[W]ww-e",
    // The localized sequences, which stand for a whole format string.
    "L",               "LL",                   "LLL",                          "LLLL",
    "LT",              "LTS",                  "l",                            "ll",
    "lll",             "llll",                 "LLLLL",                        "L LT",
    "[L] L",           "hello",
    // Backslash escaping, including the corners where moment drops the
    // whole run it matched.
                   "\\Y",                          "\\\\Y",
    "YYYY\\-MM",       "\\[abc\\]",            "\\MMD",                        "\\",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    var line: [256]u8 = undefined;

    for (0..instants.len + sweep_days) |index| {
        const on_sweep = index >= instants.len;
        const at = if (on_sweep)
            sweep_from + @as(i64, @intCast(index - instants.len)) * sweep_step
        else
            instants[index].at;

        // The awkward instants are read at every offset; the sweep only
        // at UTC, which keeps the corpus to a size worth running.
        const wanted: []const i32 = if (on_sweep) offsets[0..1] else &offsets;

        for (wanted) |minutes| {
            const seconds = minutes * 60;

            // The same instant read against a clock `seconds` from UTC,
            // which is what moment's `utcOffset` does to a moment.
            const base: Instant = .fromMilliTimestamp(at);
            const shifted: Instant = .{
                .timestamp = base.timestamp + @as(i128, seconds) * std.time.ns_per_s,
            };
            var value = shifted.asDateTime();
            value.offset = seconds;

            inline for (formats) |fmt| {
                var writer = std.Io.Writer.fixed(&line);
                try value.format(fmt, &writer);
                const formatted = writer.buffered();

                // The record separator would otherwise be ambiguous.
                // Nothing in the corpus produces either, so this is a
                // guard against the corpus growing something that does.
                std.debug.assert(std.mem.indexOfAny(u8, fmt, "\t\n") == null);
                std.debug.assert(std.mem.indexOfAny(u8, formatted, "\t\n") == null);

                try out.print("{d}\t{d}\t{s}\t{s}\n", .{ at, minutes, fmt, formatted });
            }
        }
    }

    try out.flush();
}
