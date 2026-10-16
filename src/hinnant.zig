// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Howard Hinnant's `civil_from_days`, kept as a reference to check
//! `Date.fromDaysSinceStartOfEra` against. It is not part of the library:
//! `root.zig` does not export it, and nothing outside the tests, the fuzz
//! targets and `tools/verify_days.zig` calls it.
//!
//! The library converts a day number with Ben Joffe's algorithm, which is
//! several times faster and much harder to see is right. This is the one
//! that is easy to see is right, from *chrono-Compatible Low-Level Date
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
