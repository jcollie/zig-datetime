const Instant = @This();

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Date = @import("Date.zig");
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;

timestamp: i128,

/// Returns the current time read from the `.real` clock of `io`, in UTC.
pub fn now(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
    };
}

/// Same as `now`: the current time read from the `.real` clock of `io`, in UTC.
pub fn utc(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
    };
}

/// Creates an `Instant` from a count of nanoseconds since the Unix epoch, in UTC.
pub fn fromNanoTimeStamp(timestamp: i128) Instant {
    return .{
        .timestamp = timestamp,
    };
}

/// Creates an `Instant` from a count of microseconds since the Unix epoch, in UTC.
pub fn fromMicroTimeStamp(timestamp: i64) Instant {
    return .{
        .timestamp = timestamp * std.time.ns_per_us,
    };
}

/// Creates an `Instant` from a count of milliseconds since the Unix epoch, in UTC.
pub fn fromMilliTimestamp(timestamp: i64) Instant {
    return .{
        .timestamp = timestamp * std.time.ns_per_ms,
    };
}

/// Converts this instant to a calendar `DateTime` in UTC. Timestamps
/// before the Unix epoch are supported and produce dates before 1970.
pub fn asDateTime(self: Instant) DateTime {
    // Floor division throughout, so that a negative timestamp rounds
    // towards the earlier date and leaves a non-negative remainder
    // rather than a negative time of day.
    const nanosecond: Nanosecond = @intCast(@mod(self.timestamp, std.time.ns_per_s));
    const seconds = @divFloor(self.timestamp, std.time.ns_per_s);

    const days: Date.DaysType = @intCast(@divFloor(seconds, std.time.s_per_day));
    const second_of_day: i64 = @intCast(@mod(seconds, std.time.s_per_day));

    const date = Date.fromDaysSinceStartOfEra(days);

    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(@divTrunc(second_of_day, std.time.s_per_hour)),
        .minute = @intCast(@divTrunc(@mod(second_of_day, std.time.s_per_hour), std.time.s_per_min)),
        .second = @intCast(@mod(second_of_day, std.time.s_per_min)),
        .nanosecond = nanosecond,
        .weekday = DayOfWeek.fromDaysSinceStartOfEra(days),
        .offset = 0,
    };
}

test "instantTest" {
    const cases = [_]struct {
        instant: Instant,
        datetime: DateTime,
    }{
        .{
            .instant = .{
                .timestamp = 0,
            },
            .datetime = .{
                .year = 1970,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 0,
                .second = 0,
                .nanosecond = 0,
                .weekday = .Thu,
            },
        },
        .{
            .instant = .{
                .timestamp = -1,
            },
            .datetime = .{
                .year = 1969,
                .month = .Dec,
                .day = 31,
                .hour = 23,
                .minute = 59,
                .second = 59,
                .nanosecond = 999999999,
                .weekday = .Wed,
            },
        },
        // A whole day before the epoch, so the time of day is midnight
        // rather than a borrow from the previous day.
        .{
            .instant = .{
                .timestamp = -@as(i128, std.time.ns_per_day),
            },
            .datetime = .{
                .year = 1969,
                .month = .Dec,
                .day = 31,
                .hour = 0,
                .minute = 0,
                .second = 0,
                .nanosecond = 0,
                .weekday = .Wed,
            },
        },
        // Well before the epoch, in the range historical timezone data
        // reaches into.
        .{
            .instant = .{
                .timestamp = -2208988800 * @as(i128, std.time.ns_per_s),
            },
            .datetime = .{
                .year = 1900,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 0,
                .second = 0,
                .nanosecond = 0,
                .weekday = .Mon,
            },
        },
        .{
            .instant = .{
                .timestamp = 1697316872549526016,
            },
            .datetime = .{
                .year = 2023,
                .month = .Oct,
                .day = 14,
                .hour = 20,
                .minute = 54,
                .second = 32,
                .nanosecond = 549526016,
                .weekday = .Sat,
            },
        },
    };

    inline for (cases) |case| {
        const datetime = case.instant.asDateTime();
        try std.testing.expectEqual(case.datetime, datetime);
    }
}

test "asDateTime" {
    _ = Instant.utc(std.testing.io).asDateTime();
}
