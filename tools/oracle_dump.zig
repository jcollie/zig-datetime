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
//! format string, and what this library made of it. Neither a format
//! string nor a formatted result can contain a tab or a newline, which is
//! asserted rather than assumed.
//!
//! Everything is UTC. moment's own zone handling is a separate question
//! from whether the two agree on what a format string means, and mixing
//! them would make a disagreement hard to attribute.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;

/// The instants to format, as milliseconds since the Unix epoch, each with
/// a note saying what makes it worth having.
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
    .{ .at = 1704585600000, .why = "2024-01-07, where the locale and ISO weeks differ" },
    .{ .at = 1798761600000, .why = "2026-12-31, in ISO week 53 of 2026 but locale week 1 of 2027" },
    .{ .at = 1798848000000, .why = "2027-01-01, still ISO week 53 of 2026" },
    .{ .at = 1893456000000, .why = "2029-12-31, in ISO week 1 of 2030" },
    .{ .at = 951782400000, .why = "2000-02-29, the century leap year" },
    .{ .at = -2208988800000, .why = "1900-01-01, well before the epoch" },
};

/// The format strings to try. Every sequence the library has appears at
/// least once on its own, so a disagreement names the sequence responsible
/// rather than a combination, and the combinations that follow are the
/// shapes a caller actually writes.
const formats = [_][]const u8{
    // Every sequence on its own.
    "M",     "Mo",      "MM",                   "MMM",
    "MMMM",  "Q",       "Qo",                   "D",
    "Do",    "DD",      "DDD",                  "DDDo",
    "DDDD",  "d",       "do",                   "dd",
    "ddd",   "dddd",    "e",                    "E",
    "w",     "wo",      "ww",                   "YY",
    "YYYY",  "A",       "a",                    "H",
    "HH",    "h",       "hh",                   "k",
    "kk",    "m",       "mm",                   "s",
    "ss",    "S",       "SS",                   "SSS",
    "Z",     "ZZ",
    // The shapes a caller writes.
         "YYYY-MM-DD",           "YYYY-MM-DDTHH:mm:ss",
    "HH:mm", "h:mm a",  "dddd, D MMMM YYYY",    "ddd, DD MMM YYYY HH:mm:ss ZZ",
    "MMM D", "Do MMMM", "YYYY-MM-DDTHH:mm:ssZ",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    var line: [256]u8 = undefined;

    for (instants) |instant| {
        const value = Instant.fromMilliTimestamp(instant.at).asDateTime();

        inline for (formats) |fmt| {
            var writer = std.Io.Writer.fixed(&line);
            try value.format(fmt, &writer);
            const formatted = writer.buffered();

            // The record separator would otherwise be ambiguous. Nothing
            // in the corpus produces either, so this is a guard against
            // the corpus growing something that does.
            std.debug.assert(std.mem.indexOfAny(u8, fmt, "\t\n") == null);
            std.debug.assert(std.mem.indexOfAny(u8, formatted, "\t\n") == null);

            try out.print("{d}\t{s}\t{s}\n", .{ instant.at, fmt, formatted });
        }
    }

    try out.flush();
}
