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
//! — while between them it is not. ISO 8601-2:2019/Amd 1:2025, 14.6,
//! draws the same line: years and months, and weeks and days, are
//! "unequivocally convertible", and months and days are not.
//!
//! The syntax is ISO 8601-1:2019, 5.5.2, and the signs it can carry are
//! ISO 8601-2:2019's: in front of the `P` (4.4.1.9), or on each component
//! of a composite duration (14.2). How one is added to a date is 14.4 and
//! its informative Annex D, which describes more than one method; see
//! `Arithmetic`.

const Duration = @This();

const std = @import("std");

const Date = @import("Date.zig");
const Day = @import("day.zig").Day;
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;
const json = @import("json.zig");
const iso8601 = @import("iso8601.zig");

/// Whole calendar months, years included at twelve to the year.
months: i64 = 0,
/// Whole days, weeks included at seven to the day.
days: i64 = 0,
/// Everything below a day. Not reduced to less than a day: a duration of
/// `PT36H` keeps its thirty-six hours, because ISO 8601 wrote it that way
/// and rewriting it as a day and a half would change what it says.
///
/// Hours, minutes and seconds share it at the fixed rates of 4.2.3, 60
/// seconds to the minute and 60 minutes to the hour. That is the "nominal
/// duration rule" ISO 8601-2:2019/Amd 1:2025, 14.6, EXAMPLE 15, gives for
/// ignoring leap seconds, which a duration measured in nanoseconds has no
/// way to know about. Keeping days apart from it is what 14.6 would not:
/// it counts a day and an hour as convertible "in the UTC 24-hour clock
/// system", and on a local clock a day across a change of offset is 23 or
/// 25 hours.
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
/// `{ .months = 1, .days = -1 }`, and that is a real length of time. ISO
/// 8601-1 cannot write it, since its syntax has at most a single sign in
/// front of everything; ISO 8601-2 can, with a sign on each component, and
/// that is what `format` writes for one. Anything defined only for
/// durations of one sign, an interval among them, asks this first.
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
/// Where the sign goes depends on whether the fields agree about it; see
/// `sign`. When they do, one sign stands in front of everything, `-P1Y2M`,
/// and every component after it is positive, which is ISO 8601-2:2019,
/// 4.4.1.9. When they do not, there is no single sign to write, and each
/// component carries its own instead: `{ .months = 1, .days = -1 }` is
/// `P1M-1D`. That is how ISO 8601-2:2019, 14.2, writes a composite
/// duration, whose example `P1Y10M3D - P2Y5MT10M` it gives as
/// `P3Y15M3DT-10M`. The years and months come from one field, and so do
/// the hours, minutes and seconds, so the components within each group
/// always share a sign: `{ .months = -14, .days = 3 }` is `P-1Y-2M3D`.
///
/// Both forms are read back by `iso8601.parseDuration` as the same value,
/// so every duration now round-trips. ISO 8601-1 has only the first form,
/// so a reader that knows only Part 1 will refuse the second. That is the
/// right outcome, since that reader has no way to hold the value anyway.
pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.isZero()) return writer.writeAll("PT0S");

    // Null when the fields disagree, which is when each component is signed
    // on its own and nothing goes in front.
    const whole_sign = self.sign();
    if (whole_sign == -1) try writer.writeByte('-');
    try writer.writeByte('P');
    const each = whole_sign == null;

    const months: u64 = @abs(self.months);
    const months_sign = if (each and self.months < 0) "-" else "";
    if (months / 12 != 0) try writer.print("{s}{d}Y", .{ months_sign, months / 12 });
    if (months % 12 != 0) try writer.print("{s}{d}M", .{ months_sign, months % 12 });
    if (self.days != 0) try writer.print("{s}{d}D", .{ if (each and self.days < 0) "-" else "", @abs(self.days) });

    const total: u128 = @abs(self.nanoseconds);
    if (total == 0) return;
    const time_sign = if (each and self.nanoseconds < 0) "-" else "";

    try writer.writeByte('T');
    const hours = total / @as(u128, @intCast(nanoseconds_per_hour));
    const minutes = total % @as(u128, @intCast(nanoseconds_per_hour)) / @as(u128, @intCast(nanoseconds_per_minute));
    const seconds = total % @as(u128, @intCast(nanoseconds_per_minute)) / @as(u128, @intCast(nanoseconds_per_second));
    const fraction = total % @as(u128, @intCast(nanoseconds_per_second));

    if (hours != 0) try writer.print("{s}{d}H", .{ time_sign, hours });
    if (minutes != 0) try writer.print("{s}{d}M", .{ time_sign, minutes });
    // The seconds are written whenever there is a fraction, because a bare
    // `PT0.5S` has to say the zero its fraction belongs to.
    if (seconds != 0 or fraction != 0 or (hours == 0 and minutes == 0)) {
        try writer.print("{s}{d}", .{ time_sign, seconds });
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
        // Fields that disagree in sign, each component signed on its own.
        .{ .{ .months = 1, .days = -1 }, "P1M-1D" },
        .{ .{ .months = -14, .days = 3 }, "P-1Y-2M3D" },
        .{ .{ .months = 51, .days = 3, .nanoseconds = -10 * nanoseconds_per_minute }, "P4Y3M3DT-10M" },
        .{ .{ .days = 1, .nanoseconds = -(90 * nanoseconds_per_minute + nanoseconds_per_second / 2) }, "P1DT-1H-30M-0.5S" },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try case[0].format(&w);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }

    // Whatever it writes, `iso8601.parseDuration` reads back as the same
    // value, the mixed signs included.
    for (cases) |case| {
        const again = try iso8601.parseDuration(case[1]);
        try std.testing.expectEqualStrings(case[1], again.str);
        try std.testing.expect(again.value.eql(case[0]));
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
/// This is `Arithmetic.xml_schema`; `addToDateWith` takes the other one.
///
/// A result outside the years a `Year` can hold is a panic; `addToDateChecked`
/// is the one to use on a duration somebody else chose.
pub fn addToDate(self: Duration, date: Date) Date {
    return self.addToDateWith(date, .xml_schema);
}

/// `addToDate` by the method `arithmetic` names; see `Arithmetic`.
pub fn addToDateWith(self: Duration, date: Date, arithmetic: Arithmetic) Date {
    return self.addToDateCheckedWith(date, arithmetic) catch
        @panic("Duration.addToDate: the result is outside the years a Year can hold");
}

test addToDateWith {
    const jan31: Date = .{ .year = 2001, .month = .Jan, .day = 31 };
    const d: Duration = .{ .months = 1, .days = 1 };
    // The one case the two methods answer differently: the day the months
    // leave invalid, which is then moved by days.
    try std.testing.expectEqual(Date{ .year = 2001, .month = .Mar, .day = 1 }, d.addToDateWith(jan31, .xml_schema));
    try std.testing.expectEqual(Date{ .year = 2001, .month = .Mar, .day = 4 }, d.addToDateWith(jan31, .composite));
}

/// `addToDate`, answering `error.OutOfRange` rather than panicking when the
/// result would land outside the years a `Year` can hold.
pub fn addToDateChecked(self: Duration, date: Date) error{OutOfRange}!Date {
    return self.addToDateCheckedWith(date, .xml_schema);
}

/// `addToDateWith`, answering `error.OutOfRange` rather than panicking when
/// the result would land outside the years a `Year` can hold.
///
/// The arithmetic is done in an `i128` throughout, which no `i64` month or
/// day count can overflow, and narrowed only once the answer is known to
/// fit. Narrowing first is what would make a large duration a crash instead
/// of an error.
pub fn addToDateCheckedWith(self: Duration, date: Date, arithmetic: Arithmetic) error{OutOfRange}!Date {
    const total_months = @as(i128, date.year) * 12 + (@intFromEnum(date.month) - 1) + self.months;
    const year = std.math.cast(Year, @divFloor(total_months, 12)) orelse return error.OutOfRange;
    const month: Month = @enumFromInt(@as(u8, @intCast(@mod(total_months, 12) + 1)));

    const days = switch (arithmetic) {
        .xml_schema => blk: {
            const clamped: Day = @min(date.day, month.lastDay(year));
            break :blk @as(i128, (Date{ .year = year, .month = month, .day = clamped }).toDaysSinceStartOfEra()) + self.days;
        },
        .composite => blk: {
            // A day the duration does not move is truncated to its month,
            // D.3.2; one it does move keeps its full value and carries past
            // the month's end, D.4.2. Counting from the first of the month
            // is both at once: a day past the end is so many days into the
            // next month, which is what the carry does.
            if (self.days == 0) {
                const clamped: Day = @min(date.day, month.lastDay(year));
                break :blk @as(i128, (Date{ .year = year, .month = month, .day = clamped }).toDaysSinceStartOfEra());
            }
            const first = (Date{ .year = year, .month = month, .day = 1 }).toDaysSinceStartOfEra();
            break :blk @as(i128, first) + (date.day - 1) + self.days;
        },
    };
    if (days < Date.min_days or days > Date.max_days) return error.OutOfRange;
    return Date.fromDaysSinceStartOfEra(@intCast(days));
}

test "the examples of ISO 8601-2:2019, Annex D, that begin on a real date" {
    // D.3.2, EXAMPLE 1: a month on from the 31st of January is truncated
    // to February's last day, under either method.
    const jan31: Date = .{ .year = 2018, .month = .Jan, .day = 31 };
    inline for (.{ Arithmetic.xml_schema, Arithmetic.composite }) |arithmetic| {
        try std.testing.expectEqual(
            Date{ .year = 2018, .month = .Feb, .day = 28 },
            try (Duration{ .months = 1 }).addToDateCheckedWith(jan31, arithmetic),
        );
    }
    // D.4.2, EXAMPLE 2: '2020Y2M29D + P2Y2M2D' is '2022Y5M1D', under either.
    const leap_day: Date = .{ .year = 2020, .month = .Feb, .day = 29 };
    inline for (.{ Arithmetic.xml_schema, Arithmetic.composite }) |arithmetic| {
        try std.testing.expectEqual(
            Date{ .year = 2022, .month = .May, .day = 1 },
            try (Duration{ .months = 26, .days = 2 }).addToDateCheckedWith(leap_day, arithmetic),
        );
    }
}

test addToDateCheckedWith {
    const jan31: Date = .{ .year = 2001, .month = .Jan, .day = 31 };
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Mar, .day = 4 },
        try (Duration{ .months = 1, .days = 1 }).addToDateCheckedWith(jan31, .composite),
    );
    try std.testing.expectError(
        error.OutOfRange,
        (Duration{ .months = std.math.maxInt(i64) }).addToDateCheckedWith(jan31, .composite),
    );
}

