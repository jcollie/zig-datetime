// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A date and a time of day, together with the offset from UTC that the
//! reading is against.
//!
//! `DateTime` is a wall clock: the fields say what a clock somewhere read,
//! and `offset` says how far that somewhere is from UTC. It is not an
//! instant on its own; see `Instant` for that, and `TimeZone` for the
//! rules that turn one into the other.
//!
//! `format` and `parse` here are the general-purpose text routes, driven
//! by a comptime format string of the sequences in `formatsequence.FormatTag`
//! ("YYYY-MM-DD HH:mm:ss"). Because the string is comptime, the tokenizer
//! runs during compilation and what is left at runtime is a straight line
//! of writes or reads with no interpretation of the format. That is also
//! why the standard syntaxes live elsewhere: `iso8601` and `rfc822` accept
//! inputs whose shape is only known once the input has been read, which a
//! comptime format string cannot express.

const DateTime = @This();

const std = @import("std");

const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Date = @import("Date.zig");
const Instant = @import("Instant.zig");
const formatsequence = @import("formatsequence.zig");
const FormatTag = formatsequence.FormatTag;
const writeTwelveHour = @import("hour.zig").writeTwelveHour;
const ordinal = @import("ordinal.zig");
const Designation = @import("designation.zig").Designation;
const locale = @import("locale.zig");
const print = @import("print.zig");
const read = @import("read.zig");

nanosecond: Nanosecond = 0, // [0..999999999]
second: Second = 0, // [0..61]
minute: Minute = 0, // [0..59]
hour: Hour = 0, // [0-23]
day: Day = 1, // [0-31]
month: Month = .Jan, // [1-12]
year: Year = 1970,
weekday: DayOfWeek = .Thu,
/// Offset of this local wall-clock time from UTC, in seconds east of UTC:
/// -18000 for -05:00. Zero means the fields are already UTC. Seconds
/// rather than minutes because historical local mean time offsets are not
/// whole minutes: America/Chicago's is -5:50:36.
offset: i32 = 0,
/// What the zone this reading was made in calls itself at this instant,
/// such as "CDT", or empty when it is not known.
///
/// Only `TimeZone.atInstant` and `atTimestamp` set it, because only a
/// zone knows it: an offset does not name one, and neither a parsed date
/// nor `Instant.asDateTime` has a zone to ask. Read it with
/// `designation.slice()` or compare it with `designation.eql`.
///
/// No format sequence writes it. `z` prints a constant, which is what
/// moment.js does and is documented on the sequence itself; this is where
/// the real answer lives.
designation: Designation = .{},

/// The Unix epoch, 1970-01-01T00:00:00Z. Used as the default for the date
/// fields a format string does not mention; see `parse`.
pub const unix_epoch: DateTime = .{
    .nanosecond = 0,
    .second = 0,
    .minute = 0,
    .hour = 0,
    .day = 1,
    .month = .Jan,
    .year = 1970,
    .weekday = .Thu,
    .offset = 0,
};

/// Returns the current time in UTC, read from the `.real` clock of `io`.
pub fn utc(io: std.Io) DateTime {
    return Instant.utc(io).asDateTime();
}

test utc {
    const datetime = utc(std.testing.io);

    // Nothing about the reading is fixed, but it is a real clock read as
    // UTC, so it is past the epoch and carries no offset.
    try std.testing.expect(datetime.year >= 1970);
    try std.testing.expectEqual(@as(i32, 0), datetime.offset);
}

/// Writes the name at `index` in `names` to `writer`.
fn printLongName(writer: anytype, index: u16, names: []const []const u8) !void {
    try writer.writeAll(names[index]);
}

test printLongName {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try printLongName(&writer, 1, &.{ "January", "February" });
    try std.testing.expectEqualStrings("February", writer.buffered());
}

/// Writes `year` zero padded to four digits, with a leading minus for a
/// year before the common era.
///
/// The sign is written separately and the magnitude padded, because a
/// signed value handed straight to the formatter puts its sign inside the
/// padding: -44 comes out as `0-44` rather than `-0044`, and a positive
/// year picks up a `+` it should not have.
fn printYear(writer: *std.Io.Writer, year: Year) !void {
    if (year < 0) try writer.writeAll("-");
    try writer.print("{d:0>4}", .{@abs(year)});
}

test printYear {
    var buf: [16]u8 = undefined;

    var ordinary = std.Io.Writer.fixed(&buf);
    try printYear(&ordinary, 2024);
    try std.testing.expectEqualStrings("2024", ordinary.buffered());

    var early = std.Io.Writer.fixed(&buf);
    try printYear(&early, 44);
    try std.testing.expectEqualStrings("0044", early.buffered());

    var bce = std.Io.Writer.fixed(&buf);
    try printYear(&bce, -44);
    try std.testing.expectEqualStrings("-0044", bce.buffered());
}

/// Writes `year` zero padded to `width` digits, with a leading minus for
/// a year before the common era. `printYear` is this at four digits.
fn printPaddedYear(writer: *std.Io.Writer, year: Year, comptime width: usize) !void {
    if (year < 0) try writer.writeAll("-");
    try writer.print("{d:0>[1]}", .{ @abs(year), width });
}

test printPaddedYear {
    var buf: [16]u8 = undefined;

    var five = std.Io.Writer.fixed(&buf);
    try printPaddedYear(&five, 2024, 5);
    try std.testing.expectEqualStrings("02024", five.buffered());
}

/// Wraps `val` into the range `[1, at]`, mapping a remainder of 0 to `at`
/// (e.g. hour 0 becomes 12 on a 12-hour clock).
fn wrap(val: anytype, at: @TypeOf(val)) @TypeOf(val) {
    const tmp = val % at;
    return if (tmp == 0) at else tmp;
}

test wrap {
    // On a 12-hour clock the hours run 12, 1, 2 ... 11, so the hour that
    // would divide exactly takes the top of the range instead of zero.
    try std.testing.expectEqual(@as(u8, 12), wrap(@as(u8, 0), 12));
    try std.testing.expectEqual(@as(u8, 1), wrap(@as(u8, 1), 12));
    try std.testing.expectEqual(@as(u8, 11), wrap(@as(u8, 11), 12));
    try std.testing.expectEqual(@as(u8, 12), wrap(@as(u8, 12), 12));
    try std.testing.expectEqual(@as(u8, 1), wrap(@as(u8, 13), 12));
}

/// Recomputes the `weekday` field from the current `year`, `month`, and `day`.
pub fn updateDayOfWeek(self: *DateTime) void {
    const date: Date = .{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    };
    self.weekday = date.dayOfWeek();
}

test updateDayOfWeek {
    // The weekday is a stored field, so a date assembled by hand carries
    // whatever was put there until this puts it right.
    var datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15 };
    try std.testing.expectEqual(DayOfWeek.Thu, datetime.weekday);

    datetime.updateDayOfWeek();
    try std.testing.expectEqual(DayOfWeek.Fri, datetime.weekday);
}

/// Writes this date/time to `writer` according to `fmt`, a comptime format
/// string made of `FormatTag` sequences (e.g. "YYYY-MM-DDTHH:mm:ss.SSS").
/// The literal characters `,`, ` `, `:`, `-`, `.`, `T`, and `W` are copied
/// through unchanged; any other character that is not part of a format
/// sequence is a compile error. Flushes `writer` before returning.
pub fn format(self: DateTime, comptime fmt: []const u8, writer: *std.Io.Writer) !void {
    return self.formatWith(fmt, locale.en, writer);
}

/// Writes this `DateTime` to `writer` according to the comptime `fmt`,
/// with the month names, day names, meridiem, ordinals and `L` sequences
/// `in` gives them. See `format` for the sequences themselves and
/// `locale.Locale` for what a locale decides.
///
/// The format string stays comptime, because it decides which code runs.
/// The locale does not, because it only decides which bytes come out, so
/// one can be chosen at run time from a header or a configuration file.
///
/// ```zig
/// const dt: DateTime = .{ .year = 2024, .month = .Mar, .day = 5 };
/// try dt.formatWith("dddd, D MMMM YYYY", locale.byName(tag) orelse .en, writer);
/// ```
pub fn formatWith(
    self: DateTime,
    comptime fmt: []const u8,
    in: locale.Locale,
    writer: *std.Io.Writer,
) !void {
    if (fmt.len == 0) @compileError("DateTime: format string can't be empty");

    @setEvalBranchQuota(2000000);
    const tokens = comptime tokensOf(fmt);

    // Whether a month name in this string is the declined one, which is
    // a question about the whole string and so is settled once.
    const context = comptime monthContext(tokens);
    const declined = in.months_decline.declines(context);

    inline for (tokens) |token| {
        switch (token) {
            .tag => |tag| try self.writeTag(tag, in, declined, writer, 0),
            .literal => |text| try writer.writeAll(text),
        }
    }

    try writer.flush();
}

/// Which arrangements of day and month name a format string holds.
///
/// A language that declines its month names picks between the two forms
/// by looking at the whole format string, not at what is around the
/// sequence: moment asks its locale `months(m, format)` once, with the
/// format string entire. So this is a property of the string, worked out
/// once, and `locale.DeclineShapes` says which of the arrangements a
/// given language cares about.
///
/// "Next to" means with nothing but spaces between, or a full stop and
/// spaces, which is what moment's own patterns look for.
fn monthContext(tokens: []const FormatTag.Tokenizer.Token) locale.DeclineShapes {
    var found: locale.DeclineShapes = .{};

    // What has gone by since the last sequence: nothing at all, spaces,
    // a full stop and spaces, or something that ends the run.
    const Between = enum { nothing, spaces, stop, other };

    var previous: ?FormatTag = null;
    var between: Between = .other;

    for (tokens) |token| {
        switch (token) {
            .tag => |tag| {
                const day: ?enum { plain, ordinal } = switch (tag) {
                    .D, .DD => .plain,
                    .Do => .ordinal,
                    else => null,
                };
                const month = switch (tag) {
                    .MMM, .MMMM => true,
                    else => false,
                };

                if (previous) |before| {
                    const separated = between == .spaces or between == .stop;
                    if (month and separated) switch (before) {
                        .D, .DD => {
                            if (between == .spaces) found.day_then_month = true;
                            if (between == .stop) found.day_stop_month = true;
                        },
                        .Do => found.ordinal_then_month = true,
                        else => {},
                    };
                    if (day != null and separated and (before == .MMM or before == .MMMM)) {
                        switch (day.?) {
                            .plain => found.month_then_day = true,
                            .ordinal => found.month_then_ordinal = true,
                        }
                    }
                }

                previous = if (day != null or month) tag else null;
                between = .nothing;
            },
            // Spaces keep the two next to each other, and so does a full
            // stop, which is what Czech's pattern allows. Bracketed text
            // arrives here as its contents and ends the run, which is
            // what moment's patterns do with anything else.
            .literal => |text| {
                var seen_stop = between == .stop;
                var seen_other = false;
                for (text) |char| {
                    if (std.ascii.isWhitespace(char)) continue;
                    if (char == '.' and !seen_stop) seen_stop = true else seen_other = true;
                }
                between = if (seen_other) .other else if (seen_stop) .stop else .spaces;
                if (between == .other) previous = null;
            },
        }
    }

    return found;
}

test monthContext {
    // A day and then a month name, which is what most languages look for.
    {
        const found = comptime monthContext(tokensOf("D MMMM YYYY"));
        try std.testing.expect(found.day_then_month);
        try std.testing.expect(!found.month_then_day);
        try std.testing.expect(!found.ordinal_then_month);
    }

    // An ordinal day is its own arrangement, because Polish counts one
    // and not the other.
    {
        const found = comptime monthContext(tokensOf("Do MMMM"));
        try std.testing.expect(found.ordinal_then_month);
        try std.testing.expect(!found.day_then_month);
    }

    // The other way round, which is what Konkani looks for.
    {
        const found = comptime monthContext(tokensOf("dddd, MMMM Do, YYYY"));
        try std.testing.expect(found.month_then_ordinal);
        try std.testing.expect(!found.day_then_month);
    }

    // A full stop between is its own arrangement too, which is what
    // Czech allows.
    {
        const found = comptime monthContext(tokensOf("D. MMMM YYYY"));
        try std.testing.expect(found.day_stop_month);
        try std.testing.expect(!found.day_then_month);
    }

    // Anything else between them and they are not next to each other.
    {
        const found = comptime monthContext(tokensOf("D, MMMM"));
        try std.testing.expect(!found.any());
    }
    {
        const found = comptime monthContext(tokensOf("D YYYY MMMM"));
        try std.testing.expect(!found.any());
    }

    // And a string with no month name in it asks for nothing.
    {
        const found = comptime monthContext(tokensOf("YYYY-MM-DD"));
        try std.testing.expect(!found.any());
    }
}

