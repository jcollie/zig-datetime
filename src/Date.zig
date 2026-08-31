// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A calendar date: a year, a month and a day, with no time of day and no
//! timezone attached.
//!
//! Conversion to and from a day number runs on Howard Hinnant's `civil_from_days`
//! algorithm, which shifts the year to start in March so that the leap day
//! falls at the end of it and the month lengths become a repeating pattern
//! that a single division can invert. See `fromDaysSinceStartOfEra`.

const Date = @This();

const std = @import("std");
const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const leap = @import("leap.zig");

year: Year,
month: Month,
day: Day,

/// The Unix epoch, 1970-01-01.
pub const init: Date = .{
    .year = 1970,
    .month = .Jan,
    .day = 1,
};

/// Returns true if `day` is a valid day number for this month and year.
pub fn isRegular(self: Date) bool {
    return self.day >= 1 and self.day <= self.month.lastDay(self.year);
}

test isRegular {
    try std.testing.expect((Date{ .year = 2024, .month = .Feb, .day = 29 }).isRegular());

    // 2025 is not a leap year, so the same date is not a day in it.
    try std.testing.expect(!(Date{ .year = 2025, .month = .Feb, .day = 29 }).isRegular());
    try std.testing.expect(!(Date{ .year = 2024, .month = .Apr, .day = 31 }).isRegular());
    try std.testing.expect(!(Date{ .year = 2024, .month = .Jan, .day = 0 }).isRegular());
}

/// A count of days since 1970-01-01, wide enough for every date a `Year`
/// can hold: the whole span of years at the longest a year can be.
pub const DaysType = std.math.IntFittingRange(
    std.math.minInt(Year) * 366,
    std.math.maxInt(Year) * 366,
);

/// Returns the date that is `days` days after 1970-01-01; negative values
/// give dates before the epoch.
pub fn fromDaysSinceStartOfEra(days: DaysType) Date {
    const z = days + 719468;

    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);

    const day_of_era = (z - era * 146097);
    std.debug.assert(day_of_era >= 0 and day_of_era <= 146096);

    const year_of_era = @divTrunc(day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36524) - @divTrunc(day_of_era, 146096), 365);
    std.debug.assert(year_of_era >= 0 and year_of_era <= 399);

    const year_0 = year_of_era + era * 400;

    const day_of_year = day_of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    std.debug.assert(day_of_year >= 0 and day_of_year <= 365);

    const month_0 = @divTrunc(5 * day_of_year + 2, 153);
    std.debug.assert(month_0 >= 0 and month_0 <= 11);

    const month = month_0 + (if (month_0 < 10) @as(DaysType, 3) else @as(DaysType, -9));
    std.debug.assert(month >= 1 and month <= 12);

    const year = year_0 + (if (month <= 2) @as(Year, 1) else @as(Year, 0));
    std.debug.assert(year >= std.math.minInt(Year) and year <= std.math.maxInt(Year));

    const day = day_of_year - @divTrunc(153 * month_0 + 2, 5) + 1;
    std.debug.assert(day >= 1 and day <= @as(Month, @enumFromInt(month)).lastDay(@intCast(year)));

    return Date{
        .year = @intCast(year),
        .month = @enumFromInt(month),
        .day = @intCast(day),
    };
}

test fromDaysSinceStartOfEra {
    try std.testing.expectEqual(
        Date{ .year = 1970, .month = .Jan, .day = 1 },
        fromDaysSinceStartOfEra(0),
    );
    try std.testing.expectEqual(
        Date{ .year = 1970, .month = .Jan, .day = 2 },
        fromDaysSinceStartOfEra(1),
    );

    // Negative counts reach dates before the epoch.
    try std.testing.expectEqual(
        Date{ .year = 1969, .month = .Dec, .day = 31 },
        fromDaysSinceStartOfEra(-1),
    );
}

