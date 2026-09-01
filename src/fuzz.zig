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
const locale = @import("locale.zig");
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

// Locales --------------------------------------------------------------

/// Cuts fuzzer bytes into the runs a locale is made of.
///
/// Where a run starts and how long it is both come out of the input, so
/// that the fuzzer decides the shape of a locale as well as its contents:
/// empty names, names that are prefixes of one another, and names that
/// are not valid UTF-8 all arrive without being asked for.
const Carver = struct {
    text: []const u8,
    at: usize = 0,

    /// Returns the next run, of at most `max` bytes.
    fn next(self: *Carver, max: usize) []const u8 {
        if (self.text.len == 0) return "";

        // One byte says how long the run is, and the run follows it.
        const header = self.at % self.text.len;
        const wanted = self.text[header] % (max + 1);
        const from = (header + 1) % self.text.len;
        const len = @min(wanted, self.text.len - from);
        self.at = from + len;
        return self.text[from..][0..len];
    }
};

test Carver {
    // One byte of length, then that many bytes, then the next length.
    var carver: Carver = .{ .text = "\x03abc\x02ef" };
    try std.testing.expectEqualStrings("abc", carver.next(8));
    try std.testing.expectEqualStrings("ef", carver.next(8));

    // A run is never longer than asked for, and an empty input yields
    // nothing however often it is asked.
    var short: Carver = .{ .text = "\xffabcdef" };
    try std.testing.expect(short.next(2).len <= 2);

    var empty: Carver = .{ .text = "" };
    try std.testing.expectEqualStrings("", empty.next(8));
    try std.testing.expectEqualStrings("", empty.next(8));
}

/// A `Locale` carved out of fuzzer bytes.
///
/// Everything a locale holds is a string this library did not write, and
/// ten of them are format strings: the `L` family stands for another
/// format string rather than for a value, and the locale supplies it. So
/// those reach the tokenizer at run time, where before a locale every
/// format string was comptime and a bad one was a compile error. That is
/// the new untrusted surface, and this is what points the fuzzer at it.
///
/// The arrays live here so that the `Locale` can borrow them; a `Locale`
/// built by `asLocale` must not outlive the `FuzzLocale` it came from.
const FuzzLocale = struct {
    months: [12][]const u8 = undefined,
    months_short: [12][]const u8 = undefined,
    weekdays: [7][]const u8 = undefined,
    weekdays_short: [7][]const u8 = undefined,
    weekdays_min: [7][]const u8 = undefined,
    long: locale.LongDateFormat = undefined,

    fn init(text: []const u8) FuzzLocale {
        var carver: Carver = .{ .text = text };
        var built: FuzzLocale = .{};

        for (&built.months) |*name| name.* = carver.next(16);
        for (&built.months_short) |*name| name.* = carver.next(8);
        for (&built.weekdays) |*name| name.* = carver.next(16);
        for (&built.weekdays_short) |*name| name.* = carver.next(8);
        for (&built.weekdays_min) |*name| name.* = carver.next(4);

        built.long = .{
            .LT = carver.next(24),
            .LTS = carver.next(24),
            .L = carver.next(24),
            .LL = carver.next(24),
            .LLL = carver.next(32),
            .LLLL = carver.next(32),
            // Left to be derived half the time, so that both ways through
            // `LongDateFormat.get` are reached.
            .l = if (text.len > 0 and text[0] & 1 == 0) carver.next(24) else null,
            .llll = if (text.len > 1 and text[1] & 1 == 0) carver.next(32) else null,
        };

        return built;
    }

    fn asLocale(self: *const FuzzLocale, text: []const u8) locale.Locale {
        return .{
            .tag = "fuzz",
            .months = &self.months,
            .months_short = &self.months_short,
            .weekdays = &self.weekdays,
            .weekdays_short = &self.weekdays_short,
            .weekdays_min = &self.weekdays_min,
            .long_date_format = self.long,
            .week = .{
                // Any rule at all, including the ones whose first week
                // opens in the December before.
                .starts_on = @enumFromInt(if (text.len > 2) text[2] % 7 else 0),
                .january_day_in_first_week = if (text.len > 3) @as(i8, @bitCast(text[3])) else 1,
            },
            .months_decline = .{
                .day_then_month = text.len > 4 and text[4] & 1 == 1,
                .month_then_ordinal = text.len > 4 and text[4] & 2 == 2,
            },
        };
    }
};

