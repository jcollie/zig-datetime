// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A calendar date: a year, a month and a day, with no time of day and no
//! timezone attached.
//!
//! A date is converted to and from a *day number*, a count of days from
//! 1970-01-01, by two of Ben Joffe's algorithms, one in each direction.
//! Both rest on two ideas from Howard Hinnant's *chrono-Compatible
//! Low-Level Date Algorithms*, which the page itself dates 2021-09-01:
//! <https://howardhinnant.github.io/date_algorithms.html>. The year is
//! shifted to start in March, so that the leap day falls at the end of it
//! and the month lengths become a repeating pattern that a single division
//! can invert. And the calendar is cut into *eras* of 400 years, which is
//! the period after which the proleptic Gregorian calendar repeats exactly:
//! every era is 146097 days long, whichever one it is.
//!
//! **Day number to date** is Joffe's *A Very Fast 64-Bit Date Algorithm*
//! (2025-11-23): <https://www.benjoffe.com/fast-date-64>. It keeps the
//! March-based year but counts years *backwards* from a far future leap
//! day, which lines the long four-year cycles and the long centuries up
//! with the start of the count, and it does the whole conversion in four
//! multiplications. See `fromDaysSinceStartOfEra`.
//!
//! **Date to day number** is the inverse from Joffe's *The Julian Map*
//! (2025-11-03): <https://www.benjoffe.com/fast-date>, a refinement of
//! Neri and Schneider's. It shifts the year forward by whole eras so that
//! all of it is unsigned, and counts the days before a year as 365 a year
//! plus the leap days, with no division by an era at all. See
//! `toDaysSinceStartOfEra`.
//!
//! Both build on the fixed-point technique of Neri and Schneider,
//! *Euclidean affine functions and their application to calendar
//! algorithms* (2022), <https://doi.org/10.1002/spe.3172>, and both are
//! written here from the descriptions in the articles, not translated from
//! the reference implementations.
//!
//! They replaced Hinnant's `civil_from_days` and `days_from_civil`, which
//! measured 7.0 ns and 4.3 ns a conversion in `zig build bench` against
//! Joffe's 2.0 ns and 2.5 ns (ReleaseFast, x86-64). Hinnant's are much
//! easier to see are right, so they are kept in `hinnant.zig` as the
//! reference the tests compare against, and `zig build verify-days` checks
//! both of Joffe's against them for every day number a `Date` can hold.
//! Hinnant dedicates his algorithms to the public domain ("Consider these
//! donated to the public domain").

const Date = @This();

const std = @import("std");
const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const leap = @import("leap.zig");
const iso8601 = @import("iso8601.zig");
const json = @import("json.zig");
const hinnant = @import("hinnant");

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

/// The day numbers of the first and last dates a `Date` can hold.
///
/// `DaysType` is sized for 366 days a year, which is more than a year
/// actually has, so its own extremes name years a `Year` cannot. These
/// are the real bounds, and what a saturating conversion saturates to.
pub const min_days: DaysType = (Date{
    .year = std.math.minInt(Year),
    .month = .Jan,
    .day = 1,
}).toDaysSinceStartOfEra();

pub const max_days: DaysType = (Date{
    .year = std.math.maxInt(Year),
    .month = .Dec,
    .day = 31,
}).toDaysSinceStartOfEra();

test min_days {
    // The bounds are dates, and round trip like any other.
    try std.testing.expectEqual(
        Date{ .year = std.math.minInt(Year), .month = .Jan, .day = 1 },
        fromDaysSinceStartOfEra(min_days),
    );
    try std.testing.expectEqual(
        Date{ .year = std.math.maxInt(Year), .month = .Dec, .day = 31 },
        fromDaysSinceStartOfEra(max_days),
    );

    // And they are inside what `DaysType` can hold, with room to spare,
    // because it is sized for a longer year than there is.
    try std.testing.expect(min_days > std.math.minInt(DaysType));
    try std.testing.expect(max_days < std.math.maxInt(DaysType));
}

/// The first and last instants that fall on a date a `Date` can hold, as
/// seconds since the epoch.
///
/// Outside these an instant has no calendar date at all, so anything that
/// converts one saturates rather than trapping. That keeps the conversion
/// total, and makes the answer wrong in the same way the question was.
pub const min_seconds: i64 = @as(i64, min_days) * std.time.s_per_day;
pub const max_seconds: i64 = @as(i64, max_days) * std.time.s_per_day + (std.time.s_per_day - 1);

test min_seconds {
    // The bounds are instants on the bounding dates.
    try std.testing.expectEqual(min_days, daysFromSecondsSaturating(min_seconds));
    try std.testing.expectEqual(max_days, daysFromSecondsSaturating(max_seconds));

    // And a second further out saturates rather than moving.
    try std.testing.expectEqual(min_days, daysFromSecondsSaturating(min_seconds - 1));
    try std.testing.expectEqual(max_days, daysFromSecondsSaturating(max_seconds + 1));
}