/// Splits `fmt` into tokens at compile time.
fn tokensOf(comptime fmt: []const u8) []const FormatTag.Tokenizer.Token {
    comptime {
        @setEvalBranchQuota(2000000);
        var count = 0;
        {
            var it: FormatTag.Tokenizer = .init(fmt);
            while (it.next()) |_| count += 1;
        }
        var buf: [count]FormatTag.Tokenizer.Token = undefined;
        var index = 0;
        {
            var it: FormatTag.Tokenizer = .init(fmt);
            while (it.next()) |token| {
                buf[index] = token;
                index += 1;
            }
        }
        const final = buf;
        return &final;
    }
}

/// Writes what one localized sequence stands for.
///
/// The string comes from the locale, so this is the one place a format
/// string is tokenized at run time. `abbreviated` takes a letter off the
/// padded sequences, which is how moment derives `l` from `L`.
///
/// `depth` bounds the nesting, as moment's own expansion is bounded at
/// five passes; a locale whose `L` names another localized sequence is
/// not a thing that exists, and this keeps one from looping if it did.
fn formatExpansion(
    self: DateTime,
    stands_for: locale.LongDateFormat.Expansion,
    in: locale.Locale,
    writer: *std.Io.Writer,
    depth: u8,
) std.Io.Writer.Error!void {
    // The locale has already said which form of the month name its own
    // strings use, so nothing here has to work it out. See
    // `locale.LongDateFormat.months_declined`.
    const declined = stands_for.months_declined orelse false;

    var it: FormatTag.Tokenizer = .init(stands_for.fmt);
    while (it.next()) |token| {
        switch (token) {
            .tag => |found| {
                const tag = if (stands_for.abbreviate) found.abbreviate() else found;
                // `inline else` is what makes the tag comptime again, so
                // that the same `writeTag` serves both this and the
                // unrolled walk in `formatWith`.
                switch (tag) {
                    inline else => |known| try self.writeTag(known, in, declined, writer, depth),
                }
            },
            .literal => |text| try writer.writeAll(text),
        }
    }
}

/// Writes the one value `tag` names.
///
/// `tag` is comptime so that a format string turns into straight-line
/// code, which is what it was before a locale came into it; the runtime
/// walk in `formatExpansion` gets there through `inline else`.
fn writeTag(
    self: DateTime,
    comptime tag: FormatTag,
    in: locale.Locale,
    in_format: bool,
    writer: *std.Io.Writer,
    depth: u8,
) std.Io.Writer.Error!void {
    {
        {
            {
                const format_tag = tag;
                switch (format_tag) {
                    .M => try writer.print("{}", .{@intFromEnum(self.month)}),
                    .Mo => try in.writeOrdinal(writer, @intFromEnum(self.month), .Mo),
                    .MM => try writer.print("{:0>2}", .{@intFromEnum(self.month)}),
                    .MMM, .MMMM => try writer.writeAll(in.monthName(self.month, format_tag, in_format)),

                    .Q => try writer.print("{}", .{self.month.quarter()}),
                    .Qo => try in.writeOrdinal(writer, self.month.quarter(), .Qo),

                    .D => try writer.print("{}", .{self.day}),
                    .Do => try in.writeOrdinal(writer, self.day, .Do),
                    .DD => try writer.print("{:0>2}", .{self.day}),

                    .DDD => try writer.print("{}", .{self.dayOfThisYear()}),
                    .DDDo => try in.writeOrdinal(writer, self.dayOfThisYear(), .DDDo),
                    .DDDD => try writer.print("{:0>3}", .{self.dayOfThisYear()}),

                    .d => try writer.print("{}", .{self.weekday.weekdayNumber()}),
                    .do => try in.writeOrdinal(writer, self.weekday.weekdayNumber(), .do),
                    .dd, .ddd, .dddd => try writer.writeAll(in.weekdayName(self.weekday, format_tag)),

                    .e => try writer.print("{}", .{in.weekdayNumber(self.weekday)}),
                    .E => try writer.print("{}", .{self.weekday.isoWeekdayNumber()}),

                    // Two week rules, which disagree at the turn of a year.
                    // `w` is the English-language one that moment's default
                    // locale uses; `W` is ISO 8601. Each pairs with its own
                    // week-numbering year, which is why `gg` and `GG` exist
                    // and why neither pairs with `YY`.
                    .w => try writer.print("{}", .{self.weekIn(in).week}),
                    .wo => try in.writeOrdinal(writer, self.weekIn(in).week, .wo),
                    .ww => try writer.print("{:0>2}", .{self.weekIn(in).week}),
                    .W => try writer.print("{}", .{self.isoWeek().week}),
                    .Wo => try in.writeOrdinal(writer, self.isoWeek().week, .Wo),
                    .WW => try writer.print("{:0>2}", .{self.isoWeek().week}),
                    .gg => try writer.print("{d:0>2}", .{@as(u7, @intCast(@mod(self.weekIn(in).year, 100)))}),
                    .gggg => try printYear(writer, self.weekIn(in).year),
                    .ggggg => try printPaddedYear(writer, self.weekIn(in).year, 5),
                    .GG => try writer.print("{d:0>2}", .{@as(u7, @intCast(@mod(self.isoWeek().year, 100)))}),
                    .GGGG => try printYear(writer, self.isoWeek().year),
                    .GGGGG => try printPaddedYear(writer, self.isoWeek().year, 5),

                    // @mod rather than @rem, so a year either side of the
                    // epoch lands in 0-99 rather than going negative, and the
                    // cast drops the sign the signed type would print. This
                    // is the inverse of the parse side, which reads two
                    // digits as 2000-2099.
                    .YY => try writer.print("{d:0>2}", .{@as(u7, @intCast(@mod(self.year, 100)))}),
                    .Y, .y, .yy, .yyy, .yyyy => try writer.print("{d}", .{self.year}),
                    .yo => try in.writeOrdinal(writer, @as(u32, @intCast(@max(self.year, 0))), .yo),
                    .YYYY => try printYear(writer, self.year),
                    .YYYYY => try printPaddedYear(writer, self.year, 5),
                    .YYYYYY => {
                        // Always signed, which is what makes it the expanded
                        // form rather than a wider `YYYY`.
                        try writer.writeAll(if (self.year < 0) "-" else "+");
                        try writer.print("{d:0>6}", .{@abs(self.year)});
                    },

                    // Every spelling but the longest abbreviates, which is
                    // moment.js's arrangement and not an oversight.
                    .N, .NN, .NNN, .NNNNN => try writer.writeAll(if (self.year < 1) "BC" else "AD"),
                    .NNNN => try writer.writeAll(if (self.year < 1) "Before Christ" else "Anno Domini"),

                    .A => try in.writeMeridiem(writer, self.hour, self.minute, .upper),
                    .a => try in.writeMeridiem(writer, self.hour, self.minute, .lower),

                    .H => try writer.print("{}", .{self.hour}),
                    .HH => try writer.print("{:0>2}", .{self.hour}),
                    .h => try writer.print("{}", .{wrap(self.hour, 12)}),
                    .hh => try writer.print("{:0>2}", .{wrap(self.hour, 12)}),
                    .k => try writer.print("{}", .{wrap(self.hour, 24)}),
                    .kk => try writer.print("{:0>2}", .{wrap(self.hour, 24)}),

                    .m => try writer.print("{}", .{self.minute}),
                    .mm => try writer.print("{:0>2}", .{self.minute}),

                    .s => try writer.print("{d}", .{self.second}),
                    .ss => try writer.print("{d:0>2}", .{self.second}),

                    .S,
                    .SS,
                    .SSS,
                    .SSSS,
                    .SSSSS,
                    .SSSSSS,
                    .SSSSSSS,
                    .SSSSSSSS,
                    .SSSSSSSSS,
                    => {
                        try writer.print(
                            std.fmt.comptimePrint("{{d:0>{d}}}", .{@tagName(format_tag).len}),
                            .{
                                format_tag.convertFractionalSeconds(self.nanosecond),
                            },
                        );
                    },

                    // .N => brk: {
                    //     if (self.year < 0) {
                    //         writer.writeAll("BCE");
                    //         break :brk;
                    //     }
                    //     if (self.year > 0) {
                    //         writer.writeAll("CE");
                    //         break :brk;
                    //     }
                    // },
                    // .NN => brk: {
                    //     if (self.year < 0) {
                    //         writer.writeAll("Before Common Era");
                    //         break :brk;
                    //     }
                    //     if (self.year > 0) {
                    //         writer.writeAll("CE");
                    //         break :brk;
                    //     }
                    // },

                    // Constant, which is moment.js's behaviour rather than an
                    // oversight: see the sequences' own documentation.
                    .z => try writer.writeAll("UTC"),
                    .zz => try writer.writeAll("Coordinated Universal Time"),

                    .Z => try print.offset(writer, self.offset, .colon),
                    .ZZ => try print.offset(writer, self.offset, .none),

                    // The hour is unpadded and everything after it is, so
                    // these are not the same as writing the parts separately.
                    .Hmm => try writer.print("{d}{d:0>2}", .{ self.hour, self.minute }),
                    .Hmmss => try writer.print("{d}{d:0>2}{d:0>2}", .{ self.hour, self.minute, self.second }),
                    .hmm => try writer.print("{d}{d:0>2}", .{ wrap(self.hour, 12), self.minute }),
                    .hmmss => try writer.print("{d}{d:0>2}{d:0>2}", .{ wrap(self.hour, 12), self.minute, self.second }),

                    .X => try writer.print("{d}", .{@divFloor(self.toInstant().timestamp, std.time.ns_per_s)}),
                    .x => try writer.print("{d}", .{@divFloor(self.toInstant().timestamp, std.time.ns_per_ms)}),

                    // A whole format string of the locale's own, which is
                    // the one place the tokenizer runs at run time.
                    .LT, .LTS, .L, .LL, .LLL, .LLLL, .l, .ll, .lll, .llll => {
                        if (depth >= 5) return;
                        const stands_for = in.long_date_format.get(format_tag);
                        try self.formatExpansion(stands_for, in, writer, depth + 1);
                    },
                }
            }
        }
    }
}

/// Like `format`, but returns the formatted string as a slice allocated
/// with `alloc`. The caller owns the returned memory.
pub fn formatAlloc(self: DateTime, alloc: std.mem.Allocator, comptime fmt: []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    try self.format(fmt, &buf.writer);
    return try buf.toOwnedSlice();
}

test formatAlloc {
    const datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    const text = try datetime.formatAlloc(std.testing.allocator, "dddd, D MMMM YYYY");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Friday, 15 March 2024", text);
}

/// Like `formatAlloc`, but the returned slice is terminated with `sentinel`,
/// for handing to something that expects a terminator rather than a length.
///
/// The sentinel is part of the return type and not of the length, so the
/// caller frees the whole allocation the same way as for `formatAlloc`.
pub fn formatAllocSentinel(self: DateTime, alloc: std.mem.Allocator, comptime fmt: []const u8, comptime sentinel: u8) ![:sentinel]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    try self.format(fmt, &buf.writer);
    return try buf.toOwnedSliceSentinel(sentinel);
}

test formatAllocSentinel {
    const datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    // The sentinel is for handing the result to C, so it is written past
    // the end rather than counted in the length.
    const text = try datetime.formatAllocSentinel(std.testing.allocator, "YYYY-MM-DD", 0);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("2024-03-15", text);
    try std.testing.expectEqual(@as(u8, 0), text.ptr[text.len]);
}

/// What the week sequences said, before it is turned into a date.
///
/// The two families are kept apart because they default differently. `W`,
/// `GG` and `E` count the ISO way, where a missing week is week 1; `w`,
/// `gg`, `d` and `e` count the English-language way, where a missing week
/// is the reference's own week. moment splits them the same way and for
/// the same reason.
const Week = struct {
    year: ?Year = null,
    week: ?u16 = null,
    weekday: ?DayOfWeek = null,
    local_weekday: ?DayOfWeek = null,
    iso_year: ?Year = null,
    iso_week: ?u16 = null,
    iso_weekday: ?DayOfWeek = null,

    /// Whether anything was said about a week at all.
    fn any(self: Week) bool {
        return self.year != null or self.week != null or self.weekday != null or
            self.local_weekday != null or self.iso_year != null or
            self.iso_week != null or self.iso_weekday != null;
    }

    /// Whether the ISO family was used, which is what picks the rule.
    fn isIso(self: Week) bool {
        return self.iso_year != null or self.iso_week != null or self.iso_weekday != null;
    }
};