/// The two ways this library adds a `Duration` to a date, which differ in
/// one case only: a day the months have left invalid, which the duration
/// then moves by whole days.
///
/// ISO 8601-1 does not say how to add a duration to a date at all. ISO
/// 8601-2:2019, 14.4, does, and sends the reader to its Annex D for the
/// method, and that annex is informative. So both of these are ways of
/// doing it that a standard describes, and the choice between them is a
/// caller's to make.
pub const Arithmetic = enum {
    /// XML Schema 1.1's *Adding durations to dateTimes*, and the default.
    ///
    /// The months are added first and the day of the month is clamped to
    /// the last day of the month it landed in; only then are the days added,
    /// as a count. So `P1M1D` from the 31st of January 2001 lands on the
    /// 28th of February and then the 1st of March. This is also what ISO
    /// 8601-2:2019, D.4.3, gives for a *precedence* duration written in its
    /// natural order, `P1MP1D`, applying one unit at a time with truncation
    /// at each step, and it is what Java's `Period`, .NET's `AddMonths`
    /// and most libraries compute.
    xml_schema,
    /// ISO 8601-2:2019, D.4.2, for a *composite* duration.
    ///
    /// Every component is applied to the date at once, and only then are
    /// the components carried over, lowest first, with anything still
    /// invalid truncated last. A day the duration moved that has run past
    /// the end of its month is an overflow, and the excess carries into the
    /// next: `P1M1D` from the 31st of January 2001 is the 32nd of February,
    /// which is the 4th of March. A day the duration did not move, and that
    /// only a change of month has made invalid, is truncated instead, D.3.2,
    /// so `P1M` alone from the 31st of January is still the 28th of
    /// February under either method.
    ///
    /// The annex's second example, the 29th of February 2020 plus
    /// `P2Y2M2D`, is the 1st of May 2022 under both methods. Its first
    /// begins from a date that does not exist, the 30th of February, and
    /// ends on one that does not either, the 31st of June, so it is not
    /// one to test against.
    composite,
};

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

