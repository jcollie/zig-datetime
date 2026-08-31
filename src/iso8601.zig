// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parser for the date and time representations of ISO 8601, the format
//! behind `2024-03-15T14:30:00Z` and its many relatives. RFC 3339, which
//! is what most internet protocols actually mean by "ISO 8601", is the
//! subset of this that always writes the extended form.
//!
//! Like `rfc822`, this does not go through the comptime format strings,
//! because the shape of the input is not known ahead of it being read.
//! A representation may be a calendar date, an ordinal date or a week
//! date; it may be written in the extended form with separators or the
//! basic form without them; it may stop early at reduced precision; and
//! any of its lowest component may carry a decimal fraction.
//!
//! What is accepted:
//!
//!     2024-03-15              calendar date, extended
//!     20240315                calendar date, basic
//!     2024-03                 reduced to a month
//!     2024                    reduced to a year
//!     2024-075  2024075       ordinal date, day of the year
//!     2024-W11-5  2024W115    week date, ISO week and weekday
//!     2024-W11  2024W11       week date, reduced to a week
//!     ...T14:30:00.5Z         time, fraction, and zone
//!     ...T143000+0530         basic time and zone
//!
//! What is not:
//!
//!   * Expanded years such as `+002024`, which ISO 8601 allows only by
//!     prior agreement between the parties exchanging the data.
//!   * Intervals, durations, and recurring intervals.
//!   * Mixing the basic and extended forms between the date and the time,
//!     which ISO 8601 forbids. The zone is the one deliberate exception;
//!     see `parse`.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Month = @import("month.zig").Month;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const Second = @import("second.zig").Second;
const Year = @import("year.zig").Year;

/// What `parse` can fail with.
pub const ParseError = error{
    /// The input does not start with something shaped like a date.
    ParseError,
    /// A component was outside the range its position allows, such as a
    /// month of 13 or a week of 54.
    OutOfRange,
    /// The date and the time disagreed about the basic or extended form.
    MixedFormats,
    /// A decimal point was not followed by any digits.
    BadFraction,
};

/// How much of the date and time the input actually specified. Everything
/// below this was defaulted: the first month, the first day, and zero for
/// the time of day.
///
/// The three date forms do not share one ladder of precision, so `month`
/// and `week` are alternatives rather than steps: a calendar date reduced
/// to `2024-03` reports `month`, and a week date reduced to `2024-W11`
/// reports `week`. Both mean the same thing, that a day was not named.
pub const Precision = enum {
    year,
    month,
    week,
    day,
    hour,
    minute,
    second,
};

/// What a successful parse yields: the value, how much of the input it
/// came from, and the two things a `DateTime` alone cannot record — that
/// the input said nothing about its offset, and how much of it was
/// defaulted rather than written.
pub const ParseResult = struct {
    /// The prefix of the input that was consumed.
    str: []const u8,
    value: DateTime,
    /// Whether the input carried a zone. When false, `value.offset` is
    /// zero, but only because there was nothing to put there: the input
    /// was a local time that said nothing about its offset from UTC.
    /// ISO 8601 calls this a local time, and it is not the same claim as
    /// a trailing `Z`.
    has_offset: bool,
    /// The smallest component the input named.
    precision: Precision,
};

/// Parses an ISO 8601 date, or date and time, at the start of `value`.
/// Trailing text is left unconsumed; `ParseResult.str` says where the
/// representation ended.
///
/// The date and the time must agree about which form they are written in:
/// ISO 8601 does not allow `2024-03-15T143000`, and neither does this.
/// The zone is deliberately exempt, because `+0530` after an extended
/// time is common in real data and rejecting it would help nobody.
///
/// A time of `24:00` is the end of its date rather than the start, so it
/// is returned as midnight on the following day.
pub fn parse(value: []const u8) ParseError!ParseResult {
    var cursor: Cursor = .{ .text = value };

    // Which form the date was written in, or null when it was too short
    // to say, as a bare `2024` is.
    var extended: ?bool = null;
    var precision: Precision = .year;

    var date = try parseDate(&cursor, &extended, &precision);
    var time: Time = .{};

    if (cursor.eatAny("Tt ")) {
        time = try parseTime(&cursor, &extended, &precision);
        // 24:00 is the end of the day, which is the same instant as
        // midnight starting the next one.
        if (time.end_of_day) {
            date = Date.fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra() + 1);
        }
    }

    var offset: i32 = 0;
    var has_offset = false;
    if (try parseZone(&cursor)) |zone| {
        offset = zone;
        has_offset = true;
    }

    var datetime: DateTime = .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .nanosecond = time.nanosecond,
        .weekday = .Thu,
        .offset = offset,
    };
    datetime.updateDayOfWeek();

    return .{
        .str = value[0..cursor.index],
        .value = datetime,
        .has_offset = has_offset,
        .precision = precision,
    };
}

