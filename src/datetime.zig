// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Dates, times, and timezones.
//!
//! The calendar types are `Date`, a year, month and day; `DateTime`, a
//! date with a time of day and an offset from UTC; and `Instant`, a count
//! of nanoseconds since the Unix epoch. `Instant.asDateTime` converts
//! between the two views of a moment.
//!
//! Text goes in and out through three routes. `DateTime.format` and
//! `DateTime.parse` work from a comptime format string of the sequences
//! in `formatsequence.FormatTag`, which is the general case. `iso8601`
//! and `rfc822` parse the two standard syntaxes, whose shape is not known
//! until the input is read and so cannot go through a format string.
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
/// Parsing of the ISO 8601 date and time representations.
pub const iso8601 = @import("iso8601.zig");
/// Parsing of the RFC 822 date and time syntax used by mail and HTTP.
pub const rfc822 = @import("rfc822.zig");
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

// test "bigTest" {
//     const year_start: Year = -1000000;
//     const year_end = -year_start;
//     var prev_z: i32 = Date.toCivilDays(.{ .year = year_start, .month = .Jan, .day = 1 }) - 1;
//     try std.testing.expect(prev_z < 0);
//     var prev_wd = DayOfWeek.weekdayFromDays(prev_z);
//     try std.testing.expect(0 <= @intFromEnum(prev_wd) and @intFromEnum(prev_wd) <= 6);
//     var y: Year = year_start;
//     while (y < year_end) {
//         var it = Month.iterator();
//         while (it.next()) |m| {
//             std.debug.print("{}\n", .{m});
//             var day: Day = 1;
//             const end_of_month = m.lastDay(y);
//             while (day <= end_of_month) {
//                 const date_0: Date = .{
//                     .year = y,
//                     .month = m,
//                     .day = day,
//                 };
//                 const z = date_0.toDaysSinceStartOfEra();
//                 try std.testing.expect(prev_z < z);
//                 try std.testing.expect(z == prev_z + 1);
//                 const date_1 = Date.fromDaysSinceStartOfEra(z);
//                 try std.testing.expect(y == date_1.year);
//                 try std.testing.expect(m == date_1.month);
//                 try std.testing.expect(day == date_1.day);
//                 const wd = DayOfWeek.fromDaysSinceStartOfEra(z);
//                 try std.testing.expect(0 <= @intFromEnum(wd) and @intFromEnum(wd) <= 6);
//                 try std.testing.expect(wd == prev_wd.next());
//                 try std.testing.expect(prev_wd == wd.prev());
//                 prev_z = z;
//                 prev_wd = wd;
//                 day += 1;
//             }
//         }
//         y += 1;
//     }
// }

test {
    std.testing.refAllDecls(@This());

    // refAllDecls reaches everything this file re-exports, and through them
    // every internal module but one: `ordinal` is named only from inside the
    // comptime bodies of `DateTime.parseRelativeTo`, which are never
    // instantiated by a reference alone, so its tests need asking for.
    _ = @import("ordinal.zig");
}