test "civilFromDays" {
    const tests = [_]struct { days: DaysType, result: Date }{
        .{
            .days = 0,
            .result = Date{
                .year = 1970,
                .month = .Jan,
                .day = 1,
            },
        },
        .{
            .days = 1,
            .result = Date{
                .year = 1970,
                .month = .Jan,
                .day = 2,
            },
        },
        .{
            .days = -1,
            .result = Date{
                .year = 1969,
                .month = .Dec,
                .day = 31,
            },
        },
        .{
            .days = 19605,
            .result = Date{
                .year = 2023,
                .month = .Sep,
                .day = 5,
            },
        },
    };

    for (tests) |case| {
        const result = Date.fromDaysSinceStartOfEra(case.days);
        try std.testing.expectEqual(case.result, result);
    }
}

/// Returns the number of days from 1970-01-01 to this date; negative for
/// dates before the epoch. Asserts that the date is valid (see `isRegular`).
pub fn toDaysSinceStartOfEra(self: Date) DaysType {
    std.debug.assert(self.day >= 1 and self.day <= self.month.lastDay(self.year));

    const month = self.month.monthNumber();

    const year = self.year - switch (self.month) {
        .Jan, .Feb => @as(Year, 1),
        else => @as(Year, 0),
    };

    const era = @divTrunc(
        if (year >= 0) year else year - 399,
        400,
    );

    const year_of_era = year - era * 400;
    std.debug.assert(year_of_era >= 0 and year_of_era <= 399);

    const day_of_year = @divTrunc(
        153 * (month + switch (self.month) {
            .Jan, .Feb => @as(Year, 9),
            else => @as(Year, -3),
        }) + 2,
        5,
    ) + self.day - 1;
    std.debug.assert(day_of_year >= 0 and day_of_year <= 365);

    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    std.debug.assert(day_of_era >= 0 and day_of_era <= 146096);

    return era * 146097 + day_of_era - 719468;
}

