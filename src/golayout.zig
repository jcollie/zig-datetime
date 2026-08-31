// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formatting and parsing with Go's time layouts, where a layout is one
//! particular time written the way you want your own written.
//!
//! Go picked `Mon Jan 2 15:04:05 MST 2006` as that time, chosen so every
//! component has a different number: month 1, day 2, hour 3 on the twelve
//! hour clock and 15 on the twenty-four hour one, minute 4, second 5, year
//! 6, and a zone seven hours west. So `2006-01-02` asks for a four digit
//! year, a zero padded month and a zero padded day, and `Jan _2 3:04PM`
//! asks for a short month name, a space padded day and a twelve hour
//! clock. Nothing is a code to look up; the layout is an example.
//!
//! That is a different idea from the sequences in `formatsequence`, which
//! moment.js established and which `DateTime.format` uses. Both are here
//! because both are what somebody arriving from another language expects
//! to be able to write, and neither is a subset of the other.
//!
//! The layout is comptime, so it is taken apart while this is compiled and
//! what is left at runtime is a straight line of writes or reads.
//!
//! What Go's own package does is the specification, and
//! `tools/oracle_go.go` checks it: both sides format and parse the same
//! corpus and the results are diffed. Where this deliberately differs from
//! Go it is written down on the piece that differs.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Designation = @import("designation.zig").Designation;
const Month = @import("month.zig").Month;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const Year = @import("year.zig").Year;
const read = @import("read.zig");

/// The layouts Go's `time` package names, spelled the same way so that
/// code being moved across can keep using the name it knows.
pub const layout = struct {
    /// The reference time itself, in numerical order.
    pub const default = "01/02 03:04:05PM '06 -0700";
    pub const ansic = "Mon Jan _2 15:04:05 2006";
    pub const unix_date = "Mon Jan _2 15:04:05 MST 2006";
    pub const ruby_date = "Mon Jan 02 15:04:05 -0700 2006";
    pub const rfc822 = "02 Jan 06 15:04 MST";
    pub const rfc822z = "02 Jan 06 15:04 -0700";
    pub const rfc850 = "Monday, 02-Jan-06 15:04:05 MST";
    pub const rfc1123 = "Mon, 02 Jan 2006 15:04:05 MST";
    pub const rfc1123z = "Mon, 02 Jan 2006 15:04:05 -0700";
    pub const rfc3339 = "2006-01-02T15:04:05Z07:00";
    pub const rfc3339_nano = "2006-01-02T15:04:05.999999999Z07:00";
    pub const kitchen = "3:04PM";
    pub const stamp = "Jan _2 15:04:05";
    pub const stamp_milli = "Jan _2 15:04:05.000";
    pub const stamp_micro = "Jan _2 15:04:05.000000";
    pub const stamp_nano = "Jan _2 15:04:05.000000000";
    pub const date_time = "2006-01-02 15:04:05";
    pub const date_only = "2006-01-02";
    pub const time_only = "15:04:05";
};

/// One piece of the reference time, named for what it stands for rather
/// than for how it is written.
pub const Std = enum {
    long_month, // January
    month, // Jan
    num_month, // 1
    zero_month, // 01
    long_weekday, // Monday
    weekday, // Mon
    day, // 2
    under_day, // _2
    zero_day, // 02
    under_year_day, // __2
    zero_year_day, // 002
    hour, // 15
    hour12, // 3
    zero_hour12, // 03
    minute, // 4
    zero_minute, // 04
    second, // 5
    zero_second, // 05
    long_year, // 2006
    year, // 06
    pm, // PM
    lower_pm, // pm
    tz, // MST
    num_tz, // -0700
    num_seconds_tz, // -070000
    num_short_tz, // -07
    num_colon_tz, // -07:00
    num_colon_seconds_tz, // -07:00:00
    iso_tz, // Z0700
    iso_seconds_tz, // Z070000
    iso_short_tz, // Z07
    iso_colon_tz, // Z07:00
    iso_colon_seconds_tz, // Z07:00:00
    /// `.000`, which writes exactly its own number of digits.
    frac_zero,
    /// `.999`, which writes at most its own number of digits and drops
    /// the trailing zeros, and itself when nothing is left.
    frac_nine,
};

/// A layout is a run of these: text to copy through, or a piece of the
/// reference time to fill in.
pub const Chunk = union(enum) {
    literal: []const u8,
    std: struct {
        which: Std,
        /// How many digits a fractional second asks for, and the
        /// character that introduced it. Unused by everything else.
        digits: u8 = 0,
        separator: u8 = '.',
    },
};

/// Whether `text` begins with a lower case letter.
///
/// Go uses this to keep `Jan` out of `January` spelled by hand, and `Mon`
/// out of `Month`: a name is only a name when what follows it could not be
/// more of the same word.
fn startsWithLowerCase(text: []const u8) bool {
    return text.len > 0 and text[0] >= 'a' and text[0] <= 'z';
}