/// Reads the date, in whichever of the three forms it is written.
fn parseDate(cursor: *Cursor, extended: *?bool, precision: *Precision) ParseError!Date {
    const year: Year = @intCast(try cursor.digits(4));

    if (cursor.eat('-')) {
        extended.* = true;

        if (cursor.eatAny("Ww")) return weekDate(cursor, year, true, precision);

        // `2024-075` is the 75th day of the year, while `2024-07` is a
        // month and `2024-07-05` a month and a day. Only the number of
        // digits tells them apart.
        switch (cursor.digitsAhead()) {
            3 => return ordinalDate(cursor, year, precision),
            2 => {},
            else => return error.ParseError,
        }

        const month = try monthFrom(try cursor.digits(2));
        precision.* = .month;
        if (!cursor.eat('-')) return .{ .year = year, .month = month, .day = 1 };

        const day = try dayFrom(try cursor.digits(2), month, year);
        precision.* = .day;
        return .{ .year = year, .month = month, .day = day };
    }

    if (cursor.eatAny("Ww")) {
        extended.* = false;
        return weekDate(cursor, year, false, precision);
    }

    switch (cursor.digitsAhead()) {
        // A bare year says nothing about which form it is in.
        0 => return .{ .year = year, .month = .Jan, .day = 1 },
        3 => {
            extended.* = false;
            return ordinalDate(cursor, year, precision);
        },
        4 => {
            extended.* = false;
            const month = try monthFrom(try cursor.digits(2));
            const day = try dayFrom(try cursor.digits(2), month, year);
            precision.* = .day;
            return .{ .year = year, .month = month, .day = day };
        },
        // ISO 8601 has no basic `YYYYMM`, because it cannot be told apart
        // from a six digit `YYMMDD`.
        else => return error.ParseError,
    }
}

/// Reads the `DDD` of an ordinal date, the day of its year.
fn ordinalDate(cursor: *Cursor, year: Year, precision: *Precision) ParseError!Date {
    const ordinal = try cursor.digits(3);
    if (ordinal < 1) return error.OutOfRange;

    const length: u32 = if (Month.Feb.lastDay(year) == 29) 366 else 365;
    if (ordinal > length) return error.OutOfRange;

    precision.* = .day;

    var month: Month = .Jan;
    var remaining = ordinal;
    while (remaining > month.lastDay(year)) {
        remaining -= month.lastDay(year);
        month = month.next();
    }
    return .{ .year = year, .month = month, .day = @intCast(remaining) };
}

/// Reads the `Www[-D]` of a week date. `year` is the ISO week-numbering
/// year, which near New Year is not always the calendar year of the date
/// it produces: 2027-W01-1 is 2027-01-04, while 2026-W53-5 is 2027-01-01.
fn weekDate(cursor: *Cursor, year: Year, extended: bool, precision: *Precision) ParseError!Date {
    const week = try cursor.digits(2);
    if (week < 1 or week > isoWeeksInYear(year)) return error.OutOfRange;

    precision.* = .week;

    var weekday: u32 = 1;
    if (extended) {
        if (cursor.eat('-')) {
            weekday = try cursor.digits(1);
            precision.* = .day;
        }
    } else if (cursor.digitsAhead() == 1 or cursor.digitsAhead() == 3) {
        // In the basic form a lone trailing digit is the weekday. Three
        // would mean a weekday followed by something else, which is not
        // a date, so leave it to fail later.
        weekday = try cursor.digits(1);
        precision.* = .day;
    }
    if (weekday < 1 or weekday > 7) return error.OutOfRange;

    // ISO 8601 anchors week 1 as the week containing January 4th.
    const anchor: Date = .{ .year = year, .month = .Jan, .day = 4 };
    const week1_monday = anchor.toDaysSinceStartOfEra() -
        (@as(Date.DaysType, anchor.dayOfWeek().isoWeekdayNumber()) - 1);

    return Date.fromDaysSinceStartOfEra(week1_monday +
        (@as(Date.DaysType, week) - 1) * 7 +
        (@as(Date.DaysType, weekday) - 1));
}

