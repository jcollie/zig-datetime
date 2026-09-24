// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parser for the date and time representations of ISO 8601, the format
//! behind `2024-03-15T14:30:00Z` and its many relatives. RFC 3339, which
//! is what most internet protocols actually mean by "ISO 8601", is the
//! subset of this that always writes the extended form.
//!
//! The text followed is ISO 8601-1:2019 as amended by Amendment 1:2022,
//! and, for the few things this reads that Part 1 does not define,
//! ISO 8601-2:2019. Clause numbers in these doc comments are Part 1's
//! unless they say otherwise.
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
//! `parseDuration` reads `P3Y6M4DT12H30M5S` and its relatives, and
//! `parseInterval` the three forms of a time interval, with a solidus or a
//! double hyphen between the parts and the end abbreviated if it likes, and
//! `parseRecurringInterval` a series of them, `R12/…`.
//!
//! Going the other way, `writeDateTime` and `writeDate` write the extended
//! form in full, which is what the `std.json` hooks on the types write.
//!
//! What ISO 8601 allows and this does not read:
//!
//!   * Expanded years such as `+002024` (5.2.2.3, 5.2.3.2, 5.2.4.3), which
//!     ISO 8601 allows only by agreement between the parties (4.4).
//!   * A date reduced to a decade or a century, `198` or `19` (5.2.2.2 c
//!     and d).
//!   * A time with no date, `T232050` or `23:20:50` (5.3.1, 5.3.3, 5.3.5).
//!   * The alternative `P0003-06-04T12:30:05` form of a duration (5.5.2.4),
//!     which is again by agreement; a fraction of a year, a month or a week
//!     in a duration, which 5.5.2.3 b) allows on the lowest component but
//!     which has no length to divide without a date to measure it from;
//!     and a duration standing alone as an interval (5.5.1, NOTE), whose
//!     start or end is "supplied out of band".
//!   * The repeat rules of ISO 8601-2:2019, clause 13, and the `R0` and
//!     `R-1` counts that neither part defines; see `parseRecurringInterval`.
//!
//! What this reads that ISO 8601 does not allow, on purpose:
//!
//!   * A space between the date and the time, where 3.2.1 says "The
//!     character 'space' shall not be used", and lower-case `t`, `z` and
//!     `p`. RFC 3339, section 5.6, allows both, and a parser of RFC 3339
//!     timestamps has to take them.
//!   * A zone in the basic form after a time in the extended one,
//!     `14:30:00+0530`, although 5.4.3 has the whole expression in one form.
//!     It is common in real data and says nothing ambiguous. Mixing the
//!     forms anywhere else is `error.MixedFormats`.
//!   * `-00:00`, where 4.3.13 writes a zero time shift with a plus sign.
//!     RFC 3339, section 4.3, gives `-00:00` a meaning of its own, and the
//!     instant is the same either way.
//!   * A time reduced to an hour, or to an hour with a fraction, after a
//!     date in the extended form, `2024-03-15T14` or `2024-03-15T14.5`.
//!     5.3.1.3 b) and 5.3.1.4 c) give those only a basic form, so there is
//!     no fully extended way to write them; they are read as agreeing with
//!     whichever form the date was in.
//!   * Weeks beside other components in a duration, `P1W2D`, where 5.5.2.2
//!     b) has `W` stand alone. It says nothing ambiguous.
//!   * The sign ISO 8601-2:2019 puts on a duration, in front (4.4.1.9) or on
//!     each component (14.2); see `parseDuration`.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const Duration = @import("Duration.zig");
const Interval = @import("interval.zig").Interval;
const RecurringInterval = @import("interval.zig").RecurringInterval;
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
///
/// These are the reduced precisions of 5.2.2.2 a) and b), 5.2.4.2, and
/// 5.3.1.3; `hour`, `minute` and `second` may each carry a decimal fraction
/// (5.3.1.4), which is still that precision.
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
    /// ISO 8601 calls this a local time (5.3.1), and it is not the same
    /// claim as a trailing `Z`, which is UTC of day (5.3.3).
    has_offset: bool,
    /// The smallest component the input named.
    precision: Precision,
};

/// What a successful `parseDuration` yields.
pub const DurationParseResult = struct {
    /// The prefix of the input that was consumed.
    str: []const u8,
    value: Duration,
    /// The designator of the component that carried a decimal fraction, or
    /// null when none did.
    ///
    /// ISO 8601-1:2019, 5.5.2.3 b), allows it only on the lowest-order
    /// component present, which `parseDuration` enforces; this says which
    /// one that was.
    ///
    /// It is reported because a caller may be stricter than ISO 8601 about
    /// where a fraction may appear. XML Schema's `duration`, for one, allows
    /// a fraction only on the seconds, so `P1.5D` is a perfectly good ISO
    /// 8601 duration and not a valid `xs:duration` — and once the fraction
    /// has been folded into `nanoseconds` there is no way to tell which
    /// component it came from.
    fractional: ?u8 = null,
};

/// Parses an ISO 8601 duration at the start of `value`: `P3Y6M4DT12H30M5S`,
/// `PT30M`, `P2W`, `-P1D`, `P1M-1D`.
///
/// The grammar is ISO 8601-1:2019, 5.5.2: a `P`, then years, months and
/// days, then a `T` and hours, minutes and seconds, each a number and its
/// designator, in that order (5.5.2.2 a), or a number of weeks alone
/// (5.5.2.2 b). A component that is zero may be left out, but at least one
/// has to be there (5.5.2.3 a), and a `T` has to have something after it.
/// Weeks are also read beside the other components, which 5.5.2.2 does not
/// have; see the module's doc comment.
///
/// A sign may go in either of two places, and not both. In front of the `P`
/// it reverses the whole duration, which is ISO 8601-2:2019, 4.4.1.9; that
/// clause asks every component after it to be positive, so `-P1Y-2M` is
/// refused. In front of a component's digits it makes that component
/// alone negative, which is how ISO 8601-2:2019, 14.2, writes the result of
/// adding two composite durations component by component — `P3Y15M3DT-10M`
/// is its own example. That is the only way to write a duration whose
/// fields disagree in sign, which is what `Duration.format` writes for one.
/// A `+` is accepted in front of the `P`, as before, and nowhere else; it
/// is in neither part, and changes nothing.
///
/// Years fold into the duration's months and weeks into its days, since
/// those two conversions are exact: ISO 8601-2:2019/Amd 1:2025, 14.6,
/// names them "unequivocally convertible", where months and days, or years
/// and days, are not. A decimal fraction is allowed on any
/// component that can carry one exactly — days and below — and refused on
/// years and months, which have no fixed length to divide. Only the
/// lowest-order component present may carry one, as ISO 8601-1:2019,
/// 5.5.2.3 b) says, so `PT1.5H30M` is `error.BadFraction`, and
/// `DurationParseResult.fractional` says which component did, so that a
/// stricter caller can refuse it.
///
/// Trailing text is left unconsumed, as with `parse`.
pub fn parseDuration(value: []const u8) ParseError!DurationParseResult {
    var cursor: Cursor = .{ .text = value };

    const negative = cursor.eat('-');
    if (!negative) _ = cursor.eat('+');
    if (!cursor.eatAny("Pp")) return error.ParseError;

    var result: DurationParseResult = .{ .str = &.{}, .value = .{} };
    var count: usize = 0;
    var any_negative = false;
    // Only the lowest-order component present may carry a fraction, ISO
    // 8601-1:2019, 5.5.2.3 b): "The lowest order component may have a
    // decimal fraction". So once one has, nothing may follow it.
    var fraction_seen = false;

    // The date part, whose `M` means months. `W` is an alternative to the
    // whole of it rather than one more component, but accepting it alongside
    // the others costs nothing and rejecting it would only turn a duration
    // somebody wrote into an error.
    var in_time = cursor.eatAny("Tt");
    if (!in_time) {
        while (try component(&cursor)) |c| {
            if (fraction_seen) return error.BadFraction;
            count += 1;
            any_negative = any_negative or c.negative;
            if (c.fraction.len != 0) {
                result.fractional = c.designator;
                fraction_seen = true;
            }
            switch (c.designator) {
                // A fraction of a year or a month is a length of time nobody
                // can name in days, so it is refused rather than guessed at.
                'Y' => {
                    if (c.fraction.len != 0) return error.BadFraction;
                    result.value.months = try add(result.value.months, try c.wholeIn(12));
                },
                'M' => {
                    if (c.fraction.len != 0) return error.BadFraction;
                    result.value.months = try add(result.value.months, try c.wholeIn(1));
                },
                'W' => {
                    if (c.fraction.len != 0) return error.BadFraction;
                    result.value.days = try add(result.value.days, try c.wholeIn(7));
                },
                'D' => {
                    result.value.days = try add(result.value.days, try c.wholeIn(1));
                    // Only the fraction goes to the sub-day part: the whole
                    // days are counted above.
                    const fraction = scaleFraction(c.fraction, Duration.nanoseconds_per_day);
                    result.value.nanoseconds = try addNanoseconds(
                        result.value.nanoseconds,
                        if (c.negative) -fraction else fraction,
                    );
                },
                else => return error.ParseError,
            }
            if (c.designator == 'D') break;
        }
        in_time = cursor.eatAny("Tt");
    }

    // The time part, whose `M` means minutes.
    if (in_time) {
        var time_count: usize = 0;
        while (try component(&cursor)) |c| {
            if (fraction_seen) return error.BadFraction;
            count += 1;
            time_count += 1;
            any_negative = any_negative or c.negative;
            if (c.fraction.len != 0) {
                result.fractional = c.designator;
                fraction_seen = true;
            }
            const unit: i128 = switch (c.designator) {
                'H' => Duration.nanoseconds_per_hour,
                'M' => Duration.nanoseconds_per_minute,
                'S' => Duration.nanoseconds_per_second,
                else => return error.ParseError,
            };
            result.value.nanoseconds = try addNanoseconds(
                result.value.nanoseconds,
                try c.nanosecondsIn(unit),
            );
            if (c.designator == 'S') break;
        }
        // `P1DT` is not a duration: the designator promises a time part.
        if (time_count == 0) return error.ParseError;
    }

    // `P` on its own is not a duration either.
    if (count == 0) return error.ParseError;

    // A sign on the whole and a sign on a component together: ISO 8601-2
    // asks for the components of a negative duration to be positive.
    if (negative and any_negative) return error.ParseError;

    if (negative) result.value = result.value.negate();
    result.str = value[0..cursor.index];
    return result;
}

