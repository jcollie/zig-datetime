// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fuzz targets for everything here that reads input it did not write.
//!
//! Each target is a property written once and driven twice. `zig build
//! test` runs it over a list of seeds, which is what keeps a case that
//! once failed from coming back. `zig build --fuzz` hands the same
//! property to the fuzzer, which goes looking for new ones.
//!
//! The properties are deliberately weak about what a parser should
//! *accept*, because that is what the moment.js oracles are for and a
//! fuzzer has no opinion about it. What they check is that nothing
//! crashes on input nobody chose, and that whatever does come back holds
//! together: a date that says it parsed is a real date, a zone that says
//! it loaded can be asked about any instant, and anything with an inverse
//! survives the round trip.
//!
//! Any input reaching a parser here is untrusted by construction. A
//! panic, an unreachable, or an index out of bounds is a bug even when
//! the input is nonsense, which is the whole point of pointing a fuzzer
//! at it.

const std = @import("std");
const build_options = @import("build_options");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Instant = @import("Instant.zig");
const Month = @import("month.zig").Month;
const TimeZone = @import("TimeZone.zig");
const Year = @import("year.zig").Year;
const iso8601 = @import("iso8601.zig");
const posixtz = @import("posixtz.zig");
const rfc822 = @import("rfc822.zig");
const tzif = @import("tzif.zig");
const tzdb = @import("tzdb.zig");

/// The longest input any target reads. Long enough for a real date, a
/// POSIX rule, or a small TZif file, and short enough that the fuzzer
/// spends its time on shapes rather than on length.
const max_input = 256;

/// Runs `property` over each of `seeds`, which is what a normal test run
/// does with a fuzz target.
fn overSeeds(comptime property: fn ([]const u8) anyerror!void, seeds: []const []const u8) !void {
    for (seeds) |seed| try property(seed);
}

/// Hands `property` to the fuzzer, which is what `zig build --fuzz` does.
///
/// Note that `zig build --fuzz` does not work on Zig 0.16.0: its own test
/// runner fails to compile in fuzz mode, on any project, at
/// `compiler/test_runner.zig:566`. These targets are here for when that
/// is fixed; `overMutations` is what actually explores today.
fn overFuzzer(comptime property: fn ([]const u8) anyerror!void) !void {
    const driver = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const len = smith.slice(&buffer);
            try property(buffer[0..len]);
        }
    };
    try std.testing.fuzz({}, driver.one, .{});
}

/// Runs `property` over inputs built by mutating `seeds`, which is the
/// part that actually goes looking for something.
///
/// Random bytes on their own rarely reach far into a date parser, because
/// almost nothing is a date. Starting from inputs that are nearly right
/// and breaking them a little at a time gets past the first check and
/// into the arithmetic behind it, which is where the interesting failures
/// were: every bug this file found was an overflow reached through a
/// value that had already parsed.
///
/// The seed comes from the test runner, so `zig build test --seed=N`
/// replays a failure exactly.
fn overMutations(comptime property: fn ([]const u8) anyerror!void, seeds: []const []const u8) !void {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = prng.random();

    var buffer: [max_input]u8 = undefined;
    for (0..build_options.fuzz_iterations) |_| {
        const input = mutate(random, seeds, &buffer);
        property(input) catch |err| {
            std.debug.print(
                "fuzz: seed {d} produced {any}\n  on input: {s}\n  as bytes: {x}\n",
                .{ std.testing.random_seed, err, input, input },
            );
            return err;
        };
    }
}