/// Splits `layout_string` into chunks, which is the whole of understanding
/// a Go layout.
///
/// This follows `nextStdChunk` in Go's `time/format.go` step for step,
/// including the parts that look like accidents. `_2006` is a literal
/// underscore followed by a four digit year rather than a space padded
/// anything. `Jan` is only a month when the next character is not lower
/// case. A run of `0`s or `9`s after a dot or a comma is a fractional
/// second only when what follows is not another digit.
pub fn tokenize(comptime layout_string: []const u8) []const Chunk {
    comptime {
        @setEvalBranchQuota(100000);

        var chunks: []const Chunk = &.{};
        var literal_start: usize = 0;
        var i: usize = 0;

        const flush = struct {
            fn f(list: []const Chunk, text: []const u8) []const Chunk {
                if (text.len == 0) return list;
                return list ++ &[_]Chunk{.{ .literal = text }};
            }
        }.f;

        while (i < layout_string.len) {
            const rest = layout_string[i..];

            const found: ?struct { which: Std, len: usize, skip: usize = 0 } = switch (rest[0]) {
                'J' => if (std.mem.startsWith(u8, rest, "January"))
                    .{ .which = .long_month, .len = 7 }
                else if (std.mem.startsWith(u8, rest, "Jan") and !startsWithLowerCase(rest[3..]))
                    .{ .which = .month, .len = 3 }
                else
                    null,

                'M' => if (std.mem.startsWith(u8, rest, "Monday"))
                    .{ .which = .long_weekday, .len = 6 }
                else if (std.mem.startsWith(u8, rest, "Mon") and !startsWithLowerCase(rest[3..]))
                    .{ .which = .weekday, .len = 3 }
                else if (std.mem.startsWith(u8, rest, "MST"))
                    .{ .which = .tz, .len = 3 }
                else
                    null,

                '0' => if (rest.len >= 2 and rest[1] >= '1' and rest[1] <= '6') .{
                    .which = ([_]Std{
                        .zero_month,  .zero_day,    .zero_hour12,
                        .zero_minute, .zero_second, .year,
                    })[rest[1] - '1'],
                    .len = 2,
                } else if (std.mem.startsWith(u8, rest, "002"))
                    .{ .which = .zero_year_day, .len = 3 }
                else
                    null,

                '1' => if (std.mem.startsWith(u8, rest, "15"))
                    .{ .which = .hour, .len = 2 }
                else
                    .{ .which = .num_month, .len = 1 },

                '2' => if (std.mem.startsWith(u8, rest, "2006"))
                    .{ .which = .long_year, .len = 4 }
                else
                    .{ .which = .day, .len = 1 },

                // `_2006` is a literal underscore and then a year, which
                // is Go's rule and not a slip: the underscore only pads a
                // day.
                '_' => if (std.mem.startsWith(u8, rest, "_2006"))
                    .{ .which = .long_year, .len = 5, .skip = 1 }
                else if (std.mem.startsWith(u8, rest, "_2"))
                    .{ .which = .under_day, .len = 2 }
                else if (std.mem.startsWith(u8, rest, "__2"))
                    .{ .which = .under_year_day, .len = 3 }
                else
                    null,

                '3' => .{ .which = .hour12, .len = 1 },
                '4' => .{ .which = .minute, .len = 1 },
                '5' => .{ .which = .second, .len = 1 },

                'P' => if (std.mem.startsWith(u8, rest, "PM")) .{ .which = .pm, .len = 2 } else null,
                'p' => if (std.mem.startsWith(u8, rest, "pm")) .{ .which = .lower_pm, .len = 2 } else null,

                '-' => if (std.mem.startsWith(u8, rest, "-070000"))
                    .{ .which = .num_seconds_tz, .len = 7 }
                else if (std.mem.startsWith(u8, rest, "-07:00:00"))
                    .{ .which = .num_colon_seconds_tz, .len = 9 }
                else if (std.mem.startsWith(u8, rest, "-0700"))
                    .{ .which = .num_tz, .len = 5 }
                else if (std.mem.startsWith(u8, rest, "-07:00"))
                    .{ .which = .num_colon_tz, .len = 6 }
                else if (std.mem.startsWith(u8, rest, "-07"))
                    .{ .which = .num_short_tz, .len = 3 }
                else
                    null,

                'Z' => if (std.mem.startsWith(u8, rest, "Z070000"))
                    .{ .which = .iso_seconds_tz, .len = 7 }
                else if (std.mem.startsWith(u8, rest, "Z07:00:00"))
                    .{ .which = .iso_colon_seconds_tz, .len = 9 }
                else if (std.mem.startsWith(u8, rest, "Z0700"))
                    .{ .which = .iso_tz, .len = 5 }
                else if (std.mem.startsWith(u8, rest, "Z07:00"))
                    .{ .which = .iso_colon_tz, .len = 6 }
                else if (std.mem.startsWith(u8, rest, "Z07"))
                    .{ .which = .iso_short_tz, .len = 3 }
                else
                    null,

                else => null,
            };

            if (found) |token| {
                chunks = flush(chunks, layout_string[literal_start .. i + token.skip]);
                chunks = chunks ++ &[_]Chunk{.{ .std = .{ .which = token.which } }};
                i += token.len;
                literal_start = i;
                continue;
            }

            // A fractional second is a dot or a comma and then a run of
            // one digit repeated, so long as the run is not part of a
            // longer number.
            if (rest[0] == '.' or rest[0] == ',') {
                if (rest.len >= 2 and (rest[1] == '0' or rest[1] == '9')) {
                    const repeated = rest[1];
                    var j: usize = 1;
                    while (j < rest.len and rest[j] == repeated) j += 1;
                    if (j >= rest.len or rest[j] < '0' or rest[j] > '9') {
                        chunks = flush(chunks, layout_string[literal_start..i]);
                        chunks = chunks ++ &[_]Chunk{.{ .std = .{
                            .which = if (repeated == '9') .frac_nine else .frac_zero,
                            .digits = j - 1,
                            .separator = rest[0],
                        } }};
                        i += j;
                        literal_start = i;
                        continue;
                    }
                }
            }

            i += 1;
        }

        return flush(chunks, layout_string[literal_start..]);
    }
}