/// Turns what the week sequences said into a date, filling in what they
/// did not say from `year` when the format string named one and from
/// `reference` otherwise.
///
/// This is only reached when the format string named neither a month nor a
/// day, because a week is a way of naming a date and there is nothing for
/// it to do once the date is named another way. moment gates it the same
/// way, and treats a weekday alongside a full date as a claim to check
/// rather than a date to build.
fn resolveWeek(self: Week, year: ?Year, reference: Date, in: locale.Locale) ParseError!Date {
    if (self.isIso()) {
        const week_year = self.iso_year orelse year orelse reference.isoWeek().year;
        const week = self.iso_week orelse 1;
        const weekday = self.iso_weekday orelse .Mon;

        if (week < 1 or week > Date.weeksInYear(week_year, .Mon, 4)) return error.ParseError;
        return Date.fromWeek(week_year, week, weekday, .Mon, 4);
    }

    // The other family counts by the locale's rule, which is what makes
    // `w` and `gg` mean different weeks in different languages. `W` and
    // `GG` above are ISO whatever the locale says.
    const starts_on = in.week.starts_on;
    const first = in.week.january_day_in_first_week;

    const week_year = self.year orelse year orelse
        reference.weekOfYear(starts_on, first).year;

    // A missing week is the reference's own, which is what makes a bare
    // `d` mean "that weekday, this week" rather than "in week one".
    const week = self.week orelse reference.weekOfYear(starts_on, first).week;
    const weekday = self.weekday orelse self.local_weekday orelse starts_on;

    if (week < 1 or week > Date.weeksInYear(week_year, starts_on, first)) return error.ParseError;
    return Date.fromWeek(week_year, week, weekday, starts_on, first);
}

const AmPm = enum {
    none,
    am,
    pm,
};

/// What `parse` can fail with.
///
/// `IllegalToken` is the odd one out: it is raised from the comptime block
/// that tokenizes the format string, so it is reported as a compile error
/// and is never returned to a caller at runtime. See `parseRelativeTo`.
pub const ParseError = error{
    IllegalToken,
    InvalidCharacter,
    Overflow,
    ParseError,
    TooLong,
    TooShort,
    Underflow,
} || Month.ParseError || DayOfWeek.ParseError;

/// The result of a successful parse.
pub const ParseResult = struct {
    /// The prefix of the input that was consumed, so that a caller can
    /// carry on from `value[str.len..]`.
    str: []const u8,
    /// How many bytes inside `str` were stepped over rather than read.
    ///
    /// Only lenient parsing steps over anything, and only where a sequence
    /// or a literal was found further along than it stood. `str.len` minus
    /// this is what moment reports as the length it used.
    skipped: usize = 0,
    value: DateTime,
};

/// How closely the input has to match the format string.
///
/// moment.js takes the same choice as a flag, and the two behave the same
/// way here. The difference is worth having because the two are wanted for
/// different things: reading a field out of a protocol message, where
/// anything unexpected is an error, against reading something a person
/// typed, where it is not.
pub const Mode = enum {
    /// Every sequence takes what it can. A padded sequence such as `MM`
    /// accepts one digit as well as two, `MMM` accepts a full month name
    /// as well as a short one, and text after the date is left for the
    /// caller rather than refused. This is moment's default.
    lenient,
    /// Every sequence takes exactly what it says, and the whole input has
    /// to be used: `MM` wants two digits, `MMM` wants three letters, and
    /// anything left over is an error rather than the caller's.
    strict,
};

/// What to parse against, beyond the format string itself.
pub const Options = struct {
    /// Where the date fields the format string does not mention come from.
    /// See `parseWith` for how they are filled in.
    relative_to: DateTime = .unix_epoch,
    /// How closely the input has to match. See `Mode`.
    mode: Mode = .lenient,
    /// The language the input is written in: which month and day names to
    /// look for, what stands for AM and PM, what decorates an ordinal,
    /// which day the week starts on, and what the `L` sequences stand
    /// for. See `locale.Locale`.
    locale: locale.Locale = locale.en,
};

/// What a sequence failing to read says.
///
/// `NoMatch` means the input is not shaped like this sequence, which is
/// what a lenient scan is allowed to step past and try again after.
/// Anything else means the sequence read something and the something was
/// wrong -- a month of 13, an hour of 25 -- which is an error wherever it
/// is found, and not something to go looking for a second opinion about.
///
/// moment draws the same line, though it draws it elsewhere: its regexes
/// match the shape and its overflow checks run afterwards over what they
/// collected. Keeping the two apart is what stops a scan from stepping
/// over a bad value and matching the next thing that looks plausible.
const MatchError = ParseError || error{NoMatch};

/// What one pass over the tokens is building up, so that a sequence can be
/// tried at more than one place without leaving anything behind when it
/// does not match. Every field is a value, so a snapshot is a copy.
const ParseState = struct {
    datetime: DateTime,
    am_pm: AmPm = .none,
    day_of_week: ?DayOfWeek = null,
    day_of_year: ?u16 = null,
    week: Week = .{},
};

/// Reads whatever `tag` names from the front of `left.*`, advancing it and
/// writing what it found into `state`.
///
/// `left.*` is only advanced when the whole sequence matched, so a caller
/// that means to try again somewhere else can do so without unwinding it.
/// `state` may have been written to either way, which is why the caller
/// snapshots it.
fn matchTag(
    comptime tag: FormatTag,
    left: *[]const u8,
    state: *ParseState,
    options: Options,
) MatchError!void {
    var rest = left.*;

    switch (tag) {
        // Handled by `ParseWalk.tag`, which reads what they stand for
        // rather than reaching here with a sequence that names no value.
        .LT, .LTS, .L, .LL, .LLL, .LLLL, .l, .ll, .lll, .llll => unreachable,

        .YY => {
            const str = read.int(rest, 2);
            if (options.mode == .strict and str.len != 2) return error.NoMatch;

            // moment's window: 69 through 99 are the twentieth
            // century and 00 through 68 are this one, which is
            // the POSIX rule and puts the break at 1969.
            const value_ = @as(Year, @intCast(read.digits(str)));
            state.datetime.year = value_ + (if (value_ > 68) @as(Year, 1900) else 2000);
            rest = rest[str.len..];
        },
        .YYYY, .Y, .y, .yy, .yyy, .yyyy => {
            state.datetime.year = year: {
                const str = read.int(rest, 4);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .YYYY and str.len != 4) return error.NoMatch;
                const digits = @as(Year, @intCast(read.digits(str)));
                rest = rest[str.len..];

                // Two characters against `YYYY` are a two
                // digit year and are windowed like one, which
                // is moment's rule and only reachable
                // leniently, since strict wants four.
                break :year if (tag == .YYYY and str.len == 2)
                    digits + (if (digits > 68) @as(Year, 1900) else 2000)
                else
                    digits;
            };
        },
        .MMMM => {
            // A word that is not a month is a wrong month rather
            // than no month at all, which is what stops a scan
            // stepping over it to find the next thing that looks
            // like one. moment matches any word here and judges it
            // afterwards, to the same effect.
            if (!startsWord(rest)) return error.ParseError;

            state.datetime.month = month: {
                if (options.locale.matchMonth(rest, .MMMM)) |found| {
                    rest = rest[found.len..];
                    break :month found.month;
                }
                // And a short name where a long one was asked
                // for, which moment also takes leniently.
                if (options.mode == .lenient) {
                    if (options.locale.matchMonth(rest, .MMM)) |found| {
                        rest = rest[found.len..];
                        break :month found.month;
                    }
                }
                return error.ParseError;
            };
        },
        .MMM => {
            // A word that is not a month is a wrong month rather
            // than no month at all, which is what stops a scan
            // stepping over it to find the next thing that looks
            // like one. moment matches any word here and judges it
            // afterwards, to the same effect.
            if (!startsWord(rest)) return error.ParseError;

            state.datetime.month = month: {
                // Leniently a full name is taken too, longest
                // first so that "March" is not read as "Mar"
                // with "ch" left over.
                if (options.mode == .lenient) {
                    if (options.locale.matchMonth(rest, .MMMM)) |found| {
                        rest = rest[found.len..];
                        break :month found.month;
                    }
                }
                if (options.locale.matchMonth(rest, .MMM)) |found| {
                    rest = rest[found.len..];
                    break :month found.month;
                }
                return error.ParseError;
            };
        },
        .MM, .M => {
            state.datetime.month = month: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .MM and str.len != 2) return error.NoMatch;
                defer rest = rest[str.len..];
                break :month try Month.parseInt(str);
            };
        },
        .Mo => {
            state.datetime.month = month: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                const month = try Month.parseInt(str);
                rest = rest[str.len..];
                try skipOrdinal(&rest, @intFromEnum(month), .Mo, options);
                break :month month;
            };
        },
        .DD, .D => {
            state.datetime.day = day: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .DD and str.len != 2) return error.NoMatch;
                const day = read.digits(str);
                if (day < 1 or day > 31) return error.ParseError;
                rest = rest[str.len..];
                break :day @intCast(day);
            };
        },
        .Do => {
            state.datetime.day = day: {
                const str = read.int(rest, 3);
                if (str.len == 0) return error.NoMatch;
                const day = read.digits(str);
                if (day < 1 or day > 31) return error.ParseError;
                rest = rest[str.len..];
                try skipOrdinal(&rest, day, .Do, options);
                break :day @intCast(day);
            };
        },
        .DDDD, .DDD, .DDDo => {
            state.day_of_year = doy: {
                const str = read.int(rest, 3);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .DDDD and str.len != 3) return error.NoMatch;
                const doy = read.digits(str);
                if (doy < 1 or doy > 366) return error.ParseError;
                rest = rest[str.len..];
                switch (tag) {
                    .DDDo => try skipOrdinal(&rest, doy, .DDDo, options),
                    .DDDD, .DDD => {},
                    else => unreachable,
                }
                break :doy @intCast(doy);
            };
        },
        .HH, .H, .hh, .h => {
            state.datetime.hour = hour: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                switch (tag) {
                    .HH, .hh => if (options.mode == .strict and str.len != 2) return error.NoMatch,
                    .H, .h => {},
                    else => unreachable,
                }
                const hour = read.digits(str);
                switch (tag) {
                    // 24 is allowed, and means the end of the
                    // day rather than an hour in it. It is
                    // carried into the next day below, once
                    // the minutes and seconds are known to be
                    // zero, which is moment's rule.
                    .HH, .H => if (hour > 24) return error.ParseError,
                    // Strictly this is a twelve hour clock and
                    // has to read like one. Leniently moment
                    // bounds it no more tightly than `H` and
                    // lets the meridiem make what it can of
                    // the result, so "13:30 pm" is 13:30.
                    .hh, .h => switch (options.mode) {
                        .strict => if (hour < 1 or hour > 12) return error.ParseError,
                        .lenient => if (hour > 24) return error.ParseError,
                    },
                    else => unreachable,
                }
                rest = rest[str.len..];
                break :hour @intCast(hour);
            };
        },
        .kk, .k => {
            state.datetime.hour = hour: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .kk and str.len != 2) return error.NoMatch;
                var hour = read.digits(str);
                if (hour > 24) return error.ParseError;
                if (hour == 24) hour = 0;
                rest = rest[str.len..];
                break :hour @intCast(hour);
            };
        },
        .mm, .m => {
            state.datetime.minute = minute: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .mm and str.len != 2) return error.NoMatch;
                const minute = read.digits(str);
                if (minute > 59) return error.ParseError;
                rest = rest[str.len..];
                break :minute @intCast(minute);
            };
        },
        .ss, .s => {
            state.datetime.second = second: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                if (options.mode == .strict and tag == .ss and str.len != 2) return error.NoMatch;
                const second = read.digits(str);
                if (second > 60) return error.ParseError;
                rest = rest[str.len..];
                break :second @intCast(second);
            };
        },
        .SSSSSSSSS,
        .SSSSSSSS,
        .SSSSSSS,
        .SSSSSS,
        .SSSSS,
        .SSSS,
        .SSS,
        .SS,
        .S,
        => {
            const len = @tagName(tag).len;
            state.datetime.nanosecond = try read.nanosecond(rest, len);
            rest = rest[len..];
        },
        // .NN => {
        //     const map = std.StaticStringMapWithEql(i2, std.ascii.eqlIgnoreCase).initComptime(.{
        //         .{ "Before Christ", -1 },
        //         .{ "Anno Domini", 1 },
        //         .{ "Before Common Era", -1 },
        //         .{ "Common Era", 1 },
        //     });
        //     year_sign = sign: {
        //         for (1..rest.len + 1) |l| {
        //             if (map.get(rest[0..l])) |sign| {
        //                 rest = rest[l..];
        //                 break :sign sign;
        //             }
        //         }
        //         return error.ParseError;
        //     };
        // },
        // .N => {
        //     const map = std.StaticStringMapWithEql(i2, std.ascii.eqlIgnoreCase).initComptime(.{
        //         .{ "BC", -1 },
        //         .{ "AD", 1 },
        //         .{ "BCE", -1 },
        //         .{ "CE", 1 },
        //     });
        //     year_sign = sign: {
        //         for (1..rest.len + 1) |l| {
        //             if (map.get(rest[0..l])) |sign| {
        //                 rest = rest[l..];
        //                 break :sign sign;
        //             }
        //         }
        //         return error.ParseError;
        //     };
        // },
        .A, .a => {
            const found = options.locale.matchMeridiem(rest) orelse return error.NoMatch;
            rest = rest[found.len..];
            state.am_pm = switch (found.half) {
                .am => .am,
                .pm => .pm,
            };
        },
        .dddd,
        .ddd,
        .dd,
        => {
            // Leniently any of the three lengths is taken
            // whichever was asked for, longest first so that
            // "Sunday" is not read as "Sun" with "day" over.
            if (!startsWord(rest)) return error.NoMatch;

            // Leniently any of the three lengths is taken whichever was
            // asked for, longest first so that "Sunday" is not read as
            // "Sun" with "day" left over.
            const result = (if (options.mode == .lenient)
                options.locale.matchWeekday(rest, .dddd) orelse
                    options.locale.matchWeekday(rest, .ddd) orelse
                    options.locale.matchWeekday(rest, .dd)
            else
                options.locale.matchWeekday(rest, tag)) orelse return error.ParseError;

            rest = rest[result.len..];
            state.day_of_week = result.weekday;
            state.week.weekday = result.weekday;
        },
        .w, .ww, .wo, .W, .WW, .Wo => {
            const parsed = number: {
                const str = read.int(rest, 2);
                if (str.len == 0) return error.NoMatch;
                switch (tag) {
                    .ww, .WW => if (options.mode == .strict and str.len != 2) return error.NoMatch,
                    else => {},
                }
                rest = rest[str.len..];
                break :number read.digits(str);
            };

            switch (tag) {
                .wo, .Wo => try skipOrdinal(&rest, parsed, tag, options),
                else => {},
            }

            switch (tag) {
                .w, .ww, .wo => state.week.week = @intCast(parsed),
                .W, .WW, .Wo => state.week.iso_week = @intCast(parsed),
                else => unreachable,
            }
        },
        .gg, .gggg, .GG, .GGGG => {
            const width: usize = switch (tag) {
                .gg, .GG => 2,
                else => 4,
            };

            const str = read.int(rest, width);
            if (str.len == 0) return error.NoMatch;
            if (options.mode == .strict and str.len != width) return error.NoMatch;
            rest = rest[str.len..];

            const parsed = @as(Year, @intCast(read.digits(str)));
            const year = switch (tag) {
                // Two digits are windowed the same way `YY` is.
                .gg, .GG => parsed + (if (parsed > 68) @as(Year, 1900) else 2000),
                else => parsed,
            };

            switch (tag) {
                .gg, .gggg => state.week.year = year,
                .GG, .GGGG => state.week.iso_year = year,
                else => unreachable,
            }
        },
        .d, .e, .E, .do => {
            state.day_of_week = dow: {
                const str = read.int(rest, 1);
                if (str.len != 1) return error.NoMatch;
                var dow = read.digits(str);
                switch (tag) {
                    .E => {
                        // ISO numbers the week Monday 1 to
                        // Sunday 7, and `DayOfWeek` numbers it
                        // Sunday 0 to Saturday 6, so only
                        // Sunday moves. Subtracting one, which
                        // is what this used to do, turned every
                        // day into the one before it.
                        if (dow < 1 or dow > 7) return error.ParseError;
                        if (dow == 7) dow = 0;
                    },
                    .d, .e, .do => {
                        if (dow > 6) return error.ParseError;
                    },
                    else => unreachable,
                }
                rest = rest[str.len..];
                switch (tag) {
                    .do => try skipOrdinal(&rest, dow, .do, options),
                    .d, .e, .E => {},
                    else => unreachable,
                }
                // `e` counts from the day the locale starts its week
                // on, where `d` and `do` always count from Sunday, so
                // only `e` has to be turned back into a weekday.
                const numbered: u3 = switch (tag) {
                    .e => @intCast((dow + @as(u8, options.locale.week.starts_on.weekdayNumber())) % 7),
                    else => @intCast(dow),
                };
                const parsed = std.enums.fromInt(DayOfWeek, numbered) orelse
                    return error.NoMatch;

                // `E` counts the ISO way and the others the
                // locale way, which decides both the default
                // week and the default week-numbering year if
                // the date has to be built from them.
                switch (tag) {
                    .E => state.week.iso_weekday = parsed,
                    .e => state.week.local_weekday = parsed,
                    .d, .do => state.week.weekday = parsed,
                    else => unreachable,
                }

                break :dow parsed;
            };
        },
        .Z, .ZZ => {
            state.datetime.offset = offset: {
                if (rest.len == 0) return error.NoMatch;

                // ISO 8601 writes a zero offset as "Z"; accept
                // that spelling as well as "+00:00".
                if (rest[0] == 'Z' or rest[0] == 'z') {
                    rest = rest[1..];
                    break :offset 0;
                }

                const sign: i32 = switch (rest[0]) {
                    '+' => 1,
                    '-' => -1,
                    else => return error.NoMatch,
                };
                rest = rest[1..];

                const hours = read.int(rest, 2);
                if (hours.len != 2) return error.NoMatch;
                rest = rest[hours.len..];

                // Both sequences take either spelling and the
                // minutes at all, which is moment's rule:
                // +05, +0500 and +05:00 all read the same, for
                // Z and for ZZ alike.
                if (rest.len > 0 and rest[0] == ':') rest = rest[1..];

                const minutes = read.int(rest, 2);
                if (minutes.len != 0 and minutes.len != 2) return error.NoMatch;
                rest = rest[minutes.len..];

                const hour: i32 = @intCast(read.digits(hours));
                const minute: i32 = @intCast(read.digits(minutes));
                if (hour > 23 or minute > 59) return error.ParseError;
                break :offset sign * (hour * std.time.s_per_hour + minute * std.time.s_per_min);
            };
        },
        .Q,
        .Qo,
        .yo,
        .N,
        .NN,
        .NNN,
        .NNNN,
        .NNNNN,
        .YYYYY,
        .YYYYYY,
        .Hmm,
        .Hmmss,
        .hmm,
        .hmmss,
        .X,
        .x,
        .z,
        .zz,
        .ggggg,
        .GGGGG,
        => {
            return error.IllegalToken;
        },
        // else => {},
    }

    left.* = rest;
}

