// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formatting and parsing the way PowerShell's `Get-Date` does, which has
//! two vocabularies and a parameter for each.
//!
//! `-Format` takes a .NET format string, which is `dotnet`'s job, plus
//! four names of PowerShell's own for dates that go in file names:
//!
//! ```zig
//! try powershell.format(value, "FileDateTimeUniversal", writer);   // 20240315T1930051234Z
//! try powershell.format(value, "dddd MM/dd/yyyy HH:mm K", writer); // Friday 03/15/2024 14:30 -05:00
//! ```
//!
//! `-UFormat` takes a string of `%` conversions that looks like the C
//! library's `strftime` and is not quite it:
//!
//! ```zig
//! try powershell.uformat(value, "%A %m/%d/%Y %R %Z", writer);   // Friday 03/15/2024 14:30 -05
//! ```
//!
//! PowerShell implements `-UFormat` by translating each conversion into a
//! .NET composite format item and handing the result to `String.Format`,
//! and the translation is its own. `%Z` is the offset in hours, `-05`,
//! rather than a zone's name. `%U` and `%W` are both the day of the year
//! divided by seven, which counts neither Sundays nor Mondays and puts
//! January 1st in week 0. `%c` is `Fri 15 Mar 2024 14:30:05`, day before
//! month. `%s` is rounded to the nearest second rather than truncated.
//! These are what PowerShell does, so they are what this does; `strftime`
//! is the module for the C library's meanings.
//!
//! PowerShell 7.6's `GetDateCommand.cs` is the specification, and `zig
//! build oracle-powershell` checks it: `Get-Date` itself formats the same
//! corpus and the results are diffed. Two things are deliberately not
//! followed, and the oracle carries the same list:
//!
//! - **A conversion PowerShell does not know is a compile error.**
//!   PowerShell writes the letter, so `%z` comes out as `z` and `%Q` as
//!   `Q`. A strftime habit carried across is a bug that should be found
//!   while the program is compiled, which is the choice `strftime` makes
//!   for the same reason. `%%` is still a percent sign.
//! - **`u` and `R` under `-Format` convert to UTC.** `Get-Date` hands
//!   .NET a local `DateTime`, and .NET writes `u` and `R` of one without
//!   converting it, so that the `Z` and `GMT` they end in are false for
//!   anybody not in UTC. `dotnet` follows `DateTimeOffset`, which
//!   converts, and so does this.
//!
//! PowerShell has no way to read either vocabulary back in. `parse`
//! reads `-Format` strings the way .NET's `ParseExact` does, and
//! `parseUFormat` reads `-UFormat` strings under rules of its own, set
//! out on it.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Instant = @import("Instant.zig");
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;
const dotnet = @import("dotnet.zig");
const locale = @import("locale.zig");

/// The .NET culture `Get-Date` formats in. PowerShell uses whatever the
/// session's culture is; these are the two worth naming.
pub const Culture = dotnet.Culture;

/// The four names `-Format` accepts beyond .NET's format strings, with
/// the .NET format each stands for. PowerShell matches them without
/// regard to case, and so does this.
pub const file_date = struct {
    /// `20240315`, in the value's own time.
    pub const date = "yyyyMMdd";
    /// `20240315Z`, in UTC.
    pub const date_universal = "yyyyMMddZ";
    /// `20240315T1430051234`, to ten thousandths of a second, in the
    /// value's own time.
    pub const date_time = "yyyyMMddTHHmmssffff";
    /// `20240315T1930051234Z`, the same in UTC.
    pub const date_time_universal = "yyyyMMddTHHmmssffffZ";
};

/// What a `-Format` string amounts to once PowerShell's four names are
/// taken out of it: the .NET format string, and whether the value is
/// moved into UTC first.
const Resolved = struct {
    format_string: []const u8,
    universal: bool = false,
};

/// Resolves PowerShell's names, which it compares with
/// `StringComparison.OrdinalIgnoreCase`, and passes anything else through
/// as a .NET format string.
fn resolve(comptime format_string: []const u8) Resolved {
    comptime {
        if (std.ascii.eqlIgnoreCase(format_string, "FileDate")) return .{ .format_string = file_date.date };
        if (std.ascii.eqlIgnoreCase(format_string, "FileDateUniversal")) return .{ .format_string = file_date.date_universal, .universal = true };
        if (std.ascii.eqlIgnoreCase(format_string, "FileDateTime")) return .{ .format_string = file_date.date_time };
        if (std.ascii.eqlIgnoreCase(format_string, "FileDateTimeUniversal")) return .{ .format_string = file_date.date_time_universal, .universal = true };
        return .{ .format_string = format_string };
    }
}

test resolve {
    try std.testing.expectEqualStrings("yyyyMMdd", (comptime resolve("filedate")).format_string);
    try std.testing.expect((comptime resolve("FileDateTimeUniversal")).universal);
    try std.testing.expectEqualStrings("yyyy", (comptime resolve("yyyy")).format_string);
}

/// Writes `value` the way `Get-Date -Format` does, in the invariant
/// culture.
///
/// Flushes `writer` before returning.
///
/// ```zig
/// try powershell.format(value, "FileDate", writer);   // 20240315
/// ```
pub fn format(
    value: DateTime,
    comptime format_string: []const u8,
    writer: *std.Io.Writer,
) dotnet.FormatError!void {
    return formatIn(value, format_string, Culture.invariant, writer);
}

test format {
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 5,
        .nanosecond = 123456789,
        .offset = -5 * std.time.s_per_hour,
    };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("20240315", try bufFormat(&buffer, value, "FileDate"));
    try std.testing.expectEqualStrings("20240315T1930051234Z", try bufFormat(&buffer, value, "FileDateTimeUniversal"));
    try std.testing.expectEqualStrings("Friday 03/15/2024 14:30 -05:00", try bufFormat(&buffer, value, "dddd MM/dd/yyyy HH:mm K"));
}