test tokenize {
    const only_date = comptime tokenize("2006-01-02");
    try std.testing.expectEqual(@as(usize, 5), only_date.len);
    try std.testing.expectEqual(Std.long_year, only_date[0].std.which);
    try std.testing.expectEqualStrings("-", only_date[1].literal);
    try std.testing.expectEqual(Std.zero_month, only_date[2].std.which);

    // A name is only a name when what follows could not be more of the
    // same word, so this is a literal.
    const january = comptime tokenize("Jane");
    try std.testing.expectEqual(@as(usize, 1), january.len);
    try std.testing.expectEqualStrings("Jane", january[0].literal);

    // And `_2006` is an underscore and a year, not a padded anything.
    const underscore = comptime tokenize("_2006");
    try std.testing.expectEqual(@as(usize, 2), underscore.len);
    try std.testing.expectEqualStrings("_", underscore[0].literal);
    try std.testing.expectEqual(Std.long_year, underscore[1].std.which);

    // A run of digits that goes on past the fraction is not a fraction.
    const fraction = comptime tokenize(".000");
    try std.testing.expectEqual(Std.frac_zero, fraction[0].std.which);
    try std.testing.expectEqual(@as(u8, 3), fraction[0].std.digits);
}

/// Writes `value` under `layout_string`.
pub fn format(
    value: DateTime,
    comptime layout_string: []const u8,
    writer: *std.Io.Writer,
) !void {
    const chunks = comptime tokenize(layout_string);

    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .std => |token| switch (token.which) {
            .long_month => try writer.writeAll(value.month.longName()),
            .month => try writer.writeAll(value.month.shortName()),
            .num_month => try writer.print("{d}", .{value.month.monthNumber()}),
            .zero_month => try writer.print("{d:0>2}", .{value.month.monthNumber()}),

            .long_weekday => try writer.writeAll(value.weekday.longName()),
            .weekday => try writer.writeAll(value.weekday.shortName()),

            .day => try writer.print("{d}", .{value.day}),
            .under_day => try writer.print("{d: >2}", .{value.day}),
            .zero_day => try writer.print("{d:0>2}", .{value.day}),

            .under_year_day => try writer.print("{d: >3}", .{value.dayOfThisYear()}),
            .zero_year_day => try writer.print("{d:0>3}", .{value.dayOfThisYear()}),

            .hour => try writer.print("{d:0>2}", .{value.hour}),
            .hour12 => try writer.print("{d}", .{twelve(value.hour)}),
            .zero_hour12 => try writer.print("{d:0>2}", .{twelve(value.hour)}),

            .minute => try writer.print("{d}", .{value.minute}),
            .zero_minute => try writer.print("{d:0>2}", .{value.minute}),
            .second => try writer.print("{d}", .{value.second}),
            .zero_second => try writer.print("{d:0>2}", .{value.second}),

            .long_year => try writeLongYear(writer, value.year),
            // The last two digits of the year as written, so year -44 is
            // "44". Not `@mod`, which would make it 56: Go takes the
            // magnitude first and so does `DateTime.format`'s `YY`.
            .year => try writer.print("{d:0>2}", .{@abs(value.year) % 100}),

            .pm => try writer.writeAll(if (value.hour < 12) "AM" else "PM"),
            .lower_pm => try writer.writeAll(if (value.hour < 12) "am" else "pm"),

            .tz => {
                // Go writes the zone's name when it has one and falls back
                // to the numeric offset when it does not, which is what a
                // `DateTime` that never went through a `TimeZone` has.
                var designation = value.designation;
                if (designation.slice().len > 0) {
                    try writer.writeAll(designation.slice());
                } else {
                    try writeOffset(writer, value.offset, .{ .colons = false, .seconds = false });
                }
            },

            .num_tz => try writeOffset(writer, value.offset, .{ .colons = false, .seconds = false }),
            .num_seconds_tz => try writeOffset(writer, value.offset, .{ .colons = false, .seconds = true }),
            .num_short_tz => try writeOffset(writer, value.offset, .{ .colons = false, .seconds = false, .hours_only = true }),
            .num_colon_tz => try writeOffset(writer, value.offset, .{ .colons = true, .seconds = false }),
            .num_colon_seconds_tz => try writeOffset(writer, value.offset, .{ .colons = true, .seconds = true }),

            // The `Z` forms write a literal Z at zero rather than `+0000`,
            // which is where ISO 8601 and RFC 3339 differ from a bare
            // numeric offset.
            .iso_tz => try writeIsoOffset(writer, value.offset, .{ .colons = false, .seconds = false }),
            .iso_seconds_tz => try writeIsoOffset(writer, value.offset, .{ .colons = false, .seconds = true }),
            .iso_short_tz => try writeIsoOffset(writer, value.offset, .{ .colons = false, .seconds = false, .hours_only = true }),
            .iso_colon_tz => try writeIsoOffset(writer, value.offset, .{ .colons = true, .seconds = false }),
            .iso_colon_seconds_tz => try writeIsoOffset(writer, value.offset, .{ .colons = true, .seconds = true }),

            .frac_zero, .frac_nine => try writeFraction(
                writer,
                value.nanosecond,
                token.which == .frac_nine,
                token.digits,
                token.separator,
            ),
        },
    };

    try writer.flush();
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
    const write = struct {
        fn f(v: DateTime, comptime l: []const u8, b: []u8) ![]const u8 {
            var writer = std.Io.Writer.fixed(b);
            try format(v, l, &writer);
            return writer.buffered();
        }
    }.f;

    // The layout is an example rather than a set of codes: this asks for
    // what the reference time looks like written that way.
    try std.testing.expectEqualStrings("2024-03-15", try write(value, layout.date_only, &buffer));
    try std.testing.expectEqualStrings(
        "2024-03-15T14:30:05-05:00",
        try write(value, layout.rfc3339, &buffer),
    );
    try std.testing.expectEqualStrings("2:30PM", try write(value, layout.kitchen, &buffer));
    try std.testing.expectEqualStrings(
        "Fri, 15 Mar 2024 14:30:05 CDT",
        try write(value, layout.rfc1123, &buffer),
    );

    // `.000` writes its digits whatever they are; `.999` drops the
    // trailing zeros, and itself when nothing is left.
    try std.testing.expectEqualStrings("05.123", try write(value, "05.000", &buffer));
    try std.testing.expectEqualStrings("05.123456789", try write(value, "05.999999999", &buffer));

    var whole = value;
    whole.nanosecond = 0;
    try std.testing.expectEqualStrings("05.000", try write(whole, "05.000", &buffer));
    try std.testing.expectEqualStrings("05", try write(whole, "05.999", &buffer));
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