test parseDuration {
    const cases = [_]struct { []const u8, Duration }{
        .{ "P1Y", .{ .months = 12 } },
        .{ "P1Y6M", .{ .months = 18 } },
        .{ "P3Y6M4DT12H30M5S", .{
            .months = 42,
            .days = 4,
            .nanoseconds = 12 * Duration.nanoseconds_per_hour +
                30 * Duration.nanoseconds_per_minute +
                5 * Duration.nanoseconds_per_second,
        } },
        .{ "PT30M", .{ .nanoseconds = 30 * Duration.nanoseconds_per_minute } },
        .{ "P2W", .{ .days = 14 } },
        .{ "PT0S", .{} },
        .{ "-P1D", .{ .days = -1 } },
        .{ "+P1D", .{ .days = 1 } },
        .{ "PT1.5S", .{ .nanoseconds = 3 * Duration.nanoseconds_per_second / 2 } },
        .{ "PT1,5S", .{ .nanoseconds = 3 * Duration.nanoseconds_per_second / 2 } },
        .{ "P1.5D", .{ .days = 1, .nanoseconds = Duration.nanoseconds_per_day / 2 } },
        .{ "P0D", .{} },
        // A sign on a component, which is how ISO 8601-2 writes a duration
        // whose fields disagree; its own example is the second.
        .{ "P1M-1D", .{ .months = 1, .days = -1 } },
        .{ "P3Y15M3DT-10M", .{ .months = 51, .days = 3, .nanoseconds = -10 * Duration.nanoseconds_per_minute } },
        .{ "P-1Y-2M3D", .{ .months = -14, .days = 3 } },
        .{ "P1DT-1.5S", .{ .days = 1, .nanoseconds = -3 * Duration.nanoseconds_per_second / 2 } },
        .{ "P-1.5D", .{ .days = -1, .nanoseconds = -Duration.nanoseconds_per_day / 2 } },
    };
    for (cases) |case| {
        const got = try parseDuration(case[0]);
        std.testing.expect(got.value.eql(case[1])) catch |err| {
            std.debug.print("{s}: {any}\n", .{ case[0], got.value });
            return err;
        };
        try std.testing.expectEqualStrings(case[0], got.str);
    }

    // Which component carried the fraction, for a caller that allows fewer
    // of them than ISO 8601 does.
    try std.testing.expectEqual(@as(?u8, 'S'), (try parseDuration("PT1.5S")).fractional);
    try std.testing.expectEqual(@as(?u8, 'D'), (try parseDuration("P1.5D")).fractional);
    try std.testing.expectEqual(@as(?u8, null), (try parseDuration("P1D")).fractional);

    // Trailing text is left, as with `parse`.
    try std.testing.expectEqualStrings("P1D", (try parseDuration("P1D and more")).str);

    // None of these is a duration. Which error each gives is not the point
    // -- `BadFraction` is as much a refusal as `ParseError` -- so the check
    // is only that none of them parses.
    for ([_][]const u8{
        "",      "1D",        "P",        "-P",      "PT",
        "P1DT",  "P1X",       "PTS",      "P.5D",
        // A year, month or week has no fixed length, so a fraction of one is
        // not a duration this can represent.
           "P0.5Y",
        "P0.5M", "P0.5W",
        // A decimal point with no digits after it.
            "PT1.S",
        // A sign on the whole and on a component: ISO 8601-2 asks for the
        // components of a negative duration to be positive.
           "-P1Y-2M",
        // A sign that is not a minus, or one with nothing after it.
        "P+1D",
        "P-D",
        // A fraction on a component that is not the lowest one present,
        // within a part and across the `T`.
          "PT1.5H30M", "P1.5DT1H",
    }) |bad| {
        std.testing.expect(std.meta.isError(parseDuration(bad))) catch |err| {
            std.debug.print("parsed but should not have: \"{s}\"\n", .{bad});
            return err;
        };
    }
}

/// One `<number><designator>` of a duration, with the digits of its decimal
/// fraction kept apart because what they are worth depends on the
/// designator that follows them.
const Component = struct {
    whole: u64,
    fraction: []const u8,
    designator: u8,
    /// Whether a minus sign stood in front of the digits.
    negative: bool = false,

    /// The whole part as a signed count of `unit`.
    fn wholeIn(self: Component, unit: i64) ParseError!i64 {
        const value = try mul(self.whole, unit);
        return if (self.negative) -value else value;
    }

    /// The whole part and the fraction together, as a signed count of
    /// nanoseconds of a `unit` of that many nanoseconds.
    fn nanosecondsIn(self: Component, unit: i128) ParseError!i128 {
        const value = try addNanoseconds(try mulNanoseconds(self.whole, unit), scaleFraction(self.fraction, unit));
        return if (self.negative) -value else value;
    }
};

fn component(cursor: *Cursor) ParseError!?Component {
    // A minus sign counts only when digits follow it. Otherwise it is not
    // part of the duration at all, and is left, like anything else after
    // the last component, for the caller.
    var negative = false;
    if (!cursor.done() and cursor.peek() == '-' and
        cursor.index + 1 < cursor.text.len and std.ascii.isDigit(cursor.text[cursor.index + 1]))
    {
        negative = true;
        cursor.index += 1;
    }

    const whole_len = cursor.digitsAhead();
    if (whole_len == 0) return null;

    var whole: u64 = 0;
    for (cursor.text[cursor.index..][0..whole_len]) |char| {
        whole = std.math.mul(u64, whole, 10) catch return error.OutOfRange;
        whole = std.math.add(u64, whole, char - '0') catch return error.OutOfRange;
    }
    cursor.index += whole_len;

    var fraction: []const u8 = &.{};
    if (!cursor.done() and (cursor.peek() == '.' or cursor.peek() == ',')) {
        cursor.index += 1;
        const start = cursor.index;
        cursor.index += cursor.digitsAhead();
        if (cursor.index == start) return error.BadFraction;
        fraction = cursor.text[start..cursor.index];
    }

    if (cursor.done()) return error.ParseError;
    const designator = cursor.peek();
    cursor.index += 1;
    return .{ .whole = whole, .fraction = fraction, .designator = designator, .negative = negative };
}

/// The digits after a decimal point, as a count of nanoseconds of `unit`.
/// Digits past the point where they can no longer move a nanosecond are read
/// and discarded, as in `Cursor.fraction`.
fn scaleFraction(digits: []const u8, unit: i128) i128 {
    var numerator: i128 = 0;
    var denominator: i128 = 1;
    for (digits) |char| {
        if (denominator > std.math.pow(i128, 10, 15)) break;
        numerator = numerator * 10 + (char - '0');
        denominator *= 10;
    }
    return @divTrunc(numerator * unit, denominator);
}

fn cast(whole: u64) ParseError!i64 {
    return std.math.cast(i64, whole) orelse error.OutOfRange;
}

fn mul(whole: u64, by: i64) ParseError!i64 {
    return std.math.mul(i64, try cast(whole), by) catch error.OutOfRange;
}

fn mulNanoseconds(whole: u64, unit: i128) ParseError!i128 {
    return std.math.mul(i128, whole, unit) catch error.OutOfRange;
}

/// Each component of a duration is checked as it is read, and the *running
/// total* has to be checked too: `P9000000000000000000Y` overflows on its
/// own, but so does a year count and a month count that each fit and together
/// do not.
fn add(total: i64, term: i64) ParseError!i64 {
    return std.math.add(i64, total, term) catch error.OutOfRange;
}

fn addNanoseconds(total: i128, term: i128) ParseError!i128 {
    return std.math.add(i128, total, term) catch error.OutOfRange;
}

