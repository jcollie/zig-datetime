// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formatting and parsing with the C library's conversion specifications,
//! where the format string is the one everybody has already typed:
//! `%Y-%m-%d %H:%M:%S`.
//!
//! A `%` introduces a conversion, everything else is copied through, and
//! `%%` is a literal percent sign. Between the `%` and the letter go the
//! GNU flags `-`, `_`, `0`, `^` and `#`, then a minimum field width, then
//! the `E` or `O` modifier that asks a locale for an alternative
//! representation it does not have here:
//!
//! ```zig
//! try strftime.format(value, "%A, %-d %B %Y", writer);   // Friday, 5 January 2024
//! const back = try strftime.parseAll("%Y-%m-%d", "2024-03-15");
//! ```
//!
//! This is the fourth vocabulary in the library, beside the moment.js
//! sequences `DateTime.format` uses, Go's layouts in `golayout` and the
//! CLDR patterns in `cldr`. It is here because a format string in a
//! configuration file, a log template or a shell script is nearly always
//! written this way, and translating one by hand is how a date ends up
//! wrong.
//!
//! The format string is comptime, so it is taken apart while this is
//! compiled and what is left at runtime is a straight line of writes or
//! reads. A conversion the module does not know is a compile error rather
//! than text copied through, which is what the C library does with one:
//! a `%Q` that silently writes itself is a typo nobody finds.
//!
//! glibc is the specification, in its `C` locale, and
//! `tools/oracle_strftime.c` checks it: both sides format the same corpus,
//! read what they wrote back, and the results are diffed. Where this
//! deliberately differs it is written down on the piece that differs, and
//! the oracle carries the same list so that anything else is a failure.
//! Writing, there are three:
//!
//! - **`%s` honours the offset.** A `struct tm` reaches a count of
//!   seconds through `mktime`, so glibc reads the fields against the
//!   process's own timezone and ignores `tm_gmtoff`. A `DateTime` carries
//!   the offset that says which instant it names, and uses it.
//! - **`%Z` writes nothing when the zone is not known**, which POSIX
//!   allows in so many words. glibc falls back to the running process's
//!   zone name, which would be a claim about where a reading was made
//!   that nothing here can support.
//! - **`%N` and `%:z`, `%::z` and `%:::z` exist.** They are `date(1)`'s
//!   rather than `strftime(3)`'s, and glibc's `strftime` writes them out
//!   as text. Without them a nanosecond and an RFC 3339 offset could not
//!   be written at all.
//!
//! Reading, glibc's `strptime` is followed as far as it goes and then
//! four things are kept that it throws away or refuses: `%G` with `%V`
//! resolves an ISO week date, `%j` names a date without a year beside it,
//! `%P` is read as well as written, and the flags, widths and `E`/`O`
//! modifiers are ignored rather than refused, so that a format string
//! which writes a date can read one back. `%s` reads a negative count
//! too, which glibc writes and cannot read.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Instant = @import("Instant.zig");
const Month = @import("month.zig").Month;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const Year = @import("year.zig").Year;
const locale = @import("locale.zig");

/// Format strings worth having a name for, so that a caller reaching for
/// a standard shape does not have to get the punctuation right twice.
pub const pattern = struct {
    /// What `ctime(3)` and `%c` write: `Fri Mar 15 14:30:05 2024`.
    pub const ctime = "%a %b %e %H:%M:%S %Y";
    /// What `date(1)` prints with no arguments.
    pub const date_command = "%a %b %e %H:%M:%S %Z %Y";
    /// ISO 8601's calendar date on its own.
    pub const iso_date = "%Y-%m-%d";
    /// ISO 8601's time of day on its own.
    pub const iso_time = "%H:%M:%S";
    /// RFC 3339, which needs the colon in the offset and so needs the
    /// `date(1)` extension `%:z`.
    pub const rfc_3339 = "%Y-%m-%dT%H:%M:%S%:z";
    /// The `Date:` header of a mail message, as RFC 5322 writes one.
    pub const rfc_5322 = "%a, %d %b %Y %H:%M:%S %z";
};

/// One conversion, named for what it stands for rather than for its
/// letter, with the letter beside it.
pub const Conversion = enum {
    weekday_short, // %a
    weekday_long, // %A
    month_short, // %b, %h
    month_long, // %B
    date_and_time, // %c
    century, // %C
    day, // %d
    date_slashes, // %D, %x
    day_spaced, // %e
    date_dashes, // %F
    iso_year_short, // %g
    iso_year, // %G
    hour24, // %H
    hour12, // %I
    day_of_year, // %j
    hour24_spaced, // %k
    hour12_spaced, // %l
    month, // %m
    minute, // %M
    newline, // %n
    nanosecond, // %N, from date(1)
    meridiem_upper, // %p
    meridiem_lower, // %P
    time12, // %r
    hour_minute, // %R
    epoch_seconds, // %s
    second, // %S
    tab, // %t
    time24, // %T, %X
    iso_weekday, // %u
    week_from_sunday, // %U
    iso_week, // %V
    weekday_number, // %w
    week_from_monday, // %W
    year_short, // %y
    year, // %Y
    offset, // %z
    offset_colon, // %:z, from date(1)
    offset_colon_seconds, // %::z, from date(1)
    offset_minimal, // %:::z, from date(1)
    zone, // %Z
    percent, // %%
};

/// What a flag asks for in place of a field's own padding.
pub const Pad = enum {
    /// Whatever the field pads with by itself.
    default,
    /// `-`: do not pad at all, whatever width was asked for.
    none,
    /// `_`: pad with spaces.
    space,
    /// `0`: pad with zeros.
    zero,
};

/// What a flag asks for in place of a field's own capitalization.
pub const Case = enum {
    /// However the field writes itself.
    none,
    /// `^`: upper case.
    upper,
    /// `#`: the opposite case to the field's own, which is upper case for
    /// a name and lower case for `%p` and `%Z`.
    opposite,
};

/// One conversion and the flags, width and modifier written with it.
pub const Field = struct {
    which: Conversion,
    pad: Pad = .default,
    case: Case = .none,
    /// The minimum field width, or zero when none was asked for. It is a
    /// minimum: a value too wide for it is written in full.
    width: u8 = 0,
};

/// A format string is a run of these: text to copy through, or a
/// conversion to fill in.
pub const Chunk = union(enum) {
    literal: []const u8,
    conversion: Field,
};

/// The longest a single conversion writes before padding is applied.
/// `%c` in a language with long names is the widest thing here, and a
/// field that overran would be a `Writer` failure rather than a silent
/// truncation.
const max_field = 256;