/// Parses `value` according to the comptime `format_string`, leniently and
/// relative to the Unix epoch. See `parseWith`.
pub fn parse(comptime format_string: []const u8, value: []const u8) ParseError!ParseResult {
    return parseWith(format_string, value, .{});
}

/// Parses `value` according to the comptime `format_string`, requiring an
/// exact match and the whole input. See `parseWith`.
pub fn parseStrict(comptime format_string: []const u8, value: []const u8) ParseError!ParseResult {
    return parseWith(format_string, value, .{ .mode = .strict });
}

/// A French locale, built by hand from moment's own `fr`, for the tests
/// below. Only a locale's data is needed to make one, so this is also
/// what writing one looks like.
const french: locale.Locale = blk: {
    const months = [12][]const u8{
        "janvier",
        "février",
        "mars",
        "avril",
        "mai",
        "juin",
        "juillet",
        "août",
        "septembre",
        "octobre",
        "novembre",
        "décembre",
    };
    const months_short = [12][]const u8{
        "janv.",
        "févr.",
        "mars",
        "avr.",
        "mai",
        "juin",
        "juil.",
        "août",
        "sept.",
        "oct.",
        "nov.",
        "déc.",
    };
    const weekdays = [7][]const u8{
        "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi",
    };
    const weekdays_short = [7][]const u8{
        "dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam.",
    };
    const weekdays_min = [7][]const u8{ "di", "lu", "ma", "me", "je", "ve", "sa" };

    break :blk .{
        .tag = "fr",
        .months = &months,
        .months_short = &months_short,
        .weekdays = &weekdays,
        .weekdays_short = &weekdays_short,
        .weekdays_min = &weekdays_min,
        .long_date_format = .{
            .LT = "HH:mm",
            .LTS = "HH:mm:ss",
            .L = "DD/MM/YYYY",
            .LL = "D MMMM YYYY",
            .LLL = "D MMMM YYYY HH:mm",
            .LLLL = "dddd D MMMM YYYY HH:mm",
        },
        // moment's `fr` is dow 1, doy 4, which is the ISO rule.
        .week = .iso,
    };
};

test "a locale changes the words and not the sequences" {
    const dt: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .hour = 13,
        .minute = 7,
        .weekday = .Tue,
    };

    var buffer: [128]u8 = undefined;

    // The same format string, two languages.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("dddd D MMMM YYYY", french, &writer);
        try std.testing.expectEqualStrings("mardi 5 mars 2024", writer.buffered());
    }
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.format("dddd D MMMM YYYY", &writer);
        try std.testing.expectEqualStrings("Tuesday 5 March 2024", writer.buffered());
    }

    // `L` is the piece a locale rewrites rather than renames: the same
    // sequence is a different date order.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("L", french, &writer);
        try std.testing.expectEqualStrings("05/03/2024", writer.buffered());
    }
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.format("L", &writer);
        try std.testing.expectEqualStrings("03/05/2024", writer.buffered());
    }

    // And `LLLL`, which is a whole sentence of them.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("LLLL", french, &writer);
        try std.testing.expectEqualStrings("mardi 5 mars 2024 13:07", writer.buffered());
    }

    // The lower case spellings take a letter off the padded sequences,
    // which is how moment derives them rather than letting a locale name
    // them: `DD/MM/YYYY` becomes `D/M/YYYY`.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("l", french, &writer);
        try std.testing.expectEqualStrings("5/3/2024", writer.buffered());
    }
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("llll", french, &writer);
        try std.testing.expectEqualStrings("mar. 5 mars 2024 13:07", writer.buffered());
    }

    // `e` counts from the day the week starts on, so it moves with the
    // locale where `d` and `E` do not.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("d e E", french, &writer);
        try std.testing.expectEqualStrings("2 1 2", writer.buffered());
    }
    {
        var writer = std.Io.Writer.fixed(&buffer);
        try dt.format("d e E", &writer);
        try std.testing.expectEqualStrings("2 2 2", writer.buffered());
    }
}

test "a locale reads back what it wrote" {
    const written = "mardi 5 mars 2024";

    const parsed = try parseWith("dddd D MMMM YYYY", written, .{
        .locale = french,
        .mode = .strict,
    });
    try std.testing.expectEqual(@as(Year, 2024), parsed.value.year);
    try std.testing.expectEqual(Month.Mar, parsed.value.month);
    try std.testing.expectEqual(@as(Day, 5), parsed.value.day);
    try std.testing.expectEqual(DayOfWeek.Tue, parsed.value.weekday);

    // The `L` family reads as well as it writes, and reads the locale's
    // order rather than the English one.
    const short = try parseWith("L", "05/03/2024", .{ .locale = french, .mode = .strict });
    try std.testing.expectEqual(Month.Mar, short.value.month);
    try std.testing.expectEqual(@as(Day, 5), short.value.day);

    // The same text under English is the fifth of May, because `L` means
    // something else there. Both are right, which is the point.
    const english = try parseWith("L", "05/03/2024", .{ .mode = .strict });
    try std.testing.expectEqual(Month.May, english.value.month);
    try std.testing.expectEqual(@as(Day, 3), english.value.day);

    // A name in the wrong language is not a name.
    try std.testing.expectError(
        error.ParseError,
        parseWith("dddd D MMMM YYYY", written, .{ .mode = .strict }),
    );
}

test "every locale reads back what it wrote" {
    // Only the built-in one without `-Dembed-locales`, which the tests
    // above have already been through.
    if (!locale.embedded) return error.SkipZigTest;

    // Dates spread over a year, so that every month name and every
    // weekday name is written and read at least once, and so that an
    // ordinal is asked for on the days most likely to be irregular.
    const dates = [_]Date{
        .{ .year = 2024, .month = .Jan, .day = 1 },
        .{ .year = 2024, .month = .Feb, .day = 2 },
        .{ .year = 2024, .month = .Feb, .day = 29 },
        .{ .year = 2024, .month = .Mar, .day = 3 },
        .{ .year = 2024, .month = .Apr, .day = 11 },
        .{ .year = 2024, .month = .May, .day = 21 },
        .{ .year = 2024, .month = .Jun, .day = 22 },
        .{ .year = 2024, .month = .Jul, .day = 23 },
        .{ .year = 2024, .month = .Aug, .day = 13 },
        .{ .year = 2024, .month = .Sep, .day = 4 },
        .{ .year = 2024, .month = .Oct, .day = 5 },
        .{ .year = 2024, .month = .Nov, .day = 30 },
        .{ .year = 2024, .month = .Dec, .day = 31 },
    };

    var buffer: [256]u8 = undefined;

    for (locale.all) |each| {
        // moment's pseudo-locale wraps its names in tildes, which are
        // not letters in any alphabet and which moment's own name pattern
        // does not accept either. It exists to make untranslated text
        // obvious on screen, not to be read back.
        if (std.mem.eql(u8, each.tag, "x-pseudo")) continue;

        for (dates) |date| {
            const dt: DateTime = .{
                .year = date.year,
                .month = date.month,
                .day = date.day,
                .weekday = date.dayOfWeek(),
            };

            // The long names, which is where an accent or a name that is
            // a prefix of another one would go wrong.
            var writer = std.Io.Writer.fixed(&buffer);
            dt.formatWith("dddd|D|MMMM|YYYY", each, &writer) catch |err| {
                std.debug.print("{s}: writing failed: {}\n", .{ each.tag, err });
                return err;
            };
            const written = writer.buffered();

            const parsed = parseWith("dddd|D|MMMM|YYYY", written, .{
                .locale = each,
                .mode = .strict,
            }) catch |err| {
                std.debug.print("{s}: {s} did not read back: {}\n", .{ each.tag, written, err });
                return err;
            };

            if (parsed.value.month != dt.month or parsed.value.day != dt.day or
                parsed.value.weekday != dt.weekday or parsed.value.year != dt.year)
            {
                std.debug.print("{s}: {s} read back as {d}-{d}-{d}\n", .{
                    each.tag,
                    written,
                    parsed.value.year,
                    @intFromEnum(parsed.value.month),
                    parsed.value.day,
                });
                return error.RoundTripChangedTheDate;
            }
        }
    }
}