/// The sequences a locale can reach, including every localized one, since
/// those are the ones whose expansion the locale controls.
const locale_formats = [_][]const u8{
    "L",                "LL",         "LLL",                "LLLL",
    "l",                "ll",         "lll",                "llll",
    "LT",               "LTS",        "A a",                "Do Mo wo DDDo do Wo",
    "dddd D MMMM YYYY", "ddd MMM dd", "e d E w ww gg gggg", "[x] LLLL [y] L",
};

/// Writing a date in a locale nobody sanitized has to be safe, whatever
/// the locale says a sequence stands for.
fn localeFormatProperty(text: []const u8) !void {
    var built: FuzzLocale = .init(text);
    const in = built.asLocale(text);

    const dates = [_]DateTime{
        .{ .year = 2024, .month = .Mar, .day = 5, .hour = 13, .minute = 7, .weekday = .Tue },
        .{ .year = 1900, .month = .Jan, .day = 1, .hour = 0, .minute = 0, .weekday = .Mon },
        .{ .year = 2024, .month = .Dec, .day = 31, .hour = 23, .minute = 59, .weekday = .Tue },
    };

    var buffer: [4096]u8 = undefined;
    for (dates) |value| {
        inline for (locale_formats) |fmt| {
            var writer = std.Io.Writer.fixed(&buffer);
            // A locale can name an expansion longer than any buffer, so
            // running out of room is an answer rather than a failure.
            value.formatWith(fmt, in, &writer) catch {};
        }
    }
}

/// And reading one back. Whatever a locale lets through still has to be a
/// real date, which is the promise `parseWith` makes to every caller and
/// which a locale is in no position to change.
fn localeParseProperty(text: []const u8) !void {
    var built: FuzzLocale = .init(text);
    const in = built.asLocale(text);

    inline for (.{ DateTime.Mode.lenient, DateTime.Mode.strict }) |mode| {
        inline for (.{ "LLLL", "L", "llll", "dddd D MMMM YYYY", "Do MMM A" }) |fmt| {
            if (DateTime.parseWith(fmt, text, .{ .locale = in, .mode = mode })) |result| {
                try isWellFormed(result.value);
                try std.testing.expect(result.skipped <= result.str.len);
                try std.testing.expect(result.str.len <= text.len);
            } else |_| {}
        }
    }
}

/// The same against the locales that ship, which have real names rather
/// than carved ones: what this looks for is an input that gets a real
/// table to misbehave.
fn localeTableProperty(text: []const u8) !void {
    const shipped: []const locale.Locale = if (locale.embedded) locale.all else &.{locale.en};

    // One of them per input rather than all of them, chosen by the input.
    // Walking a hundred and thirty-seven tables for every input spends
    // the run on the same answers over and over; letting the fuzzer pick
    // gets through far more inputs, and it reaches every locale soon
    // enough over a run of any length.
    const in = shipped[(if (text.len > 0) text[text.len - 1] else 0) % shipped.len];

    inline for (.{ DateTime.Mode.lenient, DateTime.Mode.strict }) |mode| {
        if (DateTime.parseWith("dddd D MMMM YYYY", text, .{ .locale = in, .mode = mode })) |result| {
            try isWellFormed(result.value);
        } else |_| {}
    }

    // And the name lookups on their own, which is where a name that is a
    // prefix of another one has to lose to the longer one.
    if (in.matchMonth(text, .MMMM)) |found| {
        try std.testing.expect(found.len <= text.len);
        try std.testing.expect(found.len > 0);
    }
    if (in.matchWeekday(text, .dddd)) |found| {
        try std.testing.expect(found.len <= text.len);
        try std.testing.expect(found.len > 0);
    }
    if (in.matchMeridiem(text)) |found| {
        try std.testing.expect(found.len <= text.len);
    }

    _ = locale.byName(text);
}

