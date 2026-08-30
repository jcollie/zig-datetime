const Instant = @This();

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Date = @import("Date.zig");
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Timezone = @import("timezone.zig").Timezone;

timestamp: i128,
timezone: Timezone,

pub fn now(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
        .timezone = .UTC,
    };
}

pub fn utc(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
        .timezone = .UTC,
    };
}

pub fn fromNanoTimeStamp(timestamp: i128) Instant {
    return .{
        .timestamp = timestamp,
        .timezone = .UTC,
    };
}

pub fn fromMicroTimeStamp(timestamp: i64) Instant {
    return .{
        .timestamp = timestamp * std.time.ns_per_us,
        .timezone = .UTC,
    };
}

pub fn fromMilliTimestamp(timestamp: i64) Instant {
    return .{
        .timestamp = timestamp * std.time.ns_per_us,
        .timezone = .UTC,
    };
}

pub fn asDateTime(self: Instant) DateTime {
    // this does not support negative timestamps yet
    std.debug.assert(self.timestamp >= 0);

    const nanosecond: Nanosecond = @intCast(@mod(
        self.timestamp,
        std.time.ns_per_s,
    ));
    var seconds = @divTrunc(
        self.timestamp,
        std.time.ns_per_s,
    );
    const second: Second = @intCast(@mod(
        seconds,
        std.time.s_per_min,
    ));
    seconds -= second;

    const minute: Minute = @intCast(@divTrunc(
        @mod(
            seconds,
            std.time.s_per_hour,
        ),
        std.time.s_per_min,
    ));
    seconds -= @as(u32, minute) * std.time.s_per_min;

    const hour: Hour = @intCast(@divTrunc(
        @mod(
            seconds,
            std.time.s_per_day,
        ),
        std.time.s_per_hour,
    ));
    seconds -= @as(u32, hour) * std.time.s_per_hour;

    const days: Date.DaysType = @intCast(@divTrunc(
        seconds,
        std.time.s_per_day,
    ));

    const date = Date.fromDaysSinceStartOfEra(days);

    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = nanosecond,
        .weekday = DayOfWeek.fromDaysSinceStartOfEra(days),
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
                .timezone = .UTC,
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
        // .{
        //     .instant = .{
        //         .timestamp = -1,
        //         .timezone = .UTC,
        //     },
        //     .datetime = .{
        //         .year = 1969,
        //         .month = .Dec,
        //         .day = 31,
        //         .hour = 23,
        //         .minute = 59,
        //         .second = 59,
        //         .nanosecond = 999999999,
        //         .weekday = .Wed,
        //     },
        // },
        .{
            .instant = .{
                .timestamp = 1697316872549526016,
                .timezone = .UTC,
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