/// The number of ISO weeks in `year`. A year has 53 when it starts on a
/// Thursday, or when it is a leap year starting on a Wednesday, and 52
/// otherwise.
pub fn isoWeeksInYear(year: Year) u8 {
    const first: Date = .{ .year = year, .month = .Jan, .day = 1 };
    const weekday = first.dayOfWeek();
    const leap = Month.Feb.lastDay(year) == 29;

    if (weekday == .Thu) return 53;
    if (leap and weekday == .Wed) return 53;
    return 52;
}

const Time = struct {
    hour: Hour = 0,
    minute: Minute = 0,
    second: Second = 0,
    nanosecond: Nanosecond = 0,
    /// Set when the input read 24:00, which belongs to the end of its
    /// date rather than the start.
    end_of_day: bool = false,
};

/// Reads the time of day, with a decimal fraction on whichever component
/// turns out to be the last one.
fn parseTime(cursor: *Cursor, extended: *?bool, precision: *Precision) ParseError!Time {
    var time: Time = .{};

    const hour = try cursor.digits(2);
    if (hour > 24) return error.OutOfRange;
    precision.* = .hour;

    // A fraction ends the representation, so anything after it is not
    // part of the time.
    if (try cursor.fraction(std.time.ns_per_hour)) |sub| {
        if (hour == 24) return error.OutOfRange;
        time.hour = @intCast(hour);
        time.minute = @intCast(sub / std.time.ns_per_min);
        time.second = @intCast(sub % std.time.ns_per_min / std.time.ns_per_s);
        time.nanosecond = @intCast(sub % std.time.ns_per_s);
        return time;
    }

    const has_more = if (cursor.eat(':')) blk: {
        try agree(extended, true);
        break :blk true;
    } else if (cursor.digitsAhead() >= 2) blk: {
        try agree(extended, false);
        break :blk true;
    } else false;

    if (!has_more) {
        if (hour == 24) {
            time.end_of_day = true;
            return time;
        }
        time.hour = @intCast(hour);
        return time;
    }

    const minute = try cursor.digits(2);
    if (minute > 59) return error.OutOfRange;
    precision.* = .minute;

    if (try cursor.fraction(std.time.ns_per_min)) |sub| {
        if (hour == 24) return error.OutOfRange;
        time.hour = @intCast(hour);
        time.minute = @intCast(minute);
        time.second = @intCast(sub / std.time.ns_per_s);
        time.nanosecond = @intCast(sub % std.time.ns_per_s);
        return time;
    }

    const seconds_follow = if (extended.*.?) cursor.eat(':') else cursor.digitsAhead() >= 2;
    if (!seconds_follow) {
        if (hour == 24) {
            if (minute != 0) return error.OutOfRange;
            time.end_of_day = true;
            return time;
        }
        time.hour = @intCast(hour);
        time.minute = @intCast(minute);
        return time;
    }

    // 60 is allowed so that a leap second parses.
    const second = try cursor.digits(2);
    if (second > 60) return error.OutOfRange;
    precision.* = .second;

    const sub = (try cursor.fraction(std.time.ns_per_s)) orelse 0;

    if (hour == 24) {
        if (minute != 0 or second != 0 or sub != 0) return error.OutOfRange;
        time.end_of_day = true;
        return time;
    }

    time.hour = @intCast(hour);
    time.minute = @intCast(minute);
    time.second = @intCast(second);
    time.nanosecond = @intCast(sub);
    return time;
}

/// Records which form a component was written in, or fails if it
/// contradicts what the representation has used so far.
fn agree(extended: *?bool, is_extended: bool) ParseError!void {
    const known = extended.* orelse {
        extended.* = is_extended;
        return;
    };
    if (known != is_extended) return error.MixedFormats;
}

