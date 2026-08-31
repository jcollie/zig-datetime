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

test dayOfWeek {
    // The epoch was a Thursday.
    try std.testing.expectEqual(DayOfWeek.Thu, (Date{ .year = 1970, .month = .Jan, .day = 1 }).dayOfWeek());
    try std.testing.expectEqual(DayOfWeek.Fri, (Date{ .year = 2024, .month = .Mar, .day = 15 }).dayOfWeek());
}
