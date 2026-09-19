// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Dates, times, and timezones.
//!
//! The calendar types are `Date`, a year, month and day; `DateTime`, a
//! date with a time of day and an offset from UTC; and `Instant`, a count
//! of nanoseconds since the Unix epoch. `Instant.asDateTime` converts
//! between the two views of a moment.
//!
//! `Duration` is a length of time as ISO 8601 writes one -- months, days
//! and everything below a day, kept apart because a month is not a fixed
//! number of days. `DateTime.add` applies one.
//!
//! Text goes in and out through four routes. `DateTime.format` and
//! `DateTime.parse` work from a comptime format string of the sequences
//! in `formatsequence.FormatTag`, which is the general case. `iso8601`
//! and `rfc822` parse the two standard syntaxes, whose shape is not known
//! until the input is read and so cannot go through a format string.
//! `rfc5322` is the strict reading of that second syntax, for a caller
//! that wants the current grammar and not the obsolete forms.
//! `golayout`, `cldr` and `strftime` are the other three vocabularies a
//! format string can be written in, taken from Go, from UTS #35 and from
//! the C library.
//!
//! Timezone support starts at `tzdb`, which loads a `TimeZone` either
//! from the operating system's copy of the IANA database or from one
//! embedded in the binary at build time. `tzif` and `posixtz` are the
//! two formats a zone is made of and are exposed for callers that want
//! to read them directly.

const std = @import("std");

/// A year of the proleptic Gregorian calendar, numbered astronomically.
pub const Year = @import("year.zig").Year;
/// A month of the year, January = 1 through December = 12.
pub const Month = @import("month.zig").Month;
/// A day of the month, 1 through 31.
pub const Day = @import("day.zig").Day;
/// An hour of the day, 0 through 23.
pub const Hour = @import("hour.zig").Hour;
/// A minute within an hour, 0 through 59.
pub const Minute = @import("minute.zig").Minute;
/// A second within a minute, 0 through 59 and beyond for a leap second.
pub const Second = @import("second.zig").Second;
/// A nanosecond within a second, 0 through 999999999.
pub const Nanosecond = @import("nanosecond.zig").Nanosecond;
/// A day of the week, Sunday = 0 through Saturday = 6.
pub const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
/// A zone abbreviation such as "CDT", stored by value on a `DateTime`.
pub const Designation = @import("designation.zig").Designation;
/// A calendar date: a year, a month and a day.
pub const Date = @import("Date.zig");
/// A date with a time of day and an offset from UTC.
pub const DateTime = @import("DateTime.zig");
/// A point on the timeline, as nanoseconds since the Unix epoch.
pub const Instant = @import("Instant.zig");
/// A length of time as ISO 8601 writes one, in months, days and everything
/// below a day.
pub const Duration = @import("Duration.zig");
/// The language a date is written in: month and day names, the meridiem,
/// ordinals, the week rule, and what the `L` sequences stand for.
/// `locale.en` is built in; `-Dembed-locales` adds moment.js's other
/// hundred and thirty-six.
pub const locale = @import("locale.zig");

/// Parsing of the ISO 8601 date and time representations, and of its
/// durations.
pub const iso8601 = @import("iso8601.zig");
/// Parsing of the RFC 822 date and time syntax used by mail and HTTP.
pub const rfc822 = @import("rfc822.zig");
/// Parsing of the RFC 5322 `date-time`, the current syntax of a message
/// `Date:` header: comments and folding are read, the obsolete forms are
/// not.
pub const rfc5322 = @import("rfc5322.zig");
/// Formatting and parsing with Go's time layouts, where the format string
/// is one particular time written the way you want yours written.
pub const golayout = @import("golayout.zig");
/// Formatting with CLDR date patterns, the vocabulary UTS #35 defines and
/// that ICU, Java and `Intl.DateTimeFormat` speak. `-Dembed-cldr` adds
/// CLDR's locales; English is built in either way.
pub const cldr = @import("cldr.zig");
/// Formatting and parsing with the C library's `strftime` conversions,
/// the `%Y-%m-%d` vocabulary that configuration files and shell scripts
/// are written in.
pub const strftime = @import("strftime.zig");
/// A timezone, and the lookups that apply it to an instant.
pub const TimeZone = @import("TimeZone.zig");
/// Where timezone data comes from: the system's copy or an embedded one.
pub const tzdb = @import("tzdb.zig");
/// The TZif binary format that timezone data is compiled into.
pub const tzif = @import("tzif.zig");
/// The POSIX `TZ` string that governs times past a zone's last transition.
pub const posixtz = @import("posixtz.zig");
/// The SI decimal prefixes, for moving a value between units of time.
pub const si = @import("si.zig");
/// Whether a year is a leap year, which several of the types ask and which
/// a caller may want to ask on its own.
pub const leap = @import("leap.zig");

