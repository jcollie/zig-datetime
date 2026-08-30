//! Parsing of the date and time syntax defined by RFC 822 section 5, as
//! amended by RFC 1123 section 5.2.14 (four digit years) and RFC 5322
//! sections 3.3 and 4.3 (obsolete forms). This is the format used by
//! internet message headers such as `Date:`, by HTTP, and by RSS.
//!
//! The grammar accepted here is
//!
//!     [ day-of-week [ "," ] ] day month year hour ":" minute [ ":" second ] zone
//!
//! with runs of spaces and tabs between the components, for example
//! `Sun, 06 Nov 1994 08:49:37 GMT` or `20 Jun 82 12:34 -0500`.

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Month = @import("month.zig").Month;
const Second = @import("second.zig").Second;
const Year = @import("year.zig").Year;
const read = @import("read.zig");

pub const ParseError = error{ParseError};

/// The result of a successful parse: the prefix of the input that was
/// consumed and the value it parsed to.
pub const ParseResult = struct {
    str: []const u8,
    value: DateTime,
};

/// Parses an RFC 822 date and time at the start of `value`, returning the
/// local wall-clock time exactly as written along with its UTC offset in
/// `DateTime.offset`. Trailing text after the zone is left unconsumed; the
/// caller can find where the date ended through `ParseResult.str`.
///
/// Leading spaces and tabs are skipped, so a header value may be passed in
/// without trimming it first. Beyond that the input is taken strictly:
/// month and day names must be the three letter abbreviations (matched
/// case-insensitively), and the zone is required. As RFC 5322 section 3.3
/// requires, a day of the week that disagrees with the date it precedes is
/// `error.ParseError` rather than being ignored.
pub fn parse(value: []const u8) ParseError!ParseResult {
    var left = value;

    skipSpace(&left);

    // [ day-of-week [ "," ] ] -- no day name begins with a digit, so a
    // leading name is never ambiguous with the day of the month.
    const day_of_week: ?DayOfWeek = day_of_week: {
        const result = DayOfWeek.parseShortStr(left) catch break :day_of_week null;
        left = left[result.str.len..];
        if (left.len > 0 and left[0] == ',') left = left[1..];
        try skipRequiredSpace(&left);
        break :day_of_week result.value;
    };

    // date = day month year
    const day: Day = day: {
        const parsed = try digits(&left, 1, 2);
        if (parsed.value < 1 or parsed.value > 31) return error.ParseError;
        break :day @intCast(parsed.value);
    };
    try skipRequiredSpace(&left);

    const month: Month = month: {
        for (1..left.len + 1) |l| {
            if (Month.short_map.get(left[0..l])) |month| {
                left = left[l..];
                break :month month;
            }
        }
        return error.ParseError;
    };
    try skipRequiredSpace(&left);

    const year: Year = year: {
        const parsed = try digits(&left, 2, 4);
        // RFC 5322 section 4.3 obs-year: a two digit year in 00-49 means
        // 2000-2049 and one in 50-99 means 1950-1999, while a three digit
        // year is an offset from 1900.
        break :year switch (parsed.len) {
            2 => if (parsed.value < 50) 2000 + @as(Year, parsed.value) else 1900 + @as(Year, parsed.value),
            3 => 1900 + @as(Year, parsed.value),
            4 => @as(Year, parsed.value),
            else => unreachable,
        };
    };

    if (day > month.lastDay(year)) return error.ParseError;
    try skipRequiredSpace(&left);

    // time = hour ":" minute [ ":" second ] zone
    const hour: Hour = hour: {
        const parsed = try digits(&left, 1, 2);
        if (parsed.value > 23) return error.ParseError;
        break :hour @intCast(parsed.value);
    };
    try literal(&left, ':');

    const minute: Minute = minute: {
        const parsed = try digits(&left, 2, 2);
        if (parsed.value > 59) return error.ParseError;
        break :minute @intCast(parsed.value);
    };

    const second: Second = second: {
        if (left.len == 0 or left[0] != ':') break :second 0;
        left = left[1..];
        // 60 is allowed so that a leap second parses.
        const parsed = try digits(&left, 2, 2);
        if (parsed.value > 60) return error.ParseError;
        break :second @intCast(parsed.value);
    };
    try skipRequiredSpace(&left);

    const offset = try zone(&left);

    var datetime: DateTime = .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = 0,
        .weekday = .Thu,
        .offset = offset,
    };
    datetime.updateDayOfWeek();

    if (day_of_week) |expected| {
        if (datetime.weekday != expected) return error.ParseError;
    }

    return .{
        .str = value[0 .. value.len - left.len],
        .value = datetime,
    };
}

