// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A length of time as ISO 8601 writes one: `P1Y6M`, `PT30M`, `P3DT4H30M`.
//!
//! The three fields are kept apart on purpose, and it is the whole design.
//! A duration is **not** a fixed number of nanoseconds, because a month is
//! not a fixed number of days and a day is not always 86400 seconds: adding
//! one month to the 31st of January lands on the 28th of February, and a
//! duration that could be reduced to a count would have no way to say so.
//! `Instant` is the type for a fixed span; this one is for the calendar's
//! own arithmetic, which is why `addToDate` and `DateTime.add` take the
//! fields in a particular order and say why.
//!
//! Years fold into `months` and weeks into `days`, because within each pair
//! the conversion is exact — twelve months to a year, seven days to a week
//! — while between them it is not.

const Duration = @This();

const std = @import("std");

const Date = @import("Date.zig");
const Day = @import("day.zig").Day;
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;

/// Whole calendar months, years included at twelve to the year.
months: i64 = 0,
/// Whole days, weeks included at seven to the day.
days: i64 = 0,
/// Everything below a day. Not reduced to less than a day: a duration of
/// `PT36H` keeps its thirty-six hours, because ISO 8601 wrote it that way
/// and rewriting it as a day and a half would change what it says.
nanoseconds: i128 = 0,

pub const nanoseconds_per_second: i128 = 1_000_000_000;
pub const nanoseconds_per_minute: i128 = 60 * nanoseconds_per_second;
pub const nanoseconds_per_hour: i128 = 60 * nanoseconds_per_minute;
pub const nanoseconds_per_day: i128 = 24 * nanoseconds_per_hour;

/// No time at all, which ISO 8601 spells `PT0S`.
pub const zero: Duration = .{};

pub fn isZero(self: Duration) bool {
    return self.months == 0 and self.days == 0 and self.nanoseconds == 0;
}

pub fn eql(a: Duration, b: Duration) bool {
    return a.months == b.months and a.days == b.days and a.nanoseconds == b.nanoseconds;
}

/// The same length of time in the other direction.
pub fn negate(self: Duration) Duration {
    return .{
        .months = -self.months,
        .days = -self.days,
        .nanoseconds = -self.nanoseconds,
    };
}

test negate {
    const d: Duration = .{ .months = 1, .days = -2 };
    try std.testing.expect(d.negate().eql(.{ .months = -1, .days = 2 }));
}

/// Which direction this duration points: `1` forwards, `-1` backwards, `0`
/// for no time at all, and **null** when its fields disagree.
///
/// Fields can disagree because nothing stops a caller building
/// `{ .months = 1, .days = -1 }`, and that is a real length of time — it is
/// simply not one ISO 8601 can write, since the syntax has a single sign in
/// front of everything. Anything that has to write a duration out, or that
/// is defined only for durations of one sign, asks this first.
pub fn sign(self: Duration) ?i2 {
    var seen: i2 = 0;
    for ([_]i128{ self.months, self.days, self.nanoseconds }) |field| {
        const s: i2 = if (field > 0) 1 else if (field < 0) -1 else 0;
        if (s == 0) continue;
        if (seen != 0 and seen != s) return null;
        seen = s;
    }
    return seen;
}

test sign {
    try std.testing.expectEqual(@as(?i2, 0), Duration.zero.sign());
    try std.testing.expectEqual(@as(?i2, 1), (Duration{ .months = 1, .days = 2 }).sign());
    try std.testing.expectEqual(@as(?i2, -1), (Duration{ .nanoseconds = -1 }).sign());
    try std.testing.expectEqual(@as(?i2, null), (Duration{ .months = 1, .days = -1 }).sign());
}

