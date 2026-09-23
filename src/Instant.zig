// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A point on the timeline, held as a count of nanoseconds since the Unix
//! epoch of 1970-01-01T00:00:00Z.
//!
//! Unlike `DateTime`, an `Instant` names a moment without reference to any
//! clock or zone, which makes it the right thing to compare, subtract and
//! store. `asDateTime` breaks one out into UTC calendar fields.

const Instant = @This();

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Date = @import("Date.zig");
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const json = @import("json.zig");

timestamp: i128,

/// Returns the current time read from the `.real` clock of `io`, in UTC.
pub fn now(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
    };
}

test now {
    const instant = now(std.testing.io);

    // Nothing about the reading is fixed, but the clock is a real one, so
    // it is somewhere after the epoch.
    try std.testing.expect(instant.timestamp > 0);
}

/// Same as `now`: the current time read from the `.real` clock of `io`, in UTC.
pub fn utc(io: std.Io) Instant {
    return .{
        .timestamp = std.Io.Timestamp.now(io, .real).nanoseconds,
    };
}

test utc {
    // An instant carries no zone, so this is `now` under another name,
    // kept for callers that would rather say which they meant.
    const instant = utc(std.testing.io);
    try std.testing.expect(instant.timestamp > 0);
}

/// Creates an `Instant` from a count of nanoseconds since the Unix epoch, in UTC.
pub fn fromNanoTimeStamp(timestamp: i128) Instant {
    return .{
        .timestamp = timestamp,
    };
}

test fromNanoTimeStamp {
    const instant: Instant = .fromNanoTimeStamp(1710512400_000000000);
    try std.testing.expectEqual(@as(i128, 1710512400_000000000), instant.timestamp);

    const datetime = instant.asDateTime();
    try std.testing.expectEqual(@as(Year, 2024), datetime.year);
    try std.testing.expectEqual(Month.Mar, datetime.month);
    try std.testing.expectEqual(@as(Day, 15), datetime.day);
}

/// Creates an `Instant` from a count of microseconds since the Unix epoch, in UTC.
pub fn fromMicroTimeStamp(timestamp: i64) Instant {
    return .{
        // Widened before multiplying: the field is an `i128` but the
        // argument is an `i64`, so the product was computed in the
        // narrower type and overflowed for a timestamp far from the
        // epoch -- around 1900 in microseconds is fine, a year before the
        // common era is not.
        .timestamp = @as(i128, timestamp) * std.time.ns_per_us,
    };
}

test fromMicroTimeStamp {
    const instant: Instant = .fromMicroTimeStamp(1_500_000);
    try std.testing.expectEqual(@as(i128, 1_500_000_000), instant.timestamp);

    // Far enough from the epoch that the product leaves an `i64`, which
    // it used to be computed in.
    try std.testing.expectEqual(
        @as(i128, std.math.maxInt(i64)) * std.time.ns_per_us,
        (Instant.fromMicroTimeStamp(std.math.maxInt(i64))).timestamp,
    );
}

/// Creates an `Instant` from a count of milliseconds since the Unix epoch, in UTC.
pub fn fromMilliTimestamp(timestamp: i64) Instant {
    return .{
        // Widened before multiplying: the field is an `i128` but the
        // argument is an `i64`, so the product was computed in the
        // narrower type and overflowed for a timestamp far from the
        // epoch -- around 1900 in milliseconds is fine, a year before the
        // common era is not.
        .timestamp = @as(i128, timestamp) * std.time.ns_per_ms,
    };
}

test fromMilliTimestamp {
    const instant: Instant = .fromMilliTimestamp(1_500);
    try std.testing.expectEqual(@as(i128, 1_500_000_000), instant.timestamp);

    // A year before the common era in milliseconds, which used to
    // overflow on the way in.
    try std.testing.expectEqual(
        @as(i128, -63500000000000) * std.time.ns_per_ms,
        (Instant.fromMilliTimestamp(-63500000000000)).timestamp,
    );
    try std.testing.expectEqual(
        @as(i128, std.math.minInt(i64)) * std.time.ns_per_ms,
        (Instant.fromMilliTimestamp(std.math.minInt(i64))).timestamp,
    );
}