/// Splits `format_string` into chunks, which is the whole of understanding
/// a strftime format.
///
/// A conversion is `%`, then any number of the flags `-_0^#` with the last
/// of each kind winning, then an optional minimum field width, then an
/// optional `E` or `O` modifier, then the conversion letter. The `%:z`
/// family is the one exception to that shape, and the colons come last
/// because `date(1)` puts them there.
///
/// Anything that is not a conversion this module knows is a compile error,
/// naming what was found. That is deliberately not what the C library
/// does, which copies an unknown conversion through as text: a `%P`
/// misremembered as `%p`, or a `%N` used where the library has none, is a
/// bug that should be found while the program is compiled rather than read
/// out of its output later.
pub fn tokenize(comptime format_string: []const u8) []const Chunk {
    comptime {
        @setEvalBranchQuota(100000);

        var chunks: []const Chunk = &.{};
        var literal_start: usize = 0;
        var i: usize = 0;

        while (i < format_string.len) {
            if (format_string[i] != '%') {
                i += 1;
                continue;
            }

            var field: Field = .{ .which = .percent };
            var j = i + 1;

            // The flags, in any order and as many as are written. glibc
            // lets the last of each kind win rather than refusing a
            // contradiction, so `%_0d` pads with zeros.
            flags: while (j < format_string.len) : (j += 1) {
                switch (format_string[j]) {
                    '-' => field.pad = .none,
                    '_' => field.pad = .space,
                    '0' => field.pad = .zero,
                    '^' => field.case = .upper,
                    '#' => field.case = .opposite,
                    else => break :flags,
                }
            }

            // The width. Note that the leading `0` of `%09d` has already
            // been taken as a flag above, which is what makes that mean a
            // zero-padded width of nine rather than a width of ninety.
            var width: usize = 0;
            var width_digits: usize = 0;
            while (j < format_string.len and std.ascii.isDigit(format_string[j])) : (j += 1) {
                width = width * 10 + (format_string[j] - '0');
                width_digits += 1;
                if (width > std.math.maxInt(u8)) @compileError(
                    "strftime: field width in '" ++ format_string ++ "' is wider than 255",
                );
            }
            if (width_digits > 0) field.width = width;

            // `E` and `O` ask the locale for an alternative
            // representation: era-based years, and the locale's own
            // digits. No locale here has either, and POSIX says the
            // unmodified conversion is used when the locale has no
            // alternative, so they are read and dropped.
            if (j < format_string.len and (format_string[j] == 'E' or format_string[j] == 'O')) j += 1;

            var colons: usize = 0;
            while (j < format_string.len and format_string[j] == ':') : (j += 1) colons += 1;

            if (j >= format_string.len) @compileError(
                "strftime: '" ++ format_string ++ "' ends in the middle of a conversion",
            );

            field.which = switch (format_string[j]) {
                'a' => .weekday_short,
                'A' => .weekday_long,
                'b', 'h' => .month_short,
                'B' => .month_long,
                'c' => .date_and_time,
                'C' => .century,
                'd' => .day,
                'D', 'x' => .date_slashes,
                'e' => .day_spaced,
                'F' => .date_dashes,
                'g' => .iso_year_short,
                'G' => .iso_year,
                'H' => .hour24,
                'I' => .hour12,
                'j' => .day_of_year,
                'k' => .hour24_spaced,
                'l' => .hour12_spaced,
                'm' => .month,
                'M' => .minute,
                'n' => .newline,
                'N' => .nanosecond,
                'p' => .meridiem_upper,
                'P' => .meridiem_lower,
                'r' => .time12,
                'R' => .hour_minute,
                's' => .epoch_seconds,
                'S' => .second,
                't' => .tab,
                'T', 'X' => .time24,
                'u' => .iso_weekday,
                'U' => .week_from_sunday,
                'V' => .iso_week,
                'w' => .weekday_number,
                'W' => .week_from_monday,
                'y' => .year_short,
                'Y' => .year,
                'z' => switch (colons) {
                    0 => .offset,
                    1 => .offset_colon,
                    2 => .offset_colon_seconds,
                    3 => .offset_minimal,
                    else => @compileError(
                        "strftime: '" ++ format_string ++ "' writes more than three colons before %z",
                    ),
                },
                'Z' => .zone,
                '%' => .percent,
                else => @compileError(
                    "strftime: '%" ++ [_]u8{format_string[j]} ++ "' in '" ++ format_string ++
                        "' is not a conversion this library knows",
                ),
            };

            if (colons > 0 and field.which != .offset_colon and
                field.which != .offset_colon_seconds and field.which != .offset_minimal)
            {
                @compileError(
                    "strftime: only %z takes colons, not '%" ++ [_]u8{format_string[j]} ++ "'",
                );
            }

            if (literal_start < i) chunks = chunks ++ &[_]Chunk{.{ .literal = format_string[literal_start..i] }};
            chunks = chunks ++ &[_]Chunk{.{ .conversion = field }};

            j += 1;
            literal_start = j;
            i = j;
        }

        if (literal_start < format_string.len) {
            chunks = chunks ++ &[_]Chunk{.{ .literal = format_string[literal_start..] }};
        }

        return chunks;
    }
}

test tokenize {
    const date = comptime tokenize("%Y-%m-%d");
    try std.testing.expectEqual(@as(usize, 5), date.len);
    try std.testing.expectEqual(Conversion.year, date[0].conversion.which);
    try std.testing.expectEqualStrings("-", date[1].literal);
    try std.testing.expectEqual(Conversion.month, date[2].conversion.which);

    // Flags, then a width, then the conversion.
    const padded = comptime tokenize("%_10Y");
    try std.testing.expectEqual(Pad.space, padded[0].conversion.pad);
    try std.testing.expectEqual(@as(u8, 10), padded[0].conversion.width);

    // The leading zero of `%09d` is the flag, so nine is the width.
    const zeroed = comptime tokenize("%09d");
    try std.testing.expectEqual(Pad.zero, zeroed[0].conversion.pad);
    try std.testing.expectEqual(@as(u8, 9), zeroed[0].conversion.width);

    // `E` and `O` are read and dropped, so the conversion is the plain one.
    try std.testing.expectEqual(Conversion.day, (comptime tokenize("%Od"))[0].conversion.which);

    // The colons belong to %z and count.
    try std.testing.expectEqual(Conversion.offset_colon, (comptime tokenize("%:z"))[0].conversion.which);

    // Text with no conversion in it is one literal.
    const plain = comptime tokenize("hello");
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("hello", plain[0].literal);
}

/// What a conversion expands to when it is a shorthand for several
/// others, or null when it stands for a value of its own.
///
/// These are the `C` locale's definitions, which is what glibc uses when
/// nothing has set `LC_TIME`. A locale passed to `formatWith` changes the
/// names inside them but not the arrangement, because a `Locale` here is
/// moment.js's and carries no `d_t_fmt` to put in their place.
fn expansion(comptime which: Conversion) ?[]const u8 {
    return switch (which) {
        .date_and_time => "%a %b %e %H:%M:%S %Y",
        .date_slashes => "%m/%d/%y",
        .date_dashes => "%Y-%m-%d",
        .time12 => "%I:%M:%S %p",
        .hour_minute => "%H:%M",
        .time24 => "%H:%M:%S",
        else => null,
    };
}

/// How wide a conversion writes itself and what it pads with when no flag
/// says otherwise.
const Shape = struct {
    width: u8 = 0,
    pad: u8 = '0',
};

/// The default shape of each conversion.
///
/// The year-ish fields -- `%Y`, `%G`, `%C` and `%s` -- are the ones with
/// no default width, so year 5 is `5` rather than `0005`. That is glibc's
/// behaviour rather than an oversight here: a width given explicitly
/// still applies, so `%4Y` is `0005`.
fn shapeOf(comptime which: Conversion) Shape {
    return switch (which) {
        .day, .hour24, .hour12, .month, .minute, .second, .year_short, .iso_year_short, .week_from_sunday, .week_from_monday, .iso_week => .{ .width = 2, .pad = '0' },
        .day_spaced, .hour24_spaced, .hour12_spaced => .{ .width = 2, .pad = ' ' },
        .day_of_year => .{ .width = 3, .pad = '0' },
        .iso_weekday, .weekday_number => .{ .width = 1, .pad = '0' },
        // A name widened to a column is padded with spaces, because a
        // zero in front of a word is not a word.
        .weekday_short, .weekday_long, .month_short, .month_long, .meridiem_upper, .meridiem_lower, .zone => .{ .width = 0, .pad = ' ' },
        else => .{ .width = 0, .pad = '0' },
    };
}