/// Parses an ISO 8601 date, or date and time, at the start of `value`.
/// Trailing text is left unconsumed; `ParseResult.str` says where the
/// representation ended.
///
/// It reads a date in any of the three forms of 5.2 — calendar (5.2.2),
/// ordinal (5.2.3) or week (5.2.4) — complete or reduced, and optionally a
/// `T` and a time of day after it (5.4), with a time shift after that
/// (5.3.4.2) or `Z` for UTC of day (5.3.3). Only a complete date may have
/// a time after it, as 5.4.1 requires, and only a time may have a time
/// shift after it; a `Z` after a bare date is left as trailing text.
///
/// The date and the time must agree about which form they are written in,
/// basic or extended (5.4.3): ISO 8601 does not allow `2024-03-15T143000`,
/// and neither does this. The zone is deliberately exempt, because `+0530`
/// after an extended time is common in real data and rejecting it would
/// help nobody; the module's doc comment lists this and the other things
/// read on purpose that ISO 8601 does not allow.
///
/// A time of `24:00` is the ending of its day, which ISO 8601-1:2019/Amd
/// 1:2022, 5.3.2, defines as the same instant as the beginning of the next
/// and says should be read as that "for processing". So it is returned as
/// midnight on the following day.
pub fn parse(value: []const u8) ParseError!ParseResult {
    return (try parseMarkingZone(value)).result;
}

/// `parse`, also saying where in `result.str` the zone began, which is
/// `result.str.len` when there was none. An abbreviated interval end takes
/// its missing components from the start's text, and the start's zone is
/// not one of the things it can take.
fn parseMarkingZone(value: []const u8) ParseError!Marked {
    var cursor: Cursor = .{ .text = value };

    // Which form the date was written in, or null when it was too short
    // to say, as a bare `2024` is.
    var extended: ?bool = null;
    var precision: Precision = .year;

    var date = try parseDate(&cursor, &extended, &precision);
    var time: Time = .{};

    // A `T` promises a time, so what follows it has to be one. A space
    // promises nothing: it is RFC 3339's stand-in for the `T`, but it is
    // also the most ordinary way for a date to end and prose to begin. So
    // it is taken as the separator only when a digit follows it, which
    // leaves `2024-03-15 and more` as a date and trailing text rather than
    // an error, while `2024-03-15 25:00` is still an hour out of range
    // rather than a date with something odd after it.
    //
    // Only a complete date may have a time after it: ISO 8601-1:2019,
    // 5.4.1, "The date part of a date and time expression shall be
    // complete". `2024-03T10:15` would be a time on no particular day, so
    // a `T` after a reduced date is refused, and a space after one is not
    // taken for a separator at all.
    const spaced = precision == .day and
        cursor.index + 1 < cursor.text.len and
        cursor.text[cursor.index] == ' ' and
        std.ascii.isDigit(cursor.text[cursor.index + 1]);
    var has_time = false;
    if (cursor.eatAny("Tt") or (spaced and cursor.eat(' '))) {
        if (precision != .day) return error.ParseError;
        has_time = true;
        time = try parseTime(&cursor, &extended, &precision);
        // 24:00 is the end of the day, which is the same instant as
        // midnight starting the next one.
        if (time.end_of_day) {
            date = Date.fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra() + 1);
        }
    }

    // A time shift belongs to a time of day, never to a date alone: ISO
    // 8601-1:2019, 4.3.13 and 5.3.4.2, appends it "to the local time of
    // day", and Amendment 1:2022 rewrote the one example in 5.5.1 that had
    // put it after a bare date. So after a date with no time, a `Z` or an
    // offset is not read, and is left with the rest of the text.
    const zone_start = cursor.index;
    var offset: i32 = 0;
    var has_offset = false;
    if (has_time) {
        if (try parseZone(&cursor)) |zone| {
            offset = zone;
            has_offset = true;
        }
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
        .result = .{
            .str = value[0..cursor.index],
            .value = datetime,
            .has_offset = has_offset,
            .precision = precision,
        },
        .zone_start = zone_start,
        .extended = extended,
    };
}

/// What `parseMarkingZone` yields beyond a `ParseResult`.
const Marked = struct {
    result: ParseResult,
    /// Where in `result.str` the zone began, or `result.str.len` for none.
    zone_start: usize,
    /// Whether the date and time were in the extended form, or null when
    /// the text was too short to say, as a bare `2024` is. An interval's two
    /// ends are held to the same form by comparing these.
    extended: ?bool,
};

test parseMarkingZone {
    const zoned = try parseMarkingZone("2024-03-15T14:30-05:00");
    try std.testing.expectEqualStrings("2024-03-15T14:30", zoned.result.str[0..zoned.zone_start]);

    const local = try parseMarkingZone("2024-03-15T14:30");
    try std.testing.expectEqual(local.result.str.len, local.zone_start);
}

/// Reads the date, in whichever of the three forms it is written: a
/// calendar date (5.2.2.1), reduced to a month or a year (5.2.2.2 a and
/// b); an ordinal date (5.2.3.1); or a week date (5.2.4.1), reduced to a
/// week (5.2.4.2). The year is always four digits (4.3.2), so the expanded
/// forms are not read.
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

/// Reads the `DDD` of an ordinal date, the day of its year: `001` to `365`,
/// or `366` in a leap year (4.3.7, and Table 1 for where each month
/// begins).
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

test ordinalDate {
    // Day 75 of 2024, which is a leap year, so the count reaches March 15
    // rather than the 16th.
    var precision: Precision = .year;
    var cursor: Cursor = .{ .text = "075" };
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try ordinalDate(&cursor, 2024, &precision),
    );
    try std.testing.expectEqual(Precision.day, precision);

    // 366 is a day in a leap year and not in an ordinary one.
    var last: Cursor = .{ .text = "366" };
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Dec, .day = 31 },
        try ordinalDate(&last, 2024, &precision),
    );

    var overrun: Cursor = .{ .text = "366" };
    try std.testing.expectError(error.OutOfRange, ordinalDate(&overrun, 2025, &precision));
}

/// Reads the `Www[-D]` of a week date. `year` is the ISO week-numbering
/// year, which near New Year is not always the calendar year of the date
/// it produces: 2027-W01-1 is 2027-01-04, while 2026-W53-5 is 2027-01-01.
///
/// The week calendar is 4.2.2; the week is `01` to `52` or `53` (4.3.4)
/// and the weekday `1` for Monday to `7` for Sunday (4.3.6, Table 2).
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

test weekDate {
    var precision: Precision = .year;

    // Week 11 of 2024, day 5, is Friday 15 March.
    var cursor: Cursor = .{ .text = "11-5" };
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try weekDate(&cursor, 2024, true, &precision),
    );
    try std.testing.expectEqual(Precision.day, precision);

    // The week-numbering year is not always the calendar year of the date
    // it produces: the first week of 2027 starts in the January that
    // follows 2026's 53rd week.
    var spanning: Cursor = .{ .text = "53-5" };
    try std.testing.expectEqual(
        Date{ .year = 2027, .month = .Jan, .day = 1 },
        try weekDate(&spanning, 2026, true, &precision),
    );

    // Naming no day leaves the week as the precision, and the date on the
    // Monday the week starts with.
    var reduced: Cursor = .{ .text = "11" };
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 11 },
        try weekDate(&reduced, 2024, true, &precision),
    );
    try std.testing.expectEqual(Precision.week, precision);
}

/// The number of ISO weeks in `year`. A year has 53 when it starts on a
/// Thursday, or when it is a leap year starting on a Wednesday, and 52
/// otherwise: the "52 or 53, depending on the number of calendar weeks in
/// that calendar year" of 4.3.4.
pub fn isoWeeksInYear(year: Year) u8 {
    const first: Date = .{ .year = year, .month = .Jan, .day = 1 };
    const weekday = first.dayOfWeek();
    const leap = Month.Feb.lastDay(year) == 29;

    if (weekday == .Thu) return 53;
    if (leap and weekday == .Wed) return 53;
    return 52;
}