/// Consumes any run of spaces and tabs at the start of `left`.
fn skipSpace(left: *[]const u8) void {
    var index: usize = 0;
    while (index < left.len and (left.*[index] == ' ' or left.*[index] == '\t')) index += 1;
    left.* = left.*[index..];
}

/// Consumes a run of spaces and tabs at the start of `left`, requiring at
/// least one of them.
fn skipRequiredSpace(left: *[]const u8) ParseError!void {
    const before = left.len;
    skipSpace(left);
    if (left.len == before) return error.ParseError;
}

/// Consumes `char` from the start of `left`.
fn literal(left: *[]const u8, char: u8) ParseError!void {
    if (left.len == 0 or left.*[0] != char) return error.ParseError;
    left.* = left.*[1..];
}

const Digits = struct {
    value: u16,
    len: usize,
};

/// Consumes between `min_len` and `max_len` ASCII digits from the start of
/// `left` and returns their value along with how many were read. `max_len`
/// must be at most 4 so that the value always fits in a `u16`.
fn digits(left: *[]const u8, min_len: usize, max_len: usize) ParseError!Digits {
    std.debug.assert(max_len <= 4);
    const str = read.int(left.*, max_len);
    if (str.len < min_len) return error.ParseError;
    const value = std.fmt.parseInt(u16, str, 10) catch return error.ParseError;
    left.* = left.*[str.len..];
    return .{ .value = value, .len = str.len };
}

/// The named zones of RFC 822 section 5.1, as seconds east of UTC, plus
/// `UTC`, which the RFC spells `UT` but which is common enough in real
/// messages to be worth accepting.
const zone_map = std.StaticStringMapWithEql(i32, std.ascii.eqlIgnoreCase).initComptime(.{
    .{ "UT", 0 },
    .{ "UTC", 0 },
    .{ "GMT", 0 },
    .{ "EST", -5 * std.time.s_per_hour },
    .{ "EDT", -4 * std.time.s_per_hour },
    .{ "CST", -6 * std.time.s_per_hour },
    .{ "CDT", -5 * std.time.s_per_hour },
    .{ "MST", -7 * std.time.s_per_hour },
    .{ "MDT", -6 * std.time.s_per_hour },
    .{ "PST", -8 * std.time.s_per_hour },
    .{ "PDT", -7 * std.time.s_per_hour },
});

/// Parses a zone at the start of `left` and returns it as seconds east of
/// UTC. Both the numeric `("+" / "-") 4DIGIT` form and the named forms are
/// accepted. A name is taken to be the whole run of letters that follows,
/// so `MST` is read as Mountain Standard Time rather than as the military
/// zone `M` with a stray `ST` after it.
fn zone(left: *[]const u8) ParseError!i32 {
    if (left.len == 0) return error.ParseError;

    if (left.*[0] == '+' or left.*[0] == '-') {
        const sign: i32 = if (left.*[0] == '-') -1 else 1;
        var rest = left.*[1..];
        const parsed = try digits(&rest, 4, 4);
        if (rest.len > 0 and std.ascii.isDigit(rest[0])) return error.ParseError;
        const hours = parsed.value / 100;
        const minutes = parsed.value % 100;
        if (hours > 23 or minutes > 59) return error.ParseError;
        left.* = rest;
        return sign * @as(i32, @intCast(hours)) * std.time.s_per_hour +
            sign * @as(i32, @intCast(minutes)) * std.time.s_per_min;
    }

    var len: usize = 0;
    while (len < left.len and std.ascii.isAlphabetic(left.*[len])) len += 1;

    const offset = switch (len) {
        1 => militaryZone(left.*[0]) orelse return error.ParseError,
        2, 3 => zone_map.get(left.*[0..len]) orelse return error.ParseError,
        else => return error.ParseError,
    };
    left.* = left.*[len..];
    return offset;
}