/// What to do to the bytes a conversion produced on the way out.
const Transform = enum { none, upper, lower };

/// Which case the `#` flag asks for, which is the opposite of the case
/// the conversion writes by itself.
fn oppositeOf(comptime which: Conversion) Transform {
    return switch (which) {
        .weekday_short, .weekday_long, .month_short, .month_long => .upper,
        .meridiem_upper, .zone => .lower,
        else => .none,
    };
}

/// The case transform a field asks for.
///
/// `%P` is always lower case, whatever flag is written with it, because
/// lower case is the whole of what distinguishes it from `%p`. The
/// composite conversions take no case from a flag either, with `%c` the
/// single exception; both of those are glibc's behaviour, checked by the
/// oracle.
fn transformOf(comptime field: Field) Transform {
    if (field.which == .meridiem_lower) return .none;
    if (expansion(field.which) != null and field.which != .date_and_time) return .none;

    return switch (field.case) {
        .none => .none,
        .upper => .upper,
        .opposite => oppositeOf(field.which),
    };
}

/// Writes `value` under `format_string` in the `en` locale, which is the
/// `C` locale's names.
///
/// Flushes `writer` before returning, as `DateTime.format` does.
///
/// ```zig
/// try strftime.format(value, "%Y-%m-%dT%H:%M:%S%:z", writer);
/// ```
pub fn format(
    value: DateTime,
    comptime format_string: []const u8,
    writer: *std.Io.Writer,
) !void {
    return formatWith(value, format_string, locale.en, writer);
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
        .designation = .from("CDT"),
    };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2024-03-15", try bufFormat(&buffer, value, "%Y-%m-%d"));
    try std.testing.expectEqualStrings("14:30:05", try bufFormat(&buffer, value, "%T"));
    try std.testing.expectEqualStrings(
        "Fri Mar 15 14:30:05 2024",
        try bufFormat(&buffer, value, "%c"),
    );
    try std.testing.expectEqualStrings(
        "2024-03-15T14:30:05-05:00",
        try bufFormat(&buffer, value, pattern.rfc_3339),
    );

    // The flags: `-` drops the padding, `_` pads with spaces, `^` shouts.
    try std.testing.expectEqualStrings("3", try bufFormat(&buffer, value, "%-m"));
    try std.testing.expectEqualStrings(" 3", try bufFormat(&buffer, value, "%_m"));
    try std.testing.expectEqualStrings("MARCH", try bufFormat(&buffer, value, "%^B"));
    try std.testing.expectEqualStrings("pm", try bufFormat(&buffer, value, "%#p"));
}

/// Writes `value` under `format_string`, taking the month names, day
/// names and meridiem from `in`.
///
/// The format string stays comptime because it decides which code runs;
/// the locale does not, because it only decides which bytes come out, so
/// it can be chosen at run time from a header or a configuration file.
/// This is the same split `DateTime.formatWith` makes.
///
/// Only the names follow the locale. The arrangements behind `%c`, `%x`
/// and `%X` stay the `C` locale's, because a `locale.Locale` is
/// moment.js's and has no `d_t_fmt`, `d_fmt` or `t_fmt` to put in their
/// place; `cldr.formatDateTime` is the entry point that does know how a
/// language arranges a date.
///
/// ```zig
/// try strftime.formatWith(value, "%A %-d %B", locale.byName("fr").?, writer);
/// ```
pub fn formatWith(
    value: DateTime,
    comptime format_string: []const u8,
    in: locale.Locale,
    writer: *std.Io.Writer,
) !void {
    try writeFormat(value, format_string, in, writer);
    try writer.flush();
}

test formatWith {
    var value: DateTime = .{ .year = 2024, .month = .Mar, .day = 15 };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try formatWith(value, "%A %-d %B %Y", locale.en, &writer);
    try std.testing.expectEqualStrings("Friday 15 March 2024", writer.buffered());
}

/// Formats into `writer` without flushing it, which is what the composite
/// conversions and the public entry points are both built out of.
fn writeFormat(
    value: DateTime,
    comptime format_string: []const u8,
    in: locale.Locale,
    writer: *std.Io.Writer,
) !void {
    const chunks = comptime tokenize(format_string);

    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .conversion => |field| try writeConversion(value, field, in, writer),
    };
}

/// Writes one conversion, padded and cased the way its flags asked for.
///
/// Everything is written into a buffer first rather than straight out,
/// because a minimum field width and a case change are both properties of
/// the whole field and neither can be applied until its length is known.
fn writeConversion(
    value: DateTime,
    comptime field: Field,
    in: locale.Locale,
    writer: *std.Io.Writer,
) !void {
    // The three that are pure text, and have no width or case to speak of.
    switch (field.which) {
        .newline => return writer.writeAll("\n"),
        .tab => return writer.writeAll("\t"),
        .percent => return writer.writeAll("%"),
        // A fraction's width is a number of digits rather than a minimum,
        // because that is what `date(1)` means by `%3N`, so it does its
        // own writing.
        .nanosecond => return writeFraction(writer, value.nanosecond, if (field.width == 0) 9 else field.width),
        else => {},
    }

    var buffer: [max_field]u8 = undefined;
    var field_writer = std.Io.Writer.fixed(&buffer);
    const into = &field_writer;

    const date = value.asDate();

    switch (field.which) {
        .weekday_short => try into.writeAll(in.weekdayName(value.weekday, .ddd)),
        .weekday_long => try into.writeAll(in.weekdayName(value.weekday, .dddd)),
        .month_short => try into.writeAll(in.monthName(value.month, .MMM, false)),
        .month_long => try into.writeAll(in.monthName(value.month, .MMMM, false)),

        .century => try into.print("{d}", .{@divFloor(value.year, 100)}),
        .day, .day_spaced => try into.print("{d}", .{value.day}),
        .day_of_year => try into.print("{d}", .{value.dayOfThisYear()}),
        .hour24, .hour24_spaced => try into.print("{d}", .{value.hour}),
        .hour12, .hour12_spaced => try into.print("{d}", .{twelve(value.hour)}),
        .month => try into.print("{d}", .{value.month.monthNumber()}),
        .minute => try into.print("{d}", .{value.minute}),
        .second => try into.print("{d}", .{value.second}),

        // The last two digits of the year, counted so that the year before
        // year 1 is 99 rather than 1. That is glibc's arithmetic, and it
        // differs from the `YY` sequence and Go's `06`, both of which take
        // the magnitude first and write 1.
        .year_short => try into.print("{d}", .{@mod(value.year, 100)}),
        .year => try into.print("{d}", .{value.year}),
        .iso_year => try into.print("{d}", .{date.isoWeek().year}),
        .iso_year_short => try into.print("{d}", .{@mod(date.isoWeek().year, 100)}),
        .iso_week => try into.print("{d}", .{date.isoWeek().week}),
        .iso_weekday => try into.print("{d}", .{value.weekday.isoWeekdayNumber()}),
        .weekday_number => try into.print("{d}", .{value.weekday.weekdayNumber()}),
        .week_from_sunday => try into.print("{d}", .{weekFrom(value, .Sun)}),
        .week_from_monday => try into.print("{d}", .{weekFrom(value, .Mon)}),

        .meridiem_upper => try in.writeMeridiem(into, value.hour, value.minute, .upper),
        .meridiem_lower => try in.writeMeridiem(into, value.hour, value.minute, .lower),

        // The instant this reading names, which honours the offset. glibc
        // cannot: a `struct tm` reaches it through `mktime`, so its `%s`
        // reads the fields against the process's own timezone and ignores
        // `tm_gmtoff` entirely. The oracle compares this one only at a
        // zero offset, where the two questions are the same question.
        .epoch_seconds => try into.print("{d}", .{@divFloor(value.toInstant().timestamp, std.time.ns_per_s)}),

        .offset => try writeOffset(into, value.offset, .{}),
        .offset_colon => try writeOffset(into, value.offset, .{ .colons = true }),
        .offset_colon_seconds => try writeOffset(into, value.offset, .{ .colons = true, .seconds = true }),
        .offset_minimal => try writeOffset(into, value.offset, .{ .colons = true, .minimal = true }),

        // What the zone calls itself, and nothing at all when that is not
        // known, which POSIX allows in so many words. glibc writes the
        // running process's zone name instead, because a `struct tm` that
        // carries no `tm_zone` still has `tzname` behind it; there is no
        // equivalent here, and inventing one would be a lie about where a
        // reading was made.
        .zone => try into.writeAll(value.designation.slice()),

        .date_and_time, .date_slashes, .date_dashes, .time12, .hour_minute, .time24 => try writeFormat(
            value,
            comptime expansion(field.which).?,
            in,
            into,
        ),

        .newline, .tab, .percent, .nanosecond => unreachable,
    }

    const shape = comptime shapeOf(field.which);
    const width: usize = comptime if (field.pad == .none)
        0
    else if (expansion(field.which) != null)
        // glibc pads no composite conversion, whatever width is asked
        // for, so neither does this.
        0
    else if (field.width != 0)
        field.width
    else
        shape.width;
    const pad: u8 = comptime switch (field.pad) {
        .default => shape.pad,
        .none => ' ',
        .space => ' ',
        .zero => '0',
    };

    try emit(writer, field_writer.buffered(), width, pad, comptime transformOf(field));
}