/// Writes a four digit year, with a leading minus before the common era.
///
/// Go pads to four and writes a sign for anything outside them, which is
/// the same shape `DateTime.format`'s `YYYY` has.
fn writeLongYear(writer: *std.Io.Writer, year: Year) !void {
    if (year < 0) try writer.writeAll("-");
    try writer.print("{d:0>4}", .{@abs(year)});
}

/// How much of an offset to write, and with what between the parts.
const OffsetShape = struct {
    colons: bool,
    seconds: bool,
    hours_only: bool = false,
};

/// Writes an offset as a sign and then hours, minutes and maybe seconds.
fn writeOffset(writer: *std.Io.Writer, offset: i32, shape: OffsetShape) !void {
    try writer.writeAll(if (offset < 0) "-" else "+");

    const magnitude = @abs(offset);
    try writer.print("{d:0>2}", .{magnitude / std.time.s_per_hour});
    if (shape.hours_only) return;

    if (shape.colons) try writer.writeAll(":");
    try writer.print("{d:0>2}", .{magnitude % std.time.s_per_hour / std.time.s_per_min});

    if (shape.seconds) {
        if (shape.colons) try writer.writeAll(":");
        try writer.print("{d:0>2}", .{magnitude % std.time.s_per_min});
    }
}

/// The same, except that a zero offset is the single letter `Z`.
fn writeIsoOffset(writer: *std.Io.Writer, offset: i32, shape: OffsetShape) !void {
    if (offset == 0) return writer.writeAll("Z");
    return writeOffset(writer, offset, shape);
}

/// Writes a fractional second of `digits` digits after `separator`.
///
/// `trim` is the `.999` form, which drops trailing zeros and then the
/// separator if nothing is left of the fraction at all.
fn writeFraction(
    writer: *std.Io.Writer,
    nanosecond: Nanosecond,
    trim: bool,
    digits: u8,
    separator: u8,
) !void {
    if (trim and (digits == 0 or nanosecond == 0)) return;

    var buffer: [10]u8 = undefined;
    buffer[0] = separator;
    _ = std.fmt.printInt(buffer[1..], nanosecond, 10, .lower, .{ .width = 9, .fill = '0' });

    var end: usize = 1 + digits;
    if (trim) {
        while (end > 1 and buffer[end - 1] == '0') end -= 1;
        if (end == 1) return;
    }

    try writer.writeAll(buffer[0..end]);
}