test toDaysSinceStartOfEra {
    try std.testing.expectEqual(
        @as(DaysType, 0),
        (Date{ .year = 1970, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra(),
    );
    try std.testing.expectEqual(
        @as(DaysType, -1),
        (Date{ .year = 1969, .month = .Dec, .day = 31 }).toDaysSinceStartOfEra(),
    );

    // It is the inverse of `fromDaysSinceStartOfEra`.
    const date: Date = .{ .year = 2024, .month = .Mar, .day = 15 };
    try std.testing.expectEqual(date, fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra()));
}

test "daysFromCivil" {
    const tests = [_]struct { date: Date, result: DaysType }{
        .{
            .date = .{
                .year = 1970,
                .month = .Jan,
                .day = 1,
            },
            .result = 0,
        },
        .{
            .date = .{
                .year = 1970,
                .month = .Jan,
                .day = 2,
            },
            .result = 1,
        },
        .{
            .date = .{
                .year = 1969,
                .month = .Dec,
                .day = 31,
            },
            .result = -1,
        },
    };

    for (tests) |case| {
        const result = Date.toDaysSinceStartOfEra(case.date);
        try std.testing.expectEqual(case.result, result);
    }
}

/// Returns the day of the week this date falls on.
pub fn dayOfWeek(self: Date) DayOfWeek {
    const days = self.toDaysSinceStartOfEra();
    return DayOfWeek.fromDaysSinceStartOfEra(days);
}

/// A week of some year, and the year that week belongs to.
pub const Week = struct {
    /// The week-numbering year, which is not always the calendar year:
    /// see `weekOfYear`.
    year: Year,
    /// The week within that year, 1 through 52, 53 or 54.
    week: u8,
};

/// Returns the week of the year this date falls in, and the year that
/// week belongs to, under a week rule given by its two parameters.
///
/// A week rule needs exactly two things: which weekday a week begins on,
/// and which day of January is always in week 1. ISO 8601 says Monday and
/// the 4th; the English-language convention, which is what moment.js uses
/// by default, says Sunday and the 1st. Everything else follows.
///
/// Because a week belongs wholly to one year, the days at either end of a
/// calendar year may fall in a week of its neighbour, which is why the
/// year is returned alongside the week and why formatting a week beside
/// the calendar year would be wrong.
///
/// The offset of week 1 from the start of the year is found from the
/// weekday of the anchoring January day, the day of the year is measured
/// against it, and a result that falls off either end is carried into the
/// neighbouring year. This is moment.js's formulation, followed
/// deliberately so that the two cannot disagree; see `tools/oracle.js`.
pub fn weekOfYear(
    self: Date,
    /// The weekday a week begins on: Monday for ISO 8601.
    week_starts_on: DayOfWeek,
    /// The day of January that is always in week 1: the 4th for ISO 8601.
    january_day_in_first_week: u4,
) Week {
    const offset = firstWeekOffset(self.year, week_starts_on, january_day_in_first_week);
    const day_of_year = @as(i32, self.month.daysBefore(self.year)) + self.day;
    const week = @divFloor(day_of_year - offset - 1, 7) + 1;

    if (week < 1) {
        const previous = self.year - 1;
        return .{
            .year = previous,
            .week = @intCast(week + weeksInYear(previous, week_starts_on, january_day_in_first_week)),
        };
    }

    const in_year = weeksInYear(self.year, week_starts_on, january_day_in_first_week);
    if (week > in_year) return .{ .year = self.year + 1, .week = @intCast(week - in_year) };

    return .{ .year = self.year, .week = @intCast(week) };
}

/// How far week 1 of `year` starts from January 1st, as a day-of-year
/// offset that may be negative when week 1 begins in the previous year.
fn firstWeekOffset(year: Year, week_starts_on: DayOfWeek, january_day_in_first_week: u4) i32 {
    const anchor: Date = .{ .year = year, .month = .Jan, .day = january_day_in_first_week };

    // Where the anchoring day sits within its own week, counting from the
    // day the week begins on rather than from Sunday.
    const within_week = @mod(
        @as(i32, anchor.dayOfWeek().weekdayNumber()) - @as(i32, week_starts_on.weekdayNumber()),
        7,
    );

    return @as(i32, january_day_in_first_week) - 1 - within_week;
}

/// The number of weeks in `year` under this rule, which is 52 or 53, and
/// is what a week falling off either end of a year is carried across.
///
/// Public because parsing needs it to bound a week it was given: week 53
/// is a real week of some years and not of others.
pub fn weeksInYear(year: Year, week_starts_on: DayOfWeek, january_day_in_first_week: u4) i32 {
    const offset = firstWeekOffset(year, week_starts_on, january_day_in_first_week);
    const next = firstWeekOffset(year + 1, week_starts_on, january_day_in_first_week);
    const days: i32 = if (leap.is(year)) 366 else 365;
    return @divTrunc(days - offset + next, 7);
}

test weeksInYear {
    // A year has 53 weeks when it starts on the day the week starts on, or
    // when a leap year starts the day before.
    try std.testing.expectEqual(@as(i32, 52), weeksInYear(2024, .Mon, 4));
    try std.testing.expectEqual(@as(i32, 53), weeksInYear(2026, .Mon, 4));
    try std.testing.expectEqual(@as(i32, 53), weeksInYear(2020, .Mon, 4));

    // The English-language rule puts January 1st in week 1 and so needs a
    // 53rd less often; 2020 and 2026 both have one by the ISO rule and
    // not by this one.
    try std.testing.expectEqual(@as(i32, 52), weeksInYear(2024, .Sun, 1));
    try std.testing.expectEqual(@as(i32, 52), weeksInYear(2020, .Sun, 1));
    try std.testing.expectEqual(@as(i32, 52), weeksInYear(2026, .Sun, 1));
}

test weekOfYear {
    // The two rules disagree about 2024-01-07: ISO weeks begin on Monday,
    // so it is still week 1, while a week beginning on Sunday has already
    // turned over into week 2.
    const january: Date = .{ .year = 2024, .month = .Jan, .day = 7 };
    try std.testing.expectEqual(@as(u8, 1), january.weekOfYear(.Mon, 4).week);
    try std.testing.expectEqual(@as(u8, 2), january.weekOfYear(.Sun, 1).week);
}

/// Returns the ISO 8601 week of this date, and the year that week belongs
/// to. Weeks run Monday to Sunday and week 1 is the one containing
/// January 4th, equivalently the one holding the year's first Thursday.
pub fn isoWeek(self: Date) Week {
    return self.weekOfYear(.Mon, 4);
}

test isoWeek {
    // A date in the middle of a year, where the week-numbering year and
    // the calendar year agree.
    const march = (Date{ .year = 2024, .month = .Mar, .day = 15 }).isoWeek();
    try std.testing.expectEqual(@as(Year, 2024), march.year);
    try std.testing.expectEqual(@as(u8, 11), march.week);

    // January 4th is in week 1 by definition, whatever weekday it is.
    try std.testing.expectEqual(@as(u8, 1), (Date{ .year = 2024, .month = .Jan, .day = 4 }).isoWeek().week);

    // The first days of a year can belong to the last week of the one
    // before: 2027 opens on a Friday, so it is still 2026's week 53.
    const newyear = (Date{ .year = 2027, .month = .Jan, .day = 1 }).isoWeek();
    try std.testing.expectEqual(@as(Year, 2026), newyear.year);
    try std.testing.expectEqual(@as(u8, 53), newyear.week);

    // And the last days of a year can belong to week 1 of the next.
    const yearend = (Date{ .year = 2029, .month = .Dec, .day = 31 }).isoWeek();
    try std.testing.expectEqual(@as(Year, 2030), yearend.year);
    try std.testing.expectEqual(@as(u8, 1), yearend.week);
}

/// Returns the date `day_of_year` days into `year`, counting from 1.
///
/// Values outside the year are carried into its neighbour rather than
/// refused, so day 0 is the last day of the year before and day 366 of an
/// ordinary year is the first of the year after. `weekOfYear`'s inverse
/// needs that, because a week can begin in one year and end in another.
pub fn fromDayOfYear(year: Year, day_of_year: i32) Date {
    const length: i32 = if (leap.is(year)) 366 else 365;

    if (day_of_year <= 0) {
        const previous = year - 1;
        const before: i32 = if (leap.is(previous)) 366 else 365;
        return fromDayOfYear(previous, before + day_of_year);
    }
    if (day_of_year > length) return fromDayOfYear(year + 1, day_of_year - length);

    var month: Month = .Jan;
    var remaining = day_of_year;
    while (remaining > month.lastDay(year)) {
        remaining -= month.lastDay(year);
        month = month.next();
    }
    return .{ .year = year, .month = month, .day = @intCast(remaining) };
}

test fromDayOfYear {
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Jan, .day = 1 }, fromDayOfYear(2024, 1));
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, fromDayOfYear(2024, 75));
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Dec, .day = 31 }, fromDayOfYear(2024, 366));

    // Out of range carries into the neighbouring year rather than failing.
    try std.testing.expectEqual(Date{ .year = 2023, .month = .Dec, .day = 31 }, fromDayOfYear(2024, 0));
    try std.testing.expectEqual(Date{ .year = 2025, .month = .Jan, .day = 1 }, fromDayOfYear(2024, 367));
    try std.testing.expectEqual(Date{ .year = 2026, .month = .Jan, .day = 1 }, fromDayOfYear(2025, 366));
}