/// Writes `bytes` padded out to `width` and cased as `transform` says.
///
/// A zero pad goes after the sign rather than before it, so a year of -1
/// at a width of six is `-00001` and not `00000-1`. A space pad goes
/// before it, which is what lines a column up.
fn emit(
    writer: *std.Io.Writer,
    bytes: []const u8,
    comptime width: usize,
    comptime pad: u8,
    comptime transform: Transform,
) !void {
    var rest = bytes;

    if (pad == '0' and rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
        try writer.writeByte(rest[0]);
        rest = rest[1..];
    }

    if (bytes.len < width) try writer.splatByteAll(pad, width - bytes.len);

    switch (transform) {
        .none => try writer.writeAll(rest),
        .upper => for (rest) |char| try writer.writeByte(std.ascii.toUpper(char)),
        .lower => for (rest) |char| try writer.writeByte(std.ascii.toLower(char)),
    }
}

test emit {
    var buffer: [16]u8 = undefined;

    var padded = std.Io.Writer.fixed(&buffer);
    try emit(&padded, "5", 3, '0', .none);
    try std.testing.expectEqualStrings("005", padded.buffered());

    // The sign keeps its place in front of the zeros.
    var negative = std.Io.Writer.fixed(&buffer);
    try emit(&negative, "-1", 6, '0', .none);
    try std.testing.expectEqualStrings("-00001", negative.buffered());

    // A value wider than the width is written in full: a width is a
    // minimum and not a truncation.
    var wide = std.Io.Writer.fixed(&buffer);
    try emit(&wide, "2024", 2, '0', .none);
    try std.testing.expectEqualStrings("2024", wide.buffered());

    var shouted = std.Io.Writer.fixed(&buffer);
    try emit(&shouted, "Mar", 0, ' ', .upper);
    try std.testing.expectEqualStrings("MAR", shouted.buffered());
}

/// The hour on a twelve hour clock, where midnight and noon are both 12.
fn twelve(hour: u5) u5 {
    const wrapped = hour % 12;
    return if (wrapped == 0) 12 else wrapped;
}

test twelve {
    try std.testing.expectEqual(@as(u5, 12), twelve(0));
    try std.testing.expectEqual(@as(u5, 1), twelve(1));
    try std.testing.expectEqual(@as(u5, 12), twelve(12));
    try std.testing.expectEqual(@as(u5, 11), twelve(23));
}

/// The week of the year that `%U` and `%W` count, where week 1 begins on
/// the first `starts_on` of the year and the days before it are week 0.
///
/// This is not `Date.weekOfYear`, and the difference matters. That
/// function implements a week rule with a week-numbering year, where the
/// first days of January can belong to the last week of the year before.
/// `%U` and `%W` have no such thing: they are the plain arithmetic
/// `(day_of_year + 7 - weekday) / 7` that C has always used, they never
/// mention another year, and they answer 0 for the days before the year's
/// first Sunday or Monday. A date written with `%Y-%W` and read back
/// under a week-numbering rule would land in the wrong year.
fn weekFrom(value: DateTime, starts_on: DayOfWeek) u8 {
    const day_of_year: i16 = @as(i16, value.dayOfThisYear()) - 1;
    const weekday: i16 = @mod(
        @as(i16, value.weekday.weekdayNumber()) - @as(i16, starts_on.weekdayNumber()),
        7,
    );
    return @intCast(@divTrunc(day_of_year + 7 - weekday, 7));
}

test weekFrom {
    // 1970 opened on a Thursday, so January 1st is in week 0 under both
    // rules: neither the first Sunday nor the first Monday has happened.
    var epoch: DateTime = .{ .year = 1970, .month = .Jan, .day = 1 };
    epoch.updateDayOfWeek();
    try std.testing.expectEqual(@as(u8, 0), weekFrom(epoch, .Sun));
    try std.testing.expectEqual(@as(u8, 0), weekFrom(epoch, .Mon));

    // 2024-03-15 is a Friday, day 75 of a leap year.
    var march: DateTime = .{ .year = 2024, .month = .Mar, .day = 15 };
    march.updateDayOfWeek();
    try std.testing.expectEqual(@as(u8, 10), weekFrom(march, .Sun));
    try std.testing.expectEqual(@as(u8, 11), weekFrom(march, .Mon));
}

/// How much of an offset to write and with what between the parts.
const OffsetShape = struct {
    colons: bool = false,
    seconds: bool = false,
    /// `%:::z`: write only as many parts as are needed, so a whole number
    /// of hours is `-05` and nothing more.
    minimal: bool = false,
};