test isoWeeksInYear {
    // 2026 begins on a Thursday, so it has a 53rd week.
    try std.testing.expectEqual(@as(u8, 53), isoWeeksInYear(2026));

    // 2020 is a leap year beginning on a Wednesday, the other way to get
    // one, since the extra day pushes a Thursday into the final week.
    try std.testing.expectEqual(@as(u8, 53), isoWeeksInYear(2020));

    try std.testing.expectEqual(@as(u8, 52), isoWeeksInYear(2024));
    try std.testing.expectEqual(@as(u8, 52), isoWeeksInYear(2025));
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
///
/// A complete time is 5.3.1.2, a reduced one 5.3.1.3, and the fraction
/// 5.3.1.4, with either a comma or a full stop as the decimal sign (3.2.6).
/// The hour is `00` to `23` (4.3.8), the minute `00` to `59` (4.3.9), and
/// the second `00` to `60`, the last for a positive leap second (4.3.10).
/// The one hour past 23 is the ending of the
/// day, `24:00`, with nothing after it but zeroes (Amendment 1:2022,
/// 5.3.2).
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
/// contradicts what the representation has used so far: 5.4.3's "The entire
/// expression shall either be completely in basic format or completely in
/// extended format".
fn agree(extended: *?bool, is_extended: bool) ParseError!void {
    const known = extended.* orelse {
        extended.* = is_extended;
        return;
    };
    if (known != is_extended) return error.MixedFormats;
}

test agree {
    // The first component to say which form it is in settles it.
    var extended: ?bool = null;
    try agree(&extended, true);
    try std.testing.expectEqual(@as(?bool, true), extended);

    // Saying the same thing again is fine; contradicting it is not.
    try agree(&extended, true);
    try std.testing.expectError(error.MixedFormats, agree(&extended, false));
}

/// Reads a zone, if one is there. Either spelling of the offset is taken
/// whatever form the rest of the representation used; see `parse`.
///
/// A zone is `Z` or a time shift (4.3.13): a sign, two digits of hour and,
/// optionally, two of minute, with a colon between them in the extended
/// form (5.3.4.1). The hour is a clock hour, `00` to `23` (4.3.8).
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

test parseZone {
    // Zulu is UTC.
    var zulu: Cursor = .{ .text = "Z" };
    try std.testing.expectEqual(@as(?i32, 0), try parseZone(&zulu));

    // Both spellings of an offset are accepted whatever form the rest of
    // the representation was written in.
    var extended: Cursor = .{ .text = "-05:00" };
    try std.testing.expectEqual(@as(?i32, -5 * std.time.s_per_hour), try parseZone(&extended));

    var basic: Cursor = .{ .text = "+0545" };
    try std.testing.expectEqual(
        @as(?i32, 5 * std.time.s_per_hour + 45 * std.time.s_per_min),
        try parseZone(&basic),
    );

    // Null means the input named no zone, which is not the same as UTC.
    var absent: Cursor = .{ .text = "" };
    try std.testing.expectEqual(@as(?i32, null), try parseZone(&absent));
}

/// Turns a parsed month number into a `Month`, rejecting 0 and anything
/// past 12: `01` to `12` (4.3.3).
fn monthFrom(value: u32) ParseError!Month {
    if (value < 1 or value > 12) return error.OutOfRange;
    return std.enums.fromInt(Month, value) orelse unreachable;
}

test monthFrom {
    try std.testing.expectEqual(Month.Jan, try monthFrom(1));
    try std.testing.expectEqual(Month.Dec, try monthFrom(12));

    try std.testing.expectError(error.OutOfRange, monthFrom(0));
    try std.testing.expectError(error.OutOfRange, monthFrom(13));
}

/// Turns a parsed day number into a `Day`, checking it against the length
/// of the month it falls in, which is why the year is needed as well:
/// `01` to `28`, `29`, `30` or `31` (4.3.5, Table 1).
fn dayFrom(value: u32, month: Month, year: Year) ParseError!Day {
    if (value < 1 or value > month.lastDay(year)) return error.OutOfRange;
    return @intCast(value);
}

test dayFrom {
    try std.testing.expectEqual(@as(Day, 31), try dayFrom(31, .Jan, 2024));

    // The month and year are needed because the limit moves with them.
    try std.testing.expectEqual(@as(Day, 29), try dayFrom(29, .Feb, 2024));
    try std.testing.expectError(error.OutOfRange, dayFrom(29, .Feb, 2025));
    try std.testing.expectError(error.OutOfRange, dayFrom(31, .Apr, 2024));
    try std.testing.expectError(error.OutOfRange, dayFrom(0, .Jan, 2024));
}

/// What a successful `parseInterval` yields.
pub const IntervalParseResult = struct {
    /// The prefix of the input that was consumed.
    str: []const u8,
    value: Interval,
    /// What `parse` reported of the start, or null when the interval began
    /// with a duration.
    start: ?Endpoint = null,
    /// What `parse` reported of the end, or null when the interval ended
    /// with a duration. An abbreviated end reports the precision it was read
    /// at once completed from the start, which is always the start's.
    end: ?Endpoint = null,
    /// `DurationParseResult.fractional`, for whichever part was a duration.
    fractional: ?u8 = null,

    /// The two things `ParseResult` records beside the value, which an
    /// `Interval` holding plain `DateTime`s cannot.
    pub const Endpoint = struct {
        /// Whether the endpoint carried a zone, or took the start's.
        has_offset: bool,
        /// The smallest component the endpoint named.
        precision: Precision,
    };
};

/// Parses an ISO 8601 time interval at the start of `value`, in any of the
/// three forms `Interval` holds, which are the three of ISO 8601-1:2019,
/// 5.5.1 a) to c), and their complete representations 5.5.3.1 to 5.5.3.3:
///
///     2007-03-01T13:00:00Z/2008-05-11T15:30:00Z
///     2007-03-01T13:00:00Z/P1Y2M10DT2H30M
///     P1Y2M10DT2H30M/2008-05-11T15:30:00Z
///
/// The two parts are separated by a solidus (5.5.1), or by the double
/// hyphen `--` that may replace it "by mutual agreement" (3.2.6, NOTE),
/// which is for where a solidus cannot go, a file name for one. The
/// separator is found first, at whichever of the two comes earlier, and the
/// first part has to be exactly what comes before it. That is what lets a
/// reduced start such as `2024-03--2024-04` be read at all: `parse` on its
/// own would take the hyphen after the month as the promise of a day.
///
/// **The end may be abbreviated.** 5.5.1 lets it leave out any of its
/// higher-order components, which it then takes from the start, "provided
/// that the resulting expression is unambiguous"; its own example is
/// `2018-01-15/02-20`. So
/// `2007-12-14T13:30/15:30` ends at half past three the same afternoon and
/// `2008-02-15/03-14` a month later. This is read by laying the end over
/// the tail of the start's text: each point in the start where one
/// component ends and the next begins — after a `-`, `:`, `T` or `W` — is
/// tried as the place the end's text starts, and the completed text is
/// parsed. A splice counts only when it reads to the same precision as the
/// start, since the end replaces the start's lowest components rather than
/// adding new ones; of those that do, the one that consumes the most of the
/// end wins, which is what tells `03-14` as a month and day from `03` as a
/// day followed by trailing text, and a tie goes to the earliest splice. A
/// full end is tried alongside, and preferred only when it consumes more.
///
/// **An end without a zone is in the start's**, abbreviated or not. 5.5.1,
/// as Amendment 1:2022 restates it, says a time shift written with the
/// part before the separator applies to the part after it unless that part
/// has its own, and its example makes
/// `2018-01-15T12:00:00+05:00/2018-02-20T12:00:00` end at `+05:00`. So the
/// end's `has_offset` reports true when it took the start's zone, since the
/// text did give one, once.
///
/// **Both ends are in one form**, basic or extended, as 5.5.3.1 requires:
/// `1985-04-12T23:20:50/19850625T103000` is `error.MixedFormats`. An end
/// too short to have a form, a bare year, agrees with either.
///
/// The splice is at component separators only, so an end abbreviated from
/// a start in the basic form can leave out the date, after the `T`, and
/// nothing finer: `20080215/0314` is not read as a month later, because
/// without separators there is no telling where in `20080215` the `0314`
/// should go. Such an end is not an error but a full representation, here
/// the year 314, which then fails the check below.
///
/// The interval has to run forwards. An end before its start, compared as
/// instants, is `error.OutOfRange`; an interval of no length is not. A
/// duration cannot carry a sign here, and cannot have a negative component:
/// ISO 8601-1 writes an interval's duration with no sign at all (5.5.2),
/// and the signs are ISO 8601-2's (4.4.1.9, 14.2); see `forwards`. A duration that would carry the other
/// endpoint outside the years a `Year` can hold is `error.OutOfRange`
/// too, which is what makes `Interval.start` and `end` safe to call on
/// anything this returns.
///
/// A recurring interval, `R5/…`, is `parseRecurringInterval`'s. A bare
/// duration is not read: 5.5.1's NOTE counts one as an interval only when
/// its start or end is "supplied out of band", and there is no band here
/// to supply it.
///
/// Trailing text after the second part is left unconsumed, as with `parse`.
pub fn parseInterval(value: []const u8) ParseError!IntervalParseResult {
    const separator = findSeparator(value) orelse return error.ParseError;
    const first = value[0..separator.index];
    const second = value[separator.index + separator.len ..];
    const consumed = separator.index + separator.len;

    // Duration, then end.
    if (first.len != 0 and (first[0] == 'P' or first[0] == 'p')) {
        const d = try parseDuration(first);
        if (d.str.len != first.len) return error.ParseError;
        try forwards(d.value);
        const e = try parse(second);
        _ = e.value.addChecked(d.value.negate()) catch return error.OutOfRange;
        return .{
            .str = value[0 .. consumed + e.str.len],
            .value = .{ .duration_end = .{ .duration = d.value, .end = e.value } },
            .end = .{ .has_offset = e.has_offset, .precision = e.precision },
            .fractional = d.fractional,
        };
    }

    const s = try parseMarkingZone(first);
    if (s.result.str.len != first.len) return error.ParseError;
    const start: IntervalParseResult.Endpoint = .{
        .has_offset = s.result.has_offset,
        .precision = s.result.precision,
    };

    // Start, then duration.
    if (second.len != 0 and (second[0] == 'P' or second[0] == 'p')) {
        const d = try parseDuration(second);
        try forwards(d.value);
        _ = s.result.value.addChecked(d.value) catch return error.OutOfRange;
        return .{
            .str = value[0 .. consumed + d.str.len],
            .value = .{ .start_duration = .{ .start = s.result.value, .duration = d.value } },
            .start = start,
            .fractional = d.fractional,
        };
    }

    // Start, then end.
    const e = try parseEnd(first[0..s.zone_start], s.result, second);
    // Both ends in one form: ISO 8601-1:2019, 5.5.3.1, combines two date
    // and time representations "provided that the resulting expression is
    // either consistently in basic format or consistently in extended
    // format". A side too short to have a form, a bare year, agrees with
    // either.
    if (s.extended != null and e.extended != null and s.extended.? != e.extended.?) return error.MixedFormats;
    if (e.result.value.toInstant().timestamp < s.result.value.toInstant().timestamp) {
        return error.OutOfRange;
    }
    return .{
        .str = value[0 .. consumed + e.len],
        .value = .{ .start_end = .{ .start = s.result.value, .end = e.result.value } },
        .start = start,
        .end = .{ .has_offset = e.result.has_offset, .precision = e.result.precision },
    };
}

test parseInterval {
    const chicago = -6 * std.time.s_per_hour;
    const cases = [_]struct { []const u8, Interval }{
        .{ "2007-03-01T13:00:00Z/2008-05-11T15:30:00Z", .{ .start_end = .{
            .start = .{ .year = 2007, .month = .Mar, .day = 1, .hour = 13, .weekday = .Thu },
            .end = .{ .year = 2008, .month = .May, .day = 11, .hour = 15, .minute = 30, .weekday = .Sun },
        } } },
        .{ "2007-03-01T13:00:00Z/P1Y2M10DT2H30M", .{ .start_duration = .{
            .start = .{ .year = 2007, .month = .Mar, .day = 1, .hour = 13, .weekday = .Thu },
            .duration = .{ .months = 14, .days = 10, .nanoseconds = 150 * Duration.nanoseconds_per_minute },
        } } },
        .{ "P1Y2M10DT2H30M/2008-05-11T15:30:00Z", .{ .duration_end = .{
            .duration = .{ .months = 14, .days = 10, .nanoseconds = 150 * Duration.nanoseconds_per_minute },
            .end = .{ .year = 2008, .month = .May, .day = 11, .hour = 15, .minute = 30, .weekday = .Sun },
        } } },
        // The double hyphen, which also lets a reduced start be read.
        .{ "2024-03--2024-04", .{ .start_end = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 1, .weekday = .Fri },
            .end = .{ .year = 2024, .month = .Apr, .day = 1, .weekday = .Mon },
        } } },
        // Abbreviated ends, which take what they leave out from the start,
        // the zone included.
        .{ "2007-12-14T13:30-06:00/15:30", .{ .start_end = .{
            .start = .{ .year = 2007, .month = .Dec, .day = 14, .hour = 13, .minute = 30, .weekday = .Fri, .offset = chicago },
            .end = .{ .year = 2007, .month = .Dec, .day = 14, .hour = 15, .minute = 30, .weekday = .Fri, .offset = chicago },
        } } },
        .{ "2008-02-15/03-14", .{ .start_end = .{
            .start = .{ .year = 2008, .month = .Feb, .day = 15, .weekday = .Fri },
            .end = .{ .year = 2008, .month = .Mar, .day = 14, .weekday = .Fri },
        } } },
        .{ "2008-02-15/16", .{ .start_end = .{
            .start = .{ .year = 2008, .month = .Feb, .day = 15, .weekday = .Fri },
            .end = .{ .year = 2008, .month = .Feb, .day = 16, .weekday = .Sat },
        } } },
        .{ "2008-02-15T09:00/16T17:00", .{ .start_end = .{
            .start = .{ .year = 2008, .month = .Feb, .day = 15, .hour = 9, .weekday = .Fri },
            .end = .{ .year = 2008, .month = .Feb, .day = 16, .hour = 17, .weekday = .Sat },
        } } },
        .{ "20071214T1330/1530", .{ .start_end = .{
            .start = .{ .year = 2007, .month = .Dec, .day = 14, .hour = 13, .minute = 30, .weekday = .Fri },
            .end = .{ .year = 2007, .month = .Dec, .day = 14, .hour = 15, .minute = 30, .weekday = .Fri },
        } } },
        // An abbreviated end of 24:00 is the end of the start's day.
        .{ "2024-03-15T09:00/24:00", .{ .start_end = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9, .weekday = .Fri },
            .end = .{ .year = 2024, .month = .Mar, .day = 16, .weekday = .Sat },
        } } },
        // An interval of no length is still an interval.
        .{ "2024-03-15/2024-03-15", .{ .start_end = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri },
            .end = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri },
        } } },
    };
    for (cases) |case| {
        const got = parseInterval(case[0]) catch |err| {
            std.debug.print("{s}: {any}\n", .{ case[0], err });
            return err;
        };
        std.testing.expectEqualDeep(case[1], got.value) catch |err| {
            std.debug.print("{s}: {any}\n", .{ case[0], got.value });
            return err;
        };
        try std.testing.expectEqualStrings(case[0], got.str);
    }

    // What each endpoint said, beside the value.
    const reduced = try parseInterval("2024-03-15T09:00Z/P1D");
    try std.testing.expectEqual(
        @as(?IntervalParseResult.Endpoint, .{ .has_offset = true, .precision = .minute }),
        reduced.start,
    );
    try std.testing.expectEqual(@as(?IntervalParseResult.Endpoint, null), reduced.end);
    try std.testing.expectEqual(@as(?u8, 'S'), (try parseInterval("2024-03-15/PT1.5S")).fractional);

    // A full end without a zone takes the start's, as an abbreviated one
    // does: this is ISO 8601-1:2019/Amd 1:2022's own example.
    const shifted = try parseInterval("2018-01-15T12:00:00+05:00/2018-02-20T12:00:00");
    try std.testing.expect(shifted.end.?.has_offset);
    try std.testing.expectEqual(@as(i32, 5 * 3600), shifted.value.end().offset);
    // An end with a zone of its own keeps it.
    const own = try parseInterval("2018-01-15T12:00:00+05:00/2018-02-20T12:00:00Z");
    try std.testing.expectEqual(@as(i32, 0), own.value.end().offset);
    // The ending of the day is the first instant of the next, so these five
    // are one interval: ISO 8601-1:2019/Amd 1:2022, 5.3.2, EXAMPLE 12.
    const day = try parseInterval("2022-04-19T00:00:00Z/P1D");
    for ([_][]const u8{
        "2022-04-19T00:00:00Z/2022-04-19T24:00:00",
        "2022-04-19T00:00:00Z/2022-04-20T00:00:00",
        "2022-04-18T24:00:00Z/2022-04-19T24:00:00",
        "2022-04-18T24:00:00Z/2022-04-20T00:00:00",
    }) |same| {
        const got = try parseInterval(same);
        try std.testing.expectEqual(day.value.start().toInstant(), got.value.start().toInstant());
        try std.testing.expectEqual(day.value.end().toInstant(), got.value.end().toInstant());
    }

    // And a local start leaves a local end local.
    const local = try parseInterval("2024-03-15T09:00/2024-03-15T17:00");
    try std.testing.expect(!local.end.?.has_offset);

    // Trailing text is left, as with `parse`, and a solidus in it is not
    // taken for the separator.
    try std.testing.expectEqualStrings(
        "2024-03-15/03-16",
        (try parseInterval("2024-03-15/03-16 and/or later")).str,
    );
    try std.testing.expectEqualStrings(
        "2008-02-15/17",
        (try parseInterval("2008-02-15/17 later")).str,
    );

    for ([_][]const u8{
        "",
        "2024-03-15",
        "P1D",
        "/",
        "2024-03-15/",
        "/2024-03-15",
        // A duration cannot stand on both sides, or carry a sign.
        "P1D/P2D",
        "2024-03-15/-P1D",
        "-P1D/2024-03-15",
        "2024-03-15/P-1D",
        // Mixed, which runs forwards from some dates and backwards from
        // others; see `forwards`.
        "2024-01-31/P1M-30D",
        "P1M-30D/2024-03-15",
        // Backwards.
        "2024-03-16/2024-03-15",
        "2024-03-15T10:00/09:00",
        // The first part has to be all of what comes before the separator.
        "2024-03-15x/2024-03-16",
        "P1Dx/2024-03-16",
        // The two ends in different forms: ISO 8601-1:2019, 5.5.3.1.
        "1985-04-12T23:20:50/19850625T103000",
        "19850412T232050/1985-06-25T10:30:00",
        // A time shift after a bare date is not read, so the first part is
        // not all of what comes before the separator: the 2019 text's own
        // example, which Amendment 1:2022 replaced for that reason.
        "2018-01-15+05:00/2018-02-20",
        // Too far for a `Year` to hold.
        "2024-03-15/P9999999999Y",
        "P9999999999Y/2024-03-15",
        // A basic end cannot be spliced into a basic date; read whole, it is
        // the year 314, and so before the start.
        "20080215/0314",
    }) |bad| {
        std.testing.expect(std.meta.isError(parseInterval(bad))) catch |err| {
            std.debug.print("parsed but should not have: \"{s}\"\n", .{bad});
            return err;
        };
    }
}