/// Builds one input by taking a seed and damaging it.
fn mutate(random: std.Random, seeds: []const []const u8, buffer: []u8) []const u8 {
    const base = seeds[random.uintLessThan(usize, seeds.len)];
    var len = @min(base.len, buffer.len);
    @memcpy(buffer[0..len], base[0..len]);

    // Between one and four changes, so an input stays recognisable often
    // enough to get deep and is wrecked often enough to test the shallow
    // paths too.
    const rounds = random.uintLessThan(usize, 4) + 1;
    for (0..rounds) |_| {
        switch (random.uintLessThan(u8, 6)) {
            // Flip a byte to anything at all.
            0 => if (len > 0) {
                buffer[random.uintLessThan(usize, len)] = random.int(u8);
            },
            // Flip a byte to something a date might hold, which reaches
            // further in than a random byte does.
            1 => if (len > 0) {
                const alphabet = "0123456789:-+TZW.,/ abcdefMTWSJ<>";
                buffer[random.uintLessThan(usize, len)] =
                    alphabet[random.uintLessThan(usize, alphabet.len)];
            },
            // Cut it short.
            2 => if (len > 0) {
                len = random.uintLessThan(usize, len);
            },
            // Grow it with a byte.
            3 => if (len < buffer.len) {
                buffer[len] = random.int(u8);
                len += 1;
            },
            // Splice another seed onto the end.
            4 => {
                const other = seeds[random.uintLessThan(usize, seeds.len)];
                const take = @min(other.len, buffer.len - len);
                @memcpy(buffer[len..][0..take], other[0..take]);
                len += take;
            },
            // Repeat a stretch of it, which is how a length field or a
            // count gets somewhere unreasonable.
            else => if (len > 0 and len < buffer.len) {
                const take = @min(random.uintLessThan(usize, len) + 1, buffer.len - len);
                @memcpy(buffer[len..][0..take], buffer[0..take]);
                len += take;
            },
        }
    }

    return buffer[0..len];
}

/// Asserts that `datetime` is a date that could exist, which every parser
/// here promises about anything it returns.
fn isWellFormed(datetime: DateTime) !void {
    try std.testing.expect(datetime.asDate().isRegular());
    try std.testing.expectEqual(datetime.asDate().dayOfWeek(), datetime.weekday);
    try std.testing.expect(datetime.hour < 24);
    try std.testing.expect(datetime.minute < 60);
    try std.testing.expect(datetime.second <= 60);
    try std.testing.expect(datetime.nanosecond < std.time.ns_per_s);

    // An offset has to be one the syntaxes admit, which is wider than any
    // zone has ever used: RFC 3339 writes the hour as `00-23` and both
    // parsers here follow it, so `+20:24` is a well formed offset even
    // though no such zone exists. Asserting the real range instead --
    // -12:00 to +14:00 -- says the parsers are wrong when they are not.
    try std.testing.expect(datetime.offset > -24 * std.time.s_per_hour);
    try std.testing.expect(datetime.offset < 24 * std.time.s_per_hour);
}

// ISO 8601 -------------------------------------------------------------

/// Whatever `iso8601.parse` accepts has to be a real date, and what it
/// says it consumed has to be a prefix of what it was given.
fn iso8601Property(text: []const u8) !void {
    const result = iso8601.parse(text) catch return;

    try isWellFormed(result.value);
    try std.testing.expect(result.str.len <= text.len);
    try std.testing.expectEqualStrings(result.str, text[0..result.str.len]);

    // A reduced representation cannot claim more precision than it wrote.
    if (result.precision == .year) {
        try std.testing.expectEqual(Month.Jan, result.value.month);
        try std.testing.expectEqual(@as(u6, 1), result.value.day);
    }
    if (!result.has_offset) try std.testing.expectEqual(@as(i32, 0), result.value.offset);
}

const iso8601_seeds = [_][]const u8{
    "",           "2024-03-15",          "20240315",   "2024-03",              "2024",                        "2024-075",         "2024075",
    "2024-W11-5", "2024W115",            "2024-W11",   "2024-03-15T14:30:00Z", "2024-03-15T14:30:00.5+05:30", "2024-03-15T24:00", "2024-02-30",
    "2024-13-01", "2024-00-01",          "2024-W54-1", "2024-W00-1",           "2024-000",                    "2024-367",         "0000-01-01",
    "9999-12-31", "2024-03-15T14:30:60", "-------",    "TTTTTT",               "2024-03-15T",                 "2024-W",           "..",
    ",,",         "2024-03-15T.5",
};

test "iso8601.parse over the seeds" {
    try overSeeds(iso8601Property, &iso8601_seeds);
}

test "fuzz iso8601.parse" {
    try overFuzzer(iso8601Property);
}

test "mutate iso8601.parse" {
    try overMutations(iso8601Property, &iso8601_seeds);
}

// RFC 822 --------------------------------------------------------------

fn rfc822Property(text: []const u8) !void {
    const result = rfc822.parse(text) catch return;

    try isWellFormed(result.value);
    try std.testing.expect(result.str.len <= text.len);
    try std.testing.expectEqualStrings(result.str, text[0..result.str.len]);
}