/// Writes an offset as a sign and then hours, minutes and maybe seconds.
///
/// Always signed, and always at least two digits of hours, which is what
/// every one of these forms requires: an offset written `-5` is not one
/// anything will read back.
fn writeOffset(writer: *std.Io.Writer, offset: i32, shape: OffsetShape) !void {
    try writer.writeAll(if (offset < 0) "-" else "+");

    const magnitude = @abs(offset);
    const hours = magnitude / std.time.s_per_hour;
    const minutes = magnitude % std.time.s_per_hour / std.time.s_per_min;
    const seconds = magnitude % std.time.s_per_min;

    try writer.print("{d:0>2}", .{hours});
    if (shape.minimal and minutes == 0 and seconds == 0) return;

    if (shape.colons) try writer.writeAll(":");
    try writer.print("{d:0>2}", .{minutes});
    if (shape.minimal and seconds == 0) return;
    if (!shape.seconds and !shape.minimal) return;

    if (shape.colons) try writer.writeAll(":");
    try writer.print("{d:0>2}", .{seconds});
}

test writeOffset {
    var buffer: [16]u8 = undefined;

    var plain = std.Io.Writer.fixed(&buffer);
    try writeOffset(&plain, -5 * std.time.s_per_hour, .{});
    try std.testing.expectEqualStrings("-0500", plain.buffered());

    var colons = std.Io.Writer.fixed(&buffer);
    try writeOffset(&colons, 5 * std.time.s_per_hour + 45 * std.time.s_per_min, .{ .colons = true });
    try std.testing.expectEqualStrings("+05:45", colons.buffered());

    // A zone whose offset is not a whole minute needs the seconds, which
    // is what the third form is for: Chicago's local mean time was
    // -5:50:36 before the railways.
    var full = std.Io.Writer.fixed(&buffer);
    try writeOffset(&full, -(5 * std.time.s_per_hour + 50 * std.time.s_per_min + 36), .{ .colons = true, .seconds = true });
    try std.testing.expectEqualStrings("-05:50:36", full.buffered());

    // The minimal form stops as soon as nothing is left to say.
    var minimal = std.Io.Writer.fixed(&buffer);
    try writeOffset(&minimal, -5 * std.time.s_per_hour, .{ .colons = true, .minimal = true });
    try std.testing.expectEqualStrings("-05", minimal.buffered());
}

/// Writes `digits` digits of a fractional second, without a separator in
/// front of them.
///
/// Truncating rather than rounding, and the leading zeros kept, so that
/// `%3N` of 1,500,000 nanoseconds is `001` -- a millisecond and a half
/// read as one millisecond. That is `date(1)`'s behaviour, and it is the
/// only reading that makes `%S.%3N` a time rather than an approximation.
fn writeFraction(writer: *std.Io.Writer, nanosecond: Nanosecond, digits: u8) !void {
    var buffer: [9]u8 = undefined;
    _ = std.fmt.printInt(&buffer, nanosecond, 10, .lower, .{ .width = 9, .fill = '0' });

    if (digits <= 9) return writer.writeAll(buffer[0..digits]);

    // More digits than a nanosecond has: the rest are zeros, because the
    // value has no more precision to give.
    try writer.writeAll(&buffer);
    try writer.splatByteAll('0', digits - 9);
}

test writeFraction {
    var buffer: [16]u8 = undefined;

    var full = std.Io.Writer.fixed(&buffer);
    try writeFraction(&full, 123456789, 9);
    try std.testing.expectEqualStrings("123456789", full.buffered());

    var milli = std.Io.Writer.fixed(&buffer);
    try writeFraction(&milli, 123456789, 3);
    try std.testing.expectEqualStrings("123", milli.buffered());

    // Truncated, not rounded: 1.5 milliseconds is one millisecond.
    var truncated = std.Io.Writer.fixed(&buffer);
    try writeFraction(&truncated, 1_500_000, 3);
    try std.testing.expectEqualStrings("001", truncated.buffered());
}

/// Formats into `buffer` and returns what was written, for the tests.
fn bufFormat(buffer: []u8, value: DateTime, comptime format_string: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try format(value, format_string, &writer);
    return writer.buffered();
}

/// What a format string can fail to read.
///
/// One error, because there is one question -- did this text match this
/// format -- and a caller that wants to know where it stopped has
/// `Result.str` to tell it.
pub const ParseError = error{ParseError};

/// What `parse` read and what it made of it.
pub const Result = struct {
    /// The prefix of the input that was read, so that a caller can carry
    /// on from `text[result.str.len..]`. `strptime` returns a pointer to
    /// the same place.
    str: []const u8,
    value: DateTime,
};

/// What `parseWith` can be told.
pub const Options = struct {
    /// Where the fields the format string does not mention come from. A
    /// format naming only a time gives that time on this date, which is
    /// the same idea as `DateTime.Options.relative_to`.
    relative_to: DateTime = .unix_epoch,
    /// The language the names are written in.
    locale: locale.Locale = locale.en,
};

/// Reads `text` under `format_string`, leaving whatever follows.
///
/// This is `strptime`'s own shape: the format has to match from the start
/// of the input, and text after what the format asked for is left alone
/// rather than refused. `Result.str` is what was read.
///
/// ```zig
/// const result = try strftime.parse("%Y-%m-%d", "2024-03-15 and more");
/// // result.value is the 15th of March; result.str is "2024-03-15".
/// ```
pub fn parse(comptime format_string: []const u8, text: []const u8) ParseError!Result {
    return parseWith(format_string, text, .{});
}

test parse {
    const result = try parse("%Y-%m-%d", "2024-03-15 and more");
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expectEqual(@as(u6, 15), result.value.day);

    // What was read, so that a caller can carry on from the rest.
    try std.testing.expectEqualStrings("2024-03-15", result.str);

    // The weekday is worked out rather than believed, which is why a
    // format naming one does not have to agree with the date.
    try std.testing.expectEqual(DayOfWeek.Fri, result.value.weekday);

    // A field the format does not mention keeps the reference's value,
    // which by default is the epoch.
    try std.testing.expectEqual(@as(u5, 0), result.value.hour);
}

/// Reads `text` under `format_string` and requires the whole of it.
///
/// The common case, and the one `golayout.parse` and `DateTime.parseStrict`
/// also take: a date with something after it is usually a mistake rather
/// than a caller that meant to carry on.
///
/// ```zig
/// const value = try strftime.parseAll("%Y-%m-%dT%H:%M:%S%z", stamp);
/// ```
pub fn parseAll(comptime format_string: []const u8, text: []const u8) ParseError!DateTime {
    const result = try parseWith(format_string, text, .{});
    if (result.str.len != text.len) return error.ParseError;
    return result.value;
}

test parseAll {
    const value = try parseAll("%Y-%m-%dT%H:%M:%S%z", "2024-03-15T14:30:05-0500");
    try std.testing.expectEqual(@as(u5, 14), value.hour);
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), value.offset);

    // Anything left over is a failure here, where `parse` would allow it.
    try std.testing.expectError(error.ParseError, parseAll("%Y-%m-%d", "2024-03-15 and more"));

    // A date that is not a date is refused, which the C library's
    // `strptime` does not do: it will happily hand back the 31st of June.
    try std.testing.expectError(error.ParseError, parseAll("%Y-%m-%d", "2024-06-31"));
}