/// Writes this duration in ISO 8601's own syntax, which is what `{f}` gets.
///
/// The form is canonical rather than the one it was parsed from: years come
/// out of `months` and weeks are written as days, so `P14M` is `P1Y2M` and
/// `P2W` is `P14D`. A duration of no time at all is `PT0S`, which is the one
/// spelling the syntax cannot leave empty.
///
/// A duration whose fields disagree in sign has no ISO 8601 spelling at all
/// — see `sign` — and is written with the sign of its largest non-zero
/// field and the magnitude of each. That does not round-trip, and is why
/// anything storing a duration should keep one `sign` can answer for.
pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.isZero()) return writer.writeAll("PT0S");

    if ((self.sign() orelse 1) < 0) try writer.writeByte('-');
    try writer.writeByte('P');

    const months: u64 = @abs(self.months);
    if (months / 12 != 0) try writer.print("{d}Y", .{months / 12});
    if (months % 12 != 0) try writer.print("{d}M", .{months % 12});
    if (self.days != 0) try writer.print("{d}D", .{@abs(self.days)});

    const total: u128 = @abs(self.nanoseconds);
    if (total == 0) return;

    try writer.writeByte('T');
    const hours = total / @as(u128, @intCast(nanoseconds_per_hour));
    const minutes = total % @as(u128, @intCast(nanoseconds_per_hour)) / @as(u128, @intCast(nanoseconds_per_minute));
    const seconds = total % @as(u128, @intCast(nanoseconds_per_minute)) / @as(u128, @intCast(nanoseconds_per_second));
    const fraction = total % @as(u128, @intCast(nanoseconds_per_second));

    if (hours != 0) try writer.print("{d}H", .{hours});
    if (minutes != 0) try writer.print("{d}M", .{minutes});
    // The seconds are written whenever there is a fraction, because a bare
    // `PT0.5S` has to say the zero its fraction belongs to.
    if (seconds != 0 or fraction != 0 or (hours == 0 and minutes == 0)) {
        try writer.print("{d}", .{seconds});
        if (fraction != 0) {
            var digits: [9]u8 = undefined;
            _ = std.fmt.printInt(&digits, fraction, 10, .lower, .{ .fill = '0', .width = 9 });
            // Trailing zeroes of the fraction say nothing: `PT0.5S`, never
            // `PT0.500000000S`.
            var len: usize = digits.len;
            while (len > 1 and digits[len - 1] == '0') len -= 1;
            try writer.print(".{s}", .{digits[0..len]});
        }
        try writer.writeByte('S');
    }
}