/// Converts this instant to a calendar `DateTime` in UTC. Timestamps
/// before the Unix epoch are supported and produce dates before 1970.
pub fn asDateTime(self: Instant) DateTime {
    // Floor division throughout, so that a negative timestamp rounds
    // towards the earlier date and leaves a non-negative remainder
    // rather than a negative time of day.
    const nanosecond: Nanosecond = @intCast(@mod(self.timestamp, std.time.ns_per_s));
    const seconds = @divFloor(self.timestamp, std.time.ns_per_s);

    const days: Date.DaysType = Date.daysFromSecondsSaturating(@intCast(std.math.clamp(seconds, std.math.minInt(i64), std.math.maxInt(i64))));
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

test asDateTime {
    // The epoch itself, which was a Thursday.
    const epoch = (Instant{ .timestamp = 0 }).asDateTime();
    try std.testing.expectEqual(@as(Year, 1970), epoch.year);
    try std.testing.expectEqual(Month.Jan, epoch.month);
    try std.testing.expectEqual(@as(Day, 1), epoch.day);
    try std.testing.expectEqual(DayOfWeek.Thu, epoch.weekday);

    // One nanosecond earlier is the last instant of 1969, not a negative
    // time of day: the split rounds towards the earlier date.
    const before = (Instant{ .timestamp = -1 }).asDateTime();
    try std.testing.expectEqual(@as(Year, 1969), before.year);
    try std.testing.expectEqual(Month.Dec, before.month);
    try std.testing.expectEqual(@as(Day, 31), before.day);
    try std.testing.expectEqual(@as(u5, 23), before.hour);
    try std.testing.expectEqual(@as(u30, 999999999), before.nanosecond);

    // The result is always UTC, so it carries no offset.
    try std.testing.expectEqual(@as(i32, 0), epoch.offset);
}

/// Writes this instant as a JSON string of the instant in UTC, `"2024-03-15T19:30:00Z"`, which is
/// what `std.json.Stringify` calls when it meets one, in a field or on its
/// own.
///
/// Reading accepts any offset, since a zoned time names one instant
/// whichever zone it was written in, and then drops it, having nowhere to
/// keep it; a field whose local offset matters wants to be a `DateTime`. It
/// refuses a time **without** an offset, which names a different instant in
/// every zone, and one not named to the second; see `json.readInstant`.
///
/// An instant beyond the years a `Year` can hold is written as the first or
/// last date there is, since `asDateTime` saturates and a hook that writes
/// has no error of its own to report it with.
pub fn jsonStringify(self: Instant, jw: anytype) !void {
    return json.stringify(jw, self, json.writeInstant);
}

test jsonStringify {
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, @as(Instant, .{ .timestamp = 1710531000 * std.time.ns_per_s }), .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\"2024-03-15T19:30:00Z\"", text);
}

/// Reads one of these from the next token of a JSON document, which has to
/// be a string; `std.json.parseFromSlice` and its relatives call this when
/// they meet the type. See `jsonStringify` for the text, and `json.parse`
/// for what happens to the token.
///
/// A string that is not the representation is `error.InvalidCharacter`, and
/// one whose components are out of range is `error.Overflow`, the errors
/// `std.json` gives for a malformed and an oversized number.
pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Instant {
    return json.parse(Instant, allocator, source, options, json.readInstant);
}

test jsonParse {
    const Record = struct { value: Instant };
    const parsed = try std.json.parseFromSlice(Record, std.testing.allocator, "{\"value\":\"2024-03-15T19:30:00Z\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Instant{ .timestamp = 1710531000 * std.time.ns_per_s }, parsed.value.value);

    try std.testing.expectError(
        error.InvalidCharacter,
        std.json.parseFromSlice(Instant, std.testing.allocator, "\"not a date\"", .{}),
    );
}

/// Reads one of these from a `std.json.Value` that has already been
/// parsed, which has to be a string; `std.json.parseFromValue` calls this
/// when it meets the type. See `jsonParse`.
pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Instant {
    _ = allocator;
    _ = options;
    return json.parseFromValue(Instant, source, json.readInstant);
}

test jsonParseFromValue {
    const parsed = try std.json.parseFromValue(Instant, std.testing.allocator, .{ .string = "2024-03-15T19:30:00Z" }, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Instant{ .timestamp = 1710531000 * std.time.ns_per_s }, parsed.value);
}