/// Returns the day number `seconds` seconds after the epoch falls in,
/// clamped to the range a `Date` can hold.
///
/// An `i64` of seconds reaches far outside the calendar: a `Year` is an
/// `i32`, so the furthest date there is sits around 6.8e16 seconds from
/// the epoch and an `i64` goes to 9.2e18. Converting the excess would be
/// an `@intCast` that cannot fit, which is a panic in a safe build and
/// illegal behaviour in a fast one.
///
/// Clamping rather than refusing keeps every caller total. The answer for
/// an instant outside the calendar is the first or last date there is,
/// which is wrong in the same way that the question was.
pub fn daysFromSecondsSaturating(seconds: i64) DaysType {
    const days = @divFloor(seconds, std.time.s_per_day);
    if (days < min_days) return min_days;
    if (days > max_days) return max_days;
    return @intCast(days);
}

test daysFromSecondsSaturating {
    try std.testing.expectEqual(@as(DaysType, 0), daysFromSecondsSaturating(0));
    try std.testing.expectEqual(@as(DaysType, 1), daysFromSecondsSaturating(std.time.s_per_day));

    // Floor division, so a second before the epoch is the day before it.
    try std.testing.expectEqual(@as(DaysType, -1), daysFromSecondsSaturating(-1));

    // Past the end of the calendar the answer stops moving rather than
    // wrapping or trapping, and what it stops at is a date.
    try std.testing.expectEqual(max_days, daysFromSecondsSaturating(std.math.maxInt(i64)));
    try std.testing.expectEqual(min_days, daysFromSecondsSaturating(std.math.minInt(i64)));
    _ = fromDaysSinceStartOfEra(daysFromSecondsSaturating(std.math.maxInt(i64)));
    _ = fromDaysSinceStartOfEra(daysFromSecondsSaturating(std.math.minInt(i64)));
}