test format {
    const cases = [_]struct { Duration, []const u8 }{
        .{ Duration.zero, "PT0S" },
        .{ .{ .months = 14 }, "P1Y2M" },
        .{ .{ .months = 12 }, "P1Y" },
        .{ .{ .days = 14 }, "P14D" },
        .{ .{ .months = -14 }, "-P1Y2M" },
        .{ .{ .nanoseconds = nanoseconds_per_hour }, "PT1H" },
        .{ .{ .nanoseconds = 90 * nanoseconds_per_minute }, "PT1H30M" },
        .{ .{ .nanoseconds = nanoseconds_per_second / 2 }, "PT0.5S" },
        .{ .{ .nanoseconds = 1 }, "PT0.000000001S" },
        .{ .{ .days = 3, .nanoseconds = 4 * nanoseconds_per_hour + 30 * nanoseconds_per_minute }, "P3DT4H30M" },
        .{ .{ .months = 1, .days = 2, .nanoseconds = 3 * nanoseconds_per_second }, "P1M2DT3S" },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try case[0].format(&w);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}

/// Adds this duration's months and days to a date, which is the calendar
/// part of XML Schema's *Adding durations to dateTimes* and of ISO 8601's
/// own reading. The sub-day part is not consulted; `DateTime.add` is the one
/// that has somewhere to put it.
///
/// The order is the whole of the algorithm, and getting it wrong is not
/// visible in most cases:
///
///  1. The months are added, which can leave a day number the new month does
///     not have.
///  2. That day is **clamped** to the last of its month, so one month after
///     the 31st of January is the 28th of February and not the 3rd of March.
///  3. Only then are the days added, as a day count, which cannot leave an
///     invalid date behind.
///
/// So `P1M1D` from the 31st of January is the 1st of March, while `P1D1M`
/// — which ISO 8601 cannot write, and which is why it cannot — would be the
/// 2nd. Adding a duration is not commutative and not associative, and the
/// clamp is the reason.
///
/// A result outside the years a `Year` can hold is a panic; `addToDateChecked`
/// is the one to use on a duration somebody else chose.
pub fn addToDate(self: Duration, date: Date) Date {
    return self.addToDateChecked(date) catch
        @panic("Duration.addToDate: the result is outside the years a Year can hold");
}

/// `addToDate`, answering `error.OutOfRange` rather than panicking when the
/// result would land outside the years a `Year` can hold.
///
/// The arithmetic is done in an `i128` throughout, which no `i64` month or
/// day count can overflow, and narrowed only once the answer is known to
/// fit. Narrowing first is what would make a large duration a crash instead
/// of an error.
pub fn addToDateChecked(self: Duration, date: Date) error{OutOfRange}!Date {
    const total_months = @as(i128, date.year) * 12 + (@intFromEnum(date.month) - 1) + self.months;
    const year = std.math.cast(Year, @divFloor(total_months, 12)) orelse return error.OutOfRange;
    const month: Month = @enumFromInt(@as(u8, @intCast(@mod(total_months, 12) + 1)));

    const clamped: Day = @min(date.day, month.lastDay(year));
    const days = @as(i128, (Date{ .year = year, .month = month, .day = clamped }).toDaysSinceStartOfEra()) + self.days;
    if (days < Date.min_days or days > Date.max_days) return error.OutOfRange;
    return Date.fromDaysSinceStartOfEra(@intCast(days));
}

test addToDateChecked {
    const jan31: Date = .{ .year = 2001, .month = .Jan, .day = 31 };
    // In range, it is `addToDate`.
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Feb, .day = 28 },
        try (Duration{ .months = 1 }).addToDateChecked(jan31),
    );
    // Past the last year a `Year` can hold, by months and by days.
    try std.testing.expectError(
        error.OutOfRange,
        (Duration{ .months = std.math.maxInt(i64) }).addToDateChecked(jan31),
    );
    try std.testing.expectError(
        error.OutOfRange,
        (Duration{ .days = std.math.minInt(i64) }).addToDateChecked(jan31),
    );
}

test addToDate {
    const jan31: Date = .{ .year = 2001, .month = .Jan, .day = 31 };
    // The clamp: February has no 31st, so one month later is its last day.
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Feb, .day = 28 },
        (Duration{ .months = 1 }).addToDate(jan31),
    );
    // And the clamp happens before the days are added, so this is the 1st of
    // March rather than the 3rd.
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Mar, .day = 1 },
        (Duration{ .months = 1, .days = 1 }).addToDate(jan31),
    );
    // A leap year has the 29th to clamp to.
    try std.testing.expectEqual(
        Date{ .year = 2000, .month = .Feb, .day = 29 },
        (Duration{ .months = 1 }).addToDate(.{ .year = 2000, .month = .Jan, .day = 31 }),
    );
    // Days carry across months and years without a clamp of their own.
    try std.testing.expectEqual(
        Date{ .year = 2002, .month = .Jan, .day = 1 },
        (Duration{ .days = 31 }).addToDate(.{ .year = 2001, .month = .Dec, .day = 1 }),
    );
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Nov, .day = 30 },
        (Duration{ .days = -1 }).addToDate(.{ .year = 2001, .month = .Dec, .day = 1 }),
    );
    // Whole years, and across the year the calendar has no zero for: this
    // library numbers years astronomically, so year 0 is a year like any
    // other and -1 is the one before it.
    try std.testing.expectEqual(
        Date{ .year = 0, .month = .Jan, .day = 1 },
        (Duration{ .months = 12 }).addToDate(.{ .year = -1, .month = .Jan, .day = 1 }),
    );
}

test {
    std.testing.refAllDecls(@This());
}