/// Reads a zone, if one is there. Either spelling of the offset is taken
/// whatever form the rest of the representation used; see `parse`.
fn parseZone(cursor: *Cursor) ParseError!?i32 {
    if (cursor.done()) return null;

    if (cursor.eatAny("Zz")) return 0;

    const sign: i32 = switch (cursor.peek()) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    cursor.index += 1;

    const hours = try cursor.digits(2);
    if (hours > 23) return error.OutOfRange;

    var minutes: u32 = 0;
    if (cursor.eat(':')) {
        minutes = try cursor.digits(2);
    } else if (cursor.digitsAhead() >= 2) {
        minutes = try cursor.digits(2);
    }
    if (minutes > 59) return error.OutOfRange;

    return sign * (@as(i32, @intCast(hours)) * std.time.s_per_hour +
        @as(i32, @intCast(minutes)) * std.time.s_per_min);
}

/// Turns a parsed month number into a `Month`, rejecting 0 and anything
/// past 12.
fn monthFrom(value: u32) ParseError!Month {
    if (value < 1 or value > 12) return error.OutOfRange;
    return std.enums.fromInt(Month, value) orelse unreachable;
}

/// Turns a parsed day number into a `Day`, checking it against the length
/// of the month it falls in, which is why the year is needed as well.
fn dayFrom(value: u32, month: Month, year: Year) ParseError!Day {
    if (value < 1 or value > month.lastDay(year)) return error.OutOfRange;
    return @intCast(value);
}

/// A position in the input, with the small operations the grammar is
/// written in terms of.
///
/// The methods split in two. `eat`, `eatAny` and `digitsAhead` never move
/// the cursor past something they did not accept, and report a refusal by
/// returning rather than by failing; the three date forms are told apart
/// by asking them what is ahead, so nothing here ever has to back up.
/// `digits` and `fraction` commit, and so report a malformed field as an
/// error instead.
const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    /// Whether the input is exhausted.
    fn done(self: Cursor) bool {
        return self.index >= self.text.len;
    }

    /// The character at the cursor. The caller must have checked `done`.
    fn peek(self: Cursor) u8 {
        return self.text[self.index];
    }

    /// Consumes `char` if it is next, and reports whether it was.
    fn eat(self: *Cursor, char: u8) bool {
        if (self.done() or self.peek() != char) return false;
        self.index += 1;
        return true;
    }

    /// Consumes the next character if it is any of `chars`, and reports
    /// whether it was.
    fn eatAny(self: *Cursor, chars: []const u8) bool {
        if (self.done()) return false;
        if (std.mem.indexOfScalar(u8, chars, self.peek()) == null) return false;
        self.index += 1;
        return true;
    }

    /// The length of the run of digits at the cursor.
    fn digitsAhead(self: Cursor) usize {
        var count: usize = 0;
        while (self.index + count < self.text.len and
            std.ascii.isDigit(self.text[self.index + count])) count += 1;
        return count;
    }

    /// Reads exactly `count` digits.
    fn digits(self: *Cursor, count: usize) ParseError!u32 {
        if (self.index + count > self.text.len) return error.ParseError;

        var value: u32 = 0;
        for (self.text[self.index..][0..count]) |char| {
            if (!std.ascii.isDigit(char)) return error.ParseError;
            value = value * 10 + (char - '0');
        }
        self.index += count;
        return value;
    }

    /// Reads a decimal fraction, if one is there, and returns it scaled
    /// to `unit` nanoseconds, so ".5" of a minute is 30 seconds' worth.
    ///
    /// ISO 8601 allows either a comma or a full stop, and says the comma
    /// is preferred. It puts no limit on the number of digits, so any
    /// past the point where they stop moving a nanosecond are read and
    /// discarded.
    fn fraction(self: *Cursor, unit: u64) ParseError!?u64 {
        if (self.done()) return null;
        if (self.peek() != '.' and self.peek() != ',') return null;

        self.index += 1;
        const start = self.index;
        self.index += self.digitsAhead();
        if (self.index == start) return error.BadFraction;

        var numerator: u128 = 0;
        var denominator: u128 = 1;
        for (self.text[start..self.index]) |char| {
            if (denominator > std.math.pow(u128, 10, 15)) break;
            numerator = numerator * 10 + (char - '0');
            denominator *= 10;
        }

        return @intCast(numerator * unit / denominator);
    }
};

