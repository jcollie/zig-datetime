// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a corpus of instants against a corpus of strftime format
//! strings and writes the results out for `tools/oracle_strftime.c` to
//! check against the C library's own `strftime` and `strptime`.
//!
//! The corpus lives here for the same reason the other oracles' do: a
//! format string has to be comptime known for `strftime.format` to take
//! it apart while this is compiled, so only this side can enumerate them.
//!
//! Output is one record per line, tab separated, of two kinds. An `F`
//! record is a formatting result: the instant as milliseconds since the
//! Unix epoch, the offset it is read at in minutes east of UTC, the zone
//! name the reading carries, the format string, and what this library
//! wrote. A `P` record is what came back when that text was read again
//! under the same format string: how many bytes were consumed and the six
//! fields a `struct tm` would carry, or `err` when it would not read.
//!
//! The zone name is carried because `%Z` writes it. A reading with no
//! name is not in the corpus at all: `%Z` writes nothing for one, where
//! glibc falls back to the running process's zone, and that difference is
//! a property of a `struct tm` rather than something to check.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Designation = datetime.Designation;
const Instant = datetime.Instant;
const strftime = datetime.strftime;

/// The instants to format, as milliseconds since the Unix epoch.
const instants = [_]i64{
    0, // the epoch, a Thursday
    1710513005123, // an ordinary afternoon
    1704240429000, // single digit month, day, hour, minute and second
    1704240000000, // midnight, where the twelve hour clock reads 12
    1710460800000, // noon, the other end of the meridiem
    1709164800000, // the leap day
    1735689599000, // the last second of a year
    1704067200000, // New Year's Day, where the week counts start over
    -2208988800000, // 1900, well before the epoch
    1136073600000, // a Sunday, where %u and %w disagree most
    1483228800000, // 2017-01-01, a Sunday: ISO week 52 of the year before
};

/// The offsets those instants are read at, in minutes east of UTC, paired
/// with the name the zone goes by.
const zones = [_]struct { minutes: i32, name: []const u8 }{
    .{ .minutes = 0, .name = "UTC" },
    .{ .minutes = -300, .name = "CDT" },
    .{ .minutes = 345, .name = "+0545" },
    .{ .minutes = 840, .name = "LINT" },
};

/// Every conversion on its own, so that a disagreement names the
/// conversion responsible rather than a combination.
const conversions = [_][]const u8{
    "%a", "%A", "%b", "%B", "%c", "%C", "%d", "%D",
    "%e", "%F", "%g", "%G", "%h", "%H", "%I", "%j",
    "%k", "%l", "%m", "%M", "%p", "%r", "%R", "%S",
    "%T", "%u", "%U", "%V", "%w", "%W", "%x", "%X",
    "%y", "%Y", "%z", "%Z", "%%", "%P",
};

/// The flags and widths, over the conversions they say anything about.
const decorated = [_][]const u8{
    "%-d",  "%_d", "%0d", "%-e",   "%0e",  "%_e",
    "%-m",  "%_m", "%-H", "%_H",   "%-k",  "%0k",
    "%-I",  "%_I", "%-l", "%0l",   "%-j",  "%_j",
    "%-y",  "%_y", "%-Y", "%0Y",   "%_Y",  "%-C",
    "%-S",  "%-M", "%-U", "%-W",   "%-V",  "%-G",
    "%-u",  "%-w", "%4Y", "%6Y",   "%10Y", "%3d",
    "%09d", "%5a", "%5p", "%5Z",   "%^a",  "%^A",
    "%^b",  "%^B", "%^p", "%^Z",   "%^c",  "%#a",
    "%#A",  "%#b", "%#B", "%#p",   "%#Z",  "%^P",
    "%#P",  "%Ec", "%EY", "%Ey",   "%EC",  "%Ex",
    "%EX",  "%Od", "%Oe", "%OH",   "%OI",  "%Om",
    "%OM",  "%OS", "%Ou", "%OU",   "%OV",  "%Ow",
    "%OW",  "%Oy", "%4C", "%_10Y", "%0j",  "%2d",
};

/// The shapes callers actually write.
const shapes = [_][]const u8{
    "%Y-%m-%d",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S%z",
    "%a, %d %b %Y %H:%M:%S %z",
    "%A, %B %-d, %Y",
    "%d/%m/%Y %I:%M %p",
    "%m/%d/%y",
    "%H:%M",
    "%j of %Y",
    "%G-W%V-%u",
    "%Y week %U (%W)",
    "%a %b %e %H:%M:%S %Z %Y",
    "%c",
    "%x %X",
    "%F %T%z",
    "%s",
};

/// The corners of the tokenizer, where text around a conversion has to
/// come through untouched.
const corners = [_][]const u8{
    "hello",
    "",
    "%%Y",
    "100%% of %Y",
    "[%Y]",
    "%n",
    "%t",
    "%Y%m%d",
    "%H%M%S",
    "%%%%",
    " %Y ",
    "%d.%m.%Y.",
};

const formats = conversions ++ decorated ++ shapes ++ corners;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    var line: [256]u8 = undefined;

    for (instants) |at| {
        for (zones) |zone| {
            const seconds = zone.minutes * 60;
            const shifted: Instant = .{
                .timestamp = Instant.fromMilliTimestamp(at).timestamp +
                    @as(i128, seconds) * std.time.ns_per_s,
            };
            var value = shifted.asDateTime();
            value.offset = seconds;
            value.designation = .from(zone.name);

            inline for (formats) |current| {
                var writer = std.Io.Writer.fixed(&line);
                try strftime.format(value, current, &writer);
                const formatted = writer.buffered();

                // The record separator would otherwise be ambiguous, and
                // `%n` and `%t` write both characters on purpose.
                if (std.mem.indexOfAny(u8, current, "\t\n") == null and
                    std.mem.indexOfAny(u8, formatted, "\t\n") == null)
                {
                    try out.print("F\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{
                        at,
                        zone.minutes,
                        zone.name,
                        current,
                        formatted,
                    });

                    // And read it straight back, which is the case that
                    // has to work and which puts every conversion through
                    // the parser without a second corpus to keep in step.
                    if (strftime.parse(current, formatted)) |back| {
                        try out.print("P\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                            current,
                            formatted,
                            back.str.len,
                            back.value.year,
                            back.value.month.monthNumber(),
                            back.value.day,
                            back.value.hour,
                            back.value.minute,
                            back.value.second,
                        });
                    } else |_| {
                        try out.print("P\t{s}\t{s}\terr\t\t\t\t\t\t\n", .{ current, formatted });
                    }
                }
            }
        }
    }

    try out.flush();
}