const rfc822_seeds = [_][]const u8{
    "",                                "Sun, 06 Nov 1994 08:49:37 GMT",  "20 Jun 82 12:34 -0500",
    "Fri, 21 Nov 1997 09:55:06 -0600", "Mon, 06 Nov 1994 08:49:37 GMT",  "06 Nov 1994 08:49:37 Z",
    "32 Nov 1994 08:49:37 GMT",        "06 Xxx 1994 08:49:37 GMT",       "06 Nov 1994 25:49:37 GMT",
    "06 Nov 1994 08:49:37 +9999",      "Sun,,,06 Nov 1994 08:49:37 GMT", "\t\t\t",
    "Sun",                             "06 Nov",                         "06 Nov 1994",
    "06 Nov 1994 08:49",
};

test "rfc822.parse over the seeds" {
    try overSeeds(rfc822Property, &rfc822_seeds);
}

test "fuzz rfc822.parse" {
    try overFuzzer(rfc822Property);
}

test "mutate rfc822.parse" {
    try overMutations(rfc822Property, &rfc822_seeds);
}

// Format strings -------------------------------------------------------

/// Both parsing modes have to survive anything, and both have to keep
/// their promises about what they consumed.
fn formatStringProperty(text: []const u8) !void {
    inline for (.{ DateTime.Mode.lenient, DateTime.Mode.strict }) |mode| {
        // A format string with most of the shapes in it, so one input
        // exercises names, numbers, an offset and a literal at once.
        if (DateTime.parseWith("ddd, DD MMM YYYY HH:mm:ss ZZ", text, .{ .mode = mode })) |result| {
            try isWellFormed(result.value);
            try std.testing.expect(result.skipped <= result.str.len);
            try std.testing.expect(result.str.len <= text.len);

            // Strict takes all of it or none of it.
            if (mode == .strict) {
                try std.testing.expectEqual(text.len, result.str.len);
                try std.testing.expectEqual(@as(usize, 0), result.skipped);
            }
        } else |_| {}
    }
}

const format_string_seeds = [_][]const u8{
    "",                                     "Fri, 15 Mar 2024 14:30:05 +0000", "Fri, 15 Mar 2024 14:30:05 -0500",
    "Mon, 15 Mar 2024 14:30:05 +0000",      "Xxx, 15 Mar 2024 14:30:05 +0000", "Fri, 32 Mar 2024 14:30:05 +0000",
    "Fri, 15 Xxx 2024 14:30:05 +0000",      "Fri, 15 Mar 2024 24:00:00 +0000", "Fri, 15 Mar 2024 14:30:05",
    "Friday, 15 March 2024 14:30:05 +0000", ",,,,,,,,",                        "0000000000000000",
};

test "DateTime.parseWith over the seeds" {
    try overSeeds(formatStringProperty, &format_string_seeds);
}

test "fuzz DateTime.parseWith" {
    try overFuzzer(formatStringProperty);
}

test "mutate DateTime.parseWith" {
    try overMutations(formatStringProperty, &format_string_seeds);
}

// POSIX TZ rules -------------------------------------------------------

/// A rule that parses has to answer for any instant without falling over,
/// including the ends of the range.
fn posixtzProperty(text: []const u8) !void {
    const rule = posixtz.parse(text) catch return;

    // Inside the calendar the answers have to hold together.
    for ([_]i64{
        0,
        1710513005,
        -2208988800,
        std.math.minInt(i32),
        std.math.maxInt(i32),
        // A margin off each end, because placing a span needs the years
        // either side and the outermost year has none. See `Posix.spanAt`.
        Date.min_seconds + 2 * 366 * std.time.s_per_day,
        Date.max_seconds - 2 * 366 * std.time.s_per_day,
    }) |at| {
        const local_type = rule.typeAt(at);
        try std.testing.expect(local_type.designation.len > 0);

        // A span has to contain the instant it was asked about, which is
        // the whole reason a caller can trust its bounds.
        const span = rule.spanAt(at);
        try std.testing.expect(span.start <= at);
        try std.testing.expect(span.end > at);
        try std.testing.expectEqual(local_type.offset, span.local_type.offset);

        // The bounds have to be switches rather than arbitrary instants:
        // the span holds all the way to its end, and something else
        // begins there. This is what the agreement above stopped being
        // able to check once `typeAt` started deferring to `spanAt`.
        if (span.start > std.math.minInt(i64) and span.start < Date.max_seconds) {
            try std.testing.expectEqual(span.local_type.offset, rule.typeAt(span.start).offset);
        }
        if (span.end < Date.max_seconds and span.end > Date.min_seconds) {
            const next = rule.spanAt(span.end);
            try std.testing.expect(next.start >= span.end);
        }
    }

    // Outside it there is no year to evaluate the rule against, so the
    // only promise is that asking is safe. See `Posix.spanAt`.
    for ([_]i64{
        std.math.minInt(i64),
        std.math.maxInt(i64),
        Date.min_seconds,
        Date.max_seconds,
        Date.min_seconds - 1,
        Date.max_seconds + 1,
        std.math.minInt(i64) / 4,
        std.math.maxInt(i64) / 4,
    }) |at| {
        _ = rule.typeAt(at);
        _ = rule.spanAt(at);
    }
}

