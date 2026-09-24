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

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const Day = @import("day.zig").Day;
const Year = @import("year.zig").Year;
const Duration = @import("Duration.zig");
const Instant = @import("Instant.zig");
const iso8601 = @import("iso8601.zig");
const json = @import("json.zig");

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
    /// Each endpoint is written in full by `iso8601.writeDateTime`. A
    /// `DateTime` cannot say that it was read without a zone, so an endpoint
    /// that was comes out as `Z`: the same instant `length` and `contains`
    /// took it to be.
    ///
    /// The duration is written by `Duration.format`.
    pub fn format(self: Interval, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .start_end => |i| {
                try iso8601.writeDateTime(writer, i.start);
                try writer.writeByte('/');
                try iso8601.writeDateTime(writer, i.end);
            },
            .start_duration => |i| {
                try iso8601.writeDateTime(writer, i.start);
                try writer.writeByte('/');
                try i.duration.format(writer);
            },
            .duration_end => |i| {
                try i.duration.format(writer);
                try writer.writeByte('/');
                try iso8601.writeDateTime(writer, i.end);
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

    /// Writes this interval as a JSON string of its ISO 8601 spelling, in the form it was built in, `"2024-03-15T09:00:00Z/P1D"`, which is
    /// what `std.json.Stringify` calls when it meets one, in a field or on its
    /// own.
    ///
    /// Reading is `iso8601.parseInterval`, so a string that runs backwards, or
    /// whose duration would carry an endpoint outside the years a `Year` can
    /// hold, is refused, and `start` and `end` are safe on what comes back.
    /// It is stricter than that parser in one way: every endpoint written has
    /// to be named to the second and carry an offset, as `DateTime` requires,
    /// rather than being read as UTC or completed with zeroes. An abbreviated
    /// end without a zone of its own is in the start's, as ISO 8601 says; see
    /// `json.readInterval`.
    pub fn jsonStringify(self: Interval, jw: anytype) !void {
        return json.stringify(jw, self, json.writeInterval);
    }

    test jsonStringify {
        const text = try std.json.Stringify.valueAlloc(std.testing.allocator, @as(Interval, .{ .start_duration = .{ .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9, .weekday = .Fri }, .duration = .{ .days = 1 } } }), .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("\"2024-03-15T09:00:00Z/P1D\"", text);
    }

    /// Reads one of these from the next token of a JSON document, which has to
    /// be a string; `std.json.parseFromSlice` and its relatives call this when
    /// they meet the type. See `jsonStringify` for the text, and `json.parse`
    /// for what happens to the token.
    ///
    /// A string that is not the representation is `error.InvalidCharacter`, and
    /// one whose components are out of range is `error.Overflow`, the errors
    /// `std.json` gives for a malformed and an oversized number.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Interval {
        return json.parse(Interval, allocator, source, options, json.readInterval);
    }

    test jsonParse {
        const Record = struct { value: Interval };
        const parsed = try std.json.parseFromSlice(Record, std.testing.allocator, "{\"value\":\"2024-03-15T09:00:00Z/P1D\"}", .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(@as(Interval, .{ .start_duration = .{ .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9, .weekday = .Fri }, .duration = .{ .days = 1 } } }), parsed.value.value);

        try std.testing.expectError(
            error.InvalidCharacter,
            std.json.parseFromSlice(Interval, std.testing.allocator, "\"not a date\"", .{}),
        );
    }

    /// Reads one of these from a `std.json.Value` that has already been
    /// parsed, which has to be a string; `std.json.parseFromValue` calls this
    /// when it meets the type. See `jsonParse`.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Interval {
        _ = allocator;
        _ = options;
        return json.parseFromValue(Interval, source, json.readInterval);
    }

    test jsonParseFromValue {
        const parsed = try std.json.parseFromValue(Interval, std.testing.allocator, .{ .string = "2024-03-15T09:00:00Z/P1D" }, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(@as(Interval, .{ .start_duration = .{ .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9, .weekday = .Fri }, .duration = .{ .days = 1 } } }), parsed.value);
    }
};

