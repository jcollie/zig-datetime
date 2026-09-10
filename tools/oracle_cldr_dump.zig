// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a corpus of instants against a corpus of CLDR patterns and
//! writes the results out for `tools/oracle_cldr.cpp` to check against
//! ICU, which is the reference implementation of UTS #35.
//!
//! The corpus lives here for the same reason the other oracles' do: a
//! pattern has to be comptime known for `cldr.format` to take it apart
//! while this is compiled, so only this side can enumerate them.
//!
//! Output is one record per line, tab separated, of two kinds.
//!
//! A `P` record is a pattern applied to a value: the locale, the instant
//! as milliseconds since the Unix epoch, the offset it is read at in
//! seconds east of UTC, the pattern, and what this library wrote. The
//! offset is in seconds rather than minutes because the corpus includes a
//! sub-minute one -- America/Chicago's local mean time -- which is the
//! only thing that exercises the seconds field of an ISO 8601 offset.
//!
//! An `S` record is the locale's own idea of a date and a time: the same
//! first three fields, then which of the four lengths was asked for on
//! each side and what came out. A length of -1 asks for that half to be
//! left off, so the three of them cover `formatDate`, `formatTime` and
//! `formatDateTime`. Nothing on the ICU side is given a pattern for
//! these; it is asked the same question through `createDateInstance` and
//! its neighbours, so what is being compared is two libraries' reading of
//! the same locale data rather than one library's reading of the other's
//! answer.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const Date = datetime.Date;
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;
const cldr = datetime.cldr;

/// Milliseconds since the Unix epoch at a UTC wall clock reading.
///
/// The corpus is written as readings rather than as numbers because a
/// bare millisecond count says nothing about what is being tested, and
/// because the interesting instants are the ones at a boundary of the
/// calendar rather than at a round number.
fn at(year: i32, month: datetime.Month, day: u8, hour: u8, minute: u8, second: u8, milli: u16) i64 {
    const date: Date = .{ .year = year, .month = month, .day = day };
    const days: i64 = date.toDaysSinceStartOfEra();
    return ((days * 86400) + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second) * 1000 + milli;
}

/// The instants to format.
///
/// Milliseconds rather than nanoseconds throughout, because ICU holds
/// milliseconds and an instant it cannot represent would be a divergence
/// about the corpus rather than about the code. The one place this
/// library writes more than ICU can -- a fraction past the third place --
/// is checked by a test of its own rather than here.
const instants = [_]i64{
    at(2024, .Mar, 5, 19, 30, 45, 123), // an ordinary afternoon at -05:00
    at(2024, .Jan, 1, 0, 0, 0, 0), // the first instant of a year
    at(2024, .Dec, 31, 23, 59, 59, 999), // and the last
    at(2024, .Feb, 29, 12, 0, 0, 0), // the leap day, at noon
    at(2024, .Jul, 4, 5, 0, 0, 0), // an early morning
    at(2024, .Jul, 4, 12, 0, 0, 0), // exactly noon, which `b` names
    at(2024, .Jul, 4, 0, 0, 0, 0), // exactly midnight, which it also names
    at(2024, .Jul, 4, 12, 0, 0, 1), // a millisecond past noon, which it does not
    at(2024, .Jul, 4, 18, 30, 0, 0), // the evening, in the languages that have one
    at(2024, .Jul, 4, 22, 15, 0, 0), // the night
    at(1970, .Jan, 1, 0, 0, 0, 0), // the epoch
    at(1900, .Jan, 1, 12, 0, 0, 0), // well before it
    at(1, .Jan, 1, 12, 0, 0, 0), // year 1, where a four digit year is padding
    at(0, .Jun, 15, 12, 0, 0, 0), // year zero, which is 1 BC
    at(-90, .Mar, 15, 12, 0, 0, 0), // a year that needs a sign as well
};