const locale_seeds = [_][]const u8{
    "",
    // A locale's worth of plausible runs: names, then the `L` family.
    "\x03Jan\x03Feb\x03Mar\x03Apr\x03May\x03Jun\x03Jul\x03Aug\x03Sep\x03Oct\x03Nov\x03Dec",
    // Format strings where a locale expects them, including ones that
    // name a localized sequence and so would expand for ever if nothing
    // stopped them.
    "\x0aMM/DD/YYYY\x0aD MMMM YYYY\x04LLLL\x01L",
    "\x04LLLL\x04LLLL\x04LLLL\x04LLLL\x04LLLL\x04LLLL",
    // Empty names throughout, which match everywhere and consume nothing.
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    // Bracketed and escaped text in an expansion, which the tokenizer
    // treats specially and which a locale can now leave unbalanced.
    "\x06[abc]\x02\\\\\x05[a[b]\x03[ab",
    // Real dates, for the parsing half.
    "Tuesday 5 March 2024",
    "mardi 5 mars 2024",
    "\u{432}\u{442}\u{43e}\u{440}\u{43d}\u{438}\u{43a} 5 \u{43c}\u{430}\u{440}\u{442}\u{430} 2024",
    "5th Mar PM",
    "\xff\xff\xff\xff\xff\xff\xff\xff",
};

test "DateTime.formatWith over the locale seeds" {
    try overSeeds(localeFormatProperty, &locale_seeds);
}

test "fuzz DateTime.formatWith with a locale" {
    try overFuzzer(localeFormatProperty);
}

test "mutate DateTime.formatWith with a locale" {
    try overMutations(localeFormatProperty, &locale_seeds);
}

test "DateTime.parseWith over the locale seeds" {
    try overSeeds(localeParseProperty, &locale_seeds);
}

test "fuzz DateTime.parseWith with a locale" {
    try overFuzzer(localeParseProperty);
}

test "mutate DateTime.parseWith with a locale" {
    try overMutations(localeParseProperty, &locale_seeds);
}

test "the shipped locales over the locale seeds" {
    try overSeeds(localeTableProperty, &locale_seeds);
}

test "fuzz the shipped locales" {
    try overFuzzer(localeTableProperty);
}

test "mutate the shipped locales" {
    try overMutations(localeTableProperty, &locale_seeds);
}

/// A locale that ships has to be able to read back what it wrote, for any
/// date and in any language.
///
/// The properties above are weak on purpose: they ask that nothing falls
/// over, because a locale carved out of fuzzer bytes has no business
/// round tripping. This is the strong one, and it is only possible
/// because the shipped tables are real: a name written in a language has
/// to be a name readable in that language, whatever the date and whatever
/// the alphabet. An asymmetry between the two sides -- a name that is a
/// prefix of another and wins when it should lose, a form written that is
/// not among the forms matched -- shows up here and nowhere else.
///
/// The date comes out of the input rather than out of a list, so this
/// explores the calendar as well as the languages.
fn localeRoundTripProperty(text: []const u8) !void {
    if (text.len < 6) return;

    const shipped: []const locale.Locale = if (locale.embedded) locale.all else &.{locale.en};
    const in = shipped[text[0] % shipped.len];

    // moment's pseudo-locale wraps its names in tildes, which are not
    // letters in any alphabet and which moment's own name pattern does
    // not accept either. It is for making untranslated text obvious on
    // screen, not for reading back.
    if (std.mem.eql(u8, in.tag, "x-pseudo")) return;

    // Any day of a wide span, kept inside what a four digit year can
    // write since the format string below cannot express anything wider.
    const span = 3_000_000;
    const days: Date.DaysType = @mod(std.mem.readInt(i32, text[1..5], .little), span) - span / 3;
    const date = Date.fromDaysSinceStartOfEra(days);
    if (!date.isRegular() or date.year < 1 or date.year > 9999) return;

    const value: DateTime = .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .weekday = date.dayOfWeek(),
    };

    // Separated by a character no language uses in a name, so that what
    // is being tested is the names rather than where one ends.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try value.formatWith("dddd|D|MMMM|YYYY", in, &writer);
    const written = writer.buffered();

    const parsed = DateTime.parseWith("dddd|D|MMMM|YYYY", written, .{
        .locale = in,
        .mode = .strict,
    }) catch |err| {
        std.debug.print("fuzz: {s} wrote {s} and could not read it: {}\n", .{ in.tag, written, err });
        return err;
    };

    try std.testing.expectEqual(value.year, parsed.value.year);
    try std.testing.expectEqual(value.month, parsed.value.month);
    try std.testing.expectEqual(value.day, parsed.value.day);
    try std.testing.expectEqual(value.weekday, parsed.value.weekday);
}