/// A recurring time interval as ISO 8601 writes one: `R5/` or `R/` in front
/// of an `Interval`, as in `R12/1985-04-12T23:20:50Z/P1Y2M15DT12H30M`.
///
/// ISO 8601-1:2019 defines one as a "series of consecutive time intervals
/// of identical duration" (3.1.1.11), and both halves of that do work here:
///
///  * **Consecutive** means each interval begins where the one before it
///    ended. So the series is built by adding the duration to each
///    occurrence in turn, not by multiplying it from the first one, and the
///    two differ once a month has been clamped. `R/2024-01-31T00:00:00Z/P1M`
///    runs to the 29th of February, then the 29th of March, and stays on the
///    29th from then on. Multiplying would give the 31st of March, but then
///    the third interval would not start where the second ended, which is
///    what the definition asks for. RFC 5545's `RRULE` multiplies, because
///    it describes a pattern of events rather than a run of intervals; this
///    is not that.
///  * **Identical duration** is the one the interval was written with, when
///    it was written with one. That it is identical as written and not as
///    measured is the standard's own note to the definition: a duration in
///    calendar units lasts however long the dates it lands on make it, so
///    `P1M` is 29 days from the 31st of January and 29 again from the 29th
///    of February. An interval written as two endpoints has a length and no
///    calendar duration (see `Interval.duration`), so its series repeats
///    that length, measured on the timeline in nanoseconds.
///
/// Which occurrence the text names depends on the form (ISO 8601-1:2019,
/// 5.6.1).
/// A start and an end, or a start and a duration, name the **first**
/// interval, and the series runs forwards from it. A duration and an end
/// name the **last**, and the series runs backwards from it: `R/P1Y/1985-
/// 04-12T23:20:50Z` is an unbounded run of years that finished in April
/// 1985. `iterator` walks outward from the named occurrence in whichever
/// direction that is.
///
/// `count` is how many intervals the series has, the first included: ISO
/// 8601's own example reads `R15/…` as "fifteen recurrences". It is null
/// when the text wrote `R/`, which the standard reads as unbounded.
pub const RecurringInterval = struct {
    /// How many intervals the series holds, or null for an unbounded one.
    /// Never zero; see `iso8601.parseRecurringInterval`.
    count: ?u64,
    /// The occurrence the text wrote: the first of the series, or the last
    /// when it was written as a duration and an end.
    interval: Interval,

    /// Whether the series runs forwards from `interval`, which is the case
    /// unless it was written as a duration and an end, where `interval` is
    /// the last occurrence and the rest came before it.
    pub fn isForwards(self: RecurringInterval) bool {
        return self.interval != .duration_end;
    }

    test isForwards {
        const monthly: RecurringInterval = .{ .count = null, .interval = .{ .start_duration = .{
            .start = .{ .year = 2024, .month = .Jan, .day = 1 },
            .duration = .{ .months = 1 },
        } } };
        try std.testing.expect(monthly.isForwards());

        const ending: RecurringInterval = .{ .count = null, .interval = .{ .duration_end = .{
            .duration = .{ .months = 1 },
            .end = .{ .year = 2024, .month = .Jan, .day = 1 },
        } } };
        try std.testing.expect(!ending.isForwards());
    }

    /// The occurrences of the series, starting with the one the text wrote
    /// and walking away from it — forwards in time, or backwards when
    /// `isForwards` says not.
    pub fn iterator(self: RecurringInterval) Iterator {
        return .{ .remaining = self.count, .current = self.interval };
    }

    test iterator {
        const series: RecurringInterval = .{ .count = 3, .interval = .{ .start_duration = .{
            .start = .{ .year = 2024, .month = .Jan, .day = 31 },
            .duration = .{ .months = 1 },
        } } };
        var it = series.iterator();
        const expected = [_]Date{
            .{ .year = 2024, .month = .Jan, .day = 31 },
            // Clamped: February has no 31st.
            .{ .year = 2024, .month = .Feb, .day = 29 },
            // And consecutive, so the clamp is carried on: the 29th of March,
            // where the second interval ended, not the 31st.
            .{ .year = 2024, .month = .Mar, .day = 29 },
        };
        for (expected) |date| {
            const occurrence = (try it.next()).?;
            try std.testing.expectEqual(date, occurrence.start().asDate());
        }
        try std.testing.expectEqual(@as(?Interval, null), try it.next());
    }

    /// Walks the occurrences of a `RecurringInterval`; see `iterator`.
    pub const Iterator = struct {
        /// How many occurrences are still to come, or null for no end.
        remaining: ?u64,
        /// The next occurrence to hand out, or, once one has been, the one
        /// most recently handed out.
        current: Interval,
        /// Whether `current` has been handed out yet.
        started: bool = false,

        /// The next occurrence, or null once the series is finished.
        ///
        /// Each occurrence after the first is made from the one before it,
        /// keeping the form the text was written in:
        ///
        ///  * start and duration: the new start is the old start plus the
        ///    duration, which is where the old interval ended;
        ///  * duration and end: the new end is the old end less the
        ///    duration, which is where the old interval started — see
        ///    `Interval.start` for what less means once a month is clamped;
        ///  * start and end: the new start is the old end, and the new end is
        ///    the old interval's length after it, in nanoseconds of the
        ///    timeline. The new endpoints carry the old end's offset.
        ///
        /// An unbounded series runs into the edge of the years a `Year` can
        /// hold eventually, and a bounded one can too. The occurrence past
        /// that edge does exist; it just cannot be represented. So it is
        /// `error.OutOfRange`, not the end of the series, which would say the
        /// series stopped when it did not.
        pub fn next(self: *Iterator) error{OutOfRange}!?Interval {
            if (self.remaining) |remaining| {
                if (remaining == 0) return null;
            }
            if (self.started) self.current = try step(self.current);
            self.started = true;
            if (self.remaining) |*remaining| remaining.* -= 1;
            return self.current;
        }

        test next {
            // Written as a duration and an end, so the text names the last
            // occurrence and the series runs backwards from it.
            const series: RecurringInterval = .{ .count = 2, .interval = .{ .duration_end = .{
                .duration = .{ .days = 1 },
                .end = .{ .year = 2024, .month = .Mar, .day = 15 },
            } } };
            var it = series.iterator();
            try std.testing.expectEqual(@as(Day, 14), (try it.next()).?.start().day);
            try std.testing.expectEqual(@as(Day, 13), (try it.next()).?.start().day);
            try std.testing.expectEqual(@as(?Interval, null), try it.next());

            // Unbounded, into the end of the calendar.
            const forever: RecurringInterval = .{ .count = null, .interval = .{ .start_duration = .{
                .start = .{ .year = std.math.maxInt(Year), .month = .Dec, .day = 30 },
                .duration = .{ .days = 1 },
            } } };
            var edge = forever.iterator();
            _ = try edge.next(); // the 30th to the 31st
            // The 31st fits and the day after it does not, so the occurrence
            // is refused whole, before `end` could be asked for it.
            try std.testing.expectError(error.OutOfRange, edge.next());
        }
    };

    /// Writes this series in ISO 8601's own syntax, which is what `{f}`
    /// gets: `R`, the count unless the series is unbounded, a solidus, and
    /// the interval as `Interval.format` writes it.
    pub fn format(self: RecurringInterval, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('R');
        if (self.count) |count| try writer.print("{d}", .{count});
        try writer.writeByte('/');
        try self.interval.format(writer);
    }

    test format {
        var buf: [96]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const series: RecurringInterval = .{ .count = 12, .interval = .{ .start_duration = .{
            .start = .{ .year = 1985, .month = .Apr, .day = 12, .hour = 23, .minute = 20, .second = 50 },
            .duration = .{ .months = 14, .days = 15, .nanoseconds = 12 * Duration.nanoseconds_per_hour + 30 * Duration.nanoseconds_per_minute },
        } } };
        try series.format(&w);
        try std.testing.expectEqualStrings("R12/1985-04-12T23:20:50Z/P1Y2M15DT12H30M", w.buffered());

        w = std.Io.Writer.fixed(&buf);
        try (RecurringInterval{ .count = null, .interval = series.interval }).format(&w);
        try std.testing.expectEqualStrings("R/1985-04-12T23:20:50Z/P1Y2M15DT12H30M", w.buffered());
    }

    /// Writes this series as a JSON string of its ISO 8601 spelling,
    /// `"R5/2024-03-15T09:00:00Z/P1W"`, which is what `std.json.Stringify`
    /// calls when it meets one, in a field or on its own.
    ///
    /// Reading is `iso8601.parseRecurringInterval`, held to the same strict
    /// endpoints as `Interval.jsonParse`: every endpoint written has to be
    /// named to the second and carry an offset; see
    /// `json.readRecurringInterval`.
    pub fn jsonStringify(self: RecurringInterval, jw: anytype) !void {
        return json.stringify(jw, self, json.writeRecurringInterval);
    }

    test jsonStringify {
        const text = try std.json.Stringify.valueAlloc(std.testing.allocator, weekly_example, .{});
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("\"R5/2024-03-15T09:00:00Z/P7D\"", text);
    }

    /// Reads one of these from the next token of a JSON document, which has
    /// to be a string; `std.json.parseFromSlice` and its relatives call this
    /// when they meet the type. See `jsonStringify` for the text, and
    /// `json.parse` for what happens to the token.
    ///
    /// A string that is not the representation is `error.InvalidCharacter`,
    /// and one whose components are out of range — `R0` among them — is
    /// `error.Overflow`, the errors `std.json` gives for a malformed and an
    /// oversized number.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !RecurringInterval {
        return json.parse(RecurringInterval, allocator, source, options, json.readRecurringInterval);
    }

    test jsonParse {
        const Record = struct { value: RecurringInterval };
        const parsed = try std.json.parseFromSlice(Record, std.testing.allocator, "{\"value\":\"R5/2024-03-15T09:00:00Z/P7D\"}", .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(weekly_example, parsed.value.value);

        try std.testing.expectError(
            error.InvalidCharacter,
            std.json.parseFromSlice(RecurringInterval, std.testing.allocator, "\"not a series\"", .{}),
        );
    }

    /// Reads one of these from a `std.json.Value` that has already been
    /// parsed, which has to be a string; `std.json.parseFromValue` calls this
    /// when it meets the type. See `jsonParse`.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !RecurringInterval {
        _ = allocator;
        _ = options;
        return json.parseFromValue(RecurringInterval, source, json.readRecurringInterval);
    }

    test jsonParseFromValue {
        const parsed = try std.json.parseFromValue(RecurringInterval, std.testing.allocator, .{ .string = "R5/2024-03-15T09:00:00Z/P7D" }, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(weekly_example, parsed.value);
    }

    /// Five weeks from 09:00 UTC on the 15th of March 2024, for the tests.
    const weekly_example: RecurringInterval = .{ .count = 5, .interval = .{ .start_duration = .{
        .start = .{ .year = 2024, .month = .Mar, .day = 15, .hour = 9, .weekday = .Fri },
        .duration = .{ .days = 7 },
    } } };
};