test "a locale round trips every day of a year" {
    // Every date of 2024 written in French and read back, which is what
    // says the accented names match and that nothing is a prefix of
    // something it should not be.
    var date: Date = .{ .year = 2024, .month = .Jan, .day = 1 };
    const last: Date = .{ .year = 2024, .month = .Dec, .day = 31 };

    var buffer: [128]u8 = undefined;
    while (true) {
        const dt: DateTime = .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .weekday = date.dayOfWeek(),
        };

        var writer = std.Io.Writer.fixed(&buffer);
        try dt.formatWith("dddd D MMMM YYYY", french, &writer);

        const parsed = try parseWith("dddd D MMMM YYYY", writer.buffered(), .{
            .locale = french,
            .mode = .strict,
        });
        try std.testing.expectEqual(dt.year, parsed.value.year);
        try std.testing.expectEqual(dt.month, parsed.value.month);
        try std.testing.expectEqual(dt.day, parsed.value.day);
        try std.testing.expectEqual(dt.weekday, parsed.value.weekday);

        if (std.meta.eql(date, last)) break;
        date = Date.fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra() + 1);
    }
}

test parseStrict {
    // The whole input has to be used, and each sequence takes exactly what
    // it says.
    _ = try parseStrict("YYYY-MM-DD", "2024-03-15");

    try std.testing.expectError(error.ParseError, parseStrict("YYYY-MM-DD", "2024-3-15"));
    try std.testing.expectError(error.ParseError, parseStrict("YYYY-MM-DD", "2024-03-15 and then some"));

    // Where `parse` takes all three.
    _ = try parse("YYYY-MM-DD", "2024-3-15");
    _ = try parse("YYYY-MM-DD", "2024-03-15 and then some");
}

test parse {
    const result = try parse("YYYY-MM-DD", "2024-03-15");
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expectEqual(@as(Day, 15), result.value.day);

    // The weekday is worked out from the date rather than taken on trust.
    try std.testing.expectEqual(DayOfWeek.Fri, result.value.weekday);

    // Fields the format string does not mention come from the epoch, so a
    // date alone leaves the time of day at midnight.
    try std.testing.expectEqual(@as(Hour, 0), result.value.hour);

    // Only what was consumed is reported, so the caller can carry on.
    try std.testing.expectEqualStrings("2024-03-15", result.str);
}

/// Parses `value` according to the comptime `format_string`, a string of
/// `FormatTag` sequences (e.g. "MMM D H:mm:ss"). Date fields missing from
/// the format string are taken from `relative_to`; time-of-day fields
/// always default to zero. A parsed day of the week is checked against the
/// computed date and `error.ParseError` is returned on mismatch.
///
/// A week names a date, so the week sequences are parsed: `w` and `W`
/// with their week-numbering years `gg` and `GG`, together with a weekday
/// from `d`, `e` or `E`, build a date between them when the format string
/// names neither a month nor a day. What each of them defaults to when the
/// string leaves it out is `resolveWeek`.
///
/// Some sequences still name no date and cannot be parsed: the quarter
/// (`Q`), the era (`N`), the zone name (`z`), the Unix timestamps (`X` and
/// `x`), and the run-together hour and minute (`Hmm`). The tokenizer runs
/// at comptime, so a format string using one is rejected while this is
/// being compiled: the `error.IllegalToken` it raises there surfaces as a
/// compile error and never reaches a caller.
pub fn parseRelativeTo(comptime format_string: []const u8, relative_to: DateTime, value: []const u8) ParseError!ParseResult {
    return parseWith(format_string, value, .{ .relative_to = relative_to });
}

/// Whether `text` begins with something a name could be written in.
///
/// A word that is not a month is a wrong month rather than no month at
/// all, which is what stops a lenient scan stepping over it to find the
/// next thing that looks like one. So a sequence that reads a name has to
/// be able to tell "there is a word here" from "there is not", without
/// knowing the language it would be in.
///
/// moment asks this with `/[0-9]{0,256}[a-z\u00A0-\u05FF...]{1,256}/i`:
/// any run of digits, then at least one letter, where letter means most
/// of the Basic Multilingual Plane. The same shape here, with "letter"
/// meaning an ASCII one or any byte a multi-byte UTF-8 sequence can start
/// or continue. The digits in front are what lets Japanese "3月" be a
/// month name rather than a number with something after it.
fn startsWord(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
    if (index >= text.len) return false;
    return std.ascii.isAlphabetic(text[index]) or text[index] == '\'' or text[index] >= 0x80;
}

test startsWord {
    try std.testing.expect(startsWord("March"));
    try std.testing.expect(startsWord("march"));

    // Not English, and not letters at all in the ASCII sense.
    try std.testing.expect(startsWord("\u{43c}\u{430}\u{440}\u{442}"));
    try std.testing.expect(startsWord("3\u{6708}"));

    // A bare number is a number, and punctuation is a separator.
    try std.testing.expect(!startsWord("15"));
    try std.testing.expect(!startsWord(" March"));
    try std.testing.expect(!startsWord("-"));
    try std.testing.expect(!startsWord(""));
}

/// Steps over whatever the locale writes around an ordinal, the number
/// itself having already been read.
fn skipOrdinal(rest: *[]const u8, n: u32, comptime tag: FormatTag, options: Options) MatchError!void {
    const len = options.locale.matchOrdinal(rest.*, n, tag) orelse return error.NoMatch;
    rest.* = rest.*[len..];
}

/// One pass over a format string's tokens while reading a date.
///
/// The state a sequence can touch, held together so that the same step
/// serves the unrolled walk over a comptime format string and the runtime
/// one over what a localized sequence stands for. Before a locale, the
/// walk was the body of `parseWith` and there was only ever one of them.
const ParseWalk = struct {
    /// What the sequences have read so far.
    state: ParseState,
    /// What is left of the input.
    left: []const u8,
    options: Options,

    /// How much of the input was stepped over rather than read, which
    /// only happens leniently. `ParseResult.str` still runs to the end of
    /// what was used, so this is what says how much of it counted.
    skipped: usize = 0,

    /// Whether any sequence read anything. An input that matched nothing
    /// at all is not a date, however many sequences were passed over on
    /// the way: moment calls that `empty` and refuses it, and so does
    /// this.
    matched_any: bool = false,

    /// Which of the date fields actually got a value. Not which ones the
    /// format string names: leniently a sequence can match nowhere and be
    /// passed over, and then its field was never set at all.
    set_year: bool = false,
    set_month: bool = false,
    set_day: bool = false,

    /// Reads what one sequence names, wherever the mode allows it to be.
    ///
    /// `depth` bounds the nesting of localized sequences the same way
    /// `DateTime.formatExpansion` does.
    fn tag(self: *ParseWalk, comptime found: FormatTag, depth: u8) ParseError!void {
        // A localized sequence stands for a string of others, which are
        // read in its place. The string is the locale's, so this is the
        // one place the tokenizer runs at run time.
        if (comptime found.isLocalized()) {
            if (depth >= 5) return;
            const stands_for = self.options.locale.long_date_format.get(found);
            return self.expansion(stands_for.fmt, stands_for.abbreviate, depth + 1);
        }

        // Leniently a sequence is looked for rather than required where
        // it stands: moment searches the rest of the input for something
        // the sequence matches, steps over whatever came before, and
        // passes over the sequence altogether when nothing does. Strictly
        // it has to be right here.
        //
        // Trying the same match at successive places is what does the
        // searching, so every sequence gets the behaviour without any of
        // them knowing about it.
        const limit = if (self.options.mode == .strict) 0 else self.left.len;

        var at: usize = 0;
        const matched = while (at <= limit) : (at += 1) {
            var attempt = self.left[at..];
            var candidate = self.state;
            if (matchTag(found, &attempt, &candidate, self.options)) |_| {
                self.skipped += at;
                self.state = candidate;
                self.left = attempt;
                break true;
            } else |err| switch (err) {
                // Not shaped like this sequence here; try further along,
                // and leave `state` as it was.
                error.NoMatch => {},
                // Shaped like it and wrong, which no amount of looking
                // elsewhere will improve.
                else => |fatal| return fatal,
            }
        } else false;

        // A sequence that matched nowhere is simply not there. Strictly
        // that is an error; leniently the field keeps whatever it was
        // going to default to.
        if (!matched and self.options.mode == .strict) return error.ParseError;
        if (matched) {
            self.matched_any = true;
            switch (found) {
                .YYYY, .YY, .Y, .y, .yy, .yyy, .yyyy => self.set_year = true,
                .MMMM, .MMM, .MM, .M, .Mo => self.set_month = true,
                .DD, .D, .Do => self.set_day = true,
                // A day of the year names a month and a day between them.
                .DDDD, .DDD, .DDDo => {
                    self.set_month = true;
                    self.set_day = true;
                },
                else => {},
            }
        }
    }

    /// Reads a run of text that is not a sequence.
    ///
    /// Looked for the same way a sequence is, so a separator that does
    /// not match is stepped over leniently rather than refused, and one
    /// that is nowhere in what is left is passed over. Strictly it has to
    /// be right here.
    fn literal(self: *ParseWalk, text: []const u8) ParseError!void {
        if (self.options.mode == .strict) {
            if (self.left.len < text.len) return error.ParseError;
            if (!std.mem.eql(u8, self.left[0..text.len], text)) return error.ParseError;
            self.left = self.left[text.len..];
        } else if (std.mem.indexOf(u8, self.left, text)) |at| {
            self.skipped += at;
            self.left = self.left[at + text.len ..];
        }
    }

    /// Reads what one localized sequence stands for.
    fn expansion(self: *ParseWalk, fmt: []const u8, abbreviated: bool, depth: u8) ParseError!void {
        var it: FormatTag.Tokenizer = .init(fmt);
        while (it.next()) |token| {
            switch (token) {
                .tag => |found| {
                    const shortened = if (abbreviated) found.abbreviate() else found;
                    if (!shortened.isParsable()) return error.IllegalToken;
                    // `inline else` is what makes the sequence comptime
                    // again, so that the same step serves both walks.
                    switch (shortened) {
                        inline else => |known| try self.tag(known, depth),
                    }
                },
                .literal => |text| try self.literal(text),
            }
        }
    }
};