const testing = std.testing;

/// Asserts that `input` parses whole, to the given value, offset flag and
/// precision.
fn expectParse(
    input: []const u8,
    expected: DateTime,
    has_offset: bool,
    precision: Precision,
) !void {
    const result = try parse(input);
    try testing.expectEqual(expected, result.value);
    try testing.expectEqual(has_offset, result.has_offset);
    try testing.expectEqual(precision, result.precision);
    // The whole of these inputs is a representation, so all of it should
    // have been consumed.
    try testing.expectEqualStrings(input, result.str);
}

test "calendar dates in both forms" {
    const march15: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    try expectParse("2024-03-15", march15, false, .day);
    try expectParse("20240315", march15, false, .day);

    // Reduced precision fills the missing components with the first of
    // each, and says how far the input actually went.
    try expectParse("2024-03", .{ .year = 2024, .month = .Mar, .day = 1, .weekday = .Fri }, false, .month);
    try expectParse("2024", .{ .year = 2024, .month = .Jan, .day = 1, .weekday = .Mon }, false, .year);

    // A leap day, and the same date in a year that has none.
    try expectParse("2024-02-29", .{ .year = 2024, .month = .Feb, .day = 29, .weekday = .Thu }, false, .day);
    try testing.expectError(error.OutOfRange, parse("2023-02-29"));
}

test "ordinal dates" {
    // Day 75 of a leap year is March 15; of a common year, March 16.
    try expectParse("2024-075", .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri }, false, .day);
    try expectParse("2024075", .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri }, false, .day);
    try expectParse("2025-075", .{ .year = 2025, .month = .Mar, .day = 16, .weekday = .Sun }, false, .day);

    try expectParse("2024-001", .{ .year = 2024, .month = .Jan, .day = 1, .weekday = .Mon }, false, .day);
    try expectParse("2024-366", .{ .year = 2024, .month = .Dec, .day = 31, .weekday = .Tue }, false, .day);

    // 366 exists only in a leap year, and there is no day zero.
    try testing.expectError(error.OutOfRange, parse("2025-366"));
    try testing.expectError(error.OutOfRange, parse("2024-367"));
    try testing.expectError(error.OutOfRange, parse("2024-000"));
}

test "week dates" {
    try expectParse("2024-W11-5", .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri }, false, .day);
    try expectParse("2024W115", .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri }, false, .day);

    // Without a weekday the week starts on its Monday.
    try expectParse("2024-W11", .{ .year = 2024, .month = .Mar, .day = 11, .weekday = .Mon }, false, .week);
    try expectParse("2024W11", .{ .year = 2024, .month = .Mar, .day = 11, .weekday = .Mon }, false, .week);

    // The week-numbering year is not always the calendar year: the last
    // week of 2026 runs into January 2027, and 2027's first week does not
    // begin until the 4th.
    try expectParse("2026-W53-5", .{ .year = 2027, .month = .Jan, .day = 1, .weekday = .Fri }, false, .day);
    try expectParse("2027-W01-1", .{ .year = 2027, .month = .Jan, .day = 4, .weekday = .Mon }, false, .day);
    // And it can run the other way, into the previous December.
    try expectParse("2026-W01-1", .{ .year = 2025, .month = .Dec, .day = 29, .weekday = .Mon }, false, .day);

    try expectParse("2020-W53-7", .{ .year = 2021, .month = .Jan, .day = 3, .weekday = .Sun }, false, .day);
    try expectParse("2015-W53-4", .{ .year = 2015, .month = .Dec, .day = 31, .weekday = .Thu }, false, .day);

    try testing.expectError(error.OutOfRange, parse("2024-W00-1"));
    try testing.expectError(error.OutOfRange, parse("2024-W11-0"));
    try testing.expectError(error.OutOfRange, parse("2024-W11-8"));
}