/// What a successful `parseRecurringInterval` yields.
pub const RecurringIntervalParseResult = struct {
    /// The prefix of the input that was consumed.
    str: []const u8,
    value: RecurringInterval,
    /// `IntervalParseResult.start`, for the interval after the `R`.
    start: ?IntervalParseResult.Endpoint = null,
    /// `IntervalParseResult.end`, for the interval after the `R`.
    end: ?IntervalParseResult.Endpoint = null,
    /// `IntervalParseResult.fractional`, for the interval after the `R`.
    fractional: ?u8 = null,
};

/// Parses an ISO 8601 recurring time interval at the start of `value`: the
/// designator `R`, the number of intervals in the series or nothing for an
/// unbounded one, a solidus, and a time interval as `parseInterval` reads
/// it. That is ISO 8601-1:2019, 5.6.2, and the three forms are 5.6.1 a) to
/// c): a start and an end, or a start and a duration, "which identify the
/// first time interval", or a duration and an end, "which identify the
/// last".
///
///     R12/1985-04-12T23:20:50Z/1985-06-25T10:30:00Z
///     R12/1985-04-12T23:20:50Z/P1Y2M15DT12H30M
///     R/P1Y2M15DT12H/1985-04-12T23:20:50Z
///
/// The count is the number of intervals, the first included, which is how
/// ISO 8601 reads its own example `R15/…` in Annex A, Table A.24: "fifteen
/// recurrences". An absent count is unbounded (5.6.1). It has to
/// be at least one. `R0` and `R-1` are refused because neither ISO 8601-1:2019
/// nor ISO 8601-2:2019 defines them: an absent count is the only spelling of
/// an unbounded series either part gives. Accounts elsewhere say `R-1` means
/// unbounded and disagree about whether `R0` is no intervals or one that is
/// not repeated. The standard settles neither, so a reading picked from
/// those would be a guess, and a count read wrongly produces a series of the
/// wrong length without complaint.
///
/// A bare duration after the `R`, as in `R8/PT72H`, is refused for the
/// reason `parseInterval` refuses one: ISO 8601 places it on the timeline
/// by context, and there is none here. ISO 8601-1:2019 lists that form only
/// in NOTE 1 to 5.6.1, as one whose start or end is "supplied
/// out-of-band". The repeat rule ISO 8601-2:2019, clause 13, appends to the
/// end, as in `R12/20150929T140000/P1H30M0S/F2W`, is not
/// read either; it is left as trailing text, like anything else after the
/// interval.
///
/// The interval itself is range-checked as `parseInterval` checks it. The
/// later occurrences are not, since an unbounded series has no last one to
/// check; `RecurringInterval.Iterator.next` reports the first one that
/// leaves the calendar as `error.OutOfRange` when it gets there.
pub fn parseRecurringInterval(value: []const u8) ParseError!RecurringIntervalParseResult {
    var cursor: Cursor = .{ .text = value };
    if (!cursor.eatAny("Rr")) return error.ParseError;

    var count: ?u64 = null;
    const digits = cursor.digitsAhead();
    if (digits != 0) {
        var n: u64 = 0;
        for (cursor.text[cursor.index..][0..digits]) |char| {
            n = std.math.mul(u64, n, 10) catch return error.OutOfRange;
            n = std.math.add(u64, n, char - '0') catch return error.OutOfRange;
        }
        cursor.index += digits;
        if (n == 0) return error.OutOfRange;
        count = n;
    }

    if (!cursor.eat('/')) return error.ParseError;

    const interval = try parseInterval(value[cursor.index..]);
    return .{
        .str = value[0 .. cursor.index + interval.str.len],
        .value = .{ .count = count, .interval = interval.value },
        .start = interval.start,
        .end = interval.end,
        .fractional = interval.fractional,
    };
}