/// Writes `value` the way `Get-Date -Format` does in `culture`.
///
/// `FileDate`, `FileDateUniversal`, `FileDateTime` and
/// `FileDateTimeUniversal`, in any case, are PowerShell's; the two
/// universal ones move the value into UTC before writing it, and write a
/// `Z` after it. Anything else is a .NET format string and goes to
/// `dotnet.formatIn`.
pub fn formatIn(
    value: DateTime,
    comptime format_string: []const u8,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) dotnet.FormatError!void {
    const resolved = comptime resolve(format_string);
    const reading = if (resolved.universal) value.toUtc() else value;
    try dotnet.formatIn(reading, resolved.format_string, culture, writer);
}

test formatIn {
    var value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .hour = 9 };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try formatIn(value, "d", Culture.en_us, &writer);
    try std.testing.expectEqualStrings("3/5/2024", writer.buffered());
}

/// Reads `text` under a `-Format` string in the invariant culture, the
/// way .NET's `ParseExact` would read it; see `dotnet.parseIn`.
///
/// PowerShell's four names are read as the .NET formats they stand for,
/// and the two universal ones say UTC through the `Z` they end in.
pub fn parse(comptime format_string: []const u8, text: []const u8) dotnet.ParseError!dotnet.Result {
    return parseIn(format_string, text, Culture.invariant, .{});
}

test parse {
    const result = try parse("FileDateUniversal", "20240315Z");
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expect(result.has_offset);

    // The local form says nothing about where it was written.
    try std.testing.expect(!(try parse("FileDate", "20240315")).has_offset);
}

/// Reads `text` under a `-Format` string in `culture`.
pub fn parseIn(
    comptime format_string: []const u8,
    text: []const u8,
    comptime culture: Culture,
    options: dotnet.Options,
) dotnet.ParseError!dotnet.Result {
    return dotnet.parseIn((comptime resolve(format_string)).format_string, text, culture, options);
}

test parseIn {
    const result = try parseIn("FileDateTime", "20240315T1430051234", Culture.invariant, .{});
    try std.testing.expectEqual(@as(u5, 14), result.value.hour);
    try std.testing.expectEqual(@as(u30, 123_400_000), result.value.nanosecond);
}

/// Formats into `buffer` with `format` and returns what was written, for
/// the tests.
fn bufFormat(buffer: []u8, value: DateTime, comptime format_string: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try format(value, format_string, &writer);
    return writer.buffered();
}

/// One `-UFormat` conversion that stands for a value, named for what it
/// is rather than its letter, with the letter and what PowerShell
/// translates it to beside it.
///
/// The composite ones -- `%c`, `%D`, `%F`, `%R`, `%r`, `%T`, `%X` and
/// `%x` -- are not here, because each is these written in a row; see
/// `expansion`.
pub const Conversion = enum {
    weekday_long, // %A, {0:dddd}
    weekday_short, // %a, {0:ddd}
    month_long, // %B, {0:MMMM}
    month_short, // %b and %h, {0:MMM}
    century, // %C, Year / 100
    day, // %d, {0:dd}
    day_spaced, // %e, {0,2} of the day
    iso_year, // %G, {0:0000} of ISOWeek.GetYear
    iso_year_short, // %g, {0:00} of ISOWeek.GetYear % 100
    hour24, // %H, {0:HH}
    hour12, // %I, {0:hh}
    day_of_year, // %j, {0:000} of DayOfYear
    hour24_spaced, // %k, {0,2:0} of the hour
    hour12_spaced, // %l, {0,2:%h}
    minute, // %M, {0:mm}
    month, // %m, {0:MM}
    meridiem, // %p, {0:tt}
    second, // %S, {0:ss}
    epoch_seconds, // %s, {0:0} of TotalSeconds since the epoch
    week, // %U and %W, DayOfYear / 7
    iso_weekday, // %u, Monday 1 to Sunday 7
    iso_week, // %V, {0:00} of ISOWeek.GetWeekOfYear
    weekday_number, // %w, Sunday 0 to Saturday 6
    year, // %Y, {0:yyyy}
    year_short, // %y, {0:yy}
    offset_hours, // %Z, {0:zz}
};

/// A `-UFormat` string is a run of these.
pub const UChunk = union(enum) {
    literal: []const u8,
    conversion: Conversion,
    /// The culture's date separator, which is what a `/` inside one of
    /// PowerShell's format items writes.
    date_separator,
    /// The culture's time separator, likewise for `:`.
    time_separator,
};

/// What a composite conversion is written as, in the conversions and
/// separators it is made of, or null when `letter` is not a composite.
///
/// Where PowerShell writes the pieces as separate format items, the text
/// between them is literal: `%c` is `{0:ddd} {0:dd} {0:MMM} {0:yyyy}
/// {0:HH}:{0:mm}:{0:ss}`, so its colons are colons in every culture.
/// Where it writes one item, the separators in it are the culture's: `%D`
/// is `{0:MM/dd/yy}`, so its slashes are whatever the culture puts
/// between the parts of a date.
fn expansion(comptime letter: u8) ?[]const UChunk {
    return switch (letter) {
        'c' => &.{
            .{ .conversion = .weekday_short }, .{ .literal = " " },
            .{ .conversion = .day },           .{ .literal = " " },
            .{ .conversion = .month_short },   .{ .literal = " " },
            .{ .conversion = .year },          .{ .literal = " " },
            .{ .conversion = .hour24 },        .{ .literal = ":" },
            .{ .conversion = .minute },        .{ .literal = ":" },
            .{ .conversion = .second },
        },
        'D', 'x' => &.{
            .{ .conversion = .month },      .date_separator,
            .{ .conversion = .day },        .date_separator,
            .{ .conversion = .year_short },
        },
        'F' => &.{
            .{ .conversion = .year },  .{ .literal = "-" },
            .{ .conversion = .month }, .{ .literal = "-" },
            .{ .conversion = .day },
        },
        'R' => &.{ .{ .conversion = .hour24 }, .time_separator, .{ .conversion = .minute } },
        'r' => &.{
            .{ .conversion = .hour12 },   .time_separator,
            .{ .conversion = .minute },   .time_separator,
            .{ .conversion = .second },   .{ .literal = " " },
            .{ .conversion = .meridiem },
        },
        'T', 'X' => &.{
            .{ .conversion = .hour24 }, .time_separator,
            .{ .conversion = .minute }, .time_separator,
            .{ .conversion = .second },
        },
        else => null,
    };
}