/// Parses `value` according to the comptime `format_string`, a string of
/// `FormatTag` sequences (e.g. "MMM D H:mm:ss"), under `options`.
pub fn parseWith(
    comptime format_string: []const u8,
    value: []const u8,
    options: Options,
) ParseError!ParseResult {
    const relative_to = options.relative_to;

    const tokens = comptime tokens: {
        @setEvalBranchQuota(200000);
        for (tokensOf(format_string)) |token| switch (token) {
            .tag => |tag| if (!tag.isParsable()) return error.IllegalToken,
            .literal => {},
        };
        break :tokens tokensOf(format_string);
    };

    var datetime: DateTime = relative_to;
    datetime.hour = 0;
    datetime.minute = 0;
    datetime.second = 0;
    datetime.nanosecond = 0;

    var walk: ParseWalk = .{
        .state = .{ .datetime = datetime },
        .left = value,
        .options = options,
    };

    // Unrolled, as `formatWith` does with the same token list. The tokens
    // are comptime known, so this turns a switch over every sequence in
    // the enum into straight-line code for the handful the format string
    // actually uses.
    inline for (tokens) |token| {
        switch (token) {
            .tag => |tag| try walk.tag(tag, 0),
            .literal => |text| try walk.literal(text),
        }
    }

    var state = walk.state;
    var set_year = walk.set_year;
    var set_month = walk.set_month;
    var set_day = walk.set_day;
    const matched_any = walk.matched_any;
    const skipped = walk.skipped;
    const left = walk.left;

    switch (state.am_pm) {
        .none => {},
        // An hour outside the twelve only arrives here leniently, and is
        // left as it is rather than refused: a zero reads as the twelve it
        // would have been written as, so "0:30 pm" is half past noon, and
        // "13:30 pm" is simply half past one.
        .am => if (state.datetime.hour == 12) {
            state.datetime.hour = 0;
        },
        .pm => if (state.datetime.hour < 12) {
            state.datetime.hour += 12;
        },
    }

    // A state.week names a date, so it is only used when the format string named
    // neither a month nor a day. With a full date already in hand a
    // weekday is a claim to check instead, which is what happens below.
    if (state.week.any() and !set_month and !set_day) {
        const from_week = try resolveWeek(
            state.week,
            if (set_year) state.datetime.year else null,
            relative_to.asDate(),
            options.locale,
        );
        state.datetime.year = from_week.year;
        state.datetime.month = from_week.month;
        state.datetime.day = from_week.day;
        set_year = true;
        set_month = true;
        set_day = true;
    }

    if (state.day_of_year) |doy| {
        // A day of the year names a complete date by itself, so it
        // replaces whatever month and day were set, and is checked
        // against the length of the year it landed in.
        const length: u16 = if (Month.Feb.lastDay(state.datetime.year) == 29) 366 else 365;
        if (doy > length) return error.ParseError;

        var month: Month = .Jan;
        var remaining = doy;
        while (remaining > month.lastDay(state.datetime.year)) {
            remaining -= month.lastDay(state.datetime.year);
            month = month.next();
        }
        state.datetime.month = month;
        state.datetime.day = @intCast(remaining);
        set_month = true;
        set_day = true;
    }

    // moment fills what is still unset by walking year, month, day in
    // order: the fields before the first one that got a value keep the
    // reference's, which they already hold, and everything after it drops
    // to its lowest. So "2024" against `YYYY` is the first of January and
    // not the reference's month and day, while a string naming only a
    // time keeps the whole reference date.
    if (set_year) {
        if (!set_month) state.datetime.month = .Jan;
        if (!set_day) state.datetime.day = 1;
    } else if (set_month) {
        if (!set_day) state.datetime.day = 1;
    }

    // An hour of 24 is the end of the day rather than an hour in it, and
    // only when nothing smaller was named: moment reads 24:00 as the
    // following midnight and rejects 24:00:01. The date has to move, so
    // this happens before the day is checked and the weekday recomputed.
    if (state.datetime.hour == 24) {
        if (state.datetime.minute != 0 or state.datetime.second != 0 or state.datetime.nanosecond != 0) {
            return error.ParseError;
        }
        state.datetime.hour = 0;

        const next = Date.fromDaysSinceStartOfEra(state.datetime.asDate().toDaysSinceStartOfEra() + 1);
        state.datetime.year = next.year;
        state.datetime.month = next.month;
        state.datetime.day = next.day;
    }

    // A day number is checked against 31 as it is read, because the month
    // it belongs to may not have been parsed yet, so it has to be checked
    // against that month once everything is in. Without this, a date like
    // 2024-02-31 reaches `updateDayOfWeek` and trips the assertion in
    // `Date.toDaysSinceStartOfEra`.
    if (!state.datetime.asDate().isRegular()) return error.ParseError;

    // Every sequence that moves the date leaves the weekday stale, so it
    // is recomputed once here rather than after each of them.
    state.datetime.updateDayOfWeek();

    // The weekday is a check rather than a source when the date was named
    // outright; when the date was built from a state.week it came from this in
    // the first place and agrees by construction.
    if (state.day_of_week) |dow| {
        if (state.datetime.weekday != dow) return error.ParseError;
    }

    if (!matched_any) return error.ParseError;

    // Strict takes the whole input or none of it. Lenient leaves whatever
    // it did not need, and says how much that was, which is what lets a
    // caller carry on from where this stopped.
    if (options.mode == .strict and left.len != 0) return error.ParseError;

    return .{
        .str = value[0 .. value.len - left.len],
        .skipped = skipped,
        .value = state.datetime,
    };
}

/// This date as a `Date`, dropping the time of day and the offset.
pub fn asDate(self: DateTime) Date {
    return .{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    };
}

test asDate {
    const datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 14 };
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        datetime.asDate(),
    );
}

/// Returns the instant this reading names, by taking its offset off it.
///
/// This is the inverse of `Instant.asDateTime`, and is what the `X` and
/// `x` sequences are written from. A wall-clock reading plus an offset
/// names exactly one instant, so unlike `TimeZone.resolve` there is
/// nothing here that can be ambiguous or missing.
pub fn toInstant(self: DateTime) Instant {
    const seconds = @as(i64, self.asDate().toDaysSinceStartOfEra()) * std.time.s_per_day +
        @as(i64, self.hour) * std.time.s_per_hour +
        @as(i64, self.minute) * std.time.s_per_min +
        @as(i64, self.second) -
        self.offset;

    return .{
        .timestamp = @as(i128, seconds) * std.time.ns_per_s + self.nanosecond,
    };
}

test toInstant {
    // The epoch, and the same instant written against a zone five hours
    // behind it.
    const utc_epoch: DateTime = .{ .year = 1970, .month = .Jan, .day = 1 };
    try std.testing.expectEqual(@as(i128, 0), utc_epoch.toInstant().timestamp);

    const shifted: DateTime = .{
        .year = 1969,
        .month = .Dec,
        .day = 31,
        .hour = 19,
        .offset = -5 * std.time.s_per_hour,
    };
    try std.testing.expectEqual(@as(i128, 0), shifted.toInstant().timestamp);

    // It undoes `Instant.asDateTime`.
    const instant: Instant = .fromNanoTimeStamp(1710513005123456789);
    try std.testing.expectEqual(instant.timestamp, instant.asDateTime().toInstant().timestamp);
}

/// Returns the ISO 8601 state.week this date falls in, and the year that state.week
/// belongs to. See `Date.isoWeek`, which this defers to. The `W` and `GG`
/// format sequences write these.
pub fn isoWeek(self: DateTime) Date.Week {
    return self.asDate().isoWeek();
}

/// Returns the week this date falls in under the English-language
/// convention, and the year that week belongs to. See `Date.localeWeek`.
///
/// This is `weekIn(locale.en)`, and is what the `w` and `gg` sequences
/// write when no locale was asked for.
pub fn localeWeek(self: DateTime) Date.Week {
    return self.asDate().localeWeek();
}

/// Returns the week this date falls in under `in`'s rule, and the year
/// that week belongs to.
///
/// Which day the week starts on and which January day is always in week
/// one are both the locale's, and the two together are what make a week
/// number: English puts January 1st in week one and starts on Sunday,
/// most of Europe starts on Monday and uses the ISO rule. The `w`, `ww`,
/// `wo`, `gg` and `gggg` sequences write these. `W` and `GG` are always
/// ISO whatever the locale says, which is what `isoWeek` is for.
pub fn weekIn(self: DateTime, in: locale.Locale) Date.Week {
    return self.asDate().weekOfYear(in.week.starts_on, in.week.january_day_in_first_week);
}

test weekIn {
    const newyear: DateTime = .{ .year = 2027, .month = .Jan, .day = 1 };

    // English puts January 1st in week one whatever weekday it is.
    try std.testing.expectEqual(@as(u8, 1), newyear.weekIn(locale.en).week);
    try std.testing.expectEqual(newyear.localeWeek(), newyear.weekIn(locale.en));

    // The ISO rule does not: 2027 opens on a Friday, which belongs to
    // 2026's week 53.
    const iso: locale.Locale = .{
        .tag = "test",
        .months = locale.en.months,
        .months_short = locale.en.months_short,
        .weekdays = locale.en.weekdays,
        .weekdays_short = locale.en.weekdays_short,
        .weekdays_min = locale.en.weekdays_min,
        .long_date_format = locale.en.long_date_format,
        .week = .iso,
    };
    try std.testing.expectEqual(@as(u8, 53), newyear.weekIn(iso).week);
    try std.testing.expectEqual(newyear.isoWeek(), newyear.weekIn(iso));
}

test localeWeek {
    // The two rules disagree at the turn of the year, which is why both
    // are available and why each has its own pair of sequences.
    const yearend: DateTime = .{ .year = 2026, .month = .Dec, .day = 31 };
    try std.testing.expectEqual(@as(u8, 1), yearend.localeWeek().week);
    try std.testing.expectEqual(@as(Year, 2027), yearend.localeWeek().year);
    try std.testing.expectEqual(@as(u8, 53), yearend.isoWeek().week);
    try std.testing.expectEqual(@as(Year, 2026), yearend.isoWeek().year);
}

test isoWeek {
    // The `w` sequences format this, and it is not the calendar year that
    // belongs beside it: 2027 opens inside 2026's state.week 53.
    const newyear: DateTime = .{ .year = 2027, .month = .Jan, .day = 1 };
    try std.testing.expectEqual(@as(Year, 2026), newyear.isoWeek().year);
    try std.testing.expectEqual(@as(u8, 53), newyear.isoWeek().week);

    const march: DateTime = .{ .year = 2024, .month = .Mar, .day = 15 };
    try std.testing.expectEqual(@as(u8, 11), march.isoWeek().week);
}

/// Returns the 1-based day of the year (1-366).
pub fn dayOfThisYear(self: DateTime) u9 {
    return self.month.daysBefore(self.year) + self.day;
}

test dayOfThisYear {
    try std.testing.expectEqual(@as(u9, 1), (DateTime{ .year = 2024, .month = .Jan, .day = 1 }).dayOfThisYear());

    // 2024 is a leap year, so from March on it runs one day ahead of 2025.
    try std.testing.expectEqual(@as(u9, 75), (DateTime{ .year = 2024, .month = .Mar, .day = 15 }).dayOfThisYear());
    try std.testing.expectEqual(@as(u9, 74), (DateTime{ .year = 2025, .month = .Mar, .day = 15 }).dayOfThisYear());

    try std.testing.expectEqual(@as(u9, 366), (DateTime{ .year = 2024, .month = .Dec, .day = 31 }).dayOfThisYear());
}

/// Returns the same point in time expressed in UTC, that is with the
/// fields shifted back by `offset` seconds and `offset` itself set to
/// zero. The shift rolls over into the neighbouring day, month, and year
/// as needed, and `weekday` is recomputed to match. Seconds and
/// nanoseconds are carried through untouched, so a value holding a leap
/// second keeps it.
///
/// The designation is not carried through. It named the zone the reading
/// was made in, and the result is not a reading in that zone any more.
pub fn toUtc(self: DateTime) DateTime {
    if (self.offset == 0) return self;

    // A leap second is the 61st second of its minute and has no meaning
    // once shifted, so it is held back and restored afterwards. Every zone
    // offset that is not a whole number of minutes predates leap seconds
    // by decades, so the two never actually meet.
    const leap_second = self.second == 60;

    const date: Date = .{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    };
    const second_of_day = @as(i32, self.hour) * std.time.s_per_hour +
        @as(i32, self.minute) * std.time.s_per_min +
        @as(i32, if (leap_second) 59 else self.second) -
        self.offset;

    const days = date.toDaysSinceStartOfEra() +
        @as(Date.DaysType, @divFloor(second_of_day, std.time.s_per_day));
    const remainder = @mod(second_of_day, std.time.s_per_day);

    const utc_date = Date.fromDaysSinceStartOfEra(days);
    return .{
        .year = utc_date.year,
        .month = utc_date.month,
        .day = utc_date.day,
        .hour = @intCast(@divTrunc(remainder, std.time.s_per_hour)),
        .minute = @intCast(@divTrunc(@mod(remainder, std.time.s_per_hour), std.time.s_per_min)),
        .second = if (leap_second) 60 else @intCast(@mod(remainder, std.time.s_per_min)),
        .nanosecond = self.nanosecond,
        .weekday = DayOfWeek.fromDaysSinceStartOfEra(days),
        .offset = 0,
    };
}

test "the two parsing modes" {
    // Strictly a padded sequence wants its padding and a name sequence
    // wants the length it asked for; leniently either will do.
    _ = try parseStrict("YYYY-MM-DD", "2024-03-15");
    try std.testing.expectError(error.ParseError, parseStrict("MMM D YYYY", "March 15 2024"));
    _ = try parse("MMM D YYYY", "March 15 2024");
    _ = try parse("MMMM D YYYY", "Mar 15 2024");

    // Strictly the whole input has to be used.
    const trailing = try parse("YYYY-MM-DD", "2024-03-15 and then some");
    try std.testing.expectEqualStrings("2024-03-15", trailing.str);
    try std.testing.expectError(
        error.ParseError,
        parseStrict("YYYY-MM-DD", "2024-03-15 and then some"),
    );

    // Two characters against YYYY are a two digit year, windowed, which
    // only strict refuses.
    try std.testing.expectEqual(@as(Year, 2024), (try parse("YYYY", "24")).value.year);
    try std.testing.expectError(error.ParseError, parseStrict("YYYY", "24"));

    // The twelve hour clock is only a twelve hour clock strictly.
    try std.testing.expectEqual(@as(Hour, 12), (try parse("h:mm a", "0:30 pm")).value.hour);
    try std.testing.expectEqual(@as(Hour, 13), (try parse("h:mm a", "13:30 pm")).value.hour);
    try std.testing.expectError(error.ParseError, parseStrict("h:mm a", "0:30 pm"));

    // The mode rides along with the reference, so both can be set at once.
    const both = try parseWith("MM-DD", "03-15", .{
        .relative_to = .{ .year = 2001, .month = .Sep, .day = 9 },
        .mode = .strict,
    });
    try std.testing.expectEqual(@as(Year, 2001), both.value.year);
    try std.testing.expectEqual(Month.Mar, both.value.month);
}