test parseRecurringInterval {
    const twelve = try parseRecurringInterval("R12/1985-04-12T23:20:50Z/P1Y2M15DT12H30M");
    try std.testing.expectEqual(@as(?u64, 12), twelve.value.count);
    try std.testing.expect(twelve.value.interval.duration().?.eql(.{
        .months = 14,
        .days = 15,
        .nanoseconds = 12 * Duration.nanoseconds_per_hour + 30 * Duration.nanoseconds_per_minute,
    }));
    try std.testing.expectEqual(
        @as(?IntervalParseResult.Endpoint, .{ .has_offset = true, .precision = .second }),
        twelve.start,
    );

    // Unbounded, and written as a duration and an end, so the series runs
    // backwards from the interval the text names.
    const ending = try parseRecurringInterval("R/P1Y2M15DT12H/1985-04-12T23:20:50Z");
    try std.testing.expectEqual(@as(?u64, null), ending.value.count);
    try std.testing.expect(!ending.value.isForwards());

    // Both endpoints, and the abbreviated end `parseInterval` reads.
    const pair = try parseRecurringInterval("R2/2024-03-15T09:00Z/17:00");
    try std.testing.expectEqual(@as(Hour, 17), pair.value.interval.end().hour);

    // Trailing text is left, the repeat rule of ISO 8601-2 included, in
    // the spelling of that part's own example.
    try std.testing.expectEqualStrings(
        "R12/2015-09-29T14:00:00Z/PT1H30M",
        (try parseRecurringInterval("R12/2015-09-29T14:00:00Z/PT1H30M/F2W")).str,
    );

    for ([_][]const u8{
        "",
        "R",
        "R5",
        "R5/",
        "5/2024-03-15/P1D",
        "R5 /2024-03-15/P1D",
        // Neither is defined by the text this was written against.
        "R0/2024-03-15/P1D",
        "R-1/2024-03-15/P1D",
        // A duration on its own has no place on the timeline.
        "R8/PT72H",
        // More intervals than a `u64` counts.
        "R99999999999999999999/2024-03-15/P1D",
    }) |bad| {
        std.testing.expect(std.meta.isError(parseRecurringInterval(bad))) catch |err| {
            std.debug.print("parsed but should not have: \"{s}\"\n", .{bad});
            return err;
        };
    }
}

/// Refuses a duration in an interval unless every one of its components is
/// zero or positive.
///
/// Checking the result of adding it would not be enough. A duration whose
/// components disagree in sign runs forwards from some dates and backwards
/// from others — `P1M-30D` from the 31st of January is the 30th, a day
/// earlier, and from the 1st of March is the 31st, a day later — so an
/// interval with one might check out and then run backwards on the next
/// step of a `RecurringInterval`. ISO 8601-1 writes an interval's duration
/// with no signs at all, and holding it to that is what makes every interval
/// this reads, and every series, run forwards however far it goes.
fn forwards(duration: Duration) ParseError!void {
    if (duration.months < 0 or duration.days < 0 or duration.nanoseconds < 0) return error.OutOfRange;
}

test forwards {
    try forwards(.{ .months = 1, .days = 2 });
    try std.testing.expectError(error.OutOfRange, forwards(.{ .months = 1, .days = -30 }));
}

/// Where the two parts of an interval divide: the first solidus or double
/// hyphen, whichever comes first, the two separators ISO 8601-1:2019, 3.2.6,
/// gives a time interval. Neither can occur inside a date, a time or a
/// duration this reads, so the first one found is the separator.
fn findSeparator(value: []const u8) ?struct { index: usize, len: usize } {
    const solidus = std.mem.findScalar(u8, value, '/');
    const hyphens = std.mem.find(u8, value, "--");
    if (solidus) |i| {
        if (hyphens) |j| if (j < i) return .{ .index = j, .len = 2 };
        return .{ .index = i, .len = 1 };
    }
    if (hyphens) |j| return .{ .index = j, .len = 2 };
    return null;
}

test findSeparator {
    try std.testing.expectEqual(@as(usize, 10), findSeparator("2024-03-15/2024-03-16").?.index);
    try std.testing.expectEqual(@as(usize, 2), findSeparator("2024-03--2024-04").?.len);
    // A negative offset is a single hyphen, and not the separator.
    try std.testing.expectEqual(@as(usize, 22), findSeparator("2024-03-15T10:00-05:00--2024-03-16").?.index);
    try std.testing.expectEqual(null, findSeparator("2024-03-15"));
}