/// The offsets those instants are read at, in seconds east of UTC.
const offsets = [_]i32{
    0, // where the ISO 8601 fields write `Z` and the localized ones do not
    -5 * 3600, // a whole number of hours
    5 * 3600 + 45 * 60, // Kathmandu, a quarter hour past the half
    -(9 * 3600 + 30 * 60), // Adelaide's neighbour on the other side
    14 * 3600, // Kiritimati, the far end of the range
    -21036, // America/Chicago's local mean time, which has seconds in it
};

/// Every field UTS #35 assigns, at every count this library accepts.
///
/// Written out rather than generated so that a count nobody thought about
/// is visibly absent, and in the order UTS #35's own table of pattern
/// characters gives them.
const field_patterns = [_][]const u8{
    "G",      "GG",     "GGG",      "GGGG",     "GGGGG",
    "y",      "yy",     "yyy",      "yyyy",     "yyyyy",
    "Y",      "YY",     "YYY",      "YYYY",     "u",
    "uu",     "uuuu",   "U",        "UU",       "UUUU",
    "r",      "rr",     "rrrr",     "Q",        "QQ",
    "QQQ",    "QQQQ",   "QQQQQ",    "q",        "qq",
    "qqq",    "qqqq",   "qqqqq",    "M",        "MM",
    "MMM",    "MMMM",   "MMMMM",    "L",        "LL",
    "LLL",    "LLLL",   "LLLLL",    "w",        "ww",
    "W",      "d",      "dd",       "D",        "DD",
    "DDD",    "F",      "g",        "gggggggg", "E",
    "EE",     "EEE",    "EEEE",     "EEEEE",    "EEEEEE",
    "e",      "ee",     "eee",      "eeee",     "eeeee",
    "eeeeee", "c",      "cc",       "ccc",      "cccc",
    "ccccc",  "cccccc", "a",        "aa",       "aaa",
    "aaaa",   "aaaaa",  "b",        "bb",       "bbb",
    "bbbb",   "bbbbb",  "B",        "BB",       "BBB",
    "BBBB",   "BBBBB",  "h",        "hh",       "hhh",
    "H",      "HH",     "HHH",      "K",        "KK",
    "k",      "kk",     "m",        "mm",       "mmm",
    "s",      "ss",     "sss",      "S",        "SS",
    "SSS",    "A",      "AAAAAAAA", "z",        "zzzz",
    "Z",      "ZZ",     "ZZZ",      "ZZZZ",     "ZZZZZ",
    "O",      "OOOO",   "v",        "vvvv",     "VVVV",
    "X",      "XX",     "XXX",      "XXXX",     "XXXXX",
    "x",      "xx",     "xxx",      "xxxx",     "xxxxx",
};

/// The shapes a caller actually writes, and the corners of the tokenizer.
///
/// The corners are the ones where quoting decides what a letter is: a
/// doubled quote outside a literal and inside one, a literal holding
/// letters that would otherwise be fields, and a pattern that is nothing
/// but text.
const shape_patterns = [_][]const u8{
    "yyyy-MM-dd",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm:ssXXX",
    "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
    "EEE, d MMM yyyy HH:mm:ss Z",
    "EEEE, MMMM d, y",
    "d MMMM y 'at' h:mm a",
    "h:mm a",
    "HH:mm",
    "H'h'mm",
    "''",
    "'it''s' y",
    "'yyyy'",
    "y'yyyy'y",
    "'[literal]'",
    "- / . , : ;",
    "GGGG y, QQQQ, MMMM, 'week' w",
    "y-MM-dd HH:mm:ss.SSS ZZZZZ",
};