test expansion {
    try std.testing.expectEqual(@as(usize, 5), expansion('T').?.len);
    try std.testing.expectEqual(@as(?[]const UChunk, null), expansion('Y'));
}

/// Splits a `-UFormat` string into chunks, which is PowerShell's
/// `UFormatDateString` done at compile time.
///
/// A leading `+` is dropped, because PowerShell drops it so that a
/// `date +%Y` habit works. After that, `%` and a letter is a conversion,
/// `%%` is a percent sign, `%n` and `%t` are a newline and a tab, and
/// everything else is copied through.
///
/// PowerShell hands the whole translation to `String.Format`, so a brace
/// in the literal text is read as the start of a format item: `{{` and
/// `}}` come out as one brace each and anything else is a
/// `FormatException`. This does the same, with the exception a compile
/// error. An empty string, and a `%` with nothing after it, are compile
/// errors too, where PowerShell throws an `IndexOutOfRangeException`; and
/// so is a conversion PowerShell does not know, which it would write out
/// as its letter.
pub fn tokenizeUFormat(comptime format_string: []const u8) []const UChunk {
    comptime {
        @setEvalBranchQuota(100000);

        if (format_string.len == 0) @compileError("powershell: an empty -UFormat string is an error in PowerShell too");

        var chunks: []const UChunk = &.{};
        var text: []const u8 = "";
        var i: usize = if (format_string[0] == '+') 1 else 0;

        while (i < format_string.len) {
            const char = format_string[i];

            if (char == '{' or char == '}') {
                if (i + 1 < format_string.len and format_string[i + 1] == char) {
                    text = text ++ &[_]u8{char};
                    i += 2;
                    continue;
                }
                @compileError(
                    "powershell: '" ++ format_string ++ "' has a lone brace, which PowerShell hands to String.Format as the start of a format item; write it twice",
                );
            }

            if (char != '%') {
                text = text ++ &[_]u8{char};
                i += 1;
                continue;
            }

            if (i + 1 >= format_string.len) @compileError(
                "powershell: '" ++ format_string ++ "' ends in the middle of a conversion",
            );
            const letter = format_string[i + 1];
            i += 2;

            switch (letter) {
                '%' => text = text ++ "%",
                'n' => text = text ++ "\n",
                't' => text = text ++ "\t",
                else => {
                    if (text.len > 0) {
                        chunks = chunks ++ &[_]UChunk{.{ .literal = text }};
                        text = "";
                    }
                    if (expansion(letter)) |pieces| {
                        chunks = chunks ++ pieces;
                    } else {
                        chunks = chunks ++ &[_]UChunk{.{ .conversion = conversionOf(letter) orelse @compileError(
                            "powershell: '%" ++ [_]u8{letter} ++ "' in '" ++ format_string ++
                                "' is not a -UFormat conversion; PowerShell would write the letter",
                        ) }};
                    }
                },
            }
        }

        if (text.len > 0) chunks = chunks ++ &[_]UChunk{.{ .literal = text }};
        return chunks;
    }
}

test tokenizeUFormat {
    const date = comptime tokenizeUFormat("%Y-%m-%d");
    try std.testing.expectEqual(@as(usize, 5), date.len);
    try std.testing.expectEqual(Conversion.year, date[0].conversion);

    // A leading `+` is dropped, and a doubled brace is one brace.
    const plus = comptime tokenizeUFormat("+{{%Y}}");
    try std.testing.expectEqualStrings("{", plus[0].literal);
    try std.testing.expectEqual(Conversion.year, plus[1].conversion);

    // A composite is its pieces.
    try std.testing.expectEqual(@as(usize, 3), (comptime tokenizeUFormat("%R")).len);
}

/// The conversion a letter stands for when it is not a composite, or null
/// when PowerShell does not know it.
fn conversionOf(comptime letter: u8) ?Conversion {
    return switch (letter) {
        'A' => .weekday_long,
        'a' => .weekday_short,
        'B' => .month_long,
        'b', 'h' => .month_short,
        'C' => .century,
        'd' => .day,
        'e' => .day_spaced,
        'G' => .iso_year,
        'g' => .iso_year_short,
        'H' => .hour24,
        'I' => .hour12,
        'j' => .day_of_year,
        'k' => .hour24_spaced,
        'l' => .hour12_spaced,
        'M' => .minute,
        'm' => .month,
        'p' => .meridiem,
        'S' => .second,
        's' => .epoch_seconds,
        'U', 'W' => .week,
        'u' => .iso_weekday,
        'V' => .iso_week,
        'w' => .weekday_number,
        'Y' => .year,
        'y' => .year_short,
        'Z' => .offset_hours,
        else => null,
    };
}