const posixtz_seeds = [_][]const u8{
    "",                           "CST6CDT,M3.2.0,M11.1.0", "IST-5:30",        "<-03>3",                 "EST5EDT",
    "EST5EDT,M3.2.0/2,M11.1.0/2", "CST6CDT,J60,J300",       "CST6CDT,59,300",  "CST6CDT,M3.5.0,M11.1.0", "AAA0BBB,M1.1.0/167,M1.1.0/-167",
    "AAA24BBB25,M1.1.0,M2.1.0",   "<>0",                    "<ABC",            "M3.2.0",                 "AAA0BBB,M13.1.0,M1.1.0",
    "AAA0BBB,M1.6.0,M1.1.0",      "AAA0BBB,M1.1.7,M1.1.0",  "AAA0BBB,J0,J366",
    // Ends at its own separator, which used to read past the end.
    "CST6CDT,M3.2.0/",        "CST6CDT,M3.2.0/2,M11.1.0/",
    "CST6CDT,M3.2.0/2,M11.1.0/-",
};

test "posixtz.parse over the seeds" {
    try overSeeds(posixtzProperty, &posixtz_seeds);
}

test "fuzz posixtz.parse" {
    try overFuzzer(posixtzProperty);
}

test "mutate posixtz.parse" {
    try overMutations(posixtzProperty, &posixtz_seeds);
}

// TZif files -----------------------------------------------------------

/// The one that reads a binary format rather than text, and the one most
/// worth pointing a fuzzer at: everything it returns is a slice into
/// bytes it was handed, sized by counts the same bytes claimed.
fn tzifProperty(bytes: []const u8) !void {
    const file = tzif.parse(bytes) catch return;

    // Every index the counts admit has to be readable.
    var index: usize = 0;
    while (index < file.transitionCount()) : (index += 1) _ = file.transitionAt(index);

    index = 0;
    while (index < file.typeCount()) : (index += 1) {
        const local_type = file.typeAt(index);
        // A designation is a slice into the file's own bytes and has to
        // stay inside them.
        try std.testing.expect(@intFromPtr(local_type.designation.ptr) >= @intFromPtr(bytes.ptr));
        try std.testing.expect(
            @intFromPtr(local_type.designation.ptr) + local_type.designation.len <=
                @intFromPtr(bytes.ptr) + bytes.len,
        );
    }

    _ = file.defaultType();
    _ = file.lastType();

    for ([_]i64{ 0, 1710513005, -2208988800, std.math.minInt(i64), std.math.maxInt(i64) }) |at| {
        if (file.spanAtTimestamp(at)) |span| {
            try std.testing.expect(span.start <= at);
            try std.testing.expect(span.end > at);
        }
        _ = file.typeAtTimestamp(at);
    }

    // Transitions are supposed to be sorted, which is what makes the
    // binary search in `spanAtTimestamp` mean anything.
    if (file.transitionCount() > 1) {
        index = 1;
        while (index < file.transitionCount()) : (index += 1) {
            if (file.transitionAt(index - 1) > file.transitionAt(index)) break;
        }
    }
}

const tzif_seeds = [_][]const u8{
    "",                        "TZif",                   "TZif2",                                    "TZif" ++ ("\x00" ** 40), "TZif" ++ ("\xff" ** 40),
    "TZif2" ++ ("\x00" ** 39), "XZif" ++ ("\x00" ** 40), "TZif" ++ ("\x00" ** 15) ++ ("\xff" ** 25),
};

test "tzif.parse over the seeds" {
    try overSeeds(tzifProperty, &tzif_seeds);
}