/// Reads the end of a start and end interval, full or abbreviated; see
/// `parseInterval` for how an abbreviated one is completed. `start_text` is
/// the start as written, without its zone.
fn parseEnd(start_text: []const u8, start: ParseResult, text: []const u8) ParseError!End {
    var best: ?End = null;
    var first_error: ?ParseError = null;

    var best_is_full = false;
    if (parseMarkingZone(text)) |full| {
        best = .{ .result = full.result, .len = full.result.str.len, .extended = full.extended };
        best_is_full = true;
    } else |err| first_error = err;

    // The start and the end spliced together. Bounded, because a fraction
    // may run to any number of digits; an end too long to splice is still
    // read whole above.
    var buffer: [128]u8 = undefined;
    for (1..start_text.len + 1) |k| {
        if (std.mem.findScalar(u8, "-:TtWw ", start_text[k - 1]) == null) continue;
        if (k + text.len > buffer.len) continue;
        @memcpy(buffer[0..k], start_text[0..k]);
        @memcpy(buffer[k..][0..text.len], text);

        const spliced = parseMarkingZone(buffer[0 .. k + text.len]) catch continue;
        var result = spliced.result;
        if (result.str.len <= k) continue;
        if (result.precision != start.precision) continue;

        const len = result.str.len - k;
        // A tie goes to a splice, which read to the start's precision, over
        // the full reading, which need not have. Between splices it goes to
        // the earliest, which reads the most of the end as the start's
        // higher components.
        if (best) |b| {
            if (len < b.len) continue;
            if (len == b.len and !best_is_full) continue;
        }

        // The result points into the buffer, which is about to go; what the
        // caller wants is how much of `text` was read.
        result.str = text[0..len];
        best = .{ .result = result, .len = len, .extended = spliced.extended };
        best_is_full = false;
    }

    var end = best orelse return first_error orelse error.ParseError;
    // The start's zone carries over to an end that has none of its own,
    // whichever way the end was read; see `parseInterval`.
    if (!end.result.has_offset and start.has_offset) {
        end.result.value.offset = start.value.offset;
        end.result.has_offset = true;
    }
    return end;
}

/// What `parseEnd` read, how much of its text that took, and which form it
/// was in, as `Marked.extended` says. A spliced end reports the form of the
/// whole spliced text, which is the start's form wherever the end's own text
/// could not say.
const End = struct { result: ParseResult, len: usize, extended: ?bool };

test parseEnd {
    const start = try parse("2007-12-14T13:30");
    const end = try parseEnd("2007-12-14T13:30", start, "15:30 and after");
    try std.testing.expectEqual(@as(usize, 5), end.len);
    try std.testing.expectEqual(@as(Hour, 15), end.result.value.hour);
    try std.testing.expectEqual(@as(Day, 14), end.result.value.day);

    // `15` alone replaces the lowest component, the minute, rather than
    // being read as an hour and falling short of the start's precision.
    const minute = try parseEnd("2007-12-14T13:30", start, "45");
    try std.testing.expectEqual(@as(Hour, 13), minute.result.value.hour);
    try std.testing.expectEqual(@as(Minute, 45), minute.result.value.minute);
}

/// Writes `datetime` as an ISO 8601 date and time in full, in the extended
/// form: `2024-03-15T14:30:00Z`, which is also RFC 3339's `date-time`. That
/// is ISO 8601-1:2019, 5.4.2.1 b), `[dateX]["T"][timeX]` followed by `Z` or
/// by a time shift in the extended form.
///
/// Every component down to the second is written whatever it holds, since
/// the reader cannot know which ones were meant to be left out. A decimal
/// fraction of the second follows only when there is one, with its trailing
/// zeroes dropped, so `.5` rather than `.500000000` (5.3.1.4, with the full
/// stop as the decimal sign, 3.2.6).
///
/// The offset is `Z` when it is zero and `±hh:mm` otherwise, which is
/// 4.3.13: `Z` for no time shift, and a plus sign for one "ahead of or
/// equal to UTC". A historical
/// offset that is not a whole number of minutes, such as the local mean
/// time a zone kept before standard time, gets `:ss` after the minutes.
/// ISO 8601 has no spelling for that and `parse` does not read it, but
/// rounding it would name a different instant, and a string that fails to
/// read back is better than one that reads back wrong.
///
/// A year from 0 to 9999 is written as four digits (4.3.2). Any other year
/// is written with a sign and at least four digits, so the output never
/// names a different year than the one it holds. A negative year of four
/// digits, `-0001`, is ISO 8601-2:2019, 4.4.1.2; a year of more than four,
/// `+10000`, is the expanded representation of 4.4 and 5.2.2.3, which the
/// parties have to agree on. `parse` reads neither.
pub fn writeDateTime(writer: *std.Io.Writer, datetime: DateTime) std.Io.Writer.Error!void {
    try writeDate(writer, datetime.asDate());
    try writer.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ datetime.hour, datetime.minute, datetime.second });

    if (datetime.nanosecond != 0) {
        var digits: [9]u8 = undefined;
        _ = std.fmt.printInt(&digits, datetime.nanosecond, 10, .lower, .{ .fill = '0', .width = 9 });
        var len: usize = digits.len;
        while (len > 1 and digits[len - 1] == '0') len -= 1;
        try writer.print(".{s}", .{digits[0..len]});
    }

    if (datetime.offset == 0) return writer.writeByte('Z');

    const magnitude: u32 = @abs(datetime.offset);
    try writer.print("{c}{d:0>2}:{d:0>2}", .{
        @as(u8, if (datetime.offset < 0) '-' else '+'),
        magnitude / std.time.s_per_hour,
        magnitude % std.time.s_per_hour / std.time.s_per_min,
    });
    if (magnitude % std.time.s_per_min != 0) {
        try writer.print(":{d:0>2}", .{magnitude % std.time.s_per_min});
    }
}

test writeDateTime {
    const cases = [_]struct { DateTime, []const u8 }{
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .hour = 14, .minute = 30 }, "2024-03-15T14:30:00Z" },
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .nanosecond = 1 }, "2024-03-15T00:00:00.000000001Z" },
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .nanosecond = 500_000_000 }, "2024-03-15T00:00:00.5Z" },
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .offset = 5 * 3600 + 30 * 60 }, "2024-03-15T00:00:00+05:30" },
        // America/Chicago's local mean time, which is not whole minutes.
        .{ .{ .year = 1883, .month = .Nov, .day = 18, .offset = -(5 * 3600 + 50 * 60 + 36) }, "1883-11-18T00:00:00-05:50:36" },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDateTime(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }

    // What it writes, `parse` reads back as the same value.
    const datetime: DateTime = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 14, .nanosecond = 250, .offset = -5 * 3600, .weekday = .Fri };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDateTime(&w, datetime);
    try std.testing.expectEqual(datetime, (try parse(w.buffered())).value);
}

/// Writes `date` as an ISO 8601 calendar date in the extended form,
/// `2024-03-15`: ISO 8601-1:2019, 5.2.2.1 b).
///
/// The year is four digits from 0 to 9999, and otherwise the expanded form
/// with a sign and at least four digits; see `writeDateTime`.
pub fn writeDate(writer: *std.Io.Writer, date: Date) std.Io.Writer.Error!void {
    if (date.year >= 0 and date.year <= 9999) {
        try writer.print("{d:0>4}", .{@as(u32, @intCast(date.year))});
    } else {
        try writer.print("{c}{d:0>4}", .{ @as(u8, if (date.year < 0) '-' else '+'), @abs(date.year) });
    }
    try writer.print("-{d:0>2}-{d:0>2}", .{ @intFromEnum(date.month), date.day });
}