/// Returns the date of `weekday` in `week` of `week_year`, under a week
/// rule given the way `weekOfYear` takes one. This is that function's
/// inverse.
///
/// The week may reach outside its numbering year at either end, which is
/// the whole point of a week-numbering year, so the result can land in the
/// year before or after: week 1 of 2027 begins on 2026-12-27.
pub fn fromWeek(
    week_year: Year,
    week: u16,
    weekday: DayOfWeek,
    week_starts_on: DayOfWeek,
    january_day_in_first_week: u4,
) Date {
    // Where the weekday sits within its week, counting from the day the
    // week begins on rather than from Sunday.
    const within_week = @mod(
        @as(i32, weekday.weekdayNumber()) - @as(i32, week_starts_on.weekdayNumber()),
        7,
    );

    const offset = firstWeekOffset(week_year, week_starts_on, january_day_in_first_week);
    return fromDayOfYear(week_year, 1 + 7 * (@as(i32, week) - 1) + within_week + offset);
}

test fromWeek {
    // ISO: Monday starts the week and week 1 holds January 4th.
    try std.testing.expectEqual(
        Date{ .year = 2001, .month = .Jan, .day = 4 },
        fromWeek(2001, 1, .Thu, .Mon, 4),
    );
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        fromWeek(2024, 11, .Fri, .Mon, 4),
    );

    // A week can reach outside its numbering year: 2026's week 53 runs to
    // the Sunday after New Year's Day 2027.
    try std.testing.expectEqual(
        Date{ .year = 2027, .month = .Jan, .day = 3 },
        fromWeek(2026, 53, .Sun, .Mon, 4),
    );
    try std.testing.expectEqual(
        Date{ .year = 2026, .month = .Dec, .day = 28 },
        fromWeek(2026, 53, .Mon, .Mon, 4),
    );

    // It is the inverse of `weekOfYear`, under either rule.
    for ([_]Date{
        .{ .year = 2024, .month = .Mar, .day = 15 },
        .{ .year = 2027, .month = .Jan, .day = 1 },
        .{ .year = 2029, .month = .Dec, .day = 31 },
    }) |date| {
        const iso = date.isoWeek();
        try std.testing.expectEqual(date, fromWeek(iso.year, iso.week, date.dayOfWeek(), .Mon, 4));

        const locale = date.localeWeek();
        try std.testing.expectEqual(date, fromWeek(locale.year, locale.week, date.dayOfWeek(), .Sun, 1));
    }
}