test "the ISO weekday sequence numbers the week from Monday" {
    // `E` is Monday 1 through Sunday 7, which is not how `DayOfWeek`
    // numbers itself, and the conversion used to be off by a day.
    const reference: DateTime = .{ .year = 2001, .month = .Sep, .day = 9 };

    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Jan, .day = 1 },
        (try parseRelativeTo("E", reference, "1")).value.asDate(),
    );
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Jan, .day = 4 },
        (try parseRelativeTo("E", reference, "4")).value.asDate(),
    );
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Jan, .day = 7 },
        (try parseRelativeTo("E", reference, "7")).value.asDate(),
    );

    // Out of range, which is an error rather than something to go looking
    // for further along the input.
    try std.testing.expectError(error.ParseError, parseRelativeTo("E", reference, "0"));
    try std.testing.expectError(error.ParseError, parseRelativeTo("E", reference, "8"));
}

test "a week names a date when nothing else does" {
    // A week is a way of naming a date, so it builds one when the format
    // string named neither a month nor a day.
    const reference: DateTime = .{ .year = 2001, .month = .Sep, .day = 9 };

    // ISO: a missing week is week 1, and a missing weekday is Monday.
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        (try parseRelativeTo("GGGG-[W]WW-E", reference, "2024-W11-5")).value.asDate(),
    );

    // The English-language rule instead defaults a missing week to the
    // reference's own, which is what makes a bare `d` mean that weekday
    // of this week.
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Sep, .day = 13 },
        (try parseRelativeTo("d", reference, "4")).value.asDate(),
    );

    // With a month and a day named there is nothing for the week to do,
    // and the weekday goes back to being a claim that has to hold.
    _ = try parseRelativeTo("dddd, D MMMM YYYY", reference, "Friday, 15 March 2024");
    try std.testing.expectError(
        error.ParseError,
        parseRelativeTo("dddd, D MMMM YYYY", reference, "Monday, 15 March 2024"),
    );

    // A week that the year does not have is refused.
    try std.testing.expectError(error.ParseError, parseRelativeTo("GGGG-[W]WW", reference, "2024-W53"));
    _ = try parseRelativeTo("GGGG-[W]WW", reference, "2026-W53");
}

test "an hour of 24 is the end of the day" {
    // moment reads 24:00 as the following midnight rather than refusing
    // it, and refuses it once anything smaller is not zero.
    const rolled = try parse("YYYY-MM-DD HH:mm", "2024-03-15 24:00");
    try std.testing.expectEqual(@as(Day, 16), rolled.value.day);
    try std.testing.expectEqual(@as(Hour, 0), rolled.value.hour);
    try std.testing.expectEqual(DayOfWeek.Sat, rolled.value.weekday);

    // It rolls the month and the year with it.
    const year_end = try parse("YYYY-MM-DD HH:mm", "2024-12-31 24:00");
    try std.testing.expectEqual(@as(Year, 2025), year_end.value.year);
    try std.testing.expectEqual(Month.Jan, year_end.value.month);
    try std.testing.expectEqual(@as(Day, 1), year_end.value.day);

    try std.testing.expectError(
        error.ParseError,
        parse("YYYY-MM-DD HH:mm:ss", "2024-03-15 24:00:01"),
    );
    try std.testing.expectError(error.ParseError, parse("HH:mm", "25:00"));
}

test "a two digit year is windowed the way moment windows it" {
    // 69 through 99 are the twentieth century, 00 through 68 are this one.
    // The break is at 1969, which is the POSIX rule moment follows.
    try std.testing.expectEqual(@as(Year, 1969), (try parse("YY", "69")).value.year);
    try std.testing.expectEqual(@as(Year, 1999), (try parse("YY", "99")).value.year);
    try std.testing.expectEqual(@as(Year, 2068), (try parse("YY", "68")).value.year);
    try std.testing.expectEqual(@as(Year, 2000), (try parse("YY", "00")).value.year);

    // One digit is accepted leniently, the way moment accepts it, and
    // windowed the same way. Strict wants both digits.
    try std.testing.expectEqual(@as(Year, 2007), (try parse("YY", "7")).value.year);
    try std.testing.expectError(error.ParseError, parseStrict("YY", "7"));
}

test "either spelling of an offset parses, for both sequences" {
    // moment takes Z, +05, +0500 and +05:00 for `Z` and for `ZZ` alike,
    // rather than one form each.
    inline for (.{ "Z", "ZZ" }) |fmt| {
        try std.testing.expectEqual(@as(i32, 0), (try parse(fmt, "Z")).value.offset);
        try std.testing.expectEqual(
            @as(i32, -5 * std.time.s_per_hour),
            (try parse(fmt, "-05:00")).value.offset,
        );
        try std.testing.expectEqual(
            @as(i32, -5 * std.time.s_per_hour),
            (try parse(fmt, "-0500")).value.offset,
        );
        try std.testing.expectEqual(
            @as(i32, -5 * std.time.s_per_hour),
            (try parse(fmt, "-05")).value.offset,
        );
        try std.testing.expectEqual(
            @as(i32, 5 * std.time.s_per_hour + 45 * std.time.s_per_min),
            (try parse(fmt, "+05:45")).value.offset,
        );
    }
}

test "the fields a format string leaves out" {
    // moment walks year, month, day: the fields before the first one the
    // format string speaks for come from the reference, and the ones after
    // it take their lowest value.
    const reference: DateTime = .{ .year = 2001, .month = .Sep, .day = 9 };

    // The year is named, so the month and day are January the first
    // rather than September the ninth.
    const year_only = try parseRelativeTo("YYYY", reference, "2024");
    try std.testing.expectEqual(@as(Year, 2024), year_only.value.year);
    try std.testing.expectEqual(Month.Jan, year_only.value.month);
    try std.testing.expectEqual(@as(Day, 1), year_only.value.day);

    // The month is named but the year is not, so the year comes from the
    // reference and the day drops to the first.
    const month_and_day = try parseRelativeTo("MM-DD", reference, "03-15");
    try std.testing.expectEqual(@as(Year, 2001), month_and_day.value.year);
    try std.testing.expectEqual(Month.Mar, month_and_day.value.month);
    try std.testing.expectEqual(@as(Day, 15), month_and_day.value.day);

    const month_only = try parseRelativeTo("MM", reference, "03");
    try std.testing.expectEqual(@as(Year, 2001), month_only.value.year);
    try std.testing.expectEqual(@as(Day, 1), month_only.value.day);

    // Nothing about the date is named, so all of it is the reference's.
    const time_only = try parseRelativeTo("HH:mm", reference, "14:30");
    try std.testing.expectEqual(@as(Year, 2001), time_only.value.year);
    try std.testing.expectEqual(Month.Sep, time_only.value.month);
    try std.testing.expectEqual(@as(Day, 9), time_only.value.day);
    try std.testing.expectEqual(@as(Hour, 14), time_only.value.hour);
}

test "a day is checked against the month it landed in" {
    // A day number is read before the month it belongs to is necessarily
    // known, so it is checked against 31 there and against the real month
    // afterwards. Without the second check this reached `updateDayOfWeek`
    // and tripped an assertion rather than returning an error.
    try std.testing.expectError(error.ParseError, parse("YYYY-MM-DD", "2024-02-31"));
    try std.testing.expectError(error.ParseError, parse("YYYY-MM-DD", "2025-02-29"));
    try std.testing.expectError(error.ParseError, parse("YYYY-MM-DD", "2024-04-31"));

    // The leap day itself is fine in a leap year.
    _ = try parse("YYYY-MM-DD", "2024-02-29");
}

test "the ordinal day of the month parses" {
    // This arm had never been compiled, because nothing parsed a `Do`.
    const result = try parse("Do MMMM YYYY", "15th March 2024");
    try std.testing.expectEqual(@as(Day, 15), result.value.day);
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);

    try std.testing.expectEqual(@as(Day, 1), (try parse("Do", "1st")).value.day);
    try std.testing.expectEqual(@as(Day, 22), (try parse("Do", "22nd")).value.day);

    // The suffix is required, though which one it is does not matter.
    // Leniently a sequence that matches nowhere is passed over rather than
    // refused, so it takes strict mode to see that.
    try std.testing.expectError(error.ParseError, parseStrict("Do", "15"));
}

test "parseTest" {
    const cases = [_]struct { value: []const u8, fmt: []const u8, expected: DateTime }{
        .{
            .value = "1970",
            .fmt = "YYYY",
            .expected = .{
                .year = 1970,
            },
        },
        .{
            .value = "2001",
            .fmt = "YYYY",
            .expected = .{
                .year = 2001,
                .weekday = .Mon,
            },
        },
        .{
            .value = "70",
            .fmt = "YY",
            .expected = .{
                .year = 1970,
                .weekday = .Thu,
            },
        },
        .{
            .value = "123456789",
            .fmt = "SSSSSSSSS",
            .expected = .{
                .nanosecond = 123456789,
            },
        },
        .{
            .value = "12345678",
            .fmt = "SSSSSSSS",
            .expected = .{
                .nanosecond = 123456780,
            },
        },
        .{
            .value = "1234567",
            .fmt = "SSSSSSS",
            .expected = .{
                .nanosecond = 123456700,
            },
        },
        .{
            .value = "123456",
            .fmt = "SSSSSS",
            .expected = .{
                .nanosecond = 123456000,
            },
        },
        .{
            .value = "12345",
            .fmt = "SSSSS",
            .expected = .{
                .nanosecond = 123450000,
            },
        },
        .{
            .value = "1234",
            .fmt = "SSSS",
            .expected = .{
                .nanosecond = 123400000,
            },
        },
        .{
            .value = "123",
            .fmt = "SSS",
            .expected = .{
                .nanosecond = 123000000,
            },
        },
        .{
            .value = "12",
            .fmt = "SS",
            .expected = .{
                .nanosecond = 120000000,
            },
        },
        .{
            .value = "1",
            .fmt = "S",
            .expected = .{
                .nanosecond = 100000000,
            },
        },
        .{
            .value = "january",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jan,
            },
        },
        .{
            .value = "february",
            .fmt = "MMMM",
            .expected = .{
                .month = .Feb,
                .weekday = .Sun,
            },
        },
        .{
            .value = "march",
            .fmt = "MMMM",
            .expected = .{
                .month = .Mar,
                .weekday = .Sun,
            },
        },
        .{
            .value = "april",
            .fmt = "MMMM",
            .expected = .{
                .month = .Apr,
                .weekday = .Wed,
            },
        },
        .{
            .value = "may",
            .fmt = "MMMM",
            .expected = .{
                .month = .May,
                .weekday = .Fri,
            },
        },
        .{
            .value = "june",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jun,
                .weekday = .Mon,
            },
        },
        .{
            .value = "july",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jul,
                .weekday = .Wed,
            },
        },
        .{
            .value = "august",
            .fmt = "MMMM",
            .expected = .{
                .month = .Aug,
                .weekday = .Sat,
            },
        },
        .{
            .value = "september",
            .fmt = "MMMM",
            .expected = .{
                .month = .Sep,
                .weekday = .Tue,
            },
        },
        .{
            .value = "october",
            .fmt = "MMMM",
            .expected = .{
                .month = .Oct,
                .weekday = .Thu,
            },
        },
        .{
            .value = "november",
            .fmt = "MMMM",
            .expected = .{
                .month = .Nov,
                .weekday = .Sun,
            },
        },
        .{
            .value = "december",
            .fmt = "MMMM",
            .expected = .{
                .month = .Dec,
                .weekday = .Tue,
            },
        },
        .{
            .value = "jan",
            .fmt = "MMM",
            .expected = .{
                .month = .Jan,
                .weekday = .Thu,
            },
        },
        .{
            .value = "feb",
            .fmt = "MMM",
            .expected = .{
                .month = .Feb,
                .weekday = .Sun,
            },
        },
        .{
            .value = "mar",
            .fmt = "MMM",
            .expected = .{
                .month = .Mar,
                .weekday = .Sun,
            },
        },
        .{
            .value = "apr",
            .fmt = "MMM",
            .expected = .{
                .month = .Apr,
                .weekday = .Wed,
            },
        },
        .{
            .value = "may",
            .fmt = "MMM",
            .expected = .{
                .month = .May,
                .weekday = .Fri,
            },
        },
        .{
            .value = "jun",
            .fmt = "MMM",
            .expected = .{
                .month = .Jun,
                .weekday = .Mon,
            },
        },
        .{
            .value = "jul",
            .fmt = "MMM",
            .expected = .{
                .month = .Jul,
                .weekday = .Wed,
            },
        },
        .{
            .value = "aug",
            .fmt = "MMM",
            .expected = .{
                .month = .Aug,
                .weekday = .Sat,
            },
        },
        .{
            .value = "sep",
            .fmt = "MMM",
            .expected = .{
                .month = .Sep,
                .weekday = .Tue,
            },
        },
        .{
            .value = "oct",
            .fmt = "MMM",
            .expected = .{
                .month = .Oct,
                .weekday = .Thu,
            },
        },
        .{
            .value = "nov",
            .fmt = "MMM",
            .expected = .{
                .month = .Nov,
                .weekday = .Sun,
            },
        },
        .{
            .value = "dec",
            .fmt = "MMM",
            .expected = .{
                .month = .Dec,
                .weekday = .Tue,
            },
        },
        // .{
        //     .value = "BC",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "AD",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "BCE",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "CE",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "Before Christ",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "Anno Domini",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "Before Common Era",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "Common Era",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        .{
            .value = "1pm",
            .fmt = "ha",
            .expected = .{
                .hour = 13,
            },
        },
        .{
            .value = "12pm",
            .fmt = "ha",
            .expected = .{
                .hour = 12,
            },
        },
        .{
            .value = "12am",
            .fmt = "ha",
            .expected = .{
                .hour = 0,
            },
        },
        .{
            .value = "1am",
            .fmt = "ha",
            .expected = .{
                .hour = 1,
            },
        },
        // A day of the year names a complete date on its own.
        .{
            .value = "2024-075",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri },
        },
        .{
            .value = "2024-200",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2024, .month = .Jul, .day = 18, .weekday = .Thu },
        },
        .{
            .value = "2024-001",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2024, .month = .Jan, .day = 1, .weekday = .Mon },
        },
        // Day 366 exists in a leap year.
        .{
            .value = "2024-366",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2024, .month = .Dec, .day = 31, .weekday = .Tue },
        },
        // The same ordinal is a different date in a common year.
        .{
            .value = "2025-075",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2025, .month = .Mar, .day = 16, .weekday = .Sun },
        },
        .{
            .value = "2025-365",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2025, .month = .Dec, .day = 31, .weekday = .Wed },
        },
        // Midnight is a valid reading on a 24-hour clock.
        .{
            .value = "2024-03-15T00:30:00",
            .fmt = "YYYY-MM-DDTHH:mm:ss",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 0,
                .minute = 30,
                .weekday = .Fri,
            },
        },
        .{
            .value = "2024-03-15T08:30:00-04:00",
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = -4 * std.time.s_per_hour,
            },
        },
        .{
            .value = "2024-03-15T08:30:00+0545",
            .fmt = "YYYY-MM-DDTHH:mm:ssZZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
            },
        },
        .{
            .value = "2024-03-15T08:30:00Z",
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
        },
    };

    inline for (cases) |case| {
        const actual = try DateTime.parse(case.fmt, case.value);
        try std.testing.expectEqual(case.expected, actual.value);
    }
}