test conversionOf {
    try std.testing.expectEqual(@as(?Conversion, .week), conversionOf('U'));
    try std.testing.expectEqual(@as(?Conversion, null), conversionOf('z'));
}

/// Writes `value` the way `Get-Date -UFormat` does, in the invariant
/// culture.
///
/// Flushes `writer` before returning.
///
/// ```zig
/// try powershell.uformat(value, "%Y-%m-%d %T %Z", writer);   // 2024-03-15 14:30:05 -05
/// ```
pub fn uformat(
    value: DateTime,
    comptime format_string: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    return uformatIn(value, format_string, Culture.invariant, writer);
}

test uformat {
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .hour = 9,
        .minute = 7,
        .second = 3,
        .offset = -5 * std.time.s_per_hour,
    };
    value.updateDayOfWeek();

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Tue 05 Mar 2024 09:07:03", try bufUFormat(&buffer, value, "%c"));
    try std.testing.expectEqualStrings("-05", try bufUFormat(&buffer, value, "%Z"));
    try std.testing.expectEqualStrings(" 5 |  9 |  9", try bufUFormat(&buffer, value, "%e | %k | %l"));
    // Day 65 of the year, divided by seven, whichever letter asked.
    try std.testing.expectEqualStrings("9 9", try bufUFormat(&buffer, value, "%U %W"));
}

/// Writes `value` the way `Get-Date -UFormat` does in `culture`.
///
/// Every conversion is written the way PowerShell's translation writes
/// it, which is set out on `Conversion`. Beyond PowerShell's years, which
/// stop at 9999, the numbers are C#'s arithmetic in a wider integer: `%C`
/// of year -5 is `0`, since C# division truncates, and `%Y` of it is
/// `-0005`.
///
/// `%s` is PowerShell's in every detail, because it is not the obvious
/// thing. PowerShell takes `TotalSeconds`, a `double`, and writes it with
/// the .NET format `0`, which rounds it to fifteen significant digits and
/// then to a whole number, halves away from zero. So a second and a half
/// past the epoch is `2`, 1.4999 seconds before it is `-1`, and anything
/// within half a second before it is `-0`.
pub fn uformatIn(
    value: DateTime,
    comptime format_string: []const u8,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writeUChunks(value, comptime tokenizeUFormat(format_string), culture, writer);
    try writer.flush();
}

test uformatIn {
    var value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .hour = 21 };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try uformatIn(value, "%r", Culture.en_us, &writer);
    try std.testing.expectEqualStrings("09:00:00 PM", writer.buffered());
}

/// Writes a run of chunks without flushing.
fn writeUChunks(
    value: DateTime,
    comptime chunks: []const UChunk,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .date_separator => try writer.writeAll(culture.date_separator),
        .time_separator => try writer.writeAll(culture.time_separator),
        .conversion => |which| try writeConversion(value, which, culture, writer),
    };
}

/// Writes one conversion.
fn writeConversion(
    value: DateTime,
    comptime which: Conversion,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    switch (which) {
        .weekday_long => try writer.writeAll(culture.names.weekdayName(value.weekday, .dddd)),
        .weekday_short => try writer.writeAll(culture.names.weekdayName(value.weekday, .ddd)),
        // Each is a format item of its own, with no day beside it, so the
        // month is never in the form a language uses after a day number.
        .month_long => try writer.writeAll(culture.names.monthName(value.month, .MMMM, false)),
        .month_short => try writer.writeAll(culture.names.monthName(value.month, .MMM, false)),

        .century => try writer.print("{d}", .{@divTrunc(value.year, 100)}),
        .day => try writeNumber(writer, value.day, 2),
        .day_spaced => try writer.print("{d: >2}", .{value.day}),
        .iso_year => try writeNumber(writer, value.isoWeek().year, 4),
        .iso_year_short => try writeNumber(writer, @rem(value.isoWeek().year, 100), 2),
        .hour24 => try writeNumber(writer, value.hour, 2),
        .hour12 => try writeNumber(writer, twelve(value.hour), 2),
        .day_of_year => try writeNumber(writer, value.dayOfThisYear(), 3),
        .hour24_spaced => try writer.print("{d: >2}", .{value.hour}),
        .hour12_spaced => try writer.print("{d: >2}", .{twelve(value.hour)}),
        .minute => try writeNumber(writer, value.minute, 2),
        .month => try writeNumber(writer, value.month.monthNumber(), 2),
        .meridiem => try writer.writeAll(if (value.hour < 12) culture.am_designator else culture.pm_designator),
        .second => try writeNumber(writer, value.second, 2),
        .epoch_seconds => try writeEpochSeconds(writer, value),
        .week => try writer.print("{d}", .{value.dayOfThisYear() / 7}),
        .iso_weekday => try writer.print("{d}", .{value.weekday.isoWeekdayNumber()}),
        .iso_week => try writeNumber(writer, value.isoWeek().week, 2),
        .weekday_number => try writer.print("{d}", .{value.weekday.weekdayNumber()}),
        .year => try writeNumber(writer, value.year, 4),
        .year_short => try writeNumber(writer, @rem(value.year, 100), 2),
        .offset_hours => {
            try writer.writeByte(if (value.offset < 0) '-' else '+');
            try writer.print("{d:0>2}", .{@abs(value.offset) / std.time.s_per_hour});
        },
    }
}

/// Writes `number` with at least `digits` digits, and a minus sign ahead
/// of the padding when it is negative, the way .NET writes a negative
/// number under `"0000"`.
fn writeNumber(writer: *std.Io.Writer, number: anytype, digits: usize) std.Io.Writer.Error!void {
    const wide: i64 = number;
    if (wide < 0) try writer.writeByte('-');
    try writer.printInt(@abs(wide), 10, .lower, .{ .width = digits, .fill = '0' });
}