/// Reads `text` under `format_string`, from `options.relative_to` and in
/// `options.locale`.
///
/// What is accepted follows glibc's `strptime`, which is more forgiving
/// than the formatting side is exact. Whitespace in the format matches
/// any run of whitespace in the input, including none; a numeric field
/// skips whitespace in front of it and takes one digit as readily as its
/// full width; and a name is matched without regard to case, in either
/// its long or its short form, whichever of `%a` and `%A` asked.
///
/// Four things are read that glibc reads and throws away, because there
/// is somewhere here to put them: `%Z` sets the designation, `%z` the
/// offset, `%s` the whole reading, and `%G` with `%V` resolves an ISO
/// week date. `%U` and `%W` are still dropped -- a week counted from the
/// first Sunday of the year names no date without a weekday beside it,
/// and nothing here asks for the pair.
///
/// ```zig
/// const result = try strftime.parseWith("%d %B", "15 mars", .{
///     .locale = locale.byName("fr").?,
///     .relative_to = base,
/// });
/// ```
pub fn parseWith(
    comptime format_string: []const u8,
    text: []const u8,
    options: Options,
) ParseError!Result {
    var state: State = .{ .value = options.relative_to };
    var rest = text;

    try readFormat(format_string, &rest, &state, options);
    try state.finish();

    return .{
        .str = text[0 .. text.len - rest.len],
        .value = state.value,
    };
}

test parseWith {
    // The fields the format does not mention come from the reference
    // rather than from the epoch.
    var base: DateTime = .{ .year = 2019, .month = .Jul, .day = 4, .hour = 9 };
    base.updateDayOfWeek();

    const result = try parseWith("%H:%M", "14:30", .{ .relative_to = base });
    try std.testing.expectEqual(@as(Year, 2019), result.value.year);
    try std.testing.expectEqual(Month.Jul, result.value.month);
    try std.testing.expectEqual(@as(u5, 14), result.value.hour);

    // A name is read in the locale that was asked for, which is only
    // worth checking when there is another locale to ask: without
    // `-Dembed-locales` the library carries English alone.
    if (locale.byName("fr")) |french| {
        const read = try parseWith("%d %B %Y", "15 mars 2024", .{ .locale = french });
        try std.testing.expectEqual(Month.Mar, read.value.month);
    }
}

/// What has been read so far, and what could not be settled until the
/// whole format string had been.
///
/// A date arrives in pieces that mean nothing on their own: a century
/// without a two digit year, a twelve hour clock without its meridiem, a
/// day of the year that needs the year to become a month and a day. So
/// each piece is put here as it is read and `finish` assembles them once.
const State = struct {
    value: DateTime,

    /// `%C`, which is a year only once `%y` has been read too.
    century: ?i32 = null,
    /// `%y`, which is a year only once it is known whether `%C` came with
    /// it.
    short_year: ?i32 = null,

    month_given: bool = false,
    day_given: bool = false,
    /// `%j`, which names a date only with a year beside it.
    day_of_year: ?u16 = null,

    /// `%G`, `%g` and `%V`, which name a date only together.
    iso_year: ?Year = null,
    iso_short_year: ?i32 = null,
    iso_week: ?u16 = null,
    /// `%u`, `%w`, `%a` or `%A`, kept because an ISO week date needs one.
    weekday: ?DayOfWeek = null,

    /// `%I`, which is an hour only once the meridiem is known.
    hour12: ?u8 = null,
    /// `%p` or `%P`.
    half: ?locale.Half = null,

    /// Turns what was read into the date it names, and refuses one that
    /// is not a date.
    ///
    /// The order matters. A year has to exist before a day of the year or
    /// an ISO week can be turned into a month and a day, and both of those
    /// only apply when the format did not name a month and a day outright:
    /// `%Y-%m-%d (%j)` means what it says, and the day of the year in it
    /// is a decoration rather than a second opinion.
    fn finish(self: *State) ParseError!void {
        if (self.century) |century| {
            // A century and a two digit year are one number written in
            // two halves, which is the only reason `%C` exists.
            self.value.year = century * 100 + (self.short_year orelse 0);
        } else if (self.short_year) |short| {
            // glibc's window, which is also Go's: 69 and up are the
            // twentieth century. It is not the one the `YY` sequence uses.
            self.value.year = if (short >= 69) 1900 + short else 2000 + short;
        }

        if (!self.month_given or !self.day_given) {
            if (self.day_of_year) |day| {
                const date = Date.fromDayOfYear(self.value.year, day);
                self.value.year = date.year;
                self.value.month = date.month;
                self.value.day = date.day;
            } else if (self.iso_week) |week| {
                const week_year = self.iso_year orelse if (self.iso_short_year) |short|
                    @as(Year, if (short >= 69) 1900 + short else 2000 + short)
                else
                    self.value.year;

                // Monday when the format named no weekday, because that is
                // the day an ISO week begins on and so the one the week
                // number alone points at.
                const date = Date.fromWeek(week_year, week, self.weekday orelse .Mon, .Mon, 4);
                self.value.year = date.year;
                self.value.month = date.month;
                self.value.day = date.day;
            }
        }

        if (self.hour12) |hour| {
            // Twelve o'clock is hour zero of its half, which is what
            // makes noon and midnight fall out of the meridiem rather
            // than out of the number. It also settles what `%I` means
            // with no `%p` beside it: hour zero, because that is the
            // half nothing said otherwise about. glibc reduces the
            // number the same way and at the same moment.
            var settled: u8 = hour % 12;
            if (self.half) |half| {
                if (half == .pm) settled += 12;
            }
            self.value.hour = @intCast(settled);
        }

        // A meridiem without a twelve hour clock beside it changes
        // nothing, which is glibc's behaviour: `%H %p` of "13 AM" is one
        // o'clock in the afternoon and a contradiction nobody asked about.

        if (!self.value.asDate().isRegular()) return error.ParseError;
        self.value.updateDayOfWeek();
    }
};

/// Reads one format string into `state`, which is what the public entry
/// points and the composite conversions are both built out of.
fn readFormat(
    comptime format_string: []const u8,
    rest: *[]const u8,
    state: *State,
    options: Options,
) ParseError!void {
    const chunks = comptime tokenize(format_string);

    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try readLiteral(rest, text),
        .conversion => |field| try readConversion(field, rest, state, options),
    };
}

/// Matches a literal run of the format string against the input.
///
/// Whitespace in a format string matches any run of whitespace in the
/// input, including none at all, which is why `%Y %m` reads "202403".
/// Everything else has to be there exactly. Both are POSIX's rules for
/// `strptime` rather than choices made here.
fn readLiteral(rest: *[]const u8, text: []const u8) ParseError!void {
    var input = rest.*;

    for (text) |char| {
        if (std.ascii.isWhitespace(char)) {
            while (input.len > 0 and std.ascii.isWhitespace(input[0])) input = input[1..];
            continue;
        }
        if (input.len == 0 or input[0] != char) return error.ParseError;
        input = input[1..];
    }

    rest.* = input;
}

test readLiteral {
    var exact: []const u8 = "-15";
    try readLiteral(&exact, "-");
    try std.testing.expectEqualStrings("15", exact);

    // A space in the format matches a run of them, or none.
    var run: []const u8 = "   15";
    try readLiteral(&run, " ");
    try std.testing.expectEqualStrings("15", run);

    var missing: []const u8 = "15";
    try readLiteral(&missing, " ");
    try std.testing.expectEqualStrings("15", missing);

    var wrong: []const u8 = "/15";
    try std.testing.expectError(error.ParseError, readLiteral(&wrong, "-"));
}

