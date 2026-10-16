// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Howard Hinnant's `civil_from_days` and `days_from_civil`, kept as a
//! reference to check `Date.fromDayNumber` and
//! `Date.toDayNumber` against. It is not part of the library:
//! `root.zig` does not export it, and nothing outside the tests, the fuzz
//! targets and `tools/verify_days.zig` calls it.
//!
//! The library converts in both directions with Ben Joffe's algorithms,
//! which are faster and much harder to see are right. These are the ones
//! that are easy to see are right, from *chrono-Compatible Low-Level Date
//! Algorithms*, which the page itself dates 2021-09-01:
//! <https://howardhinnant.github.io/date_algorithms.html>. It is written
//! out as the paper writes it, in `i64` throughout and with nothing from
//! the rest of the library, so that a mistake in `Date` or `Month` cannot
//! be repeated here and agree with itself.
//!
//! Hinnant dedicates the algorithms to the public domain ("Consider these
//! donated to the public domain").

const std = @import("std");

/// A proleptic Gregorian date, in plain integers.
pub const Civil = struct {
    year: i64,
    /// 1 through 12.
    month: u8,
    /// 1 through 31.
    day: u8,
};

/// Returns the date that is `days` days after 1970-01-01; negative values
/// give dates before it.
///
/// Adding 719468 moves the count off 1970-01-01 and onto 0000-03-01, the
/// first day of an era: one 400-year cycle, 146097 days long, after which
/// the calendar repeats exactly. Dividing by 146097, flooring, gives the
/// era and the remainder the day-of-era. The year-of-era comes out of the
/// day-of-era by `(doe - doe/1460 + doe/36524 - doe/146096) / 365`, whose
/// three corrections are the three days on which a plain `doe / 365` steps
/// a year early: day 1460, still year 3 because the first four years hold
/// 1461 days; day 36524, already year 100 because the first century holds
/// 36524; and day 146096, the last day of the era, which would otherwise
/// be year 400. What is left is a day-of-year counted from 1 March, and
/// `(5 * doy + 2) / 153` turns that into a month because March-based month
/// lengths run 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 28 — a line
/// fits the first eleven exactly, and February's short month is at the end
/// where nothing follows it to be thrown off. January and February then
/// belong to the next calendar year.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

test civilFromDays {
    try std.testing.expectEqual(Civil{ .year = 1970, .month = 1, .day = 1 }, civilFromDays(0));
    try std.testing.expectEqual(Civil{ .year = 1969, .month = 12, .day = 31 }, civilFromDays(-1));
    try std.testing.expectEqual(Civil{ .year = 2023, .month = 9, .day = 5 }, civilFromDays(19605));

    // The leap day of a year divisible by 400, and the day after it.
    try std.testing.expectEqual(Civil{ .year = 2000, .month = 2, .day = 29 }, civilFromDays(11016));
    try std.testing.expectEqual(Civil{ .year = 2000, .month = 3, .day = 1 }, civilFromDays(11017));

    // 0000-03-01 is the first day of an era, and the day before it is a
    // leap day, because year 0 is divisible by 400.
    try std.testing.expectEqual(Civil{ .year = 0, .month = 3, .day = 1 }, civilFromDays(-719468));
    try std.testing.expectEqual(Civil{ .year = 0, .month = 2, .day = 29 }, civilFromDays(-719469));
}

/// Returns the number of days from 1970-01-01 to `date`; negative for dates
/// before it. `date` must be a real date.
///
/// `civilFromDays` read backwards. January and February are moved into the
/// previous year, so that the year begins on 1 March and the leap day is
/// its last day. The year is split into an era and a year-of-era, flooring
/// so that years before 0 land in negative eras. `(153 * mp + 2) / 5` is
/// the day-of-year of the first of the March-based month `mp`, the line
/// that `(5 * doy + 2) / 153` inverts going the other way. The day-of-era
/// is then 365 days a year plus a leap day every fourth year, less one
/// every hundredth; the four-hundredth is the era boundary itself. Taking
/// 719468 off moves the count from 0000-03-01 back onto 1970-01-01.
pub fn daysFromCivil(date: Civil) i64 {
    const y = if (date.month <= 2) date.year - 1 else date.year;
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const m: i64 = date.month;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + date.day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test daysFromCivil {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(.{ .year = 1970, .month = 1, .day = 1 }));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(.{ .year = 1969, .month = 12, .day = 31 }));
    try std.testing.expectEqual(@as(i64, 19605), daysFromCivil(.{ .year = 2023, .month = 9, .day = 5 }));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(.{ .year = 2000, .month = 2, .day = 29 }));
    try std.testing.expectEqual(@as(i64, -719468), daysFromCivil(.{ .year = 0, .month = 3, .day = 1 }));
    try std.testing.expectEqual(@as(i64, -719469), daysFromCivil(.{ .year = 0, .month = 2, .day = 29 }));

    // The two are each other's inverse.
    var days: i64 = -1_000_000;
    while (days <= 1_000_000) : (days += 1) {
        try std.testing.expectEqual(days, daysFromCivil(civilFromDays(days)));
    }
}