/// What a layout can fail to read.
///
/// One error, as Go has one: its `ParseError` carries the layout and the
/// text back for a message, which a caller here can rebuild from what it
/// passed in.
pub const ParseError = error{ParseError};

/// Reads `text` under `layout_string`.
///
/// Every literal in the layout has to be there exactly, and the whole of
/// `text` has to be used, which is what Go's `time.Parse` requires too.
/// Anything the layout does not mention keeps its zero value, so a layout
/// naming only a time gives the first of January in year zero -- again as
/// Go does, which is why `time.Parse` of a bare clock is not a date
/// anybody wants.
///
/// The result carries no designation even when the layout had `MST`: the
/// name is read and checked to be a name, and then dropped, because a
/// bare abbreviation does not say what offset it stands for. Go has the
/// same difficulty and resolves it by looking the name up in the running
/// process's location, which this has no equivalent of.
pub fn parse(comptime layout_string: []const u8, text: []const u8) ParseError!DateTime {
    const chunks = comptime tokenize(layout_string);

    var value: DateTime = .{ .year = 0, .month = .Jan, .day = 1 };
    var rest = text;

    var pm_set = false;
    var am_set = false;
    var year_day: ?u16 = null;
    var month_set = false;
    var day_set = false;

    inline for (chunks, 0..) |chunk, index| {
        // Whether the layout asks for a fractional second immediately
        // after this chunk. The seconds arm needs to know, because Go
        // reads an unasked-for fraction there and must not when the
        // layout was going to read it anyway.
        const fraction_next = comptime next: {
            if (index + 1 >= chunks.len) break :next false;
            break :next switch (chunks[index + 1]) {
                .std => |t| t.which == .frac_zero or t.which == .frac_nine,
                .literal => false,
            };
        };

        switch (chunk) {
            .literal => |want| {
                if (rest.len < want.len) return error.ParseError;
                if (!std.mem.eql(u8, rest[0..want.len], want)) return error.ParseError;
                rest = rest[want.len..];
            },
            .std => |token| switch (token.which) {
                .long_month, .month => {
                    const map = if (token.which == .long_month) Month.long_map else Month.short_map;
                    value.month = found: {
                        // Longest first, so "January" is not read as "Jan"
                        // with "uary" left over.
                        var length = @min(rest.len, if (token.which == .long_month) 9 else 3);
                        while (length >= 3) : (length -= 1) {
                            if (map.get(rest[0..length])) |m| {
                                rest = rest[length..];
                                break :found m;
                            }
                        }
                        return error.ParseError;
                    };
                    month_set = true;
                },

                .num_month, .zero_month => {
                    const number = try getnum(&rest, token.which == .zero_month);
                    if (number < 1 or number > 12) return error.ParseError;
                    value.month = @enumFromInt(number);
                    month_set = true;
                },

                .long_weekday, .weekday => {
                    // Read and discarded, as Go does: a weekday adds nothing
                    // a date does not already say, and Go does not check it.
                    const result = if (token.which == .long_weekday)
                        DayOfWeek.parseLongStr(rest) catch return error.ParseError
                    else
                        DayOfWeek.parseShortStr(rest) catch return error.ParseError;
                    rest = rest[result.str.len..];
                },

                .day, .zero_day, .under_day => {
                    if (token.which == .under_day and rest.len > 0 and rest[0] == ' ') {
                        rest = rest[1..];
                    }
                    const number = try getnum(&rest, token.which == .zero_day);
                    if (number < 1 or number > 31) return error.ParseError;
                    value.day = @intCast(number);
                    day_set = true;
                },

                .under_year_day, .zero_year_day => {
                    if (token.which == .under_year_day) {
                        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                    }
                    const number = try getnum3(&rest, token.which == .zero_year_day);
                    if (number < 1 or number > 366) return error.ParseError;
                    year_day = @intCast(number);
                },

                .hour => {
                    const number = try getnum(&rest, false);
                    if (number > 23) return error.ParseError;
                    value.hour = @intCast(number);
                },
                .hour12, .zero_hour12 => {
                    const number = try getnum(&rest, token.which == .zero_hour12);
                    if (number < 1 or number > 12) return error.ParseError;
                    value.hour = @intCast(number);
                },
                .minute, .zero_minute => {
                    const number = try getnum(&rest, token.which == .zero_minute);
                    if (number > 59) return error.ParseError;
                    value.minute = @intCast(number);
                },
                .second, .zero_second => {
                    const number = try getnum(&rest, token.which == .zero_second);
                    if (number > 59) return error.ParseError;
                    value.second = @intCast(number);

                    // A second may be followed by a fraction the layout did
                    // not ask for, which Go reads rather than refuses -- but
                    // only when the layout was not about to read one itself.
                    if (!fraction_next and rest.len >= 2 and
                        (rest[0] == '.' or rest[0] == ',') and std.ascii.isDigit(rest[1]))
                    {
                        var length: usize = 1;
                        while (length < rest.len and std.ascii.isDigit(rest[length])) length += 1;
                        value.nanosecond = try scaleFraction(rest[1..length]);
                        rest = rest[length..];
                    }
                },

                .long_year => {
                    // Four digits, and no sign: Go writes a year before
                    // the common era with a leading minus and then cannot
                    // read it back, because this wants a digit first.
                    // Following that rather than being quietly more
                    // capable, so that a layout means one thing.
                    if (rest.len < 4) return error.ParseError;
                    for (rest[0..4]) |char| if (!std.ascii.isDigit(char)) return error.ParseError;
                    value.year = @intCast(read.digits(rest[0..4]));
                    rest = rest[4..];
                },
                .year => {
                    const number = try getnum(&rest, true);
                    // Go's window, which is not the same as the one `YY` uses
                    // on the moment side: 69 and up are the twentieth century.
                    value.year = if (number >= 69) 1900 + @as(Year, number) else 2000 + @as(Year, number);
                },

                .pm => {
                    if (rest.len < 2) return error.ParseError;
                    if (std.mem.eql(u8, rest[0..2], "PM")) pm_set = true else if (std.mem.eql(u8, rest[0..2], "AM")) am_set = true else return error.ParseError;
                    rest = rest[2..];
                },
                .lower_pm => {
                    if (rest.len < 2) return error.ParseError;
                    if (std.mem.eql(u8, rest[0..2], "pm")) pm_set = true else if (std.mem.eql(u8, rest[0..2], "am")) am_set = true else return error.ParseError;
                    rest = rest[2..];
                },

                .tz => {
                    // Go looks for the literal "UTC" before anything
                    // else, which is what lets `MSTMST` read `UTCUTC` as
                    // two names where the letter counting in
                    // `zoneNameLength` sees one run of six and refuses.
                    if (rest.len >= 3 and std.mem.eql(u8, rest[0..3], "UTC")) {
                        rest = rest[3..];
                    } else {
                        rest = rest[try zoneNameLength(rest)..];
                    }
                },

                .num_tz => value.offset = try readOffset(&rest, .{ .colons = false, .seconds = false }),
                .num_seconds_tz => value.offset = try readOffset(&rest, .{ .colons = false, .seconds = true }),
                .num_short_tz => value.offset = try readOffset(&rest, .{ .colons = false, .seconds = false, .hours_only = true }),
                .num_colon_tz => value.offset = try readOffset(&rest, .{ .colons = true, .seconds = false }),
                .num_colon_seconds_tz => value.offset = try readOffset(&rest, .{ .colons = true, .seconds = true }),

                .iso_tz, .iso_seconds_tz, .iso_short_tz, .iso_colon_tz, .iso_colon_seconds_tz => {
                    if (rest.len > 0 and rest[0] == 'Z') {
                        rest = rest[1..];
                        value.offset = 0;
                    } else value.offset = try readOffset(&rest, switch (token.which) {
                        .iso_tz => .{ .colons = false, .seconds = false },
                        .iso_seconds_tz => .{ .colons = false, .seconds = true },
                        .iso_short_tz => .{ .colons = false, .seconds = false, .hours_only = true },
                        .iso_colon_tz => .{ .colons = true, .seconds = false },
                        .iso_colon_seconds_tz => .{ .colons = true, .seconds = true },
                        else => unreachable,
                    });
                },

                .frac_zero => {
                    if (rest.len < 1 + token.digits) return error.ParseError;
                    if (rest[0] != token.separator) return error.ParseError;
                    for (rest[1 .. 1 + token.digits]) |char| {
                        if (!std.ascii.isDigit(char)) return error.ParseError;
                    }
                    value.nanosecond = try scaleFraction(rest[1 .. 1 + token.digits]);
                    rest = rest[1 + token.digits ..];
                },
                .frac_nine => {
                    // Optional, and as many digits as are there: this is the
                    // form that writes nothing when the fraction is zero, so
                    // reading has to accept nothing too.
                    if (rest.len >= 2 and rest[0] == token.separator and std.ascii.isDigit(rest[1])) {
                        var length: usize = 1;
                        while (length < rest.len and length <= token.digits and
                            std.ascii.isDigit(rest[length])) length += 1;
                        value.nanosecond = try scaleFraction(rest[1..length]);
                        rest = rest[length..];
                    }
                },
            },
        }
    }

    if (rest.len != 0) return error.ParseError;

    if (pm_set and value.hour < 12) {
        value.hour += 12;
    } else if (am_set and value.hour == 12) {
        value.hour = 0;
    }

    if (year_day) |doy| {
        // A day of the year names the date by itself, and only when the
        // layout did not name a month or a day another way.
        if (month_set or day_set) return error.ParseError;
        const length: u16 = if (Month.Feb.lastDay(value.year) == 29) 366 else 365;
        if (doy > length) return error.ParseError;

        const date = Date.fromDayOfYear(value.year, doy);
        value.month = date.month;
        value.day = date.day;
    }

    if (!value.asDate().isRegular()) return error.ParseError;
    value.updateDayOfWeek();

    return value;
}