/// The patterns every locale is checked with.
///
/// Narrower than the field corpus and chosen for what a locale can differ
/// about: the names at each width and context, the two ways of naming a
/// part of the day, the week rule, the digits, and the four shapes of
/// offset that go through the locale's own wrapper.
const locale_patterns = [_][]const u8{
    "MMMM",     "MMM",    "MMMMM", "LLLL",   "LLLLL",
    "EEEE",     "EEE",    "EEEEE", "EEEEEE", "cccc",
    "QQQQ",     "QQQ",    "qqqq",  "G",      "GGGG",
    "GGGGG",    "a",      "aaaa",  "aaaaa",  "b",
    "bbbb",     "bbbbb",  "B",     "BBBB",   "BBBBB",
    "w",        "ww",     "W",     "e",      "ee",
    "c",        "F",      "y",     "yy",     "yyyy-MM-dd",
    "HH:mm:ss", "h:mm a", "SSS",   "D",      "g",
    "z",        "zzzz",   "O",     "OOOO",   "ZZZZ",
    "ZZZZZ",    "XXX",    "vvvv",  "VVVV",   "d MMMM y",
};

/// The instants every locale is checked at, as indexes into `instants`.
///
/// Fewer than the whole list, because seven hundred and sixty-six locales
/// times the whole corpus is a great many comparisons for very little
/// more coverage: what a locale differs about is its names and its rules,
/// and these are the readings that reach every day period and both sides
/// of the era boundary.
const locale_instant_indexes = [_]usize{ 0, 4, 5, 6, 8, 9, 13 };

/// The offsets every locale is checked at, as indexes into `offsets`.
const locale_offset_indexes = [_]usize{ 0, 1, 5 };

/// Which lengths to ask the locale for, where -1 leaves that half of the
/// answer off.
const styles = [_][2]i8{
    .{ 0, -1 }, .{ 1, -1 }, .{ 2, -1 }, .{ 3, -1 },
    .{ -1, 0 }, .{ -1, 1 }, .{ -1, 2 }, .{ -1, 3 },
    .{ 0, 0 },  .{ 1, 1 },  .{ 2, 2 },  .{ 3, 3 },
    .{ 0, 3 },  .{ 3, 0 },  .{ 2, 3 },
};

/// Reads `millis` at `offset`, which is the value both sides are asked
/// about.
fn reading(millis: i64, offset: i32) DateTime {
    const shifted: Instant = .{
        .timestamp = Instant.fromMilliTimestamp(millis).timestamp +
            @as(i128, offset) * std.time.ns_per_s,
    };
    var value = shifted.asDateTime();
    value.offset = offset;
    return value;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [64 * 1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    // The vocabulary, in English: every field at every count, and the
    // shapes callers write, against every instant and every offset.
    for (instants) |millis| {
        for (offsets) |offset| {
            const value = reading(millis, offset);
            inline for (field_patterns ++ shape_patterns) |pattern| {
                try out.print("P\t{s}\t{d}\t{d}\t{s}\t", .{ cldr.en.tag, millis, offset, pattern });
                try cldr.format(value, pattern, cldr.en, out);
                try out.writeByte('\n');
            }
        }
    }

    // And then every locale this build carries, which is what
    // `-Dembed-cldr` is for. Without it there is only `en` and the sweep
    // above is the whole of the check.
    for (cldr.all) |locale| {
        for (locale_instant_indexes) |instant_index| {
            const millis = instants[instant_index];
            for (locale_offset_indexes) |offset_index| {
                const offset = offsets[offset_index];
                const value = reading(millis, offset);

                inline for (locale_patterns) |pattern| {
                    try out.print("P\t{s}\t{d}\t{d}\t{s}\t", .{ locale.tag, millis, offset, pattern });
                    try cldr.format(value, pattern, locale, out);
                    try out.writeByte('\n');
                }

                for (styles) |pair| {
                    try out.print("S\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{
                        locale.tag,
                        millis,
                        offset,
                        pair[0],
                        pair[1],
                    });
                    if (pair[0] < 0) {
                        try cldr.formatTime(value, @enumFromInt(pair[1]), locale, out);
                    } else if (pair[1] < 0) {
                        try cldr.formatDate(value, @enumFromInt(pair[0]), locale, out);
                    } else {
                        try cldr.formatDateTime(
                            value,
                            @enumFromInt(pair[0]),
                            @enumFromInt(pair[1]),
                            locale,
                            out,
                        );
                    }
                    try out.writeByte('\n');
                }
            }
        }
    }

    try out.flush();
}