/// Reads one conversion out of the input and records it.
fn readConversion(
    comptime field: Field,
    rest: *[]const u8,
    state: *State,
    options: Options,
) ParseError!void {
    switch (field.which) {
        // Whitespace in the input, or none: the same rule a literal space
        // follows.
        .newline, .tab => try readLiteral(rest, " "),

        .percent => try readLiteral(rest, "%"),

        .weekday_short, .weekday_long => {
            // Either form is accepted whichever was asked for, as glibc
            // does, and the long one is tried first so that "Tuesday" is
            // not read as "Tue" with "sday" left over.
            skipWhitespace(rest);
            const match = options.locale.matchWeekday(rest.*, .dddd) orelse
                options.locale.matchWeekday(rest.*, .ddd) orelse
                return error.ParseError;
            state.weekday = match.weekday;
            rest.* = rest.*[match.len..];
        },

        .month_short, .month_long => {
            skipWhitespace(rest);
            const match = options.locale.matchMonth(rest.*, .MMMM) orelse
                options.locale.matchMonth(rest.*, .MMM) orelse
                return error.ParseError;
            state.value.month = match.month;
            state.month_given = true;
            rest.* = rest.*[match.len..];
        },

        .meridiem_upper, .meridiem_lower => {
            skipWhitespace(rest);
            const match = options.locale.matchMeridiem(rest.*) orelse return error.ParseError;
            state.half = match.half;
            rest.* = rest.*[match.len..];
        },

        .century => state.century = try readNumber(rest, 0, 99, 2),

        .day, .day_spaced => {
            state.value.day = @intCast(try readNumber(rest, 1, 31, 2));
            state.day_given = true;
        },

        .month => {
            state.value.month = @enumFromInt(try readNumber(rest, 1, 12, 2));
            state.month_given = true;
        },

        .day_of_year => state.day_of_year = @intCast(try readNumber(rest, 1, 366, 3)),

        .hour24, .hour24_spaced => state.value.hour = @intCast(try readNumber(rest, 0, 23, 2)),
        .hour12, .hour12_spaced => state.hour12 = @intCast(try readNumber(rest, 1, 12, 2)),
        .minute => state.value.minute = @intCast(try readNumber(rest, 0, 59, 2)),
        // Up to 61, which is what a `struct tm` has always allowed for a
        // leap second and the second one that never came.
        .second => state.value.second = @intCast(try readNumber(rest, 0, 61, 2)),

        .year => {
            state.value.year = try readNumber(rest, 0, 9999, 4);
            state.century = null;
            state.short_year = null;
        },
        .year_short => state.short_year = try readNumber(rest, 0, 99, 2),

        .iso_year => state.iso_year = try readNumber(rest, 0, 9999, 4),
        .iso_year_short => state.iso_short_year = try readNumber(rest, 0, 99, 2),
        .iso_week => state.iso_week = @intCast(try readNumber(rest, 1, 53, 2)),

        // Read and dropped. A week counted from the year's first Sunday
        // or Monday names a date only with a weekday beside it, and
        // neither this nor glibc assembles that pair; `%V` with `%G` is
        // the one that does.
        .week_from_sunday, .week_from_monday => _ = try readNumber(rest, 0, 53, 2),

        // The ISO numbering runs Monday to Sunday as 1 to 7 while
        // `DayOfWeek` counts Sunday as 0, so seven wraps to zero.
        .iso_weekday => state.weekday = @enumFromInt(@mod(try readNumber(rest, 1, 7, 1), 7)),
        .weekday_number => state.weekday = @enumFromInt(try readNumber(rest, 0, 6, 1)),

        .nanosecond => state.value.nanosecond = try readFraction(rest, if (field.width == 0) 9 else field.width),

        .epoch_seconds => {
            const seconds = try readSeconds(rest);
            const instant: Instant = .{ .timestamp = @as(i128, seconds) * std.time.ns_per_s };
            const nanosecond = state.value.nanosecond;
            state.value = instant.asDateTime();
            // An instant says nothing about the fraction of a second, so
            // whatever `%N` read stays where it was.
            state.value.nanosecond = nanosecond;
            state.month_given = true;
            state.day_given = true;
            state.century = null;
            state.short_year = null;
        },

        .offset, .offset_colon, .offset_colon_seconds, .offset_minimal => {
            state.value.offset = try readOffset(rest);
        },

        .zone => {
            // glibc steps over a run of anything that is not whitespace
            // and remembers none of it. The stepping over is the same
            // here; what is stepped over is kept, because a `DateTime`
            // has a field for it.
            skipWhitespace(rest);
            var length: usize = 0;
            while (length < rest.len and !std.ascii.isWhitespace(rest.*[length])) length += 1;
            if (length == 0) return error.ParseError;
            state.value.designation = .from(rest.*[0..length]);
            rest.* = rest.*[length..];
        },

        .date_and_time, .date_slashes, .date_dashes, .time12, .hour_minute, .time24 => try readFormat(
            comptime expansion(field.which).?,
            rest,
            state,
            options,
        ),
    }
}

/// Steps over any whitespace at the start of the input.
///
/// Every numeric and name conversion does this before reading, which is
/// POSIX's rule and is what lets `%e` read both "15" and " 5".
fn skipWhitespace(rest: *[]const u8) void {
    var input = rest.*;
    while (input.len > 0 and std.ascii.isWhitespace(input[0])) input = input[1..];
    rest.* = input;
}

/// Reads a number of at most `max_digits` digits and checks it against
/// `from` and `to`.
///
/// This is glibc's `get_number`, quirk and all, because the quirk is
/// load-bearing: after the first digit it takes another only while the
/// number so far could still be multiplied by ten and stay in range. So
/// `%d` of "99" reads a single 9 and leaves the second, where a plain
/// two digit read would take 99 and refuse it. That is what lets an
/// unpadded field sit next to a digit.
fn readNumber(
    rest: *[]const u8,
    comptime from: i32,
    comptime to: i32,
    comptime max_digits: usize,
) ParseError!i32 {
    skipWhitespace(rest);

    var input = rest.*;
    if (input.len == 0 or !std.ascii.isDigit(input[0])) return error.ParseError;

    var value: i32 = input[0] - '0';
    input = input[1..];

    var left = max_digits - 1;
    while (left > 0 and value * 10 <= to and input.len > 0 and std.ascii.isDigit(input[0])) {
        value = value * 10 + (input[0] - '0');
        input = input[1..];
        left -= 1;
    }

    if (value < from or value > to) return error.ParseError;

    rest.* = input;
    return value;
}

test readNumber {
    var padded: []const u8 = "05-";
    try std.testing.expectEqual(@as(i32, 5), try readNumber(&padded, 1, 31, 2));
    try std.testing.expectEqualStrings("-", padded);

    // A field takes a second digit when one is there and it still fits.
    var wide: []const u8 = "15";
    try std.testing.expectEqual(@as(i32, 15), try readNumber(&wide, 1, 31, 2));

    // And stops when it would not: 99 is not a day of the month, so this
    // is day 9 with a 9 left over rather than a refusal.
    var greedy: []const u8 = "99";
    try std.testing.expectEqual(@as(i32, 9), try readNumber(&greedy, 1, 31, 2));
    try std.testing.expectEqualStrings("9", greedy);

    // Out of range after all the digits are in is a refusal.
    var large: []const u8 = "32";
    try std.testing.expectError(error.ParseError, readNumber(&large, 1, 31, 2));

    // Leading whitespace belongs to the field, which is how " 5" reads.
    var spaced: []const u8 = " 5";
    try std.testing.expectEqual(@as(i32, 5), try readNumber(&spaced, 1, 31, 2));

    var empty: []const u8 = "x";
    try std.testing.expectError(error.ParseError, readNumber(&empty, 1, 31, 2));
}