/// How much of `text` is a zone abbreviation, following Go's
/// `parseTimeZone`.
///
/// A run of capitals is not enough on its own: three letters are always a
/// name, four or five only when the last is a `T`, and six are never one.
/// Without that, `MSTMST` would read as a single six letter zone rather
/// than as two.
fn zoneNameLength(text: []const u8) ParseError!usize {
    if (text.len < 3) return error.ParseError;

    // The only two zones with a lower case letter in them.
    if (text.len >= 4 and (std.mem.eql(u8, text[0..4], "ChST") or
        std.mem.eql(u8, text[0..4], "MeST"))) return 4;

    // GMT may carry an hour offset, which is a name of a sort.
    if (std.mem.eql(u8, text[0..3], "GMT")) return 3 + signedOffsetLength(text[3..]);

    // A zone with no name of its own may be written as a signed count of
    // hours. Not as `+0545`, though: the digits are read as one number
    // and bounded to a day, so anything longer is not a zone at all. That
    // is why text this library wrote with `MST` and no designation does
    // not read back under `MST` -- Go has the same gap and this follows
    // it rather than quietly being more useful.
    if (text[0] == '+' or text[0] == '-') {
        const length = signedOffsetLength(text);
        return if (length > 0) length else error.ParseError;
    }

    var capitals: usize = 0;
    while (capitals < 6 and capitals < text.len and
        text[capitals] >= 'A' and text[capitals] <= 'Z') capitals += 1;

    return switch (capitals) {
        3 => 3,
        // Four or five letters have to end in the T of "Time", with one
        // exception Go carries for Indonesia.
        4 => if (text[3] == 'T' or std.mem.eql(u8, text[0..4], "WITA")) 4 else error.ParseError,
        5 => if (text[4] == 'T') 5 else error.ParseError,
        else => error.ParseError,
    };
}