test writeDate {
    const cases = [_]struct { Date, []const u8 }{
        .{ .{ .year = 2024, .month = .Mar, .day = 15 }, "2024-03-15" },
        .{ .{ .year = 12, .month = .Jan, .day = 1 }, "0012-01-01" },
        .{ .{ .year = -1, .month = .Jan, .day = 1 }, "-0001-01-01" },
        .{ .{ .year = 10000, .month = .Jan, .day = 1 }, "+10000-01-01" },
    };
    for (cases) |case| {
        var buf: [32]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDate(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
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

    test done {
        var cursor: Cursor = .{ .text = "5" };
        try std.testing.expect(!cursor.done());

        cursor.index = 1;
        try std.testing.expect(cursor.done());
    }

    /// The character at the cursor. The caller must have checked `done`.
    fn peek(self: Cursor) u8 {
        return self.text[self.index];
    }

    test peek {
        var cursor: Cursor = .{ .text = "2024" };
        try std.testing.expectEqual(@as(u8, '2'), cursor.peek());

        // Peeking does not consume, so the answer does not change.
        try std.testing.expectEqual(@as(u8, '2'), cursor.peek());
    }

    /// Consumes `char` if it is next, and reports whether it was.
    fn eat(self: *Cursor, char: u8) bool {
        if (self.done() or self.peek() != char) return false;
        self.index += 1;
        return true;
    }

    test eat {
        var cursor: Cursor = .{ .text = "-03" };
        try std.testing.expect(cursor.eat('-'));
        try std.testing.expectEqual(@as(usize, 1), cursor.index);

        // A refusal leaves the position alone, which is what lets the
        // caller try something else.
        try std.testing.expect(!cursor.eat('-'));
        try std.testing.expectEqual(@as(usize, 1), cursor.index);
    }

    /// Consumes the next character if it is any of `chars`, and reports
    /// whether it was.
    fn eatAny(self: *Cursor, chars: []const u8) bool {
        if (self.done()) return false;
        if (std.mem.indexOfScalar(u8, chars, self.peek()) == null) return false;
        self.index += 1;
        return true;
    }

    test eatAny {
        // The date and time may be joined by either case of T, so the
        // separator is matched against a set.
        var cursor: Cursor = .{ .text = "t14" };
        try std.testing.expect(cursor.eatAny("Tt"));
        try std.testing.expectEqual(@as(usize, 1), cursor.index);

        try std.testing.expect(!cursor.eatAny("Tt"));
    }

    /// The length of the run of digits at the cursor.
    fn digitsAhead(self: Cursor) usize {
        var count: usize = 0;
        while (self.index + count < self.text.len and
            std.ascii.isDigit(self.text[self.index + count])) count += 1;
        return count;
    }

    test digitsAhead {
        // How many digits follow is what tells `2024-075` from `2024-07`,
        // so the run is measured before any of it is consumed.
        try std.testing.expectEqual(@as(usize, 3), (Cursor{ .text = "075" }).digitsAhead());
        try std.testing.expectEqual(@as(usize, 2), (Cursor{ .text = "07-05" }).digitsAhead());
        try std.testing.expectEqual(@as(usize, 0), (Cursor{ .text = "W11" }).digitsAhead());
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

    test digits {
        var cursor: Cursor = .{ .text = "2024-03" };
        try std.testing.expectEqual(@as(u32, 2024), try cursor.digits(4));
        try std.testing.expect(cursor.eat('-'));
        try std.testing.expectEqual(@as(u32, 3), try cursor.digits(2));

        // Exactly `count` digits are required, so running out or hitting
        // a non-digit is an error rather than a short read.
        var short: Cursor = .{ .text = "20" };
        try std.testing.expectError(error.ParseError, short.digits(4));

        var letters: Cursor = .{ .text = "20xx" };
        try std.testing.expectError(error.ParseError, letters.digits(4));
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

    test fraction {
        // The fraction is of whatever component it follows, so the same
        // digits mean different amounts against different units.
        var half_minute: Cursor = .{ .text = ".5" };
        try std.testing.expectEqual(@as(?u64, std.time.ns_per_min / 2), try half_minute.fraction(std.time.ns_per_min));

        // ISO 8601 allows a comma as well, and prefers it.
        var comma: Cursor = .{ .text = ",25" };
        try std.testing.expectEqual(@as(?u64, std.time.ns_per_s / 4), try comma.fraction(std.time.ns_per_s));

        // No fraction there at all is not an error; there just isn't one.
        var none: Cursor = .{ .text = "Z" };
        try std.testing.expectEqual(@as(?u64, null), try none.fraction(std.time.ns_per_s));

        // A separator with no digits after it is malformed.
        var empty: Cursor = .{ .text = "." };
        try std.testing.expectError(error.BadFraction, empty.fraction(std.time.ns_per_s));
    }
};

const testing = std.testing;

test parse {
    // A full timestamp: date, time, and zone.
    const full = try parse("2024-03-15T14:30:00Z");
    try testing.expectEqual(@as(Year, 2024), full.value.year);
    try testing.expectEqual(Month.Mar, full.value.month);
    try testing.expectEqual(@as(Day, 15), full.value.day);
    try testing.expectEqual(@as(Hour, 14), full.value.hour);
    try testing.expect(full.has_offset);
    try testing.expectEqual(Precision.second, full.precision);

    // The basic form, written without separators, means the same thing.
    const basic = try parse("20240315T143000Z");
    try testing.expectEqual(full.value, basic.value);

    // A representation may stop early, and `precision` says where. What
    // was not written is defaulted, so this is midnight on the first.
    const reduced = try parse("2024-03");
    try testing.expectEqual(Precision.month, reduced.precision);
    try testing.expectEqual(@as(Day, 1), reduced.value.day);
    try testing.expectEqual(@as(Hour, 0), reduced.value.hour);

    // A local time says nothing about its offset, which `has_offset`
    // reports and a zero `offset` cannot.
    const local = try parse("2024-03-15T14:30:00");
    try testing.expect(!local.has_offset);

    // Only the representation is consumed; the rest is the caller's.
    const trailing = try parse("2024-03-15T14:30:00Z and then some");
    try testing.expectEqualStrings("2024-03-15T14:30:00Z", trailing.str);

    // The date and the time must agree about which form they are in.
    try testing.expectError(error.MixedFormats, parse("2024-03-15T143000"));
}

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

test parseDate {
    // The three forms are told apart by what follows the year: a two
    // digit month, a three digit ordinal day, or a W.
    var extended: ?bool = null;
    var precision: Precision = .year;

    var calendar: Cursor = .{ .text = "2024-03-15" };
    try testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try parseDate(&calendar, &extended, &precision),
    );
    try testing.expectEqual(@as(?bool, true), extended);

    extended = null;
    var ordinal: Cursor = .{ .text = "2024-075" };
    try testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try parseDate(&ordinal, &extended, &precision),
    );

    extended = null;
    var week: Cursor = .{ .text = "2024-W11-5" };
    try testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try parseDate(&week, &extended, &precision),
    );

    // A bare year is too short to say which form it is in, so `extended`
    // is left for a later component to settle, and nothing below the year
    // was named, so `precision` is left where the caller set it.
    extended = null;
    precision = .year;
    var year_only: Cursor = .{ .text = "2024" };
    try testing.expectEqual(
        Date{ .year = 2024, .month = .Jan, .day = 1 },
        try parseDate(&year_only, &extended, &precision),
    );
    try testing.expectEqual(@as(?bool, null), extended);
    try testing.expectEqual(Precision.year, precision);
}

test parseTime {
    var extended: ?bool = null;
    var precision: Precision = .year;

    var cursor: Cursor = .{ .text = "14:30:05" };
    const time = try parseTime(&cursor, &extended, &precision);
    try testing.expectEqual(@as(Hour, 14), time.hour);
    try testing.expectEqual(@as(Minute, 30), time.minute);
    try testing.expectEqual(@as(Second, 5), time.second);
    try testing.expectEqual(Precision.second, precision);

    // A fraction may sit on whichever component is the last one written,
    // so half past an hour can be spelled either way.
    extended = null;
    var fractional: Cursor = .{ .text = "14.5" };
    const half = try parseTime(&fractional, &extended, &precision);
    try testing.expectEqual(@as(Hour, 14), half.hour);
    try testing.expectEqual(@as(Minute, 30), half.minute);

    // 24:00 is the end of a day rather than the start of one, which the
    // caller resolves by moving to the following date.
    extended = null;
    var end: Cursor = .{ .text = "24:00" };
    const midnight = try parseTime(&end, &extended, &precision);
    try testing.expect(midnight.end_of_day);
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

    // A bare year would commit to neither form, but no time may follow a
    // reduced date at all; see "a time follows only a complete date".
    try testing.expectError(error.ParseError, parse("2024T14:30"));
}

test "a time follows only a complete date" {
    // ISO 8601-1:2019, 5.4.1: "The date part of a date and time expression
    // shall be complete." A calendar, ordinal or week date naming a day is
    // complete; one reduced to a month, a week or a year is not.
    for ([_][]const u8{ "1985-04-12T10:15", "19850412T1015", "1985-102T10:15", "1985W155T1015" }) |good| {
        _ = try parse(good);
    }
    for ([_][]const u8{ "1985-04T10:15", "1985T10", "1985-W15T10:15", "1985W15T1015" }) |bad| {
        try testing.expectError(error.ParseError, parse(bad));
    }
    // A space after a reduced date is not a separator, so the date is read
    // and the rest is left, as after any date.
    try testing.expectEqualStrings("1985-04", (try parse("1985-04 10:15")).str);
}

test "a time shift follows only a time" {
    // ISO 8601-1:2019, 4.3.13 and 5.3.4.2: a time shift is appended to a
    // time of day. After a bare date it is not read, and is left as
    // trailing text, so a caller that wants the whole string refuses it.
    const date = try parse("1985-04-12Z");
    try testing.expectEqualStrings("1985-04-12", date.str);
    try testing.expect(!date.has_offset);
    try testing.expectEqualStrings("1985-04-12", (try parse("1985-04-12+05:00")).str);
    // After a time it is read as ever.
    try testing.expect((try parse("1985-04-12T10Z")).has_offset);
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

    // A space after a date is only the separator when a time follows it,
    // so a bare date can be followed by prose too.
    const date = try parse("2024-03-15 and then some");
    try testing.expectEqualStrings("2024-03-15", date.str);
    try testing.expectEqual(Precision.day, date.precision);
    try testing.expectEqualStrings("2024-03", (try parse("2024-03 or so")).str);
    try testing.expectEqualStrings("2024-03-15", (try parse("2024-03-15 ")).str);

    // A digit after the space is a time, and has to be a good one.
    try testing.expectError(error.OutOfRange, parse("2024-03-15 25:00"));
    // A `T` still promises one, whatever follows it.
    try testing.expectError(error.ParseError, parse("2024-03-15T and then some"));
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