test writeNumber {
    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeNumber(&writer, @as(i32, -5), 4);
    try std.testing.expectEqualStrings("-0005", writer.buffered());
}

/// The hour on a twelve hour clock, where midnight and noon are both 12.
fn twelve(hour: u5) u5 {
    const wrapped = hour % 12;
    return if (wrapped == 0) 12 else wrapped;
}

test twelve {
    try std.testing.expectEqual(@as(u5, 12), twelve(12));
    try std.testing.expectEqual(@as(u5, 9), twelve(21));
}

/// Writes `%s`, which is PowerShell's
/// `StringUtil.Format("{0:0}", TotalSeconds)`.
///
/// Three steps, each .NET's. The instant is counted in ticks of a hundred
/// nanoseconds, since that is what a .NET `DateTime` holds, and divided
/// by ten million as a `double`. The custom numeric format `0` then turns
/// that `double` into its first fifteen significant digits, rounding the
/// sixteenth, and rounds what is left to a whole number with a five or
/// more rounding away from zero. A negative number that rounds to nothing
/// keeps its sign, which .NET has written as `-0` since .NET Core 3.0.
///
/// The two roundings are not one. 1.4999996 seconds is fifteen digits of
/// 1.49999960000000, which rounds to 1; but a time this century has ten
/// digits before the point and only five after it, so 1710513005.4999996
/// becomes 1710513005.50000 and then 1710513006.
fn writeEpochSeconds(writer: *std.Io.Writer, value: DateTime) std.Io.Writer.Error!void {
    const ticks = @divFloor(value.toInstant().timestamp, 100);
    const seconds = @as(f64, @floatFromInt(ticks)) / 1e7;

    if (seconds == 0) return writer.writeAll("0");
    if (seconds < 0) try writer.writeByte('-');

    // The fifteen significant digits, and where the decimal point goes
    // among them.
    var scratch: [64]u8 = undefined;
    const scientific = std.fmt.bufPrint(&scratch, "{e:.14}", .{@abs(seconds)}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, scientific, 'e').?;
    var digits: [15]u8 = undefined;
    digits[0] = scientific[0];
    @memcpy(digits[1..], scientific[2..e_at]);
    const exponent = std.fmt.parseInt(i32, scientific[e_at + 1 ..], 10) catch unreachable;

    // How many of the digits come before the point.
    const whole: i32 = exponent + 1;

    if (whole <= 0) {
        // Less than one: it rounds to one or to nothing, and only a first
        // digit straight after the point can make it one.
        const rounds_up = whole == 0 and digits[0] >= '5';
        return writer.writeAll(if (rounds_up) "1" else "0");
    }

    var integer: [32]u8 = undefined;
    const length: usize = @intCast(whole);
    for (0..length) |i| integer[i] = if (i < digits.len) digits[i] else '0';

    if (length < digits.len and digits[length] >= '5') {
        // Carry the rounding up through the digits, which can make the
        // number one digit longer: 9.5 is 10.
        var i = length;
        while (i > 0) {
            i -= 1;
            if (integer[i] == '9') {
                integer[i] = '0';
            } else {
                integer[i] += 1;
                break;
            }
        } else {
            try writer.writeByte('1');
        }
    }

    try writer.writeAll(integer[0..length]);
}

test writeEpochSeconds {
    var buffer: [32]u8 = undefined;

    const cases = [_]struct { nanoseconds: i128, text: []const u8 }{
        .{ .nanoseconds = 0, .text = "0" },
        .{ .nanoseconds = 1_710_513_005_123_000_000, .text = "1710513005" },
        // Halves round away from zero.
        .{ .nanoseconds = 1_500_000_000, .text = "2" },
        .{ .nanoseconds = -1_500_000_000, .text = "-2" },
        // Within half a second before the epoch keeps its sign.
        .{ .nanoseconds = -400_000_000, .text = "-0" },
        // Fifteen digits leave five after the point here, so .4999996
        // rounds up twice.
        .{ .nanoseconds = 1_710_513_005_499_999_600, .text = "1710513006" },
        .{ .nanoseconds = 1_499_999_600, .text = "1" },
        .{ .nanoseconds = 9_500_000_000, .text = "10" },
    };

    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        const value = (Instant{ .timestamp = case.nanoseconds }).asDateTime();
        try writeEpochSeconds(&writer, value);
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
}

/// Formats into `buffer` with `uformat` and returns what was written, for
/// the tests.
fn bufUFormat(buffer: []u8, value: DateTime, comptime format_string: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try uformat(value, format_string, &writer);
    return writer.buffered();
}

/// Reads `text` under a `-UFormat` string in the invariant culture. The
/// whole of `text` has to be read.
///
/// ```zig
/// const result = try powershell.parseUFormat("%F %T %Z", "2024-03-15 14:30:05 -05");
/// ```
pub fn parseUFormat(comptime format_string: []const u8, text: []const u8) dotnet.ParseError!dotnet.Result {
    return parseUFormatIn(format_string, text, Culture.invariant, .{});
}

test parseUFormat {
    const result = try parseUFormat("%F %T %Z", "2024-03-15 14:30:05 -05");
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);
    try std.testing.expectEqual(@as(u5, 14), result.value.hour);
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), result.value.offset);
    try std.testing.expect(result.has_offset);

    // A weekday that is not the date's is refused rather than believed.
    try std.testing.expectError(error.ParseError, parseUFormat("%a %F", "Mon 2024-03-15"));
}

