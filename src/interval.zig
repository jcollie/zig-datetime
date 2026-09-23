// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A stretch of the timeline as ISO 8601 writes one, in any of its three
//! forms:
//!
//!     2007-03-01T13:00:00Z/2008-05-11T15:30:00Z     start and end
//!     2007-03-01T13:00:00Z/P1Y2M10DT2H30M           start and duration
//!     P1Y2M10DT2H30M/2008-05-11T15:30:00Z           duration and end
//!
//! The form is kept rather than resolved, for the same reason `Duration`
//! keeps its months apart from its days. An interval written with a
//! duration says something a pair of endpoints does not: `2001-01-31/P1M`
//! is "a month from the 31st of January", which ends on the 28th of
//! February, and the same two endpoints written out would say only "28
//! days". Worse, the duration and end form does not even have a unique
//! pair of endpoints to turn into — see `start` — so resolving it on the
//! way in would pick an answer the text never gave.
//!
//! `start` and `end` resolve whichever endpoint was not written, and the
//! comparisons are built on those. `iso8601.parseInterval` reads one.

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Duration = @import("Duration.zig");
const Instant = @import("Instant.zig");

/// A time interval in one of ISO 8601's three forms. The duration-only form
/// is not one of them: a duration on its own has no place on the timeline
/// to be an interval of.
pub const Interval = union(enum) {
    /// Both endpoints written out.
    start_end: StartEnd,
    /// A start, and how long after it the end comes.
    start_duration: StartDuration,
    /// An end, and how long before it the start was.
    duration_end: DurationEnd,

    pub const StartEnd = struct {
        start: DateTime,
        end: DateTime,
    };

    pub const StartDuration = struct {
        start: DateTime,
        duration: Duration,
    };

    pub const DurationEnd = struct {
        duration: Duration,
        end: DateTime,
    };

    /// Where this interval starts.
    ///
    /// For the duration and end form it is found by adding the duration's
    /// negation to the end with `DateTime.add`, which is what every library
    /// that defines subtracting a calendar duration does, because there is
    /// no better answer to be had: subtraction is not the inverse of
    /// addition once a month has been clamped. One month after each of the
    /// 28th, 29th, 30th and 31st of January 2001 is the 28th of February, so
    /// `P1M/2001-02-28` has four starts that would each end there, and this
    /// answers the 28th of January — the latest of them, so the shortest
    /// interval. `start` then `end` does not always come back to the end the
    /// interval was written with: `P1M/2001-03-31` starts on the 28th of
    /// February, which is a month before the 28th of March.
    ///
    /// A result outside the years a `Year` can hold is a panic, as with
    /// `DateTime.add`; `iso8601.parseInterval` refuses any interval for which
    /// it would be.
    pub fn start(self: Interval) DateTime {
        return switch (self) {
            .start_end => |i| i.start,
            .start_duration => |i| i.start,
            .duration_end => |i| i.end.add(i.duration.negate()),
        };
    }

    test start {
        const written: Interval = .{ .duration_end = .{
            .duration = .{ .months = 1 },
            .end = .{ .year = 2001, .month = .Feb, .day = 28, .weekday = .Wed },
        } };
        try std.testing.expectEqual(
            DateTime{ .year = 2001, .month = .Jan, .day = 28, .weekday = .Sun },
            written.start(),
        );

        // Not always the inverse of `end`: a month back from the 31st of
        // March is the 28th of February, and a month on from that is the
        // 28th of March.
        const march: Interval = .{ .duration_end = .{
            .duration = .{ .months = 1 },
            .end = .{ .year = 2001, .month = .Mar, .day = 31, .weekday = .Sat },
        } };
        try std.testing.expectEqual(
            DateTime{ .year = 2001, .month = .Feb, .day = 28, .weekday = .Wed },
            march.start(),
        );
    }

    /// Where this interval ends.
    ///
    /// For the start and duration form this is `DateTime.add`, applying the
    /// duration in XML Schema's order: the sub-day part, then the months with
    /// the day of the month clamped, then the days. That order is the only
    /// one ISO 8601 can mean, since it is the order the duration is written
    /// in. A result outside the years a `Year` can hold is a panic, as it is
    /// there.
    pub fn end(self: Interval) DateTime {
        return switch (self) {
            .start_end => |i| i.end,
            .start_duration => |i| i.start.add(i.duration),
            .duration_end => |i| i.end,
        };
    }

    test end {
        const written: Interval = .{ .start_duration = .{
            .start = .{ .year = 2001, .month = .Jan, .day = 31, .weekday = .Wed },
            .duration = .{ .months = 1 },
        } };
        // The clamp: February has no 31st.
        try std.testing.expectEqual(
            DateTime{ .year = 2001, .month = .Feb, .day = 28, .weekday = .Wed },
            written.end(),
        );
    }

    /// The duration this interval was written with, or null when it was
    /// written as two endpoints.
    ///
    /// There is deliberately no answer for two endpoints. Which calendar
    /// duration lies between two dates is not a question with one answer —
    /// the 31st of January to the 28th of February is `P1M` and `P28D`
    /// both — and `length` is the fixed span, which is.
    pub fn duration(self: Interval) ?Duration {
        return switch (self) {
            .start_end => null,
            .start_duration => |i| i.duration,
            .duration_end => |i| i.duration,
        };
    }

    test duration {
        const written: Interval = .{ .start_duration = .{
            .start = .{ .year = 2001, .month = .Jan, .day = 31 },
            .duration = .{ .days = 3 },
        } };
        try std.testing.expect(written.duration().?.eql(.{ .days = 3 }));

        const endpoints: Interval = .{ .start_end = .{
            .start = .{ .year = 2001, .month = .Jan, .day = 31 },
            .end = .{ .year = 2001, .month = .Feb, .day = 28 },
        } };
        try std.testing.expectEqual(@as(?Duration, null), endpoints.duration());
    }

    /// How long this interval is, in nanoseconds of the timeline: the end's
    /// instant less the start's.
    ///
    /// Each endpoint is taken to its instant with `DateTime.toInstant`, which
    /// takes its offset off, so two endpoints written at different offsets
    /// are measured in real time rather than on the wall clock: midnight to
    /// midnight across a spring-forward is 23 hours. An end found by adding a
    /// duration carries the start's offset, as `DateTime.add` does, so `P1D`
    /// is always 24. An endpoint read without a zone has an offset of zero,
    /// and is measured as though it were UTC.
    pub fn length(self: Interval) i128 {
        return self.end().toInstant().timestamp - self.start().toInstant().timestamp;
    }

    test length {
        const day: Interval = .{ .start_duration = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15 },
            .duration = .{ .days = 1 },
        } };
        try std.testing.expectEqual(@as(i128, std.time.ns_per_day), day.length());

        // The same wall clock times, an hour apart in offset: 23 hours.
        const spring: Interval = .{ .start_end = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 9, .offset = -6 * std.time.s_per_hour },
            .end = .{ .year = 2024, .month = .Mar, .day = 10, .offset = -5 * std.time.s_per_hour },
        } };
        try std.testing.expectEqual(@as(i128, 23 * std.time.ns_per_hour), spring.length());
    }

    /// Whether `instant` falls within this interval.
    ///
    /// The interval is taken as **half-open**: it contains its start and not
    /// its end. ISO 8601 leaves the question to the application, and this is
    /// the answer that lets intervals tile, since `2024-03-15/2024-03-16` and
    /// `2024-03-16/2024-03-17` then share no instant and leave none out. An
    /// interval of no length contains nothing.
    pub fn contains(self: Interval, instant: Instant) bool {
        return self.start().toInstant().timestamp <= instant.timestamp and
            instant.timestamp < self.end().toInstant().timestamp;
    }

    test contains {
        const march15: Interval = .{ .start_end = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15 },
            .end = .{ .year = 2024, .month = .Mar, .day = 16 },
        } };
        const start_instant = (DateTime{ .year = 2024, .month = .Mar, .day = 15 }).toInstant();
        const end_instant = (DateTime{ .year = 2024, .month = .Mar, .day = 16 }).toInstant();

        try std.testing.expect(march15.contains(start_instant));
        try std.testing.expect(march15.contains(.{ .timestamp = end_instant.timestamp - 1 }));
        // The end belongs to the next interval, not this one.
        try std.testing.expect(!march15.contains(end_instant));
        try std.testing.expect(!march15.contains(.{ .timestamp = start_instant.timestamp - 1 }));
    }

    /// Whether this interval and `other` share any instant.
    ///
    /// Two half-open intervals overlap exactly when each starts before the
    /// other ends; see `contains` for why they are half-open. So intervals
    /// that only touch, one ending where the other starts, do not overlap,
    /// and an interval of no length overlaps nothing.
    pub fn overlaps(self: Interval, other: Interval) bool {
        const a_start = self.start().toInstant().timestamp;
        const a_end = self.end().toInstant().timestamp;
        const b_start = other.start().toInstant().timestamp;
        const b_end = other.end().toInstant().timestamp;
        return a_start < b_end and b_start < a_end;
    }

    test overlaps {
        const morning: Interval = .{ .start_duration = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9 },
            .duration = .{ .nanoseconds = 3 * Duration.nanoseconds_per_hour },
        } };
        const lunch: Interval = .{ .start_duration = .{
            .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 12 },
            .duration = .{ .nanoseconds = Duration.nanoseconds_per_hour },
        } };
        const late_morning: Interval = .{ .duration_end = .{
            .duration = .{ .nanoseconds = Duration.nanoseconds_per_hour },
            .end = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 12, .minute = 30 },
        } };

        // Touching is not overlapping.
        try std.testing.expect(!morning.overlaps(lunch));
        try std.testing.expect(morning.overlaps(late_morning));
        try std.testing.expect(lunch.overlaps(late_morning));
        // And it is symmetric.
        try std.testing.expect(late_morning.overlaps(morning));
    }

    /// Writes this interval in ISO 8601's own syntax, which is what `{f}`
    /// gets, in the form it was built in: the two parts joined by a solidus.
    ///
    /// An endpoint is written in full in the extended form,
    /// `2024-03-15T14:30:00`, with a decimal fraction of the second only
    /// when there is one and with no trailing zeroes on it. Its offset is
    /// written as `Z` when it is zero and `±hh:mm` otherwise, with `:ss`
    /// after that for the historical offsets that are not whole minutes —
    /// which ISO 8601 has no spelling for, and which is written anyway
    /// rather than rounded to a different instant. A `DateTime` cannot say
    /// that it was read without a zone, so an endpoint that was comes out
    /// as `Z`: the same instant `length` and `contains` took it to be.
    ///
    /// The duration is written by `Duration.format`.
    pub fn format(self: Interval, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .start_end => |i| {
                try writeDateTime(writer, i.start);
                try writer.writeByte('/');
                try writeDateTime(writer, i.end);
            },
            .start_duration => |i| {
                try writeDateTime(writer, i.start);
                try writer.writeByte('/');
                try i.duration.format(writer);
            },
            .duration_end => |i| {
                try i.duration.format(writer);
                try writer.writeByte('/');
                try writeDateTime(writer, i.end);
            },
        }
    }

    test format {
        const cases = [_]struct { Interval, []const u8 }{
            .{
                .{ .start_end = .{
                    .start = .{ .year = 2007, .month = .Mar, .day = 1, .hour = 13 },
                    .end = .{ .year = 2008, .month = .May, .day = 11, .hour = 15, .minute = 30 },
                } },
                "2007-03-01T13:00:00Z/2008-05-11T15:30:00Z",
            },
            .{
                .{ .start_duration = .{
                    .start = .{ .year = 2007, .month = .Mar, .day = 1, .hour = 13, .offset = -5 * std.time.s_per_hour },
                    .duration = .{ .months = 14, .days = 10, .nanoseconds = 150 * Duration.nanoseconds_per_minute },
                } },
                "2007-03-01T13:00:00-05:00/P1Y2M10DT2H30M",
            },
            .{
                .{ .duration_end = .{
                    .duration = .{ .days = 1 },
                    .end = .{ .year = 2008, .month = .May, .day = 11, .nanosecond = 500_000_000, .offset = 5 * std.time.s_per_hour + 30 * std.time.s_per_min },
                } },
                "P1D/2008-05-11T00:00:00.5+05:30",
            },
        };
        for (cases) |case| {
            var buf: [96]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try case[0].format(&w);
            try std.testing.expectEqualStrings(case[1], w.buffered());
        }
    }
};

