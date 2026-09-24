// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The hour of the day, and the twelve-hour clock's meridiem indicator.

const std = @import("std");

/// An hour of the day, 0 through 23 (ISO 8601-1:2019, 4.3.8). The range is
/// stated as 0 to 24 so that the type can also hold the ISO 8601 end-of-day
/// reading `24:00` before it is normalized to midnight of the following
/// day. Amendment 1:2022 to ISO 8601-1 defines that reading in 5.3.2, as
/// "the last instant of the day", which is also the first of the next, and
/// is explicit that its `24` "does not represent the hour".
pub const Hour = std.math.IntFittingRange(0, 24);

/// Writes the meridiem indicator for `hour` on a 24-hour clock: "am"/"AM"
/// for hours before 12, "pm"/"PM" otherwise, cased according to `case`.
pub fn writeTwelveHour(hour: Hour, case: enum { lower, upper }, writer: anytype) !void {
    if (hour < 12) switch (case) {
        .lower => try writer.writeAll("am"),
        .upper => try writer.writeAll("AM"),
    } else switch (case) {
        .lower => try writer.writeAll("pm"),
        .upper => try writer.writeAll("PM"),
    }
}

test writeTwelveHour {
    var buf: [2]u8 = undefined;

    var lower = std.Io.Writer.fixed(&buf);
    try writeTwelveHour(9, .lower, &lower);
    try std.testing.expectEqualStrings("am", lower.buffered());

    // Noon is already past the meridian, and so is every hour after it.
    var upper = std.Io.Writer.fixed(&buf);
    try writeTwelveHour(12, .upper, &upper);
    try std.testing.expectEqualStrings("PM", upper.buffered());
}