/// Reads `text` under a `-UFormat` string in `culture`.
///
/// PowerShell reads nothing back, so these rules are this library's,
/// chosen so that anything `uformatIn` writes for a year from 1 to 9999
/// reads back as what it was, and so that they are as strict as .NET's
/// `ParseExact` is about the same pieces:
///
/// - Literal text, and the separators, must be there exactly, and the
///   whole input must be read.
/// - A zero padded number reads exactly its width, so `%d` is two digits
///   and `%Y` four; a space padded one, `%e`, `%k` and `%l`, reads a space
///   and a digit or two digits; `%C`, `%U`, `%W`, `%u` and `%w` read the
///   one or two digits they can be; `%s` reads an optional sign and up to
///   fifteen digits. Names and the meridiem are matched in any case.
/// - `%Z` is an offset of whole hours, since that is all it says.
///
/// Then the value is settled from the strongest thing the text gave:
/// `%s` if it is there, at the offset `%Z` gives or zero; otherwise a
/// year with a month or a day; otherwise a year and `%j`; otherwise
/// `%G` or `%g` with `%V`, on the weekday `%u`, `%w`, `%a` or `%A` gave or
/// Monday; otherwise `.NET`'s table on `dotnet.Options`. `%y` alone is a
/// year placed by the culture's two digit window, and `%C` with it makes
/// it a full one.
///
/// **Everything else the text said is then checked against that value,
/// and a disagreement is a failure.** A weekday that is not the date's,
/// a `%j` that is another day, a `%U` that is another week, a `%I` and
/// `%p` that are another hour than `%H`: each is text that contradicts
/// itself, and there is no way to know which half of it was right. This is
/// the same rule .NET applies to a weekday and to a field written twice,
/// carried through to every field this vocabulary has.
pub fn parseUFormatIn(
    comptime format_string: []const u8,
    text: []const u8,
    comptime culture: Culture,
    options: dotnet.Options,
) dotnet.ParseError!dotnet.Result {
    var state: UState = .{};
    var rest = text;
    try readUChunks(comptime tokenizeUFormat(format_string), &rest, &state, culture);
    if (rest.len != 0) return error.ParseError;
    return state.finish(culture, options);
}

test parseUFormatIn {
    // `%G-W%V-%u` names a date by itself.
    const week = try parseUFormatIn("%G-W%V-%u", "2020-W53-5", Culture.invariant, .{});
    try std.testing.expectEqual(@as(Year, 2021), week.value.year);
    try std.testing.expectEqual(Month.Jan, week.value.month);
    try std.testing.expectEqual(@as(u6, 1), week.value.day);

    // `%s` is an instant, and `%Z` says where to read it.
    const stamp = try parseUFormatIn("%s %Z", "0 -05", Culture.invariant, .{});
    try std.testing.expectEqual(@as(i128, 0), stamp.value.toInstant().timestamp);
    try std.testing.expectEqual(@as(u5, 19), stamp.value.hour);
}

/// Everything a `-UFormat` string can say, each slot filled at most once
/// or else filled again with the same thing.
const UState = struct {
    year: ?i32 = null,
    century: ?i32 = null,
    short_year: ?i32 = null,
    month: ?u8 = null,
    day: ?u8 = null,
    day_of_year: ?u16 = null,
    iso_year: ?i32 = null,
    iso_short_year: ?i32 = null,
    iso_week: ?u8 = null,
    week: ?u8 = null,
    weekday: ?DayOfWeek = null,
    hour: ?u8 = null,
    hour12: ?u8 = null,
    half: ?locale.Half = null,
    minute: ?u8 = null,
    second: ?u8 = null,
    epoch: ?i64 = null,
    offset: ?i32 = null,

    /// Settles the value and checks everything else against it; see
    /// `parseUFormatIn`.
    fn finish(self: UState, comptime culture: Culture, options: dotnet.Options) dotnet.ParseError!dotnet.Result {
        const offset = self.offset orelse options.relative_to.offset;

        // The year, when the text gave one in full or in halves.
        const year: ?Year = if (self.year) |full|
            full
        else if (self.century) |century|
            (if (self.short_year) |short| century * 100 + short else null)
        else if (self.short_year) |short|
            windowYear(short, culture.two_digit_year_max)
        else
            null;

        var value: DateTime = .{ .offset = offset };

        if (self.epoch) |seconds| {
            const instant: Instant = .{ .timestamp = (@as(i128, seconds) + offset) * std.time.ns_per_s };
            value = instant.asDateTime();
            value.offset = offset;
        } else {
            const date: Date = if (self.month != null or self.day != null) date: {
                const in_year = year orelse options.relative_to.year;
                const month = self.month orelse 1;
                if (month < 1 or month > 12) return error.ParseError;
                const month_value: Month = @enumFromInt(month);
                const day = self.day orelse 1;
                if (day < 1 or day > month_value.lastDay(in_year)) return error.ParseError;
                break :date .{ .year = in_year, .month = month_value, .day = @intCast(day) };
            } else if (year != null and self.day_of_year != null) date: {
                const length: u16 = if (@import("leap.zig").is(year.?)) 366 else 365;
                if (self.day_of_year.? < 1 or self.day_of_year.? > length) return error.ParseError;
                break :date Date.fromDayOfYear(year.?, self.day_of_year.?);
            } else if (self.iso_week != null and (self.iso_year != null or self.iso_short_year != null)) date: {
                const week_year: Year = self.iso_year orelse windowYear(self.iso_short_year.?, culture.two_digit_year_max);
                const number = self.iso_week.?;
                if (number < 1 or number > Date.weeksInYear(week_year, .Mon, 4)) return error.ParseError;
                break :date Date.fromWeek(week_year, number, self.weekday orelse .Mon, .Mon, 4);
            } else if (year) |given|
                .{ .year = given, .month = .Jan, .day = 1 }
            else
                options.relative_to.asDate();

            value.year = date.year;
            value.month = date.month;
            value.day = date.day;

            const hour: u8 = if (self.hour) |given|
                given
            else if (self.hour12) |given|
                (given % 12) + @as(u8, if ((self.half orelse .am) == .pm) 12 else 0)
            else
                0;
            if (hour > 23) return error.ParseError;
            value.hour = @intCast(hour);
            const minute = self.minute orelse 0;
            const second = self.second orelse 0;
            if (minute > 59 or second > 59) return error.ParseError;
            value.minute = @intCast(minute);
            value.second = @intCast(second);
            value.updateDayOfWeek();
        }

        // Everything the text said, against what it all came to.
        const agrees = struct {
            fn check(comptime T: type, said: ?T, is: T) dotnet.ParseError!void {
                if (said) |held| if (held != is) return error.ParseError;
            }
        }.check;

        const iso = value.isoWeek();
        try agrees(i32, year, value.year);
        try agrees(i32, self.century, @divTrunc(value.year, 100));
        try agrees(i32, self.short_year, @rem(value.year, 100));
        try agrees(u8, self.month, value.month.monthNumber());
        try agrees(u8, self.day, value.day);
        try agrees(u16, self.day_of_year, value.dayOfThisYear());
        try agrees(i32, self.iso_year, @intCast(iso.year));
        try agrees(i32, self.iso_short_year, @intCast(@rem(iso.year, 100)));
        try agrees(u8, self.iso_week, iso.week);
        try agrees(u8, self.week, @intCast(value.dayOfThisYear() / 7));
        try agrees(DayOfWeek, self.weekday, value.weekday);
        try agrees(u8, self.hour, value.hour);
        try agrees(u8, self.hour12, twelve(value.hour));
        try agrees(locale.Half, self.half, if (value.hour < 12) .am else .pm);
        try agrees(u8, self.minute, value.minute);
        try agrees(u8, self.second, value.second);

        if (@abs(offset) > 14 * std.time.s_per_hour) return error.ParseError;
        return .{ .value = value, .has_offset = self.offset != null or self.epoch != null };
    }
};