/// Returns the date that is `days` days after 1970-01-01; negative values
/// give dates before the epoch. Asserts that `days` is in
/// `[min_days, max_days]`.
///
/// This is Ben Joffe's 64-bit algorithm. Like Hinnant's it works in
/// March-based years, which put the leap day at the end of a year, but it
/// counts them backwards, and that is the idea everything else follows
/// from.
///
/// **Reverse the count.** `rev = d_shift - days` counts days backwards
/// from 29 February of the year `400 * eras`, a leap day ending a
/// March-based year in a year divisible by 400. `d_shift` is that day's
/// number: 719469 days back from 1970-01-01 is 0000-02-29, and `eras`
/// eras of 146097 days on from there. Counted backwards from such a day,
/// the first year is the 366-day one and the first century the 36525-day
/// one, so the long one of each cycle comes *first*. Counted forwards from
/// 1 March it comes last, and that is where the `+ 3` in the usual
/// `(4 * days + 3) / 146097` comes from. Joffe picked `eras`
/// to centre the widest 64-bit range on the epoch; a `Date` uses a small
/// part of it.
///
/// **Centuries, then the Julian map.** `cen = rev / 36524.25`, done as a
/// multiplication by `c1 = floor(2^64 * 4 / 146097)` keeping the high 64
/// bits, counts the whole centuries behind `rev`. With the long century
/// first, the boundaries at 36525, 73049 and 109573 days are each just
/// past a multiple of 36524.25, so this is exact. `jul = rev + cen - cen
/// / 4` then puts back the leap day the Gregorian calendar drops in three
/// centuries out of four, and what is left counts days as though every
/// fourth year were a leap year: a Julian count, with no century rule
/// left in it.
///
/// **Years.** `num = jul * c2`, with `c2 = ceil(2^64 * 4 / 1461)`, is
/// `jul / 365.25` in 64.64 fixed point. Its high half is the number of
/// whole years behind `jul`, exact for the same reason the centuries were,
/// and `yrs = y_shift - high` turns that back into a forward March-based
/// year: `y_shift = 400 * eras - 1`, the year whose March starts the last
/// year before the count began. Its low half `low` is how far into the
/// backward year `jul` is, as a fraction of 365.25 days.
///
/// **The year part, and its drift.** `ypt = low * 782432 >> 64` scales
/// that fraction so that a day is about 2142.2 units: it is a day of the
/// year counted backwards, without the division Neri and Schneider spend
/// on getting it exactly. Measuring a year in units of 365.25 days rather
/// than its real length leaves it a quarter of a day out per year,
/// resetting every four: 0, ¾, ½ and ¼ of a day in the four years of a
/// cycle, leap year first.
///
/// **January and February.** `ypt < 126464`, which is 59.03 days, is the
/// first 59 or 60 days of a backward year: the January and February that
/// end the March-based year and belong to the next calendar one. That is
/// `bump`, and the year is incremented by it at the end.
///
/// **One linear map to month and day.** `n = (yrs % 4) * 512 + shift -
/// ypt` turns the count forwards again and lays it out with 65536 units a
/// month, so the month is `n >> 16` and the day is the low 16 bits divided
/// by about 2140. Those are close to the 30.6-day average of a March-based
/// month, which is the line Hinnant's `(5 * doy + 2) / 153` draws, and
/// the leeway between 2140 and the true 2142.2 a day is what lets the line
/// land on every month boundary. `shift` places 1 March at the bottom of
/// month 3; for January and February it is 786432, twelve months of 65536,
/// smaller, so they come out as 1 and 2 rather than 13 and 14 without a
/// separate subtraction. `(yrs % 4) * 512` cancels the drift: in a
/// calendar of 32-day months 512 units is a quarter of a day, so it adds
/// ¾, ½, ¼ and 0 of a day in the four years, and after it every common
/// year is a quarter of a day behind and the leap year three quarters
/// ahead. That is one day apart, the leap day, and a quarter of a day is
/// inside the leeway. `yrs` may have wrapped below zero, but 2^64 is a
/// multiple of 4, so `yrs % 4` is the same as it would have been unwrapped.
///
/// **The day.** `(n % 65536) * c3 >> 64`, with `c3 = floor(2^64 / 2140)`,
/// divides the low 16 bits by 2140 and gives the day of the month from
/// zero. Neri and Schneider divide by 2141 at this point; Joffe found 2140
/// to be the divisor the drift correction needs.
///
/// Every division is a multiplication whose high half is wanted, which is
/// the upper register of a 64-by-64 multiply and costs nothing more to
/// take, so the whole conversion is four multiplications and no division.
///
/// Joffe gives the range as ±1.89 trillion years, from testing rather than
/// proof; `tools/verify_days.zig` checks every day number from `min_days`
/// to `max_days` against Hinnant's `civil_from_days` in `hinnant.zig`. On
/// 2026-10-16 all 1,568,704,592,610 of them agreed. The
/// article also gives smaller constants for ARM, where large immediates
/// are slow to load; this is the x86-64 form, which is correct everywhere
/// and has not been measured on ARM.
pub fn fromDaysSinceStartOfEra(days: DaysType) Date {
    std.debug.assert(days >= min_days and days <= max_days);

    const eras: u64 = 4726498270;
    const d_shift: u64 = 146097 * eras - 719469;
    const y_shift: u64 = 400 * eras - 1;
    const c1: u64 = 505054698555331;
    const c2: u64 = 50504432782230121;
    const c3: u64 = 8619973866219416;

    // `days` is far inside `d_shift` either way, so this never wraps.
    const rev: u64 = @intCast(@as(i64, d_shift) - days);

    const cen: u64 = @truncate((@as(u128, rev) * c1) >> 64);
    const jul: u64 = rev + cen - cen / 4;

    const num: u128 = @as(u128, jul) * c2;
    const yrs: u64 = y_shift -% @as(u64, @truncate(num >> 64));
    const low: u64 = @truncate(num);
    const ypt: u64 = @truncate((@as(u128, 782432) * low) >> 64);

    const bump = ypt < 126464;
    const shift: u64 = if (bump) 191360 else 977792;

    const n: u64 = (yrs % 4) * 512 + shift - ypt;
    const day_0: u64 = @truncate((@as(u128, n % 65536) * c3) >> 64);

    const month = n / 65536;
    std.debug.assert(month >= 1 and month <= 12);

    const year = @as(i64, @bitCast(yrs)) + @intFromBool(bump);
    std.debug.assert(year >= std.math.minInt(Year) and year <= std.math.maxInt(Year));

    const date: Date = .{
        .year = @intCast(year),
        .month = @fromBackingInt(@intCast(month)),
        .day = @intCast(day_0 + 1),
    };
    std.debug.assert(date.isRegular());
    return date;
}

/// The year a day number falls in, together with the day number of that
/// year's first of January.
///
/// The date is worked out in full and the days before it in its year are
/// taken back off, in March-based terms so that there is one line and no
/// table: from March on, `(153 * (month - 3) + 2) / 5` is the run from the
/// first of March to the first of the month — the same line Hinnant's
/// `days_from_civil` draws — and the first of January is 59 days before
/// the first of March, or 60 in a leap year. In January and February
/// there is no leap day behind the date to count, so the only question is
/// whether January's 31 days are.
///
/// `posixtz` works out every switch of a rule as an offset from the first
/// of January, and this is where that day comes from.
pub fn yearAndFirstDay(days: DaysType) struct { year: Year, january_first: DaysType } {
    const date = fromDaysSinceStartOfEra(days);
    const into_month: DaysType = date.day - 1;
    const january_first = switch (date.month) {
        .Jan => days - into_month,
        .Feb => days - into_month - 31,
        else => days - into_month -
            @divTrunc(153 * (@as(DaysType, date.month.monthNumber()) - 3) + 2, 5) -
            @as(DaysType, if (leap.is(date.year)) 60 else 59),
    };
    return .{ .year = date.year, .january_first = january_first };
}