test "fuzz tzif.parse" {
    try overFuzzer(tzifProperty);
}

test "mutate tzif.parse" {
    try overMutations(tzifProperty, &tzif_seeds);
}

// Zone names -----------------------------------------------------------

/// A name that validates is about to be joined onto a directory, so it
/// must not be able to reach outside one.
fn zoneNameProperty(text: []const u8) !void {
    tzdb.validateName(text) catch return;

    try std.testing.expect(text.len > 0);
    try std.testing.expect(text[0] != '/');
    try std.testing.expect(text[0] != '.');
    try std.testing.expect(std.mem.indexOf(u8, text, "..") == null);
    for (text) |char| try std.testing.expect(std.ascii.isPrint(char));
}

const zone_name_seeds = [_][]const u8{
    "",                    "UTC",         "America/Chicago", "Etc/GMT+5", "US/Central",
    "../../etc/passwd",    "/etc/passwd", ".hidden",         "a/../b",    "a//b",
    "America/Chicago\x00", "\x00",        "..",              ".",         "a" ** 257,
};

test "tzdb.validateName over the seeds" {
    try overSeeds(zoneNameProperty, &zone_name_seeds);
}

test "fuzz tzdb.validateName" {
    try overFuzzer(zoneNameProperty);
}

test "mutate tzdb.validateName" {
    try overMutations(zoneNameProperty, &zone_name_seeds);
}

// Round trips ----------------------------------------------------------

// Anything with an inverse has to survive it, for any date at all rather
// than the handful a test would think to write down.
test "fuzz the calendar round trips" {
    const driver = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const year = smith.valueRangeAtMost(Year, -10000, 10000);
            const month: Month = @enumFromInt(smith.valueRangeAtMost(u4, 1, 12));
            const date: Date = .{
                .year = year,
                .month = month,
                .day = smith.valueRangeAtMost(u6, 1, month.lastDay(year)),
            };

            // A date is its day number and back again.
            try std.testing.expectEqual(date, Date.fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra()));

            // And its day of the year and back again.
            const day_of_year = @as(i32, date.month.daysBefore(date.year)) + date.day;
            try std.testing.expectEqual(date, Date.fromDayOfYear(date.year, day_of_year));

            // And its week and weekday and back again, under either rule.
            const iso = date.isoWeek();
            try std.testing.expectEqual(date, Date.fromWeek(iso.year, iso.week, date.dayOfWeek(), .Mon, 4));
            try std.testing.expect(iso.week >= 1 and iso.week <= 53);

            const locale = date.localeWeek();
            try std.testing.expectEqual(date, Date.fromWeek(locale.year, locale.week, date.dayOfWeek(), .Sun, 1));
            try std.testing.expect(locale.week >= 1 and locale.week <= 54);
        }
    };
    try std.testing.fuzz({}, driver.one, .{});
}

// Formatting and parsing are inverses for any instant, which is the
// property the moment oracles cannot check because they compare text
// rather than values.
test "fuzz format and parse round trip" {
    const driver = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            // Kept inside the range a four digit year can write, since
            // the format string cannot express anything wider.
            const at = smith.valueRangeAtMost(i64, -62135596800, 253402300799);
            const offset_minutes = smith.valueRangeAtMost(i32, -12 * 60, 14 * 60);
            const seconds = offset_minutes * 60;

            const shifted: Instant = .{
                .timestamp = @as(i128, at + seconds) * std.time.ns_per_s,
            };
            var value = shifted.asDateTime();
            value.offset = seconds;

            var buffer: [64]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try value.format("YYYY-MM-DDTHH:mm:ssZ", &writer);

            const parsed = try DateTime.parseStrict("YYYY-MM-DDTHH:mm:ssZ", writer.buffered());
            try std.testing.expectEqual(value.year, parsed.value.year);
            try std.testing.expectEqual(value.month, parsed.value.month);
            try std.testing.expectEqual(value.day, parsed.value.day);
            try std.testing.expectEqual(value.hour, parsed.value.hour);
            try std.testing.expectEqual(value.minute, parsed.value.minute);
            try std.testing.expectEqual(value.second, parsed.value.second);
            try std.testing.expectEqual(value.offset, parsed.value.offset);
            try std.testing.expectEqual(value.weekday, parsed.value.weekday);
        }
    };
    try std.testing.fuzz({}, driver.one, .{});
}