/// Writes this duration as a JSON string of its ISO 8601 spelling, `"P1Y2M10DT2H30M"`, which is
/// what `std.json.Stringify` calls when it meets one, in a field or on its
/// own.
///
/// The text is `format`'s, so it is canonical rather than as parsed —
/// `P14M` comes back as `P1Y2M`, the same length of time. A duration whose
/// fields disagree in sign is written with a sign on each component,
/// `P1M-1D`, which ISO 8601-2 allows and `jsonParse` reads back; see
/// `format`.
pub fn jsonStringify(self: Duration, jw: anytype) !void {
    return json.stringify(jw, self, json.writeDuration);
}

test jsonStringify {
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, @as(Duration, .{ .months = 14, .days = 10, .nanoseconds = 150 * nanoseconds_per_minute }), .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\"P1Y2M10DT2H30M\"", text);
}

/// Reads one of these from the next token of a JSON document, which has to
/// be a string; `std.json.parseFromSlice` and its relatives call this when
/// they meet the type. See `jsonStringify` for the text, and `json.parse`
/// for what happens to the token.
///
/// A string that is not the representation is `error.InvalidCharacter`, and
/// one whose components are out of range is `error.Overflow`, the errors
/// `std.json` gives for a malformed and an oversized number.
pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Duration {
    return json.parse(Duration, allocator, source, options, json.readDuration);
}

test jsonParse {
    const Record = struct { value: Duration };
    const parsed = try std.json.parseFromSlice(Record, std.testing.allocator, "{\"value\":\"P1Y2M10DT2H30M\"}", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.value.eql(Duration{ .months = 14, .days = 10, .nanoseconds = 150 * nanoseconds_per_minute }));

    try std.testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(Duration, std.testing.allocator, "\"not a date\"", .{}),
    );
}

/// Reads one of these from a `std.json.Value` that has already been
/// parsed, which has to be a string; `std.json.parseFromValue` calls this
/// when it meets the type. See `jsonParse`.
pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Duration {
    _ = allocator;
    _ = options;
    return json.parseFromValue(Duration, source, json.readDuration);
}

test jsonParseFromValue {
    const parsed = try std.json.parseFromValue(Duration, std.testing.allocator, .{ .string = "P1Y2M10DT2H30M" }, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(Duration{ .months = 14, .days = 10, .nanoseconds = 150 * nanoseconds_per_minute }));
}

test {
    std.testing.refAllDecls(@This());
}