/// How many years either side of year 0 the sweep below covers, from
/// `-Dbig-test-years`. Zero, the default, skips it.
const big_test_years = @import("build_options").big_test_years;

// Hinnant's own verification of the algorithms `Date` and `DayOfWeek` are
// built on, from *chrono-Compatible Low-Level Date Algorithms* (the section
// headed "Yes, but how do you know this all really works?"):
// <https://howardhinnant.github.io/date_algorithms.html>.
//
// It walks every date of a span of years in order and checks three
// properties at each one: that the day number is exactly one more than the
// previous date's, which catches a gap or a repeat anywhere in the calendar;
// that converting that day number back returns the triple it started from,
// which makes the two conversions each other's inverse; and that the weekday
// is the next one round from the previous date's, which pins the weekday to
// the same unbroken run of days. Together those say that the date the
// calendar hands out and the integer the library stores are the same
// sequence counted two ways, which is a stronger claim than any table of
// known dates can make.
//
// It is behind a build option rather than an ordinary test because the
// paper's own span is 730,485,366 dates, so `zig build test` runs none of
// it:
//
//     zig build test -Dbig-test-years=2000                     # seconds
//     zig build test -Dbig-test-years=1000000 -Doptimize=ReleaseFast
//
// The second is the paper's test as published, and it checks the paper's
// published count as well, so a disagreement about how many days those two
// million years hold is itself a failure.
test "every date in a span of years, forwards" {
    if (big_test_years == 0) return error.SkipZigTest;

    const first: Year = -@as(Year, @intCast(big_test_years));
    const last: Year = @intCast(big_test_years);

    // The day before the span starts, so that the first date of the sweep
    // is checked against something rather than taken on trust.
    var previous_day = (Date{ .year = first, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra() - 1;
    var previous_weekday = DayOfWeek.fromDaysSinceStartOfEra(previous_day);
    var count: u64 = 0;

    var year: Year = first;
    while (year <= last) : (year += 1) {
        var months = Month.iterator();
        while (months.next()) |month| {
            var day: Day = 1;
            const end_of_month = month.lastDay(year);
            while (day <= end_of_month) : (day += 1) {
                const date: Date = .{ .year = year, .month = month, .day = day };

                const days = date.toDaysSinceStartOfEra();
                try std.testing.expectEqual(previous_day + 1, days);
                try std.testing.expectEqual(date, Date.fromDaysSinceStartOfEra(days));

                const weekday = DayOfWeek.fromDaysSinceStartOfEra(days);
                try std.testing.expectEqual(previous_weekday.next(), weekday);
                try std.testing.expectEqual(previous_weekday, weekday.prev());

                previous_day = days;
                previous_weekday = weekday;
                count += 1;
            }
        }
    }

    // The paper prints the length of its own sweep, so when the span is the
    // paper's the count is one more figure to agree with.
    if (big_test_years == 1_000_000) {
        try std.testing.expectEqual(@as(u64, 730_485_366), count);
    }
}

test {
    std.testing.refAllDecls(@This());

    // refAllDecls reaches everything this file re-exports, and through them
    // every internal module but one: `ordinal` is named only from inside the
    // comptime bodies of `DateTime.parseRelativeTo`, which are never
    // instantiated by a reference alone, so its tests need asking for.
    _ = @import("ordinal.zig");

    // The fuzz targets, which nothing else refers to. Under an ordinary
    // run each one checks its property over a list of seeds; under
    // `zig build --fuzz` the fuzzer drives the same properties.
    _ = @import("fuzz.zig");
}