test "a year has 53 weeks when it starts on a Thursday, or on a Wednesday in a leap year" {
    try testing.expectEqual(@as(u8, 53), isoWeeksInYear(2015)); // starts Thursday
    try testing.expectEqual(@as(u8, 53), isoWeeksInYear(2020)); // starts Wednesday, leap
    try testing.expectEqual(@as(u8, 53), isoWeeksInYear(2026)); // starts Thursday
    try testing.expectEqual(@as(u8, 52), isoWeeksInYear(2016));
    try testing.expectEqual(@as(u8, 52), isoWeeksInYear(2024));
    try testing.expectEqual(@as(u8, 52), isoWeeksInYear(2025)); // starts Wednesday, not leap

    // Week 53 only exists in a year that has one.
    try expectParse("2020-W53-1", .{ .year = 2020, .month = .Dec, .day = 28, .weekday = .Mon }, false, .day);
    try testing.expectError(error.OutOfRange, parse("2025-W53-1"));
    try testing.expectError(error.OutOfRange, parse("2024-W53-1"));
}

test "times, at every precision" {
    const day: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    try expectParse("2024-03-15T14", set(day, 14, 0, 0, 0), false, .hour);
    try expectParse("2024-03-15T14:30", set(day, 14, 30, 0, 0), false, .minute);
    try expectParse("2024-03-15T14:30:45", set(day, 14, 30, 45, 0), false, .second);

    try expectParse("20240315T14", set(day, 14, 0, 0, 0), false, .hour);
    try expectParse("20240315T1430", set(day, 14, 30, 0, 0), false, .minute);
    try expectParse("20240315T143045", set(day, 14, 30, 45, 0), false, .second);

    // A space is accepted where ISO 8601 writes T, as RFC 3339 allows,
    // and the markers may be lower case.
    try expectParse("2024-03-15 14:30:45", set(day, 14, 30, 45, 0), false, .second);
    try expectParse("2024-03-15t14:30:45", set(day, 14, 30, 45, 0), false, .second);

    // A leap second.
    try expectParse("2024-03-15T23:59:60", set(day, 23, 59, 60, 0), false, .second);

    try testing.expectError(error.OutOfRange, parse("2024-03-15T25:00:00"));
    try testing.expectError(error.OutOfRange, parse("2024-03-15T14:60:00"));
    try testing.expectError(error.OutOfRange, parse("2024-03-15T14:30:61"));
}

test "a fraction on whichever component comes last" {
    const day: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    // Half an hour, half a minute, and a quarter of a second.
    try expectParse("2024-03-15T14.5", set(day, 14, 30, 0, 0), false, .hour);
    try expectParse("2024-03-15T14:30.5", set(day, 14, 30, 30, 0), false, .minute);
    try expectParse("2024-03-15T14:30:00.25", set(day, 14, 30, 0, 250000000), false, .second);

    // ISO 8601 prefers the comma and allows the full stop.
    try expectParse("2024-03-15T14:30:00,25", set(day, 14, 30, 0, 250000000), false, .second);

    try expectParse("2024-03-15T14:30:00.123456789", set(day, 14, 30, 0, 123456789), false, .second);
    // Digits past a nanosecond are read and discarded rather than
    // refused, since ISO 8601 puts no limit on how many there may be.
    try expectParse("2024-03-15T14:30:00.123456789012345", set(day, 14, 30, 0, 123456789), false, .second);

    // A fraction of an hour that lands on a second boundary.
    try expectParse("2024-03-15T14.25", set(day, 14, 15, 0, 0), false, .hour);
    // And one that does not.
    try expectParse("2024-03-15T14.1", set(day, 14, 6, 0, 0), false, .hour);

    try testing.expectError(error.BadFraction, parse("2024-03-15T14:30:00."));
    try testing.expectError(error.BadFraction, parse("2024-03-15T14:30:00,"));
}