/// Places a two digit year in the hundred years ending with `max`.
fn windowYear(short: i32, max: Year) Year {
    const century = @divFloor(max, 100) * 100;
    const candidate = century + short;
    return if (candidate > max) candidate - 100 else candidate;
}

test windowYear {
    try std.testing.expectEqual(@as(Year, 2024), windowYear(24, 2049));
    try std.testing.expectEqual(@as(Year, 1970), windowYear(70, 2049));
}

/// Reads a run of chunks into `state`.
fn readUChunks(
    comptime chunks: []const UChunk,
    rest: *[]const u8,
    state: *UState,
    comptime culture: Culture,
) dotnet.ParseError!void {
    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try expect(rest, text),
        .date_separator => try expect(rest, culture.date_separator),
        .time_separator => try expect(rest, culture.time_separator),
        .conversion => |which| try readConversion(which, rest, state, culture),
    };
}

/// Steps over `text`, which has to be at the start of the input.
fn expect(rest: *[]const u8, text: []const u8) dotnet.ParseError!void {
    if (!std.mem.startsWith(u8, rest.*, text)) return error.ParseError;
    rest.* = rest.*[text.len..];
}

test expect {
    var text: []const u8 = "-05";
    try expect(&text, "-");
    try std.testing.expectEqualStrings("05", text);
    try std.testing.expectError(error.ParseError, expect(&text, "-"));
}

/// Reads one conversion.
fn readConversion(
    comptime which: Conversion,
    rest: *[]const u8,
    state: *UState,
    comptime culture: Culture,
) dotnet.ParseError!void {
    const settle = dotnet.settle;

    switch (which) {
        .weekday_long, .weekday_short => {
            const match = culture.names.matchWeekday(rest.*, if (which == .weekday_long) .dddd else .ddd) orelse
                return error.ParseError;
            rest.* = rest.*[match.len..];
            try settle(DayOfWeek, &state.weekday, match.weekday);
        },
        .month_long, .month_short => {
            const match = culture.names.matchMonth(rest.*, if (which == .month_long) .MMMM else .MMM) orelse
                return error.ParseError;
            rest.* = rest.*[match.len..];
            try settle(u8, &state.month, match.month.monthNumber());
        },

        .century => try settle(i32, &state.century, @intCast(try readDigits(rest, 1, 2))),
        .day => try settle(u8, &state.day, @intCast(try readDigits(rest, 2, 2))),
        .day_spaced => try settle(u8, &state.day, @intCast(try spaced(rest))),
        .iso_year => try settle(i32, &state.iso_year, @intCast(try readDigits(rest, 4, 4))),
        .iso_year_short => try settle(i32, &state.iso_short_year, @intCast(try readDigits(rest, 2, 2))),
        .hour24 => try settle(u8, &state.hour, @intCast(try readDigits(rest, 2, 2))),
        .hour24_spaced => try settle(u8, &state.hour, @intCast(try spaced(rest))),
        .hour12 => try settle(u8, &state.hour12, try twelveHour(try readDigits(rest, 2, 2))),
        .hour12_spaced => try settle(u8, &state.hour12, try twelveHour(try spaced(rest))),
        .day_of_year => try settle(u16, &state.day_of_year, @intCast(try readDigits(rest, 3, 3))),
        .minute => try settle(u8, &state.minute, @intCast(try readDigits(rest, 2, 2))),
        .month => try settle(u8, &state.month, @intCast(try readDigits(rest, 2, 2))),
        .second => try settle(u8, &state.second, @intCast(try readDigits(rest, 2, 2))),
        .week => try settle(u8, &state.week, @intCast(try readDigits(rest, 1, 2))),
        .iso_week => try settle(u8, &state.iso_week, @intCast(try readDigits(rest, 2, 2))),
        .year => try settle(i32, &state.year, @intCast(try readDigits(rest, 4, 4))),
        .year_short => try settle(i32, &state.short_year, @intCast(try readDigits(rest, 2, 2))),

        .iso_weekday => {
            const number = try readDigits(rest, 1, 1);
            if (number < 1 or number > 7) return error.ParseError;
            try settle(DayOfWeek, &state.weekday, @enumFromInt(number % 7));
        },
        .weekday_number => {
            const number = try readDigits(rest, 1, 1);
            if (number > 6) return error.ParseError;
            try settle(DayOfWeek, &state.weekday, @enumFromInt(number));
        },

        .meridiem => {
            const half: locale.Half = if (matchWord(rest, culture.am_designator))
                .am
            else if (matchWord(rest, culture.pm_designator))
                .pm
            else
                return error.ParseError;
            try settle(locale.Half, &state.half, half);
        },

        .epoch_seconds => {
            const negative = rest.len > 0 and rest.*[0] == '-';
            if (negative) rest.* = rest.*[1..];
            // Fifteen digits is thirty million years either side of the
            // epoch, which a `Year` holds; more would be clamped to the end
            // of the calendar rather than read.
            const magnitude: i64 = @intCast(try digitsWide(rest, 1, 15));
            try settle(i64, &state.epoch, if (negative) -magnitude else magnitude);
        },

        .offset_hours => {
            if (rest.len == 0) return error.ParseError;
            const sign: i32 = switch (rest.*[0]) {
                '+' => 1,
                '-' => -1,
                else => return error.ParseError,
            };
            rest.* = rest.*[1..];
            const hours: i32 = @intCast(try readDigits(rest, 2, 2));
            try settle(i32, &state.offset, sign * hours * std.time.s_per_hour);
        },
    }
}