test parseRelativeTo {
    // A format string that names no year gets one from `relative_to`
    // rather than from the epoch, which is what makes syslog timestamps
    // and the like resolvable.
    const relative_to: DateTime = .{ .year = 2024, .month = .Jan, .day = 1 };

    const result = try parseRelativeTo("MMM D HH:mm:ss", relative_to, "Mar 22 12:40:39");
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expectEqual(@as(Day, 22), result.value.day);
    try std.testing.expectEqual(@as(Hour, 12), result.value.hour);

    // A weekday in the input is checked against the date rather than
    // believed, so one that disagrees is a parse error.
    _ = try parseRelativeTo("ddd, D MMM YYYY", relative_to, "Fri, 15 Mar 2024");
    try std.testing.expectError(
        error.ParseError,
        parseRelativeTo("ddd, D MMM YYYY", relative_to, "Mon, 15 Mar 2024"),
    );

    // Sequences that pin down no date cannot be parsed at all. That is
    // settled while the format string is being tokenized, so asking for
    // one is a compile error rather than something to catch here.
}

test "parseRelativeToTest" {
    const cases = [_]struct {
        value: []const u8,
        fmt: []const u8,
        relative_to: DateTime,
        expected: DateTime,
    }{
        .{
            .value = "Mar 22 12:40:39",
            .fmt = "MMM D H:mm:ss",
            .relative_to = .{
                .year = 2025,
                .month = .Jan,
                .day = 1,
                .weekday = .Wed,
            },
            .expected = .{
                .year = 2025,
                .month = .Mar,
                .day = 22,
                .hour = 12,
                .minute = 40,
                .second = 39,
                .weekday = .Sat,
            },
        },
    };

    inline for (cases) |case| {
        const actual = try DateTime.parseRelativeTo(case.fmt, case.relative_to, case.value);
        try std.testing.expectEqual(case.expected, actual.value);
    }
}

test format {
    const datetime: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 5,
        .nanosecond = 123456789,
        .weekday = .Fri,
    };

    var buf: [64]u8 = undefined;

    var iso = std.Io.Writer.fixed(&buf);
    try datetime.format("YYYY-MM-DDTHH:mm:ss", &iso);
    try std.testing.expectEqualStrings("2024-03-15T14:30:05", iso.buffered());

    // Names, ordinals and a 12-hour clock, and a fraction cut to however
    // many digits the sequence asks for.
    var words = std.Io.Writer.fixed(&buf);
    try datetime.format("dddd, Do MMMM YYYY, h:mma", &words);
    try std.testing.expectEqualStrings("Friday, 15th March 2024, 2:30pm", words.buffered());

    var millis = std.Io.Writer.fixed(&buf);
    try datetime.format("ss.SSS", &millis);
    try std.testing.expectEqualStrings("05.123", millis.buffered());
}

test "every format sequence is reachable from format" {
    // `format` unrolls the token list, so a sequence's arm is only ever
    // compiled when some format string uses it. Four of them had never
    // been compiled and did not build; this walks the whole enum so that
    // cannot happen again.
    //
    // 2024-03-15 is a Friday in ISO week 11 of 2024, day 75 of a leap
    // year, quarter 1, at 14:30:05 and a fraction with nine digits, so
    // every sequence has something to say.
    var datetime: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 5,
        .nanosecond = 123456789,
        .offset = -5 * std.time.s_per_hour,
    };
    datetime.updateDayOfWeek();

    var buf: [64]u8 = undefined;
    inline for (@typeInfo(FormatTag).@"enum".fields) |field| {
        var writer = std.Io.Writer.fixed(&buf);
        try datetime.format(field.name, &writer);
        try std.testing.expect(writer.buffered().len > 0);
    }
}

test "the sequences that differ only in padding" {
    // A date and time whose components are all single digit, which is the
    // only way the padded and unpadded spellings can be told apart.
    var datetime: DateTime = .{
        .year = 2024,
        .month = .Jan,
        .day = 3,
        .hour = 5,
        .minute = 7,
        .second = 9,
    };
    datetime.updateDayOfWeek();

    const cases = [_]struct { fmt: []const u8, expected: []const u8 }{
        .{ .fmt = "M-MM", .expected = "1-01" },
        .{ .fmt = "D-DD", .expected = "3-03" },
        .{ .fmt = "H-HH", .expected = "5-05" },
        .{ .fmt = "h-hh", .expected = "5-05" },
        .{ .fmt = "m-mm", .expected = "7-07" },
        .{ .fmt = "s-ss", .expected = "9-09" },
        // 2024-01-03 is a Wednesday in ISO week 1, which is the case the
        // old day-of-year-over-seven arithmetic got wrong: it gave 0.
        .{ .fmt = "w-ww", .expected = "1-01" },
        .{ .fmt = "DDD-DDDD", .expected = "3-003" },
        .{ .fmt = "YY-YYYY", .expected = "24-2024" },
        // `YYY` is not a sequence: it reads as `YY` and then `Y`, which
        // is what moment.js makes of it too.
        .{ .fmt = "YYY", .expected = "242024" },
    };

    inline for (cases) |case| {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try datetime.format(case.fmt, &writer);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "the ordinal sequences of the narrow components" {
    // A quarter and a weekday number are both u3, too narrow to divide by
    // ten, so these arms did not compile until `print.ordinal` was taught
    // to widen.
    var datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15 };
    datetime.updateDayOfWeek();

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try datetime.format("Qo-do", &writer);
    try std.testing.expectEqualStrings("1st-5th", writer.buffered());
}

test "formatTest" {
    const test_date = DateTime{
        .nanosecond = 123456789,
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = .Jan,
        .year = 1970,
        .weekday = .Fri,
    };

    const offset_date = DateTime{
        .second = 6,
        .minute = 55,
        .hour = 9,
        .day = 21,
        .month = .Nov,
        .year = 1997,
        .weekday = .Fri,
        .offset = -6 * std.time.s_per_hour,
    };

    const cases = [_]struct { datetime: DateTime, fmt: []const u8, result: []const u8 }{
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSSS",
            .result = "1970-01-01T00:00:00.123456789",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSS",
            .result = "1970-01-01T00:00:00.12345678",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSS",
            .result = "1970-01-01T00:00:00.1234567",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSS",
            .result = "1970-01-01T00:00:00.123456",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSS",
            .result = "1970-01-01T00:00:00.12345",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSS",
            .result = "1970-01-01T00:00:00.1234",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSS",
            .result = "1970-01-01T00:00:00.123",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SS",
            .result = "1970-01-01T00:00:00.12",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.S",
            .result = "1970-01-01T00:00:00.1",
        },
        .{
            .datetime = test_date,
            .fmt = "h a",
            .result = "12 am",
        },
        .{
            .datetime = test_date,
            .fmt = "h A",
            .result = "12 AM",
        },
        .{
            .datetime = test_date,
            .fmt = "ha",
            .result = "12am",
        },
        .{
            .datetime = test_date,
            .fmt = "HHmm",
            .result = "0000",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .result = "1970-01-01T00:00:00+00:00",
        },
        .{
            .datetime = offset_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .result = "1997-11-21T09:55:06-06:00",
        },
        .{
            .datetime = offset_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZZ",
            .result = "1997-11-21T09:55:06-0600",
        },
        // The RFC 822 form that `rfc822.parse` reads.
        .{
            .datetime = offset_date,
            .fmt = "ddd, DD MMM YYYY HH:mm:ss ZZ",
            .result = "Fri, 21 Nov 1997 09:55:06 -0600",
        },
    };

    inline for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();

        try case.datetime.format(case.fmt, &buf.writer);

        try std.testing.expectEqualStrings(case.result, buf.written());
    }
}

test toUtc {
    const local: DateTime = .{
        .year = 1994,
        .month = .Nov,
        .day = 6,
        .hour = 8,
        .minute = 49,
        .second = 37,
        .weekday = .Sun,
        .offset = -5 * std.time.s_per_hour,
    };

    const utc_time = local.toUtc();
    try std.testing.expectEqual(@as(Hour, 13), utc_time.hour);
    try std.testing.expectEqual(@as(i32, 0), utc_time.offset);

    // The shift rolls over the end of a day, and the weekday is
    // recomputed to match rather than carried across.
    const evening: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 20,
        .weekday = .Fri,
        .offset = -5 * std.time.s_per_hour,
    };
    const next_day = evening.toUtc();
    try std.testing.expectEqual(@as(Day, 16), next_day.day);
    try std.testing.expectEqual(@as(Hour, 1), next_day.hour);
    try std.testing.expectEqual(DayOfWeek.Sat, next_day.weekday);

    // A value that is already UTC is returned untouched.
    try std.testing.expectEqual(utc_time, utc_time.toUtc());
}

test "toUtcTest" {
    const cases = [_]struct { local: DateTime, expected: DateTime }{
        // A whole number of hours, staying within the same day.
        .{
            .local = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 8,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = -5 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 13,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // A positive offset that rolls back over a year boundary.
        .{
            .local = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 30,
                .weekday = .Mon,
                .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
            },
            .expected = .{
                .year = 2023,
                .month = .Dec,
                .day = 31,
                .hour = 18,
                .minute = 45,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // A negative offset that rolls forward over a year boundary.
        .{
            .local = .{
                .year = 2023,
                .month = .Dec,
                .day = 31,
                .hour = 23,
                .minute = 0,
                .weekday = .Sun,
                .offset = -5 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .hour = 4,
                .minute = 0,
                .weekday = .Mon,
                .offset = 0,
            },
        },
        // Leap days are crossed correctly.
        .{
            .local = .{
                .year = 2024,
                .month = .Mar,
                .day = 1,
                .hour = 1,
                .minute = 0,
                .weekday = .Fri,
                .offset = 2 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 2024,
                .month = .Feb,
                .day = 29,
                .hour = 23,
                .minute = 0,
                .weekday = .Thu,
                .offset = 0,
            },
        },
        // Seconds and nanoseconds are carried through, so a leap second
        // survives the shift.
        .{
            .local = .{
                .year = 2017,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 59,
                .second = 60,
                .nanosecond = 123456789,
                .weekday = .Sun,
                .offset = std.time.s_per_hour,
            },
            .expected = .{
                .year = 2016,
                .month = .Dec,
                .day = 31,
                .hour = 23,
                .minute = 59,
                .second = 60,
                .nanosecond = 123456789,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // A value that is already UTC is returned unchanged.
        .{
            .local = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, case.local.toUtc());
        // Converting an already-UTC value again is a no-op.
        try std.testing.expectEqual(case.expected, case.local.toUtc().toUtc());
    }
}

test "day of the year is checked against the length of the year" {
    // 366 only exists in a leap year, and there is no day zero.
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2025-366"));
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2024-367"));
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2024-000"));
}