/// Reads a count of seconds since the epoch, which is the one field here
/// that can be negative.
fn readSeconds(rest: *[]const u8) ParseError!i64 {
    skipWhitespace(rest);

    var input = rest.*;
    const negative = input.len > 0 and input[0] == '-';
    if (negative) input = input[1..];

    if (input.len == 0 or !std.ascii.isDigit(input[0])) return error.ParseError;

    var value: i64 = 0;
    var digits: usize = 0;
    while (input.len > 0 and std.ascii.isDigit(input[0])) {
        // Sixteen digits is half a billion years either side of the
        // epoch, far more than a `Year` can hold and comfortably inside
        // an `i64`, so a longer run is not a time.
        if (digits == 16) return error.ParseError;
        value = value * 10 + (input[0] - '0');
        input = input[1..];
        digits += 1;
    }

    rest.* = input;
    return if (negative) -value else value;
}

test readSeconds {
    var forward: []const u8 = "1710513005";
    try std.testing.expectEqual(@as(i64, 1710513005), try readSeconds(&forward));

    var backward: []const u8 = "-2208988800";
    try std.testing.expectEqual(@as(i64, -2208988800), try readSeconds(&backward));

    var nothing: []const u8 = "-";
    try std.testing.expectError(error.ParseError, readSeconds(&nothing));
}

/// Reads a fraction of a second of at most `digits` digits and scales it
/// to nanoseconds, so "5" is half a second whatever width was asked for.
fn readFraction(rest: *[]const u8, digits: u8) ParseError!Nanosecond {
    var input = rest.*;
    if (input.len == 0 or !std.ascii.isDigit(input[0])) return error.ParseError;

    var value: Nanosecond = 0;
    var read: u8 = 0;
    while (read < digits and read < 9 and input.len > 0 and std.ascii.isDigit(input[0])) {
        value = value * 10 + (input[0] - '0');
        input = input[1..];
        read += 1;
    }

    // Scaled by where the last digit read sat, not by how many were
    // asked for: a field cut short is a coarser number, not a wrong one.
    var scale: Nanosecond = 1;
    for (read..9) |_| scale *= 10;

    rest.* = input;
    return value * scale;
}

test readFraction {
    var half: []const u8 = "5";
    try std.testing.expectEqual(@as(Nanosecond, 500_000_000), try readFraction(&half, 9));

    var milli: []const u8 = "123";
    try std.testing.expectEqual(@as(Nanosecond, 123_000_000), try readFraction(&milli, 3));

    // The width is a maximum: what follows is left for the next field.
    var narrow: []const u8 = "123456";
    try std.testing.expectEqual(@as(Nanosecond, 123_000_000), try readFraction(&narrow, 3));
    try std.testing.expectEqualStrings("456", narrow);
}

/// Reads an offset from UTC and returns it in seconds east.
///
/// Every shape any of the `%z` forms writes is accepted whichever of them
/// asked, along with the bare `Z` that means zero: a format string is
/// usually being pointed at text somebody else wrote, and refusing
/// `+05:45` because the format said `%z` rather than `%:z` would be a
/// distinction without a purpose. glibc reads the same set.
fn readOffset(rest: *[]const u8) ParseError!i32 {
    skipWhitespace(rest);

    var input = rest.*;
    if (input.len == 0) return error.ParseError;

    if (input[0] == 'Z' or input[0] == 'z') {
        rest.* = input[1..];
        return 0;
    }

    const sign: i32 = switch (input[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.ParseError,
    };
    input = input[1..];

    const hours = try twoDigits(&input);
    var minutes: i32 = 0;
    var seconds: i32 = 0;

    if (twoDigitsAfter(&input)) |value| {
        minutes = value;
        if (twoDigitsAfter(&input)) |more| seconds = more;
    }

    if (hours > 23 or minutes > 59 or seconds > 59) return error.ParseError;

    rest.* = input;
    return sign * (hours * std.time.s_per_hour + minutes * std.time.s_per_min + seconds);
}

test readOffset {
    var basic: []const u8 = "-0500";
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), try readOffset(&basic));

    var extended: []const u8 = "+05:45";
    try std.testing.expectEqual(
        @as(i32, 5 * std.time.s_per_hour + 45 * std.time.s_per_min),
        try readOffset(&extended),
    );

    // Hours alone, which is what `%:::z` writes for a whole one.
    var hours: []const u8 = "-05";
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), try readOffset(&hours));

    var seconds: []const u8 = "-05:50:36";
    try std.testing.expectEqual(
        @as(i32, -(5 * std.time.s_per_hour + 50 * std.time.s_per_min + 36)),
        try readOffset(&seconds),
    );

    var zulu: []const u8 = "Z";
    try std.testing.expectEqual(@as(i32, 0), try readOffset(&zulu));

    var missing: []const u8 = "0500";
    try std.testing.expectError(error.ParseError, readOffset(&missing));
}

/// Reads exactly two digits, which every part of an offset is written as.
fn twoDigits(rest: *[]const u8) ParseError!i32 {
    const input = rest.*;
    if (input.len < 2) return error.ParseError;
    if (!std.ascii.isDigit(input[0]) or !std.ascii.isDigit(input[1])) return error.ParseError;
    rest.* = input[2..];
    return @as(i32, input[0] - '0') * 10 + (input[1] - '0');
}

/// Reads the next two digits of an offset, over a colon if there is one,
/// or returns null when the offset stops here.
fn twoDigitsAfter(rest: *[]const u8) ?i32 {
    var input = rest.*;
    if (input.len > 0 and input[0] == ':') input = input[1..];
    if (input.len < 2) return null;
    if (!std.ascii.isDigit(input[0]) or !std.ascii.isDigit(input[1])) return null;

    rest.* = input[2..];
    return @as(i32, input[0] - '0') * 10 + (input[1] - '0');
}

test "a formatted date reads back as itself" {
    // The property the two halves owe each other, over the pieces that
    // carry enough to rebuild a date.
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 5,
        .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
        .designation = .from("+0545"),
    };
    value.updateDayOfWeek();

    var buffer: [128]u8 = undefined;

    inline for (.{
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S%:z",
        "%A, %d %B %Y %I:%M:%S %p",
        "%F %T",
        "%C%y-%j %T",
        "%G-W%V-%u %T",
    }) |format_string| {
        const written = try bufFormat(&buffer, value, format_string);
        const back = try parseAll(format_string, written);

        try std.testing.expectEqual(value.year, back.year);
        try std.testing.expectEqual(value.month, back.month);
        try std.testing.expectEqual(value.day, back.day);
        try std.testing.expectEqual(value.hour, back.hour);
        try std.testing.expectEqual(value.minute, back.minute);
        try std.testing.expectEqual(value.second, back.second);
    }

    // `%s` round trips as well, but it is an instant rather than a
    // reading: what comes back is the same moment written in UTC, because
    // a count of seconds since the epoch says nothing about where the
    // clock was.
    const stamp = try bufFormat(&buffer, value, "%s");
    const instant = try parseAll("%s", stamp);
    try std.testing.expectEqual(value.toInstant().timestamp, instant.toInstant().timestamp);
    try std.testing.expectEqual(@as(i32, 0), instant.offset);
}