/// Returns the offset in seconds east of UTC of a single letter military
/// zone, or null if `letter` is not one.
///
/// RFC 822 section 5.1 assigns these letters the opposite sign to the
/// military standard they were taken from, which is why RFC 5322 section
/// 4.3 deprecates them and recommends treating anything but `Z` as an
/// unknown offset. The RFC 822 table is what is implemented here.
fn militaryZone(letter: u8) ?i32 {
    const char = std.ascii.toUpper(letter);
    const hours: i32 = switch (char) {
        'A'...'I' => -(@as(i32, char - 'A') + 1),
        // "J" is deliberately left unassigned.
        'K'...'M' => -(@as(i32, char - 'K') + 10),
        'N'...'Y' => @as(i32, char - 'N') + 1,
        'Z' => 0,
        else => return null,
    };
    return hours * std.time.s_per_hour;
}

test "parse" {
    const cases = [_]struct { value: []const u8, expected: DateTime }{
        // RFC 822 section 5 and RFC 2822 appendix A.1.1.
        .{
            .value = "Fri, 21 Nov 1997 09:55:06 -0600",
            .expected = .{
                .year = 1997,
                .month = .Nov,
                .day = 21,
                .hour = 9,
                .minute = 55,
                .second = 6,
                .weekday = .Fri,
                .offset = -6 * std.time.s_per_hour,
            },
        },
        // The HTTP flavour: four digit year, GMT.
        .{
            .value = "Sun, 06 Nov 1994 08:49:37 GMT",
            .expected = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 8,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // The original RFC 822 flavour: no day of the week, one digit day
        // of the month, two digit year, no seconds, named zone.
        .{
            .value = "2 Jun 82 12:34 EST",
            .expected = .{
                .year = 1982,
                .month = .Jun,
                .day = 2,
                .hour = 12,
                .minute = 34,
                .second = 0,
                .weekday = .Wed,
                .offset = -5 * std.time.s_per_hour,
            },
        },
        // Two digit years below 50 are in the twenty-first century.
        .{
            .value = "01 Jan 00 00:00:00 UT",
            .expected = .{
                .year = 2000,
                .month = .Jan,
                .day = 1,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // Three digit years are offsets from 1900.
        .{
            .value = "1 Jan 100 00:00:00 Z",
            .expected = .{
                .year = 2000,
                .month = .Jan,
                .day = 1,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // A zone offset that is not a whole number of hours.
        .{
            .value = "Thu, 13 Feb 1969 23:32:54 -0330",
            .expected = .{
                .year = 1969,
                .month = .Feb,
                .day = 13,
                .hour = 23,
                .minute = 32,
                .second = 54,
                .weekday = .Thu,
                .offset = -(3 * std.time.s_per_hour + 30 * std.time.s_per_min),
            },
        },
        // A positive offset.
        .{
            .value = "Mon, 1 Jan 2024 09:30:00 +0545",
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .hour = 9,
                .minute = 30,
                .second = 0,
                .weekday = .Mon,
                .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
            },
        },
        // Leap seconds, and a leap day.
        .{
            .value = "Sat, 29 Feb 2020 23:59:60 +0000",
            .expected = .{
                .year = 2020,
                .month = .Feb,
                .day = 29,
                .hour = 23,
                .minute = 59,
                .second = 60,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // Names are matched case-insensitively and the whitespace between
        // components may be tabs or runs of spaces.
        .{
            .value = "  sun,\t06  nov  1994  08:49:37  gmt",
            .expected = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 8,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // The comma after the day of the week is optional here.
        .{
            .value = "Sun 06 Nov 1994 08:49:37 GMT",
            .expected = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 8,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // Named zones must not be confused with military ones.
        .{
            .value = "1 Jan 2024 00:00:00 MST",
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .weekday = .Mon,
                .offset = -7 * std.time.s_per_hour,
            },
        },
        .{
            .value = "1 Jan 2024 00:00:00 M",
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .weekday = .Mon,
                .offset = -12 * std.time.s_per_hour,
            },
        },
        .{
            .value = "1 Jan 2024 00:00:00 N",
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .weekday = .Mon,
                .offset = std.time.s_per_hour,
            },
        },
    };

    for (cases) |case| {
        const result = try parse(case.value);
        try std.testing.expectEqual(case.expected, result.value);
        try std.testing.expectEqualStrings(case.value, result.str);
    }
}

test "parse stops at the end of the date" {
    // Text after a complete date is the caller's business, not an error.
    {
        const result = try parse("06 Nov 1994 08:49:37 GMT extra");
        try std.testing.expectEqualStrings("06 Nov 1994 08:49:37 GMT", result.str);
    }
    // An RFC 5322 date with an obsolete trailing comment: the date itself
    // is parsed and the comment is left for the caller.
    {
        const result = try parse("Thu, 13 Feb 1969 23:32:54 -0330 (Newfoundland Time)");
        try std.testing.expectEqualStrings("Thu, 13 Feb 1969 23:32:54 -0330", result.str);
        try std.testing.expectEqual(@as(i32, -(3 * std.time.s_per_hour + 30 * std.time.s_per_min)), result.value.offset);
    }
}

test "parse rejects malformed input" {
    const cases = [_][]const u8{
        "",
        "Sun, 06 Nov 1994 08:49:37", // no zone
        "Mon, 06 Nov 1994 08:49:37 GMT", // 6 Nov 1994 was a Sunday
        "06 Nov 1994", // no time
        "32 Jan 2024 00:00:00 GMT", // no such day of the month
        "0 Jan 2024 00:00:00 GMT",
        "30 Feb 2024 00:00:00 GMT", // day out of range for the month
        "29 Feb 2023 00:00:00 GMT", // 2023 is not a leap year
        "06 Nov 1994 24:49:37 GMT", // hour out of range
        "06 Nov 1994 08:60:37 GMT", // minute out of range
        "06 Nov 1994 08:49:61 GMT", // second out of range
        "06 Nov 1994 08:4:37 GMT", // minute must be two digits
        "06 November 1994 08:49:37 GMT", // long month names are not RFC 822
        "06 Nov 1994 08:49:37 J", // "J" is not a military zone
        "06 Nov 1994 08:49:37 QQ", // not a named zone
        "06 Nov 1994 08:49:37 +060", // offset must be four digits
        "06 Nov 1994 08:49:37 +06000",
        "06 Nov 1994 08:49:37 +0560", // minutes of the offset out of range
        "06 Nov 1994 08:49:37 +2400", // hours of the offset out of range
        "06Nov 1994 08:49:37 GMT", // components must be separated
        "6 Nov 94x 08:49:37 GMT",
    };

    for (cases) |case| {
        try std.testing.expectError(error.ParseError, parse(case));
    }
}

test "military zones follow the RFC 822 table" {
    const hour = std.time.s_per_hour;
    try std.testing.expectEqual(@as(?i32, -hour), militaryZone('A'));
    try std.testing.expectEqual(@as(?i32, -9 * hour), militaryZone('I'));
    try std.testing.expectEqual(@as(?i32, null), militaryZone('J'));
    try std.testing.expectEqual(@as(?i32, -10 * hour), militaryZone('K'));
    try std.testing.expectEqual(@as(?i32, -12 * hour), militaryZone('M'));
    try std.testing.expectEqual(@as(?i32, hour), militaryZone('N'));
    try std.testing.expectEqual(@as(?i32, 12 * hour), militaryZone('Y'));
    try std.testing.expectEqual(@as(?i32, 0), militaryZone('Z'));
    try std.testing.expectEqual(@as(?i32, 0), militaryZone('z'));
    try std.testing.expectEqual(@as(?i32, null), militaryZone('0'));
}

test "round trip through DateTime.format" {
    const value = "Fri, 21 Nov 1997 09:55:06 -0600";

    const parsed = try parse(value);
    const formatted = try parsed.value.formatAlloc(std.testing.allocator, "ddd, DD MMM YYYY HH:mm:ss ZZ");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(value, formatted);
}

test "parsed offsets convert to UTC" {
    const parsed = try parse("Fri, 21 Nov 1997 09:55:06 -0600");

    try std.testing.expectEqual(DateTime{
        .year = 1997,
        .month = .Nov,
        .day = 21,
        .hour = 15,
        .minute = 55,
        .second = 6,
        .weekday = .Fri,
        .offset = 0,
    }, parsed.value.toUtc());
}