/// One endpoint in ISO 8601's extended form; see `Interval.format`.
fn writeDateTime(writer: *std.Io.Writer, datetime: DateTime) std.Io.Writer.Error!void {
    // Four digits is all ISO 8601 allows without prior agreement, and a year
    // outside them is written with the sign its expanded form asks for rather
    // than truncated to something that means a different year.
    if (datetime.year >= 0 and datetime.year <= 9999) {
        try writer.print("{d:0>4}", .{@as(u32, @intCast(datetime.year))});
    } else {
        try writer.print("{c}{d:0>4}", .{ @as(u8, if (datetime.year < 0) '-' else '+'), @abs(datetime.year) });
    }
    try writer.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @intFromEnum(datetime.month),
        datetime.day,
        datetime.hour,
        datetime.minute,
        datetime.second,
    });

    if (datetime.nanosecond != 0) {
        var digits: [9]u8 = undefined;
        _ = std.fmt.printInt(&digits, datetime.nanosecond, 10, .lower, .{ .fill = '0', .width = 9 });
        var len: usize = digits.len;
        while (len > 1 and digits[len - 1] == '0') len -= 1;
        try writer.print(".{s}", .{digits[0..len]});
    }

    if (datetime.offset == 0) return writer.writeByte('Z');

    const magnitude: u32 = @abs(datetime.offset);
    try writer.print("{c}{d:0>2}:{d:0>2}", .{
        @as(u8, if (datetime.offset < 0) '-' else '+'),
        magnitude / std.time.s_per_hour,
        magnitude % std.time.s_per_hour / std.time.s_per_min,
    });
    if (magnitude % std.time.s_per_min != 0) {
        try writer.print(":{d:0>2}", .{magnitude % std.time.s_per_min});
    }
}

test writeDateTime {
    const cases = [_]struct { DateTime, []const u8 }{
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .hour = 14, .minute = 30 }, "2024-03-15T14:30:00Z" },
        .{ .{ .year = 2024, .month = .Mar, .day = 15, .nanosecond = 1 }, "2024-03-15T00:00:00.000000001Z" },
        .{ .{ .year = 12, .month = .Jan, .day = 1 }, "0012-01-01T00:00:00Z" },
        .{ .{ .year = -1, .month = .Jan, .day = 1 }, "-0001-01-01T00:00:00Z" },
        .{ .{ .year = 10000, .month = .Jan, .day = 1 }, "+10000-01-01T00:00:00Z" },
        // America/Chicago's local mean time, which is not whole minutes.
        .{ .{ .year = 1883, .month = .Nov, .day = 18, .offset = -(5 * 3600 + 50 * 60 + 36) }, "1883-11-18T00:00:00-05:50:36" },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDateTime(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}

test {
    std.testing.refAllDecls(@This());
}