/// How much of `text` is a signed count of hours, or zero when it is not
/// one. Go's `parseSignedOffset`.
fn signedOffsetLength(text: []const u8) usize {
    if (text.len < 2) return 0;
    if (text[0] != '+' and text[0] != '-') return 0;

    var digits: usize = 0;
    var number: i64 = 0;
    while (1 + digits < text.len and std.ascii.isDigit(text[1 + digits])) : (digits += 1) {
        number = number * 10 + (text[1 + digits] - '0');
        if (number > 1000) return 0;
    }
    if (digits == 0) return 0;
    if (text[0] == '-') number = -number;
    if (number < -23 or number > 23) return 0;

    return 1 + digits;
}

test signedOffsetLength {
    try std.testing.expectEqual(@as(usize, 3), signedOffsetLength("+05"));
    try std.testing.expectEqual(@as(usize, 3), signedOffsetLength("-05"));
    try std.testing.expectEqual(@as(usize, 2), signedOffsetLength("+5"));

    // The whole run of digits is one number, so this is 545 hours rather
    // than five and three quarters, and is not a zone.
    try std.testing.expectEqual(@as(usize, 0), signedOffsetLength("+0545"));
    try std.testing.expectEqual(@as(usize, 0), signedOffsetLength("+24"));
    try std.testing.expectEqual(@as(usize, 0), signedOffsetLength("abc"));
}

test zoneNameLength {
    try std.testing.expectEqual(@as(usize, 3), try zoneNameLength("UTC"));
    try std.testing.expectEqual(@as(usize, 3), try zoneNameLength("CDT"));

    // Six capitals are not a name, which is Go's rule and is why
    // `UTCUTC` needs the literal check in the `MST` arm to read as two.
    try std.testing.expectError(error.ParseError, zoneNameLength("UTCUTC"));

    // A zone with no name may be a signed count of hours, but only a
    // count of hours.
    try std.testing.expectEqual(@as(usize, 3), try zoneNameLength("+05"));
    try std.testing.expectError(error.ParseError, zoneNameLength("+0545"));

    // GMT carries an offset of its own.
    try std.testing.expectEqual(@as(usize, 3), try zoneNameLength("GMT"));
    try std.testing.expectEqual(@as(usize, 5), try zoneNameLength("GMT+8"));

    try std.testing.expectEqual(@as(usize, 4), try zoneNameLength("AEST"));
    try std.testing.expectEqual(@as(usize, 4), try zoneNameLength("WITA"));
    try std.testing.expectEqual(@as(usize, 4), try zoneNameLength("ChST"));
    try std.testing.expectEqual(@as(usize, 5), try zoneNameLength("AWDLT"));

    try std.testing.expectError(error.ParseError, zoneNameLength("AB"));
    try std.testing.expectError(error.ParseError, zoneNameLength("ABCD"));
}

