// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a corpus of instants in every embedded locale and writes the
//! results out for `tools/oracle_locale.js` to check against moment.js.
//!
//! The other oracles check the sequences against moment's default locale.
//! This checks the locales themselves: the same sequences, every language
//! moment ships, so that a name, an ordinal, a meridiem or an `L`
//! expansion that came out of `tools/gen_locales.js` wrong is a failure
//! rather than something nobody looks at.
//!
//! Needs `-Dembed-locales`; without it there is only English and the
//! other oracles have already checked that.
//!
//! Output is one record per line, tab separated: the locale's tag, the
//! instant as milliseconds since the Unix epoch, the format string, and
//! what this library wrote.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;
const locale = datetime.locale;

/// The instants to format, as milliseconds since the Unix epoch. Chosen
/// to reach the corners a locale can differ in: both halves of the day
/// and both sides of the half hour, since some languages change the
/// meridiem there; the first and last of a month, which is where an
/// ordinal is most likely to be irregular; the turn of a year, where the
/// week rule decides which year a week belongs to; and a leap day.
const instants = [_]i64{
    1709635620000, // 2024-03-05 11:27, morning, past the half hour
    1709618400000, // 2024-03-05 06:40 -- another morning hour
    1709650800000, // 2024-03-05 15:00, afternoon, on the hour
    1709629200000, // 2024-03-05 09:00
    1709642700000, // 2024-03-05 12:45, just past noon
    1709640000000, // 2024-03-05 12:00, noon exactly
    1709596800000, // 2024-03-05 00:00, midnight exactly
    1709598600000, // 2024-03-05 00:30
    1704067200000, // 2024-01-01, the first of a year
    1735603200000, // 2024-12-31, the last of one
    1709164800000, // 2024-02-29, a leap day
    1707436800000, // 2024-02-09, the fortieth day of the year, where
    // moment's Turkic ordinals index past the end of their own suffix
    // table and write "NaN".
    1719792000000, // 2024-07-01
    1721001600000, // 2024-07-15
    1722384000000, // 2024-07-31, the last of a month
    978307200000, // 2001-01-01
    -2208988800000, // 1900-01-01, well before the epoch
};

/// The sequences to write. Every one whose output a locale can change,
/// and a few that it cannot, so that a locale breaking something it has
/// no business touching also shows up.
const formats = [_][]const u8{
    "MMMM",      "MMM",         "dddd",
    "ddd",       "dd",          "Do",
    "Mo",        "DDDo",        "do",
    "wo",        "Wo",          "A",
    "a",         "d",           "e",
    "E",         "w",           "ww",
    "W",         "gg",          "gggg",
    "GGGG",      "L",           "LL",
    "LLL",       "LLLL",        "l",
    "ll",        "lll",         "llll",
    "LT",        "LTS",         "D MMMM YYYY",
    "MMM D, Y",  "dddd, D MMM", "YYYY-MM-DD",
    "h:mm A",    "Do MMMM",     "[on] dddd",
    "wo [week]", "e E d",       "LLLL [and] LT",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    var line: [512]u8 = undefined;

    for (locale.all) |each| {
        for (instants) |at| {
            var value = Instant.fromMilliTimestamp(at).asDateTime();

            inline for (formats) |current| {
                var writer = std.Io.Writer.fixed(&line);
                try value.formatWith(current, each, &writer);
                const formatted = writer.buffered();

                // The record separator would otherwise be ambiguous.
                std.debug.assert(std.mem.indexOfAny(u8, current, "\t\n") == null);
                std.debug.assert(std.mem.indexOfAny(u8, formatted, "\t\n") == null);

                try out.print("{s}\t{d}\t{s}\t{s}\n", .{
                    each.tag,
                    at,
                    current,
                    formatted,
                });
            }
        }
    }

    try out.flush();
}