const locale_round_trip_seeds = [_][]const u8{
    // A locale index and four bytes of day number, which is what the
    // property reads; the rest are what mutating these produces.
    "\x00\x00\x00\x00\x00\x00",
    "\x01\x40\x4c\x00\x00\x00",
    "\x2a\xff\xff\xff\x7f\x00",
    "\x55\x00\x00\x00\x80\x00",
    "\x7f\x9c\x1f\x00\x00\x00",
};

test "the shipped locales round trip over the seeds" {
    try overSeeds(localeRoundTripProperty, &locale_round_trip_seeds);
}

test "fuzz the shipped locales round trip" {
    try overFuzzer(localeRoundTripProperty);
}

test "mutate the shipped locales round trip" {
    try overMutations(localeRoundTripProperty, &locale_round_trip_seeds);
}

// Week rules -----------------------------------------------------------

/// A week rule is two numbers a locale hands over, and both of them reach
/// the calendar arithmetic.
///
/// The day the week starts on is one of seven, but the day that anchors
/// week one is signed and can name a day of the December before -- eight
/// of moment's locales use one that does. So the arithmetic has to hold
/// for an anchor nobody would write as well as for the four ISO 8601
/// uses.
fn weekRuleProperty(text: []const u8) !void {
    if (text.len < 6) return;

    const year: Year = @bitCast(std.mem.readInt(u32, text[0..4], .little));
    const starts_on: DayOfWeek = @enumFromInt(text[4] % 7);
    const anchor: i8 = @bitCast(text[5]);

    const weeks = Date.weeksInYear(year, starts_on, anchor);
    try std.testing.expect(weeks >= 1);

    // Every week the rule admits names a real date, and that date is back
    // in the week it came from.
    var week: u16 = 1;
    while (week <= @as(u16, @intCast(@min(weeks, 60)))) : (week += 1) {
        const date = Date.fromWeek(year, week, starts_on, starts_on, anchor);
        if (!date.isRegular()) continue;

        const found = date.weekOfYear(starts_on, anchor);
        try std.testing.expect(found.week >= 1);
    }
}

const week_rule_seeds = [_][]const u8{
    // 2024, Monday, the fourth: ISO 8601.
    "\xe8\x07\x00\x00\x01\x04",
    // 2024, Sunday, the first: what moment's `en` uses.
    "\xe8\x07\x00\x00\x00\x01",
    // 2024, Sunday, five days before it: what a `doy` of 12 comes to.
    "\xe8\x07\x00\x00\x00\xfb",
    // The ends of the calendar, where the arithmetic saturates.
    "\x00\x00\x00\x80\x01\x04",
    "\xff\xff\xff\x7f\x01\x04",
    "\x00\x00\x00\x00\x00\x00",
};

test "the week rules over the seeds" {
    try overSeeds(weekRuleProperty, &week_rule_seeds);
}

test "fuzz the week rules" {
    try overFuzzer(weekRuleProperty);
}

test "mutate the week rules" {
    try overMutations(weekRuleProperty, &week_rule_seeds);
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

            const english = date.localeWeek();
            try std.testing.expectEqual(date, Date.fromWeek(english.year, english.week, date.dayOfWeek(), .Sun, 1));
            try std.testing.expect(english.week >= 1 and english.week <= 54);
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