test yearAndFirstDay {
    const new_year = (Date{ .year = 2024, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();

    // A day names its own year, and the first of January names itself.
    const opening = yearAndFirstDay(new_year);
    try std.testing.expectEqual(@as(Year, 2024), opening.year);
    try std.testing.expectEqual(new_year, opening.january_first);

    const summer = yearAndFirstDay((Date{ .year = 2024, .month = .Jul, .day = 4 }).toDaysSinceStartOfEra());
    try std.testing.expectEqual(@as(Year, 2024), summer.year);
    try std.testing.expectEqual(new_year, summer.january_first);

    // And the day before belongs to the year before.
    try std.testing.expectEqual(@as(Year, 2023), yearAndFirstDay(new_year - 1).year);

    // Every day of a leap year and the ones either side of it names the
    // first of January that the other direction, which shares nothing
    // with it, puts in front of it.
    var day = (Date{ .year = 2023, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    const last = (Date{ .year = 2025, .month = .Dec, .day = 31 }).toDaysSinceStartOfEra();
    while (day <= last) : (day += 1) try expectFirstDay(day);

    // And so do the days at either end of the calendar.
    for (0..800) |i| {
        try expectFirstDay(min_days + @as(DaysType, @intCast(i)));
        try expectFirstDay(max_days - @as(DaysType, @intCast(i)));
    }
}

fn expectFirstDay(day: DaysType) !void {
    const placed = yearAndFirstDay(day);
    const first = (Date{ .year = placed.year, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    try std.testing.expectEqual(first, placed.january_first);
    try std.testing.expect(day >= first and day - first < 366);
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

/// Asserts that `fromDaysSinceStartOfEra` gives the date Hinnant's
/// `civil_from_days` does for `days`, and that `toDaysSinceStartOfEra`
/// takes that date back to `days`, as Hinnant's `days_from_civil` does.
fn expectHinnant(days: DaysType) !void {
    const expected = hinnant.civilFromDays(days);
    const got = fromDaysSinceStartOfEra(days);
    errdefer std.debug.print("day {d}: Hinnant {any}, got {any}\n", .{ days, expected, got });
    try std.testing.expectEqual(expected.year, got.year);
    try std.testing.expectEqual(expected.month, got.month.monthNumber());
    try std.testing.expectEqual(expected.day, got.day);
    try std.testing.expectEqual(@as(i64, days), hinnant.daysFromCivil(expected));
    try std.testing.expectEqual(days, got.toDaysSinceStartOfEra());
}

test expectHinnant {
    try expectHinnant(0);
    try expectHinnant(min_days);
    try expectHinnant(max_days);
}

// Joffe's algorithms against Hinnant's, which are slower and easy to check
// by eye, in both directions, wherever a fixed-point calendar is most likely to slip: around
// the epoch, around the end of every century in several eras near and
// far, and at both ends of the range a `Date` holds. `zig build
// verify-days` runs the same comparison over every day number there is.
test "fromDaysSinceStartOfEra and toDaysSinceStartOfEra agree with Hinnant" {
    // Every day of eleven thousand years around the epoch.
    var day: DaysType = -2_000_000;
    while (day <= 2_000_000) : (day += 1) try expectHinnant(day);

    // A week either side of 1 January and of the end of February of every
    // century year, in the eras around year 0 and the ones around the
    // ends of a `Year`.
    const centuries = [_][2]i64{
        .{ -400_000, 400_000 },
        .{ std.math.minInt(Year) + 1, std.math.minInt(Year) + 400_000 },
        .{ std.math.maxInt(Year) - 400_000, std.math.maxInt(Year) - 1 },
    };
    for (centuries) |span| {
        var year = span[0] - @mod(span[0], 100) + 100;
        while (year <= span[1]) : (year += 100) {
            inline for (.{ Month.Jan, Month.Mar }) |month| {
                const anchor: DaysType = @intCast(hinnant.daysFromCivil(.{ .year = year, .month = month.monthNumber(), .day = 1 }));
                var offset: DaysType = -7;
                while (offset <= 7) : (offset += 1) try expectHinnant(anchor + offset);
            }
        }
    }

    // A thousand years at each end.
    for (0..366_000) |i| {
        try expectHinnant(min_days + @as(DaysType, @intCast(i)));
        try expectHinnant(max_days - @as(DaysType, @intCast(i)));
    }
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
///
/// This is the inverse in Ben Joffe's *The Julian Map*, a refinement of
/// Neri and Schneider's (see the top of this file). Like Hinnant's
/// `days_from_civil` it moves January and February to the end of the
/// year before, so that a year runs from 1 March and its leap day is its
/// last day, but it never splits the year into eras. It works in four
/// steps.
///
/// First the year is shifted forward by `shift_eras` whole eras of 400
/// years, enough that even January of the earliest `Year` lands on a
/// non-negative year, so everything after is unsigned and every division
/// floors without a correction. A whole number of eras changes nothing
/// about which years are leap years, because the calendar repeats every
/// era.
///
/// Then the days before 1 March of that March-based year `y` are counted
/// from 1 March of year 0: 365 a year, plus a leap day at the end of every
/// fourth year, `y / 4`, less one every hundredth, `y / 100`, plus one back
/// every four-hundredth, `y / 400`, which is written `cent / 4` because
/// `cent` is `y / 100` already. Joffe writes `y * 365 + y / 4` where Neri
/// and Schneider write `y * 1461 / 4`. The two are equal, and the first is
/// what lets his 32-bit version take a shift this large without `y * 1461`
/// overflowing. In 64 bits either fits; the first is kept because it is
/// the count as just described.
///
/// Then the days from 1 March to the first of the month are
/// `(979 * m - 2919) / 32`, Neri and Schneider's fixed-point form of the
/// same line as Hinnant's `(153 * mp + 2) / 5`: with `m` running 3 for
/// March up to 14 for February, its slope of 979/32 = 30.59 days a month
/// steps over the March-based month lengths exactly, giving 0, 31, 61 and
/// so on up to 337 for February. January and February get 12 added to `m`
/// because they now close the year before.
///
/// Last, the day of the month is added and `rata_shift` takes off what the
/// first step put on: the shifted eras, the 719468 days from 0000-03-01 to
/// 1970-01-01, and 1 because the day of the month counts from 1.
///
/// The largest value along the way is the shifted year's day count, about
/// 1.6 * 10^12, far inside a `u64`. `zig build verify-days` checks that
/// this undoes `fromDaysSinceStartOfEra` for every day number a `Date` can
/// hold, which is every date there is, and on 2026-10-16 it did for all
/// 1,568,704,592,610 of them. The tests compare it with Hinnant's
/// `days_from_civil` in `hinnant.zig`.
pub fn toDaysSinceStartOfEra(self: Date) DaysType {
    std.debug.assert(self.day >= 1 and self.day <= self.month.lastDay(self.year));

    // 5368710 eras is 2147484000 years, one era more than the 2^31 + 1 a
    // year shifted out of January of `minInt(Year)` needs.
    const shift_eras: u64 = (1 << 31) / 400 + 1;
    const year_shift: u64 = 400 * shift_eras;
    const rata_shift: u64 = 719468 + 146097 * shift_eras + 1;

    const january_or_february = self.month == .Jan or self.month == .Feb;
    const year: u64 = @intCast(@as(i64, self.year) + year_shift - @intFromBool(january_or_february));
    const cent = year / 100;
    const m: u64 = @as(u64, self.month.monthNumber()) + if (january_or_february) @as(u64, 12) else 0;

    const year_days = year * 365 + year / 4 - cent + cent / 4;
    const month_days = (979 * m - 2919) / 32;
    const days: i64 = @intCast(year_days + month_days + self.day);
    return @intCast(days - @as(i64, @intCast(rata_shift)));
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

/// A week-numbering year: a `Year` and one more at each end.
///
/// The last days of December can belong to week 1 of the year after, and
/// the first days of January to the last week of the year before. At the
/// two ends of the calendar that neighbouring year is one a `Year` cannot
/// hold, so the week of 31 December of the last `Year` would have nowhere
/// to say which year it is in. This is one bit wider, which is exactly
/// enough, and means `weekOfYear` never has to answer with a year that is
/// not the right one.
pub const WeekYear = std.math.IntFittingRange(
    @as(i64, std.math.minInt(Year)) - 1,
    @as(i64, std.math.maxInt(Year)) + 1,
);

test WeekYear {
    try std.testing.expect(std.math.maxInt(WeekYear) > std.math.maxInt(Year));
    try std.testing.expect(std.math.minInt(WeekYear) < std.math.minInt(Year));
}

/// A week of some year, and the year that week belongs to.
pub const Week = struct {
    /// The week-numbering year, which is not always the calendar year:
    /// see `weekOfYear`. A `WeekYear` rather than a `Year`, because at the
    /// ends of the calendar it can be the year just past either end.
    year: WeekYear,
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
    ///
    /// May be zero or negative, which names a day of the December before
    /// and is what a rule whose first week reaches back into the old year
    /// looks like. moment writes the same thing as `doy`, and eight of
    /// its locales use a `doy` that puts this at -5.
    january_day_in_first_week: i8,
) Week {
    const offset = firstWeekOffset(self.year, week_starts_on, january_day_in_first_week);
    const day_of_year = @as(i32, self.month.daysBefore(self.year)) + self.day;
    const week = @divFloor(day_of_year - offset - 1, 7) + 1;

    // The neighbouring years are `WeekYear`s, which reach one year past
    // either end of the calendar, so these never overflow and never have
    // to answer with a year other than the right one.
    if (week < 1) {
        const previous = @as(WeekYear, self.year) - 1;
        return .{
            .year = previous,
            .week = @intCast(week + weeksInYear(previous, week_starts_on, january_day_in_first_week)),
        };
    }

    const in_year = weeksInYear(self.year, week_starts_on, january_day_in_first_week);
    if (week > in_year) return .{ .year = @as(WeekYear, self.year) + 1, .week = @intCast(week - in_year) };

    return .{ .year = self.year, .week = @intCast(week) };
}

/// How far week 1 of `year` starts from January 1st, as a day-of-year
/// offset that may be negative when week 1 begins in the previous year.
fn firstWeekOffset(year: i64, week_starts_on: DayOfWeek, january_day_in_first_week: i8) i32 {
    // Counted from January 1st rather than built as a date, because the
    // anchoring day may be zero or negative -- a day of the December
    // before, which no `Date` can hold -- and stepping a weekday by a
    // day count works either way.
    const anchor_weekday = @mod(
        januaryFirstWeekday(year) + @as(i32, january_day_in_first_week) - 1,
        7,
    );

    // Where the anchoring day sits within its own week, counting from the
    // day the week begins on rather than from Sunday.
    const within_week = @mod(anchor_weekday - @as(i32, week_starts_on.weekdayNumber()), 7);

    return @as(i32, january_day_in_first_week) - 1 - within_week;
}

/// The number of weeks in `year` under this rule, which is 52 or 53, and
/// is what a week falling off either end of a year is carried across.
///
/// Public because parsing needs it to bound a week it was given: week 53
/// is a real week of some years and not of others.
///
/// It takes a `WeekYear`, since `weekOfYear` asks it about the years either
/// side of the calendar, and measures a year against the one after it in
/// an `i64`, so even the last `WeekYear` has a real year after it rather
/// than being measured against itself.
pub fn weeksInYear(year: WeekYear, week_starts_on: DayOfWeek, january_day_in_first_week: i8) i32 {
    const offset = firstWeekOffset(year, week_starts_on, january_day_in_first_week);
    const next = firstWeekOffset(@as(i64, year) + 1, week_starts_on, january_day_in_first_week);
    const days: i32 = if (isLeapAnyYear(year)) 366 else 365;
    return @divTrunc(days - offset + next, 7);
}

/// The weekday of 1 January of any year at all, as a `weekdayNumber`,
/// Sunday = 0.
///
/// Gauss's formula for the first of January, which needs no date and so
/// works for years a `Date` cannot hold. Each of the three terms steps the
/// weekday by how far a span of years moves it: a common year is 365 days,
/// one more than 52 weeks, so every year moves it by one and each fourth
/// year by one more; a century leaves out one of those leap days, and
/// every fourth century puts it back. Written as residues of the years
/// already passed, that is `1 + 5·(y−1 mod 4) + 4·(y−1 mod 100) +
/// 6·(y−1 mod 400)`, taken mod 7, and `@mod` keeps each residue
/// non-negative so the same expression holds before year zero.
fn januaryFirstWeekday(year: i64) i32 {
    const y = year - 1;
    return @intCast(@mod(1 + 5 * @mod(y, 4) + 4 * @mod(y, 100) + 6 * @mod(y, 400), 7));
}

test januaryFirstWeekday {
    // It agrees with the day count wherever a `Date` can be built to ask,
    // including both ends of the calendar and either side of year zero.
    for ([_]Year{ 1970, 2024, 2025, 2000, 1900, 1, 0, -1, -400, -401, std.math.minInt(Year), std.math.maxInt(Year) }) |year| {
        const january_first: Date = .{ .year = year, .month = .Jan, .day = 1 };
        try std.testing.expectEqual(@as(i32, january_first.dayOfWeek().weekdayNumber()), januaryFirstWeekday(year));
    }
    // And a year past the end is a year's length on from the last one.
    const last: Date = .{ .year = std.math.maxInt(Year), .month = .Jan, .day = 1 };
    const length: i32 = if (leap.is(std.math.maxInt(Year))) 366 else 365;
    try std.testing.expectEqual(
        @mod(@as(i32, last.dayOfWeek().weekdayNumber()) + length, 7),
        januaryFirstWeekday(@as(i64, std.math.maxInt(Year)) + 1),
    );
}

/// `leap.is`, for any year at all rather than only a `Year`, by the same
/// formula; `leap.is` explains it.
fn isLeapAnyYear(year: i64) bool {
    const mask: i64 = if (@rem(year, 25) == 0) 0b1111 else 0b11;
    return year & mask == 0;
}

test isLeapAnyYear {
    for ([_]Year{ 2000, 1900, 2024, 2025, 0, -4, -100, std.math.maxInt(Year), std.math.minInt(Year) }) |year| {
        try std.testing.expectEqual(leap.is(year), isLeapAnyYear(year));
    }
    // Every year in a span around year 0 and at each end of `Year`.
    var year: Year = -100_000;
    while (year <= 100_000) : (year += 1) {
        try std.testing.expectEqual(leap.is(year), isLeapAnyYear(year));
    }
    for (0..1000) |i| {
        const offset: Year = @intCast(i);
        const low = std.math.minInt(Year) + offset;
        const high = std.math.maxInt(Year) - offset;
        try std.testing.expectEqual(leap.is(low), isLeapAnyYear(low));
        try std.testing.expectEqual(leap.is(high), isLeapAnyYear(high));
    }
    // And the years just past either end, which `leap.is` cannot be asked
    // about, against the rule as it is usually written.
    for (1..1000) |i| {
        const offset: i64 = @intCast(i);
        for ([_]i64{ @as(i64, std.math.minInt(Year)) - offset, @as(i64, std.math.maxInt(Year)) + offset }) |y| {
            const textbook = @rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0);
            try std.testing.expectEqual(textbook, isLeapAnyYear(y));
        }
    }
}

test "a week at either end of the calendar names its real year" {
    // The last days of the last `Year` can be in week 1 of the year after
    // it, and the first days of the first `Year` in the last week of the
    // year before. Both are `WeekYear`s, so the answer is exact, and it
    // comes back to the same date. This used to saturate: 31 December of
    // the last year was reported as week 1 of that same year, a week in
    // its January.
    const last = std.math.maxInt(Year);
    const first = std.math.minInt(Year);
    for ([_]struct { DayOfWeek, i8 }{ .{ .Mon, 4 }, .{ .Sun, 1 } }) |rule| {
        var crossed_forwards = false;
        var crossed_backwards = false;
        for (25..32) |day| {
            const date: Date = .{ .year = last, .month = .Dec, .day = @intCast(day) };
            const week = date.weekOfYear(rule[0], rule[1]);
            if (week.year > last) crossed_forwards = true;
            try std.testing.expectEqual(date, fromWeek(week.year, week.week, date.dayOfWeek(), rule[0], rule[1]));
        }
        for (1..8) |day| {
            const date: Date = .{ .year = first, .month = .Jan, .day = @intCast(day) };
            const week = date.weekOfYear(rule[0], rule[1]);
            if (week.year < first) crossed_backwards = true;
            try std.testing.expectEqual(date, fromWeek(week.year, week.week, date.dayOfWeek(), rule[0], rule[1]));
        }
        // With these two rules the calendar's own ends do cross over, so
        // the test is not passing by never reaching the case it is for.
        try std.testing.expect(crossed_forwards or crossed_backwards);
    }
}

test "the week rules answer at the ends of the calendar" {
    // Carrying a week into the year before or after has no year to carry
    // into at the first and last a `Year` can hold. Fuzzing found this
    // as an integer overflow reached from `DateTime.parseWith`, whose
    // `relative_to` is the caller's and can hold any year at all.
    const first = std.math.minInt(Year);
    const last = std.math.maxInt(Year);

    for ([_]Year{ first, first + 1, last - 1, last }) |year| {
        for ([_]DayOfWeek{ .Sun, .Mon, .Sat }) |starts_on| {
            // Including an anchor that puts week one in the December
            // before, which is what a `doy` of 12 comes to, and one that
            // puts it late enough that the first days of January fall in
            // the year before's last week.
            for ([_]i8{ 1, 4, 7, -5 }) |anchor| {
                const weeks = weeksInYear(year, starts_on, anchor);
                try std.testing.expect(weeks >= 1);

                // The first and last day of the year, which are the two
                // that can fall into a neighbouring year's week.
                for ([_]Date{
                    .{ .year = year, .month = .Jan, .day = 1 },
                    .{ .year = year, .month = .Jan, .day = 2 },
                    .{ .year = year, .month = .Dec, .day = 30 },
                    .{ .year = year, .month = .Dec, .day = 31 },
                }) |date| {
                    const found = date.weekOfYear(starts_on, anchor);
                    try std.testing.expect(found.week >= 1);
                }

                // And back the other way, which is where the day of the
                // year runs off the end.
                _ = fromWeek(year, 1, starts_on, starts_on, anchor);
                _ = fromWeek(year, @intCast(weeks), starts_on, starts_on, anchor);
            }
        }
    }

    // A day of the year outside the year is carried into its neighbour,
    // and clamped rather than carried when there is no neighbour.
    try std.testing.expectEqual(
        Date{ .year = first, .month = .Jan, .day = 1 },
        fromDayOfYear(first, -1000),
    );
    try std.testing.expectEqual(
        Date{ .year = last, .month = .Dec, .day = 31 },
        fromDayOfYear(last, 1000),
    );
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
///
/// That is the week calendar of ISO 8601-1:2019, 4.2.2, whose weeks begin
/// on Monday (Table 2) and number `01` to `52` or `53` (4.3.4). As its NOTE
/// says, a week's year and the calendar year "do not always match": the
/// first day of 2019's week 1 is 2018-12-31.
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

    // Saturating, because carrying into a neighbour has no neighbour to
    // carry into at the first and last year a `Year` can hold. Stepping
    // to the same year again would recur for ever, so the day is clamped
    // into the year instead and the answer stays inside the calendar.
    if (day_of_year <= 0) {
        const previous = year -| 1;
        if (previous == year) return .{ .year = year, .month = .Jan, .day = 1 };
        const before: i32 = if (leap.is(previous)) 366 else 365;
        return fromDayOfYear(previous, before + day_of_year);
    }
    if (day_of_year > length) {
        const next = year +| 1;
        if (next == year) return .{ .year = year, .month = .Dec, .day = 31 };
        return fromDayOfYear(next, day_of_year - length);
    }

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
    week_year: WeekYear,
    week: u16,
    weekday: DayOfWeek,
    week_starts_on: DayOfWeek,
    january_day_in_first_week: i8,
) Date {
    // Where the weekday sits within its week, counting from the day the
    // week begins on rather than from Sunday.
    const within_week = @mod(
        @as(i32, weekday.weekdayNumber()) - @as(i32, week_starts_on.weekdayNumber()),
        7,
    );

    const offset = firstWeekOffset(week_year, week_starts_on, january_day_in_first_week);
    const day_of_year = 1 + 7 * (@as(i64, week) - 1) + within_week + offset;

    // Counted as a day number from the first of January of `week_year`,
    // which for the year either side of the calendar is found from the
    // year inside it, since no `Date` of its own can be built to ask. A
    // day number outside the calendar is clamped to its first or last day,
    // as `fromDayOfYear` clamps.
    const january_first: i64 = if (week_year > std.math.maxInt(Year))
        @as(i64, (Date{ .year = std.math.maxInt(Year), .month = .Jan, .day = 1 }).toDaysSinceStartOfEra()) +
            (if (leap.is(std.math.maxInt(Year))) @as(i64, 366) else 365)
    else if (week_year < std.math.minInt(Year))
        @as(i64, (Date{ .year = std.math.minInt(Year), .month = .Jan, .day = 1 }).toDaysSinceStartOfEra()) -
            (if (isLeapAnyYear(week_year)) @as(i64, 366) else 365)
    else
        (Date{ .year = @intCast(week_year), .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();

    const days = std.math.clamp(january_first + day_of_year - 1, min_days, max_days);
    return fromDaysSinceStartOfEra(@intCast(days));
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

/// Writes this date as a JSON string of a calendar date, `"2024-03-15"`, which is
/// what `std.json.Stringify` calls when it meets one, in a field or on its
/// own.
///
/// Reading refuses a time of day, which a `Date` has nowhere to keep, and a
/// date reduced to a month or a year, which does not name a day; see
/// `json.readDate`.
pub fn jsonStringify(self: Date, jw: anytype) !void {
    return json.stringify(jw, self, iso8601.writeDate);
}

test jsonStringify {
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, @as(Date, .{ .year = 2024, .month = .Mar, .day = 15 }), .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\"2024-03-15\"", text);
}

/// Reads one of these from the next token of a JSON document, which has to
/// be a string; `std.json.parseFromSlice` and its relatives call this when
/// they meet the type. See `jsonStringify` for the text, and `json.parse`
/// for what happens to the token.
///
/// A string that is not the representation is `error.InvalidCharacter`, and
/// one whose components are out of range is `error.Overflow`, the errors
/// `std.json` gives for a malformed and an oversized number.
pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Date {
    return json.parse(Date, allocator, source, options, json.readDate);
}

test jsonParse {
    const Record = struct { value: Date };
    const parsed = try std.json.parseFromSlice(Record, std.testing.allocator, "{\"value\":\"2024-03-15\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, parsed.value.value);

    try std.testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(Date, std.testing.allocator, "\"not a date\"", .{}),
    );
}

/// Reads one of these from a `std.json.Value` that has already been
/// parsed, which has to be a string; `std.json.parseFromValue` calls this
/// when it meets the type. See `jsonParse`.
pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Date {
    _ = allocator;
    _ = options;
    return json.parseFromValue(Date, source, json.readDate);
}

test jsonParseFromValue {
    const parsed = try std.json.parseFromValue(Date, std.testing.allocator, .{ .string = "2024-03-15" }, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, parsed.value);
}