/// Returns the week of this date under the English-language convention,
/// where weeks run Sunday to Saturday and week 1 is the one containing
/// January 1st, and the year that week belongs to.
///
/// This is what the `w` and `gg` format sequences write, because it is
/// what moment.js's default locale means by a week. `isoWeek` is the
/// other rule, and the `W` and `GG` sequences.
pub fn localeWeek(self: Date) Week {
    return self.weekOfYear(.Sun, 1);
}

test localeWeek {
    // January 1st is always in week 1, whatever weekday it falls on.
    try std.testing.expectEqual(@as(u8, 1), (Date{ .year = 2024, .month = .Jan, .day = 1 }).localeWeek().week);
    try std.testing.expectEqual(@as(u8, 1), (Date{ .year = 2027, .month = .Jan, .day = 1 }).localeWeek().week);

    // 2026-12-31 is a Thursday, in the week that holds 2027's January
    // 1st, so it is already week 1 of 2027 by this rule while ISO still
    // calls it week 53 of 2026.
    const yearend = (Date{ .year = 2026, .month = .Dec, .day = 31 }).localeWeek();
    try std.testing.expectEqual(@as(Year, 2027), yearend.year);
    try std.testing.expectEqual(@as(u8, 1), yearend.week);
    try std.testing.expectEqual(@as(Year, 2026), (Date{ .year = 2026, .month = .Dec, .day = 31 }).isoWeek().year);
}

test dayOfWeek {
    // The epoch was a Thursday.
    try std.testing.expectEqual(DayOfWeek.Thu, (Date{ .year = 1970, .month = .Jan, .day = 1 }).dayOfWeek());
    try std.testing.expectEqual(DayOfWeek.Fri, (Date{ .year = 2024, .month = .Mar, .day = 15 }).dayOfWeek());
}