/// Reads between `min` and `max` ASCII digits.
fn readDigits(rest: *[]const u8, min: usize, max: usize) dotnet.ParseError!u32 {
    return @intCast(try digitsWide(rest, min, max));
}

test readDigits {
    var text: []const u8 = "2024-";
    try std.testing.expectEqual(@as(u32, 2024), try readDigits(&text, 4, 4));
    try std.testing.expectEqualStrings("-", text);
}

/// `readDigits`, for the up to fifteen of `%s`.
fn digitsWide(rest: *[]const u8, min: usize, max: usize) dotnet.ParseError!u64 {
    var value: u64 = 0;
    var read: usize = 0;
    while (read < max and read < rest.len and std.ascii.isDigit(rest.*[read])) : (read += 1) {
        value = value * 10 + (rest.*[read] - '0');
    }
    if (read < min) return error.ParseError;
    rest.* = rest.*[read..];
    return value;
}

test digitsWide {
    var text: []const u8 = "1710513005";
    try std.testing.expectEqual(@as(u64, 1710513005), try digitsWide(&text, 1, 17));
}

/// Reads a number written two wide with a space in front of a single
/// digit, which is what `{0,2}` makes: " 5" or "15".
fn spaced(rest: *[]const u8) dotnet.ParseError!u32 {
    if (rest.len > 0 and rest.*[0] == ' ') {
        rest.* = rest.*[1..];
        return readDigits(rest, 1, 1);
    }
    return readDigits(rest, 2, 2);
}

test spaced {
    var single: []const u8 = " 5";
    try std.testing.expectEqual(@as(u32, 5), try spaced(&single));

    var double: []const u8 = "15";
    try std.testing.expectEqual(@as(u32, 15), try spaced(&double));
}

/// Checks that an hour read from a twelve hour clock is one.
fn twelveHour(hour: u32) dotnet.ParseError!u8 {
    if (hour < 1 or hour > 12) return error.ParseError;
    return @intCast(hour);
}

test twelveHour {
    try std.testing.expectEqual(@as(u8, 12), try twelveHour(12));
    try std.testing.expectError(error.ParseError, twelveHour(0));
}

/// Steps over `word` at the start of the input in any case, and says
/// whether it was there.
fn matchWord(rest: *[]const u8, word: []const u8) bool {
    if (word.len == 0 or rest.len < word.len) return false;
    if (!std.ascii.eqlIgnoreCase(rest.*[0..word.len], word)) return false;
    rest.* = rest.*[word.len..];
    return true;
}

test matchWord {
    var text: []const u8 = "am";
    try std.testing.expect(matchWord(&text, "AM"));
}

test "a -UFormat string reads back as what it wrote" {
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .hour = 21,
        .minute = 7,
        .second = 9,
        .offset = -5 * std.time.s_per_hour,
    };
    value.updateDayOfWeek();

    var buffer: [128]u8 = undefined;
    inline for (.{
        "%c %Z",
        "%A, %B %e, %Y %r %Z",
        "%F %T %Z",
        "%D %R:%S %Z (%j, %U, %u, %w)",
        "%G-W%V-%u %H:%M:%S %Z",
        "%C%y-%m-%d %k:%M:%S %Z",
        "%Y %j %l:%M:%S %p %Z",
    }) |format_string| {
        const written = try bufUFormat(&buffer, value, format_string);
        const back = parseUFormat(format_string, written) catch |err| {
            std.debug.print("{s}: {s}\n", .{ format_string, written });
            return err;
        };
        try std.testing.expectEqual(value.toInstant().timestamp, back.value.toInstant().timestamp);
        try std.testing.expectEqual(value.offset, back.value.offset);
    }

    // `%s` is an instant with no offset of its own.
    const stamp = try bufUFormat(&buffer, value, "%s");
    const instant = try parseUFormat("%s", stamp);
    try std.testing.expectEqual(value.toInstant().timestamp, instant.value.toInstant().timestamp);
}