test "zones" {
    const day: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri };

    // Without a zone the offset is zero, but has_offset says the input
    // never claimed to be UTC.
    try expectParse("2024-03-15T14:30:00", set(day, 14, 30, 0, 0), false, .second);
    try expectParse("2024-03-15T14:30:00Z", set(day, 14, 30, 0, 0), true, .second);
    try expectParse("2024-03-15T14:30:00z", set(day, 14, 30, 0, 0), true, .second);

    try expectParse("2024-03-15T14:30:00+05:30", withOffset(set(day, 14, 30, 0, 0), 19800), true, .second);
    try expectParse("2024-03-15T14:30:00-08:00", withOffset(set(day, 14, 30, 0, 0), -28800), true, .second);
    // The basic spelling of an offset is taken after an extended time,
    // which ISO 8601 does not strictly allow but real data contains.
    try expectParse("2024-03-15T14:30:00+0530", withOffset(set(day, 14, 30, 0, 0), 19800), true, .second);
    // Hours alone.
    try expectParse("2024-03-15T14:30:00+05", withOffset(set(day, 14, 30, 0, 0), 18000), true, .second);

    try testing.expectError(error.OutOfRange, parse("2024-03-15T14:30:00+24:00"));
    try testing.expectError(error.OutOfRange, parse("2024-03-15T14:30:00+05:60"));
}

test "24:00 is the end of its day" {
    // The last moment of the 15th is the same instant as the start of
    // the 16th, which is how it is returned.
    const next: DateTime = .{ .year = 2024, .month = .Mar, .day = 16, .weekday = .Sat };
    try expectParse("2024-03-15T24:00:00", next, false, .second);
    try expectParse("2024-03-15T24:00", next, false, .minute);
    try expectParse("20240315T24", next, false, .hour);

    // It rolls over a month, and a year.
    try expectParse("2024-02-29T24:00", .{ .year = 2024, .month = .Mar, .day = 1, .weekday = .Fri }, false, .minute);
    try expectParse("2024-12-31T24:00", .{ .year = 2025, .month = .Jan, .day = 1, .weekday = .Wed }, false, .minute);

    // Only exactly midnight may be written this way.
    try testing.expectError(error.OutOfRange, parse("2024-03-15T24:00:01"));
    try testing.expectError(error.OutOfRange, parse("2024-03-15T24:30"));
    try testing.expectError(error.OutOfRange, parse("2024-03-15T24.5"));
}

test "the basic and extended forms may not be mixed" {
    try testing.expectError(error.MixedFormats, parse("2024-03-15T143000"));
    try testing.expectError(error.MixedFormats, parse("20240315T14:30:00"));
    try testing.expectError(error.MixedFormats, parse("2024-03-15T1430"));
    try testing.expectError(error.MixedFormats, parse("20240315T14:30"));

    // A bare year commits to neither, so either time form follows it.
    try testing.expect((try parse("2024T14:30")).value.minute == 30);
    try testing.expect((try parse("2024T1430")).value.minute == 30);
}

test "malformed input is rejected" {
    for ([_][]const u8{
        "",
        "abcd",
        "20-03-15",
        // ISO 8601 has no basic YYYYMM, because six digits would be
        // ambiguous with YYMMDD.
        "202403",
        "2024-13-01",
        "2024-00-01",
        "2024-03-32",
        "2024-02-30",
        "2024-03-",
        "2024-W",
        "2024-Wxx",
    }) |bad| {
        try testing.expectError(error.ParseError, parse(bad) catch |err| switch (err) {
            // Either refusal is fine; the point is that none of these parse.
            error.OutOfRange, error.MixedFormats, error.BadFraction => error.ParseError,
            else => err,
        });
    }
}

test "trailing text is left for the caller" {
    const result = try parse("2024-03-15T14:30:00Z and then some");
    try testing.expectEqualStrings("2024-03-15T14:30:00Z", result.str);
    try testing.expectEqual(@as(u5, 14), result.value.hour);
}

/// Returns `base` with the time of day replaced, so that the test cases
/// can name a date once and vary the time against it.
fn set(base: DateTime, hour: Hour, minute: Minute, second: Second, nanosecond: Nanosecond) DateTime {
    var copy = base;
    copy.hour = hour;
    copy.minute = minute;
    copy.second = second;
    copy.nanosecond = nanosecond;
    return copy;
}

/// Returns `base` with the UTC offset replaced.
fn withOffset(base: DateTime, offset: i32) DateTime {
    var copy = base;
    copy.offset = offset;
    return copy;
}
