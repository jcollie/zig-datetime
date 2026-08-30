const std = @import("std");

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