/// The occurrence after `interval` in a series; see `Iterator.next`.
///
/// Both endpoints of the new occurrence are checked, including the one it
/// does not store. `Interval.end` of a start and a duration adds the
/// duration when it is asked, and panics if that leaves the calendar, so an
/// occurrence whose start fits and whose end does not must be refused here,
/// where there is an error to refuse it with.
fn step(interval: Interval) error{OutOfRange}!Interval {
    return switch (interval) {
        .start_duration => |i| blk: {
            const start = try i.start.addChecked(i.duration);
            _ = try start.addChecked(i.duration);
            break :blk .{ .start_duration = .{ .start = start, .duration = i.duration } };
        },
        .duration_end => |i| blk: {
            const end = try i.end.addChecked(i.duration.negate());
            _ = try end.addChecked(i.duration.negate());
            break :blk .{ .duration_end = .{ .duration = i.duration, .end = end } };
        },
        .start_end => |i| blk: {
            const length: Duration = .{ .nanoseconds = interval.length() };
            // Both new endpoints are measured from the old end, so they share
            // its offset, and adding nanoseconds to a reading at a fixed offset
            // moves it exactly that far along the timeline.
            break :blk .{ .start_end = .{
                .start = i.end,
                .end = try i.end.addChecked(length),
            } };
        },
    };
}

test step {
    // Two endpoints repeat their length, not a calendar duration: the 31st
    // of January to the 29th of February is 29 days, and so is the next.
    const first: Interval = .{ .start_end = .{
        .start = .{ .year = 2024, .month = .Jan, .day = 31 },
        .end = .{ .year = 2024, .month = .Feb, .day = 29 },
    } };
    const second = try step(first);
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Feb, .day = 29 }, second.start().asDate());
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 29 }, second.end().asDate());
    try std.testing.expectEqual(first.length(), second.length());
}

test {
    std.testing.refAllDecls(@This());
}