test parse {
    const value = try parse(layout.rfc3339, "2024-03-15T14:30:05-05:00");
    try std.testing.expectEqual(@as(Year, 2024), value.year);
    try std.testing.expectEqual(Month.Mar, value.month);
    try std.testing.expectEqual(@as(u6, 15), value.day);
    try std.testing.expectEqual(@as(u5, 14), value.hour);
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), value.offset);

    // The weekday is worked out rather than taken from the text, which is
    // why a layout naming one does not have to agree with the date.
    try std.testing.expectEqual(DayOfWeek.Fri, value.weekday);

    // The whole of the input has to be used, and every literal has to be
    // there exactly.
    try std.testing.expectError(error.ParseError, parse(layout.date_only, "2024-03-15 and more"));
    try std.testing.expectError(error.ParseError, parse(layout.date_only, "2024/03/15"));
    try std.testing.expectError(error.ParseError, parse(layout.date_only, "2024-02-30"));

    // An unpadded piece takes a second digit when one is there, so `1`
    // reads December as well as January.
    try std.testing.expectEqual(Month.Dec, (try parse("1/2", "12/3")).month);
    try std.testing.expectEqual(Month.Jan, (try parse("1/2", "1/3")).month);

    // A layout mentions what it mentions; the rest keeps its zero value,
    // which for a bare clock is the first of January in year zero.
    const clock = try parse(layout.time_only, "14:30:05");
    try std.testing.expectEqual(@as(Year, 0), clock.year);
    try std.testing.expectEqual(Month.Jan, clock.month);
}

/// Reads one or two digits, or exactly two when `fixed`.
///
/// This is Go's `getnum`: unpadded fields take a second digit when one is
/// there, so `1` reads both the `1` of January and the `12` of December.
fn getnum(rest: *[]const u8, fixed: bool) ParseError!u16 {
    const text = rest.*;
    if (text.len < 1 or !std.ascii.isDigit(text[0])) return error.ParseError;

    if (text.len < 2 or !std.ascii.isDigit(text[1])) {
        if (fixed) return error.ParseError;
        rest.* = text[1..];
        return text[0] - '0';
    }

    rest.* = text[2..];
    return @as(u16, text[0] - '0') * 10 + (text[1] - '0');
}

test getnum {
    var one: []const u8 = "1x";
    try std.testing.expectEqual(@as(u16, 1), try getnum(&one, false));
    try std.testing.expectEqualStrings("x", one);

    // Greedy to two digits, which is why an unpadded month reads December.
    var two: []const u8 = "12x";
    try std.testing.expectEqual(@as(u16, 12), try getnum(&two, false));

    // Fixed wants both.
    var short: []const u8 = "1x";
    try std.testing.expectError(error.ParseError, getnum(&short, true));
}

/// Reads one to three digits, or exactly three when `fixed`. Go's
/// `getnum3`, used only by the day of the year.
fn getnum3(rest: *[]const u8, fixed: bool) ParseError!u16 {
    const text = rest.*;
    var length: usize = 0;
    var number: u16 = 0;
    while (length < 3 and length < text.len and std.ascii.isDigit(text[length])) : (length += 1) {
        number = number * 10 + (text[length] - '0');
    }
    if (length == 0 or (fixed and length != 3)) return error.ParseError;
    rest.* = text[length..];
    return number;
}

/// Turns a run of digits into nanoseconds, so "5" is half a second.
fn scaleFraction(digits: []const u8) ParseError!Nanosecond {
    if (digits.len == 0 or digits.len > 9) return error.ParseError;

    var scaled: Nanosecond = 0;
    for (0..9) |i| {
        scaled = scaled * 10 + (if (i < digits.len) digits[i] - '0' else 0);
    }
    return scaled;
}

test scaleFraction {
    try std.testing.expectEqual(@as(Nanosecond, 500000000), try scaleFraction("5"));
    try std.testing.expectEqual(@as(Nanosecond, 123000000), try scaleFraction("123"));
    try std.testing.expectEqual(@as(Nanosecond, 123456789), try scaleFraction("123456789"));
}

/// Reads an offset written the way `shape` says, and returns it in seconds
/// east of UTC.
fn readOffset(rest: *[]const u8, shape: OffsetShape) ParseError!i32 {
    var text = rest.*;
    if (text.len < 1) return error.ParseError;

    const sign: i32 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.ParseError,
    };
    text = text[1..];

    const hours = try twoDigits(&text);
    if (shape.hours_only) {
        rest.* = text;
        return sign * hours * std.time.s_per_hour;
    }

    if (shape.colons) {
        if (text.len < 1 or text[0] != ':') return error.ParseError;
        text = text[1..];
    }
    const minutes = try twoDigits(&text);

    var seconds: i32 = 0;
    if (shape.seconds) {
        if (shape.colons) {
            if (text.len < 1 or text[0] != ':') return error.ParseError;
            text = text[1..];
        }
        seconds = try twoDigits(&text);
    }

    rest.* = text;
    return sign * (hours * std.time.s_per_hour + minutes * std.time.s_per_min + seconds);
}

/// Reads exactly two digits, which every part of an offset is written as.
fn twoDigits(rest: *[]const u8) ParseError!i32 {
    const text = rest.*;
    if (text.len < 2) return error.ParseError;
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1])) return error.ParseError;
    rest.* = text[2..];
    return @as(i32, text[0] - '0') * 10 + (text[1] - '0');
}
